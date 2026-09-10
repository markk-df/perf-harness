using System.Text.Json;
using Microsoft.Diagnostics.Tracing.Etlx;
using Microsoft.Diagnostics.Tracing.Parsers.Kernel;

namespace EtlPerfReport;

// CPU-sample stack folding: attribute a process's on-CPU time (1 kHz kernel Profile samples) to the
// managed methods that were running. This is the opt-in companion to the default GC/PMC report --
// it answers "where did the CPU go", which the event-count report cannot. It is deliberately a
// separate mode because resolving stacks forces a one-time .etlx conversion (minutes and several GB
// on a large trace), a cost the per-rep extract path must never pay.
//
// Requires a trace captured WITH kernel Profile + stackwalking (PerfView -KernelEvents:...,Profile)
// and CLR method rundown (PerfView's default) so managed frames resolve to method names without any
// PDBs. Native/unresolved frames fold to "<module>!?".
public static class CpuStackFolder
{
    public sealed class MethodWeight
    {
        public string Method = "";
        public long Exclusive;   // samples where this method was the leaf (running itself)
        public long Inclusive;   // samples whose stack passed through this method
        public double ExclusiveMs;
        public double InclusiveMs;
        public double ExclusivePct;
    }

    public sealed class FoldReport
    {
        public string Etl = "";
        public string Process = "";
        public int Pid;
        public long TotalSamples;     // samples attributed (restricted to the fold window when set)
        public double TotalMs;
        public double SampleIntervalMs;
        public string? FoldUnder;     // when set, only samples whose stack passes through this frame
        public List<MethodWeight> Top = new();
    }

    public static int Run(List<string> etls, string? processFilter, string? foldUnder, int top, string? jsonOut)
    {
        var all = new List<FoldReport>();
        foreach (var etl in etls)
        {
            if (!File.Exists(etl)) { Console.Error.WriteLine($"error: not found: {etl}"); return 2; }
            Console.Error.WriteLine($"[convert] {etl} -> .etlx (one-time; minutes + GBs on a large trace) ...");
            using var log = TraceLog.OpenOrConvert(etl);
            all.AddRange(Fold(log, etl, processFilter, foldUnder, top));
        }

        if (all.Count == 0)
        {
            Console.Error.WriteLine("no CPU samples attributed. The trace must be captured with kernel Profile");
            Console.Error.WriteLine("stacks (PerfView -KernelEvents:...,Profile); check --process and --fold-under.");
            return 1;
        }

        Print(all);
        if (jsonOut != null)
        {
            File.WriteAllText(jsonOut, JsonSerializer.Serialize(all, new JsonSerializerOptions { WriteIndented = true, IncludeFields = true }));
            Console.Error.WriteLine($"[json] {jsonOut}");
        }
        return 0;
    }

    static IEnumerable<FoldReport> Fold(TraceLog log, string etl, string? processFilter, string? foldUnder, int top)
    {
        var intervalMs = SampleIntervalMs(log);

        var procs = log.Processes.Where(p =>
            !string.IsNullOrEmpty(p.Name) &&
            (processFilter == null || p.Name.Contains(processFilter, StringComparison.OrdinalIgnoreCase)));

        foreach (var proc in procs)
        {
            var exclusive = new Dictionary<string, long>();
            var inclusive = new Dictionary<string, long>();
            long total = 0;

            foreach (var data in proc.EventsInProcess)
            {
                if (data is not SampledProfileTraceData sample) continue;
                var cs = sample.CallStack();
                if (cs == null) continue;

                // Frame names leaf -> root. With --fold-under we keep only samples whose stack passes
                // through the named frame, and attribute the window from the leaf up to and including
                // that frame -- i.e. the work done *inside* that method, which is the hot-spot split.
                var frames = new List<string>();
                int foldIdx = -1;
                for (TraceCallStack? f = cs; f != null; f = f.Caller)
                {
                    var name = FrameName(f);
                    if (foldUnder != null && foldIdx < 0 && name.Contains(foldUnder, StringComparison.OrdinalIgnoreCase))
                        foldIdx = frames.Count;
                    frames.Add(name);
                }
                if (frames.Count == 0) continue;
                if (foldUnder != null && foldIdx < 0) continue;

                int limit = foldUnder != null ? foldIdx + 1 : frames.Count;
                total++;

                var leaf = frames[0];
                exclusive[leaf] = exclusive.GetValueOrDefault(leaf) + 1;

                var seen = new HashSet<string>();
                for (int i = 0; i < limit; i++)
                    if (seen.Add(frames[i]))
                        inclusive[frames[i]] = inclusive.GetValueOrDefault(frames[i]) + 1;
            }

            if (total == 0) continue;

            var merged = exclusive.Keys.Union(inclusive.Keys)
                .Select(m =>
                {
                    var ex = exclusive.GetValueOrDefault(m);
                    var inc = inclusive.GetValueOrDefault(m);
                    return new MethodWeight
                    {
                        Method = m,
                        Exclusive = ex,
                        Inclusive = inc,
                        ExclusiveMs = ex * intervalMs,
                        InclusiveMs = inc * intervalMs,
                        ExclusivePct = 100.0 * ex / total,
                    };
                })
                .OrderByDescending(w => w.Exclusive).ThenByDescending(w => w.Inclusive)
                .Take(top).ToList();

            yield return new FoldReport
            {
                Etl = etl,
                Process = proc.Name,
                Pid = proc.ProcessID,
                TotalSamples = total,
                TotalMs = total * intervalMs,
                SampleIntervalMs = intervalMs,
                FoldUnder = foldUnder,
                Top = merged,
            };
        }
    }

    static double SampleIntervalMs(TraceLog log)
    {
        // The default Windows timer sampler runs at 1 kHz (1 ms/sample). We report ms on that basis
        // and label it as assumed; the exclusive/inclusive *percentages* -- the actual deliverable --
        // are interval-independent, so a non-default rate changes only the absolute ms scale.
        return 1.0;
    }

    static string FrameName(TraceCallStack f)
    {
        var ca = f.CodeAddress;
        var method = ca.FullMethodName;
        if (!string.IsNullOrEmpty(method)) return method;
        var module = ca.ModuleName;
        return string.IsNullOrEmpty(module) ? "?!?" : module + "!?";
    }

    static void Print(List<FoldReport> reports)
    {
        foreach (var r in reports)
        {
            Console.WriteLine();
            Console.WriteLine($"=== CPU stack fold: {Path.GetFileNameWithoutExtension(r.Etl)}  ({r.Process}, pid {r.Pid}) ===");
            var scope = r.FoldUnder != null ? $"under *{r.FoldUnder}*" : "whole process";
            Console.WriteLine($"    samples={r.TotalSamples:N0}  (~{r.TotalMs:N0} ms on-CPU, {r.SampleIntervalMs:0.###} ms/sample, {scope})");
            Console.WriteLine();
            Console.WriteLine($"    {"excl ms",10}  {"excl %",7}  {"incl ms",10}   method");
            foreach (var w in r.Top)
                Console.WriteLine($"    {w.ExclusiveMs,10:N0}  {w.ExclusivePct,6:N1}%  {w.InclusiveMs,10:N0}   {w.Method}");
        }
    }
}
