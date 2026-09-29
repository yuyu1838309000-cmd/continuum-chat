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
