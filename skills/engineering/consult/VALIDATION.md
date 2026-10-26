# Consult validation

Initial validation in the development workspace on 2026-10-25, on Linux with
Python 3.12.14. Offline checks were rerun on 2026-10-26 before committing.
This record applies to this adaptation, not the upstream Claudex runner.

## Offline process tests

Run from the repository root:

```text
python -B -m unittest discover -s tests -p test_consult_runner.py -v
```

The suite launches real subprocesses implementing fake provider CLIs. It covers
both host directions, explicit selection of either provider for either host,
same-provider sessions, inherited selection and rejected provider changes on
follow-ups, starting and continuing conversations, fresh-session
isolation, inherited explicit model settings, mismatched settings/executables,
stale and failed resume points, overlapping turns, malformed and incomplete
results, missing CLIs, unusable MCP listings, permission flags, timeout cleanup,
and diagnostics outside the target checkout. POSIX entry-point tests also use
the public command-line parser and actual executable override without patching
the runner. These tests consume no model quota.

Result: **31 tests passed**, zero failures and zero skips, in 13 seconds. Catalog
and metadata checks also passed: all 28 promoted skills match the plugin list,
the new local references resolve, required documentation sections exist, and
the added prose contains no em dashes. `git diff --check` passed. Existing
`code-review`, productivity skills, package manifests and lockfiles are unchanged.

## Live smoke attempts

A disposable project contained a deliberately unsafe backup sequence: delete
the original before reading the replacement. The assignment asked for direct
file inspection, failure analysis and a safer proposal, with no edits or tests.

| Adapter | Result |
| --- | --- |
| Claude-host route to Codex CLI 0.163.0 | Failed before inference: the configured Codex state directory is mounted read-only, so the in-process client cannot initialize session state. Existing `codex login status` reports ChatGPT authentication. No model answer or resumption was validated. |
| Codex-host route to Claude Code 2.1.310 | Flags were accepted, but the CLI returned `Not logged in` with zero API duration and no model usage. No model answer or resumption was validated. |

Both attempts produced failed records and retained diagnostics outside the
checkout. No restrictions were relaxed and no alternate model/provider was
substituted. The fixture file remained unchanged. CLI authentication and a
writable provider session directory are prerequisites for live validation;
neither fake-process success nor these failed attempts proves real tool
enforcement or model compatibility. No live Windows/macOS validation was run.

## Plugin and release checks

The existing plugin version check passes. The new minor changeset parses with
the installed Changesets release-plan API and contributes to version 1.4.0.
`npm run changeset -- status --since=origin/main` passes and reports the pending
minor release after the new changeset is staged.

`claude plugin validate . --strict` on Claude Code 2.1.310 fails because it treats
the existing root `CLAUDE.md` warning as an error. The same strict failure and
warning occur on a separate archive of the untouched baseline commit
`5beb35b040e3de97e54fa9e386d7e42d15c295c2`. The validator reports no manifest
errors. Its additional directory advice includes an existing missing icon and
ignored macOS metadata shipped inside installed `node_modules`; that advice
does not determine this command's exit status. These unrelated repository
conditions were preserved.
