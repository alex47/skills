# Runtime

Requires Python 3.10+ and an installed, authenticated Claude or Codex CLI.

Replace `RUNNER` with the absolute path to `scripts/runner.py` in the installed `consult` skill. Keep message and diagnostic files outside the target project.

## Send a message

For each message, run `mktemp /tmp/consult-prompt.XXXXXX`. Write the prompt as UTF-8 text to the file it creates. Use the printed full path as `PROMPT` below.

From the target project, run:

```text
python3 "RUNNER" --message "PROMPT"
```

To continue, pass the session file path printed by the latest successful call:

```text
python3 "RUNNER" --resume "SESSION.json" --message "PROMPT"
```

Without `--resume`, a new conversation starts. With it, the existing conversation continues with the same consultant. Run only one turn at a time per conversation. Invalid resume records cause an error, not a new conversation.

## Options

The caller is inferred from its session environment; the consultant defaults to the other provider. If identification is ambiguous, specify `--provider` rather than guessing.

- `--provider claude|codex`: select the consultant directly, including the caller's provider.
- `--repo PATH`: override the current project; use a checkout root or non-Git directory.
- `--timeout SECONDS`: change the execution timeout, which defaults to 600 seconds per turn.

Use nonblocking execution for long calls.

## Reply and failures

The runner saves the reply in a text file. When the call finishes successfully, it prints two full file paths:

- **Reply file:** contains the consultant's response.
- **Session file:** pass this path to `--resume` for follow-ups. You do not need to read its contents.

Example output:

```text
Reply: /tmp/consult-a1b2c3/turn-d4e5f6/reply.txt
Resume: /tmp/consult-a1b2c3/turn-d4e5f6/session.json
```

Exit code zero means success. On a nonzero exit, report the error from stderr. Do not attempt repairs, retries or a fresh conversation without instructions. Do not resume an older session after a failed or interrupted turn, weaken read-only restrictions, or silently switch providers or models.
