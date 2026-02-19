# AI Development Guide

This document provides a technical overview of the **agent-loop** project, designed specifically for AI agents working on development tasks.

## Project Overview

`agl` is a pure Bash CLI tool for multi-agent development workflows. It generates timestamped prompt files from Markdown templates and can invoke `agw` directly as a pass-through. The companion tool `agw` (external, at `~/bin/agw`) handles actual agent execution with model selection, streaming, and read-only mode.

## Development

There is no build step, package manager, test framework, or linter. The project is standalone Bash scripts and Markdown templates.

**Deploy locally** (copies scripts to `~/bin/` and templates to `~/.config/solt/agent-loop/templates/`):
```bash
bash deploy.sh
```

**Self-update from GitHub** (after initial deploy):
```bash
agl-deploy
```

## Architecture

### Two-tool separation

- **`agl` (this repo)** — Scaffolds and runs agent loops. Creates loop directories, generates prompts, tracks metadata. Can invoke `agw` directly (`agl work`, `agl enhance claude`, etc.) or print the command for manual execution.
- **`agw` (external)** — Runs agents (Claude, Codex) with model selection, streaming, read-only mode.

### Entry point: `bin/agl.sh`

All logic lives in a single script. Key commands map to functions:

| Command | Function | Purpose |
|---------|----------|---------|
| `agl init` | `cmd_init` | Creates loop dir (+ worktree/branch), snapshots plan/context, generates worker prompt |
| `agl work <agent>` | `cmd_work` | Runs agent with the most recent prompt in the worktree |
| `agl commit` | `cmd_commit` | Stages and commits all changes in the worktree |
| `agl enhance [<agent>]` | `cmd_enhance` | Generates enhancer prompt; optionally runs agent |
| `agl review [<agent>]` | `cmd_review` | Generates reviewer prompt (auto-injects `-r`); optionally runs agent |
| `agl fix [<agent>]` | `cmd_fix` | Finds latest review output, generates fixer prompt, increments ROUND; optionally runs agent |
| `agl merge [<slug>]` | `cmd_merge` | Squash-merges branch and opens manual commit editor |
| `agl merge [<slug>] --agent <agent> [...]` | `cmd_merge` | Squash-merges branch, drafts commit message via agent, opens `git commit -e -F`, cleans up |

Helper functions: `find_loop_dir`, `read_meta`/`read_meta_optional`, `sed_escape`/`sed_inplace` (portable BSD/GNU), `slug_to_name`, `print_commands`, `run_agent`.

### Templates (`templates/`)

Five Markdown templates with `{{PLACEHOLDER}}` syntax filled by `sed`:

| File | Agent Role | Mode |
|------|-----------|------|
| `01-worker.md` | Implementation | Read-Write |
| `02-enhancer.md` | Surgical improvements | Read-Write |
| `03-reviewer.md` | Code review | Read-Only |
| `04-fixer.md` | Apply review findings | Read-Write |
| `05-commit-writer.md` | Draft squash commit message | Read-Write (scoped) |

#### Template-writing tips

1. **Front-load constraints** - Put role rules before context so the agent internalizes boundaries before loading content

2. **Be explicit about READ-ONLY** - The reviewer template repeats this multiple times because agents naturally want to help by fixing

3. **Use the same feature slug** - Keeps handoffs organized and traceable

4. **Include file paths in reviewer prompt** - Helps scope the review and prevents the agent from wandering

5. **"No changes required" is valid** - Tell enhancers this explicitly so they don't hunt for problems that don't exist

6. **Independent self-review catches blind spots** - Workers, enhancers and fixers spawn a sub-agent with fresh context to review their own work before handing off. The sub-agent works against the same spec, not the parent agent's interpretation, so it can catch assumptions the original agent baked in

### Per-loop directory structure

Each `agl init` creates a timestamped directory in the primary tree under `work/agent-loop/`:
```
work/agent-loop/<timestamp>-<slug>/
├── .agl              # key=value metadata (FEATURE_SLUG, PLAN_PATH, DATE, ROUND, BRANCH, WORKTREE, MAIN_ROOT, COMMITS)
├── context/          # snapshots of --plan and --context files
├── prompts/          # generated prompt files (01-worker.md, 03-reviewer-r2.md, etc.)
├── output/           # agent output (HANDOFF-*.md, REVIEW-*.md, etc.)
└── worktree/         # git worktree (isolated checkout on agl/<slug> branch)
```

### Deployment

- `deploy.sh` — Bootstrap from checkout. Copies `bin/*.sh` to `~/bin/` (strips `.sh` extension), copies templates to `~/.config/solt/agent-loop/templates/`.
- `bin/agl-deploy.sh` — Self-updater. Reads config from `~/.config/solt/agent-loop/deploy.toml`, shallow-clones repo, deploys, scrubs PAT from remote URL immediately.

## Coding Conventions

- All scripts use `set -euo pipefail`
- Portable sed handling (BSD/GNU) via `sed_inplace` helper
- `.agl` metadata files use simple `KEY=value` format, one per line
- Template placeholders use `{{DOUBLE_BRACE}}` syntax
- Commit messages: imperative mood, max 50 char subject, conventional commit format in the merge draft template
