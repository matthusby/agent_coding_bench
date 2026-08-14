# Lane lifecycle and failure semantics

Decided in [#5](https://github.com/matthusby/agent_coding_bench/issues/5).

## The loop

```
inventing ──task──▶ coding ──done──▶ reviewing ──review──▶ deciding
    ▲                 ▲                                      │
    │                 └────────── rework (same session) ─────┤
    │                                                        │
    └──── merge to clone main + task row ◀── approve ────────┘
    └──── abandon: reset clone + task row ◀── (from any state)
```

## States

- **Inventing** — the PM picks a World Repo for this task (rotation across
  repos, not lane-pinned) and invents the task. On the way out: reset the
  clone to main, delete stray branches (self-heals after mid-task kills), cut
  the task branch.
- **Coding** — the Coder's opencode session works the task branch. The Person
  answering opencode question events (`question.asked` and
  `question.v2.asked`) happens *inside* this state — replies are instant chat
  completions, so a lane is never observably "waiting on a human".
- **Reviewing** — a fresh Reviewer chat completion per pass (no memory of
  prior rounds) over the diff + task.
- **Deciding** — the Person reads the review and rules:
  - **approve** → merge task branch to clone main, delete branch, write task
    row (`merged`), back to inventing.
  - **rework** → feedback goes into the *same* coder session, back to coding.
    Review cycles are uncapped; the per-task hard cap is the only backstop.

Merging is a transition, not a state — git ops on a lane-local clone are
instant and can't meaningfully conflict.

## Abandonment

Abandonment is **mechanical only** — never a judgment call by any cast
member. Triggers, from any state:

| Trigger | Task row reason |
| --- | --- |
| Coder `session.error` | `session_error` |
| No SSE event from the coder session for the inactivity window | `inactivity_timeout` |
| Per-task hard cap expires (invention through merge, spanning all rework cycles) | `task_timeout` |
| PM/Reviewer/Person completion still failing after Req retries | `completion_failure` |
| Lane process crash — swept to abandoned on restart (decided in [#8](https://github.com/matthusby/agent_coding_bench/issues/8)) | `lane_crash` |

On abandon: `session_abort` the coder session if live, reset the clone,
write the task row (`abandoned` + reason), back to inventing. Never retry
the same task — a fresh PM-invented task is as good a load unit and avoids
poison-task loops.

Timeouts are config values, not constants. Defaults: inactivity 10 min,
per-task hard cap 60 min — generous because the model under heavy
concurrency is slow, not stuck.

PM completion failure is the one non-abandoning failure: there's no task
yet, so the lane just idles and retries invention.

## Task rows

Every task ends in exactly one row: task, lane, World Repo, outcome
(`merged` | `abandoned` + reason), timestamps. An operational log for "why
is lane 3 weird" — not a headline metric (whether any of it surfaces as
run metrics is [#6](https://github.com/matthusby/agent_coding_bench/issues/6)'s call).

## Runs and the world

Runs never touch lanes — a Run is a pure observation window (see
`CONTEXT.md`). World stop or lane scale-down hard-aborts mid-task: no drain
ceremony, nothing durable is lost (stats are serving-side, clones are
box-local). The clone reset on the next inventing pass cleans up whatever a
kill left behind.

## Isolation

Clone-per-lane-per-World-Repo means a codebase copy is only ever worked by
one lane, by construction. Two lanes on the same World Repo hold physically
separate clones that drift independently — no global one-lane-per-repo lease
needed.
