#Requires -Version 7.0
<#
.SYNOPSIS
    Starts opencode with the research agent and the deep-research MCP server.

.DESCRIPTION
    A thin wrapper around the opencode CLI that checks the Databricks settings first and
    runs from the repository, so the project opencode.json (provider, MCP server, agent,
    /deep-research command) applies.

    With -Topic it runs the /deep-research command non-interactively and prints the result.
    Without -Topic it opens the opencode TUI on the researcher agent.

.PARAMETER Topic
    Research topic. Runs /deep-research <topic> and exits.

.PARAMETER Model
    Model override in provider/model form. Defaults to the one in opencode.json.

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
if (-not $env:DATABRICKS_BASE_URL -or -not $env:DATABRICKS_TOKEN) {
    throw 'DATABRICKS_BASE_URL and DATABRICKS_TOKEN are not both set in this shell. Run ./scripts/Install-DeepResearch.ps1, then open a new shell.'
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
