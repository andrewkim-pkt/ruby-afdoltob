# Ruby 3.4.11 FDO campaign — PGO / AutoFDO / LTO / BOLT on gcc 15.2.0

**Campaign** `campaign-20261013-083459` · 2026-10-13 · all 9 arms, mirrored (forward + reverse)

## Platform

| | |
|---|---|
| Box | **m6i.metal** — 2S Intel Xeon Platinum 8375C @ 2.9 GHz (Ice Lake), 128 vCPU, 2 NUMA nodes, 503 GiB |
| OS | Ubuntu 26.04 LTS, kernel 7.0.0-1006-aws |
| Compiler | **gcc 15.2.0** (`gcc-15` 15.2.0-16ubuntu1, Ubuntu's default — no source bootstrap) |
| Post-link | llvm-bolt 21.1.8 · AutoFDO `create_gcov` built from source |
| Ruby | 3.4.11 |
| Baseline flags | `-O3 -march=native -mtune=native -fno-omit-frame-pointer -g` |
| Workload | yjit-bench `--category=headline`, 16 benchmarks, warmup 5 / bench 8 |

This is **not** the r8i 48xl Granite Rapids box originally scoped; quote as Ice Lake m6i.metal and
do not splice into the GNR-based PG/MySQL/MariaDB tables.

## Headline result

Speedup vs `base`, geometric mean across 16 benchmarks. MIRRORED = geomean of the forward and
reverse arm-ordering passes; `spread` = |fwd − rev|, the practical uncertainty.

| arm | fwd | rev | **MIRRORED** | spread |
|---|---|---|---|---|
| base | +0.00% | +0.00% | — | 0.00% |
| pgo | +5.94% | +5.85% | **+5.89%** | 0.10% |
| pgolto | +8.41% | +8.44% | **+8.43%** | 0.03% |
| pgoltob | +11.36% | +11.35% | **+11.35%** | 0.01% |
| pgob | +6.70% | +6.64% | **+6.67%** | 0.06% |
| afdo | +6.96% | +6.87% | **+6.91%** | 0.09% |
| afdolto | +9.16% | +9.19% | **+9.17%** | 0.03% |
| **afdoltob** | **+13.27%** | **+12.80%** | **+13.04%** | 0.47% |
| afdob | +10.97% | +11.05% | **+11.01%** | 0.08% |

**Recommendation: `afdoltob` (AutoFDO + LTO + BOLT), +13.0%.** `pgoltob` at +11.4% is the
PGO-based alternative if sampling infrastructure is unavailable.

Confidence is unusually high for this kind of campaign: the two orderings agree to within 0.5%
on every arm, no benchmark regresses in any arm, and the worst per-benchmark noise in the
baseline was 1.8% (`lobsters`) against effects of 8–21%.

## What each layer actually contributes

| step | PGO path | AutoFDO path |
|---|---|---|
| FDO alone | +5.89% | +6.91% |
| + LTO | +8.43% (**+2.5**) | +9.17% (**+2.3**) |
| + LTO + BOLT | +11.35% (**+2.9**) | +13.04% (**+3.9**) |
| FDO + BOLT, no LTO | +6.67% (**+0.8**) | +11.01% (**+4.1**) |

Three findings worth keeping:

**1. BOLT helps on Ruby — unlike on gcc-built databases.** On MariaDB and PG, BOLT stacked on
PGO+LTO was neutral-to-negative. Here it is the single largest increment on both paths (+2.9% on
`pgolto`, +3.9% on `afdolto`). The plausible reason is structural: the Ruby interpreter is a large
computed-goto dispatch loop with poor I-cache locality, so basic-block and function layout has far
more to recover than in a database engine whose hot path is already compact. This is why the
`pgob`/`afdob` arms were worth building.

**2. BOLT's benefit depends on what it is layered on.** It adds only **+0.8%** to PGO alone, but
**+4.1%** to AutoFDO alone. gcc's own instrumented-PGO layout is already good, leaving BOLT little
to improve; AutoFDO's sampled profile is coarser at basic-block level, so BOLT has real work left
to do. Note `afdob` (+11.0%, no LTO) nearly matches `pgoltob` (+11.4%) — i.e. AutoFDO + BOLT gets
you most of the way without LTO's build-time cost at all.

**3. AutoFDO beats PGO at every level** (+1.0, +0.7, +1.7 points at FDO / +LTO / +LTO+BOLT). That
is the reverse of the MySQL/MariaDB result. It also makes AutoFDO doubly attractive here, since it
trains from `perf` samples on an unmodified binary rather than requiring an instrumented build.

## Per-benchmark mirrored speedup vs base (%)

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

## Absolute mean times, ms (mean of both passes)

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

## Binaries

| arm | build | md5 |
|---|---|---|
| base | 1m00s | `6c2553ec54001f8728ee5dda48c1870a` |
| pgo | 4m57s | `48c9f74184aefe151bebd30d17139f3d` |
| pgolto | 8m16s | `5a06fe0537047eafb867323788611ce2` |
| pgoltob | 10m24s | `142d6389db35ff8518f28727a2d659e1` |
| pgob | 6m45s | `4eddff00bc5db9109929ce4767247648` |
| afdo | 4m29s | `cbe95001de7d25a926ebb45fae2154f2` |
| afdolto | 7m50s | `49ecf0eff88edc71c5d2dcd15352084f` |
| afdoltob | 9m58s | `d656566bec6b20f4baa4880e4beb0d83` |
| afdob | 6m29s | `139b892d2a18fd61b19d1eb11f6ab934` |

Installed under `/home/ubuntu/ruby-fdo/inst/ruby-<arm>/`, each with a `FINGERPRINT` recording arm,
versions, exact flags and md5. All nine md5s are distinct.

## Caveats — read before quoting these numbers

**1. The workload is a stand-in.** The request named a *GCP Ruby workload* but it was never
specified, so training and measurement both used yjit-bench's headline set. It is a defensible
proxy for a Ruby service (4 Rails apps, ActiveRecord/Sequel, Liquid templating, rubocop, ruby-lsp)
and `railsbench`/`lobsters`/`shipit` are the closest analogues at +9–11%. But FDO results are only
as representative as the training workload. **Retrain against the real application before
committing to a number** — it is a two-variable change (`TRAIN_CMD`/`MEAS_CMD`).

**2. This measures the Ruby core only.** All arms share one gem set built by `base`, so native gem
extensions are identical across arms and unoptimised. This was deliberate: yjit-bench compiles
extensions *with the ruby under test*, so the PGO arms would otherwise build extensions with
`-fprofile-generate` (polluting the profile being collected) and the LTO arms with `-flto`, leaving
each arm running different extension code. Applying FDO to the whole stack should yield **more**
than +13%, not less.

**3. Interpreter mode, not YJIT.** YJIT is Rust-compiled, so gcc-side FDO cannot move the code it
generates; these gains apply to the interpreter, GC and C runtime. A YJIT-enabled deployment will
see a smaller fraction of this.

**4. Single platform, n=1 campaign.** One box, one Ruby version. The mirrored spread (≤0.47%)
establishes *reproducibility within the run*, not cross-platform transfer. Ice Lake's weaker front
end likely flatters layout optimisations relative to Granite Rapids.

## Reproducing

```bash
cd /home/ubuntu/ruby-fdo/bin
./ruby-stage.sh                                   # toolchain, create_gcov, ruby src, perf setup
./ruby-build.sh base && ./ruby-sharegems.sh base  # base owns the shared gem set
./ruby-all.sh pgo pgolto pgoltob pgob afdo afdolto afdoltob afdob
./ruby-campaign.sh                                # mirrored fwd + rev, checkpointed per benchmark
ruby report.rb res/<campaign>
```

Two non-obvious requirements, both of which cost time to find:

* **`-Wno-missing-profile` is mandatory** on the `-fprofile-use` and `-fauto-profile` builds.
  Ruby's `configure` has a "checking whether CFLAGS is valid" probe that compiles a trivial file
  and rejects the entire flag set if anything reaches stderr; with no counters for that file gcc
  warns, and configure dies with `something wrong with CFLAGS=`.
* **`create_gcov` needs `-DCMAKE_POLICY_VERSION_MINIMUM=3.5`** on Ubuntu 26.04 (cmake 4.2 dropped
  pre-3.5 policy support, which autofdo's vendored glog still declares), plus protobuf/gflags/glog
  dev packages.

The box rebooted **four times** during this work (01:17Z, 03:35Z, 05:50Z, ~09:30Z), each time with
a new public IP, despite reporting `instance-life-cycle: on-demand`. The measurement survived only
because `ruby-campaign.sh` checkpoints one JSON per (direction, benchmark) and skips completed
ones — yjit-bench writes JSON only at the end of a run, so the original single-invocation design
lost all 16 benchmarks at once.
