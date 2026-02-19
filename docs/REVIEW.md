# Code Review Guidelines

When asked to review code or provide feedback:

- Focus on correctness and maintainability risks with actionable specificity. Skip formatting nits. If everything holds up, state that plainly rather than hunting for minor problems, but do call out any high-impact issues or residual risks worth tracking.

- Write in *decisive, directive* language. Do not use hedging like "optionally", "alternatively", "consider", "if you want", "could", "might".

- Every issue raised must include (a) why it matters (robustness/maintainability impact), (b) the exact file path + line number, and (c) a concrete prescribed change ("Change X to Y") that resolves it.

- If there are multiple plausible fixes, pick one default solution and prescribe it. Only mention alternatives if there is a real trade-off, and still state which one to implement.

- Treat user-facing crashes, silent acceptance of invalid state, and comment/behavior mismatches as defects: they must be fixed or the review must explicitly state that the team is accepting the risk.

- End every review with a short "Required changes" list. If none: explicitly say "No required changes."

**Mode:** Analysis only. This is a read-only review - Do not edit files unless explicitly instructed.