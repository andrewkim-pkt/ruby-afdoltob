# Ruby FDO — exact build, profiling and benchmark recipe

Ruby 3.4.11 · gcc 15.2.0 · m6i.metal (Ice Lake) · Ubuntu 26.04 · llvm-bolt 21.1.8

Every command below is what actually ran. Source of truth: `ruby-env.sh`, `ruby-build.sh`,
`ruby-campaign.sh`, `ruby-perf.sh`.

---

## 0. Toolchain

```bash
CC=gcc-15                 # Ubuntu 26.04 default: 15.2.0-16ubuntu1 -> dumpfullversion 15.2.0
CXX=g++-15
# Pinned and asserted at BOTH stage time and build time: an apt upgrade to 15.3 would otherwise
# silently retrain every profile on a different compiler.
GCC_WANT=15.2.0
```

| tool | version | source |
|---|---|---|
| gcc | 15.2.0 | distro default, no source bootstrap needed |
| llvm-bolt / perf2bolt | 21.1.8 | `apt install llvm-bolt` |
| create_gcov | autofdo HEAD | built from source (see §6) |
| perf | 7.0.0 | `linux-tools-$(uname -r)` |
| Ruby | 3.4.11 | cache.ruby-lang.org |

---

## 1. Flag building blocks

```bash
BASE_CFLAGS="-O3 -march=native -mtune=native -fno-omit-frame-pointer -g"
LTO_FLAGS="-flto=32 -ffat-lto-objects"
BOLT_LDFLAGS="-Wl,--emit-relocs -Wl,-q"
```

Why each piece is non-negotiable:

* **`-O3 -march=native -mtune=native`** — the common baseline. Every prior campaign here quoted FDO
  gain against this, not against distro defaults; a weaker baseline inflates the gain and makes the
  numbers non-comparable.
* **`-fno-omit-frame-pointer`** — required, not stylistic. AutoFDO and BOLT both need walkable
  stacks from `perf`, and `perf record --call-graph fp` in §7 depends on it. Omitting it degrades
  the profile *silently* instead of failing.
* **`-g`** — keeps DWARF for `perf annotate` and for AutoFDO's line/discriminator mapping.
* **`-ffat-lto-objects`** — emits both IR and real machine code per object, so the tree stays
  usable by tools that don't understand LTO IR.
* **`-Wl,--emit-relocs -Wl,-q`** — **llvm-bolt refuses the binary outright without relocations.**
  Only applied to the four `*b` arms.

---

## 2. The nine arms — exact resulting flags

`mode` selects the profiling scheme; `lto`/`bolt` are additive layers.

| arm | mode | lto | bolt | final CFLAGS | final LDFLAGS |
|---|---|---|---|---|---|
| `base` | plain | – | – | `$BASE` | *(empty)* |
| `pgo` | pgo | – | – | `$BASE` + profile-use set | *(empty)* |
| `pgolto` | pgo | ✓ | – | `$BASE $LTO` + profile-use set | `$LTO` |
| `pgoltob` | pgo | ✓ | ✓ | `$BASE $LTO` + profile-use set | `$LTO $BOLT_LD` |
| `pgob` | pgo | – | ✓ | `$BASE` + profile-use set | `$BOLT_LD` |
| `afdo` | afdo | – | – | `$BASE -fauto-profile=… -Wno-missing-profile` | *(empty)* |
| `afdolto` | afdo | ✓ | – | `$BASE $LTO -fauto-profile=… -Wno-missing-profile` | `$LTO` |
| `afdoltob` | afdo | ✓ | ✓ | `$BASE $LTO -fauto-profile=… -Wno-missing-profile` | `$LTO $BOLT_LD` |
| `afdob` | afdo | – | ✓ | `$BASE -fauto-profile=… -Wno-missing-profile` | `$BOLT_LD` |

where **profile-use set** =
`-fprofile-use -fprofile-dir=$PROF -fprofile-correction -Wno-missing-profile -Wno-error=coverage-mismatch -Wno-coverage-mismatch`

The two no-LTO BOLT arms (`pgob`, `afdob`) exist to separate "BOLT does nothing" from "BOLT does
nothing *on top of LTO*". They are what revealed that BOLT adds only +0.8% to PGO alone but +4.1%
to AutoFDO alone.

---

## 3. The configure invocation (identical for every pass of every arm)

```bash
"$SRC/configure" \
    --prefix="$PFX" \
    --disable-install-doc \
    --enable-shared=no \
    CC="$CC" CXX="$CXX" \
    CFLAGS="$cflags $extra_cflags" \
    LDFLAGS="$ldflags $extra_ldflags" \
    optflags="" debugflags=""
make -j128
rm -rf "$PFX" && make install
```

* **`optflags="" debugflags=""`** — critical. Ruby's configure otherwise injects its *own* `-O3`
  and `-g` after ours, which would override the arm's optimisation flags. Emptying them makes
  `CFLAGS` authoritative.
* **`--enable-shared=no`** — static libruby linked into the `ruby` executable. Required for the
  BOLT arms to be meaningful: with a shared build the hot interpreter code would live in
  `libruby.so`, and BOLT applied to the thin `ruby` driver would optimise nothing.
* **`--prefix`** under the campaign root, never `/opt` — no sudo anywhere in the build path.

---

## 4. `base` — one pass

```bash
configure_and_make "" ""        # 1m00s at -j128
```

---

## 5. PGO arms — two passes with a wipe between

```bash
# Pass 1: instrumented
configure_and_make "-fprofile-generate -fprofile-dir=$PROF" "-fprofile-generate"

prime                           # install gems / set up benchmarks, UNPROFILED (see §9)
rm -f "$PROF"/*.gcda            # <-- the wipe

train                           # the profiled training run (see §9)

# Pass 2: consume the profile
configure_and_make \
  "-fprofile-use -fprofile-dir=$PROF -fprofile-correction \
   -Wno-missing-profile -Wno-error=coverage-mismatch -Wno-coverage-mismatch" ""
```

Why the wipe is mandatory: Ruby runs its own freshly built `miniruby` *during its own build*, and
`prime` then runs bundler, rubygems and Rails migrations. Without `rm -f *.gcda` the profile is
dominated by Ruby compiling its stdlib and resolving gems rather than by the workload.

Why each pass-2 flag:

| flag | reason |
|---|---|
| `-fprofile-use` | consume the `.gcda` counters |
| `-fprofile-dir=$PROF` | counters kept outside the build tree, which pass 2 wipes |
| `-fprofile-correction` | training is multi-process; gcc otherwise *errors* on inconsistent counters |
| `-Wno-missing-profile` | **required** — see §11 |
| `-Wno-error=coverage-mismatch -Wno-coverage-mismatch` | LTO changes unit layout between passes |

---

## 6. AutoFDO arms — sample an unmodified binary

```bash
# Pass 1: a plain build, because AutoFDO samples a WORKING binary (no instrumentation)
configure_and_make "" ""

prime

# Sample with LBR. -b gives branch records, which is what create_gcov needs for edge counts.
perf record -o "$PROF/perf.data" -e cycles:u -b -- bash -c "$TRAIN_CMD"

create_gcov --binary "$PFX/bin/ruby" \
            --profile "$PROF/perf.data" \
            --gcov    "$PROF/ruby.gcov" \
            -gcov_version=2

# Pass 2: consume it
configure_and_make "-fauto-profile=$PROF/ruby.gcov -Wno-missing-profile" ""
```

Observed sizes: 243 MB `perf.data` → 2.95 MB `ruby.gcov`.

`create_gcov` build (needed once; not packaged):

```bash
git clone --recursive https://github.com/google/autofdo.git
cmake -G Ninja -DCMAKE_BUILD_TYPE=Release -DENABLE_TOOL=GCOV \
      -DCMAKE_POLICY_VERSION_MINIMUM=3.5 ..        # <-- required on Ubuntu 26.04
ninja && sudo install -m755 create_gcov dump_gcov profile_merger /usr/local/bin/
```

`-DCMAKE_POLICY_VERSION_MINIMUM=3.5` is required because cmake 4.2 dropped pre-3.5 policy support
and autofdo's vendored `third_party/glog` still declares one; without it configure fails outright.
Also needs `protobuf-compiler libprotobuf-dev libgflags-dev libgoogle-glog-dev libunwind-dev`.

`-gcov_version=2` must match the consuming gcc. A mismatch surfaces as a bland *"profile not
found"* from gcc rather than a version error — which is how the MariaDB campaign lost an afternoon.

---

## 7. BOLT — applied last, after the final link

Runs only for `pgoltob`, `pgob`, `afdoltob`, `afdob`, and only *after* that arm's final
`make install`.

```bash
cp "$PFX/bin/ruby" "$PFX/bin/ruby.prebolt"      # keep the pre-BOLT binary for A/B

prime

# Sample with branch stacks. -j any,u = any branch type, user space only.
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

### Every BOLT option, and what it is for

| option | what it does | why here |
|---|---|---|
| `-data=` | the `perf2bolt`-converted profile | required input |
| `-reorder-blocks=ext-tsp` | lays out basic blocks by the extended TSP model | **the main win.** Straightens the hot paths through `vm_exec_core`, the 35%-of-cycles dispatch loop |
| `-reorder-functions=hfsort+` | groups hot functions together by call affinity | packs the hot interpreter + method-dispatch set into fewer I-cache/iTLB pages → the −10% iTLB walks |
| `-split-functions` | splits each function into hot and cold fragments | lets cold paths leave the hot text region entirely |
| `-split-all-cold` | splits functions with *no* profile coverage as cold too | unsampled code is cold by definition; keeps it out of the hot region |
| `-split-eh` | moves exception-handling paths to cold | Ruby's C code is EH-heavy but EH is almost never taken |
| `-icf=1` | identical code folding | deduplicates identical function bodies, shrinking hot text |
| `-use-gnu-stack` | emit a GNU-style stack segment | keeps the rewritten binary loadable on this toolchain |
| `-dyno-stats` | print before/after dynamic instruction stats | lets BOLT's claimed improvement be read from the build log |

Effect visible in the artefacts: the `*b` arms show a **split hot/cold `.text`** (e.g. `afdoltob`
1,092,331 + 784,912 bytes) with `__hot_start`/`__hot_end` set, and drop to ~11.8 MB on disk from
~43 MB because llvm-bolt discards debug sections. Harmless for measurement, but it means **no
source-line annotation for the BOLT arms** — and LTO adds `.lto_priv.0` symbol suffixes, so a
per-function diff against `base` must be read as *work moved*, not *work vanished*.

---

## 8. Build order and cost

```bash
./ruby-build.sh base && ./ruby-sharegems.sh base    # base owns the shared gem set
./ruby-all.sh pgo pgolto pgoltob pgob afdo afdolto afdoltob afdob
```

Strictly serial: an arm compiling at `-j128` beside an arm being `perf`-sampled would contaminate
the profile. `ruby-all.sh` skips any arm whose `FINGERPRINT` md5 matches its installed binary, so a
reboot costs one arm, not the run.

| arm | time | arm | time |
|---|---|---|---|
| base | 1m00s | afdo | 4m29s |
| pgo | 4m57s | afdolto | 7m50s |
| pgolto | 8m16s | afdoltob | 9m58s |
| pgoltob | 10m24s | afdob | 6m29s |
| pgob | 6m45s | | |

---

## 9. Benchmark process details

### 9.1 The harness

yjit-bench, `--category=headline` = 16 server-shaped benchmarks: `activerecord chunky-png
erubi-rails hexapdf liquid-c liquid-compile liquid-il liquid-render lobsters mail psych-load
railsbench rubocop ruby-lsp sequel shipit`.

Iteration control (`harness/harness.rb:4-10`) — the loop runs
**until `num_itrs >= WARMUP_ITRS + MIN_BENCH_ITRS` AND `total_time >= MIN_BENCH_TIME`**:

```bash
WARMUP_ITRS      # discarded iterations
MIN_BENCH_ITRS   # minimum measured iterations
MIN_BENCH_TIME   # minimum total seconds
```

What `run_benchmarks.rb` does per invocation, observed from its own logs:

```bash
bundle check 2> /dev/null || bundle install              # per benchmark, per ruby
setarch x86_64 -R taskset -c 41 <ruby> -I harness benchmarks/<b>/benchmark.rb
```

* `setarch -R` disables ASLR → stable symbolisation and less run-to-run variance.
* `taskset -c N` pins to one CPU → the campaign measured **single-core** performance.
* The harness also writes `no_turbo=1` and `min_perf_pct=100` so frequency is fixed.

### 9.2 Three distinct workload roles

| role | iterations | purpose |
|---|---|---|
| **prime** | `WARMUP_ITRS=0 MIN_BENCH_ITRS=1` | install gems, run Rails migrations — **unprofiled** |
| **train** | `WARMUP_ITRS=1 MIN_BENCH_ITRS=2` | the profiled run; coverage matters, precision does not |
| **measure** | `--warmup=5 --bench=8` | the result |

`prime` exists for correctness, not speed. The harness installs each benchmark's gems *and runs
`db:migrate db:seed`* on first use. Profiling that would train the arm on bundler, rubygems and
ActiveRecord migrations instead of on the benchmark. Train and BOLT/AutoFDO sampling each run
`prime` first.

Training command (both PGO training and AutoFDO/BOLT sampling target it):

```bash
cd $YJIT_BENCH && ./run_benchmarks.rb --category=headline \
    --warmup=1 --bench=2 -e train::$RUBY_BIN --out-name=train-$ARM
```

### 9.3 Shared gems — a correctness requirement

All nine arms share one gem set built by `base` (444 MB), via a symlink of
`<prefix>/lib/ruby/gems` re-established after **every** `make install`.

Not an optimisation. yjit-bench compiles native extensions **with the ruby under test**, so the PGO
arms would build extensions with `-fprofile-generate` — writing stray `.gcda` and polluting the
very profile being collected — and the LTO arms with `-flto`. Each arm would then run *different
extension code*, and the measured difference would no longer be attributable to the ruby binary.

**Consequence for quoting results: the gain is FDO of the Ruby core only.** Gem native code is
identical across arms and unoptimised, so whole-stack FDO should yield more than +13%, not less.

### 9.4 Measurement — mirrored and checkpointed

```bash
./run_benchmarks.rb --name_filters=<bench> --warmup=5 --bench=8 \
    --interleave --pvalue \
    -e base::.../ruby-base/bin/ruby  -e pgo::.../ruby-pgo/bin/ruby  … \
    --out-name=$CAMP-$dir-$bench
```

* `--interleave` — within a benchmark the arms run round-robin, so slow drift hits all arms equally.
* **forward then reverse arm order**, per-arm mean of the two. Residual order effects enter with
  opposite sign and cancel. Achieved spread: ≤0.47%.
* **one invocation per (direction, benchmark)** = 32 total. yjit-bench writes its JSON only at the
  *end* of a run, so a single invocation over 16 benchmarks loses everything on a reboot — which
  happened once. Checkpoint interval is now ~2–3 min and completed benchmarks are skipped on resume.
* `--out-name` writes to the **yjit-bench repo root**, ignoring directories (that's `--out_path`).
  Looking in `data/` silently finds nothing.

---

## 10. perf characterisation runs (`ruby-perf.sh`)

Separate from the build. 128 workers, one pinned per vCPU, railsbench, each with a private 640 KB
copy of the benchmark (shared SQLite would be reseeded concurrently by all 128).

Prep, re-asserted every run because none of it survives a reboot:

```bash
sudo sh -c 'echo 1   > /sys/devices/system/cpu/intel_pstate/no_turbo'
sudo sh -c 'echo 100 > /sys/devices/system/cpu/intel_pstate/min_perf_pct'
sudo sysctl -w kernel.nmi_watchdog=0
sudo sysctl -w kernel.perf_event_paranoid=0      # stock Ubuntu 26.04 ships 4, which blocks all sampling
```

Three **non-overlapping** 30 s windows, 10 s gaps (all three program the same PMU; concurrent use
forces multiplexing):

```bash
perf stat -a -e cycles,ref-cycles,instructions,branches,branch-misses,\
topdown-retiring,topdown-fe-bound,topdown-be-bound,topdown-bad-spec,\
icache_64b.iftag_stall,icache_64b.iftag_miss,idq_uops_not_delivered.core,\
itlb_misses.walk_pending,l2_rqsts.code_rd_miss -- sleep 30

perf record -a -F 999 --call-graph fp -o record-$ARM.data -- sleep 30

perf c2c record -a --ldlat 30 -o c2c-$ARM.data -- sleep 30
```

`ref-cycles` is there to *verify* rather than assume equal frequency between arms
(`cycles/ref-cycles = 1.0000` in all four windows). `--call-graph fp` is valid only because of
`-fno-omit-frame-pointer` in §1.

Rendering:

```bash
perf report --stdio --no-children --percent-limit 0.4 -i record-$ARM.data
perf c2c report -NN --stdio -i c2c-$ARM.data
```

### The three different `perf record` uses — do not confuse them

| purpose | command | why that event |
|---|---|---|
| AutoFDO profile | `perf record -e cycles:u -b` | `-b` = LBR branch records; `create_gcov` needs edge counts |
| BOLT profile | `perf record -e cycles:u -j any,u` | `-j any,u` = branch stacks for all user branch types |
| characterisation | `perf record -a -F 999 --call-graph fp` | system-wide time attribution, not a profile to feed back |

---

## 11. Gotchas that cost real time

1. **`-Wno-missing-profile` is mandatory**, not cosmetic. Ruby's `configure` has a *"checking
   whether CFLAGS is valid"* probe that compiles a trivial file and rejects the **entire** flag set
   if anything reaches stderr. Under `-fprofile-use`/`-fauto-profile` that file has no counters,
   gcc emits `-Wmissing-profile`, and configure dies with `something wrong with CFLAGS=…`. Killed
   the first `pgo` arm at 3m48s.
2. **Ruby block-buffers `$stdout` to a file.** Worker iteration lines sat unflushed for 10+ minutes,
   making a log-based readiness gate read 0/128 on a box provably saturated at load 128. Fix:
   `RUBYOPT="-r<file-setting-\$stdout.sync=true>"`. The only lines that *did* appear were those
   immediately before a `system()` call, because Ruby flushes before spawning — which is what
   identified the cause.
3. **`pkill -f <pattern>` over ssh matches the ssh command line itself** and kills the session. Use
   an obfuscated pattern (`P="ruby-buil"; pkill -f "${P}d.sh"`).
4. **yjit-bench warns `'base' and 'pgo' appear identical`** — it compares `ruby -v` strings, which
   are necessarily identical across arms. Labelling heuristic only; the md5s in each campaign
   MANIFEST are the real discriminator.
5. **`--out-name` ignores directories** (§9.4).
6. **create_gcov gcov-version mismatch** reports "profile not found", not a version error (§6).
