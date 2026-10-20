# Deep Research for opencode

An MCP server that gives a coding agent real research capability — web search, academic
search, link following, and content extraction — packaged for the
[opencode](https://opencode.ai) CLI.

It adds a tool, an agent, and a command. It does **not** touch model access: the research
agent runs on whichever model opencode already offers you — for example
`databricks/databricks-claude-opus-4-6` on Databricks Model Serving — and your provider
configuration is left exactly as it is. If opencode has no model access yet, the installer
can set up a Databricks provider for you, but only when you ask for it.

Everything installs and runs under your own user account: no administrator rights, no
system Python, no system PATH changes. **PowerShell 7 only** — there is no bash anywhere in
this repo.

## Overview

1. **Web search** through DuckDuckGo
2. **Academic search** through Semantic Scholar
3. **Content extraction** from the pages those searches return
4. **A research agent and a `/deep-research` command** that drive a multi-stage process
5. **APA citations** of the sources the tool actually returned

![Research Workflow](./workflow.png)

The Python server speaks plain MCP over stdio, so any MCP client can use it. The opencode
pieces (`opencode.json`, `.opencode/`) and the PowerShell scripts are what make it a
one-command install on a locked-down Windows box.

## Requirements

| | |
|---|---|
| PowerShell | 7.0 or later (developed against 7.6.7) |
| Python | none installed by hand — `uv` manages it |
| Models | already available in opencode (any provider). Only needed for `-ConfigureProvider`: a Databricks workspace host and a personal access token |
| Network | HTTPS to `html.duckduckgo.com` and `api.semanticscholar.org` (see [Network](#network)) |
| Browser, search CLI | not needed — the server makes its own HTTPS requests |
| Admin rights | not needed |

The installer fetches [uv](https://docs.astral.sh/uv/) (into `%USERPROFILE%\.local\bin`)
and opencode (via scoop, npm, or the release binary into
`%LOCALAPPDATA%\Programs\opencode`) only if they are missing.

## Install

```powershell
git clone https://github.com/PieterJorissen/Claude-Deep-Research.git
cd Claude-Deep-Research
./scripts/Install-DeepResearch.ps1 -Global
```

No workspace host, no token, no provider questions: the installer sets up the server
environment, checks opencode, reports which models opencode can reach, and registers the
research tool. `-Global` puts the tool, agent, and command in `~/.config/opencode` so they
work in every project; leave it off to keep them to this repository. `-Yes` accepts the
downloads without prompting.

Then check it:

```powershell
./scripts/Test-DeepResearch.ps1
```

```
[PASS] PowerShell 7+             7.6.7
[PASS] uv on PATH                uv 0.11.32
[PASS] server environment        C:\src\Claude-Deep-Research\.venv
[PASS] MCP handshake             server 'research-assistant', tools: deep_research
[PASS] tool name in opencode     deepresearch_deep_research
[PASS] opencode on PATH          1.0.x
[PASS] model access              7 model(s), including databricks/databricks-claude-opus-4-6
[SKIP] Databricks connection     DATABRICKS_* not set - model access comes from your own opencode configuration
[PASS] reach html.duckduckgo.com HTTP 200
[PASS] reach api.semanticscholar.org HTTP 200
[PASS] opencode mcp list         deepresearch connected
```

It exits non-zero if a check fails, so it works as a smoke test. `-Quick` skips the checks
that need network access.

### If opencode has no model access yet

Only then does the installer need workspace details, and only when you ask:

```powershell
./scripts/Install-DeepResearch.ps1 -Global -ConfigureProvider -WorkspaceHost adb-1234567890.12.azuredatabricks.net
```

It prompts for a personal access token (input hidden) and adds a `databricks` provider to
your own `~/.config/opencode/opencode.json`, backing up the previous file first. It will
not overwrite an existing `databricks` provider without asking, and it leaves your default
`model` alone if you already have one. Skip this entirely if a Databricks provider is
already configured — by the Unity Gateway launcher, by your team's config, or by hand.

## Use it

```powershell
# Interactive, on the researcher agent
./scripts/Start-DeepResearch.ps1

# One-shot: runs the /deep-research command and prints the result
./scripts/Start-DeepResearch.ps1 -Topic 'room-temperature superconductors since 2023'

# Raw opencode, same thing
opencode run --command deep-research 'quantum error correction'
opencode --agent researcher
```

Inside a session:

```
/deep-research the history and cultural significance of origami
```

Or just ask, and the model reaches for the tool itself:

```
Research the latest developments in quantum computing, then write it up with citations.
```

### What ships with it

| Piece | Where | What it does |
|---|---|---|
| `deepresearch_deep_research` tool | `deep_research.py` | web + academic search, follows the top results, returns extracted content |
| `researcher` agent | `.opencode/agents/researcher.md` | search-before-answering, cite-only-what-you-saw, write reports to `research/` |
| `/deep-research` command | `.opencode/commands/deep-research.md` | the five-stage process: explore, synthesize, visualize, follow up, report |
| `deep_research` MCP prompt | `deep_research.py` | the same process for MCP clients that expose prompts |

### Tool arguments

| Argument | Default | Notes |
|---|---|---|
| `query` | required | the research question, phrased as a search query |
| `sources` | `both` | `web`, `academic`, or `both` |
| `num_results` | `2` | sources to examine, capped at `DEEP_RESEARCH_MAX_RESULTS` |

In opencode the tool is called `deepresearch_deep_research`: opencode prefixes MCP tools
with the server name from `opencode.json`.

## Configuration

`opencode.json` in the repository root registers the server and nothing else — no
provider, no `model`, no `small_model`:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "mcp": {
    "deepresearch": {
      "type": "local",
      "command": ["uv", "run", "--quiet", "--project", ".", "deep_research.py"],
      "cwd": ".",
      "timeout": 60000
    }
  }
}
```

That is deliberate. Project config outranks your global config in opencode, so a `model`
or `provider` entry here would quietly override the setup you already have whenever you
work in this directory. Model selection stays yours: pick it with `/model` in a session,
`--model provider/model` on the command line, or your own config.

To pin the research agent to one model regardless of the session default, add one line to
the frontmatter of `.opencode/agents/researcher.md`:

```yaml
model: databricks/databricks-claude-opus-4-6
```

Use the provider and endpoint names your opencode actually lists (`opencode models`).
Pay-per-token endpoints look like `databricks-claude-*`; through Unity Gateway they look
like `system.ai.claude-*`, under whatever provider id your config gives them.

### Server knobs

Set through the MCP server's `environment` block in `opencode.json`:

| Variable | Default | Effect |
|---|---|---|
| `DEEP_RESEARCH_MAX_CONTENT` | `8000` (`16000` in `opencode.json`) | character budget for a tool response |
| `DEEP_RESEARCH_MAX_RESULTS` | `3` | hard cap on `num_results` |
| `DEEP_RESEARCH_USER_AGENT` | a desktop Chrome string | User-Agent header for search and page fetches |
| `HTTPS_PROXY`, `NO_PROXY` | unset | standard proxy variables, honoured by the HTTP client |
| `SSL_CERT_FILE` | bundled CA list | CA bundle to trust, for networks that inspect TLS |

### Network

The server needs no browser and no search CLI. It makes plain HTTPS requests from Python
to exactly two hosts and parses the responses itself:

| Host | Used for |
|---|---|
| `html.duckduckgo.com` | web search results |
| `api.semanticscholar.org` | academic search results |

plus whichever result URLs it follows to extract page content. Chrome, Edge, and a
DuckDuckGo app are all irrelevant — `DEEP_RESEARCH_USER_AGENT` only sets a request
*header*, so pages serve their desktop version rather than a mobile or bot one.

On a corporate network, the two things that commonly need setting go in the MCP server's
`environment` block in `opencode.json`:

```json
"environment": {
  "HTTPS_PROXY": "http://proxy.corp.example:8080",
  "NO_PROXY": "corp.example",
  "SSL_CERT_FILE": "C:\\Users\\you\\certs\\corp-root-ca.pem"
}
```

`SSL_CERT_FILE` is for proxies that re-sign TLS: Windows usually trusts the corporate root
already, but Python ships its own CA list and does not read the Windows store. Export the
root certificate (`certmgr.msc` → Trusted Root Certification Authorities, Base-64 X.509)
and point the variable at it — no admin rights involved.

`Test-DeepResearch.ps1` probes both hosts and tells you which case you are in: blocked,
TLS-inspected, rate-limited (`429`), or served a bot challenge (`202`). The last two mean
the network is fine and the search engine is throttling this address.

### What -ConfigureProvider writes

Only relevant if you asked the installer to set up Databricks access. It writes to your own
`~/.config/opencode/opencode.json`:

```json
{
  "provider": {
    "databricks": {
      "npm": "@ai-sdk/openai-compatible",
      "options": {
        "baseURL": "https://adb-123.4.azuredatabricks.net/serving-endpoints",
        "apiKey": "{env:DATABRICKS_TOKEN}"
      },
      "models": {
        "databricks-claude-opus-4-6": { "name": "Claude Opus 4.6 (Databricks)" }
      }
    }
  }
}
```

The token is not written to the file; it is read from the environment:

| Variable | Example | Set by |
|---|---|---|
| `DATABRICKS_BASE_URL` | `https://adb-123.4.azuredatabricks.net/serving-endpoints` | installer, from `-WorkspaceHost` |
| `DATABRICKS_TOKEN` | `dapi…` | installer, prompted |

`-Scope Process` keeps both in the current shell only instead of persisting them for your
user. To keep the token out of the environment entirely, put it in a file and point the
config at it: `"apiKey": "{file:~/.databricks/opencode-token}"`. Pick the endpoint with
`-Model`, and raise `limit.context` / `limit.output` in the written block if your endpoint
allows more — those only tell opencode how to track context.

#### Databricks surfaces

The default is the OpenAI-compatible surface at `/serving-endpoints`, because its bearer
authentication is exactly what opencode's `apiKey` option sends.

Databricks also serves the native Anthropic Messages API at
`/serving-endpoints/anthropic/v1` (and `/ai-gateway/anthropic/v1` through Unity Gateway).
`-Api anthropic` configures that instead: `@ai-sdk/anthropic`, `toolStreaming: false`, and
an explicit `Authorization: Bearer` header, since the Anthropic provider would otherwise
send `x-api-key`, which Databricks rejects. That header depends on your opencode build
expanding `{env:...}` inside header values — run `Test-DeepResearch.ps1` after switching,
and fall back to the default surface if it reports 401 or 403.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `opencode: command not found` after installing | PATH changes land in new shells. Open a fresh PowerShell window. |
| Installer asks for a workspace host | You passed `-ConfigureProvider` or `-WorkspaceHost`. Leave both off to use the models opencode already has. |
| `model access` lists nothing | opencode has no provider configured. Fix that in your own opencode config, or use `-ConfigureProvider`. |
| Agent runs on the wrong model | Model selection is yours: `/model` in a session, `--model provider/model`, or a `model:` line in `.opencode/agents/researcher.md`. |
| `401` / `403` on the Databricks connection check | Only applies when `DATABRICKS_*` are set. Token expired, belongs to another workspace, or lacks access to the endpoint. |
| `404` on the Databricks connection check | Endpoint name or base URL path is wrong. Check the endpoint name in Serving and that the URL ends in `/serving-endpoints`. |
| Credentials look empty, no obvious error | `{env:...}` becomes an empty string when a variable is unset. Check 6 catches a half-set pair. |
| `deepresearch` missing from `opencode mcp list` | opencode was started outside the repository. Run it from here, or install with `-Global`. |
| MCP handshake fails | Run `uv run deep_research.py` directly — the server logs to stderr. |
| Scripts refuse to run | Per-user execution policy, no admin needed: `Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser` |
| Searches time out or return little | DuckDuckGo and Semantic Scholar both rate-limit. Narrow the query and retry. |
| `reach html.duckduckgo.com` fails with an SSL error | A TLS-inspecting proxy. Set `SSL_CERT_FILE` to your corporate root certificate (see Network). |
| `reach …` fails to connect at all | The host is blocked or needs a proxy. Set `HTTPS_PROXY` (see Network). |
| PDF sources return no content | Expected: the server reports the URL and that the text could not be extracted rather than guessing. |

## Using it from another MCP client

`deep_research.py` is a standard stdio MCP server, so any client works. Point it at:

```
uv run --project <path-to-repo> deep_research.py
```

It needs `mcp`, `httpx`, and `beautifulsoup4` (`mcp` 1.x and 2.x are both supported). For a
plain virtual environment instead of uv:

```powershell
python -m venv .venv
.venv\Scripts\python.exe -m pip install -r requirements.txt
.venv\Scripts\python.exe deep_research.py
```

## Repository layout

```
deep_research.py                     the MCP server (tool + prompt)
opencode.json                        MCP server registration (no model, no provider)
pyproject.toml / uv.lock             pinned server dependencies
requirements.txt                     same dependencies for a plain venv
AGENTS.md                            working notes for agents editing this repo
.opencode/agents/researcher.md       the research agent
.opencode/commands/deep-research.md  the /deep-research command
scripts/Install-DeepResearch.ps1     per-user install and configuration
scripts/Test-DeepResearch.ps1        diagnostics, exits non-zero on failure
scripts/Start-DeepResearch.ps1       launcher for the TUI and one-shot runs
```

## Ported from the Claude Desktop version

This started as an MCP server configured by hand in Claude Desktop's JSON config. What
changed:

- **Client**: opencode CLI instead of Claude Desktop; the server is registered in
  `opencode.json` rather than `claude_desktop_config.json`.
- **Model**: whatever opencode offers — Claude Opus on Databricks Model Serving in the
  setup this was built for. The repository deliberately configures no provider and no
  model, so it cannot override an existing opencode setup; `-ConfigureProvider` adds a
  Databricks provider for an opencode that has none.
- **Prompt**: the multi-stage research prompt became an opencode command and agent, and
  writes markdown reports to `research/` instead of Claude Desktop artifacts.
- **Install**: PowerShell 7 scripts and uv, all per-user. The server no longer shells out
  to `pip` on startup — that wrote to whichever Python it found (often needing admin) and
  printed to stdout, which is where the MCP protocol lives.
- **SDK**: works with both `mcp` 1.x (`FastMCP`) and 2.x (`MCPServer`).

## Acknowledgments

- Built on the [Model Context Protocol](https://modelcontextprotocol.io/)
- Runs in [opencode](https://opencode.ai)
- Uses [DuckDuckGo](https://duckduckgo.com/) for web search
- Uses [Semantic Scholar](https://www.semanticscholar.org/) for academic research
- Claude models served by [Databricks Model Serving](https://docs.databricks.com/aws/en/machine-learning/foundation-model-apis/)

---

Made with ❤️ for extending AI capabilities through MCP
