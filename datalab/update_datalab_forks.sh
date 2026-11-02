#!/usr/bin/env bash
#
# update_datalab_forks.sh
# Met à jour les paquets DataLab (forks personnels sur GitHub) dans le venv "py_datalab".
#
# Usage :
#   ./update_datalab_forks.sh               # mise à jour normale
#   ./update_datalab_forks.sh --dry-run     # simulation, aucun changement
#   ./update_datalab_forks.sh --reinstall   # force la réinstallation complète
#   ./update_datalab_forks.sh --sync        # synchronise d'abord les clones locaux
#                                           # des forks avec leurs upstreams, puis met à jour
#   ./update_datalab_forks.sh --sync-remote # synchronise les forks directement sur GitHub
#                                           # (via gh ou l'API, SANS clone local), puis met à jour
#   ./update_datalab_forks.sh --no-overrides  # désactive les --override uv
#
# Note : un fichier d'overrides est généré automatiquement. Il redirige toutes
# les exigences internes entre paquets vers les forks git, afin que
# la résolution de dépendances soit toujours satisfiable.
#
# Variables d'environnement optionnelles :
#   VENV_datalab   chemin du venv      (défaut : $HOME/venvs/datalab)
#   GITHUB_USER    propriétaire GitHub (défaut : deuterium33)
#   BRANCH         branche à suivre    (défaut : branche par défaut de chaque dépôt)
#   GITHUB_TOKEN   PAT pour forks privés (scope "repo")
#   CONSTRAINTS_FILE  fichier de contraintes uv optionnel
#   FORKS_DIR      dossier contenant les clones locaux des forks (avec --sync)
#                  (défaut : $HOME/forks/<nom-du-paquet>)

set -euo pipefail

# ---------------------------------------------------------------------------
# Préambule : activation du venv via l'alias "py_datalab"
# ---------------------------------------------------------------------------
VENV_datalab="${VENV_datalab:-$HOME/venvs/datalab}"

# Dans un script non interactif, les alias ne sont pas développés par défaut :
shopt -s expand_aliases
alias py_datalab='source "$VENV_datalab/bin/activate"'

if [ ! -f "$VENV_datalab/bin/activate" ]; then
    echo "ERREUR : venv introuvable à $VENV_datalab" >&2
    echo "Définis VENV_datalab=/chemin/vers/ton/venv, ou crée le venv d'abord." >&2
    exit 1
fi
py_datalab

echo "Venv actif : $VIRTUAL_ENV"
python --version

# ---------------------------------------------------------------------------
# Vérifications préalables
# ---------------------------------------------------------------------------
if ! command -v uv >/dev/null 2>&1; then
    echo "ERREUR : 'uv' n'est pas installé (voir https://docs.astral.sh/uv/)" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Paquets à mettre à jour (forks GitHub)
# ---------------------------------------------------------------------------
GITHUB_USER="${GITHUB_USER:-deuterium33}"
BRANCH="${BRANCH:-}"
PACKAGES=(guidata guiqwt Sigima SigimaX PlotPy DataLab)

# Upstream (projet d'origine) de chaque fork
declare -A UPSTREAM=(
    [guidata]="PlotPyStack/guidata"
    [guiqwt]="PlotPyStack/guiqwt"
    [PlotPy]="PlotPyStack/PlotPy"
    [Sigima]="DataLab-Platform/Sigima"
    [SigimaX]="DataLab-Platform/SigimaX"
    [DataLab]="DataLab-Platform/DataLab"
)
FORKS_DIR="${FORKS_DIR:-$HOME/forks}"

# Authentification facultative pour des forks privés
AUTH=""
if [ -n "${GITHUB_TOKEN:-}" ]; then
    AUTH="x-access-token:${GITHUB_TOKEN}@"
fi

# Options transmises à uv :
#   --upgrade  : met à jour les paquets ET leurs dépendances si nécessaire
#   --refresh  : ignore le cache, récupère le dernier commit de chaque fork
UV_OPTS=(--upgrade --refresh)
USE_OVERRIDES=1
DO_SYNC=0
DO_SYNC_REMOTE=0
for arg in "$@"; do
    case "$arg" in
        --dry-run)      UV_OPTS+=(--dry-run) ;;
        --reinstall)    UV_OPTS+=(--reinstall) ;;
        --no-overrides) USE_OVERRIDES=0 ;;
        --sync)         DO_SYNC=1 ;;
        --sync-remote)  DO_SYNC_REMOTE=1 ;;
        *) echo "Option inconnue ignorée : $arg" >&2 ;;
    esac
done

# ---------------------------------------------------------------------------
# Contraintes supplémentaires optionnelles (CONSTRAINTS_FILE)
# ---------------------------------------------------------------------------
CONSTRAINTS_FILE="${CONSTRAINTS_FILE:-}"
CONSTRAINT_OPTS=()
if [ -n "$CONSTRAINTS_FILE" ]; then
    if [ ! -f "$CONSTRAINTS_FILE" ]; then
        echo "ERREUR : CONSTRAINTS_FILE=$CONSTRAINTS_FILE introuvable" >&2
        exit 1
    fi
    CONSTRAINT_OPTS=(--constraint "$CONSTRAINTS_FILE")
fi

# ---------------------------------------------------------------------------
# Synchronisation préalable des forks locaux avec leurs upstreams (--sync)
# ---------------------------------------------------------------------------
sync_fork() {
    local pkg="$1" dir="$FORKS_DIR/$pkg" upstream="${UPSTREAM[$pkg]}"
    if [ ! -d "$dir/.git" ]; then
        echo "  ! $pkg : $dir n'est pas un clone git, ignoré"
        echo "    (cloner d'abord : git clone https://github.com/${GITHUB_USER}/${pkg}.git \"$dir\")"
        return 0
    fi
    echo "  → $pkg : synchronisation depuis ${upstream}"
    git -C "$dir" remote add upstream "https://github.com/${upstream}.git" 2>/dev/null || true
    git -C "$dir" fetch upstream --prune
    git -C "$dir" remote set-head upstream --auto   # branche par défaut de l'upstream (master, main, ...)
    if [ -n "$(git -C "$dir" status --porcelain)" ]; then
        echo "  ! $pkg : working tree sale dans $dir, synchronisation annulée pour ce dépôt" >&2
        return 1
    fi
    local branch
    branch="$(git -C "$dir" rev-parse --abbrev-ref HEAD)"
    if ! git -C "$dir" merge --no-edit upstream/HEAD; then
        echo "  ! $pkg : conflit de merge dans $dir, à résoudre manuellement :" >&2
        echo "      git -C \"$dir\" status   # puis résoudre, git add, git merge --continue"
        return 1
    fi
    # Push vers le fork (origin), ou via URL authentifiée si GITHUB_TOKEN est défini
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        git -C "$dir" push "https://x-access-token:${GITHUB_TOKEN}@github.com/${GITHUB_USER}/${pkg}.git" "$branch"
    else
        git -C "$dir" push origin "$branch"
    fi
}

if [ "$DO_SYNC" -eq 1 ]; then
    if ! command -v git >/dev/null 2>&1; then
        echo "ERREUR : 'git' est requis pour --sync" >&2
        exit 1
    fi
    echo "Synchronisation des forks locaux (FORKS_DIR=$FORKS_DIR) avec leurs upstreams..."
    for pkg in "${PACKAGES[@]}"; do
        sync_fork "$pkg" || exit 1
    done
    echo "Synchronisation terminée."
    echo
fi

# ---------------------------------------------------------------------------
# Synchronisation distante des forks directement sur GitHub (--sync-remote)
# SANS clone local : via 'gh repo sync' si gh est installé, sinon via l'API
# REST (POST /repos/<fork>/branches/<branche>/merge-upstream) avec GITHUB_TOKEN.
# ---------------------------------------------------------------------------
if [ "$DO_SYNC_REMOTE" -eq 1 ]; then
    if ! command -v gh >/dev/null 2>&1 && [ -z "${GITHUB_TOKEN:-}" ]; then
        echo "ERREUR : --sync-remote requiert 'gh' (https://cli.github.com/ + 'gh auth login') ou la variable GITHUB_TOKEN" >&2
        exit 1
    fi
    echo "Synchronisation distante des forks ${GITHUB_USER}/* depuis leurs upstreams (GitHub)..."
    for pkg in "${PACKAGES[@]}"; do
        echo "  → ${GITHUB_USER}/${pkg}"
        if command -v gh >/dev/null 2>&1; then
            # Sync la branche par défaut du fork depuis le parent (upstream)
            gh repo sync "${GITHUB_USER}/${pkg}" || { echo "  ! échec du sync pour $pkg (conflit côté fork ?)" >&2; exit 1; }
        else
            command -v curl >/dev/null 2>&1 || { echo "ERREUR : curl requis" >&2; exit 1; }
            command -v jq   >/dev/null 2>&1 || { echo "ERREUR : jq requis" >&2; exit 1; }
            repo_json="$(curl -fsS -H "Authorization: Bearer ${GITHUB_TOKEN}" -H "Accept: application/vnd.github+json" "https://api.github.com/repos/${GITHUB_USER}/${pkg}")"
            fork_branch="$(printf '%s' "$repo_json" | jq -r '.default_branch')"
            upstream_branch="$(printf '%s' "$repo_json" | jq -r '.parent.default_branch // .default_branch')"
            curl -fsS -X POST -H "Authorization: Bearer ${GITHUB_TOKEN}" -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" \
                "https://api.github.com/repos/${GITHUB_USER}/${pkg}/branches/${fork_branch}/merge-upstream" \
                -d "{\"branch\":\"${upstream_branch}\"}" >/dev/null || { echo "  ! échec du sync pour $pkg (conflit côté fork ?)" >&2; exit 1; }
        fi
    done
    echo "Synchronisation distante terminée."
    echo
fi

# ---------------------------------------------------------------------------
# Construction de la liste des dépôts git+https + fichier d'overrides uv
# ---------------------------------------------------------------------------
OVERRIDES="${TMPDIR:-/tmp}/datalab-overrides.${BASHPID:-$RANDOM}"
trap 'rm -f "$OVERRIDES"' EXIT

REQUIREMENTS=()
for pkg in "${PACKAGES[@]}"; do
    url="git+https://${AUTH}github.com/${GITHUB_USER}/${pkg}.git"
    if [ -n "$BRANCH" ]; then
        url="${url}@${BRANCH}"
    fi
    REQUIREMENTS+=("$url")
    # Override : toute dépendance interne sur ce paquet (même un pin ==x.y)
    # est remplacée par le fork git correspondant.
    printf '%s @ %s\n' "$pkg" "$url" >> "$OVERRIDES"
done

echo "Dépôts mis à jour :"
for url in "${REQUIREMENTS[@]}"; do
    echo "  - $url"
done
echo

# ---------------------------------------------------------------------------
# Installation : UNE SEULE commande pour tous les paquets, pour que le
# résolveur voie l'ensemble des contraintes en une fois et choisisse un jeu
# de dépendances globalement cohérent (évite les conflits entre versions
# imposées par DataLab, PlotPy, Sigima, etc.).
# ---------------------------------------------------------------------------
echo "Mise à jour des ${#REQUIREMENTS[@]} paquets..."
if [ "$USE_OVERRIDES" -eq 1 ]; then
    uv pip install "${UV_OPTS[@]}" --override "$OVERRIDES" ${CONSTRAINT_OPTS[@]+"${CONSTRAINT_OPTS[@]}"} "${REQUIREMENTS[@]}"
else
    uv pip install "${UV_OPTS[@]}" ${CONSTRAINT_OPTS[@]+"${CONSTRAINT_OPTS[@]}"} "${REQUIREMENTS[@]}"
fi

# ---------------------------------------------------------------------------
# Post-traitement : cohérence de l'environnement + paquets encore obsolètes
# ---------------------------------------------------------------------------
echo
echo "Vérification de la cohérence de l'environnement..."
if uv pip check; then
    echo "OK : aucune dépendance cassée."
else
    echo "ATTENTION : des conflits de dépendances ont été détectés." >&2
fi

echo
echo "Paquets tiers encore pas à jour (informatif, non modifiés) :"
uv pip list --outdated || true

echo
echo "Mise à jour terminée."
