<#
Repo.ps1 -- turn each improvement's branch into a built artifact.

Every variant is a git branch (an opinionated requirement: branches give readable labels). Two build
models are supported:

  worktree (default) -- each branch is built once in its own git worktree under worktreeRoot, so all
    variants stay built in parallel and a round-robin run never rebuilds. Best for small/medium trees.

  switch (buildMode = "switch") -- all variants share one checkout (the manifest's repo): before a
    variant runs we check out its branch, clean the tree, and build in place. This keeps every build
    at the identical path, which is what lets a tool that records its own location produce
    byte-identical output across the variants and the oracle -- a per-variant worktree would bake a
    different path into each build. The active branch is cached so consecutive cells on the same
    variant do not rebuild. Best for large trees (one checkout instead of N) and path-sensitive tools.

  clone (buildMode = "clone") -- like switch, but the shared checkout is a private clone seeded from
    the manifest's repo rather than the repo itself. The harness never checks out, cleans, or locks a
    branch in the user's working repo. The clone is seeded with `git clone --local` (object store is
    hardlinked, so this is near-instant even for a large repo); variant branch refs are hard-synced
    from the local repo each run; origin is left pointing at the real upstream. Prefer this over
    switch whenever the manifest's repo is a repo the user also works in.
#>

$script:ActiveVariantLabel = $null
$script:HarnessSkipBuild    = $false

function Test-SwitchMode($Manifest) {
    ($Manifest.PSObject.Properties.Name -contains 'buildMode') -and ($Manifest.buildMode -eq 'switch')
}

function Test-CloneMode($Manifest) {
    ($Manifest.PSObject.Properties.Name -contains 'buildMode') -and ($Manifest.buildMode -eq 'clone')
}

function Resolve-CloneDir($Manifest) {
    if ($Manifest.PSObject.Properties.Name -contains 'cloneDir') { $Manifest.cloneDir }
    else { Join-Path ([IO.Path]::GetTempPath()) 'perf-harness-clone' }
}

function Initialize-Clone($Manifest, [string]$CloneDir) {
    # Seed a private clone from the LOCAL repo and build every variant inside it, so the harness never
    # touches the user's working repo (no branch lock, no HEAD move, no `clean -xffd` of their files).
    # `git clone --local` hardlinks the object store -- near-instant even for a large repo. Variant
    # branch refs are (re)synced from the local repo via a dedicated 'seed' remote every run; origin is
    # then pointed at the real upstream so the clone still looks like a normal clone of the project.
    $src = $Manifest.repo
    if (-not (Test-Path (Join-Path $CloneDir '.git'))) {
        if (Test-Path $CloneDir) { Remove-Item -Recurse -Force $CloneDir }
        Write-Log "clone build model: seeding $CloneDir from local repo $src"
        git clone --local -- $src $CloneDir 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "could not clone '$src' into '$CloneDir'" }
    }
    git -C $CloneDir remote remove seed 2>&1 | Out-Null
    git -C $CloneDir remote add seed $src 2>&1 | Out-Null
    git -C $CloneDir fetch --no-tags seed "+refs/heads/*:refs/remotes/seed/*" 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "could not fetch branches from local repo '$src' into clone '$CloneDir'" }
    # Detach HEAD so every variant branch (even one currently checked out) can be hard-synced to its
    # local tip; Switch-Branch then checks these local branches out per cell.
    git -C $CloneDir checkout -f --detach 2>&1 | Out-Null
    foreach ($v in $Manifest.variants) {
        git -C $CloneDir branch -f $v.branch "seed/$($v.branch)" 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "variant branch '$($v.branch)' not found in local repo '$src'" }
    }
    $upstream = git -C $src remote get-url origin 2>$null
    if ($LASTEXITCODE -eq 0 -and $upstream) { git -C $CloneDir remote set-url origin $upstream.Trim() 2>&1 | Out-Null }
}

function Use-Variant($Manifest, $Variant) {
    # switch model: ensure the shared repo is checked out to the variant's branch and freshly built,
    # then return the artifact (always the same path). Cached by active label so a repeated variant
    # does not rebuild.
    $repo     = $Manifest.repo
    $artifact = Join-Path $repo $Manifest.build.artifact

    if ($script:ActiveVariantLabel -eq $Variant.label -and (Test-Path $artifact)) { return $artifact }

    if ($script:HarnessSkipBuild -and (Test-Path $artifact) -and ((Get-CurrentBranch $repo) -eq $Variant.branch)) {
        $script:ActiveVariantLabel = $Variant.label
        Write-Log "variant '$($Variant.label)': reusing existing build"
        return $artifact
    }

    Write-Log "variant '$($Variant.label)' (branch $($Variant.branch)): checkout + build"
    Switch-Branch $repo $Variant.branch

    $vars = @{ repo = $repo; worktree = $repo; label = $Variant.label }
    $command = Expand-Template $Manifest.build.command $vars
    $exit = Invoke-Build -Command $command -WorkingDir $repo

    if ($exit -ne 0 -or -not (Test-Path $artifact)) {
        throw "variant '$($Variant.label)': build failed (exit $exit, artifact present=$(Test-Path $artifact))"
    }
    $script:ActiveVariantLabel = $Variant.label
    Write-Log "variant '$($Variant.label)': built -> $artifact"
    $artifact
}

function Switch-Branch([string]$Repo, [string]$Branch) {
    # Force the tree to exactly this branch: discard any working changes, switch, then remove untracked
    # and ignored files (build outputs) so the rebuild cannot inherit the previous variant's artifacts.
    git -C $Repo checkout -f $Branch 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "could not checkout branch '$Branch' in $Repo (does the branch exist?)" }
    git -C $Repo clean -xffd 2>&1 | Out-Null
}

function Get-CurrentBranch([string]$Repo) {
    $name = git -C $Repo rev-parse --abbrev-ref HEAD 2>$null
    if ($LASTEXITCODE -eq 0 -and $name) { $name.Trim() } else { $null }
}

function Build-Variant($Manifest, $Variant, [string]$WorktreeRoot, [switch]$Force) {
    $worktree = Join-Path $WorktreeRoot $Variant.label
    $artifact = Join-Path $worktree $Manifest.build.artifact

    if ((Test-Path $artifact) -and -not $Force) {
        Write-Log "variant '$($Variant.label)': reusing existing build"
        return $artifact
    }

    Add-Worktree -Repo $Manifest.repo -Branch $Variant.branch -Path $worktree

    $vars = @{ repo = $Manifest.repo; worktree = $worktree; label = $Variant.label }
    $command = Expand-Template $Manifest.build.command $vars
    Write-Log "variant '$($Variant.label)' (branch $($Variant.branch)): building"
    $exit = Invoke-Build -Command $command -WorkingDir $worktree

    if ($exit -ne 0 -or -not (Test-Path $artifact)) {
        throw "variant '$($Variant.label)': build failed (exit $exit, artifact present=$(Test-Path $artifact))"
    }
    Write-Log "variant '$($Variant.label)': built -> $artifact"
    $artifact
}

function Add-Worktree([string]$Repo, [string]$Branch, [string]$Path) {
    if (Test-Path $Path) {
        git -C $Repo worktree remove --force $Path 2>&1 | Out-Null
        Remove-Item -Recurse -Force $Path -ErrorAction SilentlyContinue
    }
    git -C $Repo worktree add --force $Path $Branch 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "could not add worktree for branch '$Branch' (does the branch exist?)" }
}

function Invoke-Build([string]$Command, [string]$WorkingDir) {
    Push-Location $WorkingDir
    try { Invoke-Shell $Command $null }
    finally { Pop-Location }
}

function Get-VariantCommit($Manifest, $Variant) {
    # The variant's commit is the tip of its branch, read directly from the ref so it is correct in
    # both build models regardless of which branch is currently checked out in the shared repo.
    $sha = git -C $Manifest.repo rev-parse $Variant.branch 2>$null
    if ($LASTEXITCODE -eq 0 -and $sha) { $sha.Trim() } else { $null }
}

function Remove-Worktrees([string]$Repo, [string]$WorktreeRoot) {
    if (-not (Test-Path $WorktreeRoot)) { return }
    foreach ($dir in Get-ChildItem $WorktreeRoot -Directory) {
        git -C $Repo worktree remove --force $dir.FullName 2>&1 | Out-Null
    }
    git -C $Repo worktree prune 2>&1 | Out-Null
    Remove-Item -Recurse -Force $WorktreeRoot -ErrorAction SilentlyContinue
}
