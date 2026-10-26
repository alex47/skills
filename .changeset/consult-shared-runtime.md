---
"mattpocock-skills": minor
---

Add `consult`, a model-invoked supporting skill for read-only Claude and Codex collaboration, with a Python CLI runner, session continuity, retained diagnostics and offline process tests. The runner uses plain-text prompts and replies, infers the caller and current project, and continues a conversation when `--resume` is supplied. Optional `--provider claude|codex` overrides the default counterpart, supports same-provider consultation and remains fixed on follow-ups. The `code-review` Standards and Spec sub-agents each use an independent consultant alongside their own review and return one report per axis. The `implement` skill discusses its approach with a consultant and can reuse that conversation throughout implementation, including TDD. Other engineering and productivity workflows keep their behavior.
