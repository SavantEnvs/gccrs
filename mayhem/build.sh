#!/usr/bin/env bash
#
# mayhem/build.sh — builds the gccrs fuzz targets and the libiberty test suite.
#
#  * libiberty (demanglers, simple-object readers) with $SANITIZER_FLAGS + DWARF 3,
#    out of tree in mayhem/out/libiberty-fuzz, and two libFuzzer harnesses
#    (+ -standalone reproducers) linked against it.
#  * the legacy go-fuzz target on libgo/go/html (Go stdlib copy vendored for gccgo),
#    built from a copy of that package in mayhem/out/go-html with go-fuzz-build.
#  * libiberty again with NORMAL flags in mayhem/out/libiberty-test plus its
#    test-demangle runner, which mayhem/test.sh runs.
#
# Re-runnable and air-gapped: every build dir lives under mayhem/out (gitignored),
# and Go modules resolve from the in-image GOMODCACHE file proxy first.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
: "${SRC:=/mayhem}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"
OUT="$SRC/mayhem/out"
mkdir -p "$OUT"

# ── 1) libiberty, sanitized + coverage-instrumented ───────────────────────────
# UBSan vla-bound is relaxed for libiberty only: cp-demangle.c sizes its component/subst
# VLAs from strlen(mangled), so a zero-length name declares zero-length arrays that are
# never indexed (d_make_comp bounds-checks against num_comps). libFuzzer always runs the
# empty input first, so with vla-bound halting every run would stop on that benign UB.
# ASan and every other UBSan check stay on and halting.
LIBIBERTY_SAN="$SANITIZER_FLAGS"
case "$SANITIZER_FLAGS" in *undefined*) LIBIBERTY_SAN="$SANITIZER_FLAGS -fno-sanitize=vla-bound" ;; esac
mkdir -p "$OUT/libiberty-fuzz"
(
  cd "$OUT/libiberty-fuzz"
  "$SRC/libiberty/configure" --disable-shared \
      CC="$CC" CFLAGS="-O1 $LIBIBERTY_SAN -fsanitize=fuzzer-no-link $DEBUG_FLAGS" >/dev/null
  make -j"$MAYHEM_JOBS" libiberty.a
)
LIBIBERTY_FUZZ="$OUT/libiberty-fuzz/libiberty.a"

# ── 2) libiberty harnesses: libFuzzer binary + standalone reproducer each ─────
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$OUT/lsan_off.o"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$OUT/standalone_main.o"
for h in demangle_fuzz simple_object_fuzz; do
  $CC $SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link -I"$SRC/include" \
      -c "$SRC/mayhem/harnesses/$h.c" -o "$OUT/$h.o"
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE \
      "$OUT/$h.o" "$OUT/lsan_off.o" "$LIBIBERTY_FUZZ" -o "/mayhem/$h"
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS \
      "$OUT/standalone_main.o" "$OUT/$h.o" "$OUT/lsan_off.o" "$LIBIBERTY_FUZZ" -o "/mayhem/$h-standalone"
  echo "built /mayhem/$h and /mayhem/$h-standalone"
done

# ── 3) legacy go-fuzz target: libgo/go/html Fuzz() ────────────────────────────
: "${GO_DEBUG_FLAGS:=-g -gdwarf-3}"
export GOFLAGS="${GOFLAGS:--mod=mod}"
export GOPROXY="${GOPROXY:-file://$(go env GOMODCACHE)/cache/download,https://proxy.golang.org,direct}"
export GOSUMDB="${GOSUMDB:-off}"
GOPKG="$OUT/go-html"
rm -rf "$GOPKG" && mkdir -p "$GOPKG"
cp "$SRC"/libgo/go/html/entity.go "$SRC"/libgo/go/html/escape.go "$SRC"/libgo/go/html/fuzz.go "$GOPKG/"
GO_VER="$(go env GOVERSION | sed -E 's/^go([0-9]+\.[0-9]+).*/\1/')"
printf 'module gccrs.local/html\n\ngo %s\n' "$GO_VER" > "$GOPKG/go.mod"
(
  cd "$GOPKG"
  go get github.com/dvyukov/go-fuzz/go-fuzz-dep
  # cgo's C parts (incl. go-fuzz's libFuzzer glue) at DWARF 3 like every other C object.
  CGO_CFLAGS="${CGO_CFLAGS:--O2} $GO_DEBUG_FLAGS" go-fuzz-build -libfuzzer -o "$OUT/html-string-fuzz.a" .
)
# go-fuzz's libFuzzer path is ASan-only (as OSS-Fuzz builds Go targets). This go-fuzz
# revision's cgo export already defines LLVMFuzzerInitialize (waits for the Go runtime).
# lsan_off.o (DWARF 3) is linked first so the binary's first CU is DWARF 3; the Go linker
# itself only emits DWARF 4/5 for the Go code.
$CXX -fsanitize=address $LIB_FUZZING_ENGINE $GO_DEBUG_FLAGS \
    "$OUT/lsan_off.o" "$OUT/html-string-fuzz.a" -o /mayhem/html-string-fuzz.libfuzzer
nm /mayhem/html-string-fuzz.libfuzzer | grep ' T LLVMFuzzerInitialize$' >/dev/null \
  || { echo "build.sh: LLVMFuzzerInitialize (Go runtime init wait) missing from html-string-fuzz.libfuzzer" >&2; exit 1; }
echo "built /mayhem/html-string-fuzz.libfuzzer"

# ── 4) libiberty test suite with NORMAL flags (the oracle mayhem/test.sh runs) ─
mkdir -p "$OUT/libiberty-test"
(
  cd "$OUT/libiberty-test"
  env -u CFLAGS -u LDFLAGS "$SRC/libiberty/configure" --disable-shared \
      CC="$CC" CFLAGS="-O2 -g $COVERAGE_FLAGS" LDFLAGS="$COVERAGE_FLAGS" >/dev/null
  make -j"$MAYHEM_JOBS" libiberty.a
  make -C testsuite test-demangle
)
# ── 5) crab1, the gccrs Rust front end, sanitized + coverage-instrumented ─────
# Only crab1 is built (no cc1/xgcc/selftests): configure the tree out of tree in
# mayhem/out/gcc-build, build the host libraries gcc/ needs, then `make -C gcc crab1`.
# Build-side generators (gengtype, genrecog, …) are built WITHOUT sanitizers
# (*_FOR_BUILD): they are build tools, not fuzzed code, and UBSan halts in
# libiberty/regex.c while gengtype runs. -fsanitize=function is relaxed for the
# compiler: GGC marking calls through a mismatched function-pointer type
# (ggc-common.cc) on every compilation; ASan and the rest of UBSan stay on and halting.
# Coverage goes on the Rust front end (gcc/rust) only, as AFL instrumentation:
# SanCov on all of GCC gave crab1 5.4M counters and Mayhem could not run it (runs
# 1-2, 0 edges); SanCov on gcc/rust ran but at 0.1 exec/s in Mayhem's
# exec-per-input mode (run 3). The fork server avoids re-loading the ~800 MB
# binary per input. The middle/back end stays sanitized but uninstrumented.
GCC_SAN="$SANITIZER_FLAGS"
case "$SANITIZER_FLAGS" in *undefined*) GCC_SAN="$SANITIZER_FLAGS -fno-sanitize=function" ;; esac
GCC_FLAGS="-O1 $GCC_SAN $DEBUG_FLAGS"
export CARGO_HOME="${CARGO_HOME:-$OUT/cargo-home}"
GCCB="$OUT/gcc-build"
mkdir -p "$GCCB"
(
  cd "$GCCB"
  if [ ! -f config.status ]; then
    env -u CFLAGS -u CXXFLAGS -u LDFLAGS "$SRC/configure" \
        --enable-languages=rust --disable-bootstrap --disable-multilib --disable-nls \
        --disable-werror --disable-gcc-selftests --disable-plugin --disable-lto \
        CC="$CC" CXX="$CXX" CFLAGS="$GCC_FLAGS" CXXFLAGS="$GCC_FLAGS" \
        LDFLAGS="$OUT/lsan_off.o" \
        CC_FOR_BUILD="$CC" CXX_FOR_BUILD="$CXX" \
        CFLAGS_FOR_BUILD="-O2 -g" CXXFLAGS_FOR_BUILD="-O2 -g" LDFLAGS_FOR_BUILD=" " >/dev/null
  fi
  make -j"$MAYHEM_JOBS" configure-gcc
  make -j"$MAYHEM_JOBS" all-libiberty all-libbacktrace all-libcpp all-libcody all-libdecnumber \
      maybe-all-build-libiberty maybe-all-build-libcpp maybe-all-build-fixincludes \
      maybe-all-zlib maybe-all-fixincludes maybe-all-libgrust
  # Pass 1: the whole of crab1 with the plain sanitized compiler (cache-friendly).
  make -j"$MAYHEM_JOBS" -C gcc crab1
  # Pass 2: recompile only the Rust front end (gcc/rust/*.o) with afl-clang-fast++
  # and relink, so crab1 runs under a fork server with AFL coverage of the front end
  # (afl: true in Mayhemfile_crab1). CLASSIC instrumentation keeps the fixed 64K
  # AFL map. Through the pinned ccache when the build runs under it.
  AFLCXX=afl-clang-fast++
  case ":$PATH:" in *:/opt/mayhem/ccache/bin:*) AFLCXX="/opt/mayhem/ccache/ccache afl-clang-fast++" ;; esac
  rm -f gcc/rust/*.o gcc/crab1
  AFL_LLVM_INSTRUMENT=CLASSIC AFL_QUIET=1 make -j"$MAYHEM_JOBS" -C gcc crab1 CXX="$AFLCXX"
  nm gcc/crab1 | grep -c __afl_area_ptr >/dev/null || { echo "crab1 has no AFL instrumentation" >&2; exit 1; }
)
cp "$GCCB/gcc/crab1" /mayhem/crab1
echo "built /mayhem/crab1"

echo "build.sh complete"
