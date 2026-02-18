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
  init <feature-slug>   Create a new agent loop
  enhance               Generate enhancer prompt
  review                Generate reviewer prompt
  fix                   Generate fixer prompt
  track [hash]          Record a commit hash (default: HEAD)

Init options:
  --plan <path>         Path to the plan file (required)
  --task <description>  Task description (default: derived from plan)
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

Examples:
  agl init add-auth --plan work/wip/task-1.md
  agl enhance
  agl review --files "src/auth.rs, src/middleware.rs"
  agl fix
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

# Find the most recent loop directory with a .agl file
find_loop_dir() {
  local root
  root="$(project_root)"
  local loop_base="$root/work/agent-loop"

  if [[ ! -d "$loop_base" ]]; then
    die "No agent-loop directory found at $loop_base"
  fi

  local latest
  latest="$(ls -1d "$loop_base"/*/ 2>/dev/null | sort -r | while read -r d; do
    if [[ -f "$d/.agl" ]]; then
      echo "$d"
      break
    fi
  done)"

  if [[ -z "$latest" ]]; then
    die "No loop directory with .agl metadata found in $loop_base"
  fi

  # Strip trailing slash
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

# Print the prompt path and ready-to-run agw commands
print_commands() {
  local prompt_path="$1"
  local readonly_flag="${2:-}"
  local root
  root="$(project_root)"
  local rel_path="${prompt_path#$root/}"

  echo ""
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
  [[ -f "$plan_path" ]] || die "Plan file not found: $plan_path"

  local root date timestamp loop_dir prompts_dir output_dir context_dir
  root="$(project_root)"
  date="$(date +%Y-%m-%d)"
  timestamp="$(date +%Y-%m-%d-%H%M%S)"
  loop_dir="$root/work/agent-loop/${timestamp}-${slug}"
  prompts_dir="$loop_dir/prompts"
  output_dir="$loop_dir/output"
  context_dir="$loop_dir/context"

  # Relative paths (from project root)
  local rel_output_dir="${output_dir#$root/}"
  local rel_context_dir="${context_dir#$root/}"

  mkdir -p "$prompts_dir" "$output_dir" "$context_dir"

  # Snapshot plan into context/
  local plan_base
  plan_base="$(basename "$plan_path")"
  local plan_dest
  if [[ "$plan_base" == *.* ]]; then
    plan_dest="plan.${plan_base##*.}"
  else
    plan_dest="plan"
  fi
  cp "$plan_path" "$context_dir/$plan_dest"
  local rel_plan_path="$rel_context_dir/$plan_dest"

  # Snapshot --context files into context/
  local rel_context_paths="None"
  if [[ "$other_context" != "None" ]]; then
    rel_context_paths=""
    local IFS=','
    for ctx_path in $other_context; do
      # Trim whitespace
      ctx_path="$(printf '%s' "$ctx_path" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
      if [[ -f "$ctx_path" ]]; then
        local ctx_base ctx_dest
        ctx_base="$(basename "$ctx_path")"
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
        cp "$ctx_path" "$context_dir/$ctx_dest"
        if [[ -n "$rel_context_paths" ]]; then
          rel_context_paths="$rel_context_paths, $rel_context_dir/$ctx_dest"
        else
          rel_context_paths="$rel_context_dir/$ctx_dest"
        fi
      else
        die "Context file not found: $ctx_path"
      fi
    done
  fi

  # Write .agl metadata (paths are relative to project root)
  cat > "$loop_dir/.agl" <<EOF
FEATURE_SLUG=$slug
PLAN_PATH=$rel_plan_path
DATE=$date
ROUND=1
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

  echo "Created loop: ${loop_dir#$root/}"
  print_commands "$prompt"
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

  local root slug plan_path date
  root="$(project_root)"
  slug="$(read_meta "$agl_file" FEATURE_SLUG)"
  plan_path="$(read_meta "$agl_file" PLAN_PATH)"
  date="$(read_meta "$agl_file" DATE)"

  # Use tracked commits if --commits not provided
  if [[ "$commit_hashes" == "None" ]]; then
    local tracked
    tracked="$(read_meta_optional "$agl_file" COMMITS)"
    [[ -n "$tracked" ]] && commit_hashes="$tracked"
  fi

  local rel_output_dir="${loop_dir#$root/}/output"
  local handoff_path="$rel_output_dir/HANDOFF-${slug}.md"
  local feature_name
  feature_name="$(slug_to_name "$slug")"

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

  print_commands "$prompt"
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

  local root slug plan_path date round
  root="$(project_root)"
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

  local rel_output_dir="${loop_dir#$root/}/output"
  local feature_name
  feature_name="$(slug_to_name "$slug")"

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

  # Use the round-aware output path in the template
  local review_output_path="$rel_output_dir/$review_output"

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

  print_commands "$prompt" "-r"
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

  local root slug plan_path date round
  root="$(project_root)"
  slug="$(read_meta "$agl_file" FEATURE_SLUG)"
  plan_path="$(read_meta "$agl_file" PLAN_PATH)"
  date="$(read_meta "$agl_file" DATE)"
  round="$(read_meta "$agl_file" ROUND)"

  local rel_output_dir="${loop_dir#$root/}/output"
  local feature_name
  feature_name="$(slug_to_name "$slug")"

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

  local fix_output_path="$rel_output_dir/$fix_output"

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

  print_commands "$prompt"
}

cmd_track() {
  local loop_dir="" hash=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dir) require_arg "$1" "$#" "${2-}"; loop_dir="$2"; shift 2 ;;
      -*)    die "Unknown option: $1" ;;
      *)
        [[ -z "$hash" ]] || die "Unexpected argument: $1"
        hash="$1"; shift ;;
    esac
  done

  if [[ -z "$loop_dir" ]]; then
    loop_dir="$(find_loop_dir)"
  fi

  local agl_file="$loop_dir/.agl"
  [[ -f "$agl_file" ]] || die "No .agl metadata found in $loop_dir"

  # Default to HEAD
  if [[ -z "$hash" ]]; then
    hash="$(git rev-parse --short HEAD 2>/dev/null)" || die "Not in a git repository"
  else
    # Validate and shorten the provided hash
    hash="$(git rev-parse --short "$hash" 2>/dev/null)" || die "Invalid commit hash: $hash"
  fi

  local existing
  existing="$(read_meta_optional "$agl_file" COMMITS)"

  if [[ -z "$existing" ]]; then
    # No commits tracked yet — add the line
    echo "COMMITS=$hash" >> "$agl_file"
    echo "Tracked: $hash"
  else
    # Check if the last tracked hash is still an ancestor of HEAD
    local last_hash="${existing##*,}"
    if git merge-base --is-ancestor "$last_hash" HEAD 2>/dev/null; then
      # Last hash still in history — append
      sed_inplace "s|^COMMITS=.*|COMMITS=${existing},${hash}|" "$agl_file"
      echo "Tracked: $hash (appended)"
    else
      # Last hash was amended/rebased — replace it
      local prefix="${existing%,*}"
      if [[ "$prefix" == "$existing" ]]; then
        # Only one hash was tracked, replace it entirely
        sed_inplace "s|^COMMITS=.*|COMMITS=${hash}|" "$agl_file"
      else
        sed_inplace "s|^COMMITS=.*|COMMITS=${prefix},${hash}|" "$agl_file"
      fi
      echo "Tracked: $hash (replaced $last_hash)"
    fi
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
  track)   cmd_track "$@" ;;
  -h|--help) usage 0 ;;
  *)       die "Unknown command: $command. Run 'agl --help' for usage." ;;
esac
