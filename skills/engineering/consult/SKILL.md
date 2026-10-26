---
name: consult
description: Independent assessment and consultation with a separate AI agent. Use when the user wants a second opinion, another skill requests consultation, or an existing consultation needs follow-up.
---

Use a separate AI agent for an independent assessment, advice, or both. You are the **host**; the separate agent is the **consultant**, running in its own session.

The consultant stays read-only and cannot make changes or run tests.

## How to use it

You can use the consultant in two modes, separately or together.

### 1. Independent assessment

Ask the consultant to carry out the same review, analysis or investigation you are performing. Provide the task details and relevant context, and have it reach its conclusions independently.

Compare its findings with your own. You can continue the same conversation to ask why it reached a conclusion, clarify a finding, or discuss a different interpretation.

### 2. Advice

Ask the consultant for advice on a task, approach or decision. Share your current thinking and relevant context, and ask it to challenge assumptions, suggest alternatives or point out concerns.

You can ask it to explain its suggestions, question its reasoning or explore an alternative in the same conversation.

## 1. Brief the consultant

Use the participants, roles and checkpoints supplied by the calling skill. Keep its existing workflow and subagents.

Give the consultant:

- A role, task and target repository.
- The question to answer and what would count as answering it.
- Relevant requirements, constraints, code state and evidence. Supply actual test results when available.

Use the calling skill's discussion limit. For a standalone consultation, choose and state a finite limit before starting. Each consultant response counts as one turn; there is no fixed default or minimum.

Keep the relevant code state stable during an independent assessment. Complete your own assessment before reading the consultant's conclusions. Share findings only within the discussion groups the calling skill defines, after all initial assessments are complete.

## 2. Start or continue

Read [runtime.md](references/runtime.md) before running a turn: CLI setup, commands, result checks and diagnostics. Resolve the runner from this installed skill's directory. Keep explicit provider, model and effort choices throughout the conversation.

Start a separate conversation for each assignment and participant. Continue the same assignment from its latest completed result, one turn at a time. Reuse a dedicated ticket consultant across checkpoints and nested skills when the calling skill requests it. Start fresh for an independent final review or a different provider.

Read the response and its limitations before using it.

## 3. Discuss the answer

Check claims against files, requirements and test evidence. Keep supported concerns even when only one participant raises them. Agreement does not prove correctness.

For a follow-up, send the concern, evidence checked, proposed correction and remaining question. Ask the same consultant to reassess.

Stop when the question is answered, another exchange would add no useful evidence, or the discussion limit is reached. Keep unresolved disagreements; agreement is optional. A new checkpoint needs its own question and evidence, not a fresh budget for the same debate.

Decide routine technical matters from the evidence. Bring consequential user choices back to the user with alternatives, implications and your recommendation.

## 4. Report

Use the calling skill's report format. Include:

- Conclusions and supporting evidence.
- Suggestions accepted or declined, with reasons.
- Unresolved disagreements, questions and user decisions.
- Actual coverage and limitations.

If a turn fails, inspect the diagnostics and report what's blocked. Required consultation remains unfinished. Keep the selected provider/model and read-only restrictions; never use an older answer as the failed turn's result. Once the cause is fixed, start fresh with a summary: a failed or interrupted session may already have advanced.
