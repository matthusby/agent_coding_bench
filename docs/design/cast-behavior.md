# Cast behavior — PM, Reviewer, Person

Decided in [#7](https://github.com/matthusby/agent_coding_bench/issues/7).
All three are plain chat completions on the local vLLM (the Coder, an
opencode session, is out of scope here). Serving-default sampling for every
role — no per-role sampling knobs.

## PM

- **Repo pick is mechanical**: each lane walks the World Repo slate in a
  shuffled order, reshuffling each cycle. Even coverage, no cross-lane
  coordination, no streaks — the rotation is not a judgment call (same
  philosophy as mechanical-only abandonment). The PM prompt receives the
  assigned repo.
- **Context digest**, assembled by the rig (the PM has no tool use):
  depth-capped file tree, README, recent commit log (merged tasks land
  there, so it doubles as "what's been done"), and the last 10 task titles
  for this lane + clone from task rows — which catches *abandoned* tasks
  the commit log misses, so the PM doesn't reinvent a poison task.
- **Size is mechanical**, like the repo pick: each lane deals from a weighted
  size slate (`small: 10, medium: 7, large: 3` by default), reshuffling each
  cycle. Weights are whole slots per cycle rather than independent samples,
  so a lane cannot draw six larges in a row and skew a short Run. The rig is
  a load generator, and the spread of task sizes is the load mix — a knob it
  sets, not a judgment the PM makes. The dealt size selects one of
  `priv/prompts/task-size-{small,medium,large}.md`, sets the per-task hard
  cap, and is stored on the task row so the realized mix can be checked
  against the configured one.
- **Task guidance**: self-contained work concrete enough to review as a
  diff, varied in kind (feature / refactor / bugfix / docs-adjacent).
- **Output contract**: structured `{title, description}`. Title goes into
  the task row and the repeat-avoidance list; description is handed
  verbatim to the Coder as the opening prompt of its opencode session, and
  to the Reviewer alongside the diff. Written as a real ticket: what and
  why plus an acceptance sketch — no step-by-step implementation plan.
- **Named fallback** (parked in the map's calibration fog, not built): if
  digest-blind invention produces degenerate tasks, move to a two-pass PM —
  first completion picks a handful of files to read, second invents with
  their contents. Still plain completions, no tool loop. Most relevant to
  the large bucket: the digest hides 60–80% of the file tree on the bigger
  repos and every file's contents bar the README, which is thin ground for
  inventing a cross-cutting change.

## Reviewer

- **Diff-only**: a plain chat completion over the diff. The rig never runs
  the repo's test suite — provisioning working dev environments for ~8
  arbitrary OSS repos is a large lift that generates zero LLM load, and
  quality is out of scope for this rig.
- **Input**: task + full diff, hard-truncated at a char cap with a "diff
  truncated" marker so a runaway diff can't blow the context window.
- **Output**: free-form prose review — summary plus concerns — with no
  structured verdict field. The Reviewer is not a gate (per
  [lane lifecycle](lane-lifecycle.md), the Person makes the merge call),
  and its only consumer is an LLM that reads prose fine. Fresh completion
  per pass, no memory of prior rounds.

## Person

- **Persona Card**: generated at task invention by its own small
  completion — name, role, communication style, and a pickiness
  disposition. Stored on the task, used for every Person call in that
  task, discarded when the task ends (no cross-task persona memory).
  Pickiness varies per persona so merge/rework rates aren't uniform across
  lanes.
- **Task-scoped transcript**: every Person call includes the Persona Card,
  the task, and the running history of prior Q&A and rulings in this task,
  so the "human" stays coherent across rework cycles. This is prompt
  assembly from rows the rig already holds — no real statefulness.
- **Deciding**: input is Persona Card + task + the Reviewer's review + the
  task-scoped transcript — not the raw diff (the requesting human reads
  the review, not the code; it also keeps the deciding call small). Output
  is structured `{decision: "merge" | "rework", feedback}`; on rework the
  feedback is relayed verbatim into the Coder's session.
