# Agent Loop

Scaffolding tool and templates for multi-agent development workflows. `agl` generates loop directories and fills template placeholders; `agw` executes agents. Language-agnostic and platform-agnostic (works with Claude, Codex, Gemini, etc.).

---

## Quick Start

```bash
# Bootstrap (from repo checkout)
./deploy.sh

# Start a loop
cd ~/your-project
agl init add-auth --plan work/wip/task-1.md
agw claude work/agent-loop/2026-02-17-142533-add-auth/prompts/01-worker.md

# Enhance
agl enhance
agw claude work/agent-loop/2026-02-17-142533-add-auth/prompts/02-enhancer.md

# Review (read-only)
agl review --files "src/auth.rs, src/middleware.rs"
agw claude -r work/agent-loop/2026-02-17-142533-add-auth/prompts/03-reviewer.md

# Fix
agl fix
agw claude work/agent-loop/2026-02-17-142533-add-auth/prompts/04-fixer.md

# Re-review (round 2)
agl review
agw claude -r work/agent-loop/2026-02-17-142533-add-auth/prompts/03-reviewer-r2.md
```

`agl` generates prompts and prints the commands. `agw` runs the agent. They are separate tools with separate concerns.

---

## `agl` CLI

### Commands

```
agl init <feature-slug> --plan <path>   Create loop dir, generate worker prompt
agl enhance                             Generate enhancer prompt
agl review                              Generate reviewer prompt
agl fix                                 Generate fixer prompt
```

### Init Options

| Option | Description |
|--------|-------------|
| `--plan <path>` | Path to the plan file (required) |
| `--task <text>` | Task description (default: derived from plan) |
| `--context <paths>` | Additional context paths (default: None) |

### Enhance Options

| Option | Description |
|--------|-------------|
| `--dir <path>` | Loop directory (default: most recent) |
| `--context <paths>` | Additional context paths |
| `--commits <hashes>` | Relevant commit hashes |
| `--instructions <text>` | Additional instructions |

### Review Options

| Option | Description |
|--------|-------------|
| `--dir <path>` | Loop directory (default: most recent) |
| `--files <paths>` | File paths to review |
| `--context <paths>` | Additional context paths |
| `--commits <hashes>` | Relevant commit hashes |
| `--checklist <text>` | Review checklist |

### Fix Options

| Option | Description |
|--------|-------------|
| `--dir <path>` | Loop directory (default: most recent) |
| `--context <paths>` | Additional context paths |

### Round Numbering

The review-fix loop tracks rounds automatically. Round 1 files are named normally. Round 2+ get `-r2`, `-r3` suffixes:

```
prompts/03-reviewer.md      # round 1
prompts/04-fixer.md         # round 1
prompts/03-reviewer-r2.md   # round 2
prompts/04-fixer-r2.md      # round 2
```

The round counter increments each time `agl fix` is called.

---

## Workflow Patterns

### Pattern A: Worker -> Reviewer -> Fixer Loop

```
Worker ──────> Reviewer ──────> Fixer
  └─ self-review    │ ^          └─ self-review
                    │ └──────────┘
                    │
                  Approved
```

1. Worker implements according to plan (spawns self-review sub-agent)
2. Reviewer (interactive) analyzes and writes findings to disk
3. If changes required: Fixer addresses findings (spawns self-review sub-agent)
4. Back to Reviewer for re-review
5. Repeat until approved

### Pattern B: Worker -> Enhancer -> Reviewer -> Fixer Loop

```
Worker ──> Enhancer ──> Reviewer ──> Fixer
  └─ self     └─ self        │ ^      └─ self-review
   review      review        │ └──────┘
                             │
                           Approved
```

1. Worker implements according to plan (spawns self-review sub-agent)
2. Enhancer makes surgical improvements (spawns self-review sub-agent)
3. Reviewer (interactive) analyzes and writes findings to disk
4. If changes required: Fixer addresses findings (spawns self-review sub-agent)
5. Back to Reviewer for re-review
6. Repeat until approved

---

## Template Placeholders

All templates use `{{PLACEHOLDER}}` syntax. `agl` fills these automatically:

| Placeholder | Auto-filled | Source |
|-------------|-------------|--------|
| `{{DATE}}` | Yes | `date +%Y-%m-%d` |
| `{{FEATURE_SLUG}}` | Yes | User provides as arg to `init` |
| `{{FEATURE_NAME}}` | Yes | Derived from slug |
| `{{PLAN_PATH}}` | Yes | From `--plan` flag or `.agl` metadata |
| `{{OUTPUT_DIR}}` | Yes | Loop's `output/` directory |
| `{{HANDOFF_PATH}}` | Yes | Computed from output dir |
| `{{HANDOFF_PATHS}}` | Yes | Computed from what exists in output dir |
| `{{REVIEW_PATH}}` | Yes | Latest review file in output dir |
| `{{TASK_DESCRIPTION}}` | Yes | Default from plan path, or `--task` flag |
| `{{OTHER_CONTEXT}}` | Flag | `--context`, default "None" |
| `{{COMMIT_HASHES}}` | Flag | `--commits`, default "None" |
| `{{FILE_PATHS}}` | Flag | `--files`, default "None" |
| `{{REVIEW_CHECKLIST}}` | Flag | `--checklist`, default "None" |
| `{{ADDITIONAL_INSTRUCTIONS}}` | Flag | `--instructions`, default "None" |

---

## Output Locations

Each loop creates a timestamped directory under `work/agent-loop/`:

```
work/agent-loop/
└── 2026-02-17-142533-add-auth/
    ├── .agl                     # metadata (slug, plan, date, round)
    ├── prompts/
    │   ├── 01-worker.md
    │   ├── 02-enhancer.md
    │   ├── 03-reviewer.md
    │   ├── 04-fixer.md
    │   ├── 03-reviewer-r2.md   # round 2
    │   └── 04-fixer-r2.md      # round 2
    └── output/
        ├── HANDOFF-add-auth.md
        ├── ENHANCE-add-auth.md
        ├── REVIEW-add-auth.md
        ├── FIX-add-auth.md
        ├── REVIEW-r2-add-auth.md
        └── FIX-r2-add-auth.md
```

---

## Role Discipline

The templates enforce strict role boundaries:

| Role | Mode | Edits Files | Primary Output |
|------|------|-------------|----------------|
| Worker | Read-Write | Yes | Code + Handoff Report |
| Enhancer | Read-Write (surgical) | Yes, minimally | Code Changes + Change Summary |
| Reviewer | **Read-Only** | **No (except findings report)** | Findings Report |
| Fixer | Read-Write (scoped) | Yes, scoped to findings | Code Changes + Fix Report |

### Why Strict Boundaries?

1. **Reviewers fixing code** breaks the feedback loop - issues get silently "fixed" without the worker learning
2. **Enhancers rewriting code** undoes carefully considered implementations
3. **Workers deviating from plans** creates drift between intent and implementation

---

## Deployment

### Initial Setup

```bash
git clone <repo-url> ~/dev/bash/agent-loop
cd ~/dev/bash/agent-loop
./deploy.sh
```

This deploys:
- `bin/agl.sh` -> `~/bin/agl`
- `bin/agl-deploy.sh` -> `~/bin/agl-deploy`
- `templates/*.md` -> `~/.config/solt/agent-loop/templates/`
- Creates `~/.config/solt/agent-loop/deploy.toml` if it doesn't exist

### Updates

After setting your PAT in `~/.config/solt/agent-loop/deploy.toml`:

```bash
agl-deploy
```

This clones the latest from GitHub and redeploys everything.

---

## Tips

1. **Front-load constraints** - Put role rules before context so the agent internalizes boundaries before loading content

2. **Be explicit about READ-ONLY** - The reviewer template repeats this multiple times because agents naturally want to help by fixing

3. **Use the same feature slug** - Keeps handoffs organized and traceable

4. **Include file paths in reviewer prompt** - Helps scope the review and prevents the agent from wandering

5. **"No changes required" is valid** - Tell enhancers this explicitly so they don't hunt for problems that don't exist

6. **Independent self-review catches blind spots** - Workers, enhancers and fixers spawn a sub-agent with fresh context to review their own work before handing off. The sub-agent works against the same spec, not the parent agent's interpretation, so it can catch assumptions the original agent baked in
