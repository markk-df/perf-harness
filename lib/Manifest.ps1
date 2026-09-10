<#
Manifest.ps1 -- load a benchmark manifest and prove it is internally consistent before any run.

The manifest is the single source of truth for a project's benchmark: what to build, which git
branches represent the improvements, which atomic workloads each improvement runs, how to collect
and extract telemetry, and which A/B comparisons to report. See docs/manifest-reference.md.
#>

function Read-Manifest([string]$Path, [bool]$RequireRepo = $true, [string]$BaseDir = '') {
    if (-not (Test-Path $Path)) { throw "manifest not found: $Path" }
    $raw = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if ($BaseDir) {
        foreach ($field in 'repo','worktreeRoot','cloneDir') {
            if ($raw.PSObject.Properties.Name -contains $field) {
                $raw.$field = Resolve-ManifestPath $raw.$field $BaseDir
            }
        }
    }
    Assert-Manifest $raw $RequireRepo
    $raw
}

function Resolve-ManifestPath([string]$Path, [string]$BaseDir) {
    if (-not $Path -or [IO.Path]::IsPathRooted($Path)) { return $Path }
    [IO.Path]::GetFullPath([IO.Path]::Combine($BaseDir, $Path))
}

function Get-WorkloadNames($Manifest) {
    $Manifest.workloads.PSObject.Properties.Name
}

function Assert-Manifest($M, [bool]$RequireRepo = $true) {
    $problems = [System.Collections.Generic.List[string]]::new()

    foreach ($field in 'repo','build','workloads','variants','comparisons','run','telemetry') {
        if (-not $M.PSObject.Properties.Name.Contains($field)) { $problems.Add("missing top-level field: $field") }
    }
    if ($problems.Count) { throw "invalid manifest:`n - $($problems -join "`n - ")" }

    if ($RequireRepo -and -not (Test-Path $M.repo)) { $problems.Add("repo path does not exist: $($M.repo)") }
    if (-not $M.build.command)    { $problems.Add('build.command is required') }
    if (-not $M.build.artifact)   { $problems.Add('build.artifact (path within the repo/worktree) is required') }
    if (($M.PSObject.Properties.Name -contains 'buildMode') -and ($M.buildMode -notin 'worktree','switch','clone')) {
        $problems.Add("buildMode must be 'worktree', 'switch', or 'clone' (got '$($M.buildMode)')")
    }

    $workloadNames = @(Get-WorkloadNames $M)
    foreach ($w in $workloadNames) {
        $wl = $M.workloads.$w
        if (-not $wl.command) { $problems.Add("workload '$w' has no command") }
    }

    $variantLabels = @($M.variants | ForEach-Object { $_.label })
    foreach ($v in $M.variants) {
        if (-not $v.label)  { $problems.Add('a variant has no label') }
        if (-not $v.branch) { $problems.Add("variant '$($v.label)' has no branch (branches are required)") }
        if (($v.PSObject.Properties.Name -contains 'args') -and ($null -ne $v.args) -and ($v.args -isnot [string])) {
            $problems.Add("variant '$($v.label)' args must be a string (a command-line fragment)")
        }
        foreach ($w in $v.workloads) {
            if ($w -notin $workloadNames) { $problems.Add("variant '$($v.label)' references unknown workload '$w'") }
        }
    }

    # Two variants may deliberately share one branch and differ only by args (to isolate a single
    # command-line flag without a throwaway branch). That requires a build model where one checkout is
    # reused: worktree would try to check the same branch out twice. 'clone' is normalized to 'switch'
    # at run time, so only these two are safe.
    $buildMode = if ($M.PSObject.Properties.Name -contains 'buildMode') { $M.buildMode } else { 'worktree' }
    if ($buildMode -notin 'switch','clone') {
        $M.variants | Group-Object branch | Where-Object { $_.Count -gt 1 } | ForEach-Object {
            $labels = ($_.Group | ForEach-Object label) -join ', '
            $problems.Add("branch '$($_.Name)' is shared by variants [$labels]; same-branch variants require buildMode 'switch' or 'clone' (worktree cannot check one branch out twice)")
        }
    }

    foreach ($c in $M.comparisons) {
        foreach ($side in 'baseline','candidate') {
            $label = $c.$side
            if ($label -notin $variantLabels) { $problems.Add("comparison '$($c.name)' $side '$label' is not a variant"); continue }
            $variant = $M.variants | Where-Object { $_.label -eq $label }
            if ($c.workload -notin $variant.workloads) {
                $problems.Add("comparison '$($c.name)' needs workload '$($c.workload)' but variant '$label' does not run it")
            }
        }
        $base = $M.variants | Where-Object { $_.label -eq $c.baseline }
        $cand = $M.variants | Where-Object { $_.label -eq $c.candidate }
        if ($base -and $cand -and ($base.branch -eq $cand.branch) -and ((Get-VariantArgs $base) -eq (Get-VariantArgs $cand))) {
            $problems.Add("comparison '$($c.name)': baseline '$($c.baseline)' and candidate '$($c.candidate)' are identical (same branch and args) -- nothing to compare")
        }
    }

    $collector = if ($M.telemetry.PSObject.Properties.Name -contains 'collector') { $M.telemetry.collector } else { $null }
    if ($collector -notin 'perfview','command','time') {
        $problems.Add("telemetry.collector must be 'perfview', 'command', or 'time' (got '$collector')")
    }
    if ($collector -eq 'perfview' -and -not (Get-NestedValue $M.telemetry 'perfview' 'exe')) {
        $problems.Add("collector 'perfview' requires telemetry.perfview.exe")
    }
    if ($collector -eq 'command' -and -not (Get-NestedValue $M.telemetry 'collect' 'command')) {
        $problems.Add("collector 'command' requires telemetry.collect.command (a wrapper that runs {command} and writes {trace})")
    }

    if ($problems.Count) { throw "invalid manifest:`n - $($problems -join "`n - ")" }
}

function Get-NestedValue($Object, [string]$Parent, [string]$Child) {
    if ($Object.PSObject.Properties.Name -notcontains $Parent) { return $null }
    $inner = $Object.$Parent
    if ($null -eq $inner -or $inner.PSObject.Properties.Name -notcontains $Child) { return $null }
    $inner.$Child
}
