#!/usr/bin/env bash
# Build one Ruby arm. Runs ON the DUT.
#
#   ./ruby-build.sh <arm>     arm in: base pgo pgolto pgoltob afdo afdolto afdoltob
#
# Each arm installs to /opt/ruby-<arm> and drops a fingerprint (md5 + the exact flag set) next to
# it, so a result can always be traced back to the binary that produced it. The DB campaigns
# repeatedly lost time to "which binary was that?", and an md5 recorded at build time is the only
# thing that settled it.

set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/ruby-env.sh"

ARM="${1:?usage: ruby-build.sh <arm>}"
case " $ARMS " in *" $ARM "*) ;; *) echo "unknown arm: $ARM (have: $ARMS)" >&2; exit 2 ;; esac

SRC="$REMOTE_ROOT/src/ruby-$RUBY_VER"
BLD="$REMOTE_ROOT/build/$ARM"
# Installs live under the campaign root, not /opt: no sudo in the build path, and `du -sh
# $REMOTE_ROOT` stays the whole footprint of the campaign.
PFX="$REMOTE_ROOT/inst/ruby-$ARM"
PROF="$REMOTE_ROOT/prof/$ARM"
LOG="$REMOTE_ROOT/log/build-$ARM.log"
mkdir -p "$BLD" "$PROF" "$(dirname "$LOG")"

command -v "$CC" >/dev/null || { echo "$CC not installed -- run ruby-stage.sh first" >&2; exit 4; }
gcc_version_check || exit 5

J="$(nproc)"

# ---- what each arm adds on top of the common baseline -----------------------
cflags="$BASE_CFLAGS"; ldflags=""; needs_lto=0; needs_bolt=0; mode=plain
case "$ARM" in
  base)                                                      ;;
  pgo)        mode=pgo                                       ;;
  pgolto)     mode=pgo;  needs_lto=1                         ;;
  pgoltob)    mode=pgo;  needs_lto=1; needs_bolt=1           ;;
  pgob)       mode=pgo;              needs_bolt=1           ;;
  afdo)       mode=afdo                                      ;;
  afdolto)    mode=afdo; needs_lto=1                         ;;
  afdoltob)   mode=afdo; needs_lto=1; needs_bolt=1           ;;
  afdob)      mode=afdo;             needs_bolt=1           ;;
esac
[ "$needs_lto" = 1 ]  && { cflags="$cflags $LTO_FLAGS"; ldflags="$ldflags $LTO_FLAGS"; }
[ "$needs_bolt" = 1 ] && ldflags="$ldflags $BOLT_LDFLAGS"

# Records the LAST pass's full flag set so FINGERPRINT is self-sufficient. The original version
# recorded only the arm-level $cflags/$ldflags, which made `base` and `pgo` look identical in their
# fingerprints despite different md5s -- the `-fprofile-use …` set that actually distinguishes them
# was missing. Same for `-fauto-profile=` on the afdo arms.
FINAL_CFLAGS=""; FINAL_LDFLAGS=""

configure_and_make() {  # $1 extra cflags, $2 extra ldflags
  FINAL_CFLAGS="$cflags $1"; FINAL_LDFLAGS="$ldflags $2"
  rm -rf "$BLD"; mkdir -p "$BLD"; cd "$BLD"
  "$SRC/configure" \
      --prefix="$PFX" \
      --disable-install-doc \
      --enable-shared=no \
      CC="$CC" CXX="$CXX" \
      CFLAGS="$cflags $1" \
      LDFLAGS="$ldflags $2" \
      optflags="" debugflags=""
  make -j"$J"
  rm -rf "$PFX"
  make install
  # make install recreated the prefix, so the shared-gem link has to be re-established after
  # EVERY install -- including the instrumented first pass of a PGO arm, whose priming run needs
  # the gems to already be there.
  if [ "$ARM" != base ] && [ -d "$REMOTE_ROOT/gems-shared" ]; then
    "$here/ruby-sharegems.sh" "$ARM" || echo "  WARNING: $ARM will install its own gems" >&2
  fi
}

# The harness installs each benchmark's gems on first use with the ruby under test, and for the
# Rails benchmarks that is dozens of gems plus a db:migrate/db:seed. If that happens DURING a
# profiled run, the profile is dominated by bundler, rubygems and ActiveRecord migrations rather
# than by the benchmark -- which would quietly train every FDO arm on the wrong code. So prime
# first, unprofiled, and only then train or sample.
prime() {
  echo "== priming gems for $ARM (unprofiled)"
  env ARM="$ARM" RUBY_BIN="$PFX/bin/ruby" YJIT_BENCH="$YJIT_BENCH" \
      HL_TRAIN_WARMUP=0 HL_TRAIN_BENCH=1 \
      bash -c "$TRAIN_CMD" >"$REMOTE_ROOT/log/prime-$ARM.log" 2>&1 \
    || { echo "  prime failed, see log/prime-$ARM.log" >&2; return 1; }
}

train() {
  ruby_env_check || { echo "cannot train without a workload" >&2; exit 3; }
  echo "== training $ARM"
  env ARM="$ARM" RUBY_BIN="$PFX/bin/ruby" YJIT_BENCH="$YJIT_BENCH" \
      HL_TRAIN_WARMUP="$HL_TRAIN_WARMUP" HL_TRAIN_BENCH="$HL_TRAIN_BENCH" \
      bash -c "$TRAIN_CMD"
}

case "$mode" in
  plain)
    configure_and_make "" ""
    ;;

  pgo)
    # Pass 1: instrumented. Ruby runs the freshly built miniruby during its own build, so the
    # tree is already littered with counters before training starts -- wipe them, otherwise the
    # profile is dominated by Ruby compiling its own stdlib rather than by the workload.
    configure_and_make "-fprofile-generate -fprofile-dir=$PROF" "-fprofile-generate"
    prime
    # Wipe counters AFTER priming: Ruby runs its own miniruby during the build and bundler runs
    # during priming, so without this the profile is mostly Ruby compiling its stdlib and
    # resolving gems.
    rm -f "$PROF"/*.gcda
    train
    # Pass 2: use it. -fprofile-correction is required because the training run is threaded and
    # gcc otherwise errors on inconsistent counters; coverage-mismatch is demoted to a warning
    # because LTO changes the unit layout between passes.
    # -Wno-missing-profile is REQUIRED, not cosmetic: Ruby's configure has a "whether CFLAGS is
    # valid" probe that compiles a trivial file and rejects the flags if anything appears on
    # stderr. Under -fprofile-use that probe file has no counters, gcc warns -Wmissing-profile,
    # and configure concludes the whole flag set is broken. This cost the first pgo arm.
    configure_and_make \
      "-fprofile-use -fprofile-dir=$PROF -fprofile-correction -Wno-missing-profile -Wno-error=coverage-mismatch -Wno-coverage-mismatch" ""
    ;;

  afdo)
    # AutoFDO needs a *working* binary to sample, so pass 1 is just the baseline build.
    configure_and_make "" ""
    train_perf="$PROF/perf.data"
    ruby_env_check || exit 3
    prime
    echo "== sampling $ARM"
    # -b (LBR) is what create_gcov wants for branch counts; staging confirmed LBR works on this
    # m6i.metal. --per-thread/-a are deliberately avoided: the harness pins ruby to one core, so
    # a plain child-following record already captures everything that matters.
    env ARM="$ARM" RUBY_BIN="$PFX/bin/ruby" YJIT_BENCH="$YJIT_BENCH" \
        HL_TRAIN_WARMUP="$HL_TRAIN_WARMUP" HL_TRAIN_BENCH="$HL_TRAIN_BENCH" \
        perf record -o "$train_perf" -e cycles:u -b -- bash -c "$TRAIN_CMD"
    # NOTE: create_gcov must match the gcc gcov version. The MariaDB campaign needed a patch to
    # create_gcov for exactly this; see ruby-autofdo-setup.sh.
    create_gcov --binary "$PFX/bin/ruby" --profile "$train_perf" \
                --gcov "$PROF/ruby.gcov" -gcov_version=2
    # Same configure probe problem as the PGO second pass: -fauto-profile warns on a file absent
    # from the profile, which configure reads as "CFLAGS invalid".
    configure_and_make "-fauto-profile=$PROF/ruby.gcov -Wno-missing-profile" ""
    ;;
esac

# ---- BOLT, last of all ------------------------------------------------------
# On gcc, BOLT stacked on PGO+LTO was neutral-to-negative for both MariaDB and PG. It is run here
# to confirm that on Ruby, not because a gain is expected. The pre-BOLT binary is kept so the
# *b arm can be compared against its own base rather than against a different arm.
if [ "$needs_bolt" = 1 ]; then
  ruby_env_check || exit 3
  cp "$PFX/bin/ruby" "$PFX/bin/ruby.prebolt"
  echo "== bolt sampling $ARM"
  prime
  env ARM="$ARM" RUBY_BIN="$PFX/bin/ruby" YJIT_BENCH="$YJIT_BENCH" \
      HL_TRAIN_WARMUP="$HL_TRAIN_WARMUP" HL_TRAIN_BENCH="$HL_TRAIN_BENCH" \
      perf record -o "$PROF/bolt.data" -e cycles:u -j any,u -- bash -c "$TRAIN_CMD"
  perf2bolt -p "$PROF/bolt.data" -o "$PROF/bolt.fdata" "$PFX/bin/ruby.prebolt"
  llvm-bolt "$PFX/bin/ruby.prebolt" -o "$PFX/bin/ruby" -data="$PROF/bolt.fdata" \
      -reorder-blocks=ext-tsp -reorder-functions=hfsort+ -split-functions -split-all-cold \
      -split-eh -dyno-stats -icf=1 -use-gnu-stack
fi

# ---- fingerprint ------------------------------------------------------------
{
  echo "arm=$ARM"
  echo "ruby=$RUBY_VER"
  echo "gcc=$("$CC" -dumpfullversion)"
  echo "cflags=$cflags"
  echo "ldflags=$ldflags"
  # The arm-level flags above do not include the profile flags; these two do.
  echo "final_cflags=$FINAL_CFLAGS"
  echo "final_ldflags=$FINAL_LDFLAGS"
  echo "bolt=$needs_bolt lto=$needs_lto mode=$mode"
  echo "md5=$(md5sum "$PFX/bin/ruby" | cut -d' ' -f1)"
  echo "built=$(date -u +%FT%TZ)"
  echo "host=$(hostname)"
} | tee "$PFX/FINGERPRINT"
"$PFX/bin/ruby" -v
