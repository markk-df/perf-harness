<#
Common.ps1 -- logging, command-line templating, and shell execution shared by every module.

Native tools (git, dotnet, the workload, the profiler) routinely write to stderr; under the 'Stop'
preference that stderr terminates the run. We use 'Continue' and gate explicitly on exit codes.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

$script:LogFile = $null

if ($IsWindows -and -not ([System.Management.Automation.PSTypeName]'PerfHarness.Disk').Type) {
    # GetDiskFreeSpaceEx reports free space on the volume that actually contains a path, including a
    # volume mounted to a folder (a container's C:\data, a bind mount) -- which GetPathRoot/DriveInfo
    # cannot see, because they collapse the path to its drive-letter root.
    Add-Type -Namespace PerfHarness -Name Disk -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet = System.Runtime.InteropServices.CharSet.Auto, SetLastError = true)]
public static extern bool GetDiskFreeSpaceEx(string path, out ulong freeBytesAvailable, out ulong totalBytes, out ulong totalFreeBytes);
'@
}

function Get-PathFreeGB([string]$Path) {
    # Free space, in GB, on the volume that holds $Path. The disk watchdog needs this because the trace
    # directory is frequently a volume mounted to a folder (e.g. a container's C:\data), so measuring
    # the drive-letter root would watch a different volume than the one the trace is filling. On any
    # measurement failure we return the max value, so a failed probe can never trip the guard and abort
    # an otherwise healthy run.
    $full = [IO.Path]::GetFullPath($Path)
    if ($IsWindows) {
        $free = [uint64]0; $total = [uint64]0; $totalFree = [uint64]0
        if ([PerfHarness.Disk]::GetDiskFreeSpaceEx($full, [ref]$free, [ref]$total, [ref]$totalFree)) {
            return [math]::Round($free / 1GB, 1)
        }
        return [double]::MaxValue
    }
    # POSIX: the containing mount is the drive whose root is the longest prefix of the full path.
    $mount = [IO.DriveInfo]::GetDrives() |
        Where-Object { $full.StartsWith($_.RootDirectory.FullName) } |
        Sort-Object { $_.RootDirectory.FullName.Length } -Descending |
        Select-Object -First 1
    if ($mount) { [math]::Round($mount.AvailableFreeSpace / 1GB, 1) } else { [double]::MaxValue }
}

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

function Get-VariantArgs($Variant) {
    # A variant's optional extra command-line arguments, appended to the workload command it runs.
    # This is what lets two variants share one branch and differ only by command line, so a comparison
    # can isolate a single flag or option without building a throwaway branch for it. Absent or null
    # means no extra arguments.
    if (($Variant.PSObject.Properties.Name -contains 'args') -and ($null -ne $Variant.args)) { [string]$Variant.args }
    else { '' }
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
