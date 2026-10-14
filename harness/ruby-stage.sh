#!/usr/bin/env bash
# One-time DUT preparation: toolchain, FDO tooling, Ruby source. Runs ON the DUT (Ubuntu 26.04).
#
# Idempotent -- every stage is skipped if its output already exists, so re-run it freely after a
# reboot. These boxes self-power-off when idle and the public IP churns on every stop/start, so
# "re-runnable without thinking" is worth more here than "fast".

set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/ruby-env.sh"

mkdir -p "$REMOTE_ROOT"/{src,build,prof,log,res}
cd "$REMOTE_ROOT/src"

echo "===== 1/4 packages"
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -qq
# gcc-15/g++-15 explicitly (not the `gcc` alias -- gcc-14 and gcc-16 are both available here and
# an unpinned default could silently change the campaign's compiler mid-flight).
# ruby-dev + the stock ruby are pulled in because bundler/gem work during workload setup needs a
# working interpreter before any arm is built.
sudo apt-get install -y -qq \
    "$CC" "$CXX" build-essential make bison flex texinfo patch wget curl git \
    libssl-dev libreadline-dev zlib1g-dev libyaml-dev libffi-dev libgdbm-dev libncurses-dev \
    libjemalloc-dev rustc \
    linux-tools-common "linux-tools-$(uname -r)" linux-tools-generic \
    llvm-bolt cmake ninja-build pkg-config python3 python3-dev libelf-dev \
    numactl libnuma-dev htop jq ruby ruby-dev \
    protobuf-compiler libprotobuf-dev libgflags-dev libgoogle-glog-dev libunwind-dev
echo "  cc:   $($CC --version | head -1)"
gcc_version_check
echo "  bolt: $(llvm-bolt --version 2>/dev/null | grep -m1 -i version || echo MISSING)"

echo "===== 2/4 autofdo (create_gcov)"
# create_gcov writes a gcov file whose version must match the consuming gcc. A mismatch surfaces
# as a bland "profile not found" from gcc rather than a version error, so the pairing is checked
# at build time in ruby-build.sh rather than trusted here.
if command -v create_gcov >/dev/null 2>&1; then
  echo "  present: $(command -v create_gcov)"
else
  [ -d autofdo ] || git clone -q --recursive https://github.com/google/autofdo.git
  cd autofdo
  rm -rf b && mkdir b && cd b
  # ENABLE_TOOL=GCOV builds create_gcov (the gcc-facing tool); the LLVM-facing tools are not
  # needed because every arm here is gcc-built.
  # CMAKE_POLICY_VERSION_MINIMUM=3.5 is required on Ubuntu 26.04: its cmake is 4.2, which dropped
  # compatibility with pre-3.5 policies, and autofdo's vendored third_party/glog still declares
  # one. Without the flag the configure fails outright.
  cmake -G Ninja -DCMAKE_BUILD_TYPE=Release -DENABLE_TOOL=GCOV \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5 .. >/dev/null
  ninja
  sudo install -m755 create_gcov dump_gcov profile_merger /usr/local/bin/
  cd "$REMOTE_ROOT/src"
  echo "  built: $(command -v create_gcov)"
fi

echo "===== 3/4 ruby $RUBY_VER source"
[ -f "ruby-$RUBY_VER.tar.gz" ] || wget -q "$RUBY_SRC_URL"
[ -d "ruby-$RUBY_VER" ] || tar xf "ruby-$RUBY_VER.tar.gz"
echo "  $(ls -d "ruby-$RUBY_VER")"

echo "===== 4/4 profiling prerequisites"
# perf_event_paranoid is 4 on a stock Ubuntu 26.04 image, which blocks ALL user sampling. Both
# AutoFDO and BOLT need samples, so this is a hard prerequisite, not a tuning nicety.
echo "  perf_event_paranoid was: $(cat /proc/sys/kernel/perf_event_paranoid)"
sudo sysctl -q -w kernel.perf_event_paranoid=0
sudo sysctl -q -w kernel.kptr_restrict=0 || true
# Persist it: a reboot otherwise silently re-breaks the afdo/bolt arms.
echo 'kernel.perf_event_paranoid=0' | sudo tee /etc/sysctl.d/99-perf.conf >/dev/null
echo "  perf_event_paranoid now: $(cat /proc/sys/kernel/perf_event_paranoid)"

# Establish LBR availability NOW. m6i is virtualised and AWS does not expose the LBR/BTS stack on
# all instance families; `perf record -b` then fails. Finding that out after a 20-minute build is
# pure waste, and the fallback differs per tool:
#   no LBR -> AutoFDO loses branch counts (much weaker profile), llvm-bolt needs -nl.
echo -n "  LBR (-b): "
if perf record -q -o /tmp/lbrtest.data -e cycles:u -b -- sleep 0.3 >/dev/null 2>&1; then
  echo "available"
else
  echo "NOT AVAILABLE -- afdo* arms weaken, *b arms need llvm-bolt -nl"
fi
echo -n "  BRS (-j any,u): "
if perf record -q -o /tmp/brstest.data -e cycles:u -j any,u -- sleep 0.3 >/dev/null 2>&1; then
  echo "available"
else
  echo "NOT AVAILABLE"
fi
rm -f /tmp/lbrtest.data /tmp/brstest.data

echo
echo "staged. footprint: $(du -sh "$REMOTE_ROOT" 2>/dev/null | cut -f1)  free: $(df -h / | awk 'NR==2{print $4}')"
