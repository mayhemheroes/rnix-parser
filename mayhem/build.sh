#!/usr/bin/env bash
#
# rnix-parser/mayhem/build.sh — build nix-community/rnix-parser's cargo-fuzz targets as
# sanitized libFuzzer binaries (OSS-Fuzz Rust path: cargo-fuzz + ASan via RUSTFLAGS).
#
# rnix-parser is a pure-Rust parser for the Nix language (rowan-based lossless syntax tree).
# cargo-fuzz drives the build:
#   - it ships its own libFuzzer runtime (the produced binary IS a libFuzzer target — Mayhem
#     runs it directly via `libfuzzer: true`);
#   - ASan is enabled the Rust way, through RUSTFLAGS `-Zsanitizer=address` (NOT clang's
#     $SANITIZER_FLAGS / CFLAGS — those don't apply to rustc). nightly is required.
#
# Targets (mayhem/fuzz/fuzz_targets/*.rs — ported from upstream's own fuzz/ crate, kept in an
# ADDITIVE mayhem/fuzz crate so upstream stays untouched and upstream's undated
# fuzz/rust-toolchain.toml can't hijack toolchain selection):
#   lexer  — UTF-8-decodes the input and runs rnix::tokenizer::tokenize over it.
#   parser — UTF-8-decodes the input and runs a full rnix::Root::parse (lex + parse + AST).
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer (kept for parity even
# though the Rust build doesn't invoke clang directly; cargo's cc-built deps might).
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${MAYHEM_JOBS:=$(nproc)}"
export MAYHEM_JOBS
# cargo-fuzz has no --jobs flag; cargo reads parallelism from CARGO_BUILD_JOBS.
export CARGO_BUILD_JOBS="$MAYHEM_JOBS"

# DWARF < 4 debug-info contract (§6.2 item 10). Default uses -C llvm-args=--dwarf-version=2 to
# force DWARF 2 so Mayhem triage / gdb can resolve project source lines. The rlenv runtime may
# export RUST_DEBUG_FLAGS before re-running build.sh offline; the default only applies when the
# variable is unset or empty.
: "${RUST_DEBUG_FLAGS:=-C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=--dwarf-version=2}"

cd "$SRC"

# ── DWARF < 4 enforcement (§6.2 item 10) ─────────────────────────────────────────────────────
# Rust's ASan runtime (librustc-nightly_rt.asan.a) is compiled with the nightly's bundled LLVM,
# which defaults to DWARF 5. It is linked BEFORE the project code, so without intervention the
# first CU in the binary's .debug_info would be DWARF 5 — failing the verify-repo check. Strip
# the archive's debug sections once; the stripped .a is baked into the image, so the offline
# PATCH re-run sees the same file.
ASAN_RT="$(find "$RUSTUP_HOME/toolchains" -name "librustc-nightly_rt.asan.a" 2>/dev/null | head -1)"
if [ -n "$ASAN_RT" ] && [ -f "$ASAN_RT" ]; then
    echo "Stripping debug info from Rust ASan runtime to enforce DWARF < 4: $ASAN_RT"
    objcopy --strip-debug "$ASAN_RT"
fi

# libfuzzer-sys compiles libFuzzer from C++ via the cc crate; force DWARF 3 so those CUs also
# satisfy the check (the cc crate respects CFLAGS/CXXFLAGS). On the re-run these flags are the
# same, so cargo uses the cached libfuzzer.a without recompiling (fingerprint stable).
export CFLAGS="${CFLAGS:+$CFLAGS }-gdwarf-3"
export CXXFLAGS="${CXXFLAGS:+$CXXFLAGS }-gdwarf-3"

# The cargo-fuzz crate is ADDITIVE under mayhem/fuzz/ (harnesses ported verbatim from
# upstream's fuzz/ crate).
FUZZ_DIR="mayhem/fuzz"
FUZZ_TARGETS=(lexer parser)
TRIPLE="x86_64-unknown-linux-gnu"

# Replicate OSS-Fuzz `compile` RUSTFLAGS for a libFuzzer+ASan Rust build. cargo-fuzz sets the
# ASan flag itself by default, but we set it explicitly so the behavior is pinned and visible.
# `--cfg fuzzing` matches what libfuzzer-sys expects. RUST_DEBUG_FLAGS adds DWARF ≤ 2 debug info
# for our Rust code; combined with the stripped ASan runtime this keeps every .debug_info CU < 4.
export RUSTFLAGS="${RUSTFLAGS:-} --cfg fuzzing -Zsanitizer=address ${RUST_DEBUG_FLAGS}"

echo "=== cargo fuzz build (image-default nightly toolchain, ASan via RUSTFLAGS) ==="
echo "RUSTFLAGS=$RUSTFLAGS"

# `-O` (release w/ opt) + `--debug-assertions` mirrors OSS-Fuzz's build.sh. Use the image's
# DEFAULT toolchain (the Dockerfile pins RUSTUP_TOOLCHAIN); a `+toolchain` override would make
# rustup try to install a different channel into the shared /opt/toolchains/rust.
for t in "${FUZZ_TARGETS[@]}"; do
  echo "--- building fuzz target: $t ---"
  cargo fuzz build --fuzz-dir "$FUZZ_DIR" -O --debug-assertions "$t"
done

# Resolve the cargo target dir robustly via `cargo metadata` (the fuzz crate's target dir is
# where cargo-fuzz drops the binaries; default is <fuzz-crate>/target).
TARGET_DIR="$(cargo metadata --no-deps --format-version 1 --manifest-path "$FUZZ_DIR/Cargo.toml" \
  | python3 -c 'import json,sys;print(json.load(sys.stdin)["target_directory"])')"
echo "fuzz target_directory: $TARGET_DIR"

REL="$TARGET_DIR/$TRIPLE/release"
for t in "${FUZZ_TARGETS[@]}"; do
  bin="$REL/$t"
  if [ ! -x "$bin" ]; then
    echo "ERROR: expected fuzz binary not found at $bin" >&2
    ls -la "$REL" >&2 || true
    exit 1
  fi
  cp "$bin" "/mayhem/$t"
  echo "built /mayhem/$t"
done

# Pre-build the project's TEST suite too — with the crate's NORMAL flags (no sanitizer
# RUSTFLAGS, default target dir) — so mayhem/test.sh only RUNS it, never compiles.
echo "=== cargo test --no-run (normal flags, pre-building the test suite) ==="
RUSTFLAGS="" cargo test --no-run --jobs "$MAYHEM_JOBS"

echo "build.sh complete:"
ls -la /mayhem/lexer /mayhem/parser 2>&1 || true
