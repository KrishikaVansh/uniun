# Agent Skills — Agentic Ganas + User-Defined Skills

How UNIUN turns Ganas from one-shot generators into multi-step agents,
using the skill runtime that shipped with `flutter_edge_ai (then flutter_edge_ai 1.2.0)`
(`skillExecutors:` seam) + the opt-in `flutter_edge_ai_agent` package.
Extends [`Ganas.md`](Ganas.md); scheduling constraints come from
[`scheduling.md`](scheduling.md); all knowledge retrieval stays rooted
in [`graphrag.md`](graphrag.md).

> **TL;DR** — A skill is a markdown file (YAML frontmatter + body) the
> model can invoke mid-generation. We ship a predefined catalog wired
> to our existing use cases (graph search, input reading, publishing),
> let users author their own **text** skills for Ganas and Shiv, keep
> one-shot Ganas as the default with "agentic" as a per-Gana opt-in,
> and route every agent round through the InferenceScheduler. The
> knowledge graph remains the single knowledge hub — skills are
> *windows into the graph*, never a parallel knowledge store. Future:
> skills shared/sold over Nostr as signed events.

---

## Table of Contents

1. [Why](#1-why)
2. [Mental model](#2-mental-model)
3. [Skill anatomy + executor types](#3-skill-anatomy--executor-types)
4. [The graph is the hub — non-negotiable](#4-the-graph-is-the-hub--non-negotiable)
5. [Predefined skill catalog](#5-predefined-skill-catalog)
6. [Agentic Ganas](#6-agentic-ganas)
7. [Shiv chat integration](#7-shiv-chat-integration)
8. [User-defined skills](#8-user-defined-skills)
9. [Scheduler integration](#9-scheduler-integration)
10. [Architecture / layer mapping](#10-architecture--layer-mapping)
11. [Security model](#11-security-model)
12. [Background isolate constraint](#12-background-isolate-constraint)
13. [Future: skill sharing + marketplace over Nostr](#13-future-skill-sharing--marketplace-over-nostr)
14. [Phasing](#14-phasing)
15. [Open questions](#15-open-questions)

---

## 1. Why

Today a Gana run is exactly one inference call: we pre-pack context
(Manas notes + input messages + ancestry) into a prompt, generate
once, and either publish the body or honor the `<NOOP>` sentinel
(`gana_run.dart:isGanaNoop`). That works, but it has ceilings:

- **We guess the context.** `ManasContextLoader.merge` picks the
  knowledge before the model sees the task. If the retrieval missed,
  the output is bad and the model can't ask for more.
- **The publish decision is a string.** `<NOOP>` is a sentinel the
  model must spell exactly; a hallucinated variant publishes garbage.
- **Capabilities require app releases.** A Gana can only do what the
  prompt builder hard-codes.

`flutter_edge_ai (then flutter_edge_ai 1.2.0)` added the `skillExecutors:` registration seam;
`flutter_edge_ai_agent` (0.1.x) supplies the agent loop: the model reads
skill descriptions, emits a function call picking a skill, the
executor runs it, the result feeds back, the model continues. This doc
specifies how that maps onto Ganas and Shiv without breaking the
scheduler, the offline-first rule, or the graph-centric knowledge
model.

**Why now / why the old blocker is gone:** flutter_edge_ai issue
[#348](https://github.com/DenisovAV/flutter_gemma/issues/348) (per-turn
native-heap leak) is **OpenCL-GPU-specific**. The maintainer verified
CPU is flat and Metal (iOS) is flat. Fixed upstream
(google-ai-edge/LiteRT-LM#2699), so multi-round agent loops no longer
multiply a per-turn leak on either GPU backend.

**Status update (2026-09-15):** fixed in `flutter_edge_ai_litertlm` 1.4.1
(LiteRT-LM v0.16.0). UNIUN now ships flutter_edge_ai (then flutter_edge_ai 1.8.3) / litertlm 1.6.3
and prefers GPU on Android as well (`lib/core/utils/llm_backend.dart`). The
"separate SIGSEGV" previously cited as a second blocker was never tied to an
upstream issue; the known Android GPU native-crash classes (flutter_edge_ai
#209, #379) are fixed in versions older than the ones we ship. The CPU retry
only catches a *thrown* GPU failure, so any device-specific native crash
should be pinned to CPU per device.

---

## 2. Mental model

```
                     ┌────────────────────────────────┐
                     │        AgentSession loop       │
                     │                                │
   task prompt ────► │  model thinks                  │
                     │    │                           │
                     │    ├─ emits skill call ──────┐ │
                     │    │                         ▼ │
                     │    │                ┌──────────┴──────┐
                     │    │                │ UniunSkill      │
                     │    │                │ Executor        │
                     │    │                │ (data layer)    │
                     │    │                └──────┬──────────┘
                     │    │      result           │ calls use cases
                     │    ◄───────────────────────┘
                     │    │                       ┌──────────────┐
                     │    ├─ repeats ≤ maxRounds  │  KNOWLEDGE   │
                     │    │                       │  GRAPH       │
                     │    └─ final action:        │ (Isar: Note, │
                     │       publish-note skill   │  NoteRelation│
                     │       or ends silent       │  Manas, ...) │
                     └────────────────────────────┴──────────────┘
```

Two rules the diagram encodes:

1. **Every skill that reads knowledge reads the graph.** There is no
   second knowledge store. `search-notes` is vector search over the
   user's notes; `expand-graph` walks `NoteRelationModel` edges;
   `get-memories` reads `MemoryNodeModel` wiki summaries. Skills give
   the model *agency over graph traversal* — they do not introduce new
   sources of truth.
2. **The publish decision is a skill call, not a sentinel.** An
   agentic Gana that ends its loop without calling `publish-note`
   published nothing. `<NOOP>` becomes unnecessary in agentic mode
   (one-shot mode keeps it — see §6).

---

## 3. Skill anatomy + executor types

A skill is a markdown file:

```markdown
---
name: search-notes
description: Search the user's own notes by meaning. Use when you need
  facts, opinions, or past writing from the user's knowledge base.
---
Call with a short natural-language query. Returns up to 5 matching
notes (date + content preview). Query in the user's language.
```

`flutter_edge_ai_agent` ships four executor mechanisms. Our stance on
each:

| Executor | Runs | UNIUN stance |
|---|---|---|
| `TextSkillExecutor` | Text-only instructions | ✅ Used — user-defined skills are this type ONLY |
| Custom (`UniunSkillExecutor`) | Our Dart use cases | ✅ The core of the integration — all predefined skills |
| `JsSkillExecutor` | Sandboxed JS in headless webview | ❌ Not v1. Revisit only for power users, never for shared skills |
| `NativeIntentExecutor` | Whitelisted OS intents + confirmation | 🔶 Phase 3 (reminders, share sheet) |
| `McpSkillExecutor` | Remote MCP tools over HTTP | ❌ Never — violates offline-first / no-cloud-AI |

`SkillExecutorProvider` (core contract in flutter_edge_ai (then flutter_edge_ai 1.2.0)) is a
3-member interface — `name`, `priority`, `canExecute(skillType)` — so
`UniunSkillExecutor` is a plain data-layer class implementing it and
dispatching skill calls to injected use cases.

---

## 4. The graph is the hub — non-negotiable

The Nostr event graph (every `e` tag an edge, every `t` tag a topic
node, `NoteRelationModel` as the materialized edge table, Manas as
user-curated subsets, `MemoryNodeModel` as wiki overlays) **is the
knowledge hub**. The skill layer must respect three invariants:

1. **No skill introduces a knowledge store outside the graph.** A
   skill may *read* the graph (search, expand, resolve) and may
   *write* to it only through the existing publish paths (which
   create Notes — i.e. graph nodes).
2. **Skill results are graph citations.** Every knowledge skill
   returns note ids alongside content, so agent outputs can carry
   `e`-tag references — agent-written notes weave INTO the graph
   rather than floating beside it.
3. **RagPipeline and skills share the same retrieval services.**
   `VectorSearchService`, `GetGraphNeighboursUseCase`,
   `ManasContextLoader` back both the static pipeline (Shiv one-shot
   RAG, one-shot Ganas) and the skill layer (agentic mode). One
   retrieval stack, two access patterns.

---

## 5. Predefined skill catalog

Predefined skills are markdown assets bundled with the app, each
handled by `UniunSkillExecutor` → an existing use case. Grouped by
role:

### 5.1 Knowledge skills (the graph windows)

| Skill | Backed by | Returns |
|---|---|---|
| `search-notes` | `VectorSearchService` (cosine top-K, Manas-scoped when the Gana/chat has one) | ≤5 notes: id, date, preview |
| `expand-graph` | `GetGraphNeighboursUseCase` (1-hop BFS over `NoteRelationModel`) | Neighbour notes of a given note id |
| `get-memories` | `GetMemoriesByNoteIdsUseCase` | Wiki summaries linked to given notes |
| `read-note` | `NoteResolverRepository.resolveById` | Full content of one note by id |

### 5.2 Input skills (one per `GanaInputType`)

The Gana's configured input decides which ONE of these is registered
for its session — the model can re-read or page deeper instead of
receiving a fixed pre-packed dump:

| Skill | For `GanaInputType` | Backed by |
|---|---|---|
| `read-group-input` | `group` | Same query `GanaInputFilter` uses today (kind 42, cursor-scoped) |
| `read-private-group-input` | `privateGroup` | kind 9023, cursor-scoped |
| `read-dm-input` | `dm` | kind 14/15 by conversationId |
| `read-user-input` | `user` | kind 1 by author pubkey |
| `read-followed-note-input` | `followedNote` | `#e` children via edge table |
| `read-thread` | any | Reply ancestry (`resolveReplies` / ancestry walk) |

### 5.3 Output skills (one per `GanaOutputType`)

Exactly ONE output skill is registered per agentic Gana session,
matching the Gana's configured `outputType`. Calling it is the publish
decision:

| Skill | For `GanaOutputType` | Backed by |
|---|---|---|
| `publish-feed-note` | `feed` | `PublishMediaNoteUseCase` (kind 1) |
| `publish-group-message` | `group` | `CreateGroupMessageUseCase` (kind 42) |
| `publish-private-message` | `privateGroup` | `SendPrivateGroupMessageUsecase` (kind 9023) |
| `send-dm` | `dm` | `SendDmUseCase` (kind 14) |

Args: `body` (string, required), `referenceNoteIds` (list, optional —
becomes NIP-10 `e` mention tags, weaving the output into the graph per
§4.2). The executor enforces the Gana's configured destination — the
model cannot redirect output to a different group/DM than the user
configured. **One publish per run**: after the first successful
publish call the executor rejects further publish calls in the same
session.

### 5.4 Device skills (Phase 3)

`remind-me` (notification/calendar intent), `share-external` (OS share
sheet) — via `NativeIntentExecutor`, always behind a user-confirmation
dialog. Not in the initial build.

### 5.5 Registration matrix

A Gana session registers: knowledge skills (always, scoped to the
Gana's Manas) + the ONE input skill matching `inputType` (none for
standalone Ganas) + the ONE output skill matching `outputType` + any
user skills the user toggled on for this Gana (§8). A Shiv session
registers: knowledge skills (scoped to the picked Manas or all notes)
+ user skills; **no output skills** — Shiv answers in-chat, it does
not publish.

---

## 6. Agentic Ganas

### 6.1 One-shot stays the default

`GanaModel` gains one field: `agentic: bool` (default `false`).
Existing rows keep working unchanged. The Gana form gets an "Agentic
(multi-step)" toggle with a model-capability note.

| | One-shot (default) | Agentic (opt-in) |
|---|---|---|
| Inference calls per run | 1 | 2–5 (≤ `maxRounds`, default 4) |
| Context | Pre-packed by `prepareGanaRun` | Model pulls via skills |
| Silence protocol | `<NOOP>` sentinel | No `publish-*` call |
| Runs in background isolate | ✅ | ❌ (§12) |
| Model floor | any | Gemma-4-class recommended; small models allowed but warned |
| Latency (CPU, 0.6B) | ~30 s | ~1–4 min |

### 6.2 Trigger × input × output — no new matrix

`GanaTriggerPreset`, `GanaInputType`, `GanaOutputType` are untouched.
`agentic` is an orthogonal flag: any preset/input/output combination
can be agentic, EXCEPT runs executed by the background isolate (those
run one-shot regardless — §12). The skill registration matrix (§5.5)
derives mechanically from the existing input/output fields, so there
is no per-combination configuration for the user — pick input, pick
output, toggle agentic; the right skills appear.

### 6.3 Run lifecycle (agentic)

```
tick fires (reactive / interval / one-shot — unchanged)
  │
  ├─ guards (self-loop, cursor, enabled) — unchanged, from gana_run.dart
  │
  ├─ build AgentSession: task prompt (GanaPromptBuilder, output-format
  │    rules REPLACED by skill instructions) + registered skills (§5.5)
  │
  ├─ loop ≤ maxRounds:                        each round = ONE
  │    model round ──► skill call ──► result   scheduler job (§9)
  │
  ├─ terminal:
  │    • publish-* called → output event created via existing use case
  │    • loop ends w/o publish → silent run (was: NOOP)
  │    • maxRounds hit w/o publish → silent run, logged distinctly
  │
  └─ GanaRunModel: one row per RUN (unchanged), plus per-round trace
       (new lightweight GanaRunStepModel: runId, round, skillName,
        argsPreview, resultPreview, durationMs) for debuggability
```

### 6.4 Good / bad ledger (decision record)

Kept honest so future-us knows what we accepted:

- ✅ Model can retrieve what it actually needs (agentic RAG beats
  guessed context).
- ✅ Typed publish decision kills the `<NOOP>` spelling fragility.
- ✅ Capabilities extend via skills, not releases.
- ⚠️ 2–5× chip time per run — acceptable because agentic is opt-in,
  foreground-only, round-scheduled (chat still preempts, §9).
- ⚠️ Small-model tool-calling reliability unproven (Qwen3 0.6B). The
  form warns; maxRounds caps the damage; a malformed skill call ends
  the round as silent.
- ⚠️ CPU latency: minutes per run. Fine for Ganas (they're background
  personas, not chat).

---

## 7. Shiv chat integration

Shiv gets the same knowledge skills in an opt-in "deep answer" mode
(per-conversation toggle, later maybe automatic for hard questions):

- Static path (default, unchanged): `RagPipeline.buildMessage` —
  embed → top-K → 1-hop → prompt. One inference, fast.
- Agentic path (toggle): `AgentSession` with knowledge skills; the
  model searches/expands iteratively before answering. Slower,
  better on multi-hop questions ("what did I conclude about X after
  reading Y?").

Both paths cite note ids; `ShivMessageEntity.sourceNoteIds` already
carries citations to the bubble UI. No output skills in Shiv (§5.5).
The Manas picker keeps working: the picked Manas scopes
`search-notes` exactly as it scopes `RagPipeline` today.

---

## 8. User-defined skills

Users can author skills and attach them to Ganas and Shiv.

- **v1: text skills only.** A form (name, description, instructions)
  → `UserSkillModel` (Isar: `skillId`, `name`, `description`, `body`,
  `createdAt`, `updatedAt`) → registered into the session's
  `SkillRegistry` at build time. A text skill is effectively a named,
  reusable instruction block the model can *choose* to consult — a
  modular extension of the Gana `taskPrompt`.
- **Attachment:** per-Gana multi-select in the Gana form ("Custom
  skills"); per-conversation toggle sheet in Shiv.
- **No user JS, no user intents, no user MCP.** Executor mechanisms
  stay ours (§11).
- Predefined skills are assets; user skills are Isar rows. The
  registry merges both; name collisions resolve to the predefined one
  (user skills get a `user-` name prefix at registration to prevent
  shadowing).

---

## 9. Scheduler integration

The hard design problem. `AgentSession` wants to drive the model
directly; the [UNIUN Scheduling Algorithm](scheduling.md) requires all
inference to flow through `InferenceScheduler`. Resolution: **each
agent ROUND is one scheduler job.**

```
AgentSession round lifecycle
  round N ready ──► scheduler.run(kind: gana, modelId: …)   ← T4 (or T3 past deadline)
                      │ waits its turn (chat/extract may run first)
                      ▼
                    one inference round (bounded — one skill call
                    or final answer, capped by maxOutputTokens)
                      │
                    skill executes OUTSIDE the scheduler
                    (Isar reads — µs–ms, no chip time)
                      │
  round N+1 ready ──► scheduler.run(...)                    ← re-queues
```

Consequences, all intentional:

- **Chat preempts between rounds for free.** A T0 job can run between
  round N and N+1 without cancelling anything; within a round the
  existing token-boundary `CancelToken` works unchanged.
- **Fairness holds.** Each round bills vruntime to the Gana's T4
  entry; a 5-round agent costs 5 fair-pool slots, not one monopoly.
- **Model affinity works.** Rounds of one session carry the same
  `modelId`, so affinity batching keeps rounds together when the pool
  is otherwise idle.
- A cancelled round (preempted mid-generation) retries once, then the
  run ends silent (logged `cancelled`).
- Shiv agentic rounds submit at **T0** (they ARE chat).

This means we do NOT use `flutter_edge_ai_agent`'s own drive-the-model
loop verbatim — we use its `SkillRegistry` / skill parsing / executor
contract, but the round pump lives in our code
(`lib/features/shiv/generation/agent_loop.dart`) so every inference
passes the scheduler. If the package's loop can't be split this way,
we implement the (small) round pump ourselves against
`FunctionCallResponse` — the parsing machinery is already in
flutter_edge_ai core (`lib/core/parsing/`).

---

## 10. Architecture / layer mapping

```
PRESENTATION
  Gana form: "Agentic" toggle + custom-skill multi-select
  Shiv: "deep answer" toggle + skill sheet
  Skill editor page (create/edit user text skills)
    └─ all via use cases, no direct data access

DOMAIN
  SkillEntity (freezed), UserSkillRepository (interface)
  usecases: CreateUserSkillUseCase / UpdateUserSkillUseCase /
            ListUserSkillsUseCase / DeleteUserSkillUseCase*
  AgentRunPolicy (maxRounds, model gating) — pure domain rules

DATA
  UserSkillModel (@Collection)  — user-authored text skills
  GanaRunStepModel (@Collection) — per-round trace
  UniunSkillExecutor            — implements SkillExecutorProvider;
                                  constructor-injected use cases
  agent_loop.dart               — the scheduler-integrated round pump
  skill catalog assets          — assets/skills/*.md (predefined)

* Deleting a USER SKILL is fine — skills are local configuration,
  not published Notes. Feed Freedom applies to Nostr events, not to
  the user's private tooling.
```

Layer rules from CLAUDE.md hold: domain imports neither Isar nor
flutter_edge_ai; the executor and loop live in data; BLoCs see use cases
only.

---

## 11. Security model

The threat that matters: **Ganas publish under the user's own key.**
A skill is instructions the model obeys — a malicious skill is a
prompt-injection vector that posts in the user's name.

Mitigations, layered:

1. **User skills are text-only** (v1). No code execution paths exist
   for user content.
2. **Output is structurally constrained.** The executor pins the
   publish destination to the Gana's configured output; a skill
   cannot add destinations, and one publish per run is enforced in
   the executor, not the prompt.
3. **Skill text is always visible.** The editor shows the full body;
   nothing is hidden from the user who attaches it.
4. **Imported/shared skills (Phase 4, §13)** additionally require:
   full-text preview before install, signed-author provenance, and
   text-type enforcement at decode time.
5. No `McpSkillExecutor`, no `JsSkillExecutor` for user content —
   these are stances, not TODOs.

---

## 12. Background isolate constraint

`gana_workmanager.dart` (no DI, own Isar, OS background budget of
single-digit minutes) **stays one-shot permanently**:

- An agent loop's 1–4 min CPU runtime does not fit reliably inside a
  WorkManager window; a mid-loop kill wastes the entire run.
- The scheduler doesn't exist in that isolate, so rounds would be
  unscheduled — breaking §9's invariant.

Rule: when the background isolate picks up a due Gana with
`agentic == true`, it **defers** it (leaves the cursor untouched) so
the foreground engine runs it agentically on next app open; a Gana
whose trigger urgency matters more than depth should simply stay
one-shot. The form explains this ("Agentic Ganas run when the app is
open").

---

## 13. Future: skill sharing + marketplace over Nostr

Very on-brand, very deliberately Phase 4+:

- **Skill as a Nostr event.** A new addressable kind carrying the
  skill markdown in `content`, `d` tag as skill id — signed by the
  author, distributed over relays like everything else.
- **Install = follow + verify.** Import shows full text (§11.4),
  verifies the signature, stores locally as a `UserSkillModel` row
  with provenance fields (`authorPubkey`, `sourceEventId`).
- **Selling.** Zaps/payment-gated skill events, author reputation via
  the social graph, skill collections as Manas-like bundles. All
  design-TBD; nothing here constrains it except: shared skills are
  text-only, forever.
- **Gana templates.** A Gana config (taskPrompt + skill set + trigger
  preset) could itself be shared the same way — "install this
  persona".

---

## 14. Phasing

1. **P1 — Foundation.** `flutter_edge_ai_agent` dependency;
   `UniunSkillExecutor`; knowledge skills (§5.1); the scheduler round
   pump (§9); Shiv "deep answer" behind a dev flag. Prove tool-call
   reliability per model (Gemma 4 E2B/E4B, DeepSeek, Qwen3 0.6B) on
   CPU-Android + iOS.
2. **P2 — Agentic Ganas.** `agentic` flag + form toggle; input/output
   skills (§5.2–5.3); `GanaRunStepModel` trace; background-isolate
   deferral (§12).
3. **P3 — User skills.** `UserSkillModel` + editor + attachment UI in
   Gana form and Shiv; device skills (`remind-me`) behind
   confirmation dialogs.
4. **P4 — Sharing.** Nostr skill kind, import/verify flow,
   marketplace exploration (§13).

Each phase lands independently shippable; P1's dev flag means nothing
user-visible changes until reliability numbers are in.

---

## 15. Open questions

- Which Nostr kind number for shared skills (P4) — coordinate before
  anything ships to a relay.
- `maxRounds` default: 4 is a guess; P1 telemetry (GanaRunStepModel
  durations) should set it per model class.
- Does `flutter_edge_ai_agent`'s `AgentSession` expose a per-round seam
  cleanly, or do we build the round pump on raw
  `FunctionCallResponse` from day one? Decide in P1 spike week.
- Qwen3 0.6B: if tool-calling proves unusable, do we hide the agentic
  toggle for that model or show it with a strong warning? (Leaning:
  hide.)
