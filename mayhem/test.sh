#!/usr/bin/env bash
#
# mayhem/test.sh — RUN libiberty's own demangler test suite (test-demangle against
# demangle-expected, d-demangle-expected and rust-demangle-expected; built by mayhem/build.sh with
# normal flags). Each expected file is a known-answer suite: mangled input -> exact demangled output.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

RUNNER="$SRC/mayhem/out/libiberty-test/testsuite/test-demangle"
[ -x "$RUNNER" ] || { echo "test.sh: $RUNNER missing - mayhem/build.sh did not build it" >&2; emit_ctrf "libiberty-test-demangle" 0 1 0; exit 1; }

passed=0; failed=0
for suite in demangle-expected d-demangle-expected rust-demangle-expected; do
  out="$("$RUNNER" < "$SRC/libiberty/testsuite/$suite" 2>&1)"; rc=$?
  echo "$out" | tail -n 20
  # test-demangle ends with "<argv0>: N tests, F failures"; require N>0 and F==0 (a no-op runner prints nothing).
  summary="$(printf '%s\n' "$out" | grep -E ': [0-9]+ tests, [0-9]+ failures$' | tail -n1)"
  n="$(printf '%s' "$summary" | sed -nE 's/.*: ([0-9]+) tests, ([0-9]+) failures$/\1/p')"
  f="$(printf '%s' "$summary" | sed -nE 's/.*: ([0-9]+) tests, ([0-9]+) failures$/\2/p')"
  if [ "$rc" -eq 0 ] && [ -n "$n" ] && [ "$n" -gt 0 ] && [ "$f" = "0" ]; then
    echo "PASS $suite ($n known-answer cases)"; passed=$((passed+1))
  else
    echo "FAIL $suite (rc=$rc, summary='$summary')"; failed=$((failed+1))
  fi
done
emit_ctrf "libiberty-test-demangle" "$passed" "$failed" 0
