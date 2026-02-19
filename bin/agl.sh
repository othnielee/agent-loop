#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# agl — Agent Loop scaffolding tool
#
# Generates loop directories, fills template placeholders, and
# prints ready-to-run agw commands. Does NOT execute agents.
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
  enhance               Generate enhancer prompt
  review                Generate reviewer prompt
  fix                   Generate fixer prompt
  commit                Stage and commit changes in the worktree
  merge [<slug>]        Squash-merge worktree branch into the current branch

Init options:
  --plan <path>         Path to the plan file (required)
  --task <description>  Task description (default: Implement the feature according to the plan.)
  --context <paths>     Additional context paths (default: None)

Enhance options:
  --dir <path>          Loop directory (default: most recent)
  --context <paths>     Additional context paths (default: None)
  --commits <hashes>    Relevant commit hashes (default: None)
  --instructions <text> Additional instructions (default: None)

Review options:
  --dir <path>          Loop directory (default: most recent)
  --files <paths>       File paths to review (default: None)
  --context <paths>     Additional context paths (default: None)
  --commits <hashes>    Relevant commit hashes (default: None)
  --checklist <text>    Review checklist (default: None)

Fix options:
  --dir <path>          Loop directory (default: most recent)
  --context <paths>     Additional context paths (default: None)

Commit options:
  --dir <path>          Loop directory (default: most recent)

Merge options:
  [<slug>]              Feature slug to merge (default: most recent)
  --dir <path>          Loop directory (default: most recent)
  --no-delete           Preserve worktree and branch after merge

Examples:
  agl init add-auth --plan work/wip/task-1.md
  agl enhance
  agl review --files "src/auth.rs, src/middleware.rs"
  agl fix
  agl commit
  agl merge add-auth
EOF
  exit "${1:-1}"
}

# ------------------------------------------------------------
# Helpers
# ------------------------------------------------------------
die() { echo "Error: $*" >&2; exit 1; }

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
  sed "$expr" "$file" > "$tmp" && mv "$tmp" "$file"
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
  [[ "$(git rev-parse --git-dir)" == "$(git rev-parse --git-common-dir)" ]] \
    || die "$1 must run from the primary worktree, not a linked worktree."
}

# Hard-stop if a path is not ignored by git.
require_ignored() {
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "Not in a git repository"
  local root
  root="$(project_root)"
  git -C "$root" check-ignore -q -- "$1" \
    || die "$1 must be in .gitignore or .git/info/exclude before proceeding."
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
    echo "LAST_STAGE=$stage" >> "$agl_file"
  fi
}

# Validate a WORKTREE value from .agl before use in git -C or git worktree remove.
# Prevents path traversal and spoofing.
require_safe_worktree_relpath() {
  local worktree_val="$1" expected_slug="$2"

  # Must be relative (no leading /)
  if [[ "$worktree_val" == /* ]]; then
    die "Unsafe WORKTREE path (absolute): $worktree_val"
  fi

  # Must start with expected prefix
  if [[ "$worktree_val" != work/agent-loop/worktrees/* ]]; then
    die "Unsafe WORKTREE path (wrong prefix): $worktree_val"
  fi

  # Must not contain ..
  if [[ "$worktree_val" == *..* ]]; then
    die "Unsafe WORKTREE path (contains ..): $worktree_val"
  fi

  # Must be exactly work/agent-loop/worktrees/<slug> (one component after prefix)
  local after_prefix="${worktree_val#work/agent-loop/worktrees/}"
  if [[ "$after_prefix" == */* ]]; then
    die "Unsafe WORKTREE path (extra path components): $worktree_val"
  fi

  # Slug component must match FEATURE_SLUG
  if [[ "$after_prefix" != "$expected_slug" ]]; then
    die "WORKTREE slug '$after_prefix' does not match FEATURE_SLUG '$expected_slug'"
  fi
}

# Find the most recent loop directory with a .agl file.
# Falls back to worktree enumeration if nothing found in CWD's tree.
find_loop_dir() {
  local root
  root="$(project_root)"
  local loop_base="$root/work/agent-loop"

  # Try local tree first
  if [[ -d "$loop_base" ]]; then
    local latest
    latest="$(ls -1d "$loop_base"/*/ 2>/dev/null | sort -r | while read -r d; do
      if [[ -f "$d/.agl" ]] \
        && grep -q "^BRANCH=" "$d/.agl" 2>/dev/null \
        && grep -q "^WORKTREE=" "$d/.agl" 2>/dev/null \
        && grep -q "^MAIN_ROOT=" "$d/.agl" 2>/dev/null; then
        echo "$d"
        break
      fi
    done)"

    if [[ -n "$latest" ]]; then
      echo "${latest%/}"
      return 0
    fi
  fi

  # Fall back to worktree enumeration
  local wt_result
  wt_result="$(find_worktree_loop_dir)"
  if [[ -n "$wt_result" ]]; then
    echo "$wt_result"
    return 0
  fi

  die "No loop directory with .agl metadata found"
}

# Find the most recent worktree-mode loop across all linked worktrees.
# Only returns loops whose .agl contains required worktree keys.
find_worktree_loop_dir() {
  local root
  root="$(project_root)"
  local worktrees_base="$root/work/agent-loop/worktrees"

  if [[ ! -d "$worktrees_base" ]]; then
    return 0
  fi

  local wt_path
  local latest_path="" latest_name=""
  for wt_path in "$worktrees_base"/*; do
    [[ -d "$wt_path" ]] || continue
    local wt_loop_base="$wt_path/work/agent-loop"
    [[ -d "$wt_loop_base" ]] || continue

    local candidate
    candidate="$(ls -1d "$wt_loop_base"/*/ 2>/dev/null | sort -r | while read -r d; do
      [[ -f "$d/.agl" ]] || continue
      if grep -q "^BRANCH=" "$d/.agl" 2>/dev/null \
        && grep -q "^WORKTREE=" "$d/.agl" 2>/dev/null \
        && grep -q "^MAIN_ROOT=" "$d/.agl" 2>/dev/null; then
        echo "${d%/}"
        break
      fi
    done)"

    [[ -n "$candidate" ]] || continue

    local candidate_name
    candidate_name="$(basename "$candidate")"
    if [[ -z "$latest_name" || "$candidate_name" > "$latest_name" ]]; then
      latest_name="$candidate_name"
      latest_path="$candidate"
    fi
  done

  [[ -n "$latest_path" ]] && echo "$latest_path"
}

# Find loop dir within a specific root directory.
find_loop_dir_in() {
  local search_root="$1"
  local loop_base="$search_root/work/agent-loop"

  if [[ ! -d "$loop_base" ]]; then
    die "No agent-loop directory found in $search_root"
  fi

  local latest
  latest="$(ls -1d "$loop_base"/*/ 2>/dev/null | sort -r | while read -r d; do
    if [[ -f "$d/.agl" ]] \
      && grep -q "^BRANCH=" "$d/.agl" 2>/dev/null \
      && grep -q "^WORKTREE=" "$d/.agl" 2>/dev/null \
      && grep -q "^MAIN_ROOT=" "$d/.agl" 2>/dev/null; then
      echo "$d"
      break
    fi
  done)"

  if [[ -z "$latest" ]]; then
    die "No loop directory with .agl metadata found in $loop_base"
  fi

  echo "${latest%/}"
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

# Compute the loop's output dir relative to the repo/worktree root used by the agent.
# For worktree-mode loops, this makes OUTPUT_DIR valid from inside the linked worktree.
loop_rel_output_dir() {
  local loop_dir="$1" agl_file="$2"
  local root
  root="$(project_root)"

  local worktree_rel
  worktree_rel="$(read_meta_optional "$agl_file" WORKTREE)"
  if [[ -n "$worktree_rel" ]]; then
    local worktree_abs="$root/$worktree_rel"
    if [[ "$loop_dir" == "$worktree_abs/"* ]]; then
      local loop_rel="${loop_dir#"$worktree_abs"/}"
      echo "$loop_rel/output"
      return 0
    fi
  fi

  echo "${loop_dir#"$root"/}/output"
}

# Print the prompt path and ready-to-run agw commands.
# When worktree_rel is provided, prints (cd ...) wrapped commands.
print_commands() {
  local prompt_path="$1"
  local readonly_flag="${2:-}"
  local worktree_rel="${3:-}"
  local root
  root="$(project_root)"
  local rel_path="${prompt_path#"$root"/}"

  echo ""
  if [[ -n "$worktree_rel" ]]; then
    # Compute prompt path relative to worktree root
    local worktree_abs="$root/$worktree_rel"
    if [[ "$prompt_path" == "$worktree_abs/"* ]]; then
      local prompt_rel="${prompt_path#"$worktree_abs"/}"
      echo "Prompt: $rel_path"
      echo ""
      echo "Run:"
      if [[ "$readonly_flag" == "-r" ]]; then
        echo "  (cd \"$worktree_rel\" && agw claude -r \"$prompt_rel\")"
        echo "  (cd \"$worktree_rel\" && agw codex  -r \"$prompt_rel\")"
      else
        echo "  (cd \"$worktree_rel\" && agw claude \"$prompt_rel\")"
        echo "  (cd \"$worktree_rel\" && agw codex  \"$prompt_rel\")"
      fi
      return 0
    fi
  fi

  echo "Prompt: $rel_path"
  echo ""
  echo "Run:"
  if [[ "$readonly_flag" == "-r" ]]; then
    echo "  agw claude -r $rel_path"
    echo "  agw codex  -r $rel_path"
  else
    echo "  agw claude $rel_path"
    echo "  agw codex  $rel_path"
  fi
}

# ------------------------------------------------------------
# Subcommands
# ------------------------------------------------------------

cmd_init() {
  local slug="" plan_path="" task_desc="" other_context="None"

  # Parse the slug (first non-flag arg)
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --plan)     require_arg "$1" "$#" "${2-}"; plan_path="$2"; shift 2 ;;
      --task)     require_arg "$1" "$#" "${2-}"; reject_multiline "$1" "${2-}"; task_desc="$2"; shift 2 ;;
      --context)  require_arg "$1" "$#" "${2-}"; reject_multiline "$1" "${2-}"; other_context="$2"; shift 2 ;;
      -*)         die "Unknown option: $1" ;;
      *)
        if [[ -z "$slug" ]]; then
          slug="$1"; shift
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
  require_ignored "work/agent-loop/worktrees"

  local caller_pwd
  caller_pwd="$(pwd -P)"

  local plan_abs
  case "$plan_path" in
    /*) plan_abs="$plan_path" ;;
    *)  plan_abs="$caller_pwd/$plan_path" ;;
  esac

  [[ -f "$plan_abs" && -r "$plan_abs" ]] \
    || die "Plan file not found or not readable: $plan_path"

  # Validate --context files before any branch/worktree creation
  if [[ "$other_context" != "None" ]]; then
    local IFS=',' validate_ctx
    for validate_ctx in $other_context; do
      validate_ctx="$(printf '%s' "$validate_ctx" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
      local validate_abs
      case "$validate_ctx" in
        /*) validate_abs="$validate_ctx" ;;
        *)  validate_abs="$caller_pwd/$validate_ctx" ;;
      esac
      [[ -f "$validate_abs" && -r "$validate_abs" ]] \
        || die "Context file not found or not readable: $validate_ctx"
    done
  fi

  local branch_name="agl/$slug"
  local worktree_rel="work/agent-loop/worktrees/$slug"

  # Validate no conflicts
  if git rev-parse --verify "$branch_name" >/dev/null 2>&1; then
    die "Branch $branch_name already exists"
  fi
  if [[ -d "$main_root/$worktree_rel" ]]; then
    die "Worktree directory already exists: $worktree_rel"
  fi

  # --- Create branch and worktree ---
  git branch "$branch_name" HEAD

  local worktree_abs="$main_root/$worktree_rel"
  if ! git worktree add "$worktree_abs" "$branch_name"; then
    git worktree remove --force "$worktree_abs" 2>/dev/null || true
    git worktree prune 2>/dev/null || true
    if [[ "$worktree_abs" == "$main_root/work/agent-loop/worktrees/"* ]]; then
      rm -rf "$worktree_abs"
    fi
    git branch -D "$branch_name" 2>/dev/null || true
    die "Failed to create worktree at $worktree_rel"
  fi

  # Anchor all downstream paths to the worktree
  local root="$worktree_abs"

  local date timestamp loop_dir prompts_dir output_dir context_dir
  date="$(date +%Y-%m-%d)"
  timestamp="$(date +%Y-%m-%d-%H%M%S)"
  loop_dir="$root/work/agent-loop/${timestamp}-${slug}"
  prompts_dir="$loop_dir/prompts"
  output_dir="$loop_dir/output"
  context_dir="$loop_dir/context"

  # Relative paths (from worktree root)
  local rel_output_dir="${output_dir#"$root"/}"
  local rel_context_dir="${context_dir#"$root"/}"

  mkdir -p "$prompts_dir" "$output_dir" "$context_dir"

  local plan_base
  plan_base="$(basename "$plan_abs")"
  local plan_dest
  if [[ "$plan_base" == *.* ]]; then
    plan_dest="plan.${plan_base##*.}"
  else
    plan_dest="plan"
  fi
  cp "$plan_abs" "$context_dir/$plan_dest"
  local rel_plan_path="$rel_context_dir/$plan_dest"

  # Snapshot --context files into context/ (resolved from invocation directory)
  local rel_context_paths="None"
  if [[ "$other_context" != "None" ]]; then
    rel_context_paths=""
    local IFS=','
    for ctx_path in $other_context; do
      ctx_path="$(printf '%s' "$ctx_path" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"

      local ctx_abs
      case "$ctx_path" in
        /*) ctx_abs="$ctx_path" ;;
        *)  ctx_abs="$caller_pwd/$ctx_path" ;;
      esac

      local ctx_base ctx_dest
      ctx_base="$(basename "$ctx_abs")"
      ctx_dest="$ctx_base"
      # Disambiguate if basename already exists in context/
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
      if [[ -n "$rel_context_paths" ]]; then
        rel_context_paths="$rel_context_paths, $rel_context_dir/$ctx_dest"
      else
        rel_context_paths="$rel_context_dir/$ctx_dest"
      fi
    done
  fi

  # Write .agl metadata
  cat > "$loop_dir/.agl" <<EOF
FEATURE_SLUG=$slug
PLAN_PATH=$rel_plan_path
DATE=$date
ROUND=1
BRANCH=$branch_name
WORKTREE=$worktree_rel
MAIN_ROOT=$main_root
LAST_STAGE=worker
EOF

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
    -e "s|{{PLAN_PATH}}|$(sed_escape "$rel_plan_path")|g" \
    -e "s|{{HANDOFF_PATHS}}|None|g" \
    -e "s|{{OTHER_CONTEXT}}|$(sed_escape "$rel_context_paths")|g" \
    -e "s|{{TASK_DESCRIPTION}}|$(sed_escape "$task_desc")|g" \
    -e "s|{{OUTPUT_DIR}}|$(sed_escape "$rel_output_dir")|g" \
    "$template" > "$prompt"

  echo "Created loop: ${loop_dir#"$main_root"/}"
  print_commands "$prompt" "" "$worktree_rel"
}

cmd_enhance() {
  local loop_dir="" other_context="None" commit_hashes="None" instructions="None"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dir)          require_arg "$1" "$#" "${2-}"; loop_dir="$2"; shift 2 ;;
      --context)      require_arg "$1" "$#" "${2-}"; reject_multiline "$1" "${2-}"; other_context="$2"; shift 2 ;;
      --commits)      require_arg "$1" "$#" "${2-}"; reject_multiline "$1" "${2-}"; commit_hashes="$2"; shift 2 ;;
      --instructions) require_arg "$1" "$#" "${2-}"; reject_multiline "$1" "${2-}"; instructions="$2"; shift 2 ;;
      *)              die "Unknown option: $1" ;;
    esac
  done

  if [[ -z "$loop_dir" ]]; then
    loop_dir="$(find_loop_dir)"
  fi

  local agl_file="$loop_dir/.agl"
  [[ -f "$agl_file" ]] || die "No .agl metadata found in $loop_dir"

  warn_uncommitted

  local slug plan_path date
  slug="$(read_meta "$agl_file" FEATURE_SLUG)"
  plan_path="$(read_meta "$agl_file" PLAN_PATH)"
  date="$(read_meta "$agl_file" DATE)"

  # Use tracked commits if --commits not provided
  if [[ "$commit_hashes" == "None" ]]; then
    local tracked
    tracked="$(read_meta_optional "$agl_file" COMMITS)"
    [[ -n "$tracked" ]] && commit_hashes="$tracked"
  fi

  local rel_output_dir
  rel_output_dir="$(loop_rel_output_dir "$loop_dir" "$agl_file")"
  local handoff_path="$rel_output_dir/HANDOFF-${slug}.md"
  local feature_name
  feature_name="$(slug_to_name "$slug")"

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
    -e "s|{{PLAN_PATH}}|$(sed_escape "$plan_path")|g" \
    -e "s|{{HANDOFF_PATH}}|$(sed_escape "$handoff_path")|g" \
    -e "s|{{OTHER_CONTEXT}}|$(sed_escape "$other_context")|g" \
    -e "s|{{COMMIT_HASHES}}|$(sed_escape "$commit_hashes")|g" \
    -e "s|{{ADDITIONAL_INSTRUCTIONS}}|$(sed_escape "$instructions")|g" \
    -e "s|{{OUTPUT_DIR}}|$(sed_escape "$rel_output_dir")|g" \
    "$template" > "$prompt"

  update_last_stage "$agl_file" "enhancer"

  print_commands "$prompt" "" "$worktree_rel"
}

cmd_review() {
  local loop_dir="" file_paths="None" other_context="None" commit_hashes="None" checklist="None"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dir)       require_arg "$1" "$#" "${2-}"; loop_dir="$2"; shift 2 ;;
      --files)     require_arg "$1" "$#" "${2-}"; reject_multiline "$1" "${2-}"; file_paths="$2"; shift 2 ;;
      --context)   require_arg "$1" "$#" "${2-}"; reject_multiline "$1" "${2-}"; other_context="$2"; shift 2 ;;
      --commits)   require_arg "$1" "$#" "${2-}"; reject_multiline "$1" "${2-}"; commit_hashes="$2"; shift 2 ;;
      --checklist) require_arg "$1" "$#" "${2-}"; reject_multiline "$1" "${2-}"; checklist="$2"; shift 2 ;;
      *)           die "Unknown option: $1" ;;
    esac
  done

  if [[ -z "$loop_dir" ]]; then
    loop_dir="$(find_loop_dir)"
  fi

  local agl_file="$loop_dir/.agl"
  [[ -f "$agl_file" ]] || die "No .agl metadata found in $loop_dir"

  warn_uncommitted

  local slug plan_path date round
  slug="$(read_meta "$agl_file" FEATURE_SLUG)"
  plan_path="$(read_meta "$agl_file" PLAN_PATH)"
  date="$(read_meta "$agl_file" DATE)"
  round="$(read_meta "$agl_file" ROUND)"

  # Use tracked commits if --commits not provided
  if [[ "$commit_hashes" == "None" ]]; then
    local tracked
    tracked="$(read_meta_optional "$agl_file" COMMITS)"
    [[ -n "$tracked" ]] && commit_hashes="$tracked"
  fi

  local rel_output_dir
  rel_output_dir="$(loop_rel_output_dir "$loop_dir" "$agl_file")"
  local feature_name
  feature_name="$(slug_to_name "$slug")"

  local worktree_rel
  worktree_rel="$(read_meta_optional "$agl_file" WORKTREE)"

  # Compute handoff paths scoped to what's relevant for this round
  local handoff_paths=""
  local output_abs="$loop_dir/output"
  if [[ "$round" -gt 1 ]]; then
    # Re-review: only the latest fix report matters
    local prev_round=$((round - 1))
    local fix_file
    if [[ "$prev_round" -gt 1 ]]; then
      fix_file="FIX-r${prev_round}-${slug}.md"
    else
      fix_file="FIX-${slug}.md"
    fi
    if [[ ! -f "$output_abs/$fix_file" ]]; then
      die "Fix report $fix_file not found in $output_abs. Run the fixer for round $prev_round first."
    fi
    handoff_paths="$rel_output_dir/$fix_file"
  else
    # Round 1: worker and enhancer handoffs
    if [[ -f "$output_abs/HANDOFF-${slug}.md" ]]; then
      handoff_paths="$rel_output_dir/HANDOFF-${slug}.md"
    fi
    if [[ -f "$output_abs/ENHANCE-${slug}.md" ]]; then
      if [[ -n "$handoff_paths" ]]; then
        handoff_paths="$handoff_paths, $rel_output_dir/ENHANCE-${slug}.md"
      else
        handoff_paths="$rel_output_dir/ENHANCE-${slug}.md"
      fi
    fi
  fi
  [[ -z "$handoff_paths" ]] && handoff_paths="None"

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

  sed \
    -e "s|{{DATE}}|$(sed_escape "$date")|g" \
    -e "s|{{FEATURE_SLUG}}|$(sed_escape "$slug")|g" \
    -e "s|{{FEATURE_NAME}}|$(sed_escape "$feature_name")|g" \
    -e "s|{{PLAN_PATH}}|$(sed_escape "$plan_path")|g" \
    -e "s|{{HANDOFF_PATHS}}|$(sed_escape "$handoff_paths")|g" \
    -e "s|{{FILE_PATHS}}|$(sed_escape "$file_paths")|g" \
    -e "s|{{OTHER_CONTEXT}}|$(sed_escape "$other_context")|g" \
    -e "s|{{COMMIT_HASHES}}|$(sed_escape "$commit_hashes")|g" \
    -e "s|{{REVIEW_CHECKLIST}}|$(sed_escape "$checklist")|g" \
    -e "s|{{OUTPUT_DIR}}|$(sed_escape "$rel_output_dir")|g" \
    "$template" > "$prompt"

  # If round > 1, fix the output filename in the generated prompt
  if [[ "$round" -gt 1 ]]; then
    sed_inplace "s|REVIEW-$(sed_escape "${slug}").md|$(sed_escape "$review_output")|g" "$prompt"
  fi

  print_commands "$prompt" "-r" "$worktree_rel"
}

cmd_fix() {
  local loop_dir="" other_context="None"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dir)     require_arg "$1" "$#" "${2-}"; loop_dir="$2"; shift 2 ;;
      --context) require_arg "$1" "$#" "${2-}"; reject_multiline "$1" "${2-}"; other_context="$2"; shift 2 ;;
      *)         die "Unknown option: $1" ;;
    esac
  done

  if [[ -z "$loop_dir" ]]; then
    loop_dir="$(find_loop_dir)"
  fi

  local agl_file="$loop_dir/.agl"
  [[ -f "$agl_file" ]] || die "No .agl metadata found in $loop_dir"

  warn_uncommitted

  local slug plan_path date round
  slug="$(read_meta "$agl_file" FEATURE_SLUG)"
  plan_path="$(read_meta "$agl_file" PLAN_PATH)"
  date="$(read_meta "$agl_file" DATE)"
  round="$(read_meta "$agl_file" ROUND)"

  local rel_output_dir
  rel_output_dir="$(loop_rel_output_dir "$loop_dir" "$agl_file")"
  local feature_name
  feature_name="$(slug_to_name "$slug")"

  local worktree_rel
  worktree_rel="$(read_meta_optional "$agl_file" WORKTREE)"

  # Find the review file for the current round
  local review_path=""
  local output_abs="$loop_dir/output"

  if [[ "$round" -gt 1 ]]; then
    # Round 2+: look for the round-specific review file
    local review_file="REVIEW-r${round}-${slug}.md"
    if [[ -f "$output_abs/$review_file" ]]; then
      review_path="$rel_output_dir/$review_file"
    fi
  else
    # Round 1: look for the base review file
    if [[ -f "$output_abs/REVIEW-${slug}.md" ]]; then
      review_path="$rel_output_dir/REVIEW-${slug}.md"
    fi
  fi

  [[ -z "$review_path" ]] && die "No review findings found in $output_abs. Run the reviewer first."

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
    -e "s|{{PLAN_PATH}}|$(sed_escape "$plan_path")|g" \
    -e "s|{{REVIEW_PATH}}|$(sed_escape "$review_path")|g" \
    -e "s|{{OTHER_CONTEXT}}|$(sed_escape "$other_context")|g" \
    -e "s|{{OUTPUT_DIR}}|$(sed_escape "$rel_output_dir")|g" \
    "$template" > "$prompt"

  # If round > 1, fix the output filename in the generated prompt
  if [[ "$round" -gt 1 ]]; then
    sed_inplace "s|FIX-$(sed_escape "${slug}").md|$(sed_escape "$fix_output")|g" "$prompt"
  fi

  # Increment round for next review-fix cycle
  local new_round=$((round + 1))
  sed_inplace "s|^ROUND=.*|ROUND=$new_round|" "$agl_file"

  update_last_stage "$agl_file" "fixer"

  print_commands "$prompt" "" "$worktree_rel"
}

cmd_commit() {
  local loop_dir=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dir) require_arg "$1" "$#" "${2-}"; loop_dir="$2"; shift 2 ;;
      *)     die "Unknown option: $1" ;;
    esac
  done

  if [[ -z "$loop_dir" ]]; then
    loop_dir="$(find_loop_dir)"
  fi

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
  [[ "$agl_main_root_abs" == "$repo_root_abs" ]] \
    || die ".agl MAIN_ROOT does not match current repo root"

  # Validate WORKTREE path safety
  require_safe_worktree_relpath "$worktree_val" "$slug"

  # Compute and normalize worktree absolute path
  local worktree_abs_raw="$agl_main_root_abs/$worktree_val"
  [[ -d "$worktree_abs_raw" ]] || die "Worktree directory not found: $worktree_abs_raw"
  local worktree_abs
  worktree_abs="$(abs_path "$worktree_abs_raw")"

  # Require worktree is within the repo's worktree root
  [[ "$worktree_abs" == "$repo_root_abs/work/agent-loop/worktrees/"* ]] \
    || die "Unsafe WORKTREE path (escapes worktrees/)"

  # Verify target is a worktree of the current repo (git common-dir check)
  local repo_common repo_common_path repo_common_abs
  repo_common="$(git -C "$repo_root_abs" rev-parse --git-common-dir)"
  case "$repo_common" in
    /*) repo_common_path="$repo_common" ;;
    *)  repo_common_path="$repo_root_abs/$repo_common" ;;
  esac
  [[ -d "$repo_common_path" ]] || die "Invalid repo common git dir: $repo_common_path"
  repo_common_abs="$(abs_path "$repo_common_path")"

  local wt_common wt_common_path wt_common_abs
  wt_common="$(git -C "$worktree_abs" rev-parse --git-common-dir)"
  case "$wt_common" in
    /*) wt_common_path="$wt_common" ;;
    *)  wt_common_path="$worktree_abs/$wt_common" ;;
  esac
  [[ -d "$wt_common_path" ]] || die "Invalid worktree common git dir: $wt_common_path"
  wt_common_abs="$(abs_path "$wt_common_path")"

  [[ "$wt_common_abs" == "$repo_common_abs" ]] \
    || die "Worktree does not belong to current repo (git common-dir mismatch)"

  if ! git rev-parse --verify "$branch" >/dev/null 2>&1; then
    die "Branch not found: $branch"
  fi

  local current_branch
  current_branch="$(git -C "$worktree_abs" rev-parse --abbrev-ref HEAD)" \
    || die "Invalid worktree: $worktree_abs"
  if [[ "$current_branch" != "$branch" ]]; then
    die "Worktree is on $current_branch (expected $branch)"
  fi

  # Check worktree is dirty
  local wt_status
  wt_status="$(git -C "$worktree_abs" status --porcelain)" \
    || die "Invalid worktree: $worktree_abs"
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
    echo "COMMITS=$new_hash" >> "$agl_file"
  else
    sed_inplace "s|^COMMITS=.*|COMMITS=${existing_commits},${new_hash}|" "$agl_file"
  fi

  echo "Committed: $msg ($new_hash)"
}

cmd_merge() {
  local slug="" loop_dir="" no_delete=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dir)       require_arg "$1" "$#" "${2-}"; loop_dir="$2"; shift 2 ;;
      --no-delete) no_delete=true; shift ;;
      -*)          die "Unknown option: $1" ;;
      *)
        if [[ -z "$slug" ]]; then
          slug="$1"; shift
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
    local candidate_worktree_abs="$repo_root_abs/work/agent-loop/worktrees/$slug"
    [[ -d "$candidate_worktree_abs" ]] \
      || die "Worktree not found for slug '$slug': $candidate_worktree_abs"
    loop_dir="$(find_loop_dir_in "$candidate_worktree_abs")"
  else
    loop_dir="$(find_worktree_loop_dir)"
    [[ -n "$loop_dir" ]] || die "No worktree-mode loop found"
  fi

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
  [[ "$agl_main_root_abs" == "$repo_root_abs" ]] \
    || die ".agl MAIN_ROOT does not match current repo root"

  # Validate WORKTREE path safety
  require_safe_worktree_relpath "$worktree_val" "$feature_slug"

  # Compute and normalize worktree absolute path
  local worktree_abs_raw="$agl_main_root_abs/$worktree_val"
  [[ -d "$worktree_abs_raw" ]] || die "Worktree directory not found: $worktree_abs_raw"
  local worktree_abs
  worktree_abs="$(abs_path "$worktree_abs_raw")"

  # Require worktree is within the repo's worktree root
  [[ "$worktree_abs" == "$repo_root_abs/work/agent-loop/worktrees/"* ]] \
    || die "Unsafe WORKTREE path (escapes worktrees/)"

  # Verify target is a worktree of the current repo (git common-dir check)
  local repo_common repo_common_path repo_common_abs
  repo_common="$(git -C "$repo_root_abs" rev-parse --git-common-dir)"
  case "$repo_common" in
    /*) repo_common_path="$repo_common" ;;
    *)  repo_common_path="$repo_root_abs/$repo_common" ;;
  esac
  [[ -d "$repo_common_path" ]] || die "Invalid repo common git dir: $repo_common_path"
  repo_common_abs="$(abs_path "$repo_common_path")"

  local wt_common wt_common_path wt_common_abs
  wt_common="$(git -C "$worktree_abs" rev-parse --git-common-dir)"
  case "$wt_common" in
    /*) wt_common_path="$wt_common" ;;
    *)  wt_common_path="$worktree_abs/$wt_common" ;;
  esac
  [[ -d "$wt_common_path" ]] || die "Invalid worktree common git dir: $wt_common_path"
  wt_common_abs="$(abs_path "$wt_common_path")"

  [[ "$wt_common_abs" == "$repo_common_abs" ]] \
    || die "Worktree does not belong to current repo (git common-dir mismatch)"

  if ! git rev-parse --verify "$branch" >/dev/null 2>&1; then
    die "Branch not found: $branch"
  fi

  # Preflight: worktree must be clean
  local wt_status
  wt_status="$(git -C "$worktree_abs" status --porcelain)" \
    || die "Invalid worktree: $worktree_abs"
  [[ -z "$wt_status" ]] \
    || die "Worktree has uncommitted changes. Run 'agl commit' or discard changes first."

  # Preflight: primary worktree must be clean
  local primary_status
  primary_status="$(git status --porcelain)" \
    || die "Cannot check primary worktree status"
  [[ -z "$primary_status" ]] \
    || die "Primary worktree has uncommitted changes. Commit or stash them first."

  # Squash merge
  if ! git merge --squash "$branch"; then
    echo "Merge conflicts detected." >&2
    echo "Resolve conflicts, then: git add -A && git commit" >&2
    echo "To abort: git reset --hard HEAD" >&2
    exit 1
  fi

  # Commit (opens editor for user message)
  if ! git commit; then
    echo "Commit aborted. Squash is staged but not committed." >&2
    echo "To finish: rerun 'git commit'" >&2
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
    echo "Merged and cleaned up $branch"
  fi
}

# ------------------------------------------------------------
# Main
# ------------------------------------------------------------
[[ $# -lt 1 ]] && usage

command="$1"
shift

case "$command" in
  init)    cmd_init "$@" ;;
  enhance) cmd_enhance "$@" ;;
  review)  cmd_review "$@" ;;
  fix)     cmd_fix "$@" ;;
  commit)  cmd_commit "$@" ;;
  merge)   cmd_merge "$@" ;;
  -h|--help) usage 0 ;;
  *)       die "Unknown command: $command. Run 'agl --help' for usage." ;;
esac
