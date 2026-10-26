## What it does

`consult` gives the agent doing your work a read-only Claude or Codex peer. By default Claude consults Codex and Codex consults Claude; you can choose either provider explicitly, including the one hosting your conversation. The peer can inspect files, challenge an approach, investigate a failure, suggest code and examine results. Your agent keeps responsibility for implementation and decisions.

A consultation can continue in the same [session](https://www.aihero.dev/ai-coding-dictionary/session). It ends when the question is answered, discussion stops adding useful evidence, or the calling workflow reaches its discussion limit. Agreement is optional; supported concerns remain visible even when only one participant raises them.

## When to reach for it

Type `/consult`, or the agent reaches for it automatically when you request a Claude or Codex second opinion or a calling skill assigns that collaboration.

| Your situation | Reach for |
| --- | --- |
| You want a separate Claude or Codex peer to challenge an approach, investigate a concern or reassess a proposal | `consult` |
| You want Standards and Spec reviewed as separate axes over a diff | [code-review](https://aihero.dev/skills-code-review) |
| You need an agent to implement a concrete change | [implement](https://aihero.dev/skills-implement) |

## Prerequisites

The selected provider's CLI must be installed and authenticated, and Python 3.10 or newer must be available. Authentication in the host application alone may not authenticate its CLI. A selective skill installation must include `consult` alongside any skill that calls it.

The consultant needs relevant requirements, repository access and evidence. Your agent provides test results and makes project changes. The CLI retains conversation metadata and diagnostics outside the project.

## A second opinion with continuity

The calling skill decides the consultant's role, when to ask, what evidence to provide and how much discussion to allow. `consult` handles the common conversation protocol and CLI connection. It adds no automatic consultation to existing skills just because they are installed together.

Follow-ups reuse the same consultant for the same assignment. A different assignment or an independent final review starts fresh. When independent first opinions matter, participants receive the same relevant inputs before seeing each other's conclusions.

## Common questions

**Can I choose Claude or Codex?**

Yes. Name the provider, such as "consult Claude about this approach". The runner accepts `--provider claude` or `--provider codex`; omitting it chooses the counterpart. Same-provider consultation still uses a separate read-only session. Follow-ups retain the choice, and switching providers starts a fresh conversation. Model selection is a separate option.

**Can the consultant change my files?**

Its project tools enforce read-only access. It can suggest a patch, but your agent decides whether to apply it. The CLI itself can write session records outside the project.

**What happens when they disagree?**

Your agent checks the evidence and decides routine technical matters. It reports unresolved concerns with their reasoning, and asks you about consequential tradeoffs. Agreement between two agents is not a correctness check.

**Why not keep discussing until they agree?**

Agreement is not the goal. Each calling workflow sets a finite discussion limit, and stops sooner when further exchanges add no useful evidence. There is no fixed requirement for two follow-ups.

## It's working if

- The second opinion cites files, requirements or concrete scenarios you can check.
- Follow-ups address the remaining question and remember earlier exchanges.
- Only the agent responsible for implementation changes your project.
- The outcome distinguishes decisions from unresolved concerns and tells you what was actually inspected.
- Missing authentication or a failed consultation is reported, rather than hidden by a substitute answer.

## Where it fits

`consult` is supporting collaboration that another engineering skill can call, and a standalone way to request a Claude or Codex second opinion. It preserves the calling workflow's roles, including its existing [subagents](https://www.aihero.dev/ai-coding-dictionary/subagent).

[code-review](https://aihero.dev/skills-code-review) remains the skill for organizing Standards and Spec review; [implement](https://aihero.dev/skills-implement) owns building changes. Their consultation checkpoints are configured separately. [ask-matt](https://aihero.dev/skills-ask-matt) maps the wider set.
