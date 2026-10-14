# Ruby 3.4.11 FDO campaign — full report

**PGO / AutoFDO / LTO / BOLT on gcc 15.2.0**, nine arms, mirrored, with hardware-counter analysis
of the mechanism.

Campaign `campaign-20261013-083459` · perf captures 2026-10-13 · m6i.metal (Ice Lake)

This is the consolidated report. The focused extracts are [RESULTS.md](RESULTS.md) (result only),
[PERF.md](PERF.md) (perf only) and [BUILD-STEPS.md](BUILD-STEPS.md) (recipe only).

---

# Part 0 — Headline

| arm | fwd | rev | **MIRRORED** | spread |
|---|---|---|---|---|
| base | +0.00% | +0.00% | — | 0.00% |
| pgo | +5.94% | +5.85% | **+5.89%** | 0.10% |
| pgolto | +8.41% | +8.44% | **+8.43%** | 0.03% |
| pgoltob | +11.36% | +11.35% | **+11.35%** | 0.01% |
| pgob | +6.70% | +6.64% | **+6.67%** | 0.06% |
| afdo | +6.96% | +6.87% | **+6.91%** | 0.09% |
| afdolto | +9.16% | +9.19% | **+9.17%** | 0.03% |
| **afdoltob** | +13.27% | +12.80% | **+13.04%** | 0.47% |
| afdob | +10.97% | +11.05% | **+11.01%** | 0.08% |

**Recommendation: `afdoltob` (AutoFDO + LTO + BOLT), +13.04%.** `pgoltob` at +11.35% is the
PGO-based alternative where `perf` sampling infrastructure is unavailable.

**And the mechanism is established, not assumed:** instruction-cache tag stalls fall **45%**
(11.71% → 6.40% of cycles) and front-end bound falls **6.31 pp** (38.83% → 32.52%) against a
worst-case pass spread of 1.12 pp. It is a code-layout win on a 35%-of-cycles interpreter dispatch
loop. It is *not* a cache-coherence or NUMA effect — `perf c2c` is a clean null in both arms.

---

# Part 1 — System information

## 1.1 Machine

| | |
|---|---|
| Instance | **m6i.metal**, AWS us-east-1a, `instance-life-cycle: on-demand`, private <DUT_PRIVATE_IP> |
| CPU | **Intel Xeon Platinum 8375C @ 2.90 GHz** — family 6, model **106** (Ice Lake-SP), stepping 6 |
| Topology | 2 sockets × 32 cores × 2 threads = **128 vCPU**; SMT **active** |
| Frequency | base 2.90 GHz, max 3.50 GHz, min 0.80 GHz; BogoMIPS 5800 |
| NUMA | **2 nodes** — node0 `0-31,64-95` (257,747 MB), node1 `32-63,96-127` (258,018 MB) |
| Memory | 503 GiB total |
| Disk | 600 GB gp3 EBS (`nvme0n1`), `/` = 581 G, non-rotational, scheduler `none` |

## 1.2 Cache hierarchy — directly relevant to the result

| level | total | instances | per core |
|---|---|---|---|
| L1d | 3 MiB | 64 | 48 KB |
| **L1i** | **2 MiB** | **64** | **32 KB** |
| L2 | 80 MiB | 64 | 1.25 MB |
| L3 | 108 MiB | 2 | 54 MiB per socket |

**32 KB of L1i per core, shared between two SMT siblings.** That is the budget the whole Ruby
interpreter has to fit its hot path into, and it is why §5.2's I-cache numbers move so much — and
why the loaded 128-worker figure (+7.0%) is lower than single-core (+10.6%): under SMT two workers
contend for the same 32 KB.

## 1.3 Software

| | |
|---|---|
| OS | Ubuntu 26.04 LTS |
| Kernel **at measurement** | **7.0.0-1006-aws** (recorded in every campaign MANIFEST and perf timeline) |
| Kernel **now** | 7.0.0-1014-aws — a reboot pulled a kernel upgrade *after* the captures |
| Compiler | **gcc 15.2.0** (`gcc-15` 15.2.0-16ubuntu1 — distro default, no source bootstrap) |
| Post-link | llvm-bolt / perf2bolt **21.1.8** (`apt install llvm-bolt`) |
| AutoFDO | `create_gcov`, autofdo HEAD, built from source (protobuf 3.21.12, cmake 4.2) |
| perf | 7.0.0; LBR (`-b`) and branch stacks (`-j any,u`) both available; PEBS present |
| Ruby | 3.4.11 (2026-09-23 revision 592f1ffdb3) +PRISM |
| Baseline flags | `-O3 -march=native -mtune=native -fno-omit-frame-pointer -g` |
| Workload | yjit-bench `--category=headline`, 16 benchmarks |

**The kernel moved between measurement and now.** All results and perf captures were taken on
**7.0.0-1006-aws**; the live box is on 1014. Nothing in the report is invalidated — the artefacts
record 1006 — but a re-run today would not be on an identical system.

PMUs available: `cpu`, `cstate_core`, `cstate_pkg`, `intel_bts`, `intel_pt`, `msr`, `power`,
`breakpoint`, `kprobe`, `software`. Relevant CPU flags: `pebs bts arch_perfmon intel_pt cat_l3
rdt_a cqm_llc cqm_occup_llc cqm_mbm_total cqm_mbm_local hwp hwp_epp split_lock_detect`.

## 1.4 Tunables — state during the captures vs stock

`ruby-perf.sh` re-asserts all of these on every run, because **none of them survive a reboot**
(verified: after the 7th reboot the box came back at `no_turbo=0`, `min_perf_pct=22`,
`nmi_watchdog=1`, while `perf_event_paranoid` stayed 0 via `/etc/sysctl.d/99-perf.conf`).

| knob | stock | during captures | why |
|---|---|---|---|
| `intel_pstate/no_turbo` | 0 | **1** | fixes frequency; an IPC comparison is meaningless otherwise |
| `intel_pstate/min_perf_pct` | 22 | **100** | pins to base clock |
| `scaling_governor` | performance | performance | — |
| `kernel.nmi_watchdog` | 1 | **0** | removes a per-core perf consumer |
| `kernel.perf_event_paranoid` | **4** | **0** | stock 4 blocks *all* user sampling — AutoFDO and BOLT both fail without this |
| `kernel.randomize_va_space` | 2 | 2 | harness disables ASLR per-process via `setarch -R` instead |
| THP | `madvise` | `madvise` | left at distro default |
| `vm.nr_hugepages` | 0 | 0 | no explicit huge pages |
| `vm.swappiness` | 60 | 60 | irrelevant, 500 GiB free |

Verification that the pinning worked: `cycles / ref-cycles = 1.0000` in all four `perf stat`
windows, i.e. both arms ran at exactly the 2.90 GHz base clock.

## 1.5 Mitigations (identical for both arms, so they cancel in the comparison)

```
indirect_target_selection : Mitigation: Aligned branch/return thunks
mmio_stale_data           : Mitigation: Clear CPU buffers; SMT vulnerable
spec_store_bypass         : Mitigation: Speculative Store Bypass disabled via prctl
spectre_v1                : Mitigation: usercopy/swapgs barriers, __user pointer sanitization
gather_data_sampling      : Vulnerable
itlb_multihit / l1tf / mds / meltdown / retbleed : Not affected
```

Worth noting that **Indirect Target Selection mitigation is active via aligned branch/return
thunks** — a code-layout-affecting mitigation. It applies equally to both arms so it does not bias
the comparison, but it is part of the baseline any absolute number is measured against.

## 1.6 Scope note

This is **not** the r8i 48xl Granite Rapids box the work was originally scoped against. Quote as
Ice Lake m6i.metal; do not splice into the GNR-based PG/MySQL/MariaDB tables. Ice Lake's weaker
front end plausibly flatters layout optimisation relative to GNR.

---

# Part 2 — Build recipe, step by step

## 2.1 Flag building blocks

```bash
BASE_CFLAGS="-O3 -march=native -mtune=native -fno-omit-frame-pointer -g"
LTO_FLAGS="-flto=32 -ffat-lto-objects"
BOLT_LDFLAGS="-Wl,--emit-relocs -Wl,-q"
```

| piece | why it is non-negotiable |
|---|---|
| `-O3 -march=native -mtune=native` | the common baseline every prior campaign quoted against; a weaker baseline inflates the gain |
| `-fno-omit-frame-pointer` | AutoFDO, BOLT and `--call-graph fp` all need walkable stacks. Omitting it degrades profiles **silently** |
| `-g` | DWARF for `perf annotate` and AutoFDO's line/discriminator mapping |
| `-ffat-lto-objects` | emits IR *and* machine code per object, so the tree stays usable by non-LTO-aware tools |
| `-Wl,--emit-relocs -Wl,-q` | **llvm-bolt refuses the binary outright without relocations.** Only on the four `*b` arms |

## 2.2 The nine arms — exact resulting flags

| arm | mode | lto | bolt | CFLAGS | LDFLAGS |
|---|---|---|---|---|---|
| `base` | plain | – | – | `$BASE` | — |
| `pgo` | pgo | – | – | `$BASE` + PU | — |
| `pgolto` | pgo | ✓ | – | `$BASE $LTO` + PU | `$LTO` |
| `pgoltob` | pgo | ✓ | ✓ | `$BASE $LTO` + PU | `$LTO $BOLT_LD` |
| `pgob` | pgo | – | ✓ | `$BASE` + PU | `$BOLT_LD` |
| `afdo` | afdo | – | – | `$BASE -fauto-profile=… -Wno-missing-profile` | — |
| `afdolto` | afdo | ✓ | – | `$BASE $LTO -fauto-profile=… -Wno-missing-profile` | `$LTO` |
| `afdoltob` | afdo | ✓ | ✓ | `$BASE $LTO -fauto-profile=… -Wno-missing-profile` | `$LTO $BOLT_LD` |
| `afdob` | afdo | – | ✓ | `$BASE -fauto-profile=… -Wno-missing-profile` | `$BOLT_LD` |

**PU** (profile-use set) = `-fprofile-use -fprofile-dir=$PROF -fprofile-correction
-Wno-missing-profile -Wno-error=coverage-mismatch -Wno-coverage-mismatch`

The two no-LTO BOLT arms (`pgob`, `afdob`) are the reason this campaign can answer a question the
MariaDB one could not — see §4.2.

## 2.3 Configure (identical for every pass of every arm)

```bash
"$SRC/configure" \
    --prefix="$PFX" --disable-install-doc --enable-shared=no \
    CC=gcc-15 CXX=g++-15 \
    CFLAGS="$cflags $extra_cflags" LDFLAGS="$ldflags $extra_ldflags" \
    optflags="" debugflags=""
make -j128 && rm -rf "$PFX" && make install
```

* **`optflags="" debugflags=""`** — critical. Ruby's configure otherwise appends its *own* `-O3`
  and `-g` **after** ours, overriding the arm's optimisation flags.
* **`--enable-shared=no`** — static libruby inside the executable. Required for the BOLT arms to
  mean anything: with a shared build the hot interpreter lives in `libruby.so`, and BOLT applied to
  the thin `ruby` driver would optimise nothing.
* `--prefix` under the campaign root, never `/opt` — no sudo in the build path.

## 2.4 `base` — one pass

```bash
configure_and_make "" ""          # 1m00s at -j128
```

## 2.5 PGO arms — two passes with a wipe between

```bash
configure_and_make "-fprofile-generate -fprofile-dir=$PROF" "-fprofile-generate"
prime                             # gems + Rails migrations, UNPROFILED
rm -f "$PROF"/*.gcda              # <-- the wipe
train
configure_and_make \
  "-fprofile-use -fprofile-dir=$PROF -fprofile-correction \
   -Wno-missing-profile -Wno-error=coverage-mismatch -Wno-coverage-mismatch" ""
```

The wipe is mandatory: Ruby runs its own freshly built `miniruby` *during its own build*, and
`prime` then runs bundler, rubygems and Rails migrations. Without it the profile is dominated by
Ruby compiling its stdlib and resolving gems rather than by the workload.

| pass-2 flag | reason |
|---|---|
| `-fprofile-use` | consume the `.gcda` counters |
| `-fprofile-dir=$PROF` | counters kept outside the build tree, which pass 2 wipes |
| `-fprofile-correction` | training is multi-process; gcc otherwise **errors** on inconsistent counters |
| `-Wno-missing-profile` | **required** — see §6.1 |
| `-Wno-error=coverage-mismatch -Wno-coverage-mismatch` | LTO changes unit layout between passes |

## 2.6 AutoFDO arms — sample an unmodified binary

```bash
configure_and_make "" ""          # plain build: AutoFDO samples a WORKING binary
prime
perf record -o "$PROF/perf.data" -e cycles:u -b -- bash -c "$TRAIN_CMD"
create_gcov --binary "$PFX/bin/ruby" --profile "$PROF/perf.data" \
            --gcov "$PROF/ruby.gcov" -gcov_version=2
configure_and_make "-fauto-profile=$PROF/ruby.gcov -Wno-missing-profile" ""
```

Observed: 243 MB `perf.data` → 2.95 MB `ruby.gcov`. `-b` (LBR) supplies the branch records
`create_gcov` needs for edge counts.

`create_gcov` build (needed once, not packaged):

```bash
git clone --recursive https://github.com/google/autofdo.git
cmake -G Ninja -DCMAKE_BUILD_TYPE=Release -DENABLE_TOOL=GCOV \
      -DCMAKE_POLICY_VERSION_MINIMUM=3.5 ..
ninja && sudo install -m755 create_gcov dump_gcov profile_merger /usr/local/bin/
```

`-DCMAKE_POLICY_VERSION_MINIMUM=3.5` is required on Ubuntu 26.04: cmake 4.2 dropped pre-3.5 policy
support and autofdo's vendored `third_party/glog` still declares one. Also needs
`protobuf-compiler libprotobuf-dev libgflags-dev libgoogle-glog-dev libunwind-dev`.

`-gcov_version=2` must match the consuming gcc — a mismatch surfaces as a bland *"profile not
found"* from gcc, not a version error.

## 2.7 BOLT — applied last, after the final link

Only for `pgoltob`, `pgob`, `afdoltob`, `afdob`, and only after that arm's final `make install`.

```bash
cp "$PFX/bin/ruby" "$PFX/bin/ruby.prebolt"       # keep pre-BOLT binary for A/B
prime
perf record -o "$PROF/bolt.data" -e cycles:u -j any,u -- bash -c "$TRAIN_CMD"
perf2bolt -p "$PROF/bolt.data" -o "$PROF/bolt.fdata" "$PFX/bin/ruby.prebolt"
llvm-bolt "$PFX/bin/ruby.prebolt" -o "$PFX/bin/ruby" -data="$PROF/bolt.fdata" \
    -reorder-blocks=ext-tsp \
    -reorder-functions=hfsort+ \
    -split-functions \
    -split-all-cold \
    -split-eh \
    -dyno-stats \
    -icf=1 \
    -use-gnu-stack
```

| option | what it does | why here |
|---|---|---|
| `-data=` | the `perf2bolt`-converted profile | required input |
| `-reorder-blocks=ext-tsp` | basic-block layout by extended TSP | **the main win** — straightens hot paths through `vm_exec_core`, 35% of all cycles |
| `-reorder-functions=hfsort+` | groups hot functions by call affinity | packs the hot interpreter + dispatch set into fewer I-cache/iTLB pages → the −10% iTLB walks |
| `-split-functions` | hot/cold fragment per function | lets cold paths leave the hot text region |
| `-split-all-cold` | splits profile-less functions as cold too | unsampled code is cold by definition |
| `-split-eh` | exception paths to cold | Ruby's C is EH-heavy, EH almost never taken |
| `-icf=1` | identical code folding | dedupes identical bodies, shrinks hot text |
| `-use-gnu-stack` | GNU-style stack segment | keeps the rewritten binary loadable |
| `-dyno-stats` | before/after dynamic instruction stats | BOLT's claim readable from the build log |

Verified in the artefacts: the `*b` arms show a **split hot/cold `.text`** with
`__hot_start`/`__hot_end` set, and shrink to ~11.8 MB from ~43 MB because llvm-bolt discards debug
sections. Harmless for measurement, but it means **no source-line annotation for BOLT arms**.

## 2.8 Build order and cost

```bash
./ruby-build.sh base && ./ruby-sharegems.sh base
./ruby-all.sh pgo pgolto pgoltob pgob afdo afdolto afdoltob afdob
```

Strictly serial — an arm compiling at `-j128` beside an arm being `perf`-sampled would contaminate
the profile. `ruby-all.sh` skips arms whose FINGERPRINT md5 matches the installed binary, so a
reboot costs one arm, not the run.

| arm | build | md5 | .text |
|---|---|---|---|
| base | 1m00s | `6c2553ec54001f8728ee5dda48c1870a` | — |
| pgo | 4m57s | `48c9f74184aefe151bebd30d17139f3d` | 4,082,246 |
| pgolto | 8m16s | `5a06fe0537047eafb867323788611ce2` | 4,104,422 |
| pgoltob | 10m24s | `142d6389db35ff8518f28727a2d659e1` | 1,123,023 + 634,635 (split) |
| pgob | 6m45s | `4eddff00bc5db9109929ce4767247648` | 1,031,207 + 576,268 (split) |
| afdo | 4m29s | `cbe95001de7d25a926ebb45fae2154f2` | 5,308,150 |
| afdolto | 7m50s | `49ecf0eff88edc71c5d2dcd15352084f` | 5,127,062 |
| afdoltob | 9m58s | `d656566bec6b20f4baa4880e4beb0d83` | 1,092,331 + 784,912 (split) |
| afdob | 6m29s | `139b892d2a18fd61b19d1eb11f6ab934` | 1,088,535 + 845,215 (split) |

All nine md5s distinct. AutoFDO's `.text` (~5.2 MB) vs PGO's (~4.1 MB) is direct evidence the
profiles were *applied*, not silently ignored — AutoFDO inlines far more aggressively.

Flags as actually recorded in each arm's `FINGERPRINT`:

| arm | cflags | ldflags |
|---|---|---|
| base | `$BASE` | *(empty)* |
| pgo | `$BASE` | *(empty)* |
| pgolto | `$BASE -flto=32 -ffat-lto-objects` | `-flto=32 -ffat-lto-objects` |
| pgoltob | `$BASE -flto=32 -ffat-lto-objects` | `-flto=32 -ffat-lto-objects -Wl,--emit-relocs -Wl,-q` |
| pgob | `$BASE` | `-Wl,--emit-relocs -Wl,-q` |
| afdo | `$BASE` | *(empty)* |
| afdolto | `$BASE -flto=32 -ffat-lto-objects` | `-flto=32 -ffat-lto-objects` |
| afdoltob | `$BASE -flto=32 -ffat-lto-objects` | `-flto=32 -ffat-lto-objects -Wl,--emit-relocs -Wl,-q` |
| afdob | `$BASE` | `-Wl,--emit-relocs -Wl,-q` |

> **Known gap in the fingerprint, found while assembling this report.** `FINGERPRINT` records the
> *arm-level* flags (`$cflags`/`$ldflags`) but **not** the per-pass additions, so `base` and `pgo`
> show identical flag strings despite different md5s — the `-fprofile-use …` set that actually
> distinguishes them is missing. Same for `-fauto-profile=` on the afdo arms. The real flags are in
> `log/build-<arm>.log` and in each arm's `RbConfig::CONFIG['configure_args']`, and §2.2 above is
> authoritative. `ruby-build.sh` has since been changed to record the final pass's full CFLAGS so
> future fingerprints are self-sufficient; the nine binaries here predate that fix.

---

# Part 3 — Ruby configuration and benchmark process

## 3.0 Ruby build and runtime configuration

As recorded by `RbConfig` in the built `base` interpreter:

```
configure_args = '--prefix=…/inst/ruby-base' '--disable-install-doc' '--enable-shared=no'
                 'CC=gcc-15' 'CXX=g++-15'
                 'CFLAGS=-O3 -march=native -mtune=native -fno-omit-frame-pointer -g '
                 'LDFLAGS= ' 'optflags=' 'debugflags='
CC        = gcc-15
CFLAGS    = -O3 -march=native -mtune=native -fno-omit-frame-pointer -g
optflags  = -fno-fast-math          # configure's own addition; note it did NOT re-add -O3
debugflags= (empty)
LDFLAGS   = -L. -fstack-protector-strong -rdynamic -Wl,-export-dynamic
DLDFLAGS  = -Wl,--compress-debug-sections=zlib
MAINLIBS  = -lz -lrt -lrt -lgmp -ldl -lcrypt -lm -lpthread
ENABLE_SHARED = no
arch      = x86_64-linux
```

The `optflags=` override worked as intended: configure re-added only `-fno-fast-math`, **not**
its default `-O3`, so the arm's own optimisation level stands.

Runtime configuration, all at defaults:

| | |
|---|---|
| **YJIT** | **compiled in but DISABLED** (`RubyVM::YJIT.enabled? == false`) |
| ZJIT | not used |
| **malloc** | **system glibc** — `jemalloc = false`. This is why `malloc`/`malloc_usable_size` appear in the §5.3 profiles |
| GC | default implementation, `rgengc_allow_full_mark: true` |
| `GC.auto_compact` | **off** — the harness enables it only if `RUBY_GC_AUTO_COMPACT` is set, and it was not |
| `RUBY_GC_*` heap tuning | none set; stock heap growth |
| PRISM | yes (`+PRISM` in the version banner) |

That YJIT is *available but off* is what makes caveat §7.3 precise: the binary contains YJIT's
Rust-compiled code, it simply never executes. gcc-side FDO cannot move JIT-generated code.

Environment variables the harness itself honours (`harness/harness-common.rb`):
`RUBY_GC_AUTO_COMPACT`, `RUBY_BENCH_PIN_CPU`, `RESULT_JSON_PATH`, `RSS_CSV_PATH`,
`YJIT_BENCH_STATS`, `ZJIT_BENCH_STATS`.

Determinism aids built into the harness: `Random.srand(1337)` globally before every benchmark, and
ASLR disabled per-process via `setarch -R`.

## 3.1 The harness

yjit-bench `--category=headline` = 16 server-shaped benchmarks: `activerecord chunky-png
erubi-rails hexapdf liquid-c liquid-compile liquid-il liquid-render lobsters mail psych-load
railsbench rubocop ruby-lsp sequel shipit`.

Iteration control (`harness/harness.rb:4-10`) loops **until
`num_itrs >= WARMUP_ITRS + MIN_BENCH_ITRS` AND `total_time >= MIN_BENCH_TIME`**.

Per-run invocation, from the harness's own logs:

```bash
bundle check 2> /dev/null || bundle install              # per benchmark, per ruby
setarch x86_64 -R taskset -c 41 <ruby> -I harness benchmarks/<b>/benchmark.rb
```

`setarch -R` disables ASLR (stable symbolisation, less variance); `taskset -c N` pins to one CPU,
so **the campaign measured single-core performance**; the harness also sets `no_turbo=1` and
`min_perf_pct=100`.

## 3.2 Three roles for the same workload

| role | iterations | purpose |
|---|---|---|
| **prime** | `WARMUP_ITRS=0 MIN_BENCH_ITRS=1` | install gems, run Rails migrations — **unprofiled** |
| **train** | `WARMUP_ITRS=1 MIN_BENCH_ITRS=2` | the profiled run; coverage matters, precision does not |
| **measure** | `--warmup=5 --bench=8` | the result |

`prime` exists for correctness. The harness installs each benchmark's gems *and* runs
`db:migrate db:seed` on first use; profiling that would train the arm on bundler, rubygems and
ActiveRecord migrations instead of the benchmark. Train and both sampling runs each `prime` first.

```bash
# TRAIN_CMD — target of PGO training and of AutoFDO/BOLT sampling alike
cd $YJIT_BENCH && ./run_benchmarks.rb --category=headline \
    --warmup=1 --bench=2 -e train::$RUBY_BIN --out-name=train-$ARM
```

## 3.3 Shared gems — a correctness requirement, not an optimisation

All nine arms share one gem set built by `base` (444 MB), via a symlink of
`<prefix>/lib/ruby/gems` re-established after **every** `make install`.

yjit-bench compiles native extensions **with the ruby under test**. So the PGO arms would build
extensions with `-fprofile-generate` — writing stray `.gcda` and polluting the very profile being
collected — and the LTO arms with `-flto`. Each arm would then run *different extension code*, and
the measured difference would no longer be attributable to the ruby binary.

**Consequence for quoting: the gain is FDO of the Ruby core only.** Gem native code is identical
across arms and unoptimised, so whole-stack FDO should yield **more** than +13%, not less.

## 3.3a Workload parameters — the 16 headline benchmarks

`hint` is the iteration-count hint each benchmark passes to `run_benchmark(n)`; the harness's
`WARMUP_ITRS`/`MIN_BENCH_ITRS`/`MIN_BENCH_TIME` override how many actually run.

| benchmark | hint | what it does / key parameters |
|---|---|---|
| activerecord | 20 | repeatedly queries an SQLite table with highly-random names |
| chunky-png | 10 | pure-Ruby PNG encoding |
| erubi-rails | 10 | Rails template rendering of a stubbed Discourse view; `EXPECTED_TEXT_SIZE = 9369` |
| hexapdf | 10 | line-wraps The Odyssey; `WIDTH = 50`, `HEIGHT = 1000` |
| liquid-c | 200 | renders a Liquid theme via the C extension |
| liquid-compile | 200 | compiles a Liquid theme |
| liquid-il | 150 | runs LiquidIL-generated standalone Ruby |
| liquid-render | 150 | renders a Liquid theme (pure Ruby) |
| lobsters | 10 | wide route coverage of the Lobste.rs Rails app |
| mail | 100 | builds an email from text and serialises it |
| psych-load | 10 | loads a selection of real-world YAML files |
| **railsbench** | **10** | read-only SQLite-backed Rails app; **`visit_count = 2000`** |
| rubocop | 200 | RuboCop auto-correction on a sizable file |
| ruby-lsp | 200 | Ruby LSP indexing |
| sequel | 200 | Sequel queries against an SQLite table |
| shipit | 10 | HTML + JSON API routes of the shipit Rails app |

### railsbench in detail (the workload used for all perf captures)

```ruby
ENV['RAILS_ENV'] ||= 'production'
possible_routes = ['/posts', '/posts.json'] + (1..100).map { |i| "/posts/#{i}" }   # 102 routes
visit_count     = 2000
rng             = Random.new(0x1be52551fc152997)          # FIXED seed
visiting_routes = Array.new(visit_count) { possible_routes.sample(random: rng) }

run_benchmark(10) do
  visiting_routes.each do |path|
    env = Rack::MockRequest::env_for("https://localhost#{path}")
    response_array = app.call(env)                        # in-process Rack call
    raise unless response_array.first == 200
    response_array.last.close
  end
end
```

Four properties that matter:

* **2000 requests per iteration** across 102 routes, drawn with a **fixed RNG seed** — the request
  sequence is byte-identical between arms and between runs. This is a large part of why the
  measured variance was 0.1–0.5%.
* **In-process Rack** (`Rack::MockRequest.env_for` + `app.call`) — **no HTTP server, no sockets, no
  network.** This is why the campaign needed no load-generator client at all, and why the perf
  captures are pure CPU/memory work rather than a mix with network stack.
* `RAILS_ENV=production` with a 60 KB `db/production.sqlite3` holding **100 posts** — the dataset
  is tiny and fully page-cached, so this measures interpreter and framework work, not I/O.
* Setup runs `db:migrate db:seed` on **every** launch and `seeds.rb` deletes/repopulates — the
  reason each of the 128 perf workers needed a private copy (§5.1).

### Gem stack (shared set: 384 gems, 444 MB)

`rails-8.1.2` · `activesupport-8.1.2` (8.0.3, 8.1.1 also present for other benchmarks) ·
`railties-8.1.2` · `rack-3.2.2` (2.2.19/2.2.22/3.1.17/3.2.0 for others) · `sqlite3-2.7.3` ·
`prism-1.9.0` · `psych-5.3.1` · `liquid-c-4.2.0` · `sequel-5.94.0` · `mail-2.9.0` ·
`hexapdf-0.16.0` · `chunky_png-1.4.0` · `erubi-1.13.1` · `rubocop-1.79.1` (0.81.0 pinned by one
benchmark) · `ruby-lsp-0.17.17`

Several benchmarks pin different major versions of the same gem; bundler resolves per benchmark
directory, which is why the shared set contains multiple versions side by side.

Measured footprint per railsbench worker: **~104 MiB RSS** (so 128 workers ≈ 13 GiB of the 503 GiB).
For contrast, `liquid-il` runs at ~38 MiB.

## 3.4 Measurement — mirrored and checkpointed

```bash
./run_benchmarks.rb --name_filters=<bench> --warmup=5 --bench=8 \
    --interleave --pvalue \
    -e base::…/ruby-base/bin/ruby -e pgo::…/ruby-pgo/bin/ruby … \
    --out-name=$CAMP-$dir-$bench
```

* `--interleave` — within a benchmark the arms run round-robin, so slow drift hits all equally.
* **forward then reverse arm order**, per-arm mean of the two: residual order effects enter with
  opposite sign and cancel. Achieved spread ≤0.47%.
* **one invocation per (direction, benchmark)** = 32 total. yjit-bench writes JSON only at the *end*
  of a run, so a single invocation over 16 benchmarks loses everything on a reboot — which happened
  once. Checkpoint interval is now ~2–3 min; completed benchmarks are skipped on resume.
* `--out-name` writes to the **yjit-bench repo root**, ignoring directories (that's `--out_path`).

---

# Part 4 — Results

## 4.1 Mirrored headline

See Part 0. Confidence is unusually high: the two orderings agree within 0.5% on every arm, no
benchmark regresses in any arm, and the worst baseline noise was 1.8% (`lobsters`) against effects
of 8–21%.

## 4.2 What each layer contributes

| step | PGO path | AutoFDO path |
|---|---|---|
| FDO alone | +5.89% | +6.91% |
| + LTO | +8.43% (**+2.5**) | +9.17% (**+2.3**) |
| + LTO + BOLT | +11.35% (**+2.9**) | +13.04% (**+3.9**) |
| FDO + BOLT, no LTO | +6.67% (**+0.8**) | +11.01% (**+4.1**) |

**(a) BOLT helps on Ruby — unlike on gcc-built databases.** On MariaDB and PG, BOLT over PGO+LTO
was neutral-to-negative. Here it is the largest single increment on both paths. Part 5 explains
why: Ruby has a 35%-of-cycles, branch-dense, I-cache-hostile dispatch loop; those engines do not.

**(b) BOLT's payoff depends on its substrate** — only **+0.8%** over PGO alone, but **+4.1%** over
AutoFDO alone. gcc's instrumented-PGO layout is already good, leaving BOLT little to add; AutoFDO's
sampled profile is coarser per basic block, so BOLT has real work left. Note `afdob` (+11.01%,
**no LTO**) nearly matches `pgoltob` (+11.35%) — AutoFDO + BOLT gets most of the way without LTO's
build cost. This is the question the no-LTO BOLT arms were built to answer.

**(c) AutoFDO beats PGO at every level** (+1.0, +0.7, +1.7 points), reversing the MySQL/MariaDB
ordering — and it trains from samples on an unmodified binary, so it is the cheaper option too.

## 4.3 Per-benchmark mirrored speedup vs base (%)

| bench | pgo | pgolto | pgoltob | pgob | afdo | afdolto | afdoltob | afdob |
|---|---|---|---|---|---|---|---|---|
| activerecord | +3.8 | +9.6 | +11.1 | +3.8 | +8.6 | +11.4 | +14.5 | +7.7 |
| chunky-png | +7.9 | +7.0 | +10.7 | +4.1 | +12.0 | +13.2 | +13.0 | +11.1 |
| erubi-rails | +6.8 | +9.9 | +13.3 | +8.8 | +6.4 | +9.6 | +16.1 | +13.6 |
| hexapdf | +2.2 | +4.7 | +8.1 | +4.1 | +5.2 | +9.4 | +11.6 | +8.0 |
| liquid-c | +10.9 | +12.6 | +15.7 | +11.6 | +8.4 | +10.3 | +14.6 | +13.6 |
| liquid-compile | +11.6 | +16.0 | +19.3 | +12.6 | +7.8 | +12.5 | +14.5 | +15.1 |
| liquid-il | +2.4 | +4.4 | +7.8 | +2.5 | +6.4 | +6.6 | +9.1 | +9.2 |
| liquid-render | +7.7 | +9.9 | +13.1 | +6.2 | +6.7 | +9.2 | +13.2 | +13.5 |
| lobsters | +4.3 | +5.3 | +7.9 | +6.4 | +4.2 | +5.5 | +10.2 | +8.6 |
| mail | +3.9 | +7.1 | +8.5 | +3.8 | +6.5 | +8.1 | +14.0 | +10.8 |
| psych-load | +3.9 | +6.7 | +9.8 | +5.2 | +8.0 | +13.2 | +15.2 | +9.2 |
| railsbench | +5.3 | +6.4 | +9.1 | +7.7 | +4.4 | +5.2 | +10.6 | +10.0 |
| rubocop | +4.5 | +7.5 | +8.7 | +3.1 | +5.8 | +6.6 | +9.5 | +8.3 |
| ruby-lsp | +5.6 | +8.7 | +11.8 | +7.3 | +6.2 | +10.5 | +12.1 | +10.4 |
| sequel | +10.0 | +14.7 | **+19.9** | +14.0 | +9.9 | +10.8 | **+21.0** | +18.2 |
| shipit | +3.9 | +5.0 | +7.8 | +6.4 | +4.4 | +5.2 | +10.1 | +9.6 |
| **GEOMEAN** | **+5.9** | **+8.4** | **+11.4** | **+6.7** | **+6.9** | **+9.2** | **+13.0** | **+11.0** |

Tight interpreter loops gain most (`sequel` +21.0%, `liquid-compile` +19.3%, `liquid-c` +15.7%).
Full Rails stacks gain least (`shipit` +10.1%, `lobsters` +10.2%, `railsbench` +10.6%) — their
footprint is far more diffuse, so no profile concentrates as well. Even the worst case is ~+8%.

## 4.4 Absolute mean times, ms (mean of both passes)

| bench | base | pgo | pgolto | pgoltob | pgob | afdo | afdolto | afdoltob | afdob |
|---|---|---|---|---|---|---|---|---|---|
| activerecord | 318.7 | 306.9 | 290.7 | 286.9 | 306.9 | 293.5 | 286.1 | 278.5 | 296.1 |
| chunky-png | 924.2 | 856.2 | 864.1 | 834.6 | 887.4 | 825.2 | 816.5 | 817.9 | 832.0 |
| erubi-rails | 1492.7 | 1397.3 | 1358.3 | 1317.5 | 1372.1 | 1403.2 | 1361.8 | 1285.8 | 1314.4 |
| hexapdf | 2887.2 | 2826.2 | 2757.3 | 2672.0 | 2772.4 | 2745.2 | 2638.5 | 2588.2 | 2672.8 |
| liquid-c | 73.3 | 66.1 | 65.1 | 63.3 | 65.7 | 67.6 | 66.5 | 64.0 | 64.5 |
| liquid-compile | 75.0 | 67.2 | 64.7 | 62.9 | 66.6 | 69.6 | 66.7 | 65.6 | 65.2 |
| liquid-il | 426.8 | 416.9 | 408.8 | 395.8 | 416.3 | 401.4 | 400.5 | 391.1 | 391.0 |
| liquid-render | 177.1 | 164.4 | 161.2 | 156.5 | 166.8 | 165.9 | 162.1 | 156.4 | 156.0 |
| lobsters | 1171.7 | 1123.7 | 1112.5 | 1085.8 | 1101.6 | 1124.2 | 1111.1 | 1063.2 | 1078.9 |
| mail | 150.1 | 144.4 | 140.2 | 138.3 | 144.7 | 140.9 | 138.8 | 131.7 | 135.4 |
| psych-load | 2490.6 | 2396.8 | 2333.7 | 2268.3 | 2367.4 | 2306.4 | 2200.7 | 2162.1 | 2280.1 |
| railsbench | 2740.6 | 2602.0 | 2575.2 | 2512.3 | 2545.6 | 2623.9 | 2605.0 | 2476.8 | 2492.0 |
| rubocop | 201.8 | 193.1 | 187.7 | 185.7 | 195.8 | 190.8 | 189.3 | 184.3 | 186.5 |
| ruby-lsp | 189.9 | 179.8 | 174.6 | 169.9 | 177.0 | 178.7 | 171.8 | 169.4 | 172.1 |
| sequel | 82.4 | 74.9 | 71.8 | 68.7 | 72.3 | 75.0 | 74.4 | 68.1 | 69.7 |
| shipit | 2058.2 | 1980.3 | 1959.8 | 1909.1 | 1934.6 | 1971.9 | 1956.0 | 1869.0 | 1877.8 |

---

# Part 5 — perf analysis: why `afdoltob` is faster

## 5.1 How the captures were taken

**Steady state:** 128 parallel railsbench workers, one pinned per vCPU (Puma-style deployment).
Each worker got its own 640 KB copy of the benchmark, because `use_gemfile`
(`harness-common.rb:53-65`) runs `db:migrate db:seed` on *every* launch and `db/seeds.rb` deletes
and repopulates the database — 128 workers on one SQLite file would have reseeded it concurrently
instead of reaching steady state. railsbench is the only one of the 16 headline benchmarks with an
`extra_setup_cmd`, so this trap is specific to it.

**Readiness gate, not a fixed sleep:** all 128 workers had to print an iteration line (proving they
were past Rails boot, migrate, seed and warmup), the box had to be ≥90% busy, and 128 PIDs live.
Both arms gated at **128/128 workers, 100.0% busy** within 25 s.

**Three non-overlapping 30 s windows**, 10 s gaps, in order `stat` → `record` → `c2c`. They must
not overlap: all three program the same PMU, and concurrent use forces multiplexing, making each
count a scaled estimate over a different sample of time. Every window's UTC start/end is logged.

**Frequency pinned** (`no_turbo=1`, `min_perf_pct=100`, `nmi_watchdog=0`, `perf_event_paranoid=0`),
matching what yjit-bench applied during the campaign. **Verified, not assumed:**
`cycles/ref-cycles = 1.0000` in all four stat windows — both arms ran at exactly base 2.9 GHz.

**Mirrored:** the whole `perf stat` capture was repeated in reverse arm order. Figures below are the
mean of both passes.

```bash
perf stat -a -e cycles,ref-cycles,instructions,branches,branch-misses,\
topdown-retiring,topdown-fe-bound,topdown-be-bound,topdown-bad-spec,\
icache_64b.iftag_stall,icache_64b.iftag_miss,idq_uops_not_delivered.core,\
itlb_misses.walk_pending,l2_rqsts.code_rd_miss -- sleep 30

perf record -a -F 999 --call-graph fp -o record-$ARM.data -- sleep 30
perf c2c record -a --ldlat 30 -o c2c-$ARM.data -- sleep 30
```

`--call-graph fp` is valid only because of `-fno-omit-frame-pointer` in §2.1.

**The three different `perf record` uses — do not conflate them:**

| purpose | command | why that event |
|---|---|---|
| AutoFDO profile | `perf record -e cycles:u -b` | LBR branch records; `create_gcov` needs edge counts |
| BOLT profile | `perf record -e cycles:u -j any,u` | branch stacks, all user branch types |
| characterisation | `perf record -a -F 999 --call-graph fp` | system-wide time attribution, not fed back |

## 5.2 `perf stat` — the front-end hypothesis confirmed

| metric | base | afdoltob | change |
|---|---|---|---|
| cycles | 11.1605e12 | 11.1582e12 | — (same 30 s, same clock) |
| cycles / ref-cycles | 1.0000 | 1.0000 | frequency identical ✓ |
| instructions | 5.2241e12 | 5.1283e12 | **−1.83%** |
| IPC | 0.4681 | 0.4596 | −1.81% |
| branches | 923.3e9 | 884.2e9 | **−4.24%** |
| branch-misses | 50.44e9 | 53.84e9 | **+6.72%** |
| branch miss rate | 5.46% | 6.09% | +0.62 pp |
| **icache_64b.iftag_stall** (% cycles) | **11.71%** | **6.40%** | **−45.4%** |
| icache_64b.iftag_miss | 227.1e9 | 164.8e9 | **−27.4%** |
| idq_uops_not_delivered.core | 10.888e12 | 9.128e12 | **−16.2%** |
| itlb_misses.walk_pending | 155.0e9 | 139.1e9 | **−10.3%** |
| l2_rqsts.code_rd_miss | 24.26e9 | 22.11e9 | **−8.9%** |
| l2 code-read miss / kinstr | 4.65 | 4.31 | −7.2% |

Top-down slots:

| | base | afdoltob | change |
|---|---|---|---|
| **front-end bound** | **38.83%** | **32.52%** | **−6.31 pp (−16.3% rel)** |
| back-end bound | 29.19% | 34.32% | +5.13 pp |
| bad speculation | 13.25% | 15.11% | +1.86 pp |
| retiring | 18.73% | 18.04% | −0.69 pp |

Pass-to-pass spread: front-end bound base 38.27 / 39.39 (1.12 pp), afdoltob 32.60 / 32.44
(0.16 pp); I-cache stall base 11.88 / 11.53, afdoltob 6.32 / 6.48. The **6.31 pp gap is ~6× the
largest spread.**

Two results need care rather than celebration:

* **IPC fell 1.8% and the arm is still faster.** Not a contradiction: these are fixed 30 s windows
  on a saturated box, so cycles are constant *by construction* and IPC is not a proxy for speed.
  `afdoltob` retires **1.83% fewer instructions** — same work, less code executed, mostly through
  more aggressive inlining. Fewer instructions at slightly lower IPC still finishes sooner; §5.5
  measures that directly.
* **Back-end bound +5.13 pp and bad speculation +1.86 pp.** The expected consequence of removing a
  front-end bottleneck: the limiter moves. The branch-miss rise (+6.7%) is the one genuinely
  adverse counter — plausibly BOLT's re-layout changing branch directions and predictor aliasing.
  Outweighed, but it marks where further gain would have to come from.

## 5.3 `perf record` — the mechanism, function by function

| base | % | afdoltob | % |
|---|---|---|---|
| `vm_exec_core` | 31.90 | `vm_exec_core.lto_priv.0` | 34.91 |
| `vm_call_iseq_setup_normal_0start_0params_0locals` | 4.56 | same | 4.97 |
| `vm_call_iseq_setup_normal_0start_1params_1locals` | 2.89 | same | 3.14 |
| `rb_wb_protected_newobj_of` | 2.49 | *(inlined away)* | — |
| `rb_vm_opt_getconstant_path` | 2.46 | `rb_vm_opt_getconstant_path` | 2.74 |
| `vm_call_cfunc_with_frame` | 2.06 | `vm_call_cfunc_with_frame` | 2.12 |
| `vm_call_iseq_setup` | 1.59 | `vm_call_iseq_setup.lto_priv.0` | 1.48 |
| `rb_id_table_lookup` | 1.59 | *(inlined away)* | — |
| `gc_sweep_step` | 1.52 | `gc_sweep_step.lto_priv.0` | 1.48 |
| `rb_vm_search_method_slowpath` | 1.26 | → `vm_search_cc.lto_priv.0` | 2.25 |
| `rb_call0` | 1.12 | *(inlined away)* | — |
| `vm_sendish.constprop.0` | 1.08 | *(inlined away)* | — |
| `find_table_entry_ind` | 0.97 | *(inlined away)* | — |
| `callable_method_entry_or_negative` | 0.92 | *(inlined away)* | — |
| `vm_yield_setup_args` | 0.69 | *(inlined away)* | — |

`vm_exec_core` — the interpreter's giant computed-goto dispatch loop — dominates both arms at
~32–35% of all cycles. **That single function is why Ruby responds to layout optimisation where the
gcc-built databases did not:** one enormous, branch-dense body with poor I-cache locality is
precisely the shape BOLT and AutoFDO exist to re-lay-out.

**Seven of base's top-15 functions do not appear in afdoltob's profile.** They were not eliminated,
they were **inlined into callers** — write-barrier allocation, id-table lookup, `rb_call0`,
`find_table_entry_ind`, `callable_method_entry_or_negative`, `vm_yield_setup_args`, `vm_sendish`.
Read as *work moved*, not work removed; it is the mechanism behind −1.83% instructions and −4.24%
branches: fewer call-site transitions, prologues/epilogues and indirect jumps.

The profile is also **more concentrated** — a larger share in the hot loop, less scattered across
small helpers. Fewer, larger hot regions is the software-side view of what the I-cache counters
report from hardware.

## 5.4 `perf c2c` — a clean null

| | base | afdoltob |
|---|---|---|
| Total records | 29,788,949 | 29,822,992 |
| Load operations | 14,838,614 | 14,902,793 |
| **Local HITM** | **4,654** | **4,567** |
| **Remote HITM** | **4,692** | **4,371** |
| HITM as % of loads | **0.063%** | **0.060%** |
| LLC misses → local DRAM | 99.5% | 99.5% |
| LLC misses → remote DRAM | 0.3% | 0.3% |
| LLC misses → remote cache (HITM) | 0.2% | 0.2% |

No cross-core sharing problem exists in either arm, and FDO does not create or remove one. Total
HITM is ~9,000 events against 14.8M sampled loads.

The finding that settles it: the **#1 shared cache line — 21.9% of all HITM in base, 23.9% in
afdoltob — is `perf_mmap__read_head` / `perf_mmap__read_init` in the `perf` binary itself**, the
profiler's own ring buffer on CPU 127. Every remaining entry is an unresolved kernel address
(`0xffffffff8cd9…`, scheduler/futex class) spread across both nodes. **Not one Ruby symbol appears
in the shared-line table of either arm.**

That is the correct answer for this workload, not a failed measurement. The 128 workers are
separate processes: no shared Ruby heap, and after the per-worker copies no shared SQLite file.
What they genuinely share is the ruby `.text`/`.rodata` — read-only and clean, so shared loads and
never HITM, because HITM requires a *store* to a line another core holds. NUMA behaviour is healthy
and unchanged: 99.5% of LLC misses go to local DRAM in both arms.

**One real non-HITM difference, which I would not have predicted:**

| | base | afdoltob | change |
|---|---|---|---|
| Store operations | 14,950,335 | 14,920,199 | — |
| Store L1D hit | 14,233,094 | 14,547,944 | +2.2% |
| **Store L1D miss** | **717,241** | **372,255** | **−48.1%** |
| Store L1D miss rate | 4.80% | 2.49% | halved |
| Load L1D hit | 4,031,132 | 4,147,045 | +2.9% |
| Load L2 hit | 953,507 | 878,193 | −7.9% |
| Load LLC hit | 2,293,531 | 2,221,865 | −3.1% |

Store L1D misses are **halved**. Likely the same inlining seen in §5.3: far fewer call frames means
much less stack push/pop traffic, so the store stream becomes markedly more L1-resident. Loads
shift the same way. The optimisation improves **data**-side locality as a second-order effect, not
only instruction-side.

## 5.5 Throughput cross-check

From the per-worker logs, discarding each worker's 3 warmup iterations:

| arm | mean | median | p10 | p90 | iterations |
|---|---|---|---|---|---|
| base | 5627.8 ms | 5610 ms | 5502 | 5734 | 9,143 |
| afdoltob | **5259.2 ms** | 5246 ms | 5090 | 5385 | 9,396 |

**+7.01% on the mean, +6.94% on the median** under 128-way load.

This closes the loop: `afdoltob` executes 1.83% fewer instructions at 1.81% lower IPC and still
completes 7% more work. Compare **+10.6%** for railsbench single-core pinned in the campaign — the
loaded figure is lower because 128 workers on 64 physical cores means SMT siblings share L1I/L2 and
the back end, diluting part of the front-end win. Both are real; they are different operating
points. Iteration time also roughly doubles versus unloaded single-core (2635 → 5610 ms), exactly
as expected when 128 workers share 64 physical cores.

---

# Part 6 — Gotchas that cost real time

1. **`-Wno-missing-profile` is mandatory**, not cosmetic. Ruby's `configure` has a *"checking
   whether CFLAGS is valid"* probe that compiles a trivial file and rejects the **entire** flag set
   if anything reaches stderr. Under `-fprofile-use`/`-fauto-profile` that file has no counters,
   gcc emits `-Wmissing-profile`, and configure dies with `something wrong with CFLAGS=…`. Killed
   the first `pgo` arm at 3m48s.
2. **Gems must be shared from `base`** (§3.3) — otherwise arms run different extension code and the
   PGO arms pollute their own profiles.
3. **`create_gcov` needs `-DCMAKE_POLICY_VERSION_MINIMUM=3.5`** on cmake 4.2, plus
   protobuf/gflags/glog/unwind dev packages. A gcov-version mismatch reports "profile not found",
   not a version error.
4. **Ruby block-buffers `$stdout` to a file.** Worker iteration lines sat unflushed for 10+ minutes,
   making the log-based readiness gate read 0/128 on a box provably saturated at load 128. Fix:
   `RUBYOPT="-r<file setting \$stdout.sync = true>"`. The only lines that *did* appear were those
   immediately before a `system()` call, because Ruby flushes before spawning — which is what
   identified the cause.
5. **`pkill -f <pattern>` over ssh matches the ssh command line itself** and kills the session. Use
   an obfuscated pattern (`P="ruby-buil"; pkill -f "${P}d.sh"`).
6. **yjit-bench warns `'base' and 'pgo' appear identical`** — it compares `ruby -v` strings, which
   are necessarily identical across arms. Labelling heuristic only; the md5s in each MANIFEST are
   the real discriminator.
7. **`--out-name` ignores directories**, writing to the yjit-bench repo root (§3.4).
8. **`perf_event_paranoid` is 4 on stock Ubuntu 26.04**, which blocks all sampling. Persist 0 to
   `/etc/sysctl.d/99-perf.conf` or a reboot silently breaks the afdo/bolt arms.
9. **The box rebooted seven times in ~20 h** with a new public IP each time, despite reporting
   `instance-life-cycle: on-demand`. Everything under the campaign root survives (EBS), which is why
   both the build chain and the campaign are resumable. Design for it.

---

# Part 7 — Caveats before quoting any of this

1. **The workload is a stand-in.** The request named a *GCP Ruby workload* but it was never
   specified, so training and measurement both used yjit-bench's headline set. It is a defensible
   proxy for a Ruby service, and `railsbench`/`lobsters`/`shipit` (+9–11%) are the closest
   analogues — but FDO results are only as representative as the training workload. **Retrain
   against the real application before committing to a number**; it is a two-variable change
   (`TRAIN_CMD`/`MEAS_CMD`).
2. **Ruby core only** (§3.3). Whole-stack FDO should give more than +13%.
3. **Interpreter mode, not YJIT.** YJIT is Rust-compiled, so gcc-side FDO cannot move the code it
   generates; these gains apply to the interpreter, GC and C runtime. A YJIT-enabled deployment
   sees a smaller fraction.
4. **Single platform, n=1 campaign.** The ≤0.47% mirrored spread establishes *reproducibility
   within the run*, not cross-platform transfer. Ice Lake's weaker front end likely flatters layout
   optimisation relative to Granite Rapids.
5. **The perf numbers describe a loaded 128-worker deployment at +7.0%**, not the single-core-pinned
   configuration where the headline +13.04% was measured.

---

# Part 8 — Artefacts

Harness (local `~/ruby-fdo/`, deployed to `/home/ubuntu/ruby-fdo/bin/`):
`ruby-env.sh` · `ruby-stage.sh` · `ruby-build.sh` · `ruby-sharegems.sh` · `ruby-all.sh` ·
`ruby-campaign.sh` · `ruby-perf.sh` · `report.rb`

On the box:

| path | contents |
|---|---|
| `inst/ruby-<arm>/` | 9 installed arms, each with `FINGERPRINT` (arm, versions, exact flags, md5) |
| `res/campaign-20261013-083459/` | `MANIFEST` + 32 per-(direction,benchmark) JSON |
| `perf/`, `perf-mir/` | `stat-*[-mir].txt`, `report-*.txt`, `c2c-*.txt`, `timeline-*.log`, `workers-*/w*.log` |
| `perf/*.data` | raw `record-*` (1.0–1.2 GB each), `c2c-*` (2.5 GB each) |
| `prof/<arm>/` | `.gcda` (PGO), `ruby.gcov` + `perf.data` (AutoFDO), `bolt.data`/`bolt.fdata` (BOLT) |

Reproduce:

```bash
cd /home/ubuntu/ruby-fdo/bin
./ruby-stage.sh
./ruby-build.sh base && ./ruby-sharegems.sh base
./ruby-all.sh pgo pgolto pgoltob pgob afdo afdolto afdoltob afdob
./ruby-campaign.sh && ruby report.rb res/<campaign>
./ruby-perf.sh base && ./ruby-perf.sh afdoltob
```
