# AI Development Guide

This document provides a technical overview of the **agent-loop** project, designed specifically for AI agents working on development tasks.

## Project Overview

`agl` is a pure Bash CLI scaffolding tool for multi-agent development workflows. It generates timestamped prompt files from Markdown templates — it does **not** run agents itself. The companion tool `agw` (external, at `~/bin/agw`) executes the generated prompts.

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

- **`agl` (this repo)** — Generates prompts, creates loop directories, tracks metadata. Never invokes an agent.
- **`agw` (external)** — Runs agents (Claude, Codex) with model selection, streaming, read-only mode. `agl` prints the `agw` command for the user to run.

### Entry point: `bin/agl.sh`

All logic lives in a single script. Key commands map to functions:

| Command | Function | Purpose |
|---------|----------|---------|
| `agl init` | `cmd_init` | Creates loop dir (+ worktree/branch), snapshots plan/context, generates worker prompt |
| `agl enhance` | `cmd_enhance` | Generates enhancer prompt for surgical improvements |
| `agl review` | `cmd_review` | Generates reviewer prompt (read-only mode via `-r` flag), handles round numbering |
| `agl fix` | `cmd_fix` | Finds latest review output, generates fixer prompt, increments ROUND |
| `agl track` | `cmd_track` | Records commit hashes in `.agl` metadata with amend detection |

Helper functions: `find_loop_dir`, `read_meta`/`read_meta_optional`, `sed_escape`/`sed_inplace` (portable BSD/GNU), `slug_to_name`, `print_commands`.

### Templates (`templates/`)

Four Markdown templates with `{{PLACEHOLDER}}` syntax filled by `sed`:

| File | Agent Role | Mode |
|------|-----------|------|
| `01-worker.md` | Implementation | Read-Write |
| `02-enhancer.md` | Surgical improvements | Read-Write |
| `03-reviewer.md` | Code review | Read-Only |
| `04-fixer.md` | Apply review findings | Read-Write |

### Per-loop directory structure

Each `agl init` creates a timestamped directory under `work/agent-loop/`:
```
work/agent-loop/<timestamp>-<slug>/
├── .agl              # key=value metadata (FEATURE_SLUG, PLAN_PATH, DATE, ROUND, COMMITS)
├── context/          # snapshots of --plan and --context files
├── prompts/          # generated prompt files (01-worker.md, 03-reviewer-r2.md, etc.)
└── output/           # agent output (HANDOFF-*.md, REVIEW-*.md, etc.)
```

### Deployment

- `deploy.sh` — Bootstrap from checkout. Copies `bin/*.sh` to `~/bin/` (strips `.sh` extension), copies templates to `~/.config/solt/agent-loop/templates/`.
- `bin/agl-deploy.sh` — Self-updater. Reads config from `~/.config/solt/agent-loop/deploy.toml`, shallow-clones repo, deploys, scrubs PAT from remote URL immediately.

## Coding Conventions

- All scripts use `set -euo pipefail`
- Portable sed handling (BSD/GNU) via `sed_inplace` helper
- `.agl` metadata files use simple `KEY=value` format, one per line
- Template placeholders use `{{DOUBLE_BRACE}}` syntax
- Commit messages: imperative mood, max 50 char subject, no conventional-commit prefixes (see `/commit-message` slash command)
