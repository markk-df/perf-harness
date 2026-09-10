# Manifest reference

A manifest is a single JSON file. It has no comments (JSON does not allow them), so every field is
documented here. Paths may use forward slashes on Windows; the harness handles the conversion.

A complete minimal example lives beside this file: [`examples\demo.manifest.json`](../examples/demo.manifest.json) (uses the `time`
collector, so it runs with no profiler and no admin rights). The `perfview`-collector fields are shown
inline below using a placeholder program named `MyApp`; that name is only an illustration -- nothing
about any project is built into the harness.

## The manifest in plain English

The harness answers one question: *"I changed some code — did it actually get faster, and does it
still produce the same output?"* It answers it fairly, by building two versions of your program and
running them under identical conditions, many times, and comparing hardware-level work counts rather
than the wall clock.

**The manifest is the only thing that knows what your program is.** The harness code contains no
project names, no build scripts, no commands — it reads them all from the manifest. Point it at a
different manifest and it benchmarks a different program with no code change. Everything below is just
you telling it, in JSON, the handful of things it cannot guess.

Think of a manifest as answering seven plain questions:

1. **What am I comparing?** → `repo` (a git repository) and `variants` (two or more of its branches,
   each a version of the code — the "before" and the "after").
2. **How do I build one version?** → `build`: the command that compiles a branch and the `artifact`
   file it produces. The artifact existing is how the harness knows the build worked.
3. **What do I run to exercise it?** → `workloads`: named commands that invoke the built artifact
   (e.g. one subcommand of a tool). Each is a single process — the thing being measured.
4. **What input does it need, and how do I reset it between runs?** → `workspace`: a directory the
   harness restores to a known point (`seed`) before *every* run, so each repetition starts from an
   identical state. Omit it if your workload needs no shared input.
5. **How do I know the output is still correct?** → each workload's `oracle`: a command that exits 0
   when the output matches the known-good result. This is the correctness gate — a speed number only
   counts if the output did not change. (A git `diff --quiet` against a committed "golden" output is
   the recommended way to write one; see the requirements below.)
6. **How do I measure it?** → `telemetry`: which `collector` records a run (PerfView/ETW, your own
   wrapper, or a plain timer), and which `extract` command turns the recording into numbers. The
   `primaryMetric` is the single headline number.
7. **Which pairings do I report, and how often?** → `comparisons` (which baseline-vs-candidate pairs
   to show) and `run` (how many repetitions, and an optional overnight time budget).

The rest of this document is the precise field-by-field version of those seven answers.

**To author your own:** copy [`examples\demo.manifest.json`](../examples/demo.manifest.json) (the smallest complete manifest — it uses
the `time` collector, so it runs with no profiler and no admin rights) and change its fields for your
program. Then, if you want trace-based metrics, switch its `telemetry` to the `perfview` collector as
shown later in this document. The newcomer path is: write the manifest here → run it (see the
harness [`README.md`](../README.md)) → turn the results into a report (see [`docs\metrics-reference.md`](metrics-reference.md)).

## What the subject under test must provide

The harness is subject-agnostic. Any program can be benchmarked by it, in any language, as long as
the manifest can express these things — and *only* the manifest, never the harness code:

- **It builds from a git branch into a detectable artifact.** The comparison is between two branches
  of one repository; the build command and the artifact path go in `build`.
- **A run is a single process invocation.** Whatever you measure has to be one command (the collector
  wraps exactly one process). Multi-step pipelines are split into separate workloads, each seeded to
  the state it expects.
- **Its correctness can be asserted by a command that exits 0 or non-zero.** This is what makes a
  speed result trustworthy: the harness re-checks, every repetition, that the output did not change.
  The most robust form is a diff against a **version-controlled** known-good output — commit the
  expected artifacts once, and let the `oracle` be `git diff --quiet <goldencommit> -- <files>`. Keeping
  the golden output in version control is a reasonable requirement: it gives you an exact, reviewable,
  restorable definition of "correct" for free.
- **A trace of a run can be reduced to numbers.** The `extract` command reads whatever the collector
  produced and emits a JSON object of metrics. The bundled PerfView extractor covers .NET; for
  anything else you supply your own extractor — the harness never parses a trace itself.

If your program meets those four points, it can be benchmarked with a manifest and no change to the
harness. Nothing else — build tooling, project layout, language, output format — is the harness's
business.

## Top-level fields

| Field | Required | Meaning |
|---|---|---|
| `repo` | yes | Path to the git repository whose branches you are comparing. |
| `buildMode` | no | `worktree` (default) builds each variant in its own git worktree; `switch` checks each branch out in `repo` itself (one shared build dir); `clone` builds in a private clone seeded from `repo` so the user's working repo is never touched. See below. |
| `worktreeRoot` | no | Where per-variant worktrees are created (worktree mode only). Defaults to a temp folder. |
| `cloneDir` | no | Where the private clone is created (clone mode only). Relative paths resolve next to the manifest. Defaults to a temp folder. |
| `resultsDir` | no | Where results are written. Relative paths are resolved next to the harness script. Defaults to `results`. |
| `setup` | no | One-time cleanup/preparation commands run before anything else. See below. |
| `build` | yes | How to build one variant. See below. |
| `workspace` | no | A shared working directory that each run restores before it starts. See below. |
| `run` | yes | Repetition counts and guards. See below. |
| `environment` | no | CPU stabilization preferences. See below. |
| `telemetry` | yes | How runs are measured and which metric is the headline. See below. |
| `workloads` | yes | The named commands you can run. See below. |
| `variants` | yes | The branches under test. See below. |
| `comparisons` | yes | The baseline-vs-candidate pairs to report. See below. |

## `setup` (optional)

```json
"setup": {
  "commands": [
    "taskkill /f /t /im iisexpress.exe",
    "taskkill /f /t /im devenv.exe",
    "taskkill /f /t /im dotnet.exe",
    "taskkill /f /t /im msbuild.exe",
    "taskkill /f /t /im vbcscompiler.exe",
    "git -C c:\\work\\checkout2 clean -qdfx",
    "git -C c:\\work\\checkout3 clean -qdfx"
  ]
}
```

A one-time phase that runs once at the start of the harness, after the elevation check and before any
variant is built. Use it to free the machine for a clean measurement: kill stray IDEs, build servers,
and test hosts, and reclaim disk from scratch checkouts.

- `commands` -- a list of commands run in order through `cmd` (so `taskkill`, `git`, and shell
  operators all work). Each runs elevated, like the rest of the harness.
- Commands are **best-effort**: a non-zero exit is logged but does not stop the run. This is
  deliberate -- `taskkill` returns non-zero when the process is not running, which is a normal,
  harmless outcome for a cleanup step.
- The phase runs on every invocation, including `-Resume`; keep the commands idempotent.

## `build`

```json
"build": {
  "command": "dotnet build MyApp.sln -c Release -v quiet --nologo",
  "artifact": "MyApp/bin/Release/myapp.exe"
}
```

- `command` -- runs inside the variant's build dir (its worktree, or `repo` itself in switch mode).
  May use shell operators (it runs via `cmd /c`).
- `artifact` -- the file the build produces, relative to that build dir. Its presence is how the harness
  confirms the build succeeded, and its absolute path is available to workloads as `{artifact}`.

A variant is built once. If the artifact already exists the build is skipped, unless you force a
rebuild. This is the object under test -- do not confuse it with any fixture your workload reads.

## `buildMode`: worktree vs switch vs clone

By default (`"buildMode": "worktree"`) each variant is built in its own git worktree, so every
variant's build dir is a distinct path and all variants can be prebuilt once and reused across reps.

With `"buildMode": "switch"` the harness instead checks each variant's branch out **in `repo`
itself** (`git checkout -f <branch>` + `git clean -xffd`) and builds in place, so every variant -
and an oracle built the same way - uses the **identical** build-dir path. Choose this when the tool
under test embeds its own absolute build-dir path into its output: with worktree mode that path
differs per variant and breaks a byte-identical oracle comparison; switch mode makes it constant.
The trade-off is that the round-robin schedule rebuilds on each branch change, so `switch` suits
tools that build quickly. `worktreeRoot`, `-SkipBuild` worktree reuse, and `-CleanWorktrees` do not
apply in switch mode.

With `"buildMode": "clone"` the harness gets switch mode's single, path-stable build dir **without
ever touching `repo`**: it provisions a private clone at `cloneDir` and runs the switch-in-place
logic there. Both worktree and switch operate on `repo` directly - worktree locks each variant's
branch (so the main repo can't check it out), and switch force-checkouts and `clean -xffd`s the main
repo (moving HEAD and deleting untracked files). Clone mode avoids both: the clone is seeded with
`git clone --local` (object store hardlinked, so near-instant even for a large repo), its variant
branches are hard-synced from the local repo each run, and `origin` is left pointing at the real
upstream. Prefer this whenever `repo` is a repository the user also works in.


## `workspace` (optional)

```json
"workspace": {
  "path": "C:/work/workspace",
  "reset": "git -C {workspace} reset -q --hard {seed} && git -C {workspace} clean -qfdx"
}
```

A single directory that holds the input/output state your workload operates on. Before every run
(including warm-ups) the harness runs `reset` to restore it to a known point. `reset` may use shell
operators. Omit this whole section if your workload needs no shared state.

## `run`

```json
"run": { "warmups": 1, "reps": 6, "budgetHours": 10, "cooldownSec": 60, "keepTrace": "first", "minFreeGB": 30, "maxTraceGB": 3 }
```

| Field | Default | Meaning |
|---|---|---|
| `warmups` | 0 | Discarded runs before measuring, to prime JIT and file caches. Run once per distinct (variant, workload) pair up front -- a pair shared by two comparisons is warmed once, and later round-robin rounds are not re-warmed. |
| `reps` | required | Measured repetitions per arm, run round-robin: every comparison reaches rep *N* before any reaches rep *N+1*. The report uses the median, so unequal counts from an interrupted run still report. Acts as an upper bound when `budgetHours` is set. |
| `budgetHours` | no cap | Wall-clock ceiling for the whole run (setup, build, warm-up, and measurement). The round-robin loop stops launching new cells once the deadline passes, landing the run near a target duration with every comparison measured a comparable number of times. |
| `cooldownSec` | 0 | Seconds to wait between measured runs so the machine settles. Precedes every run but the first, so no idle wait trails the last run. |
| `keepTrace` | rep 1 only | `none` deletes every trace; any other value (`first`, or the default) keeps only rep 1's trace per cell. The harness keeps at most one trace per cell by design (see "Disk safety"), so there is currently no "keep every repetition" setting. |
| `keepOracleIncidents` | on (git workspaces) | When a rep's oracle check FAILs, the diverged workspace is preserved before the next rep discards it. For a git `workspace`, the harness snapshots the whole-tree delta against the oracle's reference commit (the 40-hex SHA named in the workload `oracle` command, else the workload `seed`) into `results/incidents/<cell>/`: `stat.txt`, `numstat.txt`, a readable `incident.diff`, and a reconstructable `incident.patch` (apply onto the reference with `git apply`). Set to `false` to opt out. Non-git workspaces are skipped. |
| `minFreeGB` | no guard | Checked before each run *and* continuously during collection: if free disk on the trace drive drops below this, the in-progress collection is aborted and its partial trace deleted. |
| `maxTraceGB` | no cap | Hard per-trace ceiling. While a trace is being collected the harness watches the growing trace set; if it exceeds this, collection is aborted and the partial trace deleted. This bounds disk use no matter how long or chatty a workload is -- see "Disk safety" below. |

## `environment` (optional)

```json
"environment": { "disableTurbo": true, "recordFrequency": true }
```

Preferences for CPU stabilization. Turbo is disabled at the start of a run and restored at the end
(unless you pass `-NoStabilize`). Frequency is always sampled per run for normalization; this section
documents intent and leaves room for future knobs.

## `telemetry`

```json
"telemetry": {
  "collector": "perfview",
  "traceDir": "C:/work/perf-etl",
  "perfview": {
    "exe": "C:/utils/perfview.exe",
    "kernelEvents": "Process,ImageLoad,Thread",
    "merge": true
  },
  "extract": {
    "command": "dotnet .../etl-perf-report.dll {trace} --process {process} --json {out}",
    "process": "myapp"
  },
  "primaryMetric": "TotalAllocatedMB"
}
```

| Field | Required | Meaning |
|---|---|---|
| `collector` | yes | `perfview` (built-in ETW), `command` (your own wrapper), or `time` (just run and time it). |
| `traceDir` | no | Where trace files are written. Defaults to `traces` under the results dir. |
| `perfview` | if perfview | `exe` path; optional `kernelEvents` and `clrEvents` scopes; optional `cpuCounters` string; `merge` (default true). See "Disk safety". |
| `collect` | if command | `command` template that runs `{command}` and writes a trace to `{trace}`. See below. |
| `extract` | no | External command that turns a trace into a JSON object of numbers. See below. |
| `primaryMetric` | yes | Which number is the headline. Use a name the extractor emits, or a built-in below. |

Built-in metrics always available (no extractor needed): `wallSec`, `freqPct`, `wallSecNorm`.
With the `time` collector these are the only metrics, so `primaryMetric` is normally `wallSecNorm`.

### Disk safety (the `perfview` collector)

ETW traces grow with wall-clock time, and two things dominate the size: kernel CPU-sample **stacks**
and **PMU CPU counters**. On a multi-minute workload a fully-default PerfView trace can reach tens of
gigabytes *per run*, and the harness keeps one trace per cell -- so an unbounded manifest can fill a
disk overnight. Guard against this on two independent levels:

1. **Collect only what the metric needs.** The bundled extractor derives its primary metric
   (`TotalAllocatedMB`) and all GC facts from **CLR** events; kernel CPU samples and PMU counters are
   optional extras it reports only when present. So a lean `perfview` manifest scopes the kernel provider to
   `"kernelEvents": "Process,ImageLoad,Thread"` (enough to name the process, no CPU-sample stacks) and
   omit `cpuCounters` entirely. This alone keeps a long run's trace to a few hundred MB instead of tens
   of GB. Re-enable `cpuCounters` only for short workloads or when you have disk to spare.

   | perfview field | Effect |
   |---|---|
   | `kernelEvents` | Value passed to PerfView `-KernelEvents`. Use `Process,ImageLoad,Thread` for a lean trace, `None` for CLR-only, or omit for PerfView's (large) default. |
   | `clrEvents` | Value passed to PerfView `-ClrEvents`. Omit for the default; narrow it if you need even less. |
   | `cpuCounters` | PMU counters passed to `-CpuCounters`. Very high volume on long runs -- opt-in only. |

2. **A hard watchdog that cannot be out-argued.** Independently of the settings above, while a trace
   is being collected the harness polls the growing trace set and free disk. If the set exceeds
   `run.maxTraceGB`, or free space falls below `run.minFreeGB`, it stops collection immediately --
   killing the workload and PerfView and stopping the ETW sessions with `logman` (never the
   GUI-subsystem `perfview abort`, which can hang) -- then deletes the partial trace. That repetition
   comes back with a non-zero exit and is flagged for review, but the disk is safe. Keep `maxTraceGB`
   set even with lean collection; it is the backstop for a mis-set manifest.

### The `command` collector

Use this when your profiler is not PerfView. You supply a wrapper command that runs the workload and
leaves a trace file for the extractor:

```json
"telemetry": {
  "collector": "command",
  "collect": {
    "command": "pwsh -File wrap.ps1 -Trace \"{trace}\" -Command \"{command}\""
  },
  "extract": { "command": "...", "process": "..." },
  "primaryMetric": "..."
}
```

- `{command}` is substituted with the full workload command line to run, `{trace}` with the trace
  path your wrapper must write, and `{log}` with the run's log path.
- The wrapper may use shell operators (it runs through `cmd`), because it is a setup-style command,
  not the profiled process itself.
- `perfview` is the same idea specialized; `command` is the general seam for any other profiler. It
  also makes the whole collect -> extract -> report pipeline exercisable without admin rights, which
  is how the harness self-tests (see [`examples\testkit`](../examples/testkit) and [`examples\test.manifest.json`](../examples/test.manifest.json)).

### The extractor contract

The extractor is any command that reads a trace and writes a JSON file:

- `{trace}` is substituted with the trace path, `{out}` with the JSON path the harness expects,
  `{process}` with `extract.process`.
- The JSON must be one object (or an array whose first element is the object) whose values are the
  metrics. Numbers at the top level, and numbers one level deep inside a nested object, are picked up;
  a nested value is named `parent.child`. Any of these names can be the `primaryMetric`.

A ready-made extractor for .NET traces ships in [`tools\EtlPerfReport`](../tools/EtlPerfReport) (a .NET 8 console app); the
a `perfview` manifest points `extract.command` at its build output, so **build it once** with
`dotnet build tools\EtlPerfReport -c Release` before the first run. The harness does not build it for
you. To measure a non-.NET program, supply your own extractor here instead — any command that honors
the contract above works.

This is the seam that keeps the harness project-agnostic: it never parses a trace itself.

## `workloads`

```json
"workloads": {
  "analyze": {
    "seed": "v1-in",
    "command": "{artifact} analyze -d {workspace} -v",
    "oracle": "git -C {workspace} diff --quiet v1-out -- output.json",
    "provider": "*MyAppEventSource"
  }
}
```

A workload is one command (a single process invocation), keyed by a name you choose.

| Field | Required | Meaning |
|---|---|---|
| `command` | yes | A single process invocation. **No shell operators** -- the collector wraps exactly one process. |
| `seed` | no | Passed to `workspace.reset` as `{seed}` to restore the precondition this workload needs. |
| `oracle` | no | A command that must exit 0 for the output to count as correct. May use shell operators. |
| `provider` | no | An ETW provider name enabled for this workload (perfview collector only). |

Keep each workload to one process and never combine phases into one command. Separate phases usually depend on
each other's output, which is exactly what `seed` expresses: the seed restores the state a later
phase needs before it runs.

## `variants`

```json
"variants": [
  { "label": "base", "branch": "opt/baseline",  "workloads": ["analyze"] },
  { "label": "cand", "branch": "opt/candidate", "workloads": ["analyze"] }
]
```

Each variant is one branch under test.

| Field | Required | Meaning |
|---|---|---|
| `label` | yes | Short name used in comparisons and reports. |
| `branch` | yes | The git branch to build. Variants must be branches (not tags or raw commits). |
| `workloads` | yes | The workload names this variant can run. |

Requiring branches is a deliberate simplification: branches give readable labels and a clean
worktree per variant with no detached-HEAD handling, at no cost to you.

## `comparisons`

```json
"comparisons": [
  { "name": "speedup", "workload": "analyze", "baseline": "base", "candidate": "cand" }
]
```

Each comparison is one baseline-vs-candidate result on one workload.

| Field | Required | Meaning |
|---|---|---|
| `name` | yes | Unique name; also selects the comparison with `-Only`. |
| `workload` | yes | Which workload to run for both arms. |
| `baseline` | yes | Variant label for the baseline arm. |
| `candidate` | yes | Variant label for the candidate arm. |

The harness validates that a comparison's workload is actually listed by both its variants, and that
every referenced workload and variant exists, before any build starts.

## Placeholders

These may appear in any command template and are substituted per run:

| Placeholder | Available in | Value |
|---|---|---|
| `{repo}` | build, workload | The repository path. |
| `{worktree}` | build | The variant's worktree path. |
| `{artifact}` | workload | Absolute path to the built artifact. |
| `{command}` | collect | The full workload command line the collector must run. |
| `{workspace}` | workload, reset, oracle | The workspace path. |
| `{seed}` | reset | The workload's seed. |
| `{trace}` | collect, extract | The trace file path. |
| `{log}` | collect | The run's log file path. |
| `{out}` | extract | The JSON path the extractor must write. |
| `{process}` | workload, extract | `telemetry.extract.process`. |
| `{label}` | workload | The variant label. |
| `{workload}` | workload | The workload name. |
