#!/usr/bin/env bash
# Point an arm's gem directory at the shared set built by `base`. Runs ON the DUT.
#
#   ./ruby-sharegems.sh <arm>
#
# WHY THIS IS A CORRECTNESS FIX AND NOT JUST A SPEEDUP.
# yjit-bench installs each benchmark's gems using the ruby under test, into that ruby's own gem
# dir -- ~355 MB and ~15 min per arm, which alone would add over two hours across nine arms. But
# the bigger problem is what gets installed: native extensions are compiled with the CFLAGS
# recorded in that ruby's rbconfig. So the pgo arms would build their extensions with
# -fprofile-generate (writing stray .gcda and polluting the very profile being collected), and
# the lto arms would build them with -flto. Each arm would then be running *different extension
# code*, and the measured difference would no longer be attributable to the ruby binary.
#
# Sharing one gem set built by the plain `base` arm makes the ruby executable the only thing that
# varies between arms, which is exactly the variable under test.
#
# SCOPE THIS IMPOSES ON THE RESULT, and it must be stated when quoting numbers: the gain measured
# is FDO of the Ruby core only. Native gem code (sqlite3, nokogiri, prism's C bits in gems) is
# identical across arms and is NOT optimised. Real-world gain from applying FDO to the whole
# stack would be larger; this isolates the interpreter, which is the thing being studied.
#
# SAFETY: every arm is the same Ruby 3.4.11 built by the same gcc 15.2.0, so the extension ABI
# (3.4.0) is identical and a .so built under one loads under any other. That is the same
# assumption rbenv/chruby users rely on when sharing a gemset across identical versions. It is
# verified rather than trusted -- ruby-build.sh runs a load smoke-test after linking.

set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/ruby-env.sh"

ARM="${1:?usage: ruby-sharegems.sh <arm>}"
SHARED="$REMOTE_ROOT/gems-shared"
PFX="$REMOTE_ROOT/inst/ruby-$ARM"
BASEPFX="$REMOTE_ROOT/inst/ruby-base"

[ -d "$PFX" ] || { echo "arm $ARM not installed" >&2; exit 2; }

# First call promotes base's populated gem dir to the shared location.
if [ ! -d "$SHARED" ]; then
  [ -d "$BASEPFX/lib/ruby/gems" ] || { echo "base arm has no gems yet -- prime base first" >&2; exit 3; }
  echo "promoting base gem set -> $SHARED"
  mv "$BASEPFX/lib/ruby/gems" "$SHARED"
  ln -s "$SHARED" "$BASEPFX/lib/ruby/gems"
  # Keep base's gem-generated bin stubs (rails, rubocop, ...) as the canonical set to copy from.
  mkdir -p "$REMOTE_ROOT/gems-shared-bin"
  cp -n "$BASEPFX"/bin/* "$REMOTE_ROOT/gems-shared-bin/" 2>/dev/null || true
fi

[ "$ARM" = base ] && { echo "base already owns the shared set"; exit 0; }

# Replace the arm's gem dir with a link to the shared one.
if [ -L "$PFX/lib/ruby/gems" ]; then
  echo "$ARM already shares the gem set"
else
  rm -rf "$PFX/lib/ruby/gems"
  ln -s "$SHARED" "$PFX/lib/ruby/gems"
fi

# Gem executables are generated into <prefix>/bin at install time, so an arm that never ran
# `gem install` lacks the stubs that `bundle exec rails` resolves through. Copy the ones it is
# missing; -n so the arm's own ruby/gem/bundle binaries are never overwritten.
cp -n "$REMOTE_ROOT/gems-shared-bin"/* "$PFX/bin/" 2>/dev/null || true

# Verify, loudly. A native extension failing to load here means the ABI assumption above is
# wrong for this pair, and the arm must install its own gems instead.
echo -n "verify $ARM: "
if "$PFX/bin/ruby" -e 'require "sqlite3"; require "json"; puts "ext-load OK #{RUBY_VERSION} sqlite3=#{SQLite3::VERSION}"' 2>&1; then :
else
  echo "SHARED GEMS REJECTED by $ARM -- unlink and let it install its own" >&2
  rm -f "$PFX/lib/ruby/gems"
  exit 4
fi
