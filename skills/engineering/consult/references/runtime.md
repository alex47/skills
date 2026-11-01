# Runtime

Consult through the plugin's MCP tools: `consult`, `consult_wait` and `consult_cancel`. Run only one turn at a time per conversation.

## 1. Start a turn

Write your message as UTF-8 text to a new file outside the project: create it with `mktemp /tmp/consult-message.XXXXXX` on Linux, macOS and WSL, or `[IO.Path]::GetTempFileName()` on Windows. Then call `consult` with:

- `message`: absolute path to that file.
- `repo`: absolute path to the project. Required for a new conversation.
- `session`: the session path from the latest reply, to continue that conversation.

`consult` returns a job immediately while the consultant works. Continue your own work in the meantime.

Optional: `provider` (`claude` or `codex`) chooses the consultant for a new conversation; by default, Claude consults Codex and Codex consults Claude. `timeout` sets the turn's limit in seconds, which defaults to 600.

## 2. Collect the reply

Call `consult_wait` with the job. It returns the reply, followed by the session path for follow-ups:

- If it says the consultant is still working, call it again with the same job.
- If it says more of the reply remains, call it again with the job and the offset it gives. Repeat until it reports the end of the reply.

## 3. Cancel

Call `consult_cancel` with the job to stop a consultation you no longer need. A cancelled or failed turn ends its conversation.

## Failures

When a tool reports an error, report it. Do not retry or start a new conversation without instructions.
