<Query Kind="Program">
  <NuGetReference>Microsoft.Diagnostics.Tracing.TraceEvent</NuGetReference>
  <Namespace>Microsoft.Diagnostics.Tracing</Namespace>
  <Namespace>Microsoft.Diagnostics.Tracing.Analysis</Namespace>
  <Namespace>Microsoft.Diagnostics.Tracing.Analysis.GC</Namespace>
  <Namespace>Microsoft.Diagnostics.Tracing.Parsers</Namespace>
  <Namespace>Microsoft.Diagnostics.Tracing.Parsers.Clr</Namespace>
</Query>

// etl-perf-report (interactive twin of the console tool under tools/EtlPerfReport).
//
// Human-friendly ETL exploration in LINQPad9 (LPRun9.exe for headless). Point ETLS at one or
// more PerfView captures and press F5. Two+ traces render an A/B delta grid. Same TraceEvent
// queries as the console tool, so results match; use this to poke at individual GCs interactively.
//
// The metrics here are frequency-invariant (allocation bytes, GC counts, PMU samples): they mean
// the same thing whether the CPU boosted or thermally throttled — unlike wall-clock.

static readonly string[] ETLS = new[]
{
    @"C:\temp\perf-etl\baseline.etl",
    @"C:\temp\perf-etl\candidate.etl",
};
const string ProcessFilter = "myapp"; // null = all managed processes

void Main()
{
    var all = ETLS.Where(File.Exists).SelectMany(e => Analyze(e, Path.GetFileNameWithoutExtension(e))).ToList();
    if (all.Count == 0) { "No managed processes matched. Check ETLS paths / ProcessFilter.".Dump(); return; }

    all.Select(r => new
    {
        r.Label, r.GcMode, Heaps = r.HeapCount, MaxNumHeaps = r.MaxPerGcHeapCount, ServerRaw = r.IsServerGcRaw,
        AllocMB = Math.Round(r.TotalAllocatedMB, 1), r.GcCount, r.Gen0, r.Gen1, Gen2Block = r.Gen2Blocking, Bg = r.BackgroundGcs,
        PctGC = Math.Round(r.PercentTimeInGc, 2), PauseMs = Math.Round(r.TotalPauseMSec), GcCpuMs = Math.Round(r.TotalGcCpuMSec),
        CpuSamples = r.CpuSampleCount,
    }).Dump("GC / work profile (frequency-invariant)");

    if (all.Count >= 2)
    {
        var a = all.First(); var b = all.Last();
        new[]
        {
            Row("Allocated MB", a.TotalAllocatedMB, b.TotalAllocatedMB),
            Row("GC count", a.GcCount, b.GcCount),
            Row("% time in GC", a.PercentTimeInGc, b.PercentTimeInGc),
            Row("Total GC pause ms", a.TotalPauseMSec, b.TotalPauseMSec),
            Row("GC CPU ms", a.TotalGcCpuMSec, b.TotalGcCpuMSec),
            Row("CPU samples", a.CpuSampleCount, b.CpuSampleCount),
        }.Dump($"A/B delta:  A={a.Label}  B={b.Label}");

        Util.RawHtml("<b>Read:</b> near-equal Allocated MB ⇒ byte-identical workload (sanity). " +
            "Low % time in GC bounds how much any GC change can help. " +
            "Server vs Workstation changes heaps/pauses, not Allocated MB. " +
            "<b>NumHeaps &gt; 1 ⇒ Server GC regardless of the raw flag.</b>").Dump();
    }
}

object Row(string metric, double a, double b) => new
{
    Metric = metric, A = Math.Round(a, 1), B = Math.Round(b, 1),
    Delta = Math.Round(b - a, 1), Pct = a != 0 ? Math.Round((b - a) / a * 100, 1) : 0.0,
};

// ---- shared analysis (mirrors EtlAnalyzer.cs) ----

class ProcReport
{
    public string Label = "", ProcessName = "", GcMode = "unknown";
    public int Pid, HeapCount, MaxPerGcHeapCount, IsServerGcRaw = -1;
    public double TotalAllocatedMB, TotalPauseMSec, MaxPauseMSec, PercentTimeInGc, TotalGcCpuMSec;
    public long GcCount, Gen0, Gen1, Gen2Blocking, BackgroundGcs, InducedGcs, CpuSampleCount;
}

IEnumerable<ProcReport> Analyze(string etl, string label)
{
    var reports = new List<ProcReport>();
    using var source = new ETWTraceEventSource(etl);
    source.NeedLoadedDotNetRuntimes();

    var cpuSamplesByProc = new Dictionary<int, long>();
    source.Kernel.PerfInfoSample += d =>
        cpuSamplesByProc[d.ProcessID] = cpuSamplesByProc.TryGetValue(d.ProcessID, out var c) ? c + 1 : 1;

    source.Process();

    foreach (var proc in source.Processes())
    {
        if (ProcessFilter != null && !proc.Name.Contains(ProcessFilter, StringComparison.OrdinalIgnoreCase)) continue;
        var runtime = proc.LoadedDotNetRuntime();
        if (runtime == null) continue;

        var r = new ProcReport { Label = label, ProcessName = proc.Name, Pid = proc.ProcessID };
        var gc = runtime.GC;
        var stats = gc.Stats();
        r.IsServerGcRaw = stats.IsServerGCUsed;
        r.HeapCount = stats.HeapCount;
        r.TotalAllocatedMB = stats.TotalAllocatedMB;
        r.TotalPauseMSec = stats.TotalPauseTimeMSec;
        r.MaxPauseMSec = stats.MaxPauseDurationMSec;
        r.PercentTimeInGc = stats.GetGCPauseTimePercentage();
        r.TotalGcCpuMSec = stats.TotalCpuMSec;
        r.InducedGcs = stats.NumInduced;

        foreach (var one in gc.GCs)
        {
            r.GcCount++;
            if (one.HeapCount > r.MaxPerGcHeapCount) r.MaxPerGcHeapCount = one.HeapCount;
            switch (one.Generation)
            {
                case 0: r.Gen0++; break;
                case 1: r.Gen1++; break;
                case 2: if (one.Type == GCType.BackgroundGC) r.BackgroundGcs++; else r.Gen2Blocking++; break;
            }
        }
        r.GcMode = stats.IsServerGCUsed == 1 ? "Server" : stats.IsServerGCUsed == 0 ? "Workstation"
                 : r.MaxPerGcHeapCount > 1 ? "Server (inferred)" : "Workstation (inferred)";
        if (cpuSamplesByProc.TryGetValue(proc.ProcessID, out var cs)) r.CpuSampleCount = cs;
        reports.Add(r);
    }
    return reports;
}
