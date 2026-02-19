# Repository Guidelines

**Agent Loop** is a CLI tool for multi-agent development workflows. It generates timestamped prompt directories, fills Markdown templates with context, and either prints or executes `agw` commands. Built entirely in Bash with no external dependencies beyond standard POSIX utilities and git. The project targets Linux (Bash) and macOS (Zsh) — all scripts must work correctly on both platforms.

## Architecture

The project has two concerns separated across two tools:

**`agl` (this repo)** scaffolds and runs agent loops. All logic lives in a single script `bin/agl.sh` organized as a set of command functions (`cmd_init`, `cmd_enhance`, `cmd_review`, `cmd_fix`, `cmd_work`, `cmd_commit`, `cmd_merge`) dispatched from a `case` block at the bottom. Each command function creates or locates a timestamped loop directory under `work/agent-loop/`, fills `{{PLACEHOLDER}}` values in Markdown templates using `sed`, writes the result to the loop's `prompts/` directory, and either prints the ready-to-run command or invokes `agw` directly via `exec`.

**`agw` (external, not in this repo)** runs agents with model selection, streaming output, and read-only mode enforcement. `agl` can invoke `agw` as a pass-through (`agl work`, `agl enhance claude`, etc.) or print the command for manual execution.

Templates in `templates/` define four agent roles (worker, enhancer, reviewer, fixer) as Markdown files with `{{DOUBLE_BRACE}}` placeholders. Each template is self-contained with role constraints, context loading instructions, task description, output format, and a completion checklist.

Deployment is handled by `deploy.sh` for initial bootstrap from a local checkout and `bin/agl-deploy.sh` for self-updating from GitHub. Both copy scripts to `~/bin/` and templates to `~/.config/solt/agent-loop/templates/`.

## Coding Conventions

- Start every script with `set -euo pipefail` immediately after the shebang
- Double-quote all variable expansions — unquoted `$var` is always a bug
- Declare function-local variables with `local` to avoid polluting the global scope
- Use `[[ ]]` for conditionals and `$()` for command substitution, never `[ ]` or backticks
- Use `die()` for error exits and `require_arg()` for flag validation — do not write ad-hoc error handling
- Never use `sed -i` directly — use the `sed_inplace` helper for portable BSD/GNU behavior
- Escape replacement strings through `sed_escape` before passing them to `sed` substitutions
- Parse command-line arguments with the `while [[ $# -gt 0 ]]; case/shift` pattern established in the codebase
- Use heredocs for multi-line output like usage text
- Organize scripts into sections separated by `# ----` comment blocks: header, usage, helpers, command functions, dispatch
- Name functions in `snake_case` and prefix command entry points with `cmd_`
- Metadata in `.agl` files uses `KEY=value` format, one pair per line, read by `read_meta` and `read_meta_optional`

## Coding Rules

1. **Stay focused on the specific issue being discussed.** Do not provide feedback on unrelated code, features, or theoretical concerns that aren't directly relevant to the issue at hand.

2. **Avoid perfectionism and bikeshedding on theoretical issues.** Recognize when the current implementation is good enough for its intended purpose rather than pursuing theoretical perfection.

3. **When editing code, make surgical changes directly related to the feature or issue.** Do not rewrite blocks of code for stylistic reasons. Only adjust code when there is a concrete functional gap to close — no stylistic or "nice to have" refactors.

4. **Do not jump straight into writing code when starting a new task.** First analyze the project, read the relevant source code, understand the requirements thoroughly, and discuss the scope of work before beginning implementation. Only start coding immediately when given a straightforward, obvious command to execute specific work.

5. **Actually read source files using available tools before providing any analysis or starting work.** Do not rely on memory, assumptions, or patterns you think might exist without examining the actual implementation.

6. **Prefer stable, robust, and idiomatic patterns over clever solutions.** Choose boring but reliable approaches that are easy to understand and maintain, even if they require a bit more code. In Bash this means favoring explicit conditionals over dense one-liners, readable pipelines over nested substitutions, and well-known idioms over obscure shell features.

7. **Prioritize readability and maintainability as primary concerns.** Write code that future developers can easily understand and modify, even if it means being more verbose.

8. **Use meaningful, human-readable names throughout your code.** Avoid single-letter variables and cryptic abbreviations in favor of names that clearly express purpose and intent. Short names like `f`, `d`, `i` are acceptable only in tight loops where scope is a few lines.

9. **Keep commenting minimal and purposeful.** Do not add extensive inline comments unless explicitly requested. When adding comments, use short, meaningful statements that explain non-obvious implementation details or shell idioms that might trip up a reader.

10. **Communicate clearly in prose using plain language.** Write in complete sentences using terms that any developer can understand, avoiding jargon and preferring natural sentences and paragraphs over bullet points or tables.

11. **Always run `shellcheck` and `bash -n` on modified scripts before considering any work complete.** Catch common pitfalls — unquoted variables, word splitting, incorrect conditionals — as part of your standard workflow to ensure code quality.

## Additional Guidelines

For code review guidelines, see [docs/REVIEW.md](docs/REVIEW.md).
