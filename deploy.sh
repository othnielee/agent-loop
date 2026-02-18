#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# deploy.sh — Bootstrap agent-loop from local checkout
#
# Run this once from the repo root to deploy scripts and
# templates to their runtime locations. After initial setup,
# use `agl-deploy` to pull updates from GitHub.
# ------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE_DEST="$HOME/.config/solt/agent-loop/templates"
TARGET_SHEBANG='#!/usr/bin/env bash'

ensure_dir() { mkdir -p "$1"; }

prepend_shebang_copy() {
  local src="$1" dest="$2" shebang="$3"
  awk -v sb="$shebang" '
    NR==1 {
      if ($0 ~ /^#!/) { print sb; next }
      else { print sb; print; next }
    }
    { print }
  ' "$src" > "$dest"
  chmod 0755 "$dest"
}

# ------------------------------------------------------------
# Deploy bin/ scripts -> ~/bin/
# ------------------------------------------------------------
BIN_SRC="$SCRIPT_DIR/bin"
if [[ -d "$BIN_SRC" ]]; then
  echo "Deploying bin/ -> \$HOME/bin"
  ensure_dir "$HOME/bin"
  shopt -s nullglob
  for f in "$BIN_SRC"/*.sh; do
    base="$(basename "$f")"
    name="${base%.sh}"
    dest="$HOME/bin/$name"
    tmp="/tmp/agl-deploy-$name.$$"

    echo "  - $base -> ~/bin/$name"
    prepend_shebang_copy "$f" "$tmp" "$TARGET_SHEBANG"
    install -m 0755 "$tmp" "$dest"
    rm -f "$tmp"
  done
  shopt -u nullglob
else
  echo "No bin/ directory found."
  exit 1
fi

# ------------------------------------------------------------
# Deploy templates/ -> ~/.config/solt/agent-loop/templates/
# ------------------------------------------------------------
TPL_SRC="$SCRIPT_DIR/templates"
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
  echo "No templates/ directory found."
  exit 1
fi

# ------------------------------------------------------------
# Create config file if it doesn't exist
# ------------------------------------------------------------
CONFIG_FILE="$HOME/.config/solt/agent-loop/deploy.toml"
if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Creating default config at $CONFIG_FILE"
  ensure_dir "$(dirname "$CONFIG_FILE")"
  cat > "$CONFIG_FILE" <<'TOML'
# agl-deploy configuration

[github]
user = "othnielee"
repo = "agent-loop"
pat = ""
ref = "main"
TOML
  echo "  - Set your PAT in $CONFIG_FILE for agl-deploy updates"
fi

echo "Done."
echo ""
echo "Commands available:"
echo "  agl          - Agent loop scaffolding"
echo "  agl-deploy   - Self-updater (set PAT in $CONFIG_FILE first)"
