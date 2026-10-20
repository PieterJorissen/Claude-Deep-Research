# Deep Research for opencode

An MCP server that gives a coding agent real research capability — web search, academic
search, link following, and content extraction — wired up for the
[opencode](https://opencode.ai) CLI running **Claude Opus on Databricks Model Serving**
(`databricks/databricks-claude-opus-4-6`).

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
| Databricks | a workspace with a Claude serving endpoint and a personal access token |
| Network | HTTPS to `html.duckduckgo.com` and `api.semanticscholar.org` (see [Network](#network)) |
| Browser, search CLI | not needed — the server makes its own HTTPS requests |
| Admin rights | not needed |

The installer fetches [uv](https://docs.astral.sh/uv/) (into `%USERPROFILE%\.local\bin`)
and opencode (via scoop, npm, or the release binary into
`%LOCALAPPDATA%\Programs\opencode`) only if they are missing.

## Install

```powershell
git clone https://github.com/pieterjorissen/claude-deep-research.git
cd claude-deep-research
./scripts/Install-DeepResearch.ps1 -WorkspaceHost adb-1234567890.12.azuredatabricks.net
```

You are prompted for your Databricks personal access token (input hidden). Pass `-Yes` to
accept the downloads without prompting, and `-Global` to register the server, agent, and
command in `~/.config/opencode` so they work in every project, not just this one.

Then check it:

```powershell
./scripts/Test-DeepResearch.ps1
```

```
[PASS] PowerShell 7+            7.6.7
[PASS] uv on PATH               uv 0.11.32
[PASS] server environment       C:\src\claude-deep-research\.venv
[PASS] MCP handshake            server 'research-assistant', tools: deep_research
[PASS] tool name in opencode    deepresearch_deep_research
[PASS] Databricks settings      https://adb-...azuredatabricks.net/serving-endpoints
[PASS] Databricks model call    databricks-claude-opus-4-6 answered over chat/completions
[PASS] opencode on PATH         1.0.x
[PASS] opencode mcp list        deepresearch connected
```

`Test-DeepResearch.ps1` exits non-zero if a check fails, so it works as a smoke test. Use
`-Quick` to skip the two checks that need network access.

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

`opencode.json` in the repository root holds all of it:

```json
{
  "model": "databricks/databricks-claude-opus-4-6",
  "provider": {
    "databricks": {
      "npm": "@ai-sdk/openai-compatible",
      "options": {
        "baseURL": "{env:DATABRICKS_BASE_URL}",
        "apiKey": "{env:DATABRICKS_TOKEN}"
      }
    }
  },
  "mcp": {
    "deepresearch": {
      "type": "local",
      "command": ["uv", "run", "--quiet", "--project", ".", "deep_research.py"]
    }
  }
}
```

No workspace details or secrets live in the file — it reads two environment variables,
which the installer sets for your user:

| Variable | Example | Set by |
|---|---|---|
| `DATABRICKS_BASE_URL` | `https://adb-123.4.azuredatabricks.net/serving-endpoints` | installer, from `-WorkspaceHost` |
| `DATABRICKS_TOKEN` | `dapi…` | installer, prompted |

`-Scope Process` keeps both in the current shell only, instead of persisting them to your
user environment. To keep the token out of the environment entirely, put it in a file and
point the config at it: `"apiKey": "{file:~/.databricks/opencode-token}"`.

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

### Choosing a different model

Change both the `model` field and the key under `provider.databricks.models` to the name of
a serving endpoint in your workspace — for example `databricks-claude-sonnet-4-5`. Model
names on the pay-per-token endpoints look like `databricks-claude-*`; through Unity Gateway
they look like `system.ai.claude-*`. `limit.context` and `limit.output` only tell opencode
how to track context; raise them if your endpoint allows more.

A cheaper endpoint for title generation and other side work:

```json
"small_model": "databricks/databricks-claude-sonnet-4-5"
```

### Databricks surfaces

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
| `401` / `403` on the model call | Token expired, belongs to another workspace, or lacks access to the endpoint. Re-run the installer with a fresh token. |
| `404` on the model call | Endpoint name or base URL path is wrong. Check the endpoint name in Serving and that the URL ends in `/serving-endpoints`. |
| Empty or missing credentials, no obvious error | `{env:...}` becomes an empty string when a variable is unset. `Test-DeepResearch.ps1` check 4 catches this. |
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
opencode.json                        model, Databricks provider, MCP server registration
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
- **Model**: Claude Opus through Databricks Model Serving, configured as a custom opencode
  provider.
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
