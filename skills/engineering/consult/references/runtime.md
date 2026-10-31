# Runtime

Requires an installed, authenticated Claude or Codex CLI. Use Bash on Linux, macOS or WSL, or Windows PowerShell 5.1+ on Windows.

Replace `RUNNER` with the absolute path to `scripts/runner.sh` or `scripts/runner.ps1` in the installed skill. Keep message and diagnostic files outside the target project.

## Send a message

Create a prompt file with `mktemp /tmp/consult-prompt.XXXXXX` in Bash, or `[IO.Path]::GetTempFileName()` in PowerShell. Write your message as UTF-8 text to that file and use its full path as `PROMPT`.

From the target project, run:

```bash
bash "RUNNER" --message "PROMPT"
```

On Windows, use:

```powershell
& "RUNNER" --message "PROMPT"
```

To continue, add `--resume "SESSION.txt"` using the session path printed by the latest successful call. Without `--resume`, a new conversation starts. Run only one turn at a time per conversation. An invalid resume record causes an error, not a new conversation.

## Options

The caller is inferred from its session environment; the consultant defaults to the other provider. If identification is ambiguous, specify `--provider` rather than guessing.

- `--provider claude|codex`: select the consultant directly, including the caller's provider.
- `--repo PATH`: override the project directory. Git projects use their checkout root; follow-ups keep the same working directory.
- `--timeout SECONDS`: change the execution timeout, which defaults to 600 seconds per turn.

Use nonblocking execution for long calls.

## Reply and failures

Prompts, replies and session records are plain-text files. When a call finishes successfully, stdout contains only two full file paths:

- **Reply file:** contains the consultant's response.
- **Session file:** pass this path to `--resume` for follow-ups. You do not need to read its contents.

Example output:

```text
Reply: /tmp/consult.a1b2c3/turn.d4e5f6/reply.txt
Resume: /tmp/consult.a1b2c3/turn.d4e5f6/session.txt
```

Each call uses separate output files in the system temporary directory.

Exit code zero means success. On a nonzero exit, report the error from stderr. Do not attempt repairs, retries or a fresh conversation without instructions. Do not resume an older session after a failed or interrupted turn, weaken read-only restrictions, or silently switch providers or models.
