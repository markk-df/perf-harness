<#
Common.ps1 -- logging, command-line templating, and shell execution shared by every module.

Native tools (git, dotnet, the workload, the profiler) routinely write to stderr; under the 'Stop'
preference that stderr terminates the run. We use 'Continue' and gate explicitly on exit codes.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

$script:LogFile = $null

function Set-LogFile([string]$Path) {
    $script:LogFile = $Path
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
}

function Write-Log([string]$Message, [string]$Level = 'INFO') {
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $line
    if ($script:LogFile) { Add-Content -LiteralPath $script:LogFile -Value $line }
}

function Expand-Template([string]$Text, [hashtable]$Vars) {
    # Substitutes {name} placeholders from $Vars. Unknown placeholders are left untouched so a
    # command may legitimately contain braces the harness does not own.
    if (-not $Text) { return $Text }
    $out = $Text
    foreach ($key in $Vars.Keys) {
        $out = $out.Replace('{' + $key + '}', [string]$Vars[$key])
    }
    $out
}

function Split-CommandLine([string]$CommandLine) {
    # Splits a single-process invocation into [exe, arg, arg, ...], honoring double quotes. The
    # profiled workload must be one program (no shell operators); setup commands that need a shell
    # go through Invoke-Shell instead.
    $tokens = [System.Collections.Generic.List[string]]::new()
    $current = ''
    $inQuote = $false
    foreach ($ch in $CommandLine.ToCharArray()) {
        if ($ch -eq '"') { $inQuote = -not $inQuote; continue }
        if ($ch -eq ' ' -and -not $inQuote) {
            if ($current.Length) { $tokens.Add($current); $current = '' }
            continue
        }
        $current += $ch
    }
    if ($current.Length) { $tokens.Add($current) }
    $tokens.ToArray()
}

function Invoke-Shell([string]$CommandLine, [string]$LogPath) {
    # Runs a setup command (build, workspace reset, correctness check) through the platform shell so
    # operators like '&&' work: cmd on Windows, /bin/sh elsewhere.
    $out = if ($IsWindows) { & cmd /c $CommandLine 2>&1 } else { & /bin/sh -c $CommandLine 2>&1 }
    if ($LogPath) { $out | Set-Content -LiteralPath $LogPath }
    $LASTEXITCODE
}

function Get-TextHash([string]$Text) {
    # Short, stable fingerprint of a string (first 8 bytes of SHA-256, hex). Used to stamp each result
    # with the setup/telemetry configuration that produced it, so pooled cells can be proven to come
    # from comparable runs.
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text))
        -join ($bytes[0..7] | ForEach-Object { $_.ToString('x2') })
    } finally { $sha.Dispose() }
}
