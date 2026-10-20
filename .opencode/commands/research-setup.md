---
description: Make the research tool available in every project (global registration)
---

Set up this repository's research server for use outside this directory. Work on the
machine you are running on, report what you changed, and change nothing else.

1. **Check uv.** Run `uv --version`. If it is missing, stop and tell me to install it with
   `irm https://astral.sh/uv/install.ps1 | iex` (per-user, no admin), then re-run this.

2. **Warm the environment.** Run `uv sync --frozen` in the repository root so the first
   tool call does not wait on dependency resolution. `uv run` would do this on its own;
   this only moves the wait out of the session.

3. **Register the server globally.** In `~/.config/opencode/opencode.json` (create it if
   absent, copy it to `opencode.json.bak` first if it exists), add one entry under `mcp`:

   ```json
   "deepresearch": {
     "type": "local",
     "command": ["uv", "run", "--quiet", "--project", "<absolute repo path>", "<absolute repo path>/deep_research.py"],
     "cwd": "<absolute repo path>",
     "enabled": true,
     "timeout": 60000,
     "environment": { "PYTHONUTF8": "1", "PYTHONIOENCODING": "utf-8", "DEEP_RESEARCH_MAX_CONTENT": "16000" }
   }
   ```

   Use real absolute paths, and keep the rest of the file byte-for-byte as it was. Do not
   add or change `model`, `small_model`, `provider`, or anything else: model access is mine
   to configure, not this repository's.

4. **Copy the agent and command.** Copy `.opencode/agents/researcher.md` to
   `~/.config/opencode/agents/` and `.opencode/commands/*.md` to
   `~/.config/opencode/commands/`, overwriting older copies of the same files.

5. **Verify and report.** Run `opencode mcp list` and show me the result. Then tell me
   which files you wrote, and that a new MCP server only appears after opencode restarts,
   since the config is read at startup.

If any step fails, stop and show me the error rather than working around it.
