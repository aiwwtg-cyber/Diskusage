# Project Workflow

## Session Start

At the start of every session, before any new work:

1. Read `docs/progress.md` to recover the current project state.
2. If the user's request maps to an entry in `docs/progress.md`, confirm where the previous session ended before proposing next steps.
3. If `docs/progress.md` does not exist yet, ask the user whether to create it before starting structured work.

## Task Management

For any non-trivial task (3+ steps, architectural decisions, or anything touching multiple files):

1. **Plan first.** Propose a written plan and wait for the user's confirmation before any code change. The plan must include: Goal, Steps, Files-to-Touch, Assumptions, Verification Criteria.
2. **Save the plan.** After the user approves, save the plan to `docs/plans/YYYY-MM-DD-<task-slug>.md` before starting implementation. Confirm the file was created.
3. **Execute against the plan.** If execution diverges from the approved plan, stop and re-plan rather than improvising.
4. **Verify before done.** Run the implementation against real data and report pass/fail counts (or equivalent concrete numbers). Never mark a task complete without verification numbers.
5. **Document the outcome.** Append an `## Execution Outcome` section to the same plan file: what was actually done, where it differed from the plan, verification numbers, known limitations.
6. **Update the progress log.** Add a new entry to `docs/progress.md` in this exact four-line format:
   - **What was done:** <one sentence>
   - **Artifacts:** <files / functions / data created or modified>
   - **Verification:** <concrete numbers — counts, pass/fail, processed cases>
   - **Known limitations:** <what is not yet handled>
7. **Commit.** Ask the user to confirm a git commit at the end of each task unit, with a clear message naming the unit.

## Subagent Use

Delegate to a subagent (rather than doing the work in the main context) when any of these apply:

- **Exploration with summary output.** Reading multiple files where the result you need is a one-paragraph summary, not the file contents themselves. Example: "investigate how existing sanity check rules are structured."
- **Side investigations.** Questions that arise mid-task and would pull the main context away from the primary work. Example: "find the exact field name for interest expense in the data schema."
- **Independent verification.** Cross-checking `docs/progress.md` against actual code, or running a clean-eyed audit. The subagent reports findings; the main context decides what to do.

Do **not** delegate creative decisions, multi-step implementation, or anything where the detail of the code matters more than its summary.

## Verification Discipline

- **Per task:** Pass/fail counts or equivalent concrete numbers, recorded in the plan file and `docs/progress.md`.
- **Periodic (roughly weekly):** Use a subagent to inspect the codebase directly without reading `docs/progress.md`, then compare its findings against `docs/progress.md`. Report any discrepancies.
- **Cumulative:** When the project produces measurable output (rule pass rates, processed records, etc.), generate a dated report in `docs/reports/YYYY-MM-DD.md` so changes over time are visible.

## Working Style

- **Simplicity first.** Make every change as simple as possible. Touch minimal code. Prefer deleting lines over adding them when the result is equivalent.
- **No band-aids.** Find root causes. No temporary fixes. Hold to senior-developer standards.
- **Minimal impact.** Only touch what is necessary. Do not introduce unrelated changes alongside a fix.
- **Demand elegance for non-trivial changes.** Pause and ask "is there a more elegant way?" before presenting work. Skip this for simple, obvious fixes — do not over-engineer.
- **Autonomous bug fixing.** Given a bug report with logs or failing tests, just fix it. Do not ask the user to walk you through context they have already provided.

## How to Update This File

- Add a rule only after observing a real, repeated failure that the rule would prevent.
- Every rule must be checkable: a reader (human or AI) should be able to tell whether the rule was followed.
- Remove rules that are not actually being followed in practice — a dormant rule erodes trust in the rest of the file.
