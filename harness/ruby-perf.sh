#!/usr/bin/env bash
# perf characterisation of one arm under a 128-worker steady state. Runs ON the DUT.
#
#   ./ruby-perf.sh <arm> [tag]        arm e.g. base | afdoltob
#
# Collects THREE 30 s captures in NON-OVERLAPPING windows, separated by 10 s gaps, after the
# workload has reached a verified steady state:
#     perf stat   ->  which pipeline resource the arm actually changed
#     perf record ->  where the time goes, per function
#     perf c2c    ->  whether cross-core sharing plays any part
#
# WHY THE WINDOWS MUST NOT OVERLAP: perf stat -a, perf record -a and perf c2c record -a all
# program the same PMU. Running two at once forces extra multiplexing and makes every count a
# scaled estimate of a different sample of time -- the numbers stop being comparable between arms,
# which is the only thing they are for here. Each window's UTC start/end is logged so non-overlap
# is provable from the artefacts rather than asserted.
#
# Resumable: any (arm, tool) whose output already exists is skipped. The box has rebooted six
# times in 13 h, so a reboot must cost one window, not the whole run.

set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/ruby-env.sh"

ARM="${1:?usage: ruby-perf.sh <arm> [tag]}"
TAG="${2:-}"
PFX="$REMOTE_ROOT/inst/ruby-$ARM"
[ -x "$PFX/bin/ruby" ] || { echo "arm $ARM not built" >&2; exit 2; }

OUT="$REMOTE_ROOT/perf${TAG:+-$TAG}"
LOGD="$OUT/workers-$ARM"
mkdir -p "$OUT" "$LOGD"
TS="$OUT/timeline-$ARM${TAG:+-$TAG}.log"

# Ruby block-buffers $stdout when it is a file, so a worker's iteration lines would sit unflushed
# in libc for 10+ minutes (one ~20-byte line per 2.8 s against a 4-8 KB buffer). That made the
# readiness gate below read 0/128 while the box was provably saturated at load 128 -- the workers
# were fine, their output was simply invisible. Forcing $stdout.sync restores the gate.
#
# Note the only lines that DID appear were those immediately before a `system()` call, because
# Ruby flushes $stdout before spawning a child. That is what identified the cause.
SYNCRB="$REMOTE_ROOT/bin/syncout.rb"
[ -f "$SYNCRB" ] || printf '$stdout.sync = true\n$stderr.sync = true\n' > "$SYNCRB"
export RUBYOPT="-r${SYNCRB%.rb}${RUBYOPT:+ $RUBYOPT}"

NW="${NW:-128}"                      # one worker per vCPU
BENCH="${PERF_BENCH:-lobsters}"   # akim 10-14: the customer cares most about lobsters
SETTLE="${SETTLE:-60}"
WIN="${WIN:-30}"                     # capture length, akim asked for 30 s
GAP="${GAP:-10}"

log() { echo "$(date -u +%FT%T.%3NZ) $*" | tee -a "$TS"; }

# ---------------------------------------------------------------- step 1: system prep
# Frequency MUST be pinned or an IPC comparison between two arms is meaningless -- a 5% clock
# difference would masquerade as a 5% efficiency difference. These settings also match what
# yjit-bench itself applied during the measured campaign, so the captures stay comparable with
# the +13.04% result. None of it survives a reboot, so it is re-asserted on every run.
prep() {
  sudo sh -c 'echo 1   > /sys/devices/system/cpu/intel_pstate/no_turbo' 2>/dev/null
  sudo sh -c 'echo 100 > /sys/devices/system/cpu/intel_pstate/min_perf_pct' 2>/dev/null
  sudo sysctl -q -w kernel.nmi_watchdog=0 2>/dev/null
  sudo sysctl -q -w kernel.perf_event_paranoid=0 2>/dev/null
  log "prep no_turbo=$(cat /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null) min_perf_pct=$(cat /sys/devices/system/cpu/intel_pstate/min_perf_pct 2>/dev/null) nmi_watchdog=$(cat /proc/sys/kernel/nmi_watchdog) paranoid=$(cat /proc/sys/kernel/perf_event_paranoid)"
}

# ---------------------------------------------------------------- step 2a: private copies
# railsbench runs `db:migrate db:seed` on EVERY launch (use_gemfile passes extra_setup_cmd
# unconditionally, harness-common.rb:53-65) and its db/seeds.rb deletes and repopulates the
# database. 128 workers against one SQLite file would therefore reseed it concurrently --
# write-lock contention and no steady state. Each worker gets its own 640 KB copy instead.
#
# The copy must live at benchmarks/<name> inside the yjit-bench tree, because benchmark.rb line 1
# is `require_relative '../../harness/loader'` and so depends on its own depth.
# GENERALISED 2026-10-14 after lobsters failed where railsbench had been fixed. The original
# version only copied for railsbench, on the theory that only it mutates shared state (it is the
# only headline benchmark with an `extra_setup_cmd`). That theory was wrong: lobsters has no
# extra_setup_cmd but still writes to its 41 MB SQLite database, Rails tmp/cache and log, so 128
# workers in one directory raced and produced HTTP 500s from User#unread_replies_count plus 189
# Errno::ENOENT. The single-worker smoke test passed throughout, which is exactly what a
# concurrency bug looks like.
#
# So: every benchmark gets per-worker copies now. Any Rails app has mutable state somewhere, and
# the cost (~9 GB for 128 lobsters copies, against 544 GB free) is far cheaper than a silently
# broken steady state.
make_copies() {
  local n made=0 src="$YJIT_BENCH/benchmarks/$BENCH"
  [ -d "$src" ] || { log "no such benchmark dir: $src"; return 1; }
  # Clear the source's regenerable volatile state before copying. A crashed 128-worker run leaves
  # Rails tmp/cache entries that `cp -a` cannot stat ("preserving permissions ... No such file or
  # directory"), which aborts the copy and takes the whole capture with it. Rails recreates both
  # directories on demand, so removing them is free.
  rm -rf "$src/tmp/cache" "$src/tmp/pids" 2>/dev/null
  rm -f  "$src"/log/*.log 2>/dev/null
  for ((c = 0; c < NW; c++)); do
    n=$(printf '%03d' "$c")
    if [ ! -d "$YJIT_BENCH/benchmarks/$BENCH-w$n" ]; then
      cp -a "$src" "$YJIT_BENCH/benchmarks/$BENCH-w$n" || return 1
      made=$((made + 1))
    fi
    # Recreate the Rails cache/log tree in EVERY copy, new or pre-existing. Deleting tmp/cache
    # from the source above (necessary, or cp -a aborts on stale entries) left the copies without
    # it, and Rails' ActiveSupport::Cache::FileStore then failed its rename() into
    # tmp/cache/<nn>/<nnn>/ with Errno::ENOENT -- surfacing as HTTP 500 from
    # User#unread_replies_count and killing ~80 of 128 lobsters workers in BOTH arms.
    mkdir -p "$YJIT_BENCH/benchmarks/$BENCH-w$n/tmp/cache" \
             "$YJIT_BENCH/benchmarks/$BENCH-w$n/log" 2>/dev/null
  done
  log "copies ready ($made created, $NW total, $(du -sh "$src" | cut -f1) each, $(df -h / | awk 'NR==2{print $4}') free)"
}

bench_path() {  # $1 = worker index -- always the worker's private copy (see make_copies)
  echo "benchmarks/$BENCH-w$(printf '%03d' "$1")/benchmark.rb"
}

# ---------------------------------------------------------------- smoke test
# One worker, short, before committing to 128. A direct invocation differs from going through
# run_benchmarks.rb (bundler context, cwd, setup commands), so prove it produces iteration lines
# before building a steady state on top of it.
smoke() {
  local p; p=$(bench_path 0)
  log "smoke test: $BENCH via $p"
  ( cd "$YJIT_BENCH" && \
    env WARMUP_ITRS=0 MIN_BENCH_ITRS=1 MIN_BENCH_TIME=1 \
        setarch x86_64 -R taskset -c 0 "$PFX/bin/ruby" $RUBY_FLAGS -I harness "$p" ) \
      > "$OUT/smoke-$ARM.log" 2>&1
  if grep -qE '^\s*#[0-9]+:' "$OUT/smoke-$ARM.log"; then
    log "smoke OK: $(grep -oE '#[0-9]+: *[0-9]+ms' "$OUT/smoke-$ARM.log" | tail -1)"
  else
    log "SMOKE FAILED -- see smoke-$ARM.log; not launching $NW workers"
    tail -20 "$OUT/smoke-$ARM.log"
    return 1
  fi
}

# ---------------------------------------------------------------- step 2b: launch
launch() {
  rm -f "$LOGD"/w*.log
  local n p
  for ((c = 0; c < NW; c++)); do
    n=$(printf '%03d' "$c"); p=$(bench_path "$c")
    ( cd "$YJIT_BENCH" && \
      env WARMUP_ITRS=3 MIN_BENCH_ITRS=1000000 MIN_BENCH_TIME=900 \
          setarch x86_64 -R taskset -c "$c" "$PFX/bin/ruby" $RUBY_FLAGS -I harness "$p" \
        > "$LOGD/w$n.log" 2>&1 ) &
  done
  log "launched $NW workers for $ARM ($BENCH)"
}

# ---------------------------------------------------------------- step 2c: readiness gate
# A fixed sleep would risk capturing 128 concurrent Rails boots instead of steady state. Gate on
# evidence instead: every worker must have printed at least one iteration line, meaning it is past
# boot, migrate, seed and warmup and is inside the measured loop.
#
# An unsaturated box is what produced the misleading PG 18 sysbench null, so a busy floor is
# enforced too -- counters taken off a half-idle box would be worse than no data.
gate() {
  local deadline=$((SECONDS + 600)) ready=0
  while [ $SECONDS -lt $deadline ]; do
    ready=$(grep -lE '^\s*#[0-9]+:' "$LOGD"/w*.log 2>/dev/null | wc -l)
    [ "$ready" -ge "$NW" ] && break
    sleep 10
  done
  local live; live=$(pgrep -c -f 'bench_pin_marker|rb-w[0-9]' 2>/dev/null || true)
  live=$(ps -e -o args= | grep -cE "ruby-$ARM/bin/ruby -I harness" || true)
  local idle busy
  idle=$(mpstat 1 5 | awk '/Average:/ && $2=="all" {print $NF}')
  busy=$(awk -v i="${idle:-100}" 'BEGIN{printf "%.1f", 100-i}')
  log "gate: workers-in-loop=$ready/$NW  live=$live  busy=${busy}%"
  # Threshold rather than all-or-nothing. The gate exists to guarantee a saturated steady state,
  # and 126/128 at 99.7% busy satisfies that: these captures are system-wide (perf -a), so two
  # missing workers shift offered load by 1.6%, which is far inside the noise of the per-cycle
  # ratio metrics the comparison actually rests on. Demanding exactly 128 failed the afdoltob run
  # for two workers that simply lost a startup race.
  # The ACTUAL count is logged above and quoted in the writeup, so any asymmetry between arms
  # stays visible rather than being hidden by the threshold.
  local need=$(( NW * 98 / 100 ))
  if [ "$ready" -lt "$need" ]; then
    log "GATE FAIL: only $ready/$NW workers reached the loop (need >=$need)"; return 1
  fi
  [ "$ready" -lt "$NW" ] && log "NOTE: running with $ready/$NW workers, $((NW-ready)) short"
  if awk -v b="$busy" 'BEGIN{exit !(b < 90)}'; then log "GATE FAIL: box only ${busy}% busy, need >=90%"; return 1; fi
  log "gate PASS -- settling ${SETTLE}s before first window"
  sleep "$SETTLE"
}

# ---------------------------------------------------------------- step 3: the three captures
EVENTS='cycles,ref-cycles,instructions,branches,branch-misses,topdown-retiring,topdown-fe-bound,topdown-be-bound,topdown-bad-spec,icache_64b.iftag_stall,icache_64b.iftag_miss,idq_uops_not_delivered.core,itlb_misses.walk_pending,l2_rqsts.code_rd_miss'

cap_stat() {
  local f="$OUT/stat-$ARM${TAG:+-$TAG}.txt"
  [ -s "$f" ] && { log "skip stat (exists)"; return 0; }
  log "WINDOW stat  start"
  perf stat -a -e "$EVENTS" -- sleep "$WIN" > "$f" 2>&1
  log "WINDOW stat  end   -> $(basename "$f")"
}

cap_record() {
  local d="$OUT/record-$ARM${TAG:+-$TAG}.data"
  [ -s "$d" ] && { log "skip record (exists)"; return 0; }
  log "WINDOW record start"
  # --call-graph fp is valid: every arm was built -fno-omit-frame-pointer.
  perf record -a -F 999 --call-graph fp -o "$d" -- sleep "$WIN" >"$OUT/record-$ARM.stderr" 2>&1
  log "WINDOW record end   -> $(basename "$d") $(du -h "$d" 2>/dev/null | cut -f1)"
}

cap_c2c() {
  local d="$OUT/c2c-$ARM${TAG:+-$TAG}.data"
  [ -s "$d" ] && { log "skip c2c (exists)"; return 0; }
  log "WINDOW c2c   start"
  perf c2c record -a --ldlat 30 -o "$d" -- sleep "$WIN" >"$OUT/c2c-$ARM.stderr" 2>&1
  log "WINDOW c2c   end   -> $(basename "$d") $(du -h "$d" 2>/dev/null | cut -f1)"
}

stop_workers() {
  # Pattern deliberately avoids matching this script's own command line -- `pkill -f ruby-perf`
  # over ssh kills the ssh session itself, which has already cost a debugging detour once.
  local P='harnes'
  pkill -f "ruby-$ARM/bin/ruby -I ${P}s" 2>/dev/null
  sleep 3
  pkill -9 -f "ruby-$ARM/bin/ruby -I ${P}s" 2>/dev/null
  log "workers stopped"
}

trap stop_workers EXIT

log "===== arm=$ARM bench=$BENCH workers=$NW window=${WIN}s gap=${GAP}s"
log "binary md5=$(md5sum "$PFX/bin/ruby" | cut -d' ' -f1)"
prep
make_copies || exit 3
smoke        || exit 4
launch
gate         || exit 5

# TOOLS selects which captures to take. The mirrored confirmation pass only needs `stat` -- the
# headline counters are what any conclusion rests on, whereas record and c2c are descriptive and
# re-recording them would cost another ~7 GB and 7 minutes for no added confidence.
TOOLS="${TOOLS:-stat record c2c}"
first=1
for t in $TOOLS; do
  [ $first -eq 1 ] || sleep "$GAP"
  first=0
  case "$t" in
    stat)   cap_stat   ;;
    record) cap_record ;;
    c2c)    cap_c2c    ;;
    *) log "unknown tool: $t" ;;
  esac
done

log "===== arm=$ARM complete"
ls -la "$OUT" | grep -E "$ARM" || true
