# Agent Loop

Scaffolding tool and templates for multi-agent development workflows. `agl` generates loop directories and fills template placeholders; `agw` executes agents. Language-agnostic and platform-agnostic (works with Claude, Codex, Gemini, etc.).

---

## Quick Start

```bash
# Bootstrap (from repo checkout)
./deploy.sh

# Ensure work/agent-loop/ is in .gitignore
echo "work/agent-loop/" >> .gitignore

# Start a loop (creates worktree + branch)
cd ~/your-project
agl init add-auth --plan work/wip/task-1.md

# Run the printed commands from repo root
(cd "work/agent-loop/worktrees/add-auth" && agw claude "work/agent-loop/.../prompts/01-worker.md")
agl commit

# Enhance
agl enhance
(cd "work/agent-loop/worktrees/add-auth" && agw claude "work/agent-loop/.../prompts/02-enhancer.md")
agl commit

# Review (read-only)
agl review --files "src/auth.rs, src/middleware.rs"
(cd "work/agent-loop/worktrees/add-auth" && agw claude -r "work/agent-loop/.../prompts/03-reviewer.md")

# Fix
agl fix
(cd "work/agent-loop/worktrees/add-auth" && agw claude "work/agent-loop/.../prompts/04-fixer.md")
agl commit

# Squash-merge into the current branch
agl merge add-auth
```

`agl` generates prompts and prints the commands. `agw` runs the agent. They are separate tools with separate concerns. All agent work happens in an isolated git worktree — the only manual step is the final squash-merge commit message.

---

## `agl` CLI

### Commands

```
agl init <feature-slug> --plan <path>   Create worktree, branch, and worker prompt
agl enhance                             Generate enhancer prompt
agl review                              Generate reviewer prompt
agl fix                                 Generate fixer prompt
agl commit                              Stage and commit changes in the worktree
agl merge [<slug>]                      Squash-merge worktree branch into the current branch
```

### Init Options

| Option | Description |
|--------|-------------|
| `--plan <path>` | Path to the plan file (required) |
| `--task <text>` | Task description (default: Implement the feature according to the plan.) |
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

### Commit Options

| Option | Description |
|--------|-------------|
| `--dir <path>` | Loop directory (default: most recent) |

### Merge Options

| Option | Description |
|--------|-------------|
| `[<slug>]` | Feature slug to merge (default: most recent worktree loop) |
| `--dir <path>` | Loop directory (default: most recent) |
| `--no-delete` | Preserve worktree and branch after merge |

### Worktree Workflow

`agl init` creates a git worktree at `work/agent-loop/worktrees/<slug>/` on a dedicated branch `agl/<slug>`. All agent work happens in this isolated checkout. The lifecycle is:

1. **`agl init <slug>`** — creates branch, worktree, loop directory, and worker prompt
2. **Run agents** — `agl enhance`, `agl review`, `agl fix` generate prompts; run the printed `(cd ... && agw ...)` commands from the repo root
3. **`agl commit`** — stages all changes and commits with a mechanical message (e.g. `agl: add-auth worker`)
4. **`agl merge`** — squash-merges the worktree branch into the current branch, opens the editor for a user-authored commit message, then removes the worktree and branch

This keeps agent changes isolated from unrelated work, makes intermediate commits mechanical, and produces a single squash commit with a meaningful message at the end.

### Round Numbering

The review-fix loop tracks rounds automatically. Round 1 files are named normally. Round 2+ get `-r2`, `-r3` suffixes:

```
prompts/03-reviewer.md      # round 1
prompts/04-fixer.md         # round 1
prompts/03-reviewer-r2.md   # round 2
prompts/04-fixer-r2.md      # round 2
```

The round counter increments each time `agl fix` is called.

### Context Snapshotting

`agl init` copies the plan file and any `--context` files into a `context/` directory inside the loop. All prompts reference these local copies, making loop directories self-contained records of the work.

```bash
agl init add-auth --plan work/wip/task-1.md --context "docs/spec.md, docs/design.md"
```

This creates:
```
context/
├── plan.md       # copy of work/wip/task-1.md
├── spec.md       # copy of docs/spec.md
└── design.md     # copy of docs/design.md
```

If two `--context` files share the same basename, the second gets a `-2` suffix (e.g. `spec.md` and `spec-2.md`).

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
| `{{PLAN_PATH}}` | Yes | Local copy in `context/` (snapshotted from `--plan`) |
| `{{OUTPUT_DIR}}` | Yes | Loop's `output/` directory |
| `{{HANDOFF_PATH}}` | Yes | Computed from output dir |
| `{{HANDOFF_PATHS}}` | Yes | Computed from what exists in output dir |
| `{{REVIEW_PATH}}` | Yes | Latest review file in output dir |
| `{{TASK_DESCRIPTION}}` | Yes | Default from plan path, or `--task` flag |
| `{{OTHER_CONTEXT}}` | Flag | `--context` (init snapshots to `context/`), default "None" |
| `{{COMMIT_HASHES}}` | Auto/Flag | Tracked commits from `.agl`, or `--commits` override |
| `{{FILE_PATHS}}` | Flag | `--files`, default "None" |
| `{{REVIEW_CHECKLIST}}` | Flag | `--checklist`, default "None" |
| `{{ADDITIONAL_INSTRUCTIONS}}` | Flag | `--instructions`, default "None" |

---

## Output Locations

Each loop creates a timestamped directory inside the worktree under `work/agent-loop/`:

```
work/agent-loop/
├── worktrees/
│   └── add-auth/                          # git worktree (isolated checkout)
│       └── work/agent-loop/
│           └── 2026-02-17-142533-add-auth/
│               ├── .agl                   # metadata (slug, plan, date, round, branch, worktree, etc.)
│               ├── context/
│               │   ├── plan.md            # snapshot of --plan file
│               │   └── design.md          # snapshot of --context files
│               ├── prompts/
│               │   ├── 01-worker.md
│               │   ├── 02-enhancer.md
│               │   ├── 03-reviewer.md
│               │   ├── 04-fixer.md
│               │   ├── 03-reviewer-r2.md  # round 2
│               │   └── 04-fixer-r2.md     # round 2
│               └── output/
│                   ├── HANDOFF-add-auth.md
│                   ├── ENHANCE-add-auth.md
│                   ├── REVIEW-add-auth.md
│                   ├── FIX-add-auth.md
│                   ├── REVIEW-r2-add-auth.md
│                   └── FIX-r2-add-auth.md
```

The `work/agent-loop/` directory must be in `.gitignore`.

### `.agl` Metadata

Each loop directory contains a `.agl` file with `KEY=value` metadata:

```
FEATURE_SLUG=add-auth
PLAN_PATH=work/agent-loop/.../context/plan.md
DATE=2026-02-17
ROUND=1
BRANCH=agl/add-auth
WORKTREE=work/agent-loop/worktrees/add-auth
MAIN_ROOT=/abs/path/to/project
LAST_STAGE=worker
COMMITS=a1b2c3,d4e5f6
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
