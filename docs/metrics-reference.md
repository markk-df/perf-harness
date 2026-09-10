# Metrics Reference

Every number the harness records for a repetition, explained in plain English:
what it is, how it is measured, and how much you can trust it for an A/B
comparison.

> This is the last step of the path. First **author a manifest**
> ([`docs/manifest-reference.md`](manifest-reference.md)), then **run it** (the harness [`README.md`](../README.md)), then
> use this document to **turn the results into an analysis report** — the
> "Producing the report" section below has the exact commands.

The metrics come from two places:

- **ETL-derived metrics** — extracted from the PerfView/ETW trace by
  [`tools/EtlPerfReport`](../tools/EtlPerfReport) after the workload finishes. These describe the *work*
  the program did (allocations, garbage collections, CPU consumed).
- **Harness intrinsics** — timing and CPU-clock numbers the harness itself
  records around each run ([`lib/Run.ps1`](../lib/Run.ps1)).

## Methodology and terminology

Before the metrics, here is exactly *what* is being measured and *how*, in plain
English. The rest of the document assumes these words.

### The vocabulary

- **Workload** — one application command run against a prepared input. The
  examples here use three: `parse`, `analyze`, and `render`. A workload is
  *what the program does*.

- **Variant** — one specific build of the tool, i.e. a particular git branch /
  commit. Examples: `base` (the unchanged starting point), `srv` (same code but
  Server garbage collection turned on), `fast-parse` (an algorithm change to the
  parse command), `fast-analyze` (an algorithm change to the analyze command). A variant
  is *the version of the code being tested*.

- **Comparison** — a head-to-head test of **two variants running the same
  workload**. One variant is named the **baseline** (the "before"), the other
  the **candidate** (the "after"). Example: the `gc-parse` comparison runs the
  `parse` workload under `base` versus `srv`. A comparison is *the question we
  are asking* ("does this change help?").

- **Baseline** and **candidate** — the two variants inside a comparison. The
  baseline is what we measure against; the candidate is the change we hope is
  better.

- **Arm** — one side of a comparison. Every comparison has two arms: the
  **baseline arm** (all the runs of the baseline variant) and the **candidate
  arm** (all the runs of the candidate variant). "Arm" is borrowed from medical
  trials, where two groups of patients — the two arms — get different treatments
  and are compared. Here the two "treatments" are the two variants.

- **Rep** (repetition) — a single execution of one variant on one workload,
  producing one complete set of numbers. Because a single run can be thrown off
  by a passing background task or a thermal blip, we run several reps and combine
  them.

- **Cell** — the unique address of one measurement. It is the four-part
  coordinate **(comparison, variant, workload, rep)**. Read left to right it
  says: *inside which question, which version of the code, doing which command,
  on which repetition.* For example:

  | Cell | Reads as |
  |---|---|
  | `(gc-parse, base, parse, 1)` | 1st rep of the **base** build running **parse**, as the baseline side of the **gc-parse** question |
  | `(gc-parse, srv, parse, 2)` | 2nd rep of the **Server-GC** build running **parse**, as the candidate side of the same question |
  | `(parse-change, fast-parse, parse, 3)` | 3rd rep of the **fast-parse** build running **parse**, as the candidate side of the **parse-change** question |

  Every row in `results.jsonl` is exactly one cell. (`workload` is usually
  implied by the comparison, but it is stored on every cell so the data is
  self-describing.)

- **Oracle** — the frozen, known-correct output for a workload, captured once and
  never changed. After every rep, the program's output is compared **byte for
  byte** against the oracle. `oracle=PASS` means the output was identical, which
  proves the variant did not change *what* the program produces — only *how fast*
  or *how efficiently* it produced it. A comparison is only meaningful when both
  arms pass the oracle; otherwise you would be comparing two different programs.
  If **any** rep in a comparison fails the oracle, that whole comparison is marked
  `INVALID:oracle` and its delta is withheld — a single byte-divergence means the
  candidate is no longer proven to do identical work, so the improvement cannot be
  trusted. The failing rep is not swept under the rug: it is listed as an *oracle
  incident* (see below) so the divergence can be investigated.

- **Seed** — the frozen *input* the workspace is reset to before every rep, stored
  as a fixed git commit. It is the pipeline state that command would normally
  receive. This is what lets any workload run on its own, in any order, without
  first running the earlier pipeline stages: the input comes from a checkout, not
  from a live previous run.

- **Round** — one full pass through *every* comparison at a given rep number.
  **Round-robin** scheduling means we do rep 1 of everything, then rep 2 of
  everything, then rep 3, rather than all reps of one comparison before moving on.
  The payoff: if the run is aborted early, every comparison has been measured a
  roughly equal number of times, so nothing is left with zero data.

- **Warmup** — a first, **discarded** run of each (variant, workload) before real
  measurement begins. It primes the OS disk cache and JIT so the measured reps
  start from a warm, representative state instead of a cold one.

- **Cooldown** — a short pause between reps so heat and background activity from
  the previous run don't leak into the next one.

- **Frequency stabilization** — turbo boost is disabled for the whole run so the
  CPU clock holds steady. This removes one big source of run-to-run noise. (It
  also makes wall-clock times *longer* than normal, which is one reason wall
  time is not used for the headline result — see the trust tiers below.)

### How one rep is measured

For each cell the harness does the same fixed sequence:

1. **Reset** the workspace to the workload's seed commit (identical input every
   time).
2. **Warm up** once per (variant, workload) — this first result is thrown away.
3. **Collect**: run the workload under PerfView, which records an ETW trace of
   allocations, garbage collections, CPU samples, and hardware counters.
4. **Extract**: [`tools/EtlPerfReport`](../tools/EtlPerfReport) reads the trace and produces the metrics in
   this document.
5. **Check the oracle**: compare the output byte-for-byte to the frozen correct
   output; record PASS/FAIL.
6. **Record** one line (one cell) in `results.jsonl` and `results.csv`.
7. **Cool down**, then move to the next cell.

### How reps become a result

Within a comparison, each arm has several reps (three, in a 10-hour run). The
harness takes the **median** of the reps for each metric — the middle value after
sorting — not the average. With only a few reps, one bad rep (a background task
stealing the CPU, a thermal spike) would visibly drag an average; the median
simply ignores a single outlier in either direction and costs nothing when the
reps agree. The headline number for a comparison is then the median of the
candidate arm versus the median of the baseline arm, expressed as a percentage
change. All the raw per-rep numbers are kept, so spread can always be inspected
later.

Which metric is trusted for that percentage depends on the question, and is the
subject of the trust tiers immediately below.

### Combining several runs (a week of nights)

A single 10-hour run only fits about three reps per arm. Three reps taken back to
back on the *same* night also share that night's conditions (temperature,
background processes, memory fragmentation), so they are not fully independent —
they tend to agree with each other more than they would agree with a different
night. That means three reps *understate* the true run-to-run variation.

The fix is not more reps per night but **more nights**: run the same 10-hour
harness on many nights across a week and pool all the reps together. The report
logic already supports this in principle — it groups every recorded cell by
(comparison, variant) and takes the median, and it does **not** care which night
a cell came from. Concatenate several nights' `results.jsonl` files into one and
the same report gives a median over all the pooled reps.

Pooling across nights is not only valid, it is *better*, for two reasons:

- **It captures honest variation.** Different nights differ; a central value taken
  across nights reflects real-world spread far better than three correlated reps
  from one night.
- **Nights count more than reps for confidence.** Because reps within a night are
  correlated, the number of *independent* observations is closer to the number of
  nights than the total number of reps. Many nights of a few reps each therefore
  buys more statistical confidence than one night of many reps — which is exactly
  why the short nightly run is the right shape.

Two conditions must hold for the pooling to be sound, and both are about
*comparability*:

- **Same code.** Every night being pooled must use the *same commit* for each
  variant. Pooling nights where the `srv` (or `fast-parse`, etc.) branch changed would
  silently mix two different programs.
- **Same setup.** Same machine, same manifest (same workloads, seeds, oracle,
  telemetry settings). Changing the seed or the measured command mid-week makes
  the reps non-comparable.

The one missing ingredient for doing this safely used to be **provenance**, and it
is now built in. Every recorded cell is stamped with the variant's git commit and
fingerprints of the setup (workloads/build) and telemetry (collection regime). The
aggregator uses them to enforce comparability automatically:

```
# Pool a week of nightly runs into one provenance-guarded report:
.\Invoke-PerfHarness.ps1 -Manifest your.manifest.json `
    -Aggregate results\night1, results\night2, results\night3 -AllMetrics `
    -Markdown week-report.md
```

What it does:

- **Refuses to pool different code.** If the reps of one arm were built from more
  than one commit, that comparison's status is `CONFLICT:code` and its headline
  delta is withheld rather than silently averaging two different programs.
  A differing setup fingerprint likewise yields `CONFLICT:setup`.
- **Invalidates a comparison on any oracle failure.** If even one rep in a
  comparison produced output that did not match the oracle, the comparison's
  status is `INVALID:oracle` and its delta is withheld — a byte-divergence means
  the candidate is not proven to do identical work, so the whole improvement is
  suspect, not just that one rep. The offending reps are recorded as *oracle
  incidents* (comparison, variant, rep, run, commit, timestamp) in a dedicated
  section of the report, so a correctness failure is surfaced loudly rather than
  quietly averaged in.
- **Counts `n` per metric, not per night.** A metric contributes only from reps
  that actually recorded it (a missing or null value is skipped, never treated as
  zero), so the shared GC invariants pool across every night while a PMU-only
  metric like `InstructionRetired` legitimately shows a smaller `n`. `-AllMetrics`
  prints the full per-metric breakdown with each metric's own `n`.
- **Reports spread and regime.** Each arm shows a min–max spread so a week's
  consistency is visible, and a metric collected under more than one telemetry
  regime is flagged (`mixedRegime`) so a regime-sensitive number is never mistaken
  for a clean one.
- **Flags legacy data.** Runs recorded before provenance stamping report
  `unverified` — pooled on trust, with no same-code guarantee — so old and new
  data never look equally certain.

The null-not-zero rule for dropped providers (a metric whose collection was turned
off is recorded as *absent*, not `0`) is what makes cross-regime pooling safe: a
present value always means the metric was genuinely collected that way, so pooling
only ever combines like with like.

---

## Producing the report

A finished run leaves a `results` directory holding `results.jsonl` — one
self-describing JSON line per cell (see the methodology section). Everything
below is a *reader* over those files: it runs no workload and needs no
elevation, build, or workspace, so it is safe to run any time on any copy of the
results.

There are two report shapes, for two different readers:

- **Markdown (`-Markdown`) is for humans** — a concise table. Each comparison is
  one row whose metric cell reads `baseline → candidate`, with a Δ column that
  carries a direction arrow (`↓` = candidate did less, `↑` = more, `withheld`
  when a conflict or oracle failure voids the delta). Large magnitudes are shown
  compactly (e.g. `5.25e12`).
- **JSON (`-Json`) is for tooling** — the full aggregated report object per
  comparison: exact (unrounded) medians, every metric's detail, both arms'
  commits, telemetry regime, status, and any oracle incidents. Nothing is
  abbreviated, so a script can consume it without reparsing markdown.

The two are independent: pass either, both, or neither (console only).

### One night → a markdown table

Point `-Aggregate` at the single results directory and give `-Markdown` an output
path. (`-Aggregate` pools *one or more* directories; one directory is just the
degenerate case.)

```
.\Invoke-PerfHarness.ps1 -Manifest your.manifest.json `
    -Aggregate results -Markdown report.md
```

This writes `report.md` with a **Headline** table — one row per comparison, using
that comparison's primary invariant metric, showing the `baseline → candidate`
transition, the arrowed Δ, the pooled `n` per arm, the min–max spread, the status,
and the oracle pass counts. It also prints the same table to the console. Add
`-Json report.json` to also emit the machine-readable report for tooling.

### A week of nights → one pooled table

List every night's results directory (comma-separated) and add `-AllMetrics` to
append a per-comparison breakdown of *every* metric, each with its own `n`:

```
.\Invoke-PerfHarness.ps1 -Manifest your.manifest.json `
    -Aggregate results\night1,results\night2,results\night3 `
    -AllMetrics -Markdown week-report.md -Json week-report.json
```

The provenance guards described above apply automatically: mismatched commits or
setups across the pooled nights are reported as `CONFLICT:*` with the delta
withheld, pre-provenance data is flagged `unverified`, and any comparison with an
oracle failure is reported as `INVALID:oracle` with the delta withheld and the
failing reps listed under **Oracle incidents**.

### Console only (no file)

- Drop `-Markdown` from either command above to print the aggregate table without
  writing a file.
- For a quick single-run console table without the provenance machinery, use the
  standalone reader:

  ```
  .\Show-Report.ps1 -Manifest your.manifest.json -ResultsDir results
  ```

  or, equivalently, `Invoke-PerfHarness.ps1 -ReportOnly` (handy right after a hard
  abort, to read a partial run without re-running anything).

### Under the hood

The markdown is produced by `ConvertTo-MarkdownReport` (`lib/Results.ps1`) from
the objects `Get-AggregateReport` returns, so the file, the console table, and the
`-AllMetrics` breakdown are always the same numbers in three renderings. To format
the report differently (HTML, a dashboard, a diff against last week), call
`Get-AggregateReport <dirs> <manifest>` and shape the returned objects yourself.

---

## How to read the "trust" column

The whole point of the harness is an apples-to-apples comparison of the same
program under two variants. Not every metric is equally safe for that:

| Trust tier | Meaning |
|---|---|
| **Invariant** | A direct count of work done. Not affected by CPU speed, other programs on the machine, or the act of measuring. Safe to compare directly. |
| **Robust** | A count of the process's own activity. Largely unaffected by machine contention or clock speed, but a statistical estimate, so expect small run-to-run spread. |
| **Clock-based** | Depends on elapsed wall-clock time. Distorted by turbo/thermal drift, background load, and the measurement overhead itself. Use only as context, never as the headline. |

The golden rule this harness was built around: **if a number depends on how
fast the clock was ticking, it is not a fair basis for comparison.** Prefer
the invariant metrics; treat the clock-based ones as sanity context.

---

## GC mode and topology

These describe *how* the .NET garbage collector was configured for the run.
They do not measure speed; they explain the shape of everything else.

### <a id="metric-GcMode"></a>`GcMode`
**What:** Which garbage collector the process used — `Server`, `Workstation`,
or `unknown` (with an `(inferred)` suffix when it was deduced from heap count
rather than read from a flag).
**Why it matters:** Server GC gives each CPU its own heap and collects in
parallel; Workstation GC uses a single heap. This is the single biggest lever
on GC behavior, so it frames the whole comparison.

### <a id="metric-IsServerGcRaw"></a>`IsServerGcRaw`
**What:** The raw flag straight from the CLR: `1` = Server, `0` = Workstation,
`-1` = the trace didn't contain enough to tell.
**Note:** In practice this often reads `-1` even on a valid Server GC run
because the deciding event isn't always captured. When that happens, trust
`HeapCount` / `MaxPerGcHeapCount` instead — those are definitive.

### <a id="metric-HeapCount"></a>`HeapCount`
**What:** How many managed heaps the collector was running.
**Reading:** Workstation GC is always `1`. Server GC is one heap per CPU
(e.g. `22` on a 22-core machine). A count above 1 *is* Server GC, regardless
of what `IsServerGcRaw` says.

### <a id="metric-MaxPerGcHeapCount"></a>`MaxPerGcHeapCount`
**What:** The largest number of heaps seen on any single collection.
**Reading:** A cross-check on `HeapCount`. If any GC touched more than one
heap, the process was really running Server GC.

### <a id="metric-BackgroundGc"></a>`BackgroundGc`
**What:** `true` if the run did any background (concurrent) gen2 collections —
GCs that run on a separate thread while the program keeps working, instead of
freezing it.

---

## GC volume — how much work the collector did

These are **counts and byte totals**. They are the trustworthy core of the
comparison because they measure *what happened*, not *how long it took*.

### <a id="metric-TotalAllocatedMB"></a>`TotalAllocatedMB`  — **Invariant**
**What:** Total megabytes of managed memory the program allocated over the
whole run.
**Why it's the anchor:** For a byte-identical workload, allocation is
deterministic — the same code on the same input allocates the same bytes. So
this doubles as a **sanity check**: if the two variants report nearly the same
`TotalAllocatedMB`, you've confirmed they really did the same work. If it
diverges a lot, something other than the change under test differed.
**Use it for:** algorithmic changes, where "allocate less" is the actual goal.
GC-mode changes should *not* move this number (Server vs Workstation doesn't
change how much you allocate, only how it's collected).

### <a id="metric-GcCount"></a>`GcCount`  — **Invariant**
**What:** Total number of garbage collections during the run.
**Reading:** Fewer is generally better — each collection has overhead. Server
GC typically slashes this because its larger combined nursery lets the program
allocate much more between collections.

### <a id="metric-Gen0"></a><a id="metric-Gen1"></a><a id="metric-Gen2Blocking"></a>`Gen0`, `Gen1`, `Gen2Blocking`  — **Invariant**
**What:** The `GcCount` broken down by generation:
- `Gen0` — cheap, frequent collections of the youngest, mostly-dead objects.
- `Gen1` — a middle buffer generation.
- `Gen2Blocking` — full collections of the oldest objects that **stop the
  whole program** while they run (the expensive kind).
**Reading:** Lots of `Gen2Blocking` is a red flag — those are the pauses that
hurt most. Healthy runs are dominated by `Gen0`.

### <a id="metric-BackgroundGcs"></a>`BackgroundGcs`  — **Invariant**
**What:** How many gen2 collections ran **in the background** (concurrently),
instead of freezing the program.
**Reading:** Background gen2s are the "polite" version of a full collection —
the program keeps running while they work. More of these *instead of*
`Gen2Blocking` is good.

### <a id="metric-InducedGcs"></a>`InducedGcs`  — **Invariant**
**What:** How many collections were triggered manually by the code calling
`GC.Collect()`, rather than by the runtime deciding it was time.
**Reading:** Usually you want this at or near `0`. A non-zero value means the
program is forcing collections, which is often an accidental performance bug.

### <a id="metric-FinalizationPromotedCount"></a>`FinalizationPromotedCount`  - **Invariant**
**What:** How many objects were found dead by a collection but could not be
freed on the spot because they declare a finalizer, so the runtime kept them
alive (via the f-reachable queue) to run that finalizer later. Summed over the
run.
**Reading:** Fewer is leaner. A finalizable object dying in gen0 cannot be
reclaimed there - it is promoted to gen1 and collected later, so a rise here is
a direct, mechanical explanation for a `Gen0`-down / `Gen1`-up shift between two
variants, even when total allocation falls. Undisposed types that own a
finalizable field (e.g. a `ConcurrentBag`/`ThreadLocal` that is never disposed)
inflate it.

### <a id="metric-TotalPromotedMB"></a>`TotalPromotedMB`  - **Invariant**
**What:** Total bytes that **survived** a collection and were promoted into an
older generation, summed across every GC in the run.
**Reading:** Lower means less mid-life data surviving collections. High
promotion is what feeds gen1 and ultimately gen2, so this is the volume metric
behind a rising `Gen1`/`Gen2Blocking` - the mirror image of `TotalAllocatedMB`
(what was born) is this (what refused to die young).

### <a id="metric-PinnedObjectCount"></a>`PinnedObjectCount`  - **Invariant**
**What:** Pinned objects observed across collections - objects the GC was not
allowed to move (typically pinned for interop/`fixed`), summed over the run.
**Reading:** High pinning fragments the heap and blocks compaction, which can
force the heap larger than the live-set would otherwise need. Near-zero is
healthy for pure managed workloads.

### <a id="metric-PeakHeapSizeMB"></a>`PeakHeapSizeMB`  - **Invariant (high-water)**
**What:** The largest total managed heap size seen at the end of any single GC.
This is a snapshot high-water mark (**max**, never summed), so it is a footprint
metric, not a work-rate.
**Reading:** A proxy for peak managed memory pressure. Two output-identical
variants should land close; a big gap flags one holding much more live (or
unpromoted-but-uncollected) data at its worst moment.

### <a id="metric-PeakGCHandleCount"></a>`PeakGCHandleCount`  - **Invariant (high-water)**
**What:** The most live GC handles (strong/weak/pinned/dependent) seen at any GC
- again a **max** snapshot, not a sum.
**Reading:** Steady growth across otherwise-equal runs can indicate a handle
leak (e.g. event subscriptions or pinned buffers never released).

---

## GC time cost — how long collection took

These translate the collection *counts* above into *time*. They involve
elapsed time, so they carry more caveats than the pure counts, but GC pause is
still a mostly self-contained quantity.

### <a id="metric-PercentTimeInGc"></a>`PercentTimeInGc`  — **Robust**
**What:** The share of the run the program spent **paused** for garbage
collection, as a percentage.
**Why it's important:** This is the ceiling on how much any GC improvement can
possibly help. If a run spends 62% of its time paused for GC, fixing GC can
win back most of that. If it spends 3%, there's almost nothing to gain there —
no GC change can save more time than the program spends in GC.
**Reading:** Lower is better. It is also the metric that most cleanly
separates a Workstation-GC run from a Server-GC one — see the worked example at
the end of this document.

### <a id="metric-TotalPauseMSec"></a>`TotalPauseMSec`  — **Robust**
**What:** Total milliseconds the program was frozen, summed across every
stop-the-world collection.
**Reading:** The wall-clock cost of GC pauses. Lower is better. Closely tied
to `PercentTimeInGc` but in absolute time.

### <a id="metric-MaxPauseMSec"></a>`MaxPauseMSec`  — **Robust**
**What:** The single longest stop-the-world pause in the run.
**Reading:** Matters for responsiveness/latency. A run can have an acceptable
*total* pause but one monster pause that stalls everything — this catches that.

### <a id="metric-TotalGcCpuMSec"></a>`TotalGcCpuMSec`  — **Robust**
**What:** Total CPU-milliseconds the collector's own threads consumed.
**Difference from `TotalPauseMSec`:** Pause is *wall* time the program was
frozen; this is *CPU* time the GC threads burned. Server GC can spread the same
work across many threads, so it may show low pause (little freezing) even while
doing real CPU work in parallel. Comparing the two tells you whether GC was
serialized (pause ≈ CPU) or parallel (pause ≪ CPU).

---

## CPU work

### <a id="metric-CpuSampleCount"></a>`CpuSampleCount`  — **Robust**
**What:** The number of CPU profiling samples attributed to this process. The
kernel profiler ticks 1000 times per second on each CPU; every tick that lands
on one of this process's threads counts here. So the number is, in effect,
**total CPU-milliseconds the process consumed across all cores**.
**Why it's trustworthy under load:** A sample only fires when *our* thread is
actually running on a core. Time the process spends waiting because SQL Server
or the IDE stole the CPU does **not** add samples — that CPU is charged to
those other processes. This makes `CpuSampleCount` largely immune to machine
contention, which is exactly why it is a better comparison basis than wall
time.
**Caveat:** It's a statistical sample at 1 kHz, so expect a few percent of
run-to-run wobble. Read it to the nearest few percent, not three digits.
**Reading:** Lower means the process did less total CPU work. Because it counts
*all* threads, parallelism does **not** lower it — only genuinely doing less
work does.
**When it is present:** only when the trace was collected with PerfView's
`Profile` kernel stack sampling in `kernelEvents`. A manifest that drops
`Profile` (to keep traces small and reps fast, leaning on the hardware
`InstructionRetired` counter for the "how much work" question instead) will
have **no** samples, and the extractor records the metric as `null` — *absent*,
not `0` — so it is cleanly skipped in pooling rather than dragging a median to
zero. Re-add `Profile` to `kernelEvents` if you want CPU-time share back.

### <a id="metric-PmcSampleCounts"></a><a id="metric-PmcEstimatedTotals"></a>`PmcSampleCounts` / `PmcEstimatedTotals`  — **Invariant (when present)**
**What:** Hardware performance-counter data (PMU) — e.g. instructions retired,
cache misses — captured only if the trace was collected with PerfView's
`-CpuCounters`. `PmcSampleCounts` is the raw sample count per counter;
`PmcEstimatedTotals` multiplies by the sampling interval to estimate the true
event total (e.g. total instructions executed).
**When it is present:** only when the trace was collected with PerfView's
`-CpuCounters` (set `telemetry.perfview.cpuCounters` in the manifest, e.g.
`InstructionRetired:10000000,CacheMisses:1000000`). When present,
`PmcEstimatedTotals.InstructionRetired` is the strongest invariant for
algorithmic comparisons: "instructions retired" is the gold standard for "same
amount of work" — a direct hardware count that does not change with clock speed
at all. (PMU access can be blocked inside VBS-isolated / container
environments; if a trace comes back with these empty, fall back to
`TotalAllocatedMB` as the same-work invariant.)

---

## Diagnostic fields (not performance measures)

### <a id="metric-Pid"></a>`Pid`
**What:** The operating-system process id the trace extractor attributed the
traced run to.
**Why it's here:** Pure diagnostics - it ties a report row back to a specific
process in the raw ETL. It is not a performance measure; it differs on every rep
and no delta should ever be read into it.

---

## Harness intrinsics — timing (added by `lib/Run.ps1`)

These are recorded by the harness around each run, not by the trace extractor.
They are **clock-based** and included for context and journaling only. Do not
build a performance claim on them.

### <a id="metric-wallSec"></a>`wallSec`  — **Clock-based**
**What:** Raw elapsed seconds measured by a stopwatch around the whole
collection step.
**Important caveat:** This wraps **more than the workload**. Under PerfView it
includes PerfView's startup *and its post-run trace merge*, all while ETW
tracing is active and turbo is disabled. So `wallSec` under the harness is far
larger than the program's real runtime — commonly two to three times the
uninstrumented, turbo-on runtime. Never quote it as "how long the command
takes."

### <a id="metric-freqPct"></a>`freqPct`  — **Clock-based (context)**
**What:** The median CPU "% processor performance" sampled during the run
(Windows' `\Processor Information(_Total)\% Processor Performance` counter),
i.e. how fast the clock was actually ticking relative to the CPU's nominal base
frequency.
**Why it's captured:** To attempt to correct wall time for clock drift. Note it
can read *above* 100% even with turbo disabled, because it's relative to the
*base* frequency, not the current cap.

### <a id="metric-wallSecNorm"></a>`wallSecNorm`  — **Clock-based**
**What:** `wallSec × freqPct / 100` — wall time rescaled to what it would
supposedly be at base clock speed.
**Caveat:** This inherits every problem `wallSec` has (measurement overhead,
turbo-off), and on machines where `freqPct` reads above 100% the
"normalization" actually *inflates* the number rather than correcting it. It is
the least representative figure of all; kept only for continuity with earlier
runs.

---

## Putting it together: which metric for which question

| Question | Use | Ignore |
|---|---|---|
| Did the two runs do the same work? | `TotalAllocatedMB` (should match), `PmcEstimatedTotals.InstructionRetired` | — |
| Did an **algorithmic** change reduce work? | `PmcEstimatedTotals.InstructionRetired`, `TotalAllocatedMB`, `GcCount` | wall times |
| Did a **GC-mode** change help? | `PercentTimeInGc`, `TotalPauseMSec`, `GcCount`, `PmcEstimatedTotals.InstructionRetired` | `TotalAllocatedMB` (won't move), wall times |
| How much could a GC change *possibly* help? | `PercentTimeInGc` (the ceiling) | — |
| Are there nasty latency spikes? | `MaxPauseMSec`, `Gen2Blocking` | — |
| How long does the command *really* take? | none of these — measure uninstrumented, turbo-on | all harness timings |

---

## Example: reading a real report

The numbers below are an **illustrative snapshot** from one 10-hour run (three
reps per arm), produced by the `-Aggregate results -Markdown` recipe above. They
are here to show how to *read* a report, not as a maintained result — rerun the
harness for current figures.

| Comparison | Primary metric | Base median | Cand median | Delta |
|---|---|---:|---:|---:|
| gc-parse | `PercentTimeInGc` | 41.4 | 4.1 | −90% |
| gc-analyze | `PercentTimeInGc` | 57.0 | 8.6 | −85% |
| gc-render | `PercentTimeInGc` | 30.0 | 3.0 | −90% |
| parse-change | `PmcEstimatedTotals.InstructionRetired` | 5.25e12 | 4.52e12 | −14% |
| analyze-change | `PmcEstimatedTotals.InstructionRetired` | 5.76e12 | 5.64e12 | −2.1% |

How to read it:

- **The three `gc-*` rows** compare the same code with Workstation GC (baseline)
  versus Server GC (candidate). `PercentTimeInGc` collapsing from ~30–57% to
  ~3–9% is the headline: the program spent far less of its life paused for
  collection. Because the *code* is identical, `TotalAllocatedMB` should barely
  move here (Server GC changes how memory is collected, not how much is
  allocated) — a good sanity check that nothing else differed.
- **`parse-change`** compares two *different* algorithms, so the trustworthy
  signal is an invariant count of work: `PmcEstimatedTotals.InstructionRetired`
  fell ~14%, corroborated by a matching drop in `TotalAllocatedMB`. The candidate
  genuinely does less work, and the oracle passing proves it still produces
  byte-identical output.
- **`analyze-change`** moved the invariant only ~2%, near the run-to-run spread — a
  change too small to claim with confidence from three reps. This is exactly the
  case where pooling **more nights** (not more reps per night) is needed before
  calling it real.

In the full `-AllMetrics` breakdown you would also see, for the `gc-*` rows,
`GcCount` dropping by two orders of magnitude and `HeapCount` going from `1` to
one-per-core — the mechanism behind the `PercentTimeInGc` win.
