"""Real fake-CLI subprocesses and disposable projects; no model calls or credentials.

Adapted from chaseai-yt/claudex-loop at 53cddc42e39346fb8c6d5d612281a3b1add14e66.
Copyright (c) 2026 Chase AI. MIT: skills/engineering/consult/THIRD-PARTY-NOTICES.md.
"""
import contextlib
import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("consult_runner", ROOT / "skills/engineering/consult/scripts/runner.py")
runner = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runner)
GOOD = {"summary": "Keep the original until the backup is verified.",
        "conclusions": ["Deleting first can lose the only copy."],
        "evidence": ["backup.py:1 removes the original before the copy is read."],
        "proposals": ["Verify the new copy first."], "questions": [],
        "coverage": ["backup.py"], "limitations": []}

FAKE_CLI = r'''
import json, os, pathlib, subprocess, sys, time, uuid
if '--version' in sys.argv:
    print('fake-cli 1.0')
    sys.exit(0)
if sys.argv[1:3] == ['mcp', 'list']:
    print(os.environ.get('FAKE_MCP', '[]'))
    sys.exit(int(os.environ.get('FAKE_MCP_EXIT', '0')))
prompt = sys.stdin.read()
case = os.environ.get('FAKE_CASE', 'ok')
if case in ('timeout', 'child_timeout'):
    if case == 'child_timeout':
        subprocess.Popen([sys.executable, '-c',
            'import pathlib,time;time.sleep(2);pathlib.Path('+repr(os.environ['FAKE_MARKER'])+').touch()'])
    time.sleep(30)
if case == 'exit':
    print('Authentication failed', file=sys.stderr)
    sys.exit(7)
if case == 'empty':
    sys.exit(0)
session = str(uuid.uuid4())
if 'resume' in sys.argv:
    session = sys.argv[sys.argv.index('resume')+1]
if '--resume' in sys.argv:
    session = sys.argv[sys.argv.index('--resume')+1]
if case == 'wrong_session':
    session = str(uuid.uuid4())
if case == 'invalid_session':
    session = 'not-a-uuid'
response = json.loads(os.environ['FAKE_RESPONSE'])
if case == 'malformed':
    response = {'summary': 'Missing required fields'}
if case == 'unicode':
    response['summary'] = 'Sound '+chr(0x2192)+' ok'
if 'exec' in sys.argv:
    output = pathlib.Path(sys.argv[sys.argv.index('-o')+1])
    output.write_text('not json' if case == 'bad_json' else json.dumps(response))
    print(json.dumps({'type':'thread.started', 'thread_id':session}))
    if case == 'duplicate_session':
        print(json.dumps({'type':'thread.started', 'thread_id':session}))
    if case == 'turn_failed':
        print(json.dumps({'type':'turn.failed', 'error':{'message':'quota exhausted'}}))
    elif case != 'incomplete':
        print(json.dumps({'type':'turn.completed','usage':{'input_tokens':10,'output_tokens':5}}))
else:
    value = {'type':'result','subtype':'success','is_error':False,'session_id':session,
             'structured_output':response, 'modelUsage':{'claude-test':{}},
             'usage':{'input_tokens':10}, 'permission_denials':[]}
    if case == 'turn_failed':
        value.update(subtype='error_during_execution',is_error=True)
    if case == 'denied':
        value['permission_denials'] = [{'tool_name':'Write'}]
        value['structured_output']['limitations'] = ['Write was denied; proposal only.']
    print('not json' if case == 'bad_json' else json.dumps(
        [{'type':'system','subtype':'init'}, value] if case == 'array' else value))
'''


class RunnerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="consult-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.repo = self.root / "repo with spaces"
        self.repo.mkdir()
        self.git("init", "-q")
        self.git("config", "user.email", "test@example.invalid")
        self.git("config", "user.name", "Test")
        (self.repo / "backup.py").write_text("original\n")
        self.git("add", ".")
        self.git("commit", "-qm", "baseline")
        self.assignment = self.root / "assignment.json"
        self.assignment.write_text(json.dumps({"role": "Design peer", "task": "Assess backup safety",
                                               "context": "Read backup.py and discuss alternatives."}))
        self.message = self.root / "follow up.txt"
        self.message.write_text("The host proposes verifying the copy first. Reassess the risk.")
        self.artifacts = self.root / "runs"
        self.cli = self.root / "fake_cli.py"
        self.cli.write_text(FAKE_CLI)

    def git(self, *args):
        return subprocess.check_output(["git", *args], cwd=self.repo, stderr=subprocess.PIPE).decode()

    def invoke(self, host="claude", case="ok", previous=None, extra=()):
        args = (["continue", "--resume", str(previous), "--message", str(self.message)] if previous else
                ["start", "--host", host, "--repo", str(self.repo), "--assignment", str(self.assignment),
                 "--artifacts", str(self.artifacts)]) + list(extra)
        old = set(self.artifacts.glob("**/result.json"))
        out, err = io.StringIO(), io.StringIO()
        with patch.object(runner, "cli_prefix", return_value=[sys.executable, str(self.cli)]), \
             patch.dict(os.environ, {"FAKE_CASE": case, "FAKE_RESPONSE": json.dumps(GOOD),
                                     "FAKE_MARKER": str(self.root / "child-survived")}), \
             contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = runner.main(args)
        new = set(self.artifacts.glob("**/result.json")) - old
        path = next(iter(new)) if new else None
        return code, json.loads(path.read_text()) if path else None, path, err.getvalue()

    def test_both_directions_launch_in_repo_and_keep_project_unchanged(self):
        for host in runner.PROVIDERS:
            with self.subTest(host=host):
                code, record, path, _ = self.invoke(host)
                self.assertEqual(code, 0, record)
                self.assertNotEqual(record["provider"], host)
                self.assertEqual(record["response"], GOOD)
                self.assertTrue(runner.valid_uuid(record["session_id"]))
                prompt = (path.parent / "prompt.txt").read_text()
                self.assertIn("Assess backup safety", prompt)
                self.assertIn("read-only", prompt)
                self.assertEqual(self.git("status", "--porcelain"), "")

    def test_both_directions_continue_exact_session_and_assignment(self):
        for host in runner.PROVIDERS:
            with self.subTest(host=host):
                _, first, path, _ = self.invoke(host, extra=("--model", "chosen-model", "--effort", "high"))
                self.assignment.write_text("Not used again: assignment is retained.")
                code, second, result, _ = self.invoke(previous=path)
                self.assertEqual(code, 0, second)
                for key in ("session_id", "conversation_id", "assignment", "requested_model", "requested_effort"):
                    self.assertEqual(second[key], first[key], key)
                self.assertIn(self.message.read_text(), (result.parent / "prompt.txt").read_text())
                argv = json.loads((result.parent / "command.json").read_text())
                self.assertIn(first["session_id"], argv)
                self.assertIn("chosen-model", argv)
                self.assertNotIn("--last", argv)
                self.assignment.write_text(json.dumps(first["assignment"]))

    def test_fresh_conversations_have_distinct_sessions_and_artifacts(self):
        _, first, p1, _ = self.invoke()
        _, second, p2, _ = self.invoke()
        for key in ("session_id", "conversation_id", "conversation_dir"):
            self.assertNotEqual(first[key], second[key])
        self.assertNotEqual(p1, p2)

    def test_explicit_provider_for_each_host_is_retained_on_continue_with_read_only_flags(self):
        for host in runner.PROVIDERS:
            for provider in runner.PROVIDERS:
                with self.subTest(host=host, provider=provider):
                    code, first, path, _ = self.invoke(host, extra=("--provider", provider))
                    self.assertEqual(code, 0, first)
                    code, second, continued, _ = self.invoke(previous=path)
                    self.assertEqual(code, 0, second)
                    for record in (first, second):
                        self.assertEqual(record["host"], host)
                        self.assertEqual(record["provider"], provider)
                    self.assertEqual(first["session_id"], second["session_id"])
                    for result in (path, continued):
                        argv = json.loads((result.parent / "command.json").read_text())
                        if provider == "claude":
                            self.assertIn("-p", argv)
                            self.assertEqual(argv[argv.index("--tools") + 1], "Read,Glob,Grep")
                            self.assertEqual(argv[argv.index("--permission-mode") + 1], "dontAsk")
                        else:
                            self.assertIn("exec", argv)
                            if result == path:
                                self.assertEqual(argv[argv.index("-s") + 1], "read-only")
                            else:
                                self.assertIn('sandbox_mode="read-only"', argv)
                    self.assertEqual(self.git("status", "--porcelain"), "")

    def test_continue_rejects_provider_switch_before_launch_but_accepts_same_choice(self):
        for host in runner.PROVIDERS:
            for provider in runner.PROVIDERS:
                with self.subTest(host=host, provider=provider):
                    _, first, path, _ = self.invoke(host, extra=("--provider", provider))
                    other = next(p for p in runner.PROVIDERS if p != provider)
                    with patch.object(runner, "execute", wraps=runner.execute) as launch:
                        code, result, _, error = self.invoke(previous=path, extra=("--provider", other))
                    self.assertEqual(code, 1)
                    self.assertIsNone(result)
                    self.assertIn("Continue provider differs", error)
                    launch.assert_not_called()
                    code, second, _, _ = self.invoke(previous=path, extra=("--provider", provider))
                    self.assertEqual(code, 0, second)
                    self.assertEqual(first["session_id"], second["session_id"])

    def test_invalid_provider_is_rejected_without_launch(self):
        with patch.object(runner, "execute", wraps=runner.execute) as launch, \
             contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit) as error:
                runner.main(["start", "--host", "claude", "--provider", "unknown",
                             "--repo", str(self.repo), "--assignment", str(self.assignment)])
        self.assertEqual(error.exception.code, 2)
        launch.assert_not_called()

    def test_unpinned_and_explicit_model_arguments(self):
        for provider in runner.PROVIDERS:
            args = runner.command(provider, self.root)
            self.assertNotIn("-m", args)
            self.assertNotIn("--model", args)
            pinned = runner.command(provider, self.root, "chosen-model", "high")
            self.assertIn("chosen-model", pinned)

    def test_claude_start_and_resume_expose_only_reading_tools(self):
        for session in (None, "12345678-1234-4567-8123-123456789abc"):
            args = runner.command("claude", self.root, session=session)
            self.assertEqual(args[args.index("--tools") + 1], "Read,Glob,Grep")
            self.assertEqual(args[args.index("--allowedTools") + 1], "Read,Glob,Grep")
            self.assertEqual(args[args.index("--mcp-config") + 1], '{"mcpServers":{}}')
            self.assertIn("--strict-mcp-config", args)
            self.assertIn("--safe-mode", args)
            self.assertIn("--no-chrome", args)
            self.assertEqual(args[args.index("--permission-mode") + 1], "dontAsk")
            self.assertNotIn("--dangerously-skip-permissions", args)

    def test_codex_start_and_resume_enforce_sandbox_and_disable_side_effect_tools(self):
        session = "12345678-1234-4567-8123-123456789abc"
        for resumed in (None, session):
            args = runner.command("codex", self.root, session=resumed, mcp_off=["github"])
            if resumed:
                self.assertEqual(args[:3], ["exec", "resume", session])
                self.assertIn('sandbox_mode="read-only"', args)
            else:
                self.assertEqual(args[args.index("-s") + 1], "read-only")
            self.assertIn('approval_policy="never"', args)
            self.assertIn("mcp_servers.github.enabled=false", args)
            self.assertIn("notify=[]", args)
            for feature in ("apps", "plugins", "hooks", "multi_agent", "browser_use",
                            "computer_use", "image_generation", "in_app_local_automation"):
                self.assertTrue(any(args[i:i + 2] == ["--disable", feature] for i in range(len(args))))
            self.assertNotIn("--dangerously-bypass-approvals-and-sandbox", args)

    def test_failures_keep_diagnostics_and_never_reuse_success(self):
        for host in runner.PROVIDERS:
            for case in ("exit", "empty", "malformed", "bad_json", "turn_failed", "invalid_session"):
                with self.subTest(host=host, case=case):
                    code, record, path, _ = self.invoke(host, case=case)
                    self.assertEqual(code, 1)
                    self.assertEqual(record["status"], "failed")
                    self.assertNotIn("response", record)
                    self.assertTrue((path.parent / "stderr.txt").exists())
                    if case == "exit":
                        self.assertIn("Authentication failed", (path.parent / "stderr.txt").read_text())

    def test_codex_requires_one_start_and_completion_event(self):
        for case in ("incomplete", "duplicate_session"):
            code, record, _, _ = self.invoke(case=case)
            self.assertEqual((code, record["status"]), (1, "failed"))

    def test_claude_array_envelope_and_permission_denials_are_retained(self):
        code, record, _, _ = self.invoke("codex", case="array")
        self.assertEqual(code, 0)
        self.assertEqual(record["observed_models"], ["claude-test"])
        code, record, _, _ = self.invoke("codex", case="denied")
        self.assertEqual(code, 0)
        self.assertTrue(record["permission_denials"])
        self.assertTrue(record["response"]["limitations"])

    def test_structural_response_validation_does_not_require_agreement_or_findings(self):
        runner.validate_response(copy.deepcopy(GOOD))
        blocked = {"summary": "Missing source", **{k: [] for k in runner.LIST_FIELDS}}
        blocked["limitations"] = ["Required schema is unavailable."]
        runner.validate_response(blocked)
        for key, value in (("coverage", "not a list"), ("evidence", [""]), ("summary", "")):
            bad = copy.deepcopy(GOOD)
            bad[key] = value
            with self.assertRaises(runner.RunError):
                runner.validate_response(bad)
        with self.assertRaises(runner.RunError):
            runner.validate_response({"summary": "ok"})
        with self.assertRaises(runner.RunError):
            runner.validate_response({**GOOD, "verdict": "APPROVED"})
        with self.assertRaises(runner.RunError):
            runner.validate_response({**GOOD, "coverage": [], "limitations": []})

    def test_duplicate_json_fields_are_rejected(self):
        with self.assertRaises(runner.RunError):
            runner.load_json('{"summary":"first","summary":"second"}')

    def test_wrong_resumed_session_is_refused_for_both_providers(self):
        for host in runner.PROVIDERS:
            _, _, previous, _ = self.invoke(host)
            code, record, _, _ = self.invoke(previous=previous, case="wrong_session")
            self.assertEqual(code, 1)
            self.assertIn("different session", record["error"])

    def test_model_effort_host_and_repo_mismatch_rejected_before_launch(self):
        for option, value in (("--model", "different"), ("--effort", "high"),
                              ("--host", "codex"), ("--repo", str(self.root))):
            _, _, previous, _ = self.invoke()
            with patch.object(runner, "execute", wraps=runner.execute) as launch:
                code, record, _, error = self.invoke(previous=previous, extra=(option, value))
            self.assertEqual(code, 1, error)
            self.assertIsNone(record)
            launch.assert_not_called()

    def test_latest_turn_only_and_failures_invalidate_old_resume_point(self):
        _, _, first, _ = self.invoke()
        _, _, second, _ = self.invoke(previous=first)
        code, record, _, error = self.invoke(previous=first)
        self.assertEqual(code, 1)
        self.assertIsNone(record)
        self.assertIn("stale", error)
        _, _, failed, _ = self.invoke(previous=second, case="exit")
        for previous in (second, failed):
            code, record, _, _ = self.invoke(previous=previous)
            self.assertEqual(code, 1)
            self.assertIsNone(record)

    def test_lock_prevents_overlapping_continuations(self):
        _, record, previous, _ = self.invoke()
        lock = Path(record["conversation_dir"]) / "turn.lock"
        lock.touch()
        code, result, _, error = self.invoke(previous=previous)
        self.assertEqual(code, 1)
        self.assertIsNone(result)
        self.assertIn("active or interrupted", error)
        self.assertTrue(lock.exists())

    def test_changed_executable_is_refused_before_the_next_turn(self):
        _, record, previous, _ = self.invoke()
        record["executable"] = ["/different/cli"]
        previous.write_text(json.dumps(record))
        with patch.object(runner, "execute", wraps=runner.execute) as launch:
            code, failed, _, _ = self.invoke(previous=previous)
        self.assertEqual(code, 1)
        self.assertIn("executable changed", failed["error"])
        launch.assert_not_called()

    def test_corrupt_or_moved_resume_records_are_rejected_without_launch(self):
        for change in ({"repo": None}, {"provider": "unknown"}, {"session_id": "invalid"},
                       {"artifacts": "/different/path"}, {"executable": []}):
            _, record, previous, _ = self.invoke()
            record.update(change)
            previous.write_text(json.dumps(record))
            with patch.object(runner, "execute", wraps=runner.execute) as launch:
                code, result, _, _ = self.invoke(previous=previous)
            self.assertEqual(code, 1)
            self.assertIsNone(result)
            launch.assert_not_called()

    @unittest.skipIf(os.name == "nt", "POSIX executable fixture; Windows shim resolution is separate")
    def test_public_entry_point_start_and_continue_with_actual_cli_override(self):
        self.cli.write_text('#!' + sys.executable + '\n' + FAKE_CLI)
        self.cli.chmod(0o700)
        settings = dict(os.environ, FAKE_RESPONSE=json.dumps(GOOD), FAKE_CASE="ok")
        command = [sys.executable, "-B", str(ROOT / "skills/engineering/consult/scripts/runner.py")]
        for host in runner.PROVIDERS:
            for provider in (None, *runner.PROVIDERS):
                with self.subTest(host=host, provider=provider):
                    selection = ["--provider", provider] if provider else []
                    call = subprocess.run(command + ["start", "--host", host, "--repo", str(self.repo),
                                          "--assignment", str(self.assignment), "--artifacts", str(self.artifacts),
                                          "--cli", str(self.cli)] + selection,
                                          env=settings, capture_output=True, text=True)
                    self.assertEqual(call.returncode, 0, call.stderr + call.stdout)
                    path = Path(json.loads(call.stdout.splitlines()[-1])["result"])
                    first = json.loads(path.read_text())
                    expected = provider or next(p for p in runner.PROVIDERS if p != host)
                    self.assertEqual(first["provider"], expected)
                    self.assertEqual(first["host"], host)
                    call = subprocess.run(command + ["continue", "--resume", str(path), "--message", str(self.message),
                                          "--cli", str(self.cli)], env=settings, capture_output=True, text=True)
                    self.assertEqual(call.returncode, 0, call.stderr + call.stdout)
                    second = json.loads(Path(json.loads(call.stdout.splitlines()[-1])["result"]).read_text())
                    self.assertEqual(first["session_id"], second["session_id"])
                    self.assertEqual(second["provider"], expected)

    def test_timeout_retains_failure_and_releases_lock(self):
        for host in runner.PROVIDERS:
            code, record, _, _ = self.invoke(host, case="timeout", extra=("--timeout", "1"))
            self.assertEqual(code, 1)
            self.assertIn("timed out", record["error"])
            self.assertFalse((Path(record["conversation_dir"]) / "turn.lock").exists())

    @unittest.skipIf(os.name == "nt", "POSIX process group termination; Windows needs its own live run")
    def test_timeout_kills_descendants(self):
        code, _, _, _ = self.invoke(case="child_timeout", extra=("--timeout", "1"))
        self.assertEqual(code, 1)
        time.sleep(1.5)
        self.assertFalse((self.root / "child-survived").exists())

    def test_invalid_inputs_record_failure_without_launch(self):
        for body in (b'not json', b'{"role":"peer"}', b'\xff'):
            self.assignment.write_bytes(body)
            with patch.object(runner, "execute", wraps=runner.execute) as launch:
                code, record, _, _ = self.invoke()
            self.assertEqual((code, record["status"]), (1, "failed"))
            launch.assert_not_called()

    def test_unreadable_or_empty_message_fails_without_launch(self):
        for missing in (False, True):
            _, _, previous, _ = self.invoke()
            self.message.write_text("")
            if missing:
                self.message.unlink()
            with patch.object(runner, "execute", wraps=runner.execute) as launch:
                code, record, _, _ = self.invoke(previous=previous)
            self.assertEqual((code, record["status"]), (1, "failed"))
            launch.assert_not_called()

    def test_unavailable_cli_is_recorded_and_no_fallback_occurs(self):
        with patch.object(runner.shutil, "which", return_value=None):
            out, err = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                code = runner.main(["start", "--host", "codex", "--repo", str(self.repo),
                                    "--assignment", str(self.assignment), "--artifacts", str(self.artifacts)])
        record = json.loads(next(self.artifacts.glob("**/result.json")).read_text())
        self.assertEqual(code, 1)
        self.assertIn("claude is not on PATH", record["error"])

    def test_codex_mcp_listing_is_applied_or_fails_closed(self):
        with patch.dict(os.environ, {"FAKE_MCP": json.dumps([
                {"name": "github", "enabled": True}, {"name": "off", "enabled": False}])}):
            code, record, path, _ = self.invoke()
        self.assertEqual(code, 0)
        self.assertEqual(record["disabled_mcp_servers"], ["github"])
        self.assertIn("mcp_servers.github.enabled=false", (path.parent / "command.json").read_text())
        for listing in ('not json', '{}', '[{}]', '[{"name":"unsafe.name","enabled":true}]'):
            with patch.dict(os.environ, {"FAKE_MCP": listing}):
                code, record, path, _ = self.invoke()
            self.assertEqual((code, record["status"]), (1, "failed"))
            self.assertFalse((path.parent / "command.json").exists())

    def test_codex_rollout_metadata_is_optional_and_detects_unsafe_sandbox(self):
        session = "12345678-1234-4567-8123-123456789abc"
        home = self.root / "codex-home"
        day = home / "sessions/2026/10/25"
        day.mkdir(parents=True)
        rollout = day / f"rollout-test-{session}.jsonl"
        for sandbox in ("read-only", "workspace-write"):
            rollout.write_text(json.dumps({"type": "turn_context", "payload": {
                "model": "gpt-test", "effort": "high", "sandbox_policy": {"type": sandbox}}}))
            with patch.dict(os.environ, {"CODEX_HOME": str(home)}):
                settings = runner.codex_effective_settings(session)
            self.assertEqual(settings["effective_sandbox"], sandbox)
        with patch.object(runner, "codex_effective_settings", return_value={"effective_sandbox": "workspace-write"}):
            code, record, _, _ = self.invoke()
        self.assertEqual(code, 1)
        self.assertIn("sandbox", record["error"])
        with patch.dict(os.environ, {"CODEX_HOME": str(self.root / "missing")}):
            self.assertEqual(runner.codex_effective_settings(session), {})

    def test_diagnostics_cannot_be_inside_target_or_symlink_into_it(self):
        for target in (self.repo, self.repo / "runs"):
            code, record, _, error = self.invoke(extra=("--artifacts", str(target)))
            self.assertEqual(code, 1)
            self.assertIsNone(record)
            self.assertIn("outside", error)
        if os.name != "nt":
            link = self.root / "link"
            link.symlink_to(self.repo, target_is_directory=True)
            code, _, _, error = self.invoke(extra=("--artifacts", str(link)))
            self.assertEqual(code, 1)
            self.assertIn("outside", error)

    def test_git_subdirectory_is_rejected_but_non_git_project_is_supported(self):
        sub = self.repo / "sub"
        sub.mkdir()
        code, _, _, error = self.invoke(extra=("--repo", str(sub)))
        self.assertEqual(code, 1)
        self.assertIn("pass its root", error)
        plain = self.root / "plain"
        plain.mkdir()
        code, record, _, _ = self.invoke(extra=("--repo", str(plain)))
        self.assertEqual(code, 0, record)

    def test_ascii_console_can_print_paths_after_unicode_response(self):
        out = io.TextIOWrapper(io.BytesIO(), encoding="cp1252")
        with patch.object(runner, "cli_prefix", return_value=[sys.executable, str(self.cli)]), \
             patch.dict(os.environ, {"FAKE_CASE": "unicode", "FAKE_RESPONSE": json.dumps(GOOD)}), \
             contextlib.redirect_stdout(out):
            code = runner.main(["start", "--host", "codex", "--repo", str(self.repo),
                                "--assignment", str(self.assignment), "--artifacts", str(self.artifacts)])
        self.assertEqual(code, 0)


if __name__ == "__main__":
    unittest.main()
