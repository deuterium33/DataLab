#Requires -Version 5.1
<#
.SYNOPSIS
    Met à jour les paquets DataLab (forks personnels sur GitHub) dans l'environnement conda "datalab" — version Windows.

.DESCRIPTION
    Equivalent PowerShell (conda) de update_datalab_forks.sh :
      - active l'environnement conda via la fonction py_datalab (conda activate datalab)
      - installe en UNE SEULE commande uv les 6 forks git+https (résolution cohérente)
      - génère un fichier d'overrides uv (redirige les pins internes)
      - -Sync       : synchronise les clones locaux (FORKS_DIR) avec leurs upstreams
      - -SyncRemote : synchronise les forks directement sur GitHub (gh ou API REST), SANS clone local

.EXAMPLE
    .\update_datalab_forks.ps1
.EXAMPLE
    .\update_datalab_forks.ps1 -SyncRemote -DryRun
.EXAMPLE
    $env:CONDA_ENV = 'datalab'
    $env:CONSTRAINTS_FILE = "$HOME\datalab-constraints.txt"   # ex: pandas>=1.4,<3.1 / scipy>=1.10.1,<1.17
    .\update_datalab_forks.ps1

.NOTES
    Si l'execution policy bloque le script :  Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
    ou : powershell -ExecutionPolicy Bypass -File .\update_datalab_forks.ps1
#>
[CmdletBinding()]
param(
    [switch]$DryRun,                              # simulation, aucun changement
    [switch]$Reinstall,                           # force la réinstallation complète
    [switch]$NoOverrides,                         # désactive les --override uv
    [switch]$Sync,                                # sync des clones locaux (FORKS_DIR) avant mise à jour
    [switch]$SyncRemote,                          # sync des forks sur GitHub (gh ou GITHUB_TOKEN) avant mise à jour
    [string]$ConstraintsFile = $env:CONSTRAINTS_FILE
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Préambule : activation de l'environnement conda via "py_datalab"
# ---------------------------------------------------------------------------
$CONDA_ENV = [Environment]::GetEnvironmentVariable('CONDA_ENV')
if (-not $CONDA_ENV) { $CONDA_ENV = 'datalab'; $env:CONDA_ENV = $CONDA_ENV }

$condaCmd = Get-Command conda -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $condaCmd) {
    Write-Error "ERREUR : 'conda' est introuvable dans le PATH (conda non installé ou non initialisé)."
    exit 1
}
if ($condaCmd.CommandType -ne 'Function') {
    # Charge le hook PowerShell de conda (utile si 'conda init powershell' n'a pas été fait)
    (& $condaCmd.Source 'shell.powershell' 'hook') | Out-String | Invoke-Expression
}

# Équivalent conda de l'alias bash py_datalab='source "$VENV_datalab/bin/activate"'
function py_datalab { conda activate $env:CONDA_ENV }
py_datalab

if ($env:CONDA_DEFAULT_ENV -ne $env:CONDA_ENV) {
    Write-Error "ERREUR : l'environnement conda '$env:CONDA_ENV' n'a pas pu être activé (conda activate a échoué ?)."
    exit 1
}
Write-Host "Environnement conda actif : $env:CONDA_DEFAULT_ENV ($env:CONDA_PREFIX)"
python --version

# ---------------------------------------------------------------------------
# Vérifications préalables
# ---------------------------------------------------------------------------
if (-not (Get-Command uv -ErrorAction SilentlyContinue)) {
    Write-Error "ERREUR : 'uv' n'est pas installé (voir https://docs.astral.sh/uv/)"
    exit 1
}

# ---------------------------------------------------------------------------
# Paquets à mettre à jour (forks GitHub) + upstreams
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

# Options transmises à uv :
#   --upgrade : met à jour les paquets ET leurs dépendances
#   --refresh : ignore le cache, récupère le dernier commit de chaque fork
$uvOpts = @('--upgrade', '--refresh')
if ($DryRun)    { $uvOpts += '--dry-run' }
if ($Reinstall) { $uvOpts += '--reinstall' }

# Contraintes optionnelles (bornes pandas/SciPy, etc.)
$constraintOpts = @()
if ($ConstraintsFile) {
    if (-not (Test-Path $ConstraintsFile)) {
        Write-Error "ERREUR : CONSTRAINTS_FILE=$ConstraintsFile introuvable"
        exit 1
    }
    $constraintOpts = @('--constraint', $ConstraintsFile)
}

# ---------------------------------------------------------------------------
# Synchronisation des forks
# ---------------------------------------------------------------------------
function Sync-ForkLocal {
    param([string]$Pkg)
    $dir = Join-Path $FORKS_DIR $Pkg
    $upstream = $UPSTREAM[$Pkg]
    if (-not (Test-Path (Join-Path $dir '.git'))) {
        Write-Host "  ! $Pkg : $dir n'est pas un clone git, ignoré"
        Write-Host "    (cloner d'abord : git clone https://github.com/$GITHUB_USER/$Pkg.git vers ce dossier)"
        return
    }
    Write-Host "  → $Pkg : synchronisation depuis $upstream"
    if (-not (git -C $dir remote | Select-String -SimpleMatch 'upstream')) {
        git -C $dir remote add upstream "https://github.com/$upstream.git"
    }
    git -C $dir fetch upstream --prune
    git -C $dir remote set-head upstream --auto   # branche par défaut de l'upstream (master, main, ...)
    if (git -C $dir status --porcelain) {
        Write-Error "  ! $Pkg : working tree sale dans $dir, synchronisation annulée pour ce dépôt"
        exit 1
    }
    $branch = git -C $dir rev-parse --abbrev-ref HEAD
    git -C $dir merge --no-edit upstream/HEAD
    if ($LASTEXITCODE -ne 0) {
        Write-Error "  ! $Pkg : conflit de merge dans $dir — résous manuellement (git -C <dir> status, git add, git merge --continue)"
        exit 1
    }
    if ($GITHUB_TOKEN) {
        git -C $dir push 'https://x-access-token:' + $GITHUB_TOKEN + "@github.com/$GITHUB_USER/$Pkg.git" $branch
    } else {
        git -C $dir push origin $branch
    }
    if ($LASTEXITCODE -ne 0) { Write-Error "  ! $Pkg : push échoué"; exit 1 }
}

function Sync-ForkRemote {
    param([string]$Pkg)
    Write-Host "  → $GITHUB_USER/$Pkg"
    if (Get-Command gh -ErrorAction SilentlyContinue) {
        gh repo sync "$GITHUB_USER/$Pkg"   # sync la branche par défaut du fork depuis le parent (upstream)
        if ($LASTEXITCODE -ne 0) { Write-Error "  ! échec du sync gh pour $Pkg (conflit côté fork ?)"; exit 1 }
        return
    }
    if (-not $GITHUB_TOKEN) {
        Write-Error "ERREUR : -SyncRemote requiert 'gh' (gh auth login) ou la variable d'environnement GITHUB_TOKEN"
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
        Write-Error "  ! échec du sync API pour $Pkg : $($_.Exception.Message)"
        exit 1
    }
}

if ($Sync) {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { Write-Error "ERREUR : 'git' est requis pour -Sync"; exit 1 }
    Write-Host "Synchronisation des forks locaux (FORKS_DIR=$FORKS_DIR) avec leurs upstreams..."
    foreach ($pkg in $PACKAGES) { Sync-ForkLocal -Pkg $pkg }
    Write-Host "Synchronisation terminée."
    Write-Host ""
}

if ($SyncRemote) {
    Write-Host "Synchronisation distante des forks $GITHUB_USER/* depuis leurs upstreams (GitHub)..."
    foreach ($pkg in $PACKAGES) { Sync-ForkRemote -Pkg $pkg }
    Write-Host "Synchronisation distante terminée."
    Write-Host ""
}

# ---------------------------------------------------------------------------
# Construction des dépôts git+https + fichier d'overrides uv
# ---------------------------------------------------------------------------
$overrides = Join-Path $env:TEMP "datalab-overrides.$PID.txt"
try {
    $requirements  = @()
    $overrideLines = @()
    foreach ($pkg in $PACKAGES) {
        $url = 'git+https://' + $AUTH + "github.com/$GITHUB_USER/$pkg.git"
        if ($BRANCH) { $url = "$url@$BRANCH" }
        $requirements  += $url
        # Override : toute dépendance interne sur ce paquet (même un pin ==x.y)
        # est remplacée par le fork git correspondant.
        $overrideLines += "$pkg @ $url"
    }
    $overrideLines | Set-Content -Path $overrides -Encoding ascii

    Write-Host "Dépôts mis à jour :"
    $requirements | ForEach-Object { Write-Host "  - $_" }
    Write-Host ""

    # ---------------------------------------------------------------------------
    # Installation : UNE SEULE commande pour tous les paquets, pour que le
    # résolveur voie l'ensemble des contraintes en une fois et choisisse un jeu
    # de dépendances globalement cohérent.
    # ---------------------------------------------------------------------------
    Write-Host "Mise à jour des $($requirements.Count) paquets..."
    $installArgs = @('pip', 'install') + $uvOpts
    if (-not $NoOverrides) { $installArgs += @('--override', $overrides) }
    $installArgs += $constraintOpts + $requirements
    uv @installArgs
    if ($LASTEXITCODE -ne 0) { Write-Error "ERREUR : uv pip install a échoué"; exit 1 }

    # ---------------------------------------------------------------------------
    # Post-traitement : cohérence de l'environnement + paquets encore obsolètes
    # ---------------------------------------------------------------------------
    Write-Host ""
    Write-Host "Vérification de la cohérence de l'environnement..."
    uv pip check
    if ($LASTEXITCODE -eq 0) { Write-Host "OK : aucune dépendance cassée." }
    else { Write-Warning "ATTENTION : des conflits de dépendances ont été détectés." }

    Write-Host ""
    Write-Host "Paquets tiers encore pas à jour (informatif, non modifiés) :"
    uv pip list --outdated
    if ($LASTEXITCODE -ne 0) { Write-Host "(uv pip list --outdated indisponible sur cette version de uv)" }

    Write-Host ""
    Write-Host "Mise à jour terminée."
}
finally {
    Remove-Item $overrides -ErrorAction SilentlyContinue
}
