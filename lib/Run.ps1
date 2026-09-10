<#
Run.ps1 -- execute one measured repetition of a (variant, workload) pair and report its result.

A repetition seeds the shared workspace to the workload's precondition, runs the built artifact
under the configured collector while sampling CPU frequency, then checks output correctness and
extracts frequency-invariant metrics from the trace. The result is a self-describing record; the
caller owns interleaving, warm-ups, retention, and journalling.
#>

function Get-VariantCommandLine($Manifest, $Variant, [string]$WorkloadName, [string]$Artifact) {
    # The exact command a (variant, workload) pair runs: the workload's command template with run-time
    # placeholders filled, then the variant's optional args appended (see Get-VariantArgs). Centralized
    # so the measured rep and the warm-up always run the identical command line, and so per-variant
    # args let two variants share one branch and differ only by command line.
    $workload = $Manifest.workloads.$WorkloadName
    $vars = @{ repo = $Manifest.repo; artifact = $Artifact; label = $Variant.label; workload = $WorkloadName }
    if ($Manifest.telemetry.PSObject.Properties.Name -contains 'extract') { $vars['process'] = $Manifest.telemetry.extract.process }
    if ($Manifest.PSObject.Properties.Name -contains 'workspace') { $vars['workspace'] = $Manifest.workspace.path }
    $commandLine = Expand-Template $workload.command $vars
    $extra = Get-VariantArgs $Variant
    if ($extra) { $commandLine = $commandLine.TrimEnd() + ' ' + (Expand-Template $extra $vars).Trim() }
    $commandLine
}

function Invoke-MeasuredRep($Manifest, $Variant, [string]$WorkloadName, [string]$Artifact, [string]$TracePath, [string]$LogPath) {
    $workload = $Manifest.workloads.$WorkloadName
    Reset-Workspace $Manifest $workload

    $commandLine   = Get-VariantCommandLine $Manifest $Variant $WorkloadName $Artifact
    $commandTokens = Split-CommandLine $commandLine

    $freqFile = [IO.Path]::ChangeExtension($TracePath, '.freq.txt')
    $sampler  = Start-FrequencySampler $freqFile
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $collected = Invoke-Collector $Manifest $workload $commandLine $commandTokens $TracePath $LogPath
    $stopwatch.Stop()
    $freqPct = Stop-FrequencySampler $sampler $freqFile

    $wallSec  = [math]::Round($stopwatch.Elapsed.TotalSeconds, 1)
    $wallNorm = if ($freqPct -gt 0) { [math]::Round($wallSec * $freqPct / 100, 1) } else { $wallSec }

    $metrics = Get-TraceMetrics $Manifest $collected.TracePath
    $intrinsics = [ordered]@{ wallSec = $wallSec; freqPct = $freqPct; wallSecNorm = $wallNorm }

    [ordered]@{
        variant    = $Variant.label
        workload   = $WorkloadName
        command    = $commandLine
        exit       = $collected.ExitCode
        oracle     = Test-Oracle $Manifest $workload
        tracePath  = $collected.TracePath
        wallSec    = $wallSec
        freqPct    = $freqPct
        wallSecNorm= $wallNorm
        metrics    = (Merge-Ordered $intrinsics $metrics)
    }
}

function Invoke-Warmup($Manifest, $Variant, [string]$WorkloadName, [string]$Artifact, [string]$LogPath) {
    # A warm-up run primes the JIT and the filesystem cache; it is never collected or measured.
    $workload = $Manifest.workloads.$WorkloadName
    Reset-Workspace $Manifest $workload
    $tokens = Split-CommandLine (Get-VariantCommandLine $Manifest $Variant $WorkloadName $Artifact)
    & $tokens[0] @($tokens[1..($tokens.Count - 1)]) *> $LogPath
}

function Remove-TraceSet([string]$TracePath) {
    if (-not $TracePath) { return }
    $stem = [IO.Path]::Combine([IO.Path]::GetDirectoryName($TracePath), [IO.Path]::GetFileNameWithoutExtension($TracePath))
    Get-ChildItem "$stem*" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
}

function Reset-Workspace($Manifest, $Workload) {
    if ($Manifest.PSObject.Properties.Name -notcontains 'workspace') { return }
    $vars = @{ workspace = $Manifest.workspace.path; seed = $Workload.seed }
    $command = Expand-Template $Manifest.workspace.reset $vars
    Invoke-Shell $command $null | Out-Null
}

function Save-OracleIncident($Manifest, [string]$WorkloadName, [string]$Cell, [string]$ResultsDir) {
    # A failed oracle means the rep's output diverged from the reference commit. The diverged
    # workspace is about to be discarded by the next rep's Reset-Workspace, so unless it is captured
    # now the evidence is gone and the divergence can never be investigated. When the workspace is a
    # git repo we preserve the delta against the oracle's own reference (the 40-hex commit named in
    # the oracle command) under results/incidents/<cell>: a readable diff, a reconstructable binary
    # patch, and stat/numstat summaries. On by default for any oracle-gated git workspace; set
    # run.keepOracleIncidents to false to opt out. Non-git workspaces are skipped so the harness stays
    # workspace-agnostic.
    if ($Manifest.run.PSObject.Properties.Name -contains 'keepOracleIncidents' -and -not $Manifest.run.keepOracleIncidents) { return }
    if ($Manifest.PSObject.Properties.Name -notcontains 'workspace') { return }
    $ws = $Manifest.workspace.path
    if (-not (Test-Path (Join-Path $ws '.git'))) { return }

    $workload = $Manifest.workloads.$WorkloadName
    $oracle = if ($workload.PSObject.Properties.Name -contains 'oracle') { [string]$workload.oracle } else { '' }
    $ref = if ($oracle -match '([0-9a-f]{40})') { $Matches[1] } elseif ($workload.seed) { [string]$workload.seed } else { 'HEAD' }

    $safe = ($Cell -replace '[^0-9A-Za-z._-]', '_')
    $out  = Join-Path (Join-Path $ResultsDir 'incidents') $safe
    New-Item -ItemType Directory -Force -Path $out | Out-Null

    # Stage everything (so new untracked outputs count), snapshot the whole-tree delta against the
    # oracle reference, then unstage. The working tree is left as the rep produced it; the next rep's
    # reset --hard + clean restores it.
    Invoke-Shell "git -C `"$ws`" add -A" $null | Out-Null
    Invoke-Shell "git -C `"$ws`" diff --cached --stat $ref > `"$out\stat.txt`"" $null | Out-Null
    Invoke-Shell "git -C `"$ws`" diff --cached --numstat $ref > `"$out\numstat.txt`"" $null | Out-Null
    Invoke-Shell "git -C `"$ws`" diff --cached $ref > `"$out\incident.diff`"" $null | Out-Null
    Invoke-Shell "git -C `"$ws`" diff --cached --binary $ref > `"$out\incident.patch`"" $null | Out-Null
    Invoke-Shell "git -C `"$ws`" reset -q" $null | Out-Null
    Write-Log "oracle incident preserved -> $out (delta vs $ref)" 'WARN'
}

function Invoke-Collector($Manifest, $Workload, [string]$CommandLine, [string[]]$CommandTokens, [string]$TracePath, [string]$LogPath) {
    $exe     = $CommandTokens[0]
    $cmdArgs = @($CommandTokens[1..($CommandTokens.Count - 1)])
    switch ($Manifest.telemetry.collector) {
        'perfview' { Invoke-PerfViewCollector $Manifest.telemetry $Manifest.run $Workload $exe $cmdArgs $TracePath $LogPath }
        'command'  { Invoke-CommandCollector $Manifest.telemetry $CommandLine $TracePath $LogPath }
        'time'     { Invoke-TimeCollector $exe $cmdArgs $LogPath }
        default    { throw "unknown collector: $($Manifest.telemetry.collector)" }
    }
}

function Invoke-CommandCollector($Telemetry, [string]$CommandLine, [string]$TracePath, [string]$LogPath) {
    # A caller-supplied collector: its command wraps the workload (available as {command}) and must
    # leave a trace at {trace} for the extractor to read. This is the general bring-your-own-profiler
    # path -- the PerfView collector is the same idea specialized. Shell operators are allowed here
    # because the wrapper is a setup-style command, not the profiled process itself.
    $vars = @{ command = $CommandLine; trace = $TracePath; log = $LogPath }
    $collect = Expand-Template $Telemetry.collect.command $vars
    $exit = Invoke-Shell $collect $LogPath
    @{ ExitCode = $exit; TracePath = $TracePath }
}

function Invoke-PerfViewCollector($Telemetry, $Run, $Workload, [string]$Exe, [string[]]$CommandArgs, [string]$TracePath, [string]$LogPath) {
    # PerfView is a GUI-subsystem binary: all options precede 'run', the target follows as separate
    # tokens, and only Start-Process -Wait blocks until collection and merge finish.
    $pvArgs = @('-NoGui','-AcceptEULA',"-LogFile:$LogPath","-DataFile:$TracePath",'-NoNGenPdbs','-Zip:false')
    # Kernel CPU-sample stacks and PMU counters are what make a long trace explode to tens of GB.
    # The extractor only needs CLR GC events for its primary metric, so a manifest can scope kernel
    # collection (e.g. 'Process,ImageLoad,Thread' for process-name resolution, or 'None') and omit
    # cpuCounters. Both are opt-in: defaults are unchanged when the keys are absent.
    if ($Telemetry.perfview.PSObject.Properties.Name -contains 'kernelEvents' -and $Telemetry.perfview.kernelEvents) {
        $pvArgs += "-KernelEvents:$($Telemetry.perfview.kernelEvents)"
    }
    if ($Telemetry.perfview.PSObject.Properties.Name -contains 'clrEvents' -and $Telemetry.perfview.clrEvents) {
        $pvArgs += "-ClrEvents:$($Telemetry.perfview.clrEvents)"
    }
    if ($Telemetry.perfview.PSObject.Properties.Name -contains 'cpuCounters' -and $Telemetry.perfview.cpuCounters) { $pvArgs += "-CpuCounters:$($Telemetry.perfview.cpuCounters)" }
    if ($Workload.PSObject.Properties.Name -contains 'provider' -and $Workload.provider) { $pvArgs += "-Providers:$($Workload.provider)" }
    $merge = if ($Telemetry.perfview.PSObject.Properties.Name -contains 'merge') { [bool]$Telemetry.perfview.merge } else { $true }
    $pvArgs += "-Merge:$($merge.ToString().ToLower())"
    $pvArgs += @('run', $Exe) + $CommandArgs

    $process = Start-Process -FilePath $Telemetry.perfview.exe -ArgumentList $pvArgs -NoNewWindow -PassThru
    $watch = Watch-Collection $process $Exe $TracePath $Run
    if ($watch.Aborted) { return @{ ExitCode = $watch.ExitCode; TracePath = $null; Aborted = $true } }
    @{ ExitCode = $process.ExitCode; TracePath = $TracePath }
}

function Get-TraceSetSizeGB([string]$TracePath) {
    # PerfView emits several sibling files while collecting (.etl, .kernel.etl, ...); the disk cost is
    # their sum, so we watch the whole set.
    $stem = [IO.Path]::Combine([IO.Path]::GetDirectoryName($TracePath), [IO.Path]::GetFileNameWithoutExtension($TracePath))
    $bytes = (Get-ChildItem "$stem*" -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
    if ($bytes) { [math]::Round($bytes / 1GB, 2) } else { 0 }
}

function Watch-Collection($Process, [string]$WorkloadExe, [string]$TracePath, $Run) {
    # A hard disk safety net that is independent of the manifest's collection settings: while PerfView
    # runs, poll the growing trace set and free space. If a single trace exceeds run.maxTraceGB, or free
    # space falls below run.minFreeGB, stop collection immediately (abort the ETW sessions, kill the
    # collector and the workload) and discard the partial trace so the disk can never fill. The rep
    # comes back with a non-zero exit and is flagged for review rather than silently corrupting the run.
    $maxTraceGB = if ($Run.PSObject.Properties.Name -contains 'maxTraceGB') { [double]$Run.maxTraceGB } else { 0 }
    $minFreeGB  = if ($Run.PSObject.Properties.Name -contains 'minFreeGB')  { [double]$Run.minFreeGB }  else { 0 }
    $workloadName = [IO.Path]::GetFileNameWithoutExtension($WorkloadExe)

    while (-not $Process.HasExited) {
        Start-Sleep -Seconds 5
        $sizeGB = Get-TraceSetSizeGB $TracePath
        $freeGB = try { Get-PathFreeGB $TracePath } catch { [double]::MaxValue }
        $overSize = $maxTraceGB -gt 0 -and $sizeGB -gt $maxTraceGB
        $lowDisk  = $minFreeGB  -gt 0 -and $freeGB -lt $minFreeGB
        if (-not ($overSize -or $lowDisk)) { continue }

        $reason = if ($overSize) { "trace set ${sizeGB}GB exceeds maxTraceGB ${maxTraceGB}GB" }
                  else           { "free ${freeGB}GB below minFreeGB ${minFreeGB}GB (trace set ${sizeGB}GB)" }
        Write-Log "disk watchdog: aborting collection -- $reason" 'ERROR'
        # Order matters and nothing here may block. First kill the traced workload and the PerfView
        # collector so no process keeps generating events, then stop PerfView's ETW sessions -- they
        # outlive the process and keep writing kernel events to the file. We use logman (a fast,
        # GUI-less built-in) rather than 'perfview abort', which is a GUI-subsystem call that can hang
        # and would strand the disk exactly when we are trying to protect it.
        Get-Process $workloadName -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        if (-not $Process.HasExited) { Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue }
        foreach ($session in @('PerfViewSession', 'NT Kernel Logger', 'PerfViewSessionHeap', 'PerfView-DotNetVersionLogger-Session')) {
            & logman stop $session -ets 2>&1 | Out-Null
        }
        Start-Sleep -Seconds 2
        Remove-TraceSet $TracePath
        return @{ Aborted = $true; ExitCode = 199 }
    }
    @{ Aborted = $false; ExitCode = $Process.ExitCode }
}

function Invoke-TimeCollector([string]$Exe, [string[]]$CommandArgs, [string]$LogPath) {
    & $Exe @CommandArgs *> $LogPath
    @{ ExitCode = $LASTEXITCODE; TracePath = $null }
}

function Test-Oracle($Manifest, $Workload) {
    if (-not ($Workload.PSObject.Properties.Name -contains 'oracle') -or -not $Workload.oracle) { return 'SKIP' }
    $vars = @{ workspace = $Manifest.workspace.path }
    $command = Expand-Template $Workload.oracle $vars
    if ((Invoke-Shell $command $null) -eq 0) { 'PASS' } else { 'FAIL' }
}

function Get-TraceMetrics($Manifest, [string]$TracePath) {
    if (-not $TracePath) { return [ordered]@{} }
    if ($Manifest.telemetry.PSObject.Properties.Name -notcontains 'extract') { return [ordered]@{} }

    $outFile = [IO.Path]::ChangeExtension($TracePath, '.metrics.json')
    $vars = @{ trace = $TracePath; out = $outFile; process = $Manifest.telemetry.extract.process }
    $command = Expand-Template $Manifest.telemetry.extract.command $vars
    Invoke-Shell $command $null | Out-Null
    if (-not (Test-Path $outFile)) { return [ordered]@{} }

    try { ConvertTo-FlatMetrics (Get-Content $outFile -Raw | ConvertFrom-Json) }
    catch { [ordered]@{} }
}

function ConvertTo-FlatMetrics($Report) {
    # The extractor may emit an object or an array of per-process objects; we flatten the first
    # object's numeric leaves (one level of nesting) so any named counter becomes a selectable metric.
    $first = if ($Report -is [array]) { $Report[0] } else { $Report }
    $flat = [ordered]@{}
    foreach ($property in $first.PSObject.Properties) {
        if (Test-Numeric $property.Value) { $flat[$property.Name] = [double]$property.Value }
        elseif ($property.Value -is [System.Management.Automation.PSCustomObject]) {
            foreach ($nested in $property.Value.PSObject.Properties) {
                if (Test-Numeric $nested.Value) { $flat["$($property.Name).$($nested.Name)"] = [double]$nested.Value }
            }
        }
    }
    $flat
}

function Test-Numeric($Value) {
    $Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal]
}

function Merge-Ordered($First, $Second) {
    $merged = [ordered]@{}
    foreach ($k in $First.Keys)  { $merged[$k] = $First[$k] }
    foreach ($k in $Second.Keys) { $merged[$k] = $Second[$k] }
    $merged
}
