#Requires -Version 7.0
<#
.SYNOPSIS
    Checks that the deep-research MCP server, opencode, and the Databricks connection work.

.DESCRIPTION
    Runs independent checks and prints one line per check. Exits 1 if any check fails, so
    it can gate a pipeline or a smoke test. Nothing here changes your configuration.

      1. PowerShell version
      2. uv and the server environment (.venv)
      3. MCP handshake over stdio: initialize, tools/list, prompts/list
      4. DATABRICKS_BASE_URL / DATABRICKS_TOKEN
      5. A one-token request to the Databricks endpoint (skipped with -Quick)
      6. opencode and its view of the configured MCP servers

.PARAMETER Quick
    Skip the checks that need network access (5 and 6).

.PARAMETER Model
    Serving endpoint to probe in check 5. Defaults to databricks-claude-opus-4-6.

.EXAMPLE
    ./scripts/Test-DeepResearch.ps1

.EXAMPLE
    ./scripts/Test-DeepResearch.ps1 -Quick
#>
[CmdletBinding()]
param(
    [switch] $Quick,
    [string] $Model = 'databricks-claude-opus-4-6'
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

$RepoRoot = Split-Path -Parent $PSScriptRoot
$script:Failures = 0

function Write-Result {
    param(
        [Parameter(Mandatory)] [ValidateSet('pass', 'fail', 'warn', 'skip')] [string] $State,
        [Parameter(Mandatory)] [string] $Check,
        [string] $Detail
    )
    $colour = @{ pass = 'Green'; fail = 'Red'; warn = 'Yellow'; skip = 'DarkGray' }[$State]
    Write-Host ("[{0,-4}] {1}" -f $State.ToUpper(), $Check) -ForegroundColor $colour
    if ($Detail) { Write-Host "         $Detail" -ForegroundColor DarkGray }
    if ($State -eq 'fail') { $script:Failures++ }
}

function Invoke-McpProbe {
    # Starts the server over stdio, runs the MCP handshake, and returns the parsed replies.
    param([int] $TimeoutMs = 90000)

    $startInfo = [Diagnostics.ProcessStartInfo]@{
        FileName               = 'uv'
        WorkingDirectory       = $RepoRoot
        RedirectStandardInput  = $true
        RedirectStandardOutput = $true
        RedirectStandardError  = $true
        UseShellExecute        = $false
    }
    foreach ($argument in @('run', '--quiet', '--project', $RepoRoot, 'deep_research.py')) {
        $startInfo.ArgumentList.Add($argument)
    }
    $startInfo.Environment['PYTHONUTF8'] = '1'
    $startInfo.Environment['PYTHONIOENCODING'] = 'utf-8'

    $process = [Diagnostics.Process]::Start($startInfo)
    try {
        $requests = @(
            '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"Test-DeepResearch","version":"1"}}}'
            '{"jsonrpc":"2.0","method":"notifications/initialized"}'
            '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
            '{"jsonrpc":"2.0","id":3,"method":"prompts/list"}'
        )
        foreach ($request in $requests) { $process.StandardInput.WriteLine($request) }
        $process.StandardInput.Flush()

        $replies = @{}
        $deadline = [datetime]::UtcNow.AddMilliseconds($TimeoutMs)
        while ($replies.Count -lt 3 -and [datetime]::UtcNow -lt $deadline) {
            $remaining = [int] ($deadline - [datetime]::UtcNow).TotalMilliseconds
            if ($remaining -le 0) { break }
            $read = $process.StandardOutput.ReadLineAsync()
            if (-not $read.Wait($remaining)) { break }
            $line = $read.Result
            if ($null -eq $line) { break }            # server closed stdout
            if (-not $line.Trim()) { continue }
            $message = $line | ConvertFrom-Json
            if ($message.PSObject.Properties.Name -contains 'id') { $replies[[int] $message.id] = $message }
        }
        return @{ Replies = $replies; Stderr = '' }
    }
    finally {
        if (-not $process.HasExited) { $process.Kill($true) }
        $process.WaitForExit(5000) | Out-Null
        $process.Dispose()
    }
}

Write-Host ''
Write-Host 'deep-research diagnostics' -ForegroundColor White
Write-Host "repository: $RepoRoot"
Write-Host ''

# 1. PowerShell ------------------------------------------------------------------------
if ($PSVersionTable.PSVersion.Major -ge 7) {
    Write-Result pass 'PowerShell 7+' "$($PSVersionTable.PSVersion)"
}
else {
    Write-Result fail 'PowerShell 7+' "found $($PSVersionTable.PSVersion); install PowerShell 7 from the Microsoft Store (no admin needed)"
}

# 2. uv and the server environment ------------------------------------------------------
$uv = Get-Command uv -ErrorAction SilentlyContinue
if ($uv) {
    Write-Result pass 'uv on PATH' "$((uv --version) -join ' ') at $($uv.Source)"
}
else {
    Write-Result fail 'uv on PATH' 'run ./scripts/Install-DeepResearch.ps1, or open a new shell if it was just installed'
}

$venv = Join-Path $RepoRoot '.venv'
if (Test-Path $venv) {
    Write-Result pass 'server environment' $venv
}
else {
    Write-Result warn 'server environment' "$venv is missing; uv creates it on first run (uv sync)"
}

# 3. MCP handshake ----------------------------------------------------------------------
if (-not $uv) {
    Write-Result skip 'MCP handshake' 'needs uv'
}
else {
    try {
        $probe = Invoke-McpProbe
        $replies = $probe.Replies
        if (-not $replies.ContainsKey(1)) {
            Write-Result fail 'MCP handshake' 'no initialize response; run "uv run deep_research.py" to see the error'
        }
        else {
            $serverName = $replies[1].result.serverInfo.name
            $tools = if ($replies.ContainsKey(2)) { @($replies[2].result.tools.name) } else { @() }
            $prompts = if ($replies.ContainsKey(3)) { @($replies[3].result.prompts.name) } else { @() }
            if ($tools -contains 'deep_research') {
                Write-Result pass 'MCP handshake' "server '$serverName', tools: $($tools -join ', '); prompts: $($prompts -join ', ')"
                Write-Result pass 'tool name in opencode' 'deepresearch_deep_research (server name "deepresearch" + tool name)'
            }
            else {
                Write-Result fail 'MCP handshake' "server answered but exposes no deep_research tool (tools: $($tools -join ', '))"
            }
        }
    }
    catch {
        Write-Result fail 'MCP handshake' $_.Exception.Message
    }
}

# 4. Databricks settings ----------------------------------------------------------------
$baseUrl = $env:DATABRICKS_BASE_URL
$token = $env:DATABRICKS_TOKEN
if ($baseUrl -and $token) {
    Write-Result pass 'Databricks settings' "$baseUrl (token: $($token.Length) characters)"
}
elseif ($baseUrl) {
    Write-Result fail 'Databricks settings' 'DATABRICKS_TOKEN is not set in this shell'
}
else {
    Write-Result fail 'Databricks settings' 'DATABRICKS_BASE_URL and DATABRICKS_TOKEN are not set; run ./scripts/Install-DeepResearch.ps1'
}

# 5. Live model call --------------------------------------------------------------------
if ($Quick) {
    Write-Result skip 'Databricks model call' '-Quick'
}
elseif (-not ($baseUrl -and $token)) {
    Write-Result skip 'Databricks model call' 'needs DATABRICKS_BASE_URL and DATABRICKS_TOKEN'
}
else {
    $isAnthropic = $baseUrl -match '/anthropic(/v1)?/?$'
    if ($isAnthropic) {
        $url = "$($baseUrl.TrimEnd('/'))/messages"
        $body = @{ model = $Model; max_tokens = 1; messages = @(@{ role = 'user'; content = 'ping' }) }
    }
    else {
        $url = "$($baseUrl.TrimEnd('/'))/chat/completions"
        $body = @{ model = $Model; max_tokens = 1; messages = @(@{ role = 'user'; content = 'ping' }) }
    }
    try {
        $response = Invoke-WebRequest -Uri $url -Method Post -TimeoutSec 90 -SkipHttpErrorCheck `
            -Headers @{ Authorization = "Bearer $token" } `
            -ContentType 'application/json' -Body ($body | ConvertTo-Json -Depth 5)
        switch ([int] $response.StatusCode) {
            200 {
                # A 200 from the wrong host would otherwise read as success, so check the shape.
                $payload = try { $response.Content | ConvertFrom-Json } catch { $null }
                $fields = if ($payload) { $payload.PSObject.Properties.Name } else { @() }
                $expected = if ($isAnthropic) { 'content' } else { 'choices' }
                if ($fields -contains $expected) {
                    Write-Result pass 'Databricks model call' "$Model answered over $(if ($isAnthropic) { 'the Messages API' } else { 'chat/completions' })"
                }
                else {
                    Write-Result warn 'Databricks model call' "$url returned 200 but no '$expected' field - is DATABRICKS_BASE_URL pointing at the serving endpoint?"
                }
            }
            401 { Write-Result fail 'Databricks model call' "401 from $url - the token is wrong, expired, or belongs to another workspace" }
            403 { Write-Result fail 'Databricks model call' "403 from $url - the token lacks access to this serving endpoint" }
            404 { Write-Result fail 'Databricks model call' "404 from $url - check the endpoint name '$Model' and the base URL path" }
            default { Write-Result fail 'Databricks model call' "HTTP $($response.StatusCode) from $url : $($response.Content -replace '\s+', ' ')" }
        }
    }
    catch {
        Write-Result fail 'Databricks model call' "$url - $($_.Exception.Message)"
    }
}

# 6. opencode ---------------------------------------------------------------------------
$opencode = Get-Command opencode -ErrorAction SilentlyContinue
if (-not $opencode) {
    Write-Result fail 'opencode on PATH' 'run ./scripts/Install-DeepResearch.ps1, or open a new shell if it was just installed'
}
else {
    Write-Result pass 'opencode on PATH' "$((opencode --version) -join ' ') at $($opencode.Source)"
    if ($Quick) {
        Write-Result skip 'opencode mcp list' '-Quick'
    }
    else {
        $job = Start-Job -ScriptBlock { Set-Location $using:RepoRoot; opencode mcp list 2>&1 | Out-String }
        if (Wait-Job $job -Timeout 120) {
            $output = (Receive-Job $job) -join "`n"
            if ($output -match 'deepresearch') {
                Write-Result pass 'opencode mcp list' ($output.Trim() -replace '\s+', ' ')
            }
            else {
                Write-Result warn 'opencode mcp list' "deepresearch not listed. Run opencode from $RepoRoot, or install globally with -Global. Output: $($output.Trim() -replace '\s+', ' ')"
            }
        }
        else {
            Write-Result warn 'opencode mcp list' 'timed out after 120s'
        }
        Remove-Job $job -Force
    }
}

Write-Host ''
if ($script:Failures -eq 0) {
    Write-Host 'All checks passed.' -ForegroundColor Green
    exit 0
}
Write-Host "$script:Failures check(s) failed." -ForegroundColor Red
exit 1
