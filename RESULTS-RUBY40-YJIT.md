# Ruby 4.0.6 + YJIT — FDO results (the customer's configuration)

Campaign `campaign-20261014-221801` · gcc 15.2.0 · m6i.metal (Ice Lake) · mirrored fwd+rev

**This supersedes the Ruby 3.4.11 interpreter-mode campaign as the deployment-relevant result.**
That earlier campaign is kept for comparison, not discarded — see §6.

## What changed and why

akim, 2026-10-14, relaying customer feedback:

1. **YJIT is enabled** — the customer runs with it. The first campaign measured interpreter mode
   (YJIT compiled in but disabled), which was the wrong operating point.
2. **Workload is ruby-bench headline**, and of its 16 benchmarks the customer cares most about
   **`lobsters`**. The workload already matched; `lobsters` is now reported as a headline figure
   rather than one row of sixteen.
3. **Ruby 4.0.6** instead of 3.4.11.
4. Customer contributes to Ruby and ruby-bench and runs close to HEAD, so ruby-bench was updated
   `2c3e549` → **`13e09f7`** (9 commits; headline set unchanged at 16).

## Configuration

| | |
|---|---|
| Ruby | **4.0.6** (2026-07-14 revision 03b6d3f889) +YJIT +PRISM |
| Execution | **`--yjit`** on every training *and* measurement run |
| Compiler | gcc 15.2.0 |
| Workload | ruby-bench (yjit-bench) `--category=headline`, 16 benchmarks, HEAD `13e09f7` |
| Iterations | warmup **12**, bench 8 |
| Baseline | `-O3 -march=native -mtune=native -fno-omit-frame-pointer -g` |
| Gem ABI | 4.0.0, shared set rebuilt from a freshly primed base arm (423 MB, 384 gems) |

No rebuild was needed to *enable* YJIT — rustc 1.93.1 was present at configure time so every arm
has it compiled in, and `--yjit` is a runtime flag. What YJIT invalidated was the **profiles**:
all eight FDO arms were retrained, because with YJIT on the hot C code is a different set and the
bytecode dispatch loop that dominated the interpreter profile largely disappears into
JIT-generated machine code.

Methodology changes forced by YJIT:

* **Measurement warmup 5 → 12.** YJIT compiles lazily, so early iterations include compilation
  rather than steady-state execution. ruby-bench's own default is 15 for this reason.
* **Training 1+2 → 3+5 iterations.** Under YJIT a large share of cycles lands in anonymous
  JIT-generated code with no symbols, which `create_gcov` and `perf2bolt` both discard. More
  iterations are needed for comparable coverage of the `ruby` binary's own text.

## 1. Headline

Speedup vs `base`, geometric mean over 16 benchmarks; `spread` = |fwd − rev|.

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

**Recommendation unchanged: `afdoltob` (AutoFDO + LTO + BOLT).** It wins both the geomean
(+20.42%) and the customer's benchmark of record (`lobsters`, **+13.77%**, 715.7 → 629.1 ms).
`pgoltob` +17.60% remains the PGO-based alternative if `perf` sampling is unavailable.

Spreads are 0.00–0.85%, so the ordering is solid.

### A caution specific to lobsters

The arm ordering on `lobsters` is **not** the same as the geomean ordering, and the differences
are real rather than noise:

* **LTO hurts the PGO path on lobsters**: `pgolto` +3.92% is *worse* than plain `pgo` +6.55%, and
  `pgob` (BOLT, no LTO) +9.71% beats `pgoltob` +9.00%.
* On the geomean, LTO helps everywhere.

So if `lobsters` is the deployment proxy that matters, the PGO path should skip LTO. For the
AutoFDO path, LTO helps on lobsters too (+5.97 → +7.83 → +13.77), and `afdoltob` wins outright
either way — which is the simplest reason to pick it.

## 2. Per-benchmark mirrored speedup vs base (%)

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

Every arm is positive on every benchmark. `lobsters` is among the *smallest* gainers — it is a
full Rails stack with a diffuse code footprint, so no profile concentrates on it as well as it
does on tight loops like `sequel` (+34.6%) or `chunky-png` (+32.2%).

## 3. Absolute mean times, ms

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

## 4. Binaries

| arm | build | md5 |
|---|---|---|
| base | 1m00s | `c6f32808afea0726d9d04db50b50ff40` |
| pgo | 5m16s | `9450df2f21eeabd05f0baf39f3e2004c` |
| pgolto | 8m22s | `a9c80cfb29d6462e32b8e5ac200c3ff1` |
| pgoltob | 11m09s | `d336ff339b5d7179abc386323668718f` |
| pgob | 7m58s | `c327187d087ed0a04af76dff6bb523d5` |
| afdo | 5m22s | `06ff4ac8d34a3f9581ffbc4ab6e7538d` |
| afdolto | 8m42s | `236628ff8bc18d064d080d849083d0cc` |
| **afdoltob** | 11m17s | `cf4c273637b731c480862d36d7eb1c0f` |
| afdob | 7m58s | `54d53a39a33c3230439a73ab882c42c0` |

Training was verified to run under YJIT by the harness banner reading
`train: ruby 4.0.6 … +YJIT +PRISM` — see §7.1 for why that check exists.

## 5. perf analysis — the mechanism is different under YJIT

128 parallel **railsbench** workers (see §7.2 for why not lobsters), `--yjit`, frequency pinned,
three non-overlapping 30 s windows, both arms gated at **128/128 workers, 100.0% busy**.
`cycles/ref-cycles = 1.0000` in both windows, so the clock was identical.

| metric | base | afdoltob | change |
|---|---|---|---|
| cycles | 11.3996e12 | 11.3606e12 | — (fixed 30 s window) |
| **instructions** | 7.724e12 | 7.040e12 | **−8.85%** |
| **branches** | 1.411e12 | 1.286e12 | **−8.88%** |
| IPC | 0.678 | 0.620 | −8.6% |
| topdown-fe-bound | **51.51%** | **52.17%** | +0.66 pp |
| topdown-be-bound | 14.95% | 16.26% | +1.31 pp |
| topdown-retiring | 26.23% | 23.92% | −2.31 pp |
| topdown-bad-spec | 7.31% | 7.65% | +0.34 pp |
| icache_64b.iftag_stall (% cycles) | 14.53% | 15.23% | +0.70 pp |
| icache_64b.iftag_miss | 379.2e9 | 369.5e9 | −2.6% |
| idq_uops_not_delivered.core | 14.732e12 | 14.875e12 | +1.0% |
| itlb_misses.walk_pending | 345.4e9 | 371.7e9 | +7.6% |
| l2_rqsts.code_rd_miss | 77.7e9 | 78.6e9 | +1.2% |
| branch miss rate | 2.73% | 3.04% | +0.31 pp |

**The win is now a code-size/instruction-count win, not a front-end win.** Under YJIT:

* Both arms are **~51–52% front-end bound**, and FDO moves that **not at all** (+0.66 pp, i.e.
  marginally worse). The front end is dominated by JIT-generated machine code that gcc never
  sees, so no amount of gcc-side layout optimisation can touch it. I-cache stalls, undelivered
  uops and iTLB walks are all flat-to-slightly-worse.
* Instead `afdoltob` retires **8.85% fewer instructions** and executes **8.88% fewer branches** —
  inlining and specialisation of the C runtime (GC, allocation, method lookup, C functions,
  side-exit handling) is doing the work.

Contrast with the interpreter-mode campaign on Ruby 3.4.11, where the same arm cut
`icache_64b.iftag_stall` by **45%** and front-end bound by **6.31 pp** while reducing instructions
only 1.83%. **Same optimisation, two different mechanisms, depending on whether YJIT is on.**

Note also that enabling YJIT *raises* front-end pressure substantially — base goes from 38.8%
front-end bound (interpreter, 3.4.11) to 51.5% (YJIT, 4.0.6). JIT code has a large I-cache
footprint. That is a plausible target for a *JIT-side* layout optimisation, but it is out of reach
for gcc FDO.

### Loaded throughput cross-check

| arm | mean | median | iterations |
|---|---|---|---|
| base | 22206.2 ms | 22350 ms | 15,821 |
| afdoltob | 20998.0 ms | 20395 ms | 8,983 |

**+5.75% on the mean, +9.59% on the median** under 128-way load. Treat this as weaker evidence
than §1: the two runs accumulated very different iteration counts (15,821 vs 8,983), so the
distributions are not matched. The mirrored campaign in §1 is the authoritative speedup.

## 6. Comparison with the Ruby 3.4.11 interpreter-mode campaign

| | 3.4.11, interpreter | 4.0.6, YJIT |
|---|---|---|
| afdoltob geomean | +13.04% | **+20.42%** |
| pgoltob geomean | +11.35% | +17.60% |
| lobsters (afdoltob) | +10.2% | **+13.77%** |
| mechanism | front-end: I-cache stalls −45%, fe-bound −6.31 pp | instruction count −8.85%, front end unchanged |
| base fe-bound | 38.8% | 51.5% |

**The gain went up, not down — and I expected the opposite.** My stated expectation was that YJIT
would absorb most of the FDO benefit, since gcc cannot optimise JIT-generated code. That was
wrong in direction.

**But this is not attributable to YJIT alone.** Four things changed together:

1. Ruby 3.4.11 → 4.0.6
2. interpreter → YJIT
3. training 1+2 → 3+5 iterations (a longer, likely better profile — independent of YJIT)
4. ruby-bench `2c3e549` → `13e09f7`

Any of these could carry part of the +13.04% → +20.42% difference, and the training-length change
in particular is a known confound. **Do not attribute the improvement to YJIT.** The clean
attribution experiment is cheap and worth running: measure the *same* Ruby 4.0.6 arms **without**
`--yjit`. That isolates YJIT-vs-interpreter on identical binaries and costs one campaign (~45 min).

## 7. Two problems found along the way

### 7.1 The first YJIT rebuild silently trained in interpreter mode

`RUBY_FLAGS` was set in `ruby-env.sh` but never **exported**. `TRAIN_CMD` runs via
`bash -c "$TRAIN_CMD"`, and that inner shell expands `$RUBY_FLAGS` from its own *environment* — a
plain shell variable is invisible to it. The flag expanded to empty, so the arm trained without
YJIT. Nothing errored. The only evidence was the harness banner reading `+PRISM` with no `+YJIT`.

Caught after one arm; that build was discarded. `RUBY_FLAGS` is now exported *and* passed
explicitly in all four `env` invocations, and the banner check is a required verification step.

### 7.2 lobsters is unstable at 128-way concurrency — in both arms

The perf captures were meant to run on `lobsters`, the customer's benchmark of interest. They
could not, and the reason is worth passing on:

At 128 concurrent workers, ~80 of 128 lobsters processes die with **HTTP 500** from
`User#unread_replies_count`, caused by `Errno::ENOENT` in
`ActiveSupport::Cache::FileStore` renaming into `tmp/cache/<nn>/<nnn>/`. It affects **both arms
roughly equally (base 88 failures, afdoltob 76)**, so it is *not* a miscompilation in the
optimised build — that was the first thing checked.

Part of it was self-inflicted and is fixed: per-worker private copies of the benchmark directory
are now created for *every* benchmark (not just railsbench, which was the only one with an
`extra_setup_cmd`), and the Rails `tmp/cache` and `log` trees are recreated in each copy. With 8
workers that fix gives 8/8 and zero 500s. At 128 workers the failures return, so there is a
residual concurrency limit inside the lobsters app's file-store cache.

**Consequence:** the perf characterisation uses railsbench, which is stable at 128/128 with zero
attrition. The *measured* lobsters result in §1 is unaffected — the campaign runs one process at a
time, pinned, which is the normal ruby-bench configuration.

This may be of direct interest to the customer given they contribute to ruby-bench: lobsters does
not survive heavy parallel execution from a shared checkout, even with private per-worker copies.

## 8. Caveats

1. **Ruby core only.** All arms share one gem set built by `base`, so native gem extensions are
   identical across arms and unoptimised. Whole-stack FDO should yield more.
2. **gcc FDO cannot touch YJIT.** YJIT is Rust-compiled and its output is generated at runtime.
   §5 quantifies this: the front end, now dominated by JIT code, is unmoved.
3. **One platform.** m6i.metal Ice Lake, 2S, 128 vCPU. The ≤0.85% mirrored spread establishes
   reproducibility within the run, not cross-platform transfer.
4. **Four variables moved at once** between campaigns — see §6.
5. **ZJIT also ships in Ruby 4.0** and is compiled into these binaries. It was not measured. If
   the customer is experimenting with it, a ZJIT arm is one extra `-e` spec and needs no rebuild.
