<#
Serve-Results.ps1 -- tiny read-only static HTTP server for a results directory.

Fronts a finished run's results so a reviewer can browse report.md / report.json / results.csv
from a laptop over `kubectl port-forward <pod> 8080:8080`. Serves a directory index at every
folder and each file with a sensible content type. Markdown is rendered to HTML (client-side via
marked.js) so report.md reads as a formatted page; append `?raw=1` to any .md URL for the source.
No upload, no execution, no write path. Single-threaded by design: one reviewer, a handful of files.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$Root,
    [int]$Port = 8080
)

$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path -LiteralPath $Root).Path
$sep = [IO.Path]::DirectorySeparatorChar

$ctype = @{
    '.md' = 'text/plain; charset=utf-8'; '.txt' = 'text/plain; charset=utf-8'
    '.log' = 'text/plain; charset=utf-8'; '.csv' = 'text/csv; charset=utf-8'
    '.json' = 'application/json; charset=utf-8'; '.jsonl' = 'application/x-ndjson; charset=utf-8'
    '.html' = 'text/html; charset=utf-8'; '.patch' = 'text/plain; charset=utf-8'
    '.diff' = 'text/plain; charset=utf-8'; '.etl' = 'application/octet-stream'
}

function New-Listener([string]$prefix) {
    $l = [System.Net.HttpListener]::new()
    $l.Prefixes.Add($prefix)
    $l.Start()
    $l
}

try {
    $listener = New-Listener "http://+:$Port/"
}
catch {
    # '+' needs an admin url-acl reservation; loopback never does, and kubectl port-forward
    # reaches the pod's 127.0.0.1, so it is an adequate fallback.
    $listener = New-Listener "http://localhost:$Port/"
}
Write-Host "serving $Root on $($listener.Prefixes -join ', ')"

function Send-Bytes($ctx, [int]$code, [byte[]]$body, [string]$type) {
    $ctx.Response.StatusCode = $code
    $ctx.Response.ContentType = $type
    $ctx.Response.ContentLength64 = $body.Length
    $ctx.Response.OutputStream.Write($body, 0, $body.Length)
    $ctx.Response.OutputStream.Close()
}

function Get-MarkdownHtml([string]$markdown, [string]$title) {
    # The markdown is handed to the browser base64-encoded and rendered by marked.js, so no
    # server-side HTML escaping is needed and the raw bytes survive verbatim. The CDN is fetched
    # by the reviewer's browser (which has internet), not by the pod.
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($markdown))
    @"
<!doctype html><html><head><meta charset="utf-8"><title>$title</title>
<style>
 body{font:15px/1.6 -apple-system,Segoe UI,Arial,sans-serif;max-width:1100px;margin:2rem auto;padding:0 1rem;color:#1f2328}
 table{border-collapse:collapse;margin:1rem 0;font-size:13px}
 th,td{border:1px solid #d0d7de;padding:4px 9px}
 th{background:#f6f8fa} tr:nth-child(even) td{background:#f6f8fa}
 code{background:#eff1f3;padding:.1em .3em;border-radius:4px;font-size:90%}
 pre{background:#f6f8fa;padding:12px;border-radius:6px;overflow:auto}
 h1,h2,h3{border-bottom:1px solid #d8dee4;padding-bottom:.2em}
 a.raw{float:right;font-size:12px}
</style></head><body>
<a class="raw" href="?raw=1">view raw</a>
<article id="content"></article>
<script src="https://cdn.jsdelivr.net/npm/marked/marked.min.js"></script>
<script>
 const md=new TextDecoder().decode(Uint8Array.from(atob("$b64"),c=>c.charCodeAt(0)));
 document.getElementById("content").innerHTML=marked.parse(md);
 // The content is rendered after load, so the browser's initial jump to #metric-* found nothing;
 // scroll to it ourselves once the anchors exist, and keep following in-page fragment links.
 function gotoHash(){if(!location.hash)return;const el=document.getElementById(decodeURIComponent(location.hash.slice(1)));if(el)el.scrollIntoView();}
 gotoHash();
 window.addEventListener("hashchange",gotoHash);
</script></body></html>
"@
}

while ($listener.IsListening) {
    $ctx = $listener.GetContext()
    try {
        $rel = [Uri]::UnescapeDataString($ctx.Request.Url.AbsolutePath).TrimStart('/')
        $full = [IO.Path]::GetFullPath($(if ($rel) { Join-Path $Root $rel } else { $Root }))
        if ($full -ne $Root -and -not $full.StartsWith($Root + $sep, [StringComparison]::OrdinalIgnoreCase)) {
            Send-Bytes $ctx 403 ([Text.Encoding]::UTF8.GetBytes('forbidden')) 'text/plain; charset=utf-8'
        }
        elseif (Test-Path -LiteralPath $full -PathType Container) {
            $rows = Get-ChildItem -LiteralPath $full | Sort-Object { -not $_.PSIsContainer }, Name | ForEach-Object {
                $name = $_.Name + $(if ($_.PSIsContainer) { '/' } else { '' })
                "<li><a href=""$name"">$name</a></li>"
            }
            $html = "<!doctype html><meta charset=utf-8><title>results</title><h1>/$rel</h1><ul>$($rows -join '')</ul>"
            Send-Bytes $ctx 200 ([Text.Encoding]::UTF8.GetBytes($html)) 'text/html; charset=utf-8'
        }
        elseif (Test-Path -LiteralPath $full -PathType Leaf) {
            $ext = [IO.Path]::GetExtension($full).ToLowerInvariant()
            $raw = $ctx.Request.QueryString['raw'] -eq '1'
            if ($ext -eq '.md' -and -not $raw) {
                $html = Get-MarkdownHtml ([IO.File]::ReadAllText($full)) ([IO.Path]::GetFileName($full))
                Send-Bytes $ctx 200 ([Text.Encoding]::UTF8.GetBytes($html)) 'text/html; charset=utf-8'
            }
            else {
                $type = if ($ctype.ContainsKey($ext)) { $ctype[$ext] } else { 'application/octet-stream' }
                Send-Bytes $ctx 200 ([IO.File]::ReadAllBytes($full)) $type
            }
        }
        else {
            Send-Bytes $ctx 404 ([Text.Encoding]::UTF8.GetBytes('not found')) 'text/plain; charset=utf-8'
        }
    }
    catch {
        try { Send-Bytes $ctx 500 ([Text.Encoding]::UTF8.GetBytes($_.Exception.Message)) 'text/plain; charset=utf-8' } catch { }
    }
    Write-Host ("{0} {1} -> {2}" -f (Get-Date -Format HH:mm:ss), $ctx.Request.Url.AbsolutePath, $ctx.Response.StatusCode)
}
