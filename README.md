# opencode-in-PowerShell skills

Skills for agents that run opencode in PowerShell 7. They are written for Claude Haiku and
are loaded by an orchestration that lives outside this repository.

Each skill is a folder under `.opencode/skills/` containing a `SKILL.md`. opencode
discovers them automatically when it is started in this repository.

| Skill | Goal |
| --- | --- |
| [`clarify-job`](.opencode/skills/clarify-job/SKILL.md) | Detect ambiguous words in a job and rewrite each ambiguous sentence with `<... ...>` placeholders for the missing information. |
