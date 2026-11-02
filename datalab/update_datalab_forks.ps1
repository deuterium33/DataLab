#Requires -Version 5.1
<#
.SYNOPSIS
    Updates the DataLab packages (personal GitHub forks) in the conda environment "datalab" - Windows version.

.DESCRIPTION
    PowerShell/conda equivalent of update_datalab_forks.sh :
      - activates the conda env via the py_datalab function (conda activate datalab)
      - installs the 6 git+https forks in ONE single uv command (coherent resolution)
      - generates a uv overrides file (redirects internal pins, e.g. guiqwt -> guidata==3.1)
      - -Sync       : syncs local clones (FORKS_DIR) with their upstreams first
      - -SyncRemote : syncs the forks directly on GitHub (gh or REST API), NO local clone needed

    NOTE: this script is 100% ASCII on purpose. Windows PowerShell 5.1 reads .ps1 files
    without a BOM as ANSI, so any accented character would break parsing. Keep it ASCII,
    or save the file as UTF-8 WITH BOM if you add accents back.

.EXAMPLE
    .\update_datalab_forks.ps1
.EXAMPLE
    .\update_datalab_forks.ps1 -SyncRemote -DryRun
.EXAMPLE
    $env:CONDA_ENV = 'datalab'
    $env:CONSTRAINTS_FILE = "$HOME\datalab-constraints.txt"   # e.g. pandas>=1.4,<3.1 / scipy>=1.10.1,<1.17
    .\update_datalab_forks.ps1

.NOTES
    If the execution policy blocks the script:  Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
    or: powershell -ExecutionPolicy Bypass -File .\update_datalab_forks.ps1
#>
[CmdletBinding()]
param(
    [switch]$DryRun,                              # simulation, no change
    [switch]$Reinstall,                           # force full reinstall
    [switch]$NoOverrides,                         # disable uv --override
    [switch]$Sync,                                # sync local clones (FORKS_DIR) before updating
    [switch]$SyncRemote,                          # sync forks on GitHub (gh or GITHUB_TOKEN) before updating
    [string]$ConstraintsFile = $env:CONSTRAINTS_FILE
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Preamble: activate the conda environment via "py_datalab"
# ---------------------------------------------------------------------------
$CONDA_ENV = [Environment]::GetEnvironmentVariable('CONDA_ENV')
if (-not $CONDA_ENV) { $CONDA_ENV = 'datalab'; $env:CONDA_ENV = $CONDA_ENV }

$condaCmd = Get-Command conda -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $condaCmd) {
    Write-Error "ERROR: 'conda' not found in PATH (conda not installed or not initialized)."
    exit 1
}
if ($condaCmd.CommandType -ne 'Function') {
    # Load conda's PowerShell hook (useful if 'conda init powershell' was never run)
    (& $condaCmd.Source 'shell.powershell' 'hook') | Out-String | Invoke-Expression
}

# conda equivalent of the bash alias py_datalab='source "$VENV_datalab/bin/activate"'
function py_datalab { conda activate $env:CONDA_ENV }
py_datalab

if ($env:CONDA_DEFAULT_ENV -ne $env:CONDA_ENV) {
    Write-Error "ERROR: conda environment '$env:CONDA_ENV' could not be activated (conda activate failed?)."
    exit 1
}
Write-Host "Active conda environment: $env:CONDA_DEFAULT_ENV ($env:CONDA_PREFIX)"
python --version

# ---------------------------------------------------------------------------
# Preliminary checks
# ---------------------------------------------------------------------------
if (-not (Get-Command uv -ErrorAction SilentlyContinue)) {
    Write-Error "ERROR: 'uv' is not installed (see https://docs.astral.sh/uv/)"
    exit 1
}

# ---------------------------------------------------------------------------
# Packages to update (GitHub forks) + upstreams
# ---------------------------------------------------------------------------
$GITHUB_USER  = [Environment]::GetEnvironmentVariable('GITHUB_USER');  if (-not $GITHUB_USER)  { $GITHUB_USER = 'deuterium33' }
$BRANCH       = [Environment]::GetEnvironmentVariable('BRANCH')
$FORKS_DIR    = [Environment]::GetEnvironmentVariable('FORKS_DIR');    if (-not $FORKS_DIR)    { $FORKS_DIR = Join-Path $HOME 'forks' }
$GITHUB_TOKEN = [Environment]::GetEnvironmentVariable('GITHUB_TOKEN')
$PACKAGES = @('guidata', 'guiqwt', 'Sigima', 'SigimaX', 'PlotPy', 'DataLab')

$UPSTREAM = @{
    'guidata' = 'PlotPyStack/guidata'
    'guiqwt'  = 'PlotPyStack/guiqwt'
    'PlotPy'  = 'PlotPyStack/PlotPy'
    'Sigima'  = 'DataLab-Platform/Sigima'
    'SigimaX' = 'DataLab-Platform/SigimaX'
    'DataLab' = 'DataLab-Platform/DataLab'
}

$AUTH = ''
if ($GITHUB_TOKEN) { $AUTH = 'x-access-token:' + $GITHUB_TOKEN + '@' }

# Options passed to uv :
#   --upgrade : upgrades packages AND their dependencies
#   --refresh : ignores the cache, fetches the latest commit of each fork
$uvOpts = @('--upgrade', '--refresh')
if ($DryRun)    { $uvOpts += '--dry-run' }
if ($Reinstall) { $uvOpts += '--reinstall' }

# Optional constraints (pandas/SciPy bounds, etc.)
$constraintOpts = @()
if ($ConstraintsFile) {
    if (-not (Test-Path $ConstraintsFile)) {
        Write-Error "ERROR: CONSTRAINTS_FILE=$ConstraintsFile not found"
        exit 1
    }
    $constraintOpts = @('--constraint', $ConstraintsFile)
}

# ---------------------------------------------------------------------------
# Fork synchronization
# ---------------------------------------------------------------------------
function Sync-ForkLocal {
    param([string]$Pkg)
    $dir = Join-Path $FORKS_DIR $Pkg
    $upstream = $UPSTREAM[$Pkg]
    if (-not (Test-Path (Join-Path $dir '.git'))) {
        Write-Host "  ! $Pkg : $dir is not a git clone, skipped"
        Write-Host "    (clone first: git clone https://github.com/$GITHUB_USER/$Pkg.git into that folder)"
        return
    }
    Write-Host "  -> $Pkg : syncing from $upstream"
    if (-not (git -C $dir remote | Select-String -SimpleMatch 'upstream')) {
        git -C $dir remote add upstream "https://github.com/$upstream.git"
    }
    git -C $dir fetch upstream --prune
    git -C $dir remote set-head upstream --auto   # default branch of the upstream (master, main, ...)
    if (git -C $dir status --porcelain) {
        Write-Error "  ! $Pkg : dirty working tree in $dir, sync aborted for this repo"
        exit 1
    }
    $branch = git -C $dir rev-parse --abbrev-ref HEAD
    git -C $dir merge --no-edit upstream/HEAD
    if ($LASTEXITCODE -ne 0) {
        Write-Error "  ! $Pkg : merge conflict in $dir - resolve manually (git -C <dir> status, git add, git merge --continue)"
        exit 1
    }
    if ($GITHUB_TOKEN) {
        git -C $dir push 'https://x-access-token:' + $GITHUB_TOKEN + "@github.com/$GITHUB_USER/$Pkg.git" $branch
    } else {
        git -C $dir push origin $branch
    }
    if ($LASTEXITCODE -ne 0) { Write-Error "  ! $Pkg : push failed"; exit 1 }
}

function Sync-ForkRemote {
    param([string]$Pkg)
    Write-Host "  -> $GITHUB_USER/$Pkg"
    if (Get-Command gh -ErrorAction SilentlyContinue) {
        gh repo sync "$GITHUB_USER/$Pkg"   # sync the fork's default branch from its parent (upstream)
        if ($LASTEXITCODE -ne 0) { Write-Error "  ! gh sync failed for $Pkg (conflict on the fork side?)"; exit 1 }
        return
    }
    if (-not $GITHUB_TOKEN) {
        Write-Error "ERROR: -SyncRemote requires 'gh' (gh auth login) or the GITHUB_TOKEN environment variable"
        exit 1
    }
    $headers = @{
        Authorization          = 'Bearer ' + $GITHUB_TOKEN
        Accept                 = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = '2022-11-28'
    }
    try {
        $repo = Invoke-RestMethod -Uri "https://api.github.com/repos/$GITHUB_USER/$Pkg" -Headers $headers
        $forkBranch     = $repo.default_branch
        $upstreamBranch = if ($repo.parent) { $repo.parent.default_branch } else { $repo.default_branch }
        $syncParams = @{
            Method      = 'POST'
            Uri         = "https://api.github.com/repos/$GITHUB_USER/$Pkg/branches/$forkBranch/merge-upstream"
            Headers     = $headers
            ContentType = 'application/json'
            Body        = (@{ branch = $upstreamBranch } | ConvertTo-Json)
        }
        Invoke-RestMethod @syncParams
    } catch {
        Write-Error "  ! API sync failed for $Pkg : $($_.Exception.Message)"
        exit 1
    }
}

if ($Sync) {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { Write-Error "ERROR: 'git' is required for -Sync"; exit 1 }
    Write-Host "Syncing local forks (FORKS_DIR=$FORKS_DIR) with their upstreams..."
    foreach ($pkg in $PACKAGES) { Sync-ForkLocal -Pkg $pkg }
    Write-Host "Sync finished."
    Write-Host ""
}

if ($SyncRemote) {
    Write-Host "Remote-syncing forks $GITHUB_USER/* from their upstreams (GitHub)..."
    foreach ($pkg in $PACKAGES) { Sync-ForkRemote -Pkg $pkg }
    Write-Host "Remote sync finished."
    Write-Host ""
}

# ---------------------------------------------------------------------------
# Build the git+https repo list + uv overrides file
# ---------------------------------------------------------------------------
$overrides = Join-Path $env:TEMP "datalab-overrides.$PID.txt"
try {
    $requirements  = @()
    $overrideLines = @()
    foreach ($pkg in $PACKAGES) {
        $url = 'git+https://' + $AUTH + "github.com/$GITHUB_USER/$pkg.git"
        if ($BRANCH) { $url = "$url@$BRANCH" }
        $requirements  += $url
        # Override: any internal dependency on this package (even a ==x.y pin)
        # is replaced by the corresponding git fork.
        $overrideLines += "$pkg @ $url"
    }
    $overrideLines | Set-Content -Path $overrides -Encoding ascii

    Write-Host "Repos being updated:"
    $requirements | ForEach-Object { Write-Host "  - $_" }
    Write-Host ""

    # ---------------------------------------------------------------------------
    # Installation: ONE single command for all packages, so that the resolver
    # sees all constraints at once and picks a globally coherent dependency set.
    # ---------------------------------------------------------------------------
    Write-Host "Updating $($requirements.Count) packages..."
    $installArgs = @('pip', 'install') + $uvOpts
    if (-not $NoOverrides) { $installArgs += @('--override', $overrides) }
    $installArgs += $constraintOpts + $requirements
    uv @installArgs
    if ($LASTEXITCODE -ne 0) { Write-Error "ERROR: uv pip install failed"; exit 1 }

    # ---------------------------------------------------------------------------
    # Post-processing: environment consistency + still outdated packages
    # ---------------------------------------------------------------------------
    Write-Host ""
    Write-Host "Checking environment consistency..."
    uv pip check
    if ($LASTEXITCODE -eq 0) { Write-Host "OK: no broken dependencies." }
    else { Write-Warning "WARNING: dependency conflicts detected." }

    Write-Host ""
    Write-Host "Third-party packages still outdated (informational, not modified):"
    uv pip list --outdated
    if ($LASTEXITCODE -ne 0) { Write-Host "(uv pip list --outdated not available in this uv version)" }

    Write-Host ""
    Write-Host "Update finished."
}
finally {
    Remove-Item $overrides -ErrorAction SilentlyContinue
}
