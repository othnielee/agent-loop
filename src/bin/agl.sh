#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# agl — Agent Loop scaffolding tool
#
# Generates loop directories, fills template placeholders, and
# prints or executes agr commands.
# ------------------------------------------------------------

TEMPLATE_DIR="$HOME/.config/solt/agent-loop/templates"

# ------------------------------------------------------------
# Usage
# ------------------------------------------------------------
usage() {
  cat <<'EOF'
Usage: agl <command> [options]

Commands:
  init <feature-slug>   Create a new agent loop (worktree + branch)
  work [options] [<agent>]  Run agent with the most recent prompt
  commit                Stage and commit changes in the worktree
  enhance [<agent>]     Generate enhancer prompt (optionally run agent)
  review [<agent>]      Generate reviewer prompt (optionally run agent)
  fix [<agent>]         Generate fixer prompt (optionally run agent)
  merge [<slug>]        Squash-merge branch (optional draft message)
  drop [<slug>]         Remove worktree and branch (abandon work)

Init options:
  --plan <path>         Path to the plan file (required)
  --task <description>  Task description (default: Implement the feature according to the plan.)
  --context <paths>     Additional context paths (default: None)
  --worktree-base <path> Worktree base directory (overrides config/env)

Work options:
  --dir <path>          Loop directory (default: most recent)
  --plan <path>         Scaffold a new worker prompt with this plan
  --task <description>  Task description (default: Implement the plan.)
  --context <paths>     Additional context paths (default: None)
  [<agent> [flags...]]  Run agent after scaffolding (flags pass through to agr)
                        Agent is required when --plan is not used.

Commit options:
  --dir <path>          Loop directory (default: most recent)

Enhance options:
  --dir <path>          Loop directory (default: most recent)
  --context <paths>     Additional context paths (default: None)
  --commits <hashes>    Relevant commit hashes (default: None)
  --instructions <text> Additional instructions (default: None)
  [<agent> [flags...]]  Run agent after scaffolding (flags pass through to agr)

Review options:
  --dir <path>          Loop directory (default: most recent)
  --files <paths>       File paths to review (default: None)
  --context <paths>     Additional context paths (default: None)
  --commits <hashes>    Relevant commit hashes (default: None)
  --checklist <text>    Review checklist (default: None)
  [<agent> [flags...]]  Run agent after scaffolding (flags pass through to agr)

Fix options:
  --dir <path>          Loop directory (default: most recent)
  --context <paths>     Additional context paths (default: None)
  [<agent> [flags...]]  Run agent after scaffolding (flags pass through to agr)

Merge options:
  [<slug>]              Feature slug to merge (default: most recent loop)
  --agent <agent> [...] Agent name and flags for commit-message drafting
                        Place --dir/--no-delete before --agent.
                        Args after --agent <agent> pass through to agr.
  --dir <path>          Loop directory (default: most recent)
  --no-delete           Preserve worktree and branch after merge

Drop options:
  [<slug>]              Feature slug to drop (default: most recent loop)
  --dir <path>          Loop directory (default: most recent)
  --all                 Also remove the loop directory (prompts, output, context)

Examples:
  agl init add-auth --plan work/wip/task-1.md
  agl work --plan work/planning/subplan-01.md claude  # scaffold + run subplan
  agl work --plan work/planning/subplan-01.md         # scaffold only (print commands)
  agl work claude                          # run agent with most recent prompt
  agl commit
  agl enhance codex                        # scaffold + run
  agl commit
  agl review                               # scaffold only (interactive)
  agl fix claude --fast                    # scaffold + run with flags
  agl commit
  agl merge add-auth                       # manual message
  agl merge add-auth --agent claude --fast # draft + merge
  agl drop add-auth                        # remove worktree + branch
  agl drop add-auth --all                  # also remove loop directory
EOF
  exit "${1:-1}"
}

# ------------------------------------------------------------
# Helpers
# ------------------------------------------------------------
die() {
  echo "Error: $*" >&2
  exit 1
}

# Validate that a flag has a non-flag value argument following it.
# Must be called BEFORE expanding $2 — only uses $# to check.
require_arg() {
  local flag="$1" remaining="$2" next="${3-}"
  if [[ "$remaining" -lt 2 ]]; then
    die "Missing value for $flag"
  fi
  if [[ "$next" == -* ]]; then
    die "Missing value for $flag (got '$next')"
  fi
}

# Reject multiline values that would break sed substitution
reject_multiline() {
  local flag="$1" value="$2"
  if [[ "$value" == *$'\n'* ]]; then
    die "Multiline values are not supported for $flag"
  fi
}

project_root() {
  git rev-parse --show-toplevel 2>/dev/null || die "Not in a git repository"
}

slug_to_name() {
  local slug="$1"
  echo "$slug" | sed 's/-/ /g' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) tolower(substr($i,2))}1'
}

# Portable in-place sed (BSD sed -i requires '' arg, GNU does not)
sed_inplace() {
  local expr="$1" file="$2"
  local tmp="${file}.tmp.$$"
  sed "$expr" "$file" >"$tmp" && mv "$tmp" "$file"
}

# Escape a string for use as a sed replacement value.
# Handles &, \, and | (the sed delimiter).
sed_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//&/\\&}"
  s="${s//|/\\|}"
  printf '%s' "$s"
}

# Normalize an existing directory to a physical absolute path (resolves symlinks).
# Callers must check [[ -d "$path" ]] first.
abs_path() {
  cd "$1" && pwd -P
}

# Guard that CWD is in the primary (non-linked) worktree.
# Takes the command name as $1 for the error message.
require_primary_worktree() {
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "Not in a git repository"
  [[ "$(git rev-parse --git-dir)" == "$(git rev-parse --git-common-dir)" ]] ||
    die "$1 must run from the primary worktree, not a linked worktree."
}

# Hard-stop if a path is not ignored by git.
require_ignored() {
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "Not in a git repository"
  local root
  root="$(project_root)"
  git -C "$root" check-ignore -q -- "$1" ||
    die "$1 must be in .gitignore or .git/info/exclude before proceeding."
}

# Advisory warning for uncommitted changes. Non-blocking, cannot exit the script.
warn_uncommitted() {
  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    return 0
  fi

  local root
  root="$(project_root)"
  if [[ -n "$(git -C "$root" status --porcelain 2>/dev/null)" ]]; then
    echo "Warning: uncommitted changes detected. Run 'agl commit' first." >&2
  fi
}

# Write or update LAST_STAGE in .agl metadata.
update_last_stage() {
  local agl_file="$1" stage="$2"
  local existing
  existing="$(read_meta_optional "$agl_file" LAST_STAGE)"
  if [[ -n "$existing" ]]; then
    sed_inplace "s|^LAST_STAGE=.*|LAST_STAGE=$stage|" "$agl_file"
  else
    echo "LAST_STAGE=$stage" >>"$agl_file"
  fi
}

# Best-effort cleanup for partially initialized loops in cmd_init.
cleanup_init_artifacts() {
  local worktree_mode="$1" main_root="$2" loop_dir="$3" branch_name="$4" worktree_abs="$5"
  local external_wt_dir="${6:-}"

  if [[ -n "$worktree_abs" && -d "$worktree_abs" ]]; then
    git worktree remove --force "$worktree_abs" 2>/dev/null || true
  fi
  git worktree prune 2>/dev/null || true

  if [[ "$worktree_mode" == "external" ]]; then
    if [[ -n "$external_wt_dir" &&
      "$worktree_abs" == "$external_wt_dir/worktree" &&
      -d "$external_wt_dir" ]]; then
      rm -rf "$external_wt_dir"
    fi
  elif [[ -n "$worktree_abs" &&
    "$worktree_abs" == "$main_root/work/agent-loop/"* &&
    -d "$worktree_abs" ]]; then
    rm -rf "$worktree_abs"
  fi

  if [[ -n "$branch_name" ]]; then
    git branch -D "$branch_name" 2>/dev/null || true
  fi

  if [[ -n "$loop_dir" && -d "$loop_dir" ]]; then
    rm -rf "$loop_dir"
  fi
}

# Validate a WORKTREE value from .agl before use in git -C or git worktree remove.
# Supports both external (absolute, default) and internal (relative, fallback) modes.
# Reads WORKTREE_MODE and WORKTREE_BASE from agl_file only — never from CLI,
# environment, or config file.
require_safe_worktree_path() {
  local agl_file="$1" worktree_val="$2" loop_dir_rel="$3" main_root_abs="$4"

  local worktree_mode
  worktree_mode="$(read_meta_optional "$agl_file" WORKTREE_MODE)"

  if [[ "$worktree_val" == /* ]]; then
    # Absolute path: must be external mode
    if [[ "$worktree_mode" != "external" ]]; then
      die "Absolute WORKTREE requires WORKTREE_MODE=external and WORKTREE_BASE"
    fi

    local worktree_base_val
    worktree_base_val="$(read_meta_optional "$agl_file" WORKTREE_BASE)"
    [[ -n "$worktree_base_val" ]] ||
      die "Absolute WORKTREE requires WORKTREE_MODE=external and WORKTREE_BASE"

    # Must be under WORKTREE_BASE (trailing / prevents prefix collision)
    [[ "$worktree_val" == "$worktree_base_val/"* ]] ||
      die "WORKTREE is not under WORKTREE_BASE"

    # Must end with /worktree
    [[ "$worktree_val" == */worktree ]] ||
      die "WORKTREE must end with /worktree"

    # Exact equality to the derived canonical path
    local framework_name
    framework_name="$(derive_framework_name "$main_root_abs" "$worktree_base_val")"
    local expected
    expected="$worktree_base_val/$framework_name/$(basename "$main_root_abs")/$(basename "$loop_dir_rel")/worktree"
    [[ "$worktree_val" == "$expected" ]] ||
      die "WORKTREE '$worktree_val' does not match expected '$expected'"

    # Symlink-safe comparison when both directories exist
    if [[ -d "$worktree_val" && -d "$worktree_base_val" ]]; then
      local wt_norm base_norm
      wt_norm="$(abs_path "$worktree_val")"
      base_norm="$(abs_path "$worktree_base_val")"
      [[ "$wt_norm" == "$base_norm/"* ]] ||
        die "WORKTREE escapes WORKTREE_BASE (symlink detected)"
    fi
  else
    # Relative path
    if [[ "$worktree_mode" == "external" ]]; then
      die "WORKTREE_MODE=external requires absolute WORKTREE"
    fi

    # Defense-in-depth: must not contain ..
    if [[ "$worktree_val" == *..* ]]; then
      die "Unsafe WORKTREE path (contains ..): $worktree_val"
    fi

    # Defense-in-depth: must start with expected prefix
    if [[ "$worktree_val" != work/agent-loop/* ]]; then
      die "Unsafe WORKTREE path (wrong prefix): $worktree_val"
    fi

    # Exact equality: must match this loop dir's worktree path
    local expected="${loop_dir_rel}/worktree"
    if [[ "$worktree_val" != "$expected" ]]; then
      die "WORKTREE '$worktree_val' does not match expected '$expected'"
    fi
  fi
}

# Find the most recent loop directory whose worktree directory exists.
# Used by commands that need a live worktree (work, commit, enhance, review, fix).
find_loop_dir_with_worktree() {
  local root
  root="$(project_root)"
  local loop_base="$root/work/agent-loop"

  if [[ -d "$loop_base" ]]; then
    local latest
    latest="$(find "$loop_base" -mindepth 1 -maxdepth 1 -type d | sort -r | while read -r d; do
      if [[ -f "$d/.agl" ]] &&
        grep -q "^BRANCH=" "$d/.agl" 2>/dev/null &&
        grep -q "^WORKTREE=" "$d/.agl" 2>/dev/null &&
        grep -q "^MAIN_ROOT=" "$d/.agl" 2>/dev/null; then
        local wt_val
        wt_val="$(grep "^WORKTREE=" "$d/.agl" 2>/dev/null | head -1 | cut -d'=' -f2-)"
        if [[ "$wt_val" == /* ]]; then
          # Absolute: require external mode metadata
          grep -q "^WORKTREE_MODE=external$" "$d/.agl" 2>/dev/null || continue
          grep -q "^WORKTREE_BASE=" "$d/.agl" 2>/dev/null || continue
          [[ -d "$wt_val" ]] || continue
        else
          [[ -d "$root/$wt_val" ]] || continue
        fi
        echo "$d"
        break
      fi
    done)"

    if [[ -n "$latest" ]]; then
      echo "${latest%/}"
      return 0
    fi
  fi

  die "No loop directory with .agl metadata found"
}

# Find the most recent loop directory with valid .agl metadata, regardless of
# whether the worktree directory exists. Used by merge and drop which must be
# able to find loops whose worktree has already been removed.
find_loop_dir_any() {
  local root
  root="$(project_root)"
  local loop_base="$root/work/agent-loop"

  if [[ -d "$loop_base" ]]; then
    local latest
    latest="$(find "$loop_base" -mindepth 1 -maxdepth 1 -type d | sort -r | while read -r d; do
      if [[ -f "$d/.agl" ]] &&
        grep -q "^BRANCH=" "$d/.agl" 2>/dev/null &&
        grep -q "^WORKTREE=" "$d/.agl" 2>/dev/null &&
        grep -q "^MAIN_ROOT=" "$d/.agl" 2>/dev/null; then
        local wt_val
        wt_val="$(grep "^WORKTREE=" "$d/.agl" 2>/dev/null | head -1 | cut -d'=' -f2-)"
        # If absolute, require external mode fields
        if [[ "$wt_val" == /* ]]; then
          grep -q "^WORKTREE_MODE=external$" "$d/.agl" 2>/dev/null || continue
          grep -q "^WORKTREE_BASE=" "$d/.agl" 2>/dev/null || continue
        fi
        echo "$d"
        break
      fi
    done)"

    if [[ -n "$latest" ]]; then
      echo "${latest%/}"
      return 0
    fi
  fi

  die "No loop directory with .agl metadata found"
}

# Resolve --dir input to an absolute loop directory path.
# Defaults to the most recent loop when empty.
resolve_loop_dir() {
  local loop_dir_input="$1"
  local resolved_loop_dir

  if [[ -z "$loop_dir_input" ]]; then
    resolved_loop_dir="$(find_loop_dir_with_worktree)"
  else
    case "$loop_dir_input" in
    /*) resolved_loop_dir="$loop_dir_input" ;;
    *) resolved_loop_dir="$(pwd -P)/$loop_dir_input" ;;
    esac
    [[ -d "$resolved_loop_dir" ]] || die "Loop directory not found: $loop_dir_input"
  fi
  resolved_loop_dir="$(abs_path "$resolved_loop_dir")"

  local root
  root="$(project_root)"
  root="$(abs_path "$root")"
  [[ "$resolved_loop_dir" == "$root/work/agent-loop/"* ]] ||
    die "Loop directory must be under $root/work/agent-loop"

  printf '%s' "$resolved_loop_dir"
}

# Snapshot context files into context_dir, returning comma-separated absolute
# paths of the copies.  Handles basename deduplication (counter suffix).
# Returns "None" when input is "None".
snapshot_context_files() {
  local context_paths="$1"
  local caller_pwd="$2"
  local context_dir="$3"

  if [[ "$context_paths" == "None" ]]; then
    printf '%s' "None"
    return 0
  fi

  mkdir -p "$context_dir"

  local result=""
  local IFS=','
  local ctx_path
  for ctx_path in $context_paths; do
    ctx_path="$(printf '%s' "$ctx_path" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [[ -n "$ctx_path" ]] || continue

    local ctx_abs
    case "$ctx_path" in
    /*) ctx_abs="$ctx_path" ;;
    *) ctx_abs="$caller_pwd/$ctx_path" ;;
    esac

    [[ -f "$ctx_abs" && -r "$ctx_abs" ]] ||
      die "Context file not found or not readable: $ctx_path"

    local ctx_base ctx_dest
    ctx_base="$(basename "$ctx_abs")"
    ctx_dest="$ctx_base"
    if [[ -f "$context_dir/$ctx_dest" ]]; then
      local name ext counter
      if [[ "$ctx_base" == *.* ]]; then
        name="${ctx_base%.*}"
        ext=".${ctx_base##*.}"
      else
        name="$ctx_base"
        ext=""
      fi
      counter=2
      while [[ -f "$context_dir/${name}-${counter}${ext}" ]]; do
        counter=$((counter + 1))
      done
      ctx_dest="${name}-${counter}${ext}"
    fi
    cp "$ctx_abs" "$context_dir/$ctx_dest"
    if [[ -n "$result" ]]; then
      result="$result, $context_dir/$ctx_dest"
    else
      result="$context_dir/$ctx_dest"
    fi
  done

  if [[ -z "$result" ]]; then
    result="None"
  fi

  printf '%s' "$result"
}

# Return file mtime epoch seconds (portable across BSD/GNU stat).
file_mtime_epoch() {
  local file_path="$1"
  local mtime

  if mtime="$(stat -f '%m' "$file_path" 2>/dev/null)"; then
    printf '%s' "$mtime"
    return 0
  fi

  if mtime="$(stat -c '%Y' "$file_path" 2>/dev/null)"; then
    printf '%s' "$mtime"
    return 0
  fi

  die "Unable to read file mtime: $file_path"
}

# Build a deterministic key for prompt filename tie-breaks when mtimes match.
# Treat base prompts as pass 1 so 01-worker-r3.md outranks 01-worker.md.
prompt_tiebreak_key() {
  local prompt_file="$1"
  local base_name
  base_name="$(basename "$prompt_file")"
  local numeric_suffix

  if [[ "$base_name" =~ ^(.+)-r([0-9]+)\.md$ ]]; then
    numeric_suffix=$((10#${BASH_REMATCH[2]}))
    printf '%s-r%09d.md' "${BASH_REMATCH[1]}" "$numeric_suffix"
    return 0
  fi

  if [[ "$base_name" =~ ^(.+)-([0-9]+)\.md$ ]]; then
    numeric_suffix=$((10#${BASH_REMATCH[2]}))
    printf '%s-%09d.md' "${BASH_REMATCH[1]}" "$numeric_suffix"
    return 0
  fi

  if [[ "$base_name" =~ ^(.+)\.md$ ]]; then
    printf '%s-%09d.md' "${BASH_REMATCH[1]}" 1
    return 0
  fi

  printf '%s' "$base_name"
}

# Find the most recently modified prompt file in a prompt directory.
find_latest_prompt_file() {
  local prompts_dir="$1"
  local latest_prompt=""
  local latest_mtime="-1"
  local latest_key=""
  local prompt_file

  while IFS= read -r prompt_file; do
    local prompt_mtime
    prompt_mtime="$(file_mtime_epoch "$prompt_file")"
    local prompt_key
    prompt_key="$(prompt_tiebreak_key "$prompt_file")"

    if [[ -z "$latest_prompt" || "$prompt_mtime" -gt "$latest_mtime" ]]; then
      latest_prompt="$prompt_file"
      latest_mtime="$prompt_mtime"
      latest_key="$prompt_key"
      continue
    fi

    if [[ "$prompt_mtime" -eq "$latest_mtime" ]]; then
      if [[ "$prompt_key" > "$latest_key" || ("$prompt_key" == "$latest_key" && "$prompt_file" > "$latest_prompt") ]]; then
        latest_prompt="$prompt_file"
        latest_key="$prompt_key"
      fi
    fi
  done < <(find "$prompts_dir" -mindepth 1 -maxdepth 1 -type f -name '*.md' | sort)

  printf '%s' "$latest_prompt"
}

# Build a comma-separated list of markdown report paths in output/.
collect_output_reports() {
  local output_dir="$1"
  local report_paths=""
  local report_file

  while IFS= read -r report_file; do
    if [[ -n "$report_paths" ]]; then
      report_paths="$report_paths, $report_file"
    else
      report_paths="$report_file"
    fi
  done < <(find "$output_dir" -mindepth 1 -maxdepth 1 -type f -name '*.md' | sort)

  if [[ -z "$report_paths" ]]; then
    report_paths="None"
  fi

  printf '%s' "$report_paths"
}

# Read a required key from the .agl metadata file. Dies if missing.
read_meta() {
  local agl_file="$1" key="$2"
  local value
  value="$(grep "^${key}=" "$agl_file" 2>/dev/null | head -1 | cut -d'=' -f2- || true)"
  if [[ -z "$value" ]]; then
    die "Required key $key missing from $agl_file"
  fi
  printf '%s' "$value"
}

# Read an optional key from the .agl metadata file. Returns empty if missing.
read_meta_optional() {
  local agl_file="$1" key="$2"
  grep "^${key}=" "$agl_file" 2>/dev/null | head -1 | cut -d'=' -f2- || true
}

# Read worktree.base from ~/.config/solt/agent-loop/agl.toml.
# Prints the value (with quotes stripped) and returns 0, or prints nothing and
# returns 0 when the config file or key is absent.
read_config_worktree_base() {
  local config_file="$HOME/.config/solt/agent-loop/agl.toml"
  [[ -f "$config_file" ]] || return 0

  local in_worktree_section=false
  local line
  while IFS= read -r line; do
    # Skip blank lines and comments
    [[ -z "$line" || "$line" == "#"* ]] && continue

    # Section headers
    if [[ "$line" == "["*"]" ]]; then
      if [[ "$line" == "[worktree]" ]]; then
        in_worktree_section=true
      else
        in_worktree_section=false
      fi
      continue
    fi

    if [[ "$in_worktree_section" == true ]]; then
      # Only parse lines with an = sign
      [[ "$line" == *=* ]] || continue
      local cfg_key="${line%%=*}"
      cfg_key="$(printf '%s' "$cfg_key" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
      [[ "$cfg_key" == "base" ]] || continue

      local value_part="${line#*=}"
      value_part="$(printf '%s' "$value_part" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"

      # Must be exactly "..." (quoted, nothing else on line)
      if [[ ! "$value_part" =~ ^\"[^\"]*\"$ ]]; then
        die "Invalid worktree.base in $config_file: value must be quoted (\"...\")"
      fi

      # Strip quotes
      local cfg_value="${value_part:1:${#value_part}-2}"

      # Reject spaces/tabs in value
      if [[ "$cfg_value" == *" "* || "$cfg_value" == *$'\t'* ]]; then
        die "Invalid worktree.base in $config_file: value must not contain spaces or tabs"
      fi

      printf '%s' "$cfg_value"
      return 0
    fi
  done <"$config_file"
}

# Derive a framework name from the repo's parent directory.
# If the repo parent is an ancestor of (or equal to) the worktree base,
# the parent is a generic container (e.g. ~/dev) — return "etc".
# Otherwise return the parent directory name (e.g. "bash", "python").
derive_framework_name() {
  local main_root_norm="$1" worktree_base_abs="$2"
  local repo_parent_norm
  repo_parent_norm="$(dirname "$main_root_norm")"
  if [[ "$worktree_base_abs" == "$repo_parent_norm/"* || "$worktree_base_abs" == "$repo_parent_norm" ]]; then
    printf '%s' "etc"
  else
    printf '%s' "$(basename "$repo_parent_norm")"
  fi
}

# Resolve the WORKTREE value from .agl to an absolute path.
# Returns the absolute path directly when WORKTREE starts with /,
# otherwise joins MAIN_ROOT with the relative WORKTREE value.
# Does not call abs_path — the directory may not exist.
resolve_worktree_abs() {
  local agl_file="$1"
  local worktree_val
  worktree_val="$(read_meta "$agl_file" WORKTREE)"

  if [[ "$worktree_val" == /* ]]; then
    printf '%s' "$worktree_val"
    return 0
  fi

  local main_root_val
  main_root_val="$(read_meta "$agl_file" MAIN_ROOT)"
  printf '%s' "$main_root_val/$worktree_val"
}

# Verify the worktree belongs to the current repo by comparing git common-dir.
# Both paths must be absolute and the worktree directory must exist.
require_repo_membership() {
  local worktree_abs="$1" main_root_abs="$2"

  local repo_common repo_common_path repo_common_abs
  repo_common="$(git -C "$main_root_abs" rev-parse --git-common-dir)"
  case "$repo_common" in
  /*) repo_common_path="$repo_common" ;;
  *) repo_common_path="$main_root_abs/$repo_common" ;;
  esac
  [[ -d "$repo_common_path" ]] || die "Invalid repo common git dir: $repo_common_path"
  repo_common_abs="$(abs_path "$repo_common_path")"

  local wt_common wt_common_path wt_common_abs
  wt_common="$(git -C "$worktree_abs" rev-parse --git-common-dir)"
  case "$wt_common" in
  /*) wt_common_path="$wt_common" ;;
  *) wt_common_path="$worktree_abs/$wt_common" ;;
  esac
  [[ -d "$wt_common_path" ]] || die "Invalid worktree common git dir: $wt_common_path"
  wt_common_abs="$(abs_path "$wt_common_path")"

  [[ "$wt_common_abs" == "$repo_common_abs" ]] ||
    die "Worktree does not belong to current repo (git common-dir mismatch)"
}

# Print the prompt path and ready-to-run agr commands.
# When worktree_path is provided, prints (cd ...) wrapped commands with absolute
# prompt path. worktree_path is absolute (default) or relative (internal fallback).
print_commands() {
  local prompt_path="$1"
  local worktree_path="${2:-}"
  local root
  root="$(project_root)"
  root="$(abs_path "$root")"

  local prompt_abs
  case "$prompt_path" in
  /*) prompt_abs="$prompt_path" ;;
  *) prompt_abs="$(pwd -P)/$prompt_path" ;;
  esac

  local rel_path="$prompt_abs"
  if [[ "$prompt_abs" == "$root/"* ]]; then
    rel_path="${prompt_abs#"$root"/}"
  fi

  echo ""
  if [[ -n "$worktree_path" ]]; then
    local worktree_abs
    if [[ "$worktree_path" == /* ]]; then
      worktree_abs="$worktree_path"
    else
      worktree_abs="$root/$worktree_path"
    fi
    echo "Prompt: $rel_path"
    echo ""
    echo "Run:"
    echo "  (cd \"$worktree_abs\" && agr claude \"$prompt_abs\")"
    echo "  (cd \"$worktree_abs\" && agr codex  \"$prompt_abs\")"
    return 0
  fi

  echo "Prompt: $rel_path"
  echo ""
  echo "Run:"
  echo "  agr claude $rel_path"
  echo "  agr codex  $rel_path"
}

# Execute agr in the worktree. Reads WORKTREE from .agl, resolves paths,
# cds into the worktree, and execs agr. Does not return.
run_agent() {
  local loop_dir="$1" agl_file="$2" prompt_path="$3"
  shift 3
  # Remaining args: agent name and flags for agr

  local root
  root="$(project_root)"
  root="$(abs_path "$root")"
  local loop_dir_abs
  loop_dir_abs="$(abs_path "$loop_dir")"
  local loop_dir_rel="${loop_dir_abs#"$root"/}"

  local prompt_abs
  case "$prompt_path" in
  /*) prompt_abs="$prompt_path" ;;
  *) prompt_abs="$(pwd -P)/$prompt_path" ;;
  esac
  [[ -f "$prompt_abs" ]] || die "Prompt file not found: $prompt_abs"

  local worktree_val
  worktree_val="$(read_meta "$agl_file" WORKTREE)"
  require_safe_worktree_path "$agl_file" "$worktree_val" "$loop_dir_rel" "$root"

  local worktree_abs_raw
  worktree_abs_raw="$(resolve_worktree_abs "$agl_file")"
  [[ -d "$worktree_abs_raw" ]] || die "Worktree directory not found: $worktree_abs_raw"
  local worktree_abs
  worktree_abs="$(abs_path "$worktree_abs_raw")"

  # For internal fallback worktrees, verify under work/agent-loop/
  local worktree_mode
  worktree_mode="$(read_meta_optional "$agl_file" WORKTREE_MODE)"
  if [[ "$worktree_mode" != "external" ]]; then
    [[ "$worktree_abs" == "$root/work/agent-loop/"* ]] ||
      die "Unsafe WORKTREE path (escapes work/agent-loop/)"
  fi

  require_repo_membership "$worktree_abs" "$root"

  cd "$worktree_abs"
  exec agr "$@" "$prompt_abs"
}

# Execute agr in a specific directory and return to caller.
run_agent_once() {
  local run_dir="$1" prompt_path="$2"
  shift 2
  # Remaining args: agent name and flags for agr

  local prompt_abs
  case "$prompt_path" in
  /*) prompt_abs="$prompt_path" ;;
  *) prompt_abs="$(pwd -P)/$prompt_path" ;;
  esac
  [[ -f "$prompt_abs" ]] || die "Prompt file not found: $prompt_abs"

  local run_dir_abs
  run_dir_abs="$(abs_path "$run_dir")"

  (
    cd "$run_dir_abs"
    agr "$@" "$prompt_abs" >&2
  )
}

# Generate commit-message draft prompt, run agent, and return draft path.
create_commit_draft() {
  local loop_dir="$1" agl_file="$2"
  shift 2
  local agent_args=("$@")

  local root
  root="$(project_root)"
  root="$(abs_path "$root")"

  local slug feature_name date plan_path_rel
  slug="$(read_meta "$agl_file" FEATURE_SLUG)"
  feature_name="$(slug_to_name "$slug")"
  date="$(read_meta "$agl_file" DATE)"
  plan_path_rel="$(read_meta "$agl_file" PLAN_PATH)"
  local abs_plan_path="$root/$plan_path_rel"

  local output_dir="$loop_dir/output"
  local context_dir="$loop_dir/context"
  local prompts_dir="$loop_dir/prompts"
  mkdir -p "$output_dir" "$context_dir" "$prompts_dir"

  local handoff_paths
  handoff_paths="$(collect_output_reports "$output_dir")"

  local commit_hashes
  commit_hashes="$(read_meta_optional "$agl_file" COMMITS)"
  [[ -n "$commit_hashes" ]] || commit_hashes="None"

  local squash_diff_path="$context_dir/squash-diff.patch"
  git -C "$root" diff --staged >"$squash_diff_path"

  local commit_message_path="$output_dir/COMMIT_MESSAGE-${slug}.txt"
  : >"$commit_message_path"

  local template="$TEMPLATE_DIR/05-commit-writer.md"
  [[ -f "$template" ]] || die "Template not found: $template"

  local prompt="$prompts_dir/05-commit-writer.md"
  sed \
    -e "s|{{DATE}}|$(sed_escape "$date")|g" \
    -e "s|{{FEATURE_SLUG}}|$(sed_escape "$slug")|g" \
    -e "s|{{FEATURE_NAME}}|$(sed_escape "$feature_name")|g" \
    -e "s|{{PLAN_PATH}}|$(sed_escape "$abs_plan_path")|g" \
    -e "s|{{HANDOFF_PATHS}}|$(sed_escape "$handoff_paths")|g" \
    -e "s|{{COMMIT_HASHES}}|$(sed_escape "$commit_hashes")|g" \
    -e "s|{{SQUASH_DIFF_PATH}}|$(sed_escape "$squash_diff_path")|g" \
    -e "s|{{COMMIT_MESSAGE_PATH}}|$(sed_escape "$commit_message_path")|g" \
    "$template" >"$prompt"

  run_agent_once "$root" "$prompt" "${agent_args[@]}"

  [[ -s "$commit_message_path" ]] ||
    die "Commit message draft was not created: $commit_message_path"

  printf '%s' "$commit_message_path"
}

# ------------------------------------------------------------
# Subcommands
# ------------------------------------------------------------

cmd_init() {
  local slug="" plan_path="" task_desc="" other_context="None" worktree_base_input=""

  # Parse the slug (first non-flag arg)
  while [[ $# -gt 0 ]]; do
    case "$1" in
    --plan)
      require_arg "$1" "$#" "${2-}"
      plan_path="$2"
      shift 2
      ;;
    --task)
      require_arg "$1" "$#" "${2-}"
      reject_multiline "$1" "${2-}"
      task_desc="$2"
      shift 2
      ;;
    --context)
      require_arg "$1" "$#" "${2-}"
      reject_multiline "$1" "${2-}"
      other_context="$2"
      shift 2
      ;;
    --worktree-base)
      require_arg "$1" "$#" "${2-}"
      worktree_base_input="$2"
      shift 2
      ;;
    -*) die "Unknown option: $1" ;;
    *)
      if [[ -z "$slug" ]]; then
        slug="$1"
        shift
      else
        die "Unexpected argument: $1"
      fi
      ;;
    esac
  done

  [[ -z "$slug" ]] && die "Feature slug is required. Usage: agl init <feature-slug> --plan <path>"
  if [[ ! "$slug" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]; then
    die "Invalid feature slug '$slug'. Use lowercase alphanumeric with hyphens (e.g. add-auth-middleware)."
  fi
  [[ -z "$plan_path" ]] && die "--plan is required. Usage: agl init <feature-slug> --plan <path>"

  # --- Early validation (before any side effects) ---
  require_primary_worktree "agl init"

  local main_root
  main_root="$(project_root)"

  require_ignored "work/agent-loop"

  local caller_pwd
  caller_pwd="$(pwd -P)"

  local plan_abs
  case "$plan_path" in
  /*) plan_abs="$plan_path" ;;
  *) plan_abs="$caller_pwd/$plan_path" ;;
  esac

  [[ -f "$plan_abs" && -r "$plan_abs" ]] ||
    die "Plan file not found or not readable: $plan_path"

  # Validate --context files before any branch/worktree creation
  if [[ "$other_context" != "None" ]]; then
    local IFS=',' validate_ctx
    for validate_ctx in $other_context; do
      validate_ctx="$(printf '%s' "$validate_ctx" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
      local validate_abs
      case "$validate_ctx" in
      /*) validate_abs="$validate_ctx" ;;
      *) validate_abs="$caller_pwd/$validate_ctx" ;;
      esac
      [[ -f "$validate_abs" && -r "$validate_abs" ]] ||
        die "Context file not found or not readable: $validate_ctx"
    done
  fi

  local branch_name="agl/$slug"

  # Validate no conflicts
  if git rev-parse --verify "$branch_name" >/dev/null 2>&1; then
    die "Branch $branch_name already exists"
  fi

  # --- Create loop dir in the primary tree ---
  local date timestamp loop_dir prompts_dir output_dir context_dir
  date="$(date +%Y-%m-%d)"
  timestamp="$(date +%Y-%m-%d-%H%M%S)"
  loop_dir="$main_root/work/agent-loop/${timestamp}-${slug}"
  prompts_dir="$loop_dir/prompts"
  output_dir="$loop_dir/output"
  context_dir="$loop_dir/context"

  mkdir -p "$prompts_dir" "$output_dir" "$context_dir"

  # --- Resolve worktree base (CLI > env > config > unset) ---
  local project_name
  project_name="$(basename "$(abs_path "$main_root")")"

  local worktree_base=""
  if [[ -n "$worktree_base_input" ]]; then
    worktree_base="$worktree_base_input"
  elif [[ -n "${AGL_WORKTREE_BASE:-}" ]]; then
    worktree_base="$AGL_WORKTREE_BASE"
  else
    worktree_base="$(read_config_worktree_base)"
  fi

  # --- Resolve worktree paths and mode ---
  local worktree_agl_val="" worktree_abs_for_git="" external_wt_dir=""
  local worktree_mode_val="internal" worktree_base_abs=""

  if [[ -n "$worktree_base" ]]; then
    # External worktree mode (default — base seeded by setup.sh)

    # Expand ~/
    # shellcheck disable=SC2088  # intentional literal ~/
    if [[ "${worktree_base:0:2}" == '~/' ]]; then
      worktree_base="$HOME/${worktree_base:2}"
    fi

    # Must be absolute after expansion
    if [[ "$worktree_base" != /* ]]; then
      rm -rf "$loop_dir"
      die "worktree base must be absolute (after ~ expansion): $worktree_base"
    fi

    # Create base dir and normalize
    if ! mkdir -p "$worktree_base"; then
      rm -rf "$loop_dir"
      die "Failed to create worktree base directory: $worktree_base"
    fi
    worktree_base_abs="$(abs_path "$worktree_base")"

    # Reject if under MAIN_ROOT
    local main_root_norm
    main_root_norm="$(abs_path "$main_root")"
    if [[ "$worktree_base_abs" == "$main_root_norm" || "$worktree_base_abs" == "$main_root_norm/"* ]]; then
      rm -rf "$loop_dir"
      die "worktree base must be outside the repository"
    fi

    local framework_name
    framework_name="$(derive_framework_name "$main_root_norm" "$worktree_base_abs")"
    external_wt_dir="$worktree_base_abs/$framework_name/$project_name/${timestamp}-${slug}"
    worktree_abs_for_git="$external_wt_dir/worktree"
    worktree_agl_val="$worktree_abs_for_git"
    worktree_mode_val="external"
  else
    # Internal worktree fallback (no base configured)
    local worktree_rel="work/agent-loop/${timestamp}-${slug}/worktree"
    worktree_abs_for_git="$main_root/$worktree_rel"
    worktree_agl_val="$worktree_rel"
  fi

  if ! git branch "$branch_name" HEAD; then
    rm -rf "$loop_dir"
    die "Failed to create branch: $branch_name"
  fi

  if [[ "$worktree_mode_val" == "external" ]]; then
    if ! mkdir -p "$external_wt_dir"; then
      cleanup_init_artifacts "$worktree_mode_val" "$main_root" "$loop_dir" "$branch_name" "$worktree_abs_for_git" "$external_wt_dir"
      die "Failed to create external worktree directory: $external_wt_dir"
    fi

    if ! git worktree add "$worktree_abs_for_git" "$branch_name"; then
      cleanup_init_artifacts "$worktree_mode_val" "$main_root" "$loop_dir" "$branch_name" "$worktree_abs_for_git" "$external_wt_dir"
      die "Failed to create worktree at $worktree_abs_for_git"
    fi
  else
    if ! git worktree add "$worktree_abs_for_git" "$branch_name"; then
      cleanup_init_artifacts "$worktree_mode_val" "$main_root" "$loop_dir" "$branch_name" "$worktree_abs_for_git"
      die "Failed to create worktree at $worktree_agl_val"
    fi
  fi

  # Absolute paths for placeholders (D4: agent CWD is in the worktree)
  local abs_output_dir="$output_dir"
  local abs_context_dir="$context_dir"

  local plan_base
  plan_base="$(basename "$plan_abs")"
  local plan_dest
  if [[ "$plan_base" == *.* ]]; then
    plan_dest="plan.${plan_base##*.}"
  else
    plan_dest="plan"
  fi
  if ! cp "$plan_abs" "$context_dir/$plan_dest"; then
    cleanup_init_artifacts "$worktree_mode_val" "$main_root" "$loop_dir" "$branch_name" "$worktree_abs_for_git" "$external_wt_dir"
    die "Failed to snapshot plan file into loop context"
  fi
  local abs_plan_path="$abs_context_dir/$plan_dest"

  # Snapshot --context files into context/ (resolved from invocation directory)
  local abs_context_paths
  if ! abs_context_paths="$(snapshot_context_files "$other_context" "$caller_pwd" "$context_dir")"; then
    cleanup_init_artifacts "$worktree_mode_val" "$main_root" "$loop_dir" "$branch_name" "$worktree_abs_for_git" "$external_wt_dir"
    die "Failed to snapshot context files into loop context"
  fi

  # Write .agl metadata (PLAN_PATH stored as relative for portability in metadata)
  local loop_dir_rel="${loop_dir#"$main_root"/}"
  local rel_plan_path="${abs_plan_path#"$main_root"/}"
  if ! cat >"$loop_dir/.agl" <<EOF; then
FEATURE_SLUG=$slug
PLAN_PATH=$rel_plan_path
DATE=$date
ROUND=1
BRANCH=$branch_name
WORKTREE=$worktree_agl_val
MAIN_ROOT=$main_root
LAST_STAGE=worker
EOF
    cleanup_init_artifacts "$worktree_mode_val" "$main_root" "$loop_dir" "$branch_name" "$worktree_abs_for_git" "$external_wt_dir"
    die "Failed to write loop metadata: $loop_dir/.agl"
  fi

  # Append worktree mode metadata (present for external, absent for internal fallback)
  if [[ "$worktree_mode_val" == "external" ]]; then
    if ! cat >>"$loop_dir/.agl" <<EOF; then
WORKTREE_MODE=external
WORKTREE_BASE=$worktree_base_abs
EOF
      cleanup_init_artifacts "$worktree_mode_val" "$main_root" "$loop_dir" "$branch_name" "$worktree_abs_for_git" "$external_wt_dir"
      die "Failed to write external worktree metadata: $loop_dir/.agl"
    fi
  fi

  local feature_name
  feature_name="$(slug_to_name "$slug")"

  # Default task description
  if [[ -z "$task_desc" ]]; then
    task_desc="Implement the feature according to the plan."
  fi

  local template="$TEMPLATE_DIR/01-worker.md"
  [[ -f "$template" ]] || die "Template not found: $template"

  local prompt="$prompts_dir/01-worker.md"

  sed \
    -e "s|{{DATE}}|$(sed_escape "$date")|g" \
    -e "s|{{FEATURE_SLUG}}|$(sed_escape "$slug")|g" \
    -e "s|{{FEATURE_NAME}}|$(sed_escape "$feature_name")|g" \
    -e "s|{{PLAN_PATH}}|$(sed_escape "$abs_plan_path")|g" \
    -e "s|{{HANDOFF_PATHS}}|None|g" \
    -e "s|{{OTHER_CONTEXT}}|$(sed_escape "$abs_context_paths")|g" \
    -e "s|{{TASK_DESCRIPTION}}|$(sed_escape "$task_desc")|g" \
    -e "s|{{OUTPUT_DIR}}|$(sed_escape "$abs_output_dir")|g" \
    "$template" >"$prompt"

  echo "Created loop: $loop_dir_rel"
  print_commands "$prompt" "$worktree_agl_val"
}

cmd_enhance() {
  require_primary_worktree "agl enhance"

  local loop_dir="" other_context="None" commit_hashes="None" instructions="None"
  local caller_pwd
  caller_pwd="$(pwd -P)"
  local agent_args=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
    --dir)
      require_arg "$1" "$#" "${2-}"
      loop_dir="$2"
      shift 2
      ;;
    --context)
      require_arg "$1" "$#" "${2-}"
      reject_multiline "$1" "${2-}"
      other_context="$2"
      shift 2
      ;;
    --commits)
      require_arg "$1" "$#" "${2-}"
      reject_multiline "$1" "${2-}"
      commit_hashes="$2"
      shift 2
      ;;
    --instructions)
      require_arg "$1" "$#" "${2-}"
      reject_multiline "$1" "${2-}"
      instructions="$2"
      shift 2
      ;;
    --)
      shift
      agent_args+=("$@")
      break
      ;;
    -*) die "Unknown option: $1" ;;
    *)
      agent_args+=("$@")
      break
      ;;
    esac
  done

  loop_dir="$(resolve_loop_dir "$loop_dir")"

  local root
  root="$(project_root)"
  local agl_file="$loop_dir/.agl"
  [[ -f "$agl_file" ]] || die "No .agl metadata found in $loop_dir"

  warn_uncommitted

  local slug plan_path_rel date
  slug="$(read_meta "$agl_file" FEATURE_SLUG)"
  plan_path_rel="$(read_meta "$agl_file" PLAN_PATH)"
  date="$(read_meta "$agl_file" DATE)"

  # Use tracked commits if --commits not provided
  if [[ "$commit_hashes" == "None" ]]; then
    local tracked
    tracked="$(read_meta_optional "$agl_file" COMMITS)"
    [[ -n "$tracked" ]] && commit_hashes="$tracked"
  fi

  local abs_output_dir="$loop_dir/output"
  local abs_plan_path="$root/$plan_path_rel"
  local handoff_path="None"
  if [[ -f "$abs_output_dir/HANDOFF-${slug}.md" ]]; then
    handoff_path="$abs_output_dir/HANDOFF-${slug}.md"
  fi
  local feature_name
  feature_name="$(slug_to_name "$slug")"
  local context_dir="$loop_dir/context"
  local abs_other_context
  abs_other_context="$(snapshot_context_files "$other_context" "$caller_pwd" "$context_dir")"

  local worktree_rel
  worktree_rel="$(read_meta_optional "$agl_file" WORKTREE)"

  local template="$TEMPLATE_DIR/02-enhancer.md"
  [[ -f "$template" ]] || die "Template not found: $template"

  local prompt="$loop_dir/prompts/02-enhancer.md"
  mkdir -p "$loop_dir/prompts"

  sed \
    -e "s|{{DATE}}|$(sed_escape "$date")|g" \
    -e "s|{{FEATURE_SLUG}}|$(sed_escape "$slug")|g" \
    -e "s|{{FEATURE_NAME}}|$(sed_escape "$feature_name")|g" \
    -e "s|{{PLAN_PATH}}|$(sed_escape "$abs_plan_path")|g" \
    -e "s|{{HANDOFF_PATH}}|$(sed_escape "$handoff_path")|g" \
    -e "s|{{OTHER_CONTEXT}}|$(sed_escape "$abs_other_context")|g" \
    -e "s|{{COMMIT_HASHES}}|$(sed_escape "$commit_hashes")|g" \
    -e "s|{{ADDITIONAL_INSTRUCTIONS}}|$(sed_escape "$instructions")|g" \
    -e "s|{{OUTPUT_DIR}}|$(sed_escape "$abs_output_dir")|g" \
    "$template" >"$prompt"

  if [[ "$instructions" == "None" ]]; then
    sed_inplace '/^None$/{N;d}' "$prompt"
  fi

  update_last_stage "$agl_file" "enhancer"

  if [[ ${#agent_args[@]} -gt 0 ]]; then
    run_agent "$loop_dir" "$agl_file" "$prompt" "${agent_args[@]}"
  else
    print_commands "$prompt" "$worktree_rel"
  fi
}

cmd_review() {
  require_primary_worktree "agl review"

  local loop_dir="" file_paths="None" other_context="None" commit_hashes="None" checklist="None"
  local caller_pwd
  caller_pwd="$(pwd -P)"
  local agent_args=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
    --dir)
      require_arg "$1" "$#" "${2-}"
      loop_dir="$2"
      shift 2
      ;;
    --files)
      require_arg "$1" "$#" "${2-}"
      reject_multiline "$1" "${2-}"
      file_paths="$2"
      shift 2
      ;;
    --context)
      require_arg "$1" "$#" "${2-}"
      reject_multiline "$1" "${2-}"
      other_context="$2"
      shift 2
      ;;
    --commits)
      require_arg "$1" "$#" "${2-}"
      reject_multiline "$1" "${2-}"
      commit_hashes="$2"
      shift 2
      ;;
    --checklist)
      require_arg "$1" "$#" "${2-}"
      reject_multiline "$1" "${2-}"
      checklist="$2"
      shift 2
      ;;
    --)
      shift
      agent_args+=("$@")
      break
      ;;
    -*) die "Unknown option: $1" ;;
    *)
      agent_args+=("$@")
      break
      ;;
    esac
  done

  loop_dir="$(resolve_loop_dir "$loop_dir")"

  local root
  root="$(project_root)"
  local agl_file="$loop_dir/.agl"
  [[ -f "$agl_file" ]] || die "No .agl metadata found in $loop_dir"

  warn_uncommitted

  local slug plan_path_rel date round
  slug="$(read_meta "$agl_file" FEATURE_SLUG)"
  plan_path_rel="$(read_meta "$agl_file" PLAN_PATH)"
  date="$(read_meta "$agl_file" DATE)"
  round="$(read_meta "$agl_file" ROUND)"

  # Use tracked commits if --commits not provided
  if [[ "$commit_hashes" == "None" ]]; then
    local tracked
    tracked="$(read_meta_optional "$agl_file" COMMITS)"
    [[ -n "$tracked" ]] && commit_hashes="$tracked"
  fi

  local abs_output_dir="$loop_dir/output"
  local abs_plan_path="$root/$plan_path_rel"
  local feature_name
  feature_name="$(slug_to_name "$slug")"
  local context_dir="$loop_dir/context"
  local abs_other_context
  abs_other_context="$(snapshot_context_files "$other_context" "$caller_pwd" "$context_dir")"

  local worktree_rel
  worktree_rel="$(read_meta_optional "$agl_file" WORKTREE)"

  # Compute handoff paths scoped to what's relevant for this round
  local handoff_paths=""
  if [[ "$round" -gt 1 ]]; then
    # Re-review: only the latest fix report matters
    local prev_round=$((round - 1))
    local fix_file
    if [[ "$prev_round" -gt 1 ]]; then
      fix_file="FIX-r${prev_round}-${slug}.md"
    else
      fix_file="FIX-${slug}.md"
    fi
    if [[ ! -f "$abs_output_dir/$fix_file" ]]; then
      die "Fix report $fix_file not found in $abs_output_dir. Run the fixer for round $prev_round first."
    fi
    handoff_paths="$abs_output_dir/$fix_file"
  else
    # Round 1: worker and enhancer handoffs
    if [[ -f "$abs_output_dir/HANDOFF-${slug}.md" ]]; then
      handoff_paths="$abs_output_dir/HANDOFF-${slug}.md"
    fi
    if [[ -f "$abs_output_dir/ENHANCE-${slug}.md" ]]; then
      if [[ -n "$handoff_paths" ]]; then
        handoff_paths="$handoff_paths, $abs_output_dir/ENHANCE-${slug}.md"
      else
        handoff_paths="$abs_output_dir/ENHANCE-${slug}.md"
      fi
    fi
  fi
  [[ -z "$handoff_paths" ]] && handoff_paths="None"

  # Collect previous review reports for re-reviews
  if [[ "$round" -gt 1 ]]; then
    local prev_reviews=""
    local ri review_file
    for ((ri = 1; ri < round; ri++)); do
      if [[ "$ri" -eq 1 ]]; then
        review_file="$abs_output_dir/REVIEW-${slug}.md"
      else
        review_file="$abs_output_dir/REVIEW-r${ri}-${slug}.md"
      fi
      if [[ -f "$review_file" ]]; then
        if [[ -n "$prev_reviews" ]]; then
          prev_reviews="$prev_reviews, $review_file"
        else
          prev_reviews="$review_file"
        fi
      fi
    done
    if [[ -n "$prev_reviews" ]]; then
      if [[ "$abs_other_context" == "None" ]]; then
        abs_other_context="$prev_reviews"
      else
        abs_other_context="$abs_other_context, $prev_reviews"
      fi
    fi
  fi

  local template="$TEMPLATE_DIR/03-reviewer.md"
  [[ -f "$template" ]] || die "Template not found: $template"

  # Round numbering for prompts and output
  local prompt_name="03-reviewer.md"
  local review_output="REVIEW-${slug}.md"
  if [[ "$round" -gt 1 ]]; then
    prompt_name="03-reviewer-r${round}.md"
    review_output="REVIEW-r${round}-${slug}.md"
  fi

  local prompt="$loop_dir/prompts/$prompt_name"
  mkdir -p "$loop_dir/prompts"

  local review_output_path="$abs_output_dir/$review_output"

  sed \
    -e "s|{{DATE}}|$(sed_escape "$date")|g" \
    -e "s|{{FEATURE_SLUG}}|$(sed_escape "$slug")|g" \
    -e "s|{{FEATURE_NAME}}|$(sed_escape "$feature_name")|g" \
    -e "s|{{PLAN_PATH}}|$(sed_escape "$abs_plan_path")|g" \
    -e "s|{{HANDOFF_PATHS}}|$(sed_escape "$handoff_paths")|g" \
    -e "s|{{FILE_PATHS}}|$(sed_escape "$file_paths")|g" \
    -e "s|{{OTHER_CONTEXT}}|$(sed_escape "$abs_other_context")|g" \
    -e "s|{{COMMIT_HASHES}}|$(sed_escape "$commit_hashes")|g" \
    -e "s|{{REVIEW_CHECKLIST}}|$(sed_escape "$checklist")|g" \
    -e "s|{{OUTPUT_DIR}}|$(sed_escape "$abs_output_dir")|g" \
    -e "s|{{REVIEW_OUTPUT_PATH}}|$(sed_escape "$review_output_path")|g" \
    "$template" >"$prompt"

  if [[ "$checklist" == "None" ]]; then
    awk '/^### Review Checklist$/{skip=1;next} skip && /^### /{skip=0} skip{next} {print}' \
      "$prompt" > "${prompt}.tmp" && mv "${prompt}.tmp" "$prompt"
  fi

  update_last_stage "$agl_file" "reviewer"

  if [[ ${#agent_args[@]} -gt 0 ]]; then
    run_agent "$loop_dir" "$agl_file" "$prompt" "${agent_args[@]}"
  else
    print_commands "$prompt" "$worktree_rel"
  fi
}

cmd_fix() {
  require_primary_worktree "agl fix"

  local loop_dir="" other_context="None"
  local caller_pwd
  caller_pwd="$(pwd -P)"
  local agent_args=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
    --dir)
      require_arg "$1" "$#" "${2-}"
      loop_dir="$2"
      shift 2
      ;;
    --context)
      require_arg "$1" "$#" "${2-}"
      reject_multiline "$1" "${2-}"
      other_context="$2"
      shift 2
      ;;
    --)
      shift
      agent_args+=("$@")
      break
      ;;
    -*) die "Unknown option: $1" ;;
    *)
      agent_args+=("$@")
      break
      ;;
    esac
  done

  loop_dir="$(resolve_loop_dir "$loop_dir")"

  local root
  root="$(project_root)"
  local agl_file="$loop_dir/.agl"
  [[ -f "$agl_file" ]] || die "No .agl metadata found in $loop_dir"

  warn_uncommitted

  local slug plan_path_rel date round
  slug="$(read_meta "$agl_file" FEATURE_SLUG)"
  plan_path_rel="$(read_meta "$agl_file" PLAN_PATH)"
  date="$(read_meta "$agl_file" DATE)"
  round="$(read_meta "$agl_file" ROUND)"

  local abs_output_dir="$loop_dir/output"
  local abs_plan_path="$root/$plan_path_rel"
  local feature_name
  feature_name="$(slug_to_name "$slug")"
  local context_dir="$loop_dir/context"
  local abs_other_context
  abs_other_context="$(snapshot_context_files "$other_context" "$caller_pwd" "$context_dir")"

  local worktree_rel
  worktree_rel="$(read_meta_optional "$agl_file" WORKTREE)"

  # Find the review file for the current round
  local review_path=""

  if [[ "$round" -gt 1 ]]; then
    # Round 2+: look for the round-specific review file
    local review_file="REVIEW-r${round}-${slug}.md"
    if [[ -f "$abs_output_dir/$review_file" ]]; then
      review_path="$abs_output_dir/$review_file"
    fi
  else
    # Round 1: look for the base review file
    if [[ -f "$abs_output_dir/REVIEW-${slug}.md" ]]; then
      review_path="$abs_output_dir/REVIEW-${slug}.md"
    fi
  fi

  [[ -z "$review_path" ]] && die "No review findings found in $abs_output_dir. Run the reviewer first."

  local template="$TEMPLATE_DIR/04-fixer.md"
  [[ -f "$template" ]] || die "Template not found: $template"

  # Round numbering for prompts and output
  local prompt_name="04-fixer.md"
  local fix_output="FIX-${slug}.md"
  if [[ "$round" -gt 1 ]]; then
    prompt_name="04-fixer-r${round}.md"
    fix_output="FIX-r${round}-${slug}.md"
  fi

  local prompt="$loop_dir/prompts/$prompt_name"
  mkdir -p "$loop_dir/prompts"

  sed \
    -e "s|{{DATE}}|$(sed_escape "$date")|g" \
    -e "s|{{FEATURE_SLUG}}|$(sed_escape "$slug")|g" \
    -e "s|{{FEATURE_NAME}}|$(sed_escape "$feature_name")|g" \
    -e "s|{{PLAN_PATH}}|$(sed_escape "$abs_plan_path")|g" \
    -e "s|{{REVIEW_PATH}}|$(sed_escape "$review_path")|g" \
    -e "s|{{OTHER_CONTEXT}}|$(sed_escape "$abs_other_context")|g" \
    -e "s|{{OUTPUT_DIR}}|$(sed_escape "$abs_output_dir")|g" \
    "$template" >"$prompt"

  # If round > 1, fix the output filename in the generated prompt
  if [[ "$round" -gt 1 ]]; then
    sed_inplace "/produce a fix report at/ s|FIX-$(sed_escape "${slug}")\\.md|$(sed_escape "$fix_output")|g" "$prompt"
  fi

  # Increment round for next review-fix cycle
  local new_round=$((round + 1))
  sed_inplace "s|^ROUND=.*|ROUND=$new_round|" "$agl_file"

  update_last_stage "$agl_file" "fixer"

  if [[ ${#agent_args[@]} -gt 0 ]]; then
    run_agent "$loop_dir" "$agl_file" "$prompt" "${agent_args[@]}"
  else
    print_commands "$prompt" "$worktree_rel"
  fi
}

cmd_work() {
  require_primary_worktree "agl work"

  local loop_dir="" plan_path="" task_desc="" other_context="None"
  local plan_flag_provided=false task_flag_provided=false context_flag_provided=false
  local caller_pwd
  caller_pwd="$(pwd -P)"
  local agent_args=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
    --dir)
      require_arg "$1" "$#" "${2-}"
      loop_dir="$2"
      shift 2
      ;;
    --plan)
      require_arg "$1" "$#" "${2-}"
      plan_flag_provided=true
      plan_path="$2"
      shift 2
      ;;
    --task)
      require_arg "$1" "$#" "${2-}"
      reject_multiline "$1" "${2-}"
      task_flag_provided=true
      task_desc="$2"
      shift 2
      ;;
    --context)
      require_arg "$1" "$#" "${2-}"
      reject_multiline "$1" "${2-}"
      context_flag_provided=true
      other_context="$2"
      shift 2
      ;;
    --)
      shift
      agent_args+=("$@")
      break
      ;;
    -*) die "Unknown option: $1" ;;
    *)
      agent_args+=("$@")
      break
      ;;
    esac
  done

  # --task and --context require --plan
  if [[ "$plan_flag_provided" == false ]]; then
    if [[ "$task_flag_provided" == true ]]; then
      die "--task requires --plan"
    fi
    if [[ "$context_flag_provided" == true ]]; then
      die "--context requires --plan"
    fi
  fi

  # Validate agent name when provided: first token must not start with -
  if [[ ${#agent_args[@]} -gt 0 && "${agent_args[0]}" == -* ]]; then
    die "Agent name is required before flags"
  fi

  loop_dir="$(resolve_loop_dir "$loop_dir")"

  local agl_file="$loop_dir/.agl"
  [[ -f "$agl_file" ]] || die "No .agl metadata found in $loop_dir"

  if [[ "$plan_flag_provided" == true ]]; then
    # --- Scaffolding branch (--plan provided) ---

    # Resolve and validate the plan file
    local plan_abs
    case "$plan_path" in
    /*) plan_abs="$plan_path" ;;
    *) plan_abs="$caller_pwd/$plan_path" ;;
    esac
    [[ -f "$plan_abs" && -r "$plan_abs" ]] ||
      die "Plan file not found or not readable: $plan_path"

    # Read .agl metadata
    local slug date omnibus_plan_rel
    slug="$(read_meta "$agl_file" FEATURE_SLUG)"
    date="$(read_meta "$agl_file" DATE)"
    omnibus_plan_rel="$(read_meta "$agl_file" PLAN_PATH)"
    local worktree_rel
    worktree_rel="$(read_meta "$agl_file" WORKTREE)"

    local root
    root="$(project_root)"
    root="$(abs_path "$root")"

    local feature_name
    feature_name="$(slug_to_name "$slug")"

    local prompts_dir="$loop_dir/prompts"
    local output_dir="$loop_dir/output"
    local context_dir="$loop_dir/context"
    mkdir -p "$prompts_dir" "$output_dir" "$context_dir"

    # Compute prompt filename: scan for existing 01-worker-r*.md files
    # The unsuffixed 01-worker.md (from init) is index 0; worker passes start at r1.
    local max_index=0
    local prompt_file
    while IFS= read -r prompt_file; do
      local basename_file
      basename_file="$(basename "$prompt_file")"
      if [[ "$basename_file" =~ ^01-worker-r([0-9]+)\.md$ ]]; then
        local idx_raw idx_num
        idx_raw="${BASH_REMATCH[1]}"
        idx_num=$((10#$idx_raw))
        if [[ "$idx_num" -gt "$max_index" ]]; then
          max_index="$idx_num"
        fi
      fi
    done < <(find "$prompts_dir" -mindepth 1 -maxdepth 1 -type f -name '01-worker-r*.md' 2>/dev/null)

    local next_index=$((max_index + 1))
    local prompt_name="01-worker-r${next_index}.md"

    # Snapshot the plan file into context/
    local abs_plan_path
    abs_plan_path="$(snapshot_context_files "$plan_abs" "$caller_pwd" "$context_dir")"

    # Snapshot --context files if provided
    local abs_context_paths
    abs_context_paths="$(snapshot_context_files "$other_context" "$caller_pwd" "$context_dir")"

    # Build {{OTHER_CONTEXT}}: always include the omnibus plan path
    local omnibus_abs="$root/$omnibus_plan_rel"
    local other_context_val="$omnibus_abs"
    if [[ "$abs_context_paths" != "None" ]]; then
      other_context_val="$other_context_val, $abs_context_paths"
    fi

    # Check if handoff exists
    local template handoff_paths
    if [[ -f "$output_dir/HANDOFF-${slug}.md" ]]; then
      template="$TEMPLATE_DIR/01-worker-next.md"
      handoff_paths="$output_dir/HANDOFF-${slug}.md"
    else
      template="$TEMPLATE_DIR/01-worker.md"
      handoff_paths="None"
    fi
    [[ -f "$template" ]] || die "Template not found: $template"

    # Default task description
    if [[ -z "$task_desc" ]]; then
      task_desc="Implement the plan."
    fi

    # Scaffold prompt via sed substitution
    local prompt="$prompts_dir/$prompt_name"
    sed \
      -e "s|{{DATE}}|$(sed_escape "$date")|g" \
      -e "s|{{FEATURE_SLUG}}|$(sed_escape "$slug")|g" \
      -e "s|{{FEATURE_NAME}}|$(sed_escape "$feature_name")|g" \
      -e "s|{{PLAN_PATH}}|$(sed_escape "$abs_plan_path")|g" \
      -e "s|{{HANDOFF_PATHS}}|$(sed_escape "$handoff_paths")|g" \
      -e "s|{{OTHER_CONTEXT}}|$(sed_escape "$other_context_val")|g" \
      -e "s|{{TASK_DESCRIPTION}}|$(sed_escape "$task_desc")|g" \
      -e "s|{{OUTPUT_DIR}}|$(sed_escape "$output_dir")|g" \
      "$template" >"$prompt"

    # Store worker pass index in .agl
    local existing_pass
    existing_pass="$(read_meta_optional "$agl_file" WORKER_PASS)"
    if [[ -n "$existing_pass" ]]; then
      sed_inplace "s|^WORKER_PASS=.*|WORKER_PASS=$next_index|" "$agl_file"
    else
      echo "WORKER_PASS=$next_index" >>"$agl_file"
    fi

    update_last_stage "$agl_file" "worker"

    if [[ ${#agent_args[@]} -gt 0 ]]; then
      run_agent "$loop_dir" "$agl_file" "$prompt" "${agent_args[@]}"
    else
      print_commands "$prompt" "$worktree_rel"
    fi
  else
    # --- No-plan branch: unchanged current behavior ---
    [[ ${#agent_args[@]} -gt 0 ]] || die "Agent name is required. Usage: agl work <agent> [flags...]"

    # Find the most recent prompt file
    local prompts_dir="$loop_dir/prompts"
    [[ -d "$prompts_dir" ]] || die "No prompts directory found in $loop_dir"

    local latest_prompt
    latest_prompt="$(find_latest_prompt_file "$prompts_dir")"
    [[ -n "$latest_prompt" ]] || die "No prompt found in $prompts_dir"

    run_agent "$loop_dir" "$agl_file" "$latest_prompt" "${agent_args[@]}"
  fi
}

cmd_commit() {
  require_primary_worktree "agl commit"

  local loop_dir=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
    --dir)
      require_arg "$1" "$#" "${2-}"
      loop_dir="$2"
      shift 2
      ;;
    *) die "Unknown option: $1" ;;
    esac
  done

  loop_dir="$(resolve_loop_dir "$loop_dir")"

  local agl_file="$loop_dir/.agl"
  [[ -f "$agl_file" ]] || die "No .agl metadata found in $loop_dir"

  # Read required .agl keys
  local slug last_stage round branch worktree_val agl_main_root
  slug="$(read_meta_optional "$agl_file" FEATURE_SLUG)"
  last_stage="$(read_meta_optional "$agl_file" LAST_STAGE)"
  round="$(read_meta_optional "$agl_file" ROUND)"
  branch="$(read_meta_optional "$agl_file" BRANCH)"
  worktree_val="$(read_meta_optional "$agl_file" WORKTREE)"
  agl_main_root="$(read_meta_optional "$agl_file" MAIN_ROOT)"

  if [[ -z "$slug" || -z "$last_stage" || -z "$round" || -z "$branch" || -z "$worktree_val" || -z "$agl_main_root" ]]; then
    die "Not a worktree-mode loop (required keys missing)"
  fi

  if [[ ! "$round" =~ ^[0-9]+$ ]]; then
    die "Invalid ROUND in .agl: $round"
  fi

  local expected_branch="agl/$slug"
  if [[ "$branch" != "$expected_branch" ]]; then
    die "Unexpected BRANCH in .agl: $branch (expected $expected_branch)"
  fi

  # Establish current repo root
  local repo_root
  repo_root="$(project_root)"
  [[ -d "$repo_root" ]] || die "Invalid repo root: $repo_root"
  local repo_root_abs
  repo_root_abs="$(abs_path "$repo_root")"

  # Validate .agl MAIN_ROOT matches current repo
  [[ -d "$agl_main_root" ]] || die "Invalid .agl MAIN_ROOT: $agl_main_root"
  local agl_main_root_abs
  agl_main_root_abs="$(abs_path "$agl_main_root")"
  [[ "$agl_main_root_abs" == "$repo_root_abs" ]] ||
    die ".agl MAIN_ROOT does not match current repo root"

  # Validate WORKTREE path safety
  local loop_dir_rel="${loop_dir#"$repo_root_abs"/}"
  require_safe_worktree_path "$agl_file" "$worktree_val" "$loop_dir_rel" "$repo_root_abs"

  # Compute and normalize worktree absolute path
  local worktree_abs_raw
  worktree_abs_raw="$(resolve_worktree_abs "$agl_file")"
  [[ -d "$worktree_abs_raw" ]] || die "Worktree directory not found: $worktree_abs_raw"
  local worktree_abs
  worktree_abs="$(abs_path "$worktree_abs_raw")"

  # For internal fallback worktrees, require within the repo's agent-loop directory
  local worktree_mode
  worktree_mode="$(read_meta_optional "$agl_file" WORKTREE_MODE)"
  if [[ "$worktree_mode" != "external" ]]; then
    [[ "$worktree_abs" == "$repo_root_abs/work/agent-loop/"* ]] ||
      die "Unsafe WORKTREE path (escapes work/agent-loop/)"
  fi

  # Verify target is a worktree of the current repo
  require_repo_membership "$worktree_abs" "$repo_root_abs"

  if ! git rev-parse --verify "$branch" >/dev/null 2>&1; then
    die "Branch not found: $branch"
  fi

  local current_branch
  current_branch="$(git -C "$worktree_abs" rev-parse --abbrev-ref HEAD)" ||
    die "Invalid worktree: $worktree_abs"
  if [[ "$current_branch" != "$branch" ]]; then
    die "Worktree is on $current_branch (expected $branch)"
  fi

  # Check worktree is dirty
  local wt_status
  wt_status="$(git -C "$worktree_abs" status --porcelain)" ||
    die "Invalid worktree: $worktree_abs"
  [[ -n "$wt_status" ]] || die "Nothing to commit (working tree clean)"

  # Build commit message
  local msg
  if [[ "$last_stage" == "fixer" ]]; then
    local fix_round=$((round - 1))
    if [[ "$fix_round" -le 1 ]]; then
      msg="agl: $slug fixer"
    else
      msg="agl: $slug fixer-r${fix_round}"
    fi
  elif [[ "$last_stage" == "worker" ]]; then
    local worker_pass
    worker_pass="$(read_meta_optional "$agl_file" WORKER_PASS)"
    if [[ -n "$worker_pass" && ! "$worker_pass" =~ ^[0-9]+$ ]]; then
      die "Invalid WORKER_PASS in .agl: $worker_pass"
    fi
    if [[ -n "$worker_pass" ]]; then
      msg="agl: $slug worker-r$((10#$worker_pass))"
    else
      msg="agl: $slug worker"
    fi
  else
    msg="agl: $slug $last_stage"
  fi

  # Stage and commit
  git -C "$worktree_abs" add -A && git -C "$worktree_abs" commit -m "$msg"

  # Record commit hash in .agl
  local new_hash
  new_hash="$(git -C "$worktree_abs" rev-parse --short HEAD)"
  local existing_commits
  existing_commits="$(read_meta_optional "$agl_file" COMMITS)"
  if [[ -z "$existing_commits" ]]; then
    echo "COMMITS=$new_hash" >>"$agl_file"
  else
    sed_inplace "s|^COMMITS=.*|COMMITS=${existing_commits}, ${new_hash}|" "$agl_file"
  fi

  echo "Committed: $msg ($new_hash)"
}

cmd_merge() {
  local slug="" loop_dir="" no_delete=false
  local agent_args=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
    --dir)
      require_arg "$1" "$#" "${2-}"
      loop_dir="$2"
      shift 2
      ;;
    --no-delete)
      no_delete=true
      shift
      ;;
    --agent)
      require_arg "$1" "$#" "${2-}"
      agent_args=("$2")
      shift 2
      agent_args+=("$@")
      break
      ;;
    -*) die "Unknown option: $1" ;;
    *)
      if [[ -z "$slug" ]]; then
        slug="$1"
        shift
      else
        die "Unexpected argument: $1"
      fi
      ;;
    esac
  done

  require_primary_worktree "agl merge"

  local repo_root
  repo_root="$(project_root)"
  [[ -d "$repo_root" ]] || die "Invalid repo root: $repo_root"
  local repo_root_abs
  repo_root_abs="$(abs_path "$repo_root")"

  # Find loop dir
  if [[ -n "$loop_dir" ]]; then
    : # use provided --dir
  elif [[ -n "$slug" ]]; then
    # Glob for loop dirs matching *-<slug>/ and confirm FEATURE_SLUG in .agl
    local loop_base="$repo_root_abs/work/agent-loop"
    local candidate_dir="" candidate_name=""
    local cand
    for cand in "$loop_base"/*-"${slug}"/; do
      [[ -d "$cand" ]] || continue
      [[ -f "$cand/.agl" ]] || continue
      local cand_slug
      cand_slug="$(grep "^FEATURE_SLUG=" "$cand/.agl" 2>/dev/null | head -1 | cut -d'=' -f2- || true)"
      [[ "$cand_slug" == "$slug" ]] || continue
      local cand_name
      cand_name="$(basename "$cand")"
      if [[ -z "$candidate_name" || "$cand_name" > "$candidate_name" ]]; then
        candidate_name="$cand_name"
        candidate_dir="${cand%/}"
      fi
    done
    [[ -n "$candidate_dir" ]] || die "No loop directory found for slug '$slug'"
    loop_dir="$candidate_dir"
  else
    loop_dir="$(find_loop_dir_any)"
  fi
  loop_dir="$(resolve_loop_dir "$loop_dir")"

  local agl_file="$loop_dir/.agl"
  [[ -f "$agl_file" ]] || die "No .agl metadata found in $loop_dir"

  # Read required .agl keys
  local agl_main_root branch worktree_val feature_slug
  agl_main_root="$(read_meta_optional "$agl_file" MAIN_ROOT)"
  branch="$(read_meta_optional "$agl_file" BRANCH)"
  worktree_val="$(read_meta_optional "$agl_file" WORKTREE)"
  feature_slug="$(read_meta_optional "$agl_file" FEATURE_SLUG)"

  if [[ -z "$agl_main_root" || -z "$branch" || -z "$worktree_val" || -z "$feature_slug" ]]; then
    die "Not a worktree-mode loop (required keys missing)"
  fi

  local expected_branch="agl/$feature_slug"
  if [[ "$branch" != "$expected_branch" ]]; then
    die "Unexpected BRANCH in .agl: $branch (expected $expected_branch)"
  fi

  # Validate .agl MAIN_ROOT matches current repo
  [[ -d "$agl_main_root" ]] || die "Invalid .agl MAIN_ROOT: $agl_main_root"
  local agl_main_root_abs
  agl_main_root_abs="$(abs_path "$agl_main_root")"
  [[ "$agl_main_root_abs" == "$repo_root_abs" ]] ||
    die ".agl MAIN_ROOT does not match current repo root"

  # Validate WORKTREE path safety
  local loop_dir_rel="${loop_dir#"$repo_root_abs"/}"
  require_safe_worktree_path "$agl_file" "$worktree_val" "$loop_dir_rel" "$repo_root_abs"

  # Compute and normalize worktree absolute path
  local worktree_abs_raw
  worktree_abs_raw="$(resolve_worktree_abs "$agl_file")"
  [[ -d "$worktree_abs_raw" ]] || die "Worktree directory not found: $worktree_abs_raw"
  local worktree_abs
  worktree_abs="$(abs_path "$worktree_abs_raw")"

  # For internal fallback worktrees, require within the repo's agent-loop directory
  local worktree_mode
  worktree_mode="$(read_meta_optional "$agl_file" WORKTREE_MODE)"
  if [[ "$worktree_mode" != "external" ]]; then
    [[ "$worktree_abs" == "$repo_root_abs/work/agent-loop/"* ]] ||
      die "Unsafe WORKTREE path (escapes work/agent-loop/)"
  fi

  # Verify target is a worktree of the current repo
  require_repo_membership "$worktree_abs" "$repo_root_abs"

  if ! git rev-parse --verify "$branch" >/dev/null 2>&1; then
    die "Branch not found: $branch"
  fi

  # Preflight: worktree must be clean
  local wt_status
  wt_status="$(git -C "$worktree_abs" status --porcelain)" ||
    die "Invalid worktree: $worktree_abs"
  [[ -z "$wt_status" ]] ||
    die "Worktree has uncommitted changes. Run 'agl commit' or discard changes first."

  # Preflight: primary worktree must be clean
  local primary_status
  primary_status="$(git status --porcelain)" ||
    die "Cannot check primary worktree status"
  [[ -z "$primary_status" ]] ||
    die "Primary worktree has uncommitted changes. Commit or stash them first."

  # Squash merge
  if ! git merge --squash "$branch"; then
    echo "Merge conflicts detected." >&2
    echo "Resolve conflicts, then: git add -A && git commit" >&2
    echo "To abort: git reset --hard HEAD" >&2
    exit 1
  fi

  local draft_path=""
  if [[ ${#agent_args[@]} -gt 0 ]]; then
    draft_path="$(create_commit_draft "$loop_dir" "$agl_file" "${agent_args[@]}")"
  fi

  # Commit (opens editor for user message)
  if [[ ${#agent_args[@]} -eq 0 ]]; then
    if ! git commit; then
      echo "Commit aborted. Squash is staged but not committed." >&2
      echo "To finish: rerun 'git commit'" >&2
      echo "To abandon: git reset --hard HEAD" >&2
      exit 1
    fi
  elif ! git commit -e -F "$draft_path"; then
    echo "Commit aborted. Squash is staged but not committed." >&2
    echo "To finish: rerun 'git commit -e -F \"$draft_path\"'" >&2
    echo "To abandon: git reset --hard HEAD" >&2
    exit 1
  fi

  # Cleanup (only after successful commit)
  if [[ "$no_delete" == true ]]; then
    echo "Merged $branch (worktree and branch preserved with --no-delete)"
  else
    git worktree remove "$worktree_abs"
    if [[ "$branch" != "$expected_branch" ]]; then
      die "Unexpected BRANCH in .agl: $branch (expected $expected_branch)"
    fi
    git branch -D "$branch"

    # For external worktrees, remove the timestamp-slug leaf directory
    if [[ "$worktree_mode" == "external" ]]; then
      local external_wt_dir
      external_wt_dir="$(dirname "$worktree_abs")"
      local worktree_base_val
      worktree_base_val="$(read_meta_optional "$agl_file" WORKTREE_BASE)"
      local framework_name
      framework_name="$(derive_framework_name "$repo_root_abs" "$worktree_base_val")"
      local expected_parent
      expected_parent="$worktree_base_val/$framework_name/$(basename "$repo_root_abs")"
      if [[ -n "$worktree_base_val" && "$external_wt_dir" == "$expected_parent/"* && -d "$external_wt_dir" ]]; then
        rm -rf "$external_wt_dir"
      fi
    fi

    echo "Merged and cleaned up $branch"
  fi
}

cmd_drop() {
  local slug="" loop_dir="" remove_all=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
    --dir)
      require_arg "$1" "$#" "${2-}"
      loop_dir="$2"
      shift 2
      ;;
    --all)
      remove_all=true
      shift
      ;;
    -*) die "Unknown option: $1" ;;
    *)
      if [[ -z "$slug" ]]; then
        slug="$1"
        shift
      else
        die "Unexpected argument: $1"
      fi
      ;;
    esac
  done

  require_primary_worktree "agl drop"

  local repo_root
  repo_root="$(project_root)"
  [[ -d "$repo_root" ]] || die "Invalid repo root: $repo_root"
  local repo_root_abs
  repo_root_abs="$(abs_path "$repo_root")"

  # Find loop dir
  if [[ -n "$loop_dir" ]]; then
    : # use provided --dir
  elif [[ -n "$slug" ]]; then
    local loop_base="$repo_root_abs/work/agent-loop"
    local candidate_dir="" candidate_name=""
    local cand
    for cand in "$loop_base"/*-"${slug}"/; do
      [[ -d "$cand" ]] || continue
      [[ -f "$cand/.agl" ]] || continue
      local cand_slug
      cand_slug="$(grep "^FEATURE_SLUG=" "$cand/.agl" 2>/dev/null | head -1 | cut -d'=' -f2- || true)"
      [[ "$cand_slug" == "$slug" ]] || continue
      local cand_name
      cand_name="$(basename "$cand")"
      if [[ -z "$candidate_name" || "$cand_name" > "$candidate_name" ]]; then
        candidate_name="$cand_name"
        candidate_dir="${cand%/}"
      fi
    done
    [[ -n "$candidate_dir" ]] || die "No loop directory found for slug '$slug'"
    loop_dir="$candidate_dir"
  else
    loop_dir="$(find_loop_dir_any)"
  fi
  loop_dir="$(resolve_loop_dir "$loop_dir")"

  local agl_file="$loop_dir/.agl"
  [[ -f "$agl_file" ]] || die "No .agl metadata found in $loop_dir"

  local agl_main_root branch worktree_val feature_slug
  agl_main_root="$(read_meta_optional "$agl_file" MAIN_ROOT)"
  branch="$(read_meta_optional "$agl_file" BRANCH)"
  worktree_val="$(read_meta_optional "$agl_file" WORKTREE)"
  feature_slug="$(read_meta_optional "$agl_file" FEATURE_SLUG)"

  if [[ -z "$agl_main_root" || -z "$branch" || -z "$worktree_val" || -z "$feature_slug" ]]; then
    die "Not a worktree-mode loop (required keys missing)"
  fi

  local expected_branch="agl/$feature_slug"
  if [[ "$branch" != "$expected_branch" ]]; then
    die "Unexpected BRANCH in .agl: $branch (expected $expected_branch)"
  fi

  # Validate .agl MAIN_ROOT matches current repo
  [[ -d "$agl_main_root" ]] || die "Invalid .agl MAIN_ROOT: $agl_main_root"
  local agl_main_root_abs
  agl_main_root_abs="$(abs_path "$agl_main_root")"
  [[ "$agl_main_root_abs" == "$repo_root_abs" ]] ||
    die ".agl MAIN_ROOT does not match current repo root"

  # Validate WORKTREE path safety
  local loop_dir_rel="${loop_dir#"$repo_root_abs"/}"
  require_safe_worktree_path "$agl_file" "$worktree_val" "$loop_dir_rel" "$repo_root_abs"

  local worktree_abs
  worktree_abs="$(resolve_worktree_abs "$agl_file")"

  # Print what will be removed and ask for confirmation
  echo "Will remove:"
  echo "  Branch:   $branch"
  if [[ -d "$worktree_abs" ]]; then
    echo "  Worktree: $worktree_val"
  fi
  if [[ "$remove_all" == true ]]; then
    echo "  Loop dir: $loop_dir_rel"
  fi
  printf 'Proceed? [y/N] '
  local answer
  read -r answer
  case "$answer" in
  [yY] | [yY][eE][sS]) ;;
  *)
    echo "Aborted."
    exit 1
    ;;
  esac

  # Remove worktree
  if [[ -d "$worktree_abs" ]]; then
    require_repo_membership "$worktree_abs" "$repo_root_abs"
    git worktree remove --force "$worktree_abs"
  fi
  git worktree prune 2>/dev/null || true

  # For external worktrees, remove the timestamp-slug leaf directory
  local worktree_mode
  worktree_mode="$(read_meta_optional "$agl_file" WORKTREE_MODE)"
  if [[ "$worktree_mode" == "external" ]]; then
    local external_wt_dir
    external_wt_dir="$(dirname "$worktree_abs")"
    local worktree_base_val
    worktree_base_val="$(read_meta_optional "$agl_file" WORKTREE_BASE)"
    local framework_name
    framework_name="$(derive_framework_name "$repo_root_abs" "$worktree_base_val")"
    local expected_parent
    expected_parent="$worktree_base_val/$framework_name/$(basename "$repo_root_abs")"
    if [[ -n "$worktree_base_val" && "$external_wt_dir" == "$expected_parent/"* && -d "$external_wt_dir" ]]; then
      rm -rf "$external_wt_dir"
    fi
  fi

  # Delete branch
  if git rev-parse --verify "$branch" >/dev/null 2>&1; then
    git branch -D "$branch"
  fi

  # Remove loop directory
  if [[ "$remove_all" == true ]]; then
    rm -rf "$loop_dir"
    echo "Dropped $feature_slug (worktree, branch, and loop directory removed)"
  else
    echo "Dropped $feature_slug (worktree and branch removed; loop directory preserved)"
  fi
}

# ------------------------------------------------------------
# Main
# ------------------------------------------------------------
[[ $# -lt 1 ]] && usage

command="$1"
shift

case "$command" in
init) cmd_init "$@" ;;
work) cmd_work "$@" ;;
commit) cmd_commit "$@" ;;
enhance) cmd_enhance "$@" ;;
review) cmd_review "$@" ;;
fix) cmd_fix "$@" ;;
merge) cmd_merge "$@" ;;
drop) cmd_drop "$@" ;;
-h | --help) usage 0 ;;
*) die "Unknown command: $command. Run 'agl --help' for usage." ;;
esac
