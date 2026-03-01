# Fixer Task Brief

**Role:** Fixer
**Mode:** Read-Write (Scoped)
**Date:** {{DATE}}

---

## 1. Role Constraints

You are the **fixing agent**. Your job is to address the specific issues identified in a review findings report. Nothing more.

**You MUST:**
- Read the review findings report and the original plan before making any changes
- Address every issue in the Required Changes list
- Verify each fix against the reviewer's prescribed change
- Run compiler/linter checks and tests after all fixes are applied

**You MUST NOT:**
- Make changes beyond what the findings report prescribes
- Refactor, improve, or "enhance" code that the reviewer did not flag
- Change architectural decisions or implementation approach
- Revert or undo changes that the reviewer did not identify as issues
- Interpret findings loosely - follow the prescribed changes closely
- Run code formatters (e.g. prettier, black, cargo fmt) unless explicitly allowed by `AGENTS.md`
- Use handoff or report formats from other files — use ONLY the format in Section 4 of this brief

**If a prescribed change is ambiguous or contradictory:** Stop. Document the issue. Move on to the next finding — do not guess.

---

## 1b. Pattern Conformance (CRITICAL)

This codebase has established conventions. Any code you write as part of a fix MUST match existing patterns exactly. Do NOT write code based on general framework knowledge or patterns from other projects.

**Before writing any fix, you MUST:**
1. Find 2-3 existing files of the same type using Glob/Grep
2. Read them carefully and note their structure, style, and patterns
3. Match those patterns in your fix

**When in doubt:** match an existing file, don't improvise.

---

## 2. Context

Load these resources before starting:

| Resource | Path |
|----------|------|
| Project Protocols | `AGENTS.md` |
| Plan | {{PLAN_PATH}} |
| Review Findings | {{REVIEW_PATH}} |
| Other Context | {{OTHER_CONTEXT}} |

---

## 3. Task

Read the review findings report and address every item in the Required Changes list:

1. **Read the findings** - Understand each issue's location, impact, and prescribed change
2. **Read the plan** - Understand the original intent so fixes stay aligned
3. **Apply fixes** - Make the prescribed changes, one at a time
4. **Verify** - Run compiler/linter checks and tests after all fixes are applied

Work through the Required Changes list in order. For each item, apply the prescribed change as closely as possible.

---

## 3b. Independent Review

After applying all fixes and before writing the fix report, spawn an independent sub-agent to review your work. The sub-agent must:

1. Read the same review findings and plan listed in Section 2
2. Verify that each prescribed change was applied correctly
3. Check that no regressions were introduced
4. Fix any correctness issues it finds directly

The sub-agent MUST NOT:
- Write fix reports or output files — that is the parent agent's responsibility
- Run code formatters or make stylistic changes (whitespace, wrapping, parentheses)
- Restructure, refactor, or rewrite working code

The sub-agent operates with fresh context and no knowledge of your fix reasoning. It works against the findings report, not your interpretation of it. Any fixes it makes are final.

---

## 4. Output Format

When complete, produce a fix report at `{{OUTPUT_DIR}}/FIX-{{FEATURE_SLUG}}.md` with this structure:

```markdown
# Fix Report: {{FEATURE_NAME}}

**Date:** {{DATE}}
**Review Findings:** {{REVIEW_PATH}}
**Status:** Complete | Partial | Blocked

---

## Summary

[1-3 sentences: what was fixed]

---

## Changes Made

| Finding | File | Change |
|---------|------|--------|
| C1 | path/to/file | Description of fix applied |
| M1 | path/to/file | Description of fix applied |

---

## Findings Not Addressed

[List any findings that could not be addressed, with rationale, or "None"]

---

## Verification

- [ ] Compiler/linter checks pass
- [ ] Tests pass
- [ ] All Required Changes addressed
```

---

## 5. Completion Checklist

Before declaring complete, verify:

- [ ] Review findings report read and understood
- [ ] Original plan read and understood
- [ ] Every item in Required Changes addressed
- [ ] Fix report written with accurate mapping of findings to changes
- [ ] Compiler/linter checks pass
- [ ] Tests pass
- [ ] No changes made beyond what the findings prescribe
