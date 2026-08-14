# Agent Coding Bench

A load generator and observability rig: a living ecosystem of LLM agents doing
realistic agent-coding work against a vLLM server (DeepSeek on an AMD MI300X),
so serving performance can be observed under real agentic stress.

## Language

**World**:
The living ecosystem as a whole — the lanes, their clones, and the cast,
running against one vLLM box.
_Avoid_: simulation, environment

**Lane**:
One pipeline instance of PM → Coder → Reviewer → Person working a single task
at a time. The concurrency knob is the number of lanes.
_Avoid_: stack, pod, crew, worker

**Run**:
An explicit observation window over the world, tagged with knob settings and a
fingerprint of the serving config, so two runs can be compared.
_Avoid_: session, experiment

**World Repo**:
One of the ~8 upstream open-source repositories the world's work happens in.
_Avoid_: project, target repo

**Clone**:
A lane-local copy of a World Repo. Approved work merges into the clone's main,
so it drifts over time. Clones never push upstream and are never shared
between lanes.
_Avoid_: checkout, workspace

**Task**:
A unit of work a PM invents for its lane's clone, carried end to end through
implementation, review, and merge. Its size — `small`, `medium`, or `large` —
is dealt mechanically from a weighted slate before invention, and sets both
the PM's size instruction and the task's hard cap.
_Avoid_: ticket, issue, story

**Mirror**:
The box-local bare copy of a World Repo, fetched from upstream once when the
box is provisioned and never updated after. Clones are created from it.
_Avoid_: bare repo, origin, cache

**Collector**:
The process that samples the vLLM metrics endpoint continuously while the
world is up. Runs never touch it.

**Sample**:
One scraped metric value — a single (metric, labels, value) observation the
Collector takes at one instant.
_Avoid_: datapoint, reading

**Call**:
One unit of LLM work as observed by the client: a single chat completion for
PM/Reviewer/Person, one assistant message (a whole tool-loop turn) for the
Coder.
_Avoid_: request

**Lane states**:
Inventing (PM picks a World Repo and invents the task) → Coding (Coder works;
Person answers questions inline) → Reviewing (fresh Reviewer pass over the
diff) → Deciding (Person rules: merge or rework). Merging is a transition,
not a state.

**Abandon**:
Mechanical termination of a task — session error, inactivity timeout,
per-task hard cap, persistent completion failure, or lane crash. Never a
judgment call by any cast member; the clone resets and the PM invents fresh.
_Avoid_: fail, cancel, reject

### The cast

**PM**:
The agent that invents the next task for a lane.

**Coder**:
The agent that implements a task. The only cast member that is an opencode
session; the rest are plain chat completions.

**Reviewer**:
The agent that reviews a coder's finished work. Produces a review; the merge
call belongs to the Person, not the Reviewer.

**Person**:
The agent playing the requesting human: answers when a coder asks a question,
and rules on reviews — merge as-is, or back to the Coder for rework. Personas
are generated dynamically; replies have no artificial delay.
_Avoid_: human, user, stakeholder

**Persona Card**:
The Person's identity for one task — name, role, communication style, and a
pickiness disposition — generated at task invention and discarded when the
task ends. Every Person call in the task uses the same card.
_Avoid_: profile, character
