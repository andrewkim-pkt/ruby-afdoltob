#!/usr/bin/env bash
# Build every arm, in dependency order, logging each separately. Runs ON the DUT.
#
#   ./ruby-all.sh [arm ...]     default: all nine
#
# Deliberately NOT parallel across arms. The AutoFDO and BOLT arms sample with perf while the
# benchmark runs pinned to a core, so a second arm compiling at -j128 in the background would
# contaminate the very profile being collected. Serial is slower and correct.
#
# A failed arm does not abort the campaign -- it is recorded and the rest continue, so one broken
# arm does not cost the whole night. The summary at the end is the authoritative list of what
# actually got built.

set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/ruby-env.sh"

read -r -a arms <<<"${*:-$ARMS}"
mkdir -p "$REMOTE_ROOT/log"
SUM="$REMOTE_ROOT/log/build-summary.txt"
: > "$SUM"

# base must exist first: it owns the shared gem set every other arm links to.
case " ${arms[*]} " in
  *" base "*) ;;
  *) [ -d "$REMOTE_ROOT/gems-shared" ] || [ -d "$REMOTE_ROOT/inst/ruby-base/lib/ruby/gems" ] \
       || { echo "base arm must be built and primed before the others" >&2; exit 2; } ;;
esac

# An arm counts as DONE only if its FINGERPRINT exists AND still describes the binary sitting
# there. FINGERPRINT is written as the last step of ruby-build.sh, so a half-finished arm (e.g. an
# instrumented PGO first pass left behind by a reboot) has none and is correctly rebuilt.
#
# This box rebooted twice inside an hour and took the build chain down with it both times, so
# resumability is worth more than the few seconds the check costs. FORCE=1 rebuilds regardless.
arm_done() {
  local a="$1" fp="$REMOTE_ROOT/inst/ruby-$a/FINGERPRINT" bin="$REMOTE_ROOT/inst/ruby-$a/bin/ruby"
  [ "${FORCE:-0}" = 1 ] && return 1
  [ -f "$fp" ] && [ -x "$bin" ] || return 1
  local want got
  want=$(sed -n 's/^md5=//p' "$fp")
  got=$(md5sum "$bin" | cut -d' ' -f1)
  [ -n "$want" ] && [ "$want" = "$got" ]
}

for a in "${arms[@]}"; do
  if arm_done "$a"; then
    printf 'SKIP  %-10s already built  md5=%s\n' "$a" \
           "$(md5sum "$REMOTE_ROOT/inst/ruby-$a/bin/ruby" | cut -d' ' -f1)" | tee -a "$SUM"
    continue
  fi
  echo
  echo "################################################################"
  echo "# arm $a   start $(date -u +%FT%TZ)"
  echo "################################################################"
  t0=$(date +%s)
  if "$here/ruby-build.sh" "$a" > "$REMOTE_ROOT/log/build-$a.log" 2>&1; then
    t=$(( $(date +%s) - t0 ))
    md5=$(md5sum "$REMOTE_ROOT/inst/ruby-$a/bin/ruby" 2>/dev/null | cut -d' ' -f1)
    printf 'OK    %-10s %4dm%02ds  md5=%s\n' "$a" $((t/60)) $((t%60)) "$md5" | tee -a "$SUM"
  else
    t=$(( $(date +%s) - t0 ))
    printf 'FAIL  %-10s %4dm%02ds  see log/build-%s.log\n' "$a" $((t/60)) $((t%60)) "$a" | tee -a "$SUM"
    tail -15 "$REMOTE_ROOT/log/build-$a.log" | sed 's/^/      | /'
  fi
done

echo
echo "===== build summary"
cat "$SUM"
