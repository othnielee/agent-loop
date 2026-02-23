#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# agl-deploy — Self-updater for agent-loop
#
# Clones the agent-loop repo, deploys bin/ scripts to ~/bin/
# and templates to ~/.config/solt/agent-loop/templates/.
# ------------------------------------------------------------

CONFIG_FILE="$HOME/.config/solt/agent-loop/deploy.toml"
TEMPLATE_DEST="$HOME/.config/solt/agent-loop/templates"
TARGET_SHEBANG='#!/usr/bin/env bash'

# ------------------------------------------------------------
# Config reader (simple TOML)
# ------------------------------------------------------------
get_config() {
  local section="$1" key="$2"
  if [[ ! -f "$CONFIG_FILE" ]]; then
    echo ""
    return
  fi
  sed -n "/^\[$section\]/,/^\[/p" "$CONFIG_FILE" |
    grep "^$key" | head -1 |
    cut -d'=' -f2- | tr -d ' "' | tr -d "'" |
    sed 's|^~/|'"$HOME"'/|' || true
}

# ------------------------------------------------------------
# Load config with fallbacks
# ------------------------------------------------------------
GH_USER="$(get_config github user)"
GH_REPO_NAME="$(get_config github repo)"
PAT="$(get_config github pat)"
REF="$(get_config github ref)"

[[ -z "$GH_USER" ]] && GH_USER="othnielee"
[[ -z "$GH_REPO_NAME" ]] && GH_REPO_NAME="agent-loop"
[[ -z "$REF" ]] && REF="main"

# Environment variable override
[[ -n "${GH_PAT:-}" ]] && PAT="$GH_PAT"

KEEP_TEMP=0

usage() {
  cat <<EOF
Usage: $0 [--pat TOKEN] [--ref REF] [--keep-temp]

Config file: $CONFIG_FILE

Options:
  --pat         Override PAT from config (or set in config file)
  --ref         Branch/tag/commit to clone (default: main)
  --keep-temp   Keep temp dir for debugging
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
  --pat)
    [[ $# -ge 2 && "$2" != -* ]] || {
      echo "Error: Missing value for --pat" >&2
      exit 1
    }
    PAT="$2"
    shift 2
    ;;
  --ref)
    [[ $# -ge 2 && "$2" != -* ]] || {
      echo "Error: Missing value for --ref" >&2
      exit 1
    }
    REF="$2"
    shift 2
    ;;
  --keep-temp)
    KEEP_TEMP=1
    shift
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    echo "Unknown arg: $1" >&2
    usage
    exit 1
    ;;
  esac
done

if [[ -z "${PAT:-}" ]]; then
  echo "Error: PAT is required. Set it in $CONFIG_FILE or use --pat." >&2
  exit 1
fi

# ------------------------------------------------------------
# Helpers
# ------------------------------------------------------------
ensure_dir() { mkdir -p "$1"; }
have_cmd() { command -v "$1" >/dev/null 2>&1; }

prepend_shebang_copy() {
  local src="$1" dest="$2" shebang="$3"
  awk -v sb="$shebang" '
    NR==1 {
      if ($0 ~ /^#!/) { print sb; next }
      else { print sb; print; next }
    }
    { print }
  ' "$src" >"$dest"
  chmod 0755 "$dest"
}

rawurlencode() {
  local s="$1" i c
  for ((i = 0; i < ${#s}; i++)); do
    c=${s:i:1}
    case "$c" in
    [a-zA-Z0-9.~_-]) printf '%s' "$c" ;;
    *) printf '%%%02X' "'$c" ;;
    esac
  done
}

# ------------------------------------------------------------
# Clone, scrub remote, auto-clean
# ------------------------------------------------------------
have_cmd git || {
  echo "git is required." >&2
  exit 1
}

WORKDIR="$(mktemp -d)"
if ((!KEEP_TEMP)); then
  trap 'rm -rf "$WORKDIR"' EXIT
fi

SRC_DIR="$WORKDIR/src"
ensure_dir "$SRC_DIR"

ENC_PAT="$(rawurlencode "$PAT")"
CLONE_URL="https://${GH_USER}:${ENC_PAT}@github.com/${GH_USER}/${GH_REPO_NAME}.git"

echo "Cloning repo to temp dir..."
(
  set +x
  git clone --depth=1 --branch "$REF" "$CLONE_URL" "$SRC_DIR"
) >/dev/null

# Scrub token from remote URL immediately
git -C "$SRC_DIR" remote set-url origin "https://github.com/${GH_USER}/${GH_REPO_NAME}.git" >/dev/null

# ------------------------------------------------------------
# Deploy bin/ scripts -> ~/bin/
# ------------------------------------------------------------
BIN_SRC="$SRC_DIR/bin"
if [[ -d "$BIN_SRC" ]]; then
  echo "Deploying bin/ -> \$HOME/bin"
  ensure_dir "$HOME/bin"
  shopt -s nullglob
  for f in "$BIN_SRC"/*.sh; do
    base="$(basename "$f")"
    name="${base%.sh}"
    dest="$HOME/bin/$name"
    tmp="$WORKDIR/$name.tmp"

    echo "  - $base -> ~/bin/$name"
    prepend_shebang_copy "$f" "$tmp" "$TARGET_SHEBANG"
    install -m 0755 "$tmp" "$dest"
  done
  shopt -u nullglob
else
  echo "No bin/ directory found in repository."
fi

# ------------------------------------------------------------
# Deploy templates/ -> ~/.config/solt/agent-loop/templates/
# ------------------------------------------------------------
TPL_SRC="$SRC_DIR/templates"
if [[ -d "$TPL_SRC" ]]; then
  echo "Deploying templates/ -> $TEMPLATE_DEST"
  ensure_dir "$TEMPLATE_DEST"
  shopt -s nullglob
  for f in "$TPL_SRC"/*.md; do
    base="$(basename "$f")"
    echo "  - $base"
    install -m 0644 "$f" "$TEMPLATE_DEST/$base"
  done
  shopt -u nullglob
else
  echo "No templates/ directory found in repository."
fi

# ------------------------------------------------------------
# Create agl config if it doesn't exist
# ------------------------------------------------------------
AGL_CONFIG="$HOME/.config/solt/agent-loop/agl.toml"
if [[ ! -f "$AGL_CONFIG" ]]; then
  echo "Creating default config at $AGL_CONFIG"
  ensure_dir "$(dirname "$AGL_CONFIG")"
  cat > "$AGL_CONFIG" <<'TOML'
# agl configuration

[worktree]
base = "~/dev/worktrees"
TOML
fi

echo "Done."
if ((KEEP_TEMP)); then
  echo "Temp dir kept at: $WORKDIR"
fi
