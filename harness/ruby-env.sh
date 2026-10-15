#!/usr/bin/env bash
# Shared settings for the Ruby FDO campaign. Sourced by every other script; never run directly.
#
# DUT: m6i.metal, Ubuntu 26.04 LTS, gcc 15.2.0 (distro default).
#      2S Ice Lake Xeon Platinum 8375C @ 2.9 GHz, 128 vCPU, 2 NUMA nodes, 503 GiB.
#      public <DUT_PUBLIC_IP> / private <DUT_PRIVATE_IP> / us-east-1a. ssh alias: ruby-m6i
#
# This is NOT the r8i 48xl Granite Rapids box the campaign was originally scoped for, and gain
# numbers from here must be quoted as Ice Lake m6i.metal. Ice Lake has a smaller L2, no GNR-era
# front-end improvements and half the core count, all of which move FDO gain -- typically UP,
# because a weaker front end has more to gain from better code layout. Do not splice these
# numbers into the GNR-based PG/MySQL/MariaDB tables.
#
# Arms: base  pgo pgolto pgoltob pgob  afdo afdolto afdoltob afdob
#
# The two no-LTO BOLT arms (pgob, afdob) are what separate "BOLT does nothing" from "BOLT does
# nothing ON TOP OF LTO". On gcc, BOLT stacked on PGO+LTO was neutral-to-negative for both
# MariaDB and PG, and without a BOLT-without-LTO arm there is no way to tell whether BOLT is
# useless here or merely redundant with what LTO already achieved. That is exactly the question
# the MariaDB campaign could not answer.
#
# WHY A COMMON -O3 -march=native BASELINE: every previous campaign here quoted FDO gain against
# -O3 -march=native, not against distro default flags. A weaker baseline inflates the gain and
# makes the numbers non-comparable with the published db-collab results.

set -o pipefail

# ---------------------------------------------------------------- box
SSH_HOST="${SSH_HOST:-ruby-m6i}"
# 579 GB free on /, so no tmpfs juggling and no separate data volume is needed on this box.
REMOTE_ROOT="${REMOTE_ROOT:-/home/ubuntu/ruby-fdo}"

# ---------------------------------------------------------------- toolchain
# Ubuntu 26.04 ships 15.2.0 as the default gcc, so there is no from-source bootstrap. gcc-15 is
# named explicitly rather than relying on `gcc` because the box also has gcc-14 and gcc-16
# available, and an unpinned `gcc` would silently change the whole campaign's compiler if the
# default moved.
GCC_VER="${GCC_VER:-15}"
CC="${CC:-gcc-$GCC_VER}"
CXX="${CXX:-g++-$GCC_VER}"
# akim pinned the campaign to 15.2.0 exactly. Ubuntu 26.04's gcc-15 is 15.2.0-16ubuntu1, so this
# matches today -- but an apt upgrade to 15.3 would otherwise retrain every profile on a
# different compiler without anyone noticing. Checked at stage time AND at build time.
GCC_WANT="${GCC_WANT:-15.2.0}"

gcc_version_check() {
  local got; got="$("$CC" -dumpfullversion 2>/dev/null || echo none)"
  if [ "$got" != "$GCC_WANT" ]; then
    echo "ruby-env: $CC is $got, campaign is pinned to $GCC_WANT" >&2
    echo "  override with GCC_WANT=$got if that is intended" >&2
    return 1
  fi
  echo "gcc: $got (pinned $GCC_WANT) OK"
}

# ---------------------------------------------------------------- ruby
# akim 2026-10-14: switched from 3.4.11 to 4.0.6. Note the gem ABI directory changes with it
# (3.4.0 -> 4.0.0), so the shared gem set must be rebuilt from a freshly primed base arm; the old
# gems-shared tree cannot serve a 4.0 interpreter.
RUBY_VER="${RUBY_VER:-4.0.6}"
RUBY_SRC_URL="https://cache.ruby-lang.org/pub/ruby/${RUBY_VER%.*}/ruby-${RUBY_VER}.tar.gz"

# ---------------------------------------------------------------- flags
# -fno-omit-frame-pointer is NOT optional: the AutoFDO and BOLT arms both need walkable stacks
# from perf, and omitting it degrades the profile silently rather than failing loudly.
BASE_CFLAGS="${BASE_CFLAGS:--O3 -march=native -mtune=native -fno-omit-frame-pointer -g}"
LTO_JOBS="${LTO_JOBS:-32}"
LTO_FLAGS="${LTO_FLAGS:--flto=$LTO_JOBS -ffat-lto-objects}"
# BOLT rewrites the linked binary, so the final link of any *b arm must emit relocations and keep
# the symbol table; without --emit-relocs llvm-bolt refuses the input outright.
BOLT_LDFLAGS="${BOLT_LDFLAGS:--Wl,--emit-relocs -Wl,-q}"

ARMS="${ARMS:-base pgo pgolto pgoltob pgob afdo afdolto afdoltob afdob}"

# ---------------------------------------------------------------- workload
# yjit-bench, headline category: 17 server-shaped benchmarks (Rails via lobsters / railsbench /
# shipit / erubi-rails, ActiveRecord + Sequel over SQLite, Liquid templating, rubocop, ruby-lsp,
# psych, mail, hexapdf, chunky-png). Chosen as the stand-in for the GCP Ruby workload because it
# is the closest public proxy for a Ruby *service*, and measured variance on this box is 0.9%,
# which is tight enough to resolve a few-percent FDO effect.
#
# SWAPPING IN THE REAL WORKLOAD IS A TWO-VARIABLE CHANGE: point TRAIN_CMD and MEAS_CMD at it.
# Nothing else in the harness knows what the workload is.
YJIT_BENCH="${YJIT_BENCH:-$REMOTE_ROOT/src/yjit-bench}"

# ---------------------------------------------------------------- YJIT
# THE CUSTOMER RUNS WITH YJIT ENABLED (akim, 2026-10-14), so every arm is trained AND measured
# with --yjit. The first campaign ran interpreter-only, which was the wrong operating point.
#
# All nine arms already have YJIT compiled in (rustc 1.93.1 was present at configure time), so
# this needs no rebuild -- `--yjit` is a runtime flag. What it DOES invalidate is the profiles:
# they were collected in interpreter mode, and with YJIT on the hot C code is a different set
# (YJIT side-exits, GC and allocation under JIT, C function calls, megamorphic lookup) while the
# bytecode dispatch loop that dominated the interpreter profile largely disappears into
# JIT-generated machine code. So all eight FDO arms are retrained.
#
# EXPECT A SMALLER GAIN, and that is not a failure: gcc-side FDO cannot touch YJIT's output (it is
# generated at runtime) nor YJIT itself (Rust, not compiled by gcc). The remaining FDO surface is
# the C runtime. Measured reference point: YJIT alone takes base lobsters 1164.4 -> 773.2 ms.
# MUST BE EXPORTED, not just set. TRAIN_CMD is executed via `bash -c "$TRAIN_CMD"`, and that
# inner shell expands $RUBY_FLAGS from its own ENVIRONMENT -- a plain shell variable is invisible
# to it. The first YJIT rebuild attempt silently trained the pgo arm in interpreter mode for
# exactly this reason: the flag expanded to empty and the only evidence was the harness banner
# reading "+PRISM" with no "+YJIT". Always check that banner after changing this.
export RUBY_FLAGS="${RUBY_FLAGS:---yjit}"

# Training iterations are raised from 1/2 because of SAMPLE DILUTION under YJIT: a large share of
# cycles now lands in anonymous JIT-generated code with no symbols, which create_gcov and
# perf2bolt both discard. More iterations are needed to collect comparable coverage of the
# `ruby` binary's own text.
HL_TRAIN_WARMUP="${HL_TRAIN_WARMUP:-3}"
HL_TRAIN_BENCH="${HL_TRAIN_BENCH:-5}"

# Training is about COVERAGE, not precision: few iterations, all 17 benchmarks. An instrumented
# build is several times slower, so spending iterations here buys nothing.
# Single-quoted on purpose -- $RUBY_BIN and $ARM are exported by ruby-build.sh and expand when
# the command actually runs, not when this file is sourced.
TRAIN_CMD="${TRAIN_CMD:-cd \$YJIT_BENCH && ./run_benchmarks.rb --category=headline --warmup=\$HL_TRAIN_WARMUP --bench=\$HL_TRAIN_BENCH -e \"train::\$RUBY_BIN \$RUBY_FLAGS\" --out-name=train-\$ARM}"

# The measured run is driven by ruby-campaign.sh, which puts all 9 arms in ONE harness invocation
# so the comparison is paired per benchmark. MEAS_CMD exists only to satisfy the arm-level checks.
MEAS_CMD="${MEAS_CMD:-cd \$YJIT_BENCH && ./run_benchmarks.rb --category=headline -e \"m::\$RUBY_BIN \$RUBY_FLAGS\"}"

# Measured-run iteration counts. Warmup is raised from 5 to 12 for the YJIT campaign: YJIT
# compiles lazily, so early iterations include JIT compilation work rather than steady-state
# execution, and yjit-bench's own default is 15 for exactly this reason. bench=8 was already
# comfortably inside the noise floor (liquid-render showed 0.9% at bench=3).
HL_WARMUP="${HL_WARMUP:-12}"
HL_BENCH="${HL_BENCH:-8}"

# The customer is most interested in `lobsters` (akim, 2026-10-14), so it is reported as the
# headline figure alongside the 16-benchmark geomean rather than being buried in the table.
FOCUS_BENCH="${FOCUS_BENCH:-lobsters}"

ruby_env_check() {
  local missing=0
  [ -n "$TRAIN_CMD" ] || { echo "ruby-env: TRAIN_CMD unset -- workload not chosen yet" >&2; missing=1; }
  [ -n "$MEAS_CMD" ]  || { echo "ruby-env: MEAS_CMD unset -- workload not chosen yet"  >&2; missing=1; }
  return $missing
}
