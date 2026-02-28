#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# agl-setup — Setup agent-loop from GitHub
#
# Clones the agent-loop repo, deploys bin/ scripts to ~/bin/
# and templates to ~/.config/solt/agent-loop/templates/.
# ------------------------------------------------------------

CONFIG_FILE="$HOME/.config/solt/agent-loop/agl.toml"
TEMPLATE_DEST="$HOME/.config/solt/agent-loop/templates"
TARGET_SHEBANG='#!/usr/bin/env bash'

# ------------------------------------------------------------
# Config reader (section-scanning TOML parser)
# ------------------------------------------------------------
read_config_toml_string() {
  local target_section="$1" target_key="$2"
  [[ -f "$CONFIG_FILE" ]] || return 0

  local in_section=false
  local line
  while IFS= read -r line; do
    # Skip blank lines and comments
    [[ -z "$line" || "$line" == "#"* ]] && continue

    # Section headers
    if [[ "$line" == "["*"]" ]]; then
      if [[ "$line" == "[$target_section]" ]]; then
        in_section=true
      else
        in_section=false
      fi
      continue
    fi

    if [[ "$in_section" == true ]]; then
      [[ "$line" == *=* ]] || continue
      local cfg_key="${line%%=*}"
      cfg_key="$(printf '%s' "$cfg_key" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
      [[ "$cfg_key" == "$target_key" ]] || continue

      local value_part="${line#*=}"
      value_part="$(printf '%s' "$value_part" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"

      # Must be exactly "..." (double-quoted, nothing else on line)
      if [[ "$value_part" =~ ^\"[^\"]*\"$ ]]; then
        # Strip quotes
        local cfg_value="${value_part:1:${#value_part}-2}"
        printf '%s' "$cfg_value"
      fi
      return 0
    fi
  done <"$CONFIG_FILE"
}

# ------------------------------------------------------------
# Load config with fallbacks
# ------------------------------------------------------------
GH_USER="$(read_config_toml_string github user)"
GH_REPO_NAME="$(read_config_toml_string github repo)"
PAT="$(read_config_toml_string github pat)"
REF="$(read_config_toml_string github ref)"

[[ -z "$REF" ]] && REF="main"

# Environment variable override
[[ -n "${GH_PAT:-}" ]] && PAT="$GH_PAT"

KEEP_TEMP=0
SKIP_CONFIG=0

usage() {
  cat <<EOF
Usage: $0 [--user USER] [--repo REPO] [--pat TOKEN] [--ref REF]
       [--no-config] [--keep-temp]

Config file: $CONFIG_FILE

Options:
  --user        GitHub username (overrides config)
  --repo        GitHub repo name (overrides config)
  --pat         Override PAT from config (or set in config file)
  --ref         Branch/tag to clone (default: main)
  --no-config   Skip creating config file if it doesn't exist
  --keep-temp   Keep temp dir for debugging
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
  --user)
    [[ $# -ge 2 && "$2" != -* ]] || {
      echo "Error: Missing value for --user" >&2
      exit 1
    }
    GH_USER="$2"
    shift 2
    ;;
  --repo)
    [[ $# -ge 2 && "$2" != -* ]] || {
      echo "Error: Missing value for --repo" >&2
      exit 1
    }
    GH_REPO_NAME="$2"
    shift 2
    ;;
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
  --no-config)
    SKIP_CONFIG=1
    shift
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
  echo "No PAT provided. Add one to $CONFIG_FILE for automatic use, or pass --pat TOKEN." >&2
  exit 1
fi

if [[ -z "${GH_USER:-}" || -z "${GH_REPO_NAME:-}" ]]; then
  echo "Error: github user and repo must be set in $CONFIG_FILE." >&2
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

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/agl-setup.XXXXXX")"
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
BIN_SRC="$SRC_DIR/src/bin"
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
TPL_SRC="$SRC_DIR/src/templates"
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
# Install config example (only if real file doesn't exist)
# ------------------------------------------------------------
if ((!SKIP_CONFIG)); then
  CONFIG_EXAMPLE="$SRC_DIR/src/config/agl.toml.example"
  if [[ -f "$CONFIG_EXAMPLE" && ! -f "$CONFIG_FILE" ]]; then
    ensure_dir "$(dirname "$CONFIG_FILE")"
    install -m 0644 "$CONFIG_EXAMPLE" "$CONFIG_FILE"
    echo "Created $CONFIG_FILE (from example)"
  fi
fi

echo "Done."
if ((KEEP_TEMP)); then
  echo "Temp dir kept at: $WORKDIR"
fi
