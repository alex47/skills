# Runtime

For long calls, run the command in the background so you can continue your own work while it runs. Run only one turn at a time per conversation.

## Linux, macOS and WSL

From the target project, run:

```bash
# Start a conversation
bash "RUNNER" --message "MESSAGE"

# Continue a conversation
bash "RUNNER" --message "MESSAGE" --session "SESSION"
```

- `RUNNER`: absolute path to `scripts/runner.sh` inside the `consult` skill directory.
- `MESSAGE`: absolute path to the text file containing your message to the consultant. Create it with `mktemp /tmp/consult-message.XXXXXX` and write the message as UTF-8 text.
- `SESSION`: absolute path to the session file for the conversation you want to continue.

## Windows

From the target project, run in PowerShell:

```powershell
# Start a conversation
& "RUNNER" --message "MESSAGE"

# Continue a conversation
& "RUNNER" --message "MESSAGE" --session "SESSION"
```

- `RUNNER`: absolute path to `scripts/runner.ps1` inside the `consult` skill directory.
- `MESSAGE`: absolute path to the text file containing your message to the consultant. Create it with `[IO.Path]::GetTempFileName()` and write the message as UTF-8 text.
- `SESSION`: absolute path to the session file for the conversation you want to continue.

## Optional arguments

- `--provider claude|codex`: choose the consultant’s provider. By default, Claude consults Codex and Codex consults Claude.
- `--timeout SECONDS`: set the execution timeout, which defaults to 600 seconds per turn.

## Results

When a call finishes successfully, the runner prints two absolute paths to stdout:

- **Reply:** absolute path to the plain-text file containing the consultant’s reply.
- **Session:** absolute path to the session file. Pass this to `--session` to continue the same conversation.

Example output:

```text
Reply: /tmp/consult.a1b2c3/turn.d4e5f6/reply.txt
Session: /tmp/consult.a1b2c3/turn.d4e5f6/session.txt
```

On failure, report the error from stderr. Do not retry or start a new conversation without instructions.
