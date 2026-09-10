using System.Text;
using System.Text.Json;
using EtlPerfReport;

// etl-perf-report: frequency-invariant GC/CPU work profile from one or more ETW/ETL traces.
//
//   etl-perf-report <a.etl> [b.etl ...] [--process <name>] [--json out.json] [--csv out.csv]
//
// Designed to run headless (CI / batch) and to be re-run on ETLs captured with the same
// PerfView command prefix. When two or more traces are given it prints
// an A/B delta so a claimed speedup can be judged on allocation volume + GC counts + PMU
// instructions, not on wall-clock (which is distorted by turbo/thermal drift).

var etls = new List<string>();
string? processFilter = null;
string? jsonOut = null, csvOut = null;

for (int i = 0; i < args.Length; i++)
{
    switch (args[i])
    {
        case "--process": processFilter = args[++i]; break;
        case "--all-processes": processFilter = null; break;
        case "--json": jsonOut = args[++i]; break;
        case "--csv": csvOut = args[++i]; break;
        case "-h" or "--help":
            Console.WriteLine("usage: etl-perf-report <a.etl> [b.etl ...] [--process <name>] [--all-processes] [--json f] [--csv f]");
            return 0;
        default: etls.Add(args[i]); break;
    }
}

if (etls.Count == 0)
{
    Console.Error.WriteLine("error: give at least one .etl path. Try --help.");
    return 2;
}

var all = new List<ProcessReport>();
foreach (var etl in etls)
{
    if (!File.Exists(etl)) { Console.Error.WriteLine($"error: not found: {etl}"); return 2; }
    var label = Path.GetFileNameWithoutExtension(etl);
    Console.Error.WriteLine($"[scan] {etl} ...");
    try { all.AddRange(EtlAnalyzer.Analyze(etl, label, processFilter)); }
    catch (Exception ex) { Console.Error.WriteLine($"error scanning {etl}: {ex.Message}"); return 1; }
}

if (all.Count == 0)
{
    Console.Error.WriteLine("no managed processes matched. Re-run with --all-processes to list what is present.");
    return 1;
}

PrintTable(all);
if (all.Count >= 2) PrintDelta(all[0], all[^1]);

if (csvOut != null) { File.WriteAllText(csvOut, ToCsv(all)); Console.Error.WriteLine($"[csv] {csvOut}"); }
if (jsonOut != null)
{
    File.WriteAllText(jsonOut, JsonSerializer.Serialize(all, new JsonSerializerOptions { WriteIndented = true, IncludeFields = true }));
    Console.Error.WriteLine($"[json] {jsonOut}");
}
return 0;

static void PrintTable(List<ProcessReport> rows)
{
    Console.WriteLine();
    Console.WriteLine("=== GC / work profile (frequency-invariant) ===");
    foreach (var r in rows)
    {
        Console.WriteLine();
        Console.WriteLine($"  {r.Label}  (pid {r.Pid}, {r.ProcessName})");
        Console.WriteLine($"    GC mode              : {r.GcMode}{(r.BackgroundGc ? " + Background" : "")}   heaps={r.HeapCount} (max per-GC NumHeaps={r.MaxPerGcHeapCount}, IsServerGCUsed raw={r.IsServerGcRaw})");
        Console.WriteLine($"    Allocated (invariant): {r.TotalAllocatedMB,12:N1} MB");
        Console.WriteLine($"    GC count             : {r.GcCount,12:N0}   gen0={r.Gen0:N0} gen1={r.Gen1:N0} gen2(blocking)={r.Gen2Blocking:N0} bg={r.BackgroundGcs:N0} induced={r.InducedGcs:N0}");
        Console.WriteLine($"    % time in GC (pause) : {r.PercentTimeInGc,12:N2} %");
        Console.WriteLine($"    Total GC pause       : {r.TotalPauseMSec,12:N0} ms   (max single {r.MaxPauseMSec:N1} ms)");
        Console.WriteLine($"    GC CPU time          : {r.TotalGcCpuMSec,12:N0} ms");
        Console.WriteLine($"    CPU profile samples  : {(r.CpuSampleCount.HasValue ? r.CpuSampleCount.Value.ToString("N0") : "n/a"),12}   (1 kHz kernel sampler; CPU-time share proxy)");
        if (r.PmcSampleCounts.Count > 0)
        {
            Console.WriteLine("    PMU counters (frequency-invariant work):");
            foreach (var kv in r.PmcSampleCounts)
            {
                var est = r.PmcEstimatedTotals.TryGetValue(kv.Key, out var t) ? $"  ~{t:N0} events" : "";
                Console.WriteLine($"      {kv.Key,-28}: {kv.Value,10:N0} samples{est}");
            }
        }
        else
        {
            Console.WriteLine("    PMU counters         : none in trace (capture with PerfView -CpuCounters; unavailable in VBS/containers)");
        }
    }
}

static void PrintDelta(ProcessReport a, ProcessReport b)
{
    Console.WriteLine();
    Console.WriteLine($"=== A/B delta:  A={a.Label}   B={b.Label} ===");
    Pct("Allocated MB      ", a.TotalAllocatedMB, b.TotalAllocatedMB);
    Pct("GC count          ", a.GcCount, b.GcCount);
    Pct("% time in GC      ", a.PercentTimeInGc, b.PercentTimeInGc, isPercentPoints: true);
    Pct("Total GC pause ms ", a.TotalPauseMSec, b.TotalPauseMSec);
    Pct("GC CPU ms         ", a.TotalGcCpuMSec, b.TotalGcCpuMSec);
    Pct("CPU samples       ", a.CpuSampleCount ?? 0, b.CpuSampleCount ?? 0);
    Console.WriteLine($"  GC mode           : A={a.GcMode}(heaps {a.HeapCount})  ->  B={b.GcMode}(heaps {b.HeapCount})");
    Console.WriteLine();
    Console.WriteLine("  Interpretation guide:");
    Console.WriteLine("   - Near-equal Allocated MB confirms the workload is byte-identical (sanity check).");
    Console.WriteLine("   - A low '% time in GC' bounds how much ANY GC-mode change can possibly help end-to-end.");
    Console.WriteLine("   - Server vs Workstation should change heaps/pause distribution, not Allocated MB.");
}

static void Pct(string label, double a, double b, bool isPercentPoints = false)
{
    var delta = b - a;
    var pct = a != 0 ? delta / a * 100.0 : 0.0;
    var suffix = isPercentPoints ? $"  (Δ {delta:+0.00;-0.00} pts)" : $"  (Δ {pct:+0.0;-0.0}%)";
    Console.WriteLine($"  {label}: {a,14:N1}  ->  {b,14:N1}{suffix}");
}

static string ToCsv(List<ProcessReport> rows)
{
    var sb = new StringBuilder();
    sb.AppendLine("label,etl,pid,process,gc_mode,background_gc,heap_count,allocated_mb,gc_count,gen0,gen1,gen2_blocking,background_gcs,induced_gcs,pct_time_in_gc,total_pause_ms,max_pause_ms,gc_cpu_ms,cpu_samples");
    foreach (var r in rows)
        sb.AppendLine(string.Join(",",
            Q(r.Label), Q(r.Etl), r.Pid, Q(r.ProcessName), r.GcMode, r.BackgroundGc, r.HeapCount,
            F(r.TotalAllocatedMB), r.GcCount, r.Gen0, r.Gen1, r.Gen2Blocking, r.BackgroundGcs, r.InducedGcs,
            F(r.PercentTimeInGc), F(r.TotalPauseMSec), F(r.MaxPauseMSec), F(r.TotalGcCpuMSec), r.CpuSampleCount));
    return sb.ToString();

    static string F(double d) => d.ToString("0.###");
    static string Q(string s) => s.Contains(',') ? $"\"{s}\"" : s;
}
