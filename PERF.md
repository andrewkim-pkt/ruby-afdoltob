# Why `afdoltob` is faster — perf characterisation vs `base`

Ruby 3.4.11, gcc 15.2.0, m6i.metal (2S Ice Lake Xeon 8375C, 128 vCPU, 2 NUMA nodes).
Captured 2026-10-13. Arms: `base` (`6c2553ec…`) vs `afdoltob` (`d656566b…`).

## How this was measured

**Steady state:** 128 parallel railsbench workers, one pinned per vCPU (Puma-style deployment).
Each worker got its own 640 KB copy of the benchmark, because `use_gemfile`
(`harness-common.rb:53-65`) runs `db:migrate db:seed` on *every* launch and `db/seeds.rb` deletes
and repopulates the database — 128 workers on one SQLite file would have reseeded it concurrently
instead of reaching a steady state.

**Readiness gate, not a fixed sleep:** all 128 workers had to print an iteration line (proving
they were past Rails boot, migrate, seed and warmup), the box had to be ≥90% busy, and 128 PIDs
had to be live. Both arms gated at **128/128 workers, 100.0% busy** within 25 s.

**Three non-overlapping 30 s windows** with 10 s gaps, in this order: `perf stat`, `perf record`,
`perf c2c`. They must not overlap because all three program the same PMU; concurrent use forces
multiplexing and makes each count a scaled estimate over a different sample of time. UTC
start/end for every window is in `perf/timeline-<arm>.log`.

**Frequency pinned** (`no_turbo=1`, `min_perf_pct=100`, `nmi_watchdog=0`), matching what yjit-bench
itself applied during the measured campaign. Verified, not assumed: `cycles/ref-cycles = 1.0000`
in all four stat windows, i.e. both arms ran at exactly the base 2.9 GHz.

**Mirrored:** the whole `perf stat` capture was repeated in reverse arm order. All figures below
are the mean of the two passes, with the pass-to-pass spread quoted for the load-bearing metrics.

---

## 1. `perf stat` — what resource actually changed

| metric | base | afdoltob | change |
|---|---|---|---|
| cycles | 11.1605e12 | 11.1582e12 | — (same 30 s, same clock) |
| cycles / ref-cycles | 1.0000 | 1.0000 | frequency identical ✓ |
| instructions | 5.2241e12 | 5.1283e12 | **−1.83%** |
| IPC | 0.4681 | 0.4596 | −1.81% |
| branches | 923.3e9 | 884.2e9 | **−4.24%** |
| branch-misses | 50.44e9 | 53.84e9 | **+6.72%** |
| branch miss rate | 5.46% | 6.09% | +0.62 pp |
| **icache_64b.iftag_stall** (% of cycles) | **11.71%** | **6.40%** | **−45.4%** |
| icache_64b.iftag_miss | 227.1e9 | 164.8e9 | **−27.4%** |
| idq_uops_not_delivered.core | 10.888e12 | 9.128e12 | **−16.2%** |
| itlb_misses.walk_pending | 155.0e9 | 139.1e9 | **−10.3%** |
| l2_rqsts.code_rd_miss | 24.26e9 | 22.11e9 | **−8.9%** |
| l2 code-read miss / kinstr | 4.65 | 4.31 | −7.2% |

Top-down slot breakdown:

| | base | afdoltob | change |
|---|---|---|---|
| **front-end bound** | **38.83%** | **32.52%** | **−6.31 pp (−16.3% rel)** |
| back-end bound | 29.19% | 34.32% | +5.13 pp |
| bad speculation | 13.25% | 15.11% | +1.86 pp |
| retiring | 18.73% | 18.04% | −0.69 pp |

Pass-to-pass spread on the load-bearing figures: front-end bound base 38.27 / 39.39 (1.12 pp),
afdoltob 32.60 / 32.44 (0.16 pp); I-cache stall base 11.88 / 11.53, afdoltob 6.32 / 6.48. The
**6.31 pp gap is ~6× the largest spread**, so the direction is not in question.

**Analysis.** The front-end hypothesis is confirmed, and by a wide margin. Instruction-cache tag
stalls — cycles where the front end cannot fetch because of an I-cache tag lookup — are **cut
nearly in half**, 11.71% of all cycles down to 6.40%. Every supporting front-end counter moves the
same way: I-cache misses −27%, undelivered uops −16%, iTLB page-walk cycles −10%, L2 code-read
misses −9%. This is a code-layout win, which is exactly what PGO/AutoFDO + LTO + BOLT are for.

Two results need care rather than celebration:

* **IPC went *down* 1.8%, and the arm is still faster.** This is not a contradiction. These are
  fixed 30 s windows on a saturated box, so cycles are constant by construction and IPC is not a
  proxy for speed here. `afdoltob` retires **1.83% fewer instructions** — it does the same
  railsbench work with less code executed, largely through more aggressive inlining (its `.text`
  is 5.2 MB vs PGO's 4.1 MB). Fewer instructions at slightly lower IPC still finishes sooner, and
  §4 measures that directly.
* **Back-end bound rose 5.13 pp and bad speculation 1.86 pp.** This is the expected consequence of
  removing a front-end bottleneck: the limiter moves. Once the front end stops starving the
  machine, the back end and the branch predictor become the binding constraints. The branch-miss
  increase (+6.7%, rate 5.46% → 6.09%) is the one genuinely unfavourable counter — plausibly BOLT's
  re-layout changing branch directions and predictor aliasing. It is outweighed, but it marks where
  the next increment of gain would have to come from.

---

## 2. `perf record` — where the time goes

Top functions by self time (`--no-children`, 30 s, system-wide):

| base | % | afdoltob | % |
|---|---|---|---|
| `vm_exec_core` | 31.90 | `vm_exec_core.lto_priv.0` | 34.91 |
| `vm_call_iseq_setup_normal_0start_0params_0locals` | 4.56 | same (`.lto_priv.0`) | 4.97 |
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

**Analysis.** `vm_exec_core` — the interpreter's giant computed-goto dispatch loop — dominates both
arms at ~32–35%. That single function is *why* Ruby responds to layout optimisation where the
gcc-built databases did not: it is one enormous, branch-dense body with poor I-cache locality,
precisely the shape BOLT and AutoFDO exist to re-lay-out.

Seven of base's top-15 functions **do not appear** in afdoltob's profile. They were not eliminated,
they were **inlined into their callers** — `rb_wb_protected_newobj_of` (write-barrier allocation),
`rb_id_table_lookup`, `rb_call0`, `find_table_entry_ind`, `callable_method_entry_or_negative`,
`vm_yield_setup_args`, `vm_sendish`. This must be read as *work moved*, not work removed, and it is
the mechanism behind the −1.83% instruction count and −4.24% branch count: fewer call-site
transitions, fewer prologues/epilogues, fewer indirect jumps.

The profile is also **more concentrated**: a larger share of time sits in the hot dispatch loop and
less in small helper functions scattered across the binary. Fewer, larger hot regions is the same
phenomenon the I-cache counters report from the hardware side.

**Caveat on this table.** `afdoltob` is BOLT-rewritten and carries no debug sections (11.8 MB vs
43 MB), and LTO privatisation adds `.lto_priv.0` suffixes. Symbolisation works for both arms — the
verification condition — but source-line annotation is unavailable for `afdoltob`, and name-by-name
diffing requires the inlining caveat above.

---

## 3. `perf c2c` — a clean null, as expected

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

**Analysis.** There is no cross-core sharing problem to find, in either arm, and FDO does not
change one. Total HITM is ~9,000 events against 14.8M sampled loads — 0.06%, which is noise.

The finding that settles it: the **#1 shared cache line, carrying 21.9% of all HITM in base and
23.9% in afdoltob, is `perf_mmap__read_head` / `perf_mmap__read_init` in the `perf` binary
itself** — the profiler's own ring buffer, on CPU 127. Every remaining entry is an unresolved
kernel address (`0xffffffff8cd9…`, scheduler/futex-class contention) spread across both nodes.
**Not one Ruby symbol appears in the shared-line table of either arm.**

That is the correct answer for this workload, not a failed measurement. The 128 workers are
separate processes: no shared Ruby heap, and after the per-worker copies no shared SQLite file
either. What they genuinely share is the ruby `.text`/`.rodata`, which is read-only and clean —
shared loads, never HITM, because HITM requires a *store* to a line another core holds. NUMA
behaviour is also healthy and unchanged: 99.5% of LLC misses go to local DRAM in both arms.

**One real non-HITM difference, worth noting:**

| | base | afdoltob | change |
|---|---|---|---|
| Store operations | 14,950,335 | 14,920,199 | — |
| Store L1D hit | 14,233,094 | 14,547,944 | +2.2% |
| **Store L1D miss** | **717,241** | **372,255** | **−48.1%** |
| Store L1D miss rate | 4.80% | 2.49% | halved |
| Load L1D hit | 4,031,132 | 4,147,045 | +2.9% |
| Load L2 hit | 953,507 | 878,193 | −7.9% |
| Load LLC hit | 2,293,531 | 2,221,865 | −3.1% |

Store L1D misses are **halved**. The likely cause is the same inlining seen in §2: far fewer call
frames means much less stack push/pop traffic, so the store stream becomes markedly more
L1-resident. Loads shift the same direction — more L1 hits, fewer L2 and LLC hits. So the
optimisation improves *data*-side locality as a second-order effect, not only instruction-side.

---

## 4. Throughput cross-check

Taken from the per-worker logs, discarding each worker's 3 warmup iterations:

| arm | mean | median | p10 | p90 | iterations |
|---|---|---|---|---|---|
| base | 5627.8 ms | 5610 ms | 5502 | 5734 | 9,143 |
| afdoltob | **5259.2 ms** | 5246 ms | 5090 | 5385 | 9,396 |

**+7.01% on the mean, +6.94% on the median** under 128-way load.

This is the number that closes the loop: `afdoltob` executes 1.83% fewer instructions at 1.81%
lower IPC, and still completes 7% more work. Compare **+10.6%** for railsbench single-core pinned
in the campaign — the loaded figure is lower because with 128 workers on 64 physical cores, SMT
siblings share the L1I/L2 and the back end, so part of the front-end win is diluted. Both numbers
are real; they describe different operating points.

Note also iteration time roughly doubles versus the unloaded single-core figure (2635 → 5610 ms),
exactly as expected when 128 workers share 64 physical cores.

---

## Conclusion

**The +13.04% is a front-end/code-layout win, confirmed by hardware counters.** I-cache tag stalls
fall 45%, front-end bound falls 6.31 pp against a worst-case pass spread of 1.12 pp, and every
corroborating front-end counter (I-cache misses, undelivered uops, iTLB walks, L2 code reads)
moves the same way. The mechanism is visible in the profile: a single huge dispatch loop
(`vm_exec_core`, ~32–35% of all cycles) plus aggressive inlining that removes seven of base's
top-15 helper functions, cutting instructions 1.83% and branches 4.24%.

**This also explains why Ruby behaves oppositely to the databases.** On MariaDB and PG, BOLT over
gcc PGO+LTO was neutral-to-negative. Those engines do not have a 35%-of-cycles, branch-dense,
I-cache-hostile interpreter loop to re-lay-out; Ruby does. The gain here is of a kind those
workloads had little of to recover.

**What it is not:** it is not a cache-coherence or NUMA effect. c2c is a null in both arms, and the
largest shared line is the profiler observing itself.

**Costs and limits.** Branch misses rise 6.7% (rate 5.46% → 6.09%) and the binding constraint
shifts to the back end (+5.13 pp) and speculation (+1.86 pp) — that is where any further gain
would have to be found. And all of this characterises a **loaded 128-worker deployment at +7.0%**,
not the single-core-pinned configuration where the headline +13.04% was measured.

## Artefacts

On the box under `/home/ubuntu/ruby-fdo/perf/` (and `perf-mir/` for the reverse-order pass):
`stat-{base,afdoltob}[-mir].txt`, `report-{base,afdoltob}.txt`, `c2c-{base,afdoltob}.txt`,
`timeline-{base,afdoltob}.log`, `workers-{base,afdoltob}/w*.log`, plus the raw
`record-*.data` (1.0–1.2 GB each) and `c2c-*.data` (2.5 GB each). Text reports copied to
`~/ruby-fdo/perf/`. Driver: `ruby-perf.sh`.
