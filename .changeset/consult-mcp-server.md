---
"mattpocock-skills": minor
---

`consult` now runs through an MCP server that the plugin ships for both Claude Code and Codex, which fixes follow-ups failing with "No conversation found" when Codex hosts a Claude consultation inside its sandbox. The server runs each consultation outside the host's sandbox, so the consultant's CLI keeps its conversation between turns. Hosts call `consult_start` to start a turn and get a job back at once, keep working, then collect the reply with `consult_collect`, which returns long replies in pages within both hosts' tool-result limits, followed by the session path for follow-ups. `consult_cancel` stops a turn, and closing the host session stops any consultation still running. The runners stay as the engine the server calls. Codex now reads a new `.codex-plugin/plugin.json`, which declares the server; the version sync script copies the version into both manifests and the skills list from `.claude-plugin/plugin.json` into the Codex one.
