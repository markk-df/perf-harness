using Microsoft.Diagnostics.Tracing;
using Microsoft.Diagnostics.Tracing.Analysis;
using Microsoft.Diagnostics.Tracing.Analysis.GC;
using Microsoft.Diagnostics.Tracing.Parsers;
using Microsoft.Diagnostics.Tracing.Parsers.Clr;

namespace EtlPerfReport;

/// <summary>
/// One managed process's frequency-invariant "work" profile extracted from an ETW/ETL trace.
/// Every field here is derived from event counts/bytes, never from wall-clock rate, so the same
/// numbers mean the same thing whether the CPU was boosting or thermally throttled.
/// </summary>
public sealed class ProcessReport
{
    public string Etl = "";
    public string Label = "";
    public string ProcessName = "";
    public int Pid;
    public string CommandLine = "";

    // GC mode / topology
    public string GcMode = "unknown";      // "Server" | "Workstation" | "unknown"
    public int IsServerGcRaw = -1;         // raw CLR flag: 1=server, 0=workstation, -1=undetermined
    public int MaxPerGcHeapCount;          // max NumHeaps seen on any single GC (Server GC > 1)
    public bool BackgroundGc;
    public int HeapCount;

    // GC volume (allocation is deterministic for a byte-identical workload -> a true invariant)
    public double TotalAllocatedMB;
    public long GcCount;
    public long Gen0;
    public long Gen1;
    public long Gen2Blocking;   // gen2 that stops the world
    public long BackgroundGcs;
    public long InducedGcs;

    // Promotion / finalization / pinning work (summed across GCs -- cumulative counts/bytes, so a
    // true invariant like allocation). More finalizable objects means more gen0->gen1 promotion.
    public long FinalizationPromotedCount;   // objects promoted via the f-reachable queue (finalizers)
    public double TotalPromotedMB;           // total bytes promoted (survived a GC) over the run
    public long PinnedObjectCount;           // pinned objects observed across GCs (pinning pressure)

    // Heap/handle high-water marks (max across GCs -- these are end-of-GC snapshots, never summed).
    public double PeakHeapSizeMB;            // largest total managed heap seen at any GC
    public long PeakGCHandleCount;           // most live GC handles seen at any GC

    // GC time cost (pause is clock-based, kept as a secondary/context metric)
    public double TotalPauseMSec;
    public double MaxPauseMSec;
    public double PercentTimeInGc;
    public double TotalGcCpuMSec;

    // Optional CPU performance counters (PMU). Empty when the trace carries no -CpuCounters data
    // (e.g. Windows-container or VBS-isolated hosts where PMU access is denied).
    public readonly Dictionary<string, long> PmcSampleCounts = new();
    public readonly Dictionary<string, long> PmcEstimatedTotals = new();
    // 1 kHz kernel Profile samples for this process (proxy for CPU-time share). Null -- not zero --
    // when the trace carried no Profile sampling at all, so a run that simply did not collect this
    // is distinguishable from a genuine zero and is excluded (rather than averaged in) when results
    // from different collection regimes are pooled.
    public long? CpuSampleCount;
}

public static class EtlAnalyzer
{
    // Kernel PMC events carry a numeric profile-source ID, not a name. These IDs are assigned by the
    // OS/PerfView and are stable per counter on Intel parts (confirmed here via 'PerfView
    // listCpuCounters'). Mapping them to names keeps the emitted metric keys self-documenting;
    // anything unmapped falls back to ProfileSource<id> so no data is ever lost.
    static readonly Dictionary<int, string> ProfileSourceNames = new()
    {
        [2] = "TotalIssues", [6] = "BranchInstructions", [10] = "CacheMisses",
        [11] = "BranchMispredictions", [19] = "TotalCycles", [25] = "UnhaltedCoreCycles",
        [26] = "InstructionRetired", [27] = "UnhaltedReferenceCycles", [28] = "LLCReference",
        [29] = "LLCMisses", [30] = "BranchInstructionRetired", [31] = "BranchMispredictsRetired",
        [32] = "LbrInserts", [33] = "InstructionsRetiredFixed", [34] = "UnhaltedCoreCyclesFixed",
        [35] = "UnhaltedReferenceCyclesFixed",
    };

    public static List<ProcessReport> Analyze(string etlPath, string label, string? processFilter)
    {
        var reports = new List<ProcessReport>();

        // Pass 1: managed-runtime + GC analysis (self-describing CLR events, no symbols needed).
        using (var source = new ETWTraceEventSource(etlPath))
        {
            source.NeedLoadedDotNetRuntimes();

            // Pass-through counters gathered on the same source in a single scan.
            var pmcByProc = new Dictionary<int, Dictionary<int, long>>();
            var cpuSamplesByProc = new Dictionary<int, long>();
            var pmcIntervals = new Dictionary<int, long>();

            source.Kernel.PerfInfoCollectionStart += d =>
            {
                // Sampling interval per profile source; PMU total ~= samples * interval.
                pmcIntervals[d.SampleSource] = d.NewInterval;
            };
            source.Kernel.PerfInfoPMCSample += d =>
            {
                var byProc = pmcByProc.TryGetValue(d.ProcessID, out var m) ? m : (pmcByProc[d.ProcessID] = new());
                byProc[d.ProfileSource] = byProc.TryGetValue(d.ProfileSource, out var c) ? c + 1 : 1;
            };
            source.Kernel.PerfInfoSample += d =>
            {
                cpuSamplesByProc[d.ProcessID] = cpuSamplesByProc.TryGetValue(d.ProcessID, out var c) ? c + 1 : 1;
            };

            source.Process();

            var cpuSamplingOn = cpuSamplesByProc.Count > 0;

            foreach (var proc in source.Processes())
            {
                if (processFilter != null &&
                    !proc.Name.Contains(processFilter, StringComparison.OrdinalIgnoreCase))
                    continue;

                var runtime = proc.LoadedDotNetRuntime();
                if (runtime == null) continue;

                var r = new ProcessReport
                {
                    Etl = etlPath,
                    Label = label,
                    ProcessName = proc.Name,
                    Pid = proc.ProcessID,
                    CommandLine = proc.CommandLine ?? "",
                };

                var gc = runtime.GC;
                var stats = gc.Stats();
                r.IsServerGcRaw = stats.IsServerGCUsed;
                r.GcMode = stats.IsServerGCUsed == 1 ? "Server"
                         : stats.IsServerGCUsed == 0 ? "Workstation"
                         : "unknown";
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
                    if (one.HeapStats != null)
                    {
                        var hs = one.HeapStats;
                        r.FinalizationPromotedCount += hs.FinalizationPromotedCount;
                        // Do not add hs.FinalizationPromotedSize here: on BackgroundGC events it is a
                        // bogus fixed sentinel (~3.46e18), not a byte count, so summing it overflows
                        // Int64 and wraps negative. FinalizationPromotedCount is valid on all GC types.
                        r.TotalPromotedMB += hs.TotalPromoted / 1024.0 / 1024.0;
                        r.PinnedObjectCount += hs.PinnedObjectCount;
                        var heapMB = hs.TotalHeapSize / 1024.0 / 1024.0;
                        if (heapMB > r.PeakHeapSizeMB) r.PeakHeapSizeMB = heapMB;
                        if (hs.GCHandleCount > r.PeakGCHandleCount) r.PeakGCHandleCount = hs.GCHandleCount;
                    }
                    if (one.HeapCount > r.MaxPerGcHeapCount) r.MaxPerGcHeapCount = one.HeapCount;
                    switch (one.Generation)
                    {
                        case 0: r.Gen0++; break;
                        case 1: r.Gen1++; break;
                        case 2:
                            if (one.Type == GCType.BackgroundGC) r.BackgroundGcs++;
                            else r.Gen2Blocking++;
                            break;
                    }
                }
                r.BackgroundGc = r.BackgroundGcs > 0;
                if (r.GcMode == "unknown" && r.MaxPerGcHeapCount > 1) r.GcMode = "Server (inferred)";
                else if (r.GcMode == "unknown" && r.MaxPerGcHeapCount == 1) r.GcMode = "Workstation (inferred)";

                r.CpuSampleCount = cpuSamplingOn
                    ? (cpuSamplesByProc.TryGetValue(proc.ProcessID, out var cs) ? cs : 0)
                    : (long?)null;
                if (pmcByProc.TryGetValue(proc.ProcessID, out var pmc))
                {
                    foreach (var kv in pmc)
                    {
                        var name = ProfileSourceNames.TryGetValue(kv.Key, out var friendly)
                            ? friendly : $"ProfileSource{kv.Key}";
                        r.PmcSampleCounts[name] = kv.Value;
                        if (pmcIntervals.TryGetValue(kv.Key, out var interval) && interval > 0)
                            r.PmcEstimatedTotals[name] = kv.Value * interval;
                    }
                }

                reports.Add(r);
            }
        }

        return reports;
    }
}
