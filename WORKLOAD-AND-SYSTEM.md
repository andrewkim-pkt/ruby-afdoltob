# Workload configs, system info, and benchmark summary

For the primary campaign: **Ruby 4.0.6 + YJIT**, `campaign-20261014-221801`, gcc 15.2.0.
Everything below was read off the measurement box, not reconstructed from notes.

---

# Part 1 — System information

## 1.1 Machine

| | |
|---|---|
| Instance | AWS **m6i.metal**, us-east-1a, `instance-life-cycle: on-demand` |
| CPU | **Intel Xeon Platinum 8375C @ 2.90 GHz** — family 6, model **106** (Ice Lake-SP), stepping 6 |
| Topology | 2 sockets × 32 cores × 2 threads = **128 vCPU**; SMT **active** |
| Frequency | base 2.90 GHz (max reads 2900 MHz while `no_turbo=1` is set; 3500 MHz stock) |
| NUMA | **2 nodes** — node0 `0-31,64-95`, node1 `32-63,96-127` (~258 GB each) |
| Memory | **503 GiB** |
| Disk | 581 GB usable on gp3 EBS (`nvme0n1`), 531 GB free |
| OS | **Ubuntu 26.04 LTS**, kernel **7.0.0-1014-aws** |

## 1.2 Cache hierarchy — the number that explains the YJIT result

| level | total | instances | per core |
|---|---|---|---|
| L1d | 3 MiB | 64 | 48 KB |
| **L1i** | **2 MiB** | **64** | **32 KB** |
| L2 | 80 MiB | 64 | 1.25 MB |
| L3 | 108 MiB | 2 | 54 MiB per socket |

**32 KB of L1i per core, shared between two SMT siblings.** Enabling YJIT pushes the baseline from
38.8% to **51.5% front-end bound**, because JIT-generated code has to share that 32 KB with the
runtime. This is the single most useful system fact for interpreting the result.

## 1.3 Toolchain

| | |
|---|---|
| Compiler | **gcc 15.2.0** (`gcc-15` 15.2.0-16ubuntu1 — Ubuntu 26.04 default, no source bootstrap) |
| Post-link | llvm-bolt / perf2bolt **21.1.8** (`apt install llvm-bolt`) |
| AutoFDO | `create_gcov`, google/autofdo HEAD, built from source |
| Rust (YJIT) | **rustc 1.93.1** — present at configure time, so YJIT is compiled into every arm |
| perf | 7.0.0; LBR (`-b`) and branch stacks (`-j any,u`) both available; PEBS present |

## 1.4 Tunables — state during measurement vs stock

**None of these survive a reboot**, so `ruby-perf.sh` re-asserts them on every run. Verified: after
one reboot the box came back at `no_turbo=0`, `min_perf_pct=22`, `nmi_watchdog=1`, while
`perf_event_paranoid` stayed 0 via `/etc/sysctl.d/99-perf.conf`.

| knob | stock | during measurement | why |
|---|---|---|---|
| `intel_pstate/no_turbo` | 0 | **1** | fixes frequency; an IPC comparison is meaningless otherwise |
| `intel_pstate/min_perf_pct` | 22 | **100** | pins to base clock |
| `intel_pstate/max_perf_pct` | 100 | 100 | — |
| `scaling_governor` | performance | performance | — |
| `kernel.nmi_watchdog` | 1 | **0** | removes a per-core perf consumer |
| `kernel.perf_event_paranoid` | **4** | **0** | stock 4 blocks *all* user sampling; AutoFDO and BOLT both fail without this |
| `kernel.randomize_va_space` | 2 | 2 | ASLR disabled per-process instead, via `setarch -R` |
| THP | `madvise` | `madvise` | distro default, untouched |

Pinning verified rather than assumed: `cycles / ref-cycles = 1.0000` in every `perf stat` window,
i.e. both arms ran at exactly the 2.90 GHz base clock.

## 1.5 Mitigations

Identical for both arms, so they cancel in the comparison — but they are part of the baseline any
absolute number is measured against:

```
indirect_target_selection : Mitigation: Aligned branch/return thunks
mmio_stale_data           : Mitigation: Clear CPU buffers; SMT vulnerable
spec_store_bypass         : Mitigation: Speculative Store Bypass disabled via prctl
spectre_v1                : Mitigation: usercopy/swapgs barriers, __user pointer sanitization
gather_data_sampling      : Vulnerable
itlb_multihit / l1tf / mds / meltdown / retbleed : Not affected
```

Note that **Indirect Target Selection mitigation is active via aligned branch/return thunks** — a
code-layout-affecting mitigation, in a study about code layout. It applies equally to both arms.

---

# Part 2 — Ruby configuration

## 2.1 Build configuration, read from the shipped `afdoltob` binary

`RbConfig::CONFIG['configure_args']` — this is the authoritative record of what was built, and it
includes the per-pass profile flags that the `FINGERPRINT` files omit:

```
'--prefix=/home/ubuntu/ruby-fdo/inst/ruby-afdoltob'
'--disable-install-doc'
'--enable-shared=no'
'CC=gcc-15' 'CXX=g++-15'
'CFLAGS=-O3 -march=native -mtune=native -fno-omit-frame-pointer -g
        -flto=32 -ffat-lto-objects
        -fauto-profile=/home/ubuntu/ruby-fdo/prof/afdoltob/ruby.gcov
        -Wno-missing-profile'
'LDFLAGS= -flto=32 -ffat-lto-objects -Wl,--emit-relocs -Wl,-q '
'optflags=' 'debugflags='
```

Resolved by configure:

```
CC        = gcc-15
optflags  = -fno-fast-math        # configure's own addition; it did NOT re-add -O3
debugflags= (empty)
LDFLAGS   = -L. -flto=32 -ffat-lto-objects -Wl,--emit-relocs -Wl,-q
            -fstack-protector-strong -rdynamic -Wl,-export-dynamic
MAINLIBS  = -lz -lrt -lrt -lgmp -ldl -lcrypt -lm -lpthread
ENABLE_SHARED = no
arch      = x86_64-linux
```

The `optflags=` override worked as intended — configure re-added only `-fno-fast-math`, **not** its
default `-O3`, so each arm's own optimisation level stands. `--enable-shared=no` matters for the
BOLT arms: with a shared build the hot interpreter would live in `libruby.so` and BOLT applied to
the thin `ruby` driver would optimise nothing.

## 2.2 Runtime configuration

| | |
|---|---|
| Ruby | **4.0.6** (2026-07-14 revision 03b6d3f889) +YJIT +PRISM |
| **YJIT** | **enabled** — `RubyVM::YJIT.enabled? == true`, via `--yjit` on every run |
| **ZJIT** | **present but unused** — ships in Ruby 4.0, compiled in, not measured |
| malloc | **system glibc** (`jemalloc = false`) — why `malloc`/`malloc_usable_size` appear in the profiles |
| GC | default implementation, `rgengc_allow_full_mark: true` |
| `GC.auto_compact` | **false** — the harness enables it only via `RUBY_GC_AUTO_COMPACT`, which was not set |
| `RUBY_GC_*` heap tuning | none; stock heap growth |

YJIT is **off by default** in the binary — `--yjit` is required. Every number in this repo was
measured with it. Environment variables the harness honours: `RUBY_GC_AUTO_COMPACT`,
`RUBY_BENCH_PIN_CPU`, `RESULT_JSON_PATH`, `RSS_CSV_PATH`, `YJIT_BENCH_STATS`, `ZJIT_BENCH_STATS`.

---

# Part 3 — Workload configuration

## 3.1 Harness

**ruby-bench (yjit-bench)**, revision **`13e09f7`** (2026-10-13), `--category=headline` = 16
benchmarks. Updated from `2c3e549` for this campaign (9 commits, mostly Windows CI; headline set
unchanged).

Iteration control (`harness/harness.rb:4-10`) loops **until
`num_itrs >= WARMUP_ITRS + MIN_BENCH_ITRS` AND `total_time >= MIN_BENCH_TIME`**.

Per-run invocation, from the harness's own logs:

```bash
bundle check 2> /dev/null || bundle install                  # per benchmark, per ruby
setarch x86_64 -R taskset -c <cpu> <ruby> --yjit -I harness benchmarks/<b>/benchmark.rb
```

`setarch -R` disables ASLR (stable symbolisation, less variance); `taskset -c N` pins to one CPU —
so **the campaign measured single-core performance**; the harness also sets `no_turbo=1` and
`min_perf_pct=100`. Determinism aids: `Random.srand(1337)` before every benchmark.

## 3.2 Iteration counts used

| role | warmup | bench | purpose |
|---|---|---|---|
| **prime** | 0 | 1 | install gems, run Rails migrations — **unprofiled** |
| **train** | **3** | **5** | the profiled run (raised from 1+2 for YJIT, see below) |
| **measure** | **12** | 8 | the result (raised from 5 for YJIT, see below) |

Both increases are forced by YJIT:

* **Measurement warmup 5 → 12.** YJIT compiles lazily, so early iterations include JIT compilation
  rather than steady-state execution. ruby-bench's own default is 15 for this reason.
* **Training 1+2 → 3+5.** Under YJIT a large share of cycles lands in anonymous JIT-generated code
  with no symbols, which `create_gcov` and `perf2bolt` both discard. More iterations are needed for
  comparable coverage of the `ruby` binary's own text.

## 3.3 The 16 headline benchmarks

`hint` is the iteration-count hint each benchmark passes to `run_benchmark(n)`; the env vars above
override how many actually run.

| benchmark | hint | what it does / parameters |
|---|---|---|
| activerecord | 20 | repeatedly queries an SQLite table with highly-random names |
| chunky-png | 10 | pure-Ruby PNG encoding |
| erubi-rails | 10 | Rails template rendering of a stubbed Discourse view; `EXPECTED_TEXT_SIZE = 9369` |
| hexapdf | 10 | line-wraps The Odyssey; `WIDTH = 50`, `HEIGHT = 1000` |
| liquid-c | 200 | renders a Liquid theme via the C extension |
| liquid-compile | 200 | compiles a Liquid theme |
| liquid-il | 150 | runs LiquidIL-generated standalone Ruby |
| liquid-render | 150 | renders a Liquid theme (pure Ruby) |
| **lobsters** | 10 | **the focus benchmark** — wide route coverage of the Lobste.rs Rails app |
| mail | 100 | builds an email from text and serialises it |
| psych-load | 10 | loads a selection of real-world YAML files |
| railsbench | 10 | read-only SQLite-backed Rails app; `visit_count = 2000` |
| rubocop | 200 | RuboCop auto-correction on a sizable file |
| ruby-lsp | 200 | Ruby LSP indexing |
| sequel | 200 | Sequel queries against an SQLite table |
| shipit | 10 | HTML + JSON API routes of the shipit Rails app |

All 16 use `use_gemfile`; **railsbench is the only one with an `extra_setup_cmd`**
(`db:migrate db:seed`), which is why it alone needed special handling during the interpreter-era
perf work.

## 3.4 `lobsters` — the customer's benchmark of record

```ruby
ENV['RAILS_ENV'] ||= 'production'
run_benchmark(10) do
  # ~114 HTTP requests per iteration across the Lobste.rs route set
  # (observed directly in harness errors: "req 19/114, /threads",
  #  "req 23/114, /upvoted/stories")
end
# the production log is unlinked afterwards so it does not fill the disk
```

| | |
|---|---|
| Rails env | `production` |
| Requests per iteration | **~114**, across routes incl. `/threads`, `/upvoted/stories`, `/` |
| Database | `db/production.sqlite3`, **40.1 MB** |
| Driving | in-process Rack (`app.call(env)`) — **no HTTP server, no sockets, no network** |
| Measured result | **afdoltob +13.77%**, 715.7 → 629.1 ms |

The in-process Rack design is why this campaign needed **no load-generator client** at all, and why
the perf captures are pure CPU/memory work rather than a mix with the network stack.

**Known limitation found during this work:** lobsters **does not survive 128-way parallel
execution**, even from private per-worker copies. ~80 of 128 workers die with HTTP 500 from
`User#unread_replies_count`, caused by `Errno::ENOENT` in `ActiveSupport::Cache::FileStore`
renaming into `tmp/cache/<nn>/<nnn>/`. It affects **both arms** (base 88 failures, afdoltob 76), so
it is *not* a miscompilation. The single-process pinned configuration the campaign uses is
unaffected. This is likely of direct interest to anyone working on ruby-bench.

## 3.5 `railsbench` — the perf characterisation vehicle

Used for the perf captures because it is stable at 128/128 workers with zero attrition.

```ruby
ENV['RAILS_ENV'] ||= 'production'
possible_routes = ['/posts', '/posts.json'] + (1..100).map { |i| "/posts/#{i}" }   # 102 routes
visit_count     = 2000
rng             = Random.new(0x1be52551fc152997)      # FIXED seed
visiting_routes = Array.new(visit_count) { possible_routes.sample(random: rng) }
```

**2000 requests per iteration** over 102 routes with a fixed RNG seed, so the request sequence is
byte-identical between arms and between runs — a large part of why measured variance is 0.1–0.9%.
Database is a 60 KB SQLite with 100 posts, fully page-cached. ~104 MiB RSS per worker (128 workers
≈ 13 GiB of 503 GiB).

## 3.6 Gem stack — shared across all nine arms

**369 gems, 423 MB**, ABI `4.0.0`, built once by the `base` arm.

Core versions (several majors coexist because benchmarks pin different ones, resolved per
benchmark directory by bundler):

`rails-8.1.2` · `activesupport-8.1.2` (8.0.2, 8.0.3, 8.1.1 also present) · `railties-8.1.2` ·
`rack-3.2.2` (2.2.19, 2.2.22, 3.1.17, 3.2.0) · `sqlite3-2.7.3` (1.7.3) · `prism-1.9.0` (1.4.0,
1.7.0, 1.8.1) · `psych-5.3.1` (4.0.6, 5.2.6) · `liquid-c-4.2.0` · `sequel-5.94.0` ·
`mail-2.9.0` (2.7.1, 2.8.1) · `hexapdf-0.16.0` · `chunky_png-1.4.0` · `erubi-1.13.1` ·
`rubocop-1.79.1` (0.81.0) · `ruby-lsp-0.17.17`

**Why sharing is a correctness requirement, not a shortcut:** ruby-bench compiles native extensions
*with the ruby under test*. Without sharing, the PGO arms would build extensions with
`-fprofile-generate` — writing stray `.gcda` and polluting the very profile being collected — and
the LTO arms with `-flto`. Each arm would then run *different extension code*, and the measured
difference would no longer be attributable to the ruby binary.

**Consequence for quoting: the measured gain is FDO of the Ruby core only.** Gem native code is
identical across arms and unoptimised, so whole-stack FDO should yield more, not less.

---

# Part 4 — Benchmark summary

## 4.1 Headline (mirrored: geomean of forward and reverse arm-ordering passes)

| arm | fwd | rev | **MIRRORED** | spread | **lobsters** | lobsters ms |
|---|---|---|---|---|---|---|
| base | +0.00% | +0.00% | — | 0.00% | — | 715.7 |
| pgo | +8.42% | +8.44% | **+8.43%** | 0.02% | +6.55% | 671.7 |
| pgolto | +13.21% | +13.74% | **+13.47%** | 0.53% | +3.92% | 688.7 |
| pgoltob | +18.03% | +17.18% | **+17.60%** | 0.85% | +9.00% | 656.6 |
| pgob | +11.51% | +12.28% | **+11.90%** | 0.77% | +9.71% | 652.3 |
| afdo | +9.98% | +9.80% | **+9.89%** | 0.18% | +5.97% | 675.4 |
| afdolto | +14.50% | +14.50% | **+14.50%** | 0.00% | +7.83% | 663.7 |
| **afdoltob** | +20.16% | +20.68% | **+20.42%** | 0.52% | **+13.77%** | **629.1** |
| afdob | +16.59% | +16.98% | **+16.78%** | 0.39% | +12.35% | 637.0 |

Spreads 0.00–0.85%. Every arm positive on every benchmark.

**On lobsters the arm ordering differs from the geomean:** LTO *hurts* the PGO path (`pgolto`
+3.92% is worse than plain `pgo` +6.55%; `pgob` +9.71% beats `pgoltob` +9.00%) while helping the
AutoFDO path. `afdoltob` wins under both, which is the simplest reason to pick it.

## 4.2 Per-benchmark mirrored speedup vs base (%)

| bench | pgo | pgolto | pgoltob | pgob | afdo | afdolto | afdoltob | afdob |
|---|---|---|---|---|---|---|---|---|
| activerecord | +8.7 | +13.1 | +14.3 | +11.6 | +8.4 | +11.7 | +19.5 | +15.9 |
| chunky-png | +4.7 | +15.1 | +15.6 | +10.0 | +16.7 | **+34.1** | +32.2 | +16.6 |
| erubi-rails | +6.4 | +17.5 | +23.8 | +12.7 | +12.2 | +17.7 | +28.1 | +25.9 |
| hexapdf | +7.6 | +11.7 | +14.7 | +9.6 | +6.6 | +13.6 | +15.1 | +13.1 |
| liquid-c | +8.6 | +19.5 | +22.3 | +17.1 | +11.8 | +11.7 | +20.8 | +18.8 |
| liquid-compile | +16.9 | +16.9 | +20.1 | +15.4 | +7.1 | +16.9 | +20.9 | +14.0 |
| liquid-il | +8.5 | +11.5 | +13.0 | +11.1 | +8.5 | +12.1 | +16.0 | +12.7 |
| liquid-render | +12.5 | +15.8 | +19.5 | +15.6 | +12.3 | +16.6 | +21.5 | +18.8 |
| **lobsters** | +6.6 | +3.9 | +9.0 | +9.7 | +6.0 | +7.8 | **+13.8** | +12.3 |
| mail | +6.3 | +15.3 | +20.3 | +10.9 | +12.9 | +15.2 | +20.7 | +16.6 |
| psych-load | +4.5 | +10.5 | +13.0 | +3.6 | +3.5 | +6.6 | +8.5 | +12.3 |
| railsbench | +7.0 | +8.6 | +16.6 | +12.0 | +5.6 | +7.7 | +18.5 | +14.7 |
| rubocop | +9.5 | +14.4 | +17.6 | +13.2 | +9.3 | +14.7 | +20.9 | +17.4 |
| ruby-lsp | +11.7 | +15.5 | +18.3 | +11.0 | +15.7 | +17.5 | +20.8 | +18.4 |
| sequel | +9.6 | +19.0 | +31.7 | +16.2 | +15.3 | +20.5 | **+34.6** | +26.2 |
| shipit | +6.5 | +8.5 | +13.8 | +11.3 | +7.7 | +10.3 | +17.3 | +15.8 |
| **GEOMEAN** | **+8.4** | **+13.5** | **+17.6** | **+11.9** | **+9.9** | **+14.5** | **+20.4** | **+16.8** |

Tight loops gain most (`sequel` +34.6%, `chunky-png` +32.2%). Full Rails stacks gain least
(`lobsters` +13.8%, `shipit` +17.3%, `railsbench` +18.5%) — their code footprint is diffuse, so no
profile concentrates on them as well.

## 4.3 Absolute mean times, ms (mean of both passes)

| bench | base | pgo | pgolto | pgoltob | pgob | afdo | afdolto | afdoltob | afdob |
|---|---|---|---|---|---|---|---|---|---|
| activerecord | 125.7 | 115.7 | 111.2 | 110.0 | 112.6 | 116.0 | 112.5 | 105.2 | 108.5 |
| chunky-png | 436.4 | 416.6 | 379.0 | 377.6 | 396.6 | 374.1 | 325.5 | 330.0 | 374.3 |
| erubi-rails | 765.5 | 719.2 | 651.3 | 618.5 | 679.3 | 682.3 | 650.6 | 597.5 | 608.1 |
| hexapdf | 1437.3 | 1336.1 | 1286.4 | 1253.3 | 1311.6 | 1348.4 | 1265.2 | 1249.6 | 1270.7 |
| liquid-c | 48.5 | 44.6 | 40.6 | 39.6 | 41.4 | 43.4 | 43.4 | 40.1 | 40.8 |
| liquid-compile | 42.9 | 36.7 | 36.7 | 35.7 | 37.2 | 40.0 | 36.7 | 35.5 | 37.6 |
| liquid-il | 181.2 | 167.0 | 162.5 | 160.4 | 163.1 | 167.0 | 161.7 | 156.2 | 160.7 |
| liquid-render | 68.1 | 60.5 | 58.8 | 57.0 | 58.9 | 60.7 | 58.4 | 56.0 | 57.3 |
| **lobsters** | **715.7** | 671.7 | 688.7 | 656.6 | 652.3 | 675.4 | 663.7 | **629.1** | 637.0 |
| mail | 95.3 | 89.6 | 82.6 | 79.2 | 85.9 | 84.4 | 82.7 | 78.9 | 81.7 |
| psych-load | 1401.0 | 1340.8 | 1268.4 | 1239.7 | 1352.3 | 1353.6 | 1314.1 | 1290.8 | 1248.0 |
| railsbench | 1322.6 | 1235.9 | 1218.0 | 1134.1 | 1180.7 | 1252.6 | 1228.1 | 1115.8 | 1153.3 |
| rubocop | 119.0 | 108.7 | 104.0 | 101.2 | 105.2 | 108.9 | 103.8 | 98.4 | 101.4 |
| ruby-lsp | 115.8 | 103.7 | 100.3 | 97.9 | 104.3 | 100.1 | 98.6 | 95.9 | 97.8 |
| sequel | 54.4 | 49.6 | 45.7 | 41.3 | 46.8 | 47.2 | 45.2 | 40.4 | 43.1 |
| shipit | 995.1 | 934.7 | 917.4 | 874.8 | 893.8 | 924.4 | 902.2 | 848.5 | 859.2 |

## 4.4 Binaries

| arm | build | md5 |
|---|---|---|
| base | 1m00s | `c6f32808afea0726d9d04db50b50ff40` |
| pgo | 5m16s | `9450df2f21eeabd05f0baf39f3e2004c` |
| pgolto | 8m22s | `a9c80cfb29d6462e32b8e5ac200c3ff1` |
| pgoltob | 11m09s | `d336ff339b5d7179abc386323668718f` |
| pgob | 7m58s | `c327187d087ed0a04af76dff6bb523d5` |
| afdo | 5m22s | `06ff4ac8d34a3f9581ffbc4ab6e7538d` |
| afdolto | 8m42s | `236628ff8bc18d064d080d849083d0cc` |
| **afdoltob** | 11m17s | **`cf4c273637b731c480862d36d7eb1c0f`** ← shipped in `binaries/` |
| afdob | 7m58s | `54d53a39a33c3230439a73ab882c42c0` |

All nine distinct. Training was verified to run under YJIT by the harness banner reading
`train: ruby 4.0.6 … +YJIT +PRISM`.

## 4.5 Mechanism, in one table

| | 3.4.11 interpreter | 4.0.6 + YJIT |
|---|---|---|
| afdoltob geomean | +13.04% | **+20.42%** |
| I-cache stalls (% cycles) | 11.71% → 6.40% (**−45%**) | 14.53% → 15.23% (unmoved) |
| front-end bound | 38.83% → 32.52% (**−6.31 pp**) | 51.51% → 52.17% (unmoved) |
| instructions retired | −1.83% | **−8.85%** |
| `vm_exec_core` share of cycles | **31.9%** | **0.84%** |

In interpreter mode FDO wins by fixing the layout of the bytecode dispatch loop. Under YJIT that
loop is gone — replaced by JIT code gcc never sees — so FDO instead wins by retiring ~9% fewer
C-side instructions.

**The +13.04% → +20.42% difference is not attributable to YJIT alone:** four variables moved
together (Ruby version, YJIT, training iterations, ruby-bench revision). The clean attribution
experiment — the same 4.0.6 binaries measured *without* `--yjit` — has not been run.
