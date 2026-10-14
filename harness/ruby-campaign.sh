#!/usr/bin/env bash
# Mirrored measurement of every built arm, checkpointed per benchmark. Runs ON the DUT.
#
#   CAMP=<name> ./ruby-campaign.sh [arm ...]     default: every built arm in $ARMS
#
# THE MIRRORED DESIGN, and why it is not optional on these boxes.
# Drift during a sweep -- thermal, page cache, memory placement -- has repeatedly been LARGER than
# the FDO effect being measured. On the PG 18 NUMA work an arm ordering reversed outright between
# two runs of the same binaries, which made the result unattributable. Two defences are stacked:
#
#   1. --interleave (yjit-bench built-in): within one benchmark the arms run round-robin rather
#      than arm-after-arm, so slow drift hits all arms roughly equally.
#   2. FORWARD then REVERSE arm order (this script): any residual order effect enters the two
#      passes with opposite sign, so the per-arm mean of fwd and rev cancels it to first order.
#
# A disagreement between the passes is a RESULT, not a nuisance: if an arm wins in fwd and loses
# in rev, the honest conclusion is "inside the noise", not an average dressed up as a finding.
#
# WHY PER-BENCHMARK CHECKPOINTING. This box has rebooted three times in five hours while under
# load (01:17Z, 03:35Z, 05:50Z) -- most likely spot reclamation. yjit-bench writes its JSON only
# at the very end of a run, so a single invocation covering 16 benchmarks x 9 arms loses
# EVERYTHING on a reboot; that is exactly how the first measurement attempt was lost. Running one
# invocation per benchmark per direction checkpoints every ~2-3 minutes and makes the campaign
# resumable: completed benchmarks are skipped on restart.
#
# The cost is losing cross-benchmark interleaving, which does not matter -- benchmarks are never
# compared against each other, only arms within a benchmark, and that comparison stays interleaved.

set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/ruby-env.sh"

CAMP="${CAMP:-campaign-$(date -u +%Y%m%d-%H%M%S)}"
OUT="$REMOTE_ROOT/res/$CAMP"
mkdir -p "$OUT"

BENCHES="${BENCHES:-activerecord chunky-png erubi-rails hexapdf liquid-c liquid-compile liquid-il liquid-render lobsters mail psych-load railsbench rubocop ruby-lsp sequel shipit}"

want=("$@"); [ ${#want[@]} -eq 0 ] && read -r -a want <<<"$ARMS"
arms=(); for a in "${want[@]}"; do
  if [ -x "$REMOTE_ROOT/inst/ruby-$a/bin/ruby" ] && [ -f "$REMOTE_ROOT/inst/ruby-$a/FINGERPRINT" ]; then
    arms+=("$a")
  else echo "skip $a (not built)" >&2; fi
done
[ ${#arms[@]} -gt 0 ] || { echo "no built arms to measure" >&2; exit 2; }

# MANIFEST is rewritten on every (re)start so a resumed campaign still records exactly which
# binaries produced the numbers. A result that cannot be traced to an md5 is not a result.
{
  echo "campaign=$CAMP"
  echo "host=$(hostname)  $(. /etc/os-release; echo "$PRETTY_NAME")  kernel=$(uname -r)"
  echo "cpu=$(lscpu|grep -m1 'Model name'|cut -d: -f2|xargs)  vcpu=$(nproc)"
  echo "gcc=$($CC -dumpfullversion)  ruby=$RUBY_VER"
  echo "workload=yjit-bench headline  warmup=$HL_WARMUP  bench=$HL_BENCH"
  echo "started=$(date -u +%FT%TZ)"
  echo "arms=${arms[*]}"
  for a in "${arms[@]}"; do
    echo "  $a md5=$(md5sum "$REMOTE_ROOT/inst/ruby-$a/bin/ruby" | cut -d' ' -f1)"
  done
} > "$OUT/MANIFEST"
cat "$OUT/MANIFEST"

eargs() {  # $1 = fwd|rev
  local -a e=()
  if [ "$1" = fwd ]; then
    for a in "${arms[@]}"; do e+=(-e "$a::$REMOTE_ROOT/inst/ruby-$a/bin/ruby"); done
  else
    for ((i=${#arms[@]}-1; i>=0; i--)); do
      e+=(-e "${arms[i]}::$REMOTE_ROOT/inst/ruby-${arms[i]}/bin/ruby")
    done
  fi
  printf '%s\n' "${e[@]}"
}

run_one() {  # $1 = dir (fwd|rev), $2 = benchmark
  local dir="$1" b="$2" tag="$CAMP-$dir-$b"
  if [ -f "$OUT/$tag.json" ]; then
    echo "  skip $dir/$b (done)"
    return 0
  fi
  local -a e=(); mapfile -t e < <(eargs "$dir")
  cd "$YJIT_BENCH" || return 1
  if ./run_benchmarks.rb \
        --name_filters="$b" \
        --warmup="$HL_WARMUP" --bench="$HL_BENCH" \
        --interleave --pvalue \
        "${e[@]}" \
        --out-name="$tag" >>"$OUT/$dir.log" 2>&1
  then
    # --out-name writes "exactly this output file plus file extension, IGNORING DIRECTORIES", so
    # the json/csv land in the yjit-bench repo ROOT -- not data/, which is where --out_path would
    # put them. Looking in data/ silently found nothing and broke resume on the first attempt.
    cp -f "$YJIT_BENCH/$tag.json" "$YJIT_BENCH/$tag.csv" "$OUT/" 2>/dev/null
    if [ -f "$OUT/$tag.json" ]; then echo "  ok   $dir/$b"; else echo "  WARN $dir/$b produced no json"; fi
  else
    echo "  FAIL $dir/$b (see $dir.log)"
  fi
}

for dir in fwd rev; do
  echo
  echo "################ pass $dir  ($(date -u +%FT%TZ))"
  for b in $BENCHES; do run_one "$dir" "$b"; done
done

echo
echo "campaign $CAMP complete -> $OUT"
ls "$OUT"/*.json 2>/dev/null | wc -l | xargs echo "json files:"
