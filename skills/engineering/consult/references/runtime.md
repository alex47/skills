# CLI runtime

Python 3.10+, standard library only. The runtime executes **one turn**, either starting or continuing a consultation with Claude or Codex. The coordinating host owns the discussion loop, tests and user decisions.

Resolve `RUNNER` to `scripts/runner.py` beneath the installed `consult` skill, using the skill location supplied by the harness. Installation paths vary; do not substitute a file of that name in the target project. Bundle `consult` with every skill that depends on it. Managed installation of the whole promoted plugin includes it; a selective installer must include both the calling skill and `consult`.

## Start

Create a host-authored UTF-8 JSON assignment outside the target checkout. It has exactly these three nonempty string fields:

```json
{
  "role": "Design peer",
  "task": "Assess whether the proposed backup sequence can lose data.",
  "context": "Read backup.py. The host proposes verifying the new copy before deleting the old one. Identify failure cases and alternatives; tests have not run yet."
}
```

Use the actual provider hosting the user conversation, rather than inferring it from installed binaries:

```text
python RUNNER start --host codex --repo PROJECT --assignment ASSIGNMENT_JSON
python RUNNER start --host claude --repo PROJECT --assignment ASSIGNMENT_JSON
```

By default, Codex hosts consult Claude and Claude hosts consult Codex. Use optional `--provider claude|codex` to choose the consultant explicitly, including the same provider as the host. It starts a separate read-only session with the same restrictions. Keep `--host` set to the actual host:

```text
python RUNNER start --host claude --provider claude --repo PROJECT --assignment ASSIGNMENT_JSON
python RUNNER start --host codex --provider codex --repo PROJECT --assignment ASSIGNMENT_JSON
```

Provider selection is separate from model selection: `--provider` chooses the CLI; `--model` chooses a model within that provider. There is no writable mode. `--repo` is an existing checkout root or a non-Git project directory. Dirty working trees are supported and preserved. The caller must stabilize the relevant files when reviewing a specific code state; the runner creates no source snapshot or lock.

Use `--model MODEL` and optionally `--effort LEVEL` for explicit choices. Omit them on start to use CLI configuration. The CLI account and defaults can differ from the host application. The runner does not change global configuration or silently fall back. If an explicit choice is unsupported, report the failure.

`--cli ABSOLUTE_EXECUTABLE` selects a verified installation when PATH chooses the wrong one. Windows npm shims are resolved to known native or Node entry points, without a batch shell. Runtime installation and CLI authentication are prerequisites; use the providers' supported installation and login instructions, never ask for credentials in chat.

## Continue

Write a host-authored UTF-8 message outside the checkout, then pass the **latest completed** result:

```text
python RUNNER continue --resume PREVIOUS_RESULT_JSON --message FOLLOW_UP_TEXT
```

The record retains repository, role, task, context, provider, session and explicit model/effort choices. Omitting provider/model/effort on continuation inherits them. Repeating `--provider` is allowed only with the same choice. Supplying a different host, provider, repository, model or effort is rejected; start a new conversation to change provider or assignment. Keep the same CLI executable, supplying the same `--cli` override when needed. With CLI defaults, the effective model remains subject to provider configuration; use explicit choices when identity must stay fixed.

Each conversation has an exclusive `turn.lock` and `state.json`. Overlapping turns and attempts to resume older results are rejected. A failed/running latest result cannot be continued through an earlier successful record, because the provider may have consumed the prompt already. Inspect the failure and start a fresh conversation with a host-authored summary. After abrupt runner termination an abandoned lock or running record can remain; check that no process is active before archiving those diagnostics and starting fresh. Do not delete an active lock to force a continuation.

## Response and diagnostics

The runner immediately prints a unique artifact directory outside the target checkout, then prints the result path and transport status. The default parent is the system temporary directory; use `--artifacts DIRECTORY` on start for durable diagnostics. Each conversation retains separate turn directories containing `prompt.txt`, `schema.json`, `command.json`, CLI stdout/stderr and `result.json`. Diagnostics may contain private code; keep them outside version control and manage retention accordingly. Do not copy authentication files or secret values into them.

An exit code of zero plus a new `completed` record means a structurally valid, completed exchange. Any nonzero exit, failed record or incomplete CLI completion is a failed exchange. Inspect its diagnostics and tell the caller what failed; a failed exchange cannot satisfy a required consultation. Never infer completion from a session-start event, output-file existence or a previous successful result.

The `response` object contains exactly:

| Field | Content |
| --- | --- |
| `summary` | Nonempty summary of the answer or blocker |
| `conclusions` | Conclusions, including supported disagreement |
| `evidence` | Source locations, concrete failure scenarios and supplied observations supporting conclusions |
| `proposals` | Suggested approaches, changes or code for the host to consider |
| `questions` | Open questions requiring more evidence or a decision |
| `coverage` | Files, requirements and supplied evidence actually examined |
| `limitations` | Uncertainty, denied tools, missing evidence or other limits |

Every field except `summary` is an array of nonempty strings; empty arrays are allowed. A response must identify actual coverage or explain the blocked inspection in limitations, and contain a conclusion, question or limitation. There is no universal approval verdict or minimum objection count. Validation catches malformed transport and shape; it cannot establish that claims, coverage or evidence are true.

Records also include conversation/session UUIDs, assignment, prompt hash, previous result path, CLI version and executable, requested model/effort, duration, usage and reported model information when available. Codex effective model/effort/sandbox metadata is read best-effort from its local rollout format. These are client observations, not server confirmation; unavailable model identity stays unknown.

## Read-only boundaries

| Provider | Enforced restrictions |
| --- | --- |
| Claude | Safe mode; strict empty MCP configuration; only `Read,Glob,Grep` exposed and preapproved; `dontAsk` denies other permissions; Chrome disabled. No shell, editing or delegation tools. Safe mode preserves supported CLI authentication while disabling customizations. |
| Codex | Read-only shell sandbox on both start and resume; approvals set to never; apps, plugins, hooks, multi-agent, browser, computer, image generation and local automation features disabled; notify hook cleared; web search disabled. Every enabled MCP server is listed and disabled individually; an unreadable or unsafe listing fails closed. |

Shell sandboxing alone does not constrain MCP or other external side effects. Keep all the restrictions, including when resuming. An unsupported flag is a compatibility failure: upgrade the CLI or report the limitation. Do not remove restrictions or accept an unrestricted run to make it pass. Admin-managed policy and the execution environment still apply.

Read-only describes the consultant's project tools. The CLI may write session metadata outside the checkout so conversation continuity works. The host independently runs tests, supplies actual results and applies changes; the consultant reports its inspection and the limits of supplied proof.

The default execution timeout is 600 seconds per turn; version and MCP probes have separate bounded timeouts. `--timeout SECONDS` changes the execution bound. Use nonblocking host execution and continue progress updates while waiting. Timeout/interruption terminates the CLI process tree and records failure. No automatic retry, model switch or weaker permission mode follows.

Invoke the runner with separate arguments, never a shell command assembled from model output. Arbitrary extra provider flags are unsupported. Avoid broad prefix permission rules for the runner: such rules can also authorize shell chaining around it.

Provider references: [Claude headless usage](https://code.claude.com/docs/en/headless), [Claude CLI](https://code.claude.com/docs/en/cli-reference), [Codex non-interactive mode](https://developers.openai.com/codex/noninteractive), [Codex security](https://developers.openai.com/codex/security).
