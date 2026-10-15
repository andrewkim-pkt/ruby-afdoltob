# Prebuilt binaries and FDO profiles — Ruby 4.0.6, gcc 15.2.0

| file | size | md5 |
|---|---|---|
| `ruby-4.0.6-afdoltob-icelake.tar.xz` | 11.3 MB | `98a6e2101d995760488d0182c3eba22b` |
| `ruby-4.0.6-base-icelake.tar.xz` | 21.1 MB | `4a2cffa2e6794bda2de435ae0337d187` |
| `ruby-4.0.6-fdo-profiles.tar.xz` | 3.2 MB | `6c16dad0bf88c15ce01c6191e463f115` |

* **afdoltob** — the winning arm. Everything below applies to it.
* **base** — the `-O3 -march=native` baseline, so the published **+20.42% / +13.77%** comparison can
  be reproduced rather than taken on faith. `bin/ruby` md5 `c6f32808afea0726d9d04db50b50ff40`,
  matching the campaign MANIFEST. Same install rules and same Ice Lake restriction as afdoltob.
  Larger than afdoltob because BOLT strips debug sections and base keeps them.
* **fdo-profiles** — the collected AutoFDO `ruby.gcov`, BOLT `.fdata` and PGO `.gcda` for all eight
  FDO arms (41 MB raw). These let an arm be **rebuilt without re-running training**, which is
  otherwise a multi-hour step. Saved deliberately: an earlier PostgreSQL campaign lost its PGO
  `.gcda` with the build box, after which no new PGO arm could ever share that profile again.
  Pair them with the matching `-fprofile-use -fprofile-dir=` / `-fauto-profile=` /
  `perf2bolt`-less `llvm-bolt -data=` invocations in [../BUILD-STEPS.md](../BUILD-STEPS.md).

## The afdoltob binary

`ruby-4.0.6-afdoltob-icelake.tar.xz` — 11.3 MB, md5 **`98a6e2101d995760488d0182c3eba22b`**

This is the winning arm of the campaign: **+20.42% geomean** over `-O3 -march=native` on
ruby-bench headline, and **+13.77% on `lobsters`** (715.7 → 629.1 ms), measured with **YJIT
enabled**. See [../RESULTS-RUBY40-YJIT.md](../RESULTS-RUBY40-YJIT.md).

Pulled live off the build box — **not a rebuild**. The `bin/ruby` inside the archive is
byte-identical to the binary that produced the published numbers:

| file | md5 | size |
|---|---|---|
| `bin/ruby` | **`cf4c273637b731c480862d36d7eb1c0f`** | 15.3 MB |

That md5 matches `results-ruby40-yjit/fingerprints/afdoltob.txt` and the campaign `MANIFEST`, so
any number in this repo can be traced to this exact binary.

## READ THIS FIRST — three things that will bite you

**1. `-march=native` on Ice Lake. This binary is not portable.**
Built with `-O3 -march=native -mtune=native` on an **Intel Xeon Platinum 8375C (Ice Lake-SP,
family 6 model 106)**. It uses AVX-512 and other Ice Lake instructions. It will almost certainly
**crash with SIGILL** on older Intel parts, on AMD, and on Graviton/ARM. It should run on
Ice Lake-SP or newer Intel server parts, but it is only *tested* on 8375C.

**2. You must pass `--yjit`, or you are not running the measured configuration.**
YJIT is compiled in but **off by default**. Every number in this repo was measured with
`--yjit`. Without it you get a different operating point entirely — and a different FDO
mechanism (see the mechanism table in the top-level README).

```bash
ruby --yjit -v     # must print "+YJIT"
```

**3. The binary is NOT relocatable.** It was built without `--enable-load-relative`, so the
stdlib path is baked in at the original prefix. Unpacking elsewhere and running it plainly fails
with `RubyGems' were not loaded` / `did_you_mean' was not loaded`. Verified, not assumed — see the
install options below for the two ways to handle it.

## Install

### Option A — unpack at the original prefix (simplest)

```bash
sudo mkdir -p /home/ubuntu/ruby-fdo/inst
sudo tar xf ruby-4.0.6-afdoltob-icelake.tar.xz -C /home/ubuntu/ruby-fdo/inst
/home/ubuntu/ruby-fdo/inst/ruby-afdoltob/bin/ruby --yjit -v
```

The archive unpacks to a single top-level directory `ruby-afdoltob/`, so the result is
`/home/ubuntu/ruby-fdo/inst/ruby-afdoltob/`.

### Option B — unpack anywhere, set `RUBYLIB`

```bash
tar xf ruby-4.0.6-afdoltob-icelake.tar.xz -C /opt
R=/opt/ruby-afdoltob
export RUBYLIB="$R/lib/ruby/4.0.0:$R/lib/ruby/4.0.0/x86_64-linux"
$R/bin/ruby --yjit -e 'require "json"; puts "OK #{RUBY_VERSION} yjit=#{RubyVM::YJIT.enabled?}"'
# => OK 4.0.6 yjit=true
```

Both options are tested. Option B was verified with the original prefix hidden inside a private
mount namespace, so the `RUBYLIB` override genuinely works rather than silently falling back to
another install.

## What is and isn't in the archive

Included (47 MB unpacked): `bin/` (the BOLT-optimised `ruby` plus the gem/bundler stubs),
`lib/ruby/4.0.0` (stdlib), `lib/pkgconfig`, `include/`, and the build `FINGERPRINT`.

Deliberately excluded:

| excluded | size | why |
|---|---|---|
| `bin/ruby.prebolt` | 139 MB | the pre-BOLT binary, kept on the build box for A/B; not needed to run |
| `lib/libruby-static.a` | 214 MB | static library for linking, not needed to run |
| `lib/ruby/gems` | 423 MB | was a symlink to the shared gem set (see below) |

Nothing that affects execution was removed, and `bin/ruby` is untouched — its md5 is unchanged.

## No gems are included, and that is also a scope statement

`gem install` works normally; the archive simply ships no gems. This matters for interpreting the
result: during the campaign **all nine arms shared one gem set built by the `base` arm**, because
ruby-bench compiles native extensions *with the ruby under test* — otherwise the PGO arms would
build extensions with `-fprofile-generate`, polluting the very profile being collected.

**So the measured +20.42% is FDO of the Ruby core only.** Gem native code was identical across
arms and unoptimised. Applying FDO across the whole stack should yield more, not less.

## Do not mix prefixes

Do not point this `ruby` at another install's `lib/ruby`, and do not install it over an existing
Ruby tree. The stdlib shipped here is the one this binary was built against; mixing versions
produces load errors that look like gem problems but are not.

## The profile this binary carries

Trained with AutoFDO (`perf record -e cycles:u -b` → `create_gcov`) on **ruby-bench
`--category=headline`, 16 benchmarks, under `--yjit`**, then LTO, then BOLT
(`-reorder-blocks=ext-tsp -reorder-functions=hfsort+ -split-functions -split-all-cold -split-eh
-icf=1`).

FDO results are only as representative as the training workload. If your workload differs
substantially from a Rails/templating/parsing mix, retrain rather than assuming this profile
transfers — the harness in [../harness/](../harness/) does this in two variables
(`TRAIN_CMD`/`MEAS_CMD`).

Also worth knowing: on `lobsters` specifically, LTO *hurts* the PGO path, and the arm ordering
differs from the geomean. `afdoltob` wins under both, which is why it is the one shipped here.
