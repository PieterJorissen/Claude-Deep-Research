#Requires -Version 7.0
<#
.SYNOPSIS
    Starts opencode with the research agent and the deep-research MCP server.

.DESCRIPTION
    A thin wrapper around the opencode CLI that runs from the repository, so the project
    opencode.json (the MCP server registration) and .opencode (the researcher agent and
    the /deep-research command) apply. Model selection is left to your opencode
    configuration; pass -Model to override it for one run.

    With -Topic it runs the /deep-research command non-interactively and prints the result.
    Without -Topic it opens the opencode TUI on the researcher agent.

.PARAMETER Topic
    Research topic. Runs /deep-research <topic> and exits.

.PARAMETER Model
    Model override in provider/model form, e.g. databricks/databricks-claude-opus-4-6.
    Defaults to whatever your opencode configuration selects.

.PARAMETER Agent
    Agent to use. Defaults to 'researcher'.

.PARAMETER Resume
    Continue the previous session instead of starting a new one.

.PARAMETER Json
    Emit raw JSON events instead of formatted output (non-interactive runs only).

.EXAMPLE
    ./scripts/Start-DeepResearch.ps1

.EXAMPLE
    ./scripts/Start-DeepResearch.ps1 -Topic 'room-temperature superconductors since 2023'

.EXAMPLE
    ./scripts/Start-DeepResearch.ps1 -Topic 'origami in mathematics education' -Json > run.jsonl
#>
[CmdletBinding()]
param(
    [string] $Topic,
    [string] $Model,
    [string] $Agent = 'researcher',
    [switch] $Resume,
    [switch] $Json
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

$RepoRoot = Split-Path -Parent $PSScriptRoot

if (-not (Get-Command opencode -ErrorAction SilentlyContinue)) {
    throw 'opencode is not on PATH. Run ./scripts/Install-DeepResearch.ps1 (or open a new shell if it was just installed).'
}
# Model access belongs to your opencode configuration, so nothing is required here. Only
# a half-configured pair of variables is worth warning about: an empty {env:...}
# substitution surfaces later as an authentication failure.
if (($env:DATABRICKS_BASE_URL -and -not $env:DATABRICKS_TOKEN) -or ($env:DATABRICKS_TOKEN -and -not $env:DATABRICKS_BASE_URL)) {
    Write-Warning 'Only one of DATABRICKS_BASE_URL / DATABRICKS_TOKEN is set. If your opencode provider reads them, it will fail to authenticate.'
}

$arguments = @()
if ($Topic) {
    $arguments += @('run', '--command', 'deep-research')
    if ($Json) { $arguments += @('--format', 'json') }
}
$arguments += @('--agent', $Agent)
if ($Model) { $arguments += @('--model', $Model) }
if ($Resume) { $arguments += '--continue' }
if ($Topic) { $arguments += $Topic }

Push-Location $RepoRoot
try {
    Write-Host "opencode $($arguments -join ' ')" -ForegroundColor DarkGray
    & opencode @arguments
    $code = $LASTEXITCODE
}
finally { Pop-Location }

exit $code
