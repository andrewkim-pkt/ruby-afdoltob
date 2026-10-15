# ruby-afdoltob — Ruby feedback-directed optimisation with gcc 15.2.0

A nine-arm study of **PGO, AutoFDO, LTO and BOLT** applied to CRuby, measured mirrored on
ruby-bench's 16 headline benchmarks, with hardware-counter analysis of *why* the winning
configuration wins.

Two campaigns at two operating points. **The Ruby 4.0.6 + YJIT campaign is the one to quote** — it
is the deployment configuration; the 3.4.11 interpreter campaign is kept for comparison.

## Primary: Ruby 4.0.6 with YJIT enabled

**`afdoltob` (AutoFDO + LTO + BOLT) is +20.42% geomean, and +13.77% on `lobsters`.**

| arm | fwd | rev | **mirrored** | spread | **lobsters** |
|---|---|---|---|---|---|
| base | +0.00% | +0.00% | — | 0.00% | — |
| pgo | +8.42% | +8.44% | **+8.43%** | 0.02% | +6.55% |
| pgolto | +13.21% | +13.74% | **+13.47%** | 0.53% | +3.92% |
| pgoltob | +18.03% | +17.18% | **+17.60%** | 0.85% | +9.00% |
| pgob | +11.51% | +12.28% | **+11.90%** | 0.77% | +9.71% |
| afdo | +9.98% | +9.80% | **+9.89%** | 0.18% | +5.97% |
| afdolto | +14.50% | +14.50% | **+14.50%** | 0.00% | +7.83% |
| **afdoltob** | +20.16% | +20.68% | **+20.42%** | 0.52% | **+13.77%** |
| afdob | +16.59% | +16.98% | **+16.78%** | 0.39% | +12.35% |

Full detail, per-benchmark tables and perf analysis: **[RESULTS-RUBY40-YJIT.md](RESULTS-RUBY40-YJIT.md)**.

**Prebuilt binary available:** [`binaries/ruby-4.0.6-afdoltob-icelake.tar.xz`](binaries/) — the
exact `afdoltob` build that produced these numbers (`bin/ruby` md5 `cf4c273637b731c480862d36d7eb1c0f`,
byte-identical, not a rebuild). It is **`-march=native` Ice Lake-only**, needs **`--yjit`** to be
the measured configuration, and is **not relocatable** without setting `RUBYLIB`. Read
[binaries/README.md](binaries/README.md) before using it.

**Note for anyone whose own proxy is `lobsters`:** the arm ordering there differs from the geomean.
LTO *hurts* the PGO path on lobsters (`pgolto` +3.92% is worse than plain `pgo` +6.55%, and `pgob`
+9.71% beats `pgoltob` +9.00%), while it helps on the AutoFDO path. `afdoltob` wins either way,
which is the simplest reason to choose it.

## Secondary: Ruby 3.4.11, interpreter mode (YJIT off)

**`afdoltob` is +13.04%** — same recommendation, different magnitude and a *different mechanism*
(see below).

| arm | mirrored | | arm | mirrored |
|---|---|---|---|---|
| pgo | +5.89% | | afdo | +6.91% |
| pgolto | +8.43% | | afdolto | +9.17% |
| pgoltob | +11.35% | | **afdoltob** | **+13.04%** |
| pgob | +6.67% | | afdob | +11.01% |

Geometric mean across 16 benchmarks, speedup vs `base`. "fwd"/"rev" are forward and reverse
arm-ordering passes; "spread" is their disagreement, i.e. the practical uncertainty. No benchmark
regresses in any arm of either campaign.

## The same optimisation wins by two different mechanisms

| | 3.4.11 interpreter | 4.0.6 + YJIT |
|---|---|---|
| afdoltob geomean | +13.04% | **+20.42%** |
| I-cache stalls (% cycles) | 11.71% → 6.40% (**−45%**) | 14.53% → 15.23% (unmoved) |
| front-end bound | 38.83% → 32.52% (**−6.31 pp**) | 51.51% → 52.17% (unmoved) |
| instructions retired | −1.83% | **−8.85%** |
| `vm_exec_core` share of cycles | **31.9%** | **0.84%** |

In interpreter mode FDO wins by fixing the layout of the bytecode dispatch loop. **Under YJIT that
loop is gone** — replaced by JIT-generated machine code that gcc never sees, and which pushes the
baseline from 38.8% to 51.5% front-end bound. FDO cannot touch that at all. Instead it wins by
retiring ~9% fewer C-side instructions through inlining and specialisation of the runtime (GC,
allocation, method lookup, C functions).

**Important:** the +13.04% → +20.42% difference is **not attributable to YJIT alone.** Four things
changed between campaigns — Ruby version, YJIT, training iteration count (1+2 → 3+5), and
ruby-bench revision. The clean attribution experiment (same 4.0.6 binaries measured without
`--yjit`) has not been run.

## Three findings

**1. BOLT helps on Ruby.** On gcc-built databases (MariaDB, PostgreSQL) BOLT stacked on PGO+LTO is
neutral-to-negative. Here it is the largest single increment on both paths: **+2.9%** on top of
`pgolto`, **+3.9%** on top of `afdolto`. The reason is structural and visible in the profile —
`vm_exec_core`, the interpreter's computed-goto dispatch loop, is **32–35% of all cycles**: one
enormous, branch-dense, I-cache-hostile function, which is exactly what block and function layout
optimisation exists to fix. Database engines have no equivalent.

**2. BOLT's payoff depends on what it is layered on.** Only **+0.8%** over PGO alone, but
**+4.1%** over AutoFDO alone. gcc's instrumented-PGO layout is already good, leaving BOLT little
to add; AutoFDO's sampled profile is coarser per basic block, so BOLT has real work left. Note
`afdob` (+11.01%, **no LTO**) nearly matches `pgoltob` (+11.35%) — AutoFDO + BOLT reaches most of
the gain without LTO's build cost. The no-LTO BOLT arms (`pgob`, `afdob`) exist specifically to
separate "BOLT does nothing" from "BOLT does nothing *on top of LTO*".

**3. AutoFDO beats PGO at every level** (+1.0, +0.7, +1.7 points at FDO / +LTO / +LTO+BOLT),
reversing the MySQL/MariaDB ordering — and it trains from `perf` samples on an unmodified binary
rather than requiring an instrumented build, so it is cheaper too.

## Why — confirmed by hardware counters, not inferred

128 parallel railsbench workers, frequency pinned, three non-overlapping 30 s windows, mirrored:

| metric | base | afdoltob | change |
|---|---|---|---|
| **icache_64b.iftag_stall** (% of cycles) | **11.71%** | **6.40%** | **−45.4%** |
| **topdown-fe-bound** | **38.83%** | **32.52%** | **−6.31 pp** |
| idq_uops_not_delivered.core | 10.888e12 | 9.128e12 | −16.2% |
| icache_64b.iftag_miss | 227.1e9 | 164.8e9 | −27.4% |
| itlb_misses.walk_pending | 155.0e9 | 139.1e9 | −10.3% |
| l2_rqsts.code_rd_miss | 24.26e9 | 22.11e9 | −8.9% |
| instructions | 5.2241e12 | 5.1283e12 | −1.83% |
| back-end bound | 29.19% | 34.32% | +5.13 pp |
| branch-misses | 50.44e9 | 53.84e9 | +6.72% |

It is a **front-end / code-layout win**. The 6.31 pp front-end change is ~6× the worst
pass-to-pass spread. Seven of base's top-15 functions are *inlined away* in `afdoltob`
(`rb_wb_protected_newobj_of`, `rb_id_table_lookup`, `rb_call0`, `find_table_entry_ind`,
`callable_method_entry_or_negative`, `vm_yield_setup_args`, `vm_sendish`), which is what produces
the −1.83% instructions and −4.24% branches.

Two results that need care:

* **IPC falls 1.8% while the arm is faster.** These are fixed 30 s windows on a saturated box, so
  cycles are constant by construction and IPC is not a proxy for speed. Fewer instructions at
  slightly lower IPC still finishes sooner — measured throughput confirms it: **+7.01%** under
  128-way load (5627.8 → 5259.2 ms/iteration).
* **Back-end bound and bad speculation both rise.** Expected when a front-end bottleneck is
  removed: the limiter moves. Branch misses rising 6.7% is the one genuinely adverse counter.

`perf c2c` is a **clean null** — HITM is 0.06% of loads in both arms, and the single largest shared
cache line is `perf_mmap__read_head` in the `perf` binary itself (the profiler's own ring buffer).
No Ruby symbol appears in either arm's shared-line table. This is *not* a coherence or NUMA effect.
One unexpected side-finding: **store L1D misses halve** (4.80% → 2.49%), because inlining removes
call frames and so stack push/pop traffic — the optimisation improves data-side locality too.

## Platform

| | |
|---|---|
| Ruby | **4.0.6** (primary campaign) / 3.4.11 (secondary) |
| Box | AWS **m6i.metal** — 2S Intel Xeon Platinum 8375C @2.9 GHz (Ice Lake-SP, family 6 model 106), 32c/64t per socket, **128 vCPU**, 2 NUMA nodes, 503 GiB |
| Cache | L1i **32 KB/core** (shared between SMT siblings), L1d 48 KB/core, L2 1.25 MB/core, L3 54 MiB/socket |
| OS | Ubuntu 26.04 LTS, kernel **7.0.0-1006-aws** at measurement |
| Compiler | **gcc 15.2.0** (Ubuntu's `gcc-15` 15.2.0-16ubuntu1 — distro default) |
| Post-link | llvm-bolt / perf2bolt **21.1.8** |
| AutoFDO | `create_gcov` (google/autofdo), built from source |
| Ruby | 3.4.11 +PRISM, `--enable-shared=no`, YJIT compiled in but **disabled**, system glibc malloc |
| Baseline | `-O3 -march=native -mtune=native -fno-omit-frame-pointer -g` |

The 32 KB of L1i per core, shared between two SMT siblings, is the budget the whole interpreter hot
path must fit into. It is why the I-cache counters move so much, and why the loaded 128-worker
figure (+7.0%) is below the single-core figure (+10.6% on railsbench).

## Build recipe

```bash
BASE_CFLAGS="-O3 -march=native -mtune=native -fno-omit-frame-pointer -g"
LTO_FLAGS="-flto=32 -ffat-lto-objects"
BOLT_LDFLAGS="-Wl,--emit-relocs -Wl,-q"      # llvm-bolt REFUSES the binary without these
```

AutoFDO:

```bash
# pass 1: plain build (AutoFDO samples a working binary)
perf record -o perf.data -e cycles:u -b -- <training run>        # -b = LBR edge counts
create_gcov --binary ruby --profile perf.data --gcov ruby.gcov -gcov_version=2
# pass 2:
CFLAGS="$BASE_CFLAGS $LTO_FLAGS -fauto-profile=ruby.gcov -Wno-missing-profile"
```

BOLT, after the final link:

```bash
perf record -o bolt.data -e cycles:u -j any,u -- <training run>
perf2bolt -p bolt.data -o bolt.fdata ruby.prebolt
llvm-bolt ruby.prebolt -o ruby -data=bolt.fdata \
    -reorder-blocks=ext-tsp -reorder-functions=hfsort+ \
    -split-functions -split-all-cold -split-eh \
    -dyno-stats -icf=1 -use-gnu-stack
```

Full per-option rationale, the PGO two-pass sequence, and the `configure` invocation (including why
`optflags="" debugflags=""` and `--enable-shared=no` are load-bearing) are in
[BUILD-STEPS.md](BUILD-STEPS.md) and Part 2 of [RUBY-FDO-REPORT.md](RUBY-FDO-REPORT.md).

## Three gotchas worth knowing before you try this

1. **`-Wno-missing-profile` is mandatory** for `-fprofile-use` and `-fauto-profile`. Ruby's
   `configure` has a *"checking whether CFLAGS is valid"* probe that compiles a trivial file and
   rejects the **entire** flag set if anything reaches stderr. That file has no counters, gcc emits
   `-Wmissing-profile`, and configure dies with `something wrong with CFLAGS=…`.
2. **Share one gem set across all arms.** yjit-bench compiles native extensions *with the ruby
   under test*, so PGO arms would build extensions with `-fprofile-generate` — writing stray
   `.gcda` and polluting the very profile being collected — and LTO arms with `-flto`. Each arm
   would then run different extension code. Consequence: **the gain measured here is FDO of the
   Ruby core only**; gem native code is identical across arms and unoptimised.
3. **`create_gcov` needs `-DCMAKE_POLICY_VERSION_MINIMUM=3.5`** on cmake 4.x, plus
   protobuf/gflags/glog/unwind dev packages. A gcov-version mismatch reports "profile not found",
   not a version error.

## Repository layout

```
RUBY-FDO-REPORT.md          full report: system info, recipe, workload config, results, perf analysis
RESULTS.md                  results only
PERF.md                     perf analysis only
BUILD-STEPS.md              build/profiling recipe only
harness/
  ruby-env.sh               shared config: arm matrix, flags, workload hooks
  ruby-stage.sh             toolchain, create_gcov, Ruby source, perf prerequisites
  ruby-build.sh             builds one arm (PGO / AutoFDO / LTO / BOLT)
  ruby-sharegems.sh         points an arm at the shared gem set
  ruby-all.sh               builds all arms, resumable
  ruby-campaign.sh          mirrored measurement, checkpointed per benchmark
  ruby-perf.sh              perf stat / record / c2c in non-overlapping windows
  report.rb                 aggregates a campaign into the mirrored tables
results/
  campaign/                 MANIFEST + 32 per-(direction,benchmark) JSON/CSV
  perf/                     perf stat, report, c2c text output + capture timelines
  fingerprints/             per-arm build record (versions, flags, md5)
```

Binaries are not included. Each arm's md5 is in `results/fingerprints/` and in the campaign
`MANIFEST`, so any number here can be traced to the binary that produced it.

## Reproducing

```bash
cd harness
./ruby-stage.sh                                     # toolchain + create_gcov + Ruby src + perf setup
./ruby-build.sh base && ./ruby-sharegems.sh base    # base owns the shared gem set
./ruby-all.sh pgo pgolto pgoltob pgob afdo afdolto afdoltob afdob
./ruby-campaign.sh && ruby report.rb res/<campaign> # mirrored fwd + rev
./ruby-perf.sh base && ./ruby-perf.sh afdoltob      # the three 30 s windows per arm
```

Builds are strictly serial — an arm compiling at `-j128` beside an arm being `perf`-sampled would
contaminate the profile. Total ~45 min of builds, ~1 h of mirrored measurement.

## Limitations

1. **The workload is a stand-in.** The motivating target was a specific Ruby service workload that
   was never specified, so training and measurement both used yjit-bench's headline set. It is a
   defensible proxy — four Rails apps, ActiveRecord/Sequel, Liquid templating, rubocop, ruby-lsp —
   and `railsbench`/`lobsters`/`shipit` (+9–11%) are the closest analogues. But FDO results are
   only as representative as the training workload. Retrain against your own application before
   committing to a number; it is a two-variable change (`TRAIN_CMD`/`MEAS_CMD` in `ruby-env.sh`).
2. **Ruby core only**, not gems (see gotcha 2). Whole-stack FDO should give more than +13%.
3. **Interpreter mode, not YJIT.** YJIT is Rust-compiled, so gcc-side FDO cannot move the code it
   generates. A YJIT-enabled deployment sees a smaller fraction of this.
4. **One platform, one campaign.** The ≤0.47% mirrored spread establishes reproducibility *within
   the run*, not cross-platform transfer. Ice Lake's comparatively weak front end plausibly
   flatters layout optimisation relative to newer parts.
5. **The perf analysis characterises a loaded 128-worker deployment at +7.0%**, not the
   single-core-pinned configuration in which the headline +13.04% was measured.
