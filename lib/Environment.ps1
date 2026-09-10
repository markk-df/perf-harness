<#
Environment.ps1 -- reduce CPU-frequency variance and record what frequency each run actually saw.

Wall-clock is only corroborating evidence: on many laptops the firmware's autonomous frequency
control ignores OS hard caps, so the same work takes a different number of seconds each time. We do
the one thing that is reliably honored -- disable turbo boost -- and, because even that leaves a
residual band, we record every run's average frequency so wall-clock can be normalized to base.
The trustworthy signal remains the frequency-invariant metrics from the extractor.

We mutate a duplicate of the active power scheme; restore reactivates the original and deletes it.
#>

$script:PerfBoostAlias  = 'PERFBOOSTMODE'
$script:PerfAutonomous  = '8baa4a8a-14c6-4451-8e8b-14bdbd197537'
$script:SavedSchemeFile = $null

function Set-FrequencyStable([string]$StateDir) {
    $script:SavedSchemeFile = Join-Path $StateDir '.orig-power-scheme'
    Repair-StaleScheme $script:SavedSchemeFile
    $orig = Get-ActiveSchemeGuid
    $dup  = ((powercfg /duplicatescheme $orig) -replace '.*GUID:\s*([0-9a-fA-F-]+).*', '$1').Trim()
    Set-Content -LiteralPath $script:SavedSchemeFile -Value "$orig`n$dup"

    powercfg -attributes SUB_PROCESSOR $script:PerfAutonomous -ATTRIB_HIDE 2>&1 | Out-Null
    foreach ($plane in 'setacvalueindex','setdcvalueindex') {
        powercfg /$plane $dup SUB_PROCESSOR $script:PerfBoostAlias 0 | Out-Null
        powercfg /$plane $dup SUB_PROCESSOR $script:PerfAutonomous 0 | Out-Null
    }
    powercfg /setactive $dup | Out-Null
    Start-Sleep -Seconds 5
    Write-Log "frequency stabilized (turbo off); idle performance ~$(Get-FrequencyPercent)% of base"
}

function Restore-Frequency {
    if (-not $script:SavedSchemeFile -or -not (Test-Path $script:SavedSchemeFile)) { return }
    $orig, $dup = (Get-Content -LiteralPath $script:SavedSchemeFile) | ForEach-Object { $_.Trim() }
    powercfg /setactive $orig | Out-Null
    if ($dup -and $dup -ne $orig) { powercfg /delete $dup 2>&1 | Out-Null }
    Remove-Item -LiteralPath $script:SavedSchemeFile -ErrorAction SilentlyContinue
    Write-Log "frequency restored (active=$orig)"
}

function Repair-StaleScheme([string]$File) {
    # Restore-Frequency runs in the harness's finally block, but a hard external kill (Stop-Process on
    # the host shell) bypasses it and strands the turbo-off duplicate: it stays the ACTIVE scheme and
    # its original GUID is left recorded here. If we then snapshot the active scheme as our "original"
    # we would freeze the already-degraded duplicate and leak a new scheme on every crash. So on
    # startup we recover any prior run's state first -- reactivate its saved original, delete its dup.
    if (-not (Test-Path $File)) { return }
    $orig, $dup = (Get-Content -LiteralPath $File) | ForEach-Object { $_.Trim() }
    if ($orig) { powercfg /setactive $orig 2>&1 | Out-Null }
    if ($dup -and $dup -ne $orig) { powercfg /delete $dup 2>&1 | Out-Null }
    Remove-Item -LiteralPath $File -ErrorAction SilentlyContinue
    Write-Log "recovered power scheme from a prior interrupted run (reactivated $orig, deleted stale dup $dup)" 'WARN'
}

function Get-ActiveSchemeGuid {
    ((powercfg /getactivescheme) -replace '.*GUID:\s*([0-9a-fA-F-]+).*', '$1').Trim()
}

function Test-Administrator {
    # Elevation is a Windows concept; ETW collection (PerfView) and power-scheme changes both need it.
    if (-not $IsWindows) { return $true }
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-Elevation([string]$Collector, [bool]$Stabilize) {
    $elevated = Test-Administrator
    if ($elevated) { Write-Log 'running elevated (Administrator)'; return }

    $reasons = @()
    if ($Collector -eq 'perfview') { $reasons += "the 'perfview' collector needs ETW access" }
    if ($Stabilize)                { $reasons += 'CPU stabilization changes power settings' }
    if ($reasons.Count) {
        throw "administrator rights required: $($reasons -join '; '). Re-run in an elevated shell, or use -NoStabilize with the 'time'/'command' collector."
    }
    Write-Log "not elevated; allowed because collector '$Collector' and no stabilization require it" 'WARN'
}

function Get-FrequencyPercent {
    try { [math]::Round((Get-Counter '\Processor Information(_Total)\% Processor Performance' -ErrorAction Stop).CounterSamples[0].CookedValue, 1) }
    catch { -1 }
}

function Start-FrequencySampler([string]$File) {
    # In-process ThreadJob rather than Start-Job: a store-packaged pwsh has no pwsh.exe at the fixed
    # path Start-Job spawns, so Start-Job fails and would abort every measured rep. Frequency sampling
    # is optional (it only normalizes wall time); if it cannot start, degrade to no frequency data
    # (freqPct = -1) instead of failing the run.
    Remove-Item $File -ErrorAction SilentlyContinue
    try {
        Start-ThreadJob -ScriptBlock {
            param($f)
            Get-Counter '\Processor Information(_Total)\% Processor Performance' -Continuous -SampleInterval 2 |
                ForEach-Object { $_.CounterSamples[0].CookedValue | Add-Content -LiteralPath $f }
        } -ArgumentList $File
    } catch {
        Write-Log "frequency sampler unavailable ($($_.Exception.Message)) -- continuing without frequency data" 'WARN'
        $null
    }
}

function Stop-FrequencySampler($Job, [string]$File) {
    if ($Job) { Stop-Job $Job -ErrorAction SilentlyContinue; Remove-Job $Job -Force -ErrorAction SilentlyContinue }
    if (-not (Test-Path $File)) { return -1 }
    $samples = @(Get-Content $File | Where-Object { $_ -match '^\d' } | ForEach-Object { [double]$_ })
    if ($samples.Count -eq 0) { return -1 }
    [math]::Round(($samples | Measure-Object -Average).Average, 1)
}
