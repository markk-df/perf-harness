# Perf telemetry analysis

Reusable tooling that turns a PerfView ETL into a **frequency-invariant** work profile --
allocation bytes, GC counts, GC mode/heap topology, and (when captured) PMU counters. These
metrics mean the same thing whether the CPU was boosting or thermally throttled, so they are the
honest way to compare two runs. Wall-clock is deliberately *not* the headline number.

The same ETL layout is produced by a local profiler run and by an unattended CI run, so
these tools run unchanged on ETLs captured in either place (for example copied off a build agent).

## Two twins, one analysis

| Tool | For | Run |
| --- | --- | --- |
| [`EtlPerfReport/`](EtlPerfReport) (.NET console) | headless / CI / batch over many ETLs | `dotnet run -c Release -- <a.etl> [b.etl ...]` |
| [`etl-report.linq`](etl-report.linq) (LINQPad9) | interactive human exploration | open in LINQPad9, or `LPRun9.exe etl-report.linq` |

Both share the same TraceEvent queries ([`EtlAnalyzer.cs`](EtlPerfReport/EtlAnalyzer.cs) mirrors the `.linq`), so their numbers match.

### Console tool

```powershell
cd tools/EtlPerfReport
dotnet build -c Release
dotnet bin/Release/net8.0/etl-perf-report.dll `
    C:\temp\perf-etl\baseline.etl C:\temp\perf-etl\candidate.etl `
    --process myapp --csv out.csv --json out.json
```

Flags: `--process <name>` (default: all managed processes), `--all-processes`, `--csv <f>`, `--json <f>`.
Pass `--process <name>` (e.g. `--process myapp`) to narrow the report to one process.
Give two or more ETLs to get an A/B delta block. The console tool is intentionally isolated from
the repo's Central Package Management (local `Directory.Build.props/.targets` stubs) so it builds
and runs standalone, including on a machine that only has the ETLs.

### LINQPad twin

Edit the `ETLS` array at the top of [`etl-report.linq`](etl-report.linq), press F5. `LPRun9.exe` runs it headless
and prints JSON (first-run downloads the TraceEvent NuGet automatically).

## What the metrics tell you

- **GC mode / `MaxNumHeaps`** -- the ground truth for Server vs Workstation. **NumHeaps > 1 => Server
  GC**, no matter what the raw `IsServerGCUsed` flag says (that flag needs a start-of-process event
  that is sometimes absent, so we infer from actual per-GC heap counts). Workstation GC is always 1
  heap. Use this to *verify* a run really used the GC mode you configured -- App.config staleness in
  incremental builds silently produced Server GC on a supposedly-Workstation "baseline" once.
- **Allocated MB** -- deterministic for a byte-identical workload; use it as a sanity check that two
  runs did the same work, and as the true measure of GC *pressure*.
- **% time in GC** -- bounds how much *any* GC change can help end-to-end. If it is a few percent,
  Server-vs-Workstation cannot move the wall-clock much regardless of heap topology.
- **PMU counters** (`InstructionRetired`, `TotalCycles`, `CacheMisses`, `LLCMisses`,
  `BranchMispredictions`) -- the frequency-invariant "work" metric. Present only when the ETL was
  captured with PerfView `-CpuCounters`, which needs hardware PMU access. Many virtualized / cloud
  Windows hosts do not expose the PMU -- `perfview listCpuCounters` there reports only the `Timer`
  source (0 hardware counters) because the hypervisor does not virtualize the PMU for that VM SKU. So
  treat PMU counters as a bare-metal / local luxury and fall back to allocation + GC metrics where
  they are unavailable.
- **CPU profile samples** -- 1 kHz kernel sampler; a proxy for this process's CPU-time share.

## Why verify the GC mode from telemetry

Build staleness can silently defeat a GC experiment. An incremental build can keep a stale
`App.config`, so a run you labelled "Workstation" actually executes under Server GC. If both the
baseline and candidate arms end up on the same GC mode, their near-identical wall-clock is comparing
like-for-like -- **not** evidence that switching GC mode is a no-op, because the arm you meant to
change was never actually built that way. Always assert the GC mode from telemetry (`MaxNumHeaps`:
`> 1` => Server, `1` => Workstation) before trusting any timing.
