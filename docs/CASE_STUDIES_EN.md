# Source-product case studies: engineering long-running agents

> This document summarizes engineering problems that were observed, tested, and addressed in the **source product** behind Continuum Chat.  
> The public repository remains a sanitized, runnable reference baseline. The advanced mechanisms described here demonstrate design reasoning and validation practice; **not every mechanism is fully open-sourced in this repository**.

The cases focus on the system around the model rather than on model choice itself.

## 1. Memory: retrieval is not the same as provider visibility

### Problem

A retrieved Memory card can still be filtered by score thresholds, cooldowns, layout policy, or the final context-selection path. Counting every retrieved candidate as a `hit` therefore overstates actual model exposure.

### Design decision

Split retrieval from provider-visible injection.

A durable injection receipt is written only when a specific Memory revision actually enters the Context sent to the Provider. Receipts are idempotent per generation/card/revision so retries do not double-count usage.

### Result

Memory metrics answer a more useful question:

> “Which memories did the model actually see?”

instead of:

> “Which candidates did the retriever return?”

### Public-repository boundary

The public baseline keeps Memory as an independent CRUD/recall service but does not automatically inject it into chat Context. This case documents why the source product later separated retrieval metrics from injection metrics.

---

## 2. Tools: a successful action is useless if the next turn forgets it

### Problem

A tool can complete successfully while the next model turn has no durable record of what happened. The model then guesses whether an action ran, which parameters were used, and whether the result was delivered.

### Design decision

Persist compact **execution receipts**:

```text
decide → call tool → execute → normalize result → persist receipt
                                           ↓
                                  next-turn context
```

Receipts keep stable, reusable facts while excluding raw stdout, large tool JSON, and debugging noise.

### Result

The tool loop becomes more than “the model can call a function”:

> **the action happened, and later decisions can reliably know that it happened.**

---

## 3. Context: continuity should not be traded away through silent truncation

### Problem

For long windows, a tempting optimization is to send only the most recent N messages or silently replace older history with summaries. In the source product, that changed the semantic basis for commitments, tool facts, and long-running behavior inside the same conversation.

### Design decision

Separate context ownership:

- **canonical history** for what actually happened;
- **Context Epochs** for explicit user-created conversation boundaries;
- **immutable handoff** for bounded replay of a fixed previous-window snapshot;
- **Context Inspector** for observing the final provider payload at the send boundary.

Performance work is directed toward prefix/KV stability, duplicate composition, dynamic blocks, provider-call structure, and frontend streaming rather than silently rewriting continuity.

### Result

Context becomes a lifecycle-managed system with explicit owners and an audit surface, rather than a loose collection of prompt strings.

---

## 4. Pending: standing principles are not unfinished tasks

### Problem

A pending-task ledger can accidentally absorb statements such as “be more proactive from now on” or “never do this again.” These have no finite completion point, so they become permanent “ghost tasks” repeatedly injected into later turns.

### Design decision

Restrict Pending to **finite obligations**: a reply, action, tool result, artifact, or one bounded action after a concrete prerequisite is met.

The lifecycle includes:

- `actionable`
- `waiting_user`
- `paused`
- `blocked`

plus a progress checkpoint describing what is done, what comes next, who/what is being waited on, and the resume condition.

Long-term behavior belongs to other owners such as Prompt, Policy, Memory, or Self-model state.

### Result

Pending becomes a finite, resumable obligation ledger rather than a dumping ground for every unresolved statement.

---

## 5. Proactive behavior: real execution needs one owner

### Problem

Long-running agents may have contact triggers, free-activity loops, future plans, event wakeups, deduplication, throttling, and tool execution. If multiple schedulers can all “really send,” ownership becomes ambiguous and duplicate behavior follows.

### Design decision

Separate trigger signals, plan state, and execution while enforcing a single real execution owner.

Canonical action facts / receipts record what actually happened. Suppression and NO_RESPONSE remain distinct semantic outcomes rather than being disguised as assistant text.

### Result

A proactive action can be explained:

- why it triggered;
- why it did not trigger;
- what actually happened;
- why something was suppressed;
- what the next model turn can observe.

---

## 6. Self Model: personality maintenance must not become self-confirming prompt drift

### Problem

A long-running agent gradually forms stable beliefs such as “how I usually behave” or “what kind of agent I am.” The simplest implementation is to write those beliefs directly into Prompt or Memory, but that creates several failure modes:

- one user comment can become a permanent personality fact;
- maintenance turns can repeatedly say “this is who I am” and create a self-confirming loop;
- one-off behavior can be overgeneralized into a stable trait;
- hot updates can silently change the active long-window input mid-conversation.

### Design decision

The source product separates **Self Model** from ordinary Memory and separates proposal, mutation, evidence, maturity, and adoption.

The lifecycle is:

```text
real conversation / tool / proactive behavior
        ↓
canonical evidence
        ↓
Curator: support / contradiction / no_match
        ↓
review suggestion (proposal only; no mutation)
        ↓
primary agent review / revise
        ↓
re-validate current evidence
        ↓
Deterministic Gate
        ↓
append-only claim version
        ↓
future ContextEpoch adoption
```

Important constraints:

- the Curator has **no** claim-mutation authority;
- suggestions, summaries, and review events do not count as maturity evidence;
- a maintenance turn repeating the agent's own self-description does not count as another independent support event;
- a user preference alone cannot establish personality;
- only current, agent-origin, independent evidence can advance maturity;
- multiple independent evidence roots are required, with no active contradiction, before a claim can become established;
- maturity is decided by a deterministic gate rather than by the LLM declaring itself “stable”;
- provider-visible adoption is frozen at a **ContextEpoch boundary**, so the active conversation does not silently change personality when the store updates.

### Why this is not ordinary Memory

Memory is primarily about:

> “What happened before?”

Self Model is about:

> “Given repeated real behavior over time, what stable belief about myself is justified now?”

Those two systems need different evidence rules, lifecycles, and mutation authority. Mixing them allows a single event to become both a historical fact and an immediate personality definition.

### Result

Personality maintenance becomes an auditable lifecycle instead of a few editable persona strings:

> **real behavior → evidence → candidate interpretation → primary-agent review → deterministic gating → adoption at a new context boundary**

The personality can evolve without drifting merely because of one comment, one anomalous behavior, or maintenance self-repetition.

### Public-repository boundary

The public baseline does not currently ship the production Self Model store, Curator, or maintenance runtime. This document exposes only the sanitized architecture and engineering trade-offs; private personality content, real evidence, and production databases are not published.

---

## 7. Scene-first Memory: write from grounded experiences, not every turn

### Problem

The earlier writing pipeline could promote routine conversation fragments into long-term memory. A continuous experience could also be fragmented by technical conversation-window boundaries, increasing duplicates and retrieval noise.

### Design and trade-offs

- Keep raw events as immutable sources of truth. Scenes are rebuildable, source-linked experience structures that may cross Context Epochs and retain revision/boundary provenance.
- When a Scene finalizes, decide among `scene_only / promote_memory / pending / drop_scene` rather than writing a new memory for every exchange.
- Reuse strict evidence, scope, lineage, and idempotency gates before promoting or updating a memory. Automatically maintained content must not override manually protected memories.
- Allow local re-review of derived Scene boundaries without rewriting raw history.

### Verified result and boundary

The source product's **Scene-first Writer took over scheduled writes on 2026-10-04**. A subsequent fix restored a missing final-commit consumer, and the flow was validated for both new writes and evidence-grounded updates to existing memories. Scene boundary repair, admission checks, and retry paths have focused regression evidence.

The public reference still includes only an independent Memory service with deterministic recall; **the production Scene/Writer pipeline is not bundled here**. This is not a performance claim for the public demo.

---

## 8. Retrieval, ambient surfacing, activation, and pre-action checks are different layers

### Problem

Being retrieved is not the same as being seen by the model; being injected is not evidence that a memory has become important again. Conflating them in a `hit`/heat score creates feedback loops. Unrelated ambient memories can also disrupt a task.

### Design and trade-offs

- **Related** selects evidence based on the current request and explicit historical references; **Ambient / Resonance** can surface a small amount of past context under separate eligibility and cooldown rules.
- Track retrieval candidates, provider-visible injection, and genuine activation as distinct events. Retrieval/injection do not automatically reheat memories; explicit user reactivation and real updates are evaluated separately.
- Prepare bounded recall before the first model reasoning pass on proactive turns. For potentially mutating tools, perform a sanitized, read-only historical preflight before allowing a repeat action.
- Prefer abstaining on ambiguous semantic matches; an optional reranker is not automatically enabled globally based on a few promising probes.

### Verified result and boundary

Related recall, Ambient/Resonance, proactive pre-recall, and pre-action checks were deployed and regression-checked in the source product. **Legacy scheduled memory-lifecycle logic has not been fully replaced**, so this does not claim a complete migration of all heat/archival rules. The public reference neither auto-injects Memory nor runs an autonomous tool loop.

---

## 9. Context observability: inspect what the provider actually receives

### Problem

Over a long conversation, historical tool output, backend state, and no-response bookkeeping can accidentally re-enter later requests as if they were conversational examples. This expands the prompt and can distort behavior while the real conversation stays unchanged.

### Design and trade-offs

- Place a **Context Inspector** near the actual provider-send boundary instead of relying only on the theoretical context builder.
- Preserve all real user/assistant speech inside the active epoch, while excluding historical backend bookkeeping from few-shot-style replay. Current action receipts still have a separate bounded path.
- Reuse the existing Inspector to trace Scene boundary decisions, reflective proposals, and pre-action checks rather than inventing a second diagnostics system.

### Verified result and boundary

In one sanitized source-product regression, projected messages fell from roughly **468 to 371** and historical system messages from **101 to 4**, while retaining all **367** actual user/assistant messages. The fix has focused tests and production load evidence. This is **one case study, not a general performance benchmark**.

Backend observation and runtime details were validated; **parts of the Context Inspector UI are still being developed**. The full production Inspector is not shipped in the public repository.

---

## 10. Memory R5: safely migrating a reviewed historical-memory rebuild

### Problem

Long-running Memory records can accumulate duplicate identities and complex revision/evidence relationships. Production conversations may also continue between human review and deployment. A bulk overwrite would obscure provenance and rollback.

### Design and trade-offs

- R1–R4 covered inventory, identity proposals and human review; R5 revalidated approved semantic inputs against current canonical revisions.
- Approved changes became canonical revisions, soft-trash operations, lineage edges and a Water organization graph, with backup and rollback receipts retained.
- Canonical storage, VNext retrieval-index consistency and live read endpoints were checked independently.

### Verified result and boundary

**The source product completed its R5 cutover on 2026-10-09.** Preflight checked **549 cards** and supporting evidence. The production cutover included **452 coalesced revisions, 28 soft-trash changes and 4 active lineage edges**. The Water graph contains **5 Lakes, 18 Streams and 545 memberships**; VNext valid-index reconciliation reached **518/518**, and the production Water and VNext read endpoints passed live checks.

These are figures from **one source-product migration**, not public-demo scale or a general accuracy benchmark. Automated new-topic Water growth is not yet live. No private Memory text, real conversation content, relationship details or production databases are published.

---

## 11. Multi-provider transport: verify streaming responses and measured cache behavior

### Problem

After adding the native Gemini API in the source product, a real reply could be returned by the model while the app displayed "no response." Tool-continuation format differences and low long-context cache hits were also observed.

### Design and trade-offs

- Replay frozen sanitized requests and inspect the actual SSE events. A CRLF event-framing error was fixed, including delimiters split across network chunks.
- Normalize native function-call / function-response objects into the internal tool-continuation contract and verify subsequent rounds.
- Use provider-reported usage to measure explicit caching while preserving canonical history and complete-request fallback on cache errors.

### Verified result and boundary

Focused streaming and tool-continuation regressions passed in the source product. In **one fixed input of approximately 15,848 tokens**, an explicit-cache experiment reported **14,628 cached tokens (92.3%)**. This observation is **not a general cache-hit average or cost guarantee**.

The public reference provides a compact OpenAI-compatible adapter and mock flow; it **does not include the production native Gemini transport or cache implementation**.

---

## Shared principles

The source-product iteration converged on several recurring rules:

1. **Facts need a canonical owner.**
2. **Candidates, plans, execution, and visible results are different layers.**
3. **Model-external state needs lifecycle rules instead of more prompt text.**
4. **Automation needs receipts, traces, and regression tests to stay maintainable.**
5. **User-visible continuity takes priority over silent context truncation.**

The public baseline is intentionally compact and runnable. The source product keeps stress-testing these lifecycle boundaries under long-term use.

> **Public reference = a safe, reproducible engineering slice**  
> **Source product = the production system used to validate the broader boundaries**

See also: [Architecture](ARCHITECTURE.md) · [README](../README_EN.md)
