## What it does

`consult` gives the agent doing your work a read-only Claude or Codex peer. By default Claude consults Codex and Codex consults Claude; you can choose either provider explicitly, including the one hosting your conversation. The peer can inspect files, challenge an approach, investigate a failure, suggest code and examine results. Your agent keeps responsibility for implementation and decisions.

Use it for an independent assessment of the same task, or for advice, brainstorming and thinking through a problem. Follow-up discussion is optional in either mode.

A consultation can continue in the same [session](https://www.aihero.dev/ai-coding-dictionary/session), with follow-ups when useful. The agent and consultant may reach different conclusions, which can be an acceptable outcome.

## When to reach for it

Type `/consult`, or the agent reaches for it automatically when you request a Claude or Codex second opinion or a calling skill assigns that collaboration.

| Your situation | Reach for |
| --- | --- |
| You want a separate Claude or Codex peer to challenge an approach, investigate a concern or reassess a proposal | `consult` |
| You want Standards and Spec reviewed as separate axes over a diff | [code-review](https://aihero.dev/skills-code-review) |
| You need an agent to implement a concrete change | [implement](https://aihero.dev/skills-implement) |

## Prerequisites

The selected provider's CLI must be installed and authenticated. The runner uses Bash on Linux, macOS and WSL, or Windows PowerShell 5.1+ on Windows. On Windows, use the native CLI executable. Authentication in the host application alone may not authenticate its CLI. A selective skill installation must include `consult` alongside any skill that calls it.

The consultant needs relevant requirements, repository access and evidence. It does not inherit your agent's conversation or loaded skills, so your agent includes the relevant task instructions, constraints and decisions in its brief. Your agent provides test results and makes project changes. The CLI retains conversation metadata and diagnostics outside the project.

The runner saves the reply and a session record in separate text files and prints their full paths. It starts the CLI in the project's checkout root and uses that directory for follow-ups. Add `--resume` with the session path to continue the conversation.

## A second opinion with continuity

The calling skill decides the consultant's role, when to ask and what context to provide. `consult` handles the common conversation protocol and CLI connection. `implement` and `implement-spec`'s implementer subagents use it for implementation advice. [code-review](https://aihero.dev/skills-code-review) uses fresh consultants for independent assessments within each review axis. `diagnosing-bugs` requests independent hypotheses after reproducing and minimising the bug. The `improve-codebase-architecture` exploration subagent compares independent assessments of deepening opportunities. `to-tickets` reviews draft breakdowns involving shared changes, coordination between parallel tickets or staged migrations before user approval. `to-spec` reviews its draft for contradictions, ambiguous requirements and gaps before publication, with the host checking feedback against the conversation. `wayfinder` reviews proposed decision tickets and dependencies before creating the map and tickets. Other workflows can call it at their own checkpoints.

Follow-ups reuse the same consultant for the same assignment. A different assignment or an independent final review starts fresh. When independent first opinions matter, participants receive the same relevant inputs before seeing each other's conclusions.

## Common questions

**Can I choose Claude or Codex?**

Yes. Name the provider, such as "consult Claude about this approach". The runner accepts `--provider claude` or `--provider codex`; omitting it chooses the counterpart. Same-provider consultation still uses a separate read-only session. Follow-ups retain the choice, and switching providers starts a fresh conversation. Model selection is a separate option.

**Can the consultant change my files?**

Its project tools enforce read-only access. It can suggest a patch, but your agent decides whether to apply it. The CLI itself can write session records outside the project.

**Can a consultant start another consultation?**

No. Consultants must not invoke this skill or start other consultants.

**What happens when they disagree?**

Different conclusions can be an acceptable outcome. You can ask the consultant to explain a finding or discuss another interpretation in the same conversation.

**Why not keep discussing until they agree?**

You can use a single assessment or advice response, or continue with further questions. The agent and consultant may reach different conclusions; agreement is not required.

## It's working if

- The second opinion cites files, requirements or concrete scenarios you can check.
- Follow-ups address the remaining question and remember earlier exchanges.
- Only the agent responsible for implementation changes your project.
- The outcome distinguishes decisions from unresolved concerns and tells you what was actually inspected.
- Missing authentication or a failed consultation is reported, rather than hidden by a substitute answer.
- A failed consultation is reported without automatic repairs, retries or a new conversation.

## Where it fits

`consult` is supporting collaboration that another engineering skill can call, and a standalone way to request a Claude or Codex second opinion. It preserves the calling workflow's roles, including its existing [subagents](https://www.aihero.dev/ai-coding-dictionary/subagent).

[code-review](https://aihero.dev/skills-code-review) organizes Standards and Spec review, with a separate consultant for each axis; [implement](https://aihero.dev/skills-implement) owns building changes. [ask-matt](https://aihero.dev/skills-ask-matt) maps the wider set.
