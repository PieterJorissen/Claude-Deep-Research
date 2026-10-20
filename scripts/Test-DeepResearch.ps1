#Requires -Version 7.0
<#
.SYNOPSIS
    Checks that the deep-research MCP server works and that opencode can see it.

.DESCRIPTION
    Runs independent checks and prints one line per check. Exits 1 if any check fails, so
    it can gate a pipeline or a smoke test. Nothing here changes your configuration.

      1. PowerShell version
      2. uv and the server environment (.venv)
      3. MCP handshake over stdio: initialize, tools/list, prompts/list
      4. opencode on PATH
      5. Models opencode can reach (skipped with -Quick)
      6. Databricks connection - only when this repo's installer configured one
      7. Reachability of the two research hosts (skipped with -Quick)
      8. opencode's view of the configured MCP servers (skipped with -Quick)

    Model access is not this repository's business: if DATABRICKS_BASE_URL and
    DATABRICKS_TOKEN are not set, check 6 is skipped and check 5 reports what your own
    opencode configuration provides.

.PARAMETER Quick
    Skip the checks that need network access (5, 7 and 8).

.PARAMETER Model
    Serving endpoint to probe in check 6. Defaults to databricks-claude-opus-4-6.

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
        return $replies
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
        $replies = Invoke-McpProbe
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

# 4. opencode ---------------------------------------------------------------------------
$opencode = Get-Command opencode -ErrorAction SilentlyContinue
if ($opencode) {
    Write-Result pass 'opencode on PATH' "$((opencode --version) -join ' ') at $($opencode.Source)"
}
else {
    Write-Result fail 'opencode on PATH' 'run ./scripts/Install-DeepResearch.ps1, or open a new shell if it was just installed'
}

# 5. Model access -----------------------------------------------------------------------
# Whatever provides the models - this repo's installer, the Unity Gateway launcher, or a
# config written by hand - the research agent just uses what opencode offers.
if (-not $opencode) {
    Write-Result skip 'model access' 'needs opencode'
}
elseif ($Quick) {
    Write-Result skip 'model access' '-Quick'
}
else {
    $models = @()
    try { $models = @(opencode models 2>&1 | Where-Object { $_ -and $_ -notmatch '^\s*$' }) } catch { }
    if (-not $models) {
        Write-Result fail 'model access' "'opencode models' listed nothing - configure a provider in opencode, or run the installer with -ConfigureProvider -WorkspaceHost <host>"
    }
    else {
        $claude = @($models | Where-Object { $_ -match '(?i)claude|opus|sonnet' })
        if ($claude) {
            Write-Result pass 'model access' "$($models.Count) model(s), including $(($claude | Select-Object -First 3 | ForEach-Object { $_.Trim() }) -join ', ')"
        }
        else {
            Write-Result warn 'model access' "$($models.Count) model(s) available, none named like a Claude model"
        }
    }
}

# 6. Databricks connection (only when this repo configured one) -------------------------
$baseUrl = $env:DATABRICKS_BASE_URL
$token = $env:DATABRICKS_TOKEN
if (-not $baseUrl -and -not $token) {
    Write-Result skip 'Databricks connection' 'DATABRICKS_* not set - model access comes from your own opencode configuration (check 5)'
}
elseif (-not ($baseUrl -and $token)) {
    $missing = if ($baseUrl) { 'DATABRICKS_TOKEN' } else { 'DATABRICKS_BASE_URL' }
    Write-Result fail 'Databricks connection' "$missing is not set in this shell, but the other one is - an empty {env:...} substitution reads as an auth failure"
}
elseif ($Quick) {
    Write-Result skip 'Databricks connection' '-Quick'
}
else {
    $isAnthropic = $baseUrl -match '/anthropic(/v1)?/?$'
    $url = if ($isAnthropic) { "$($baseUrl.TrimEnd('/'))/messages" } else { "$($baseUrl.TrimEnd('/'))/chat/completions" }
    $body = @{ model = $Model; max_tokens = 1; messages = @(@{ role = 'user'; content = 'ping' }) }
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
                    Write-Result pass 'Databricks connection' "$Model answered over $(if ($isAnthropic) { 'the Messages API' } else { 'chat/completions' })"
                }
                else {
                    Write-Result warn 'Databricks connection' "$url returned 200 but no '$expected' field - is DATABRICKS_BASE_URL pointing at the serving endpoint?"
                }
            }
            401 { Write-Result fail 'Databricks connection' "401 from $url - the token is wrong, expired, or belongs to another workspace" }
            403 { Write-Result fail 'Databricks connection' "403 from $url - the token lacks access to this serving endpoint" }
            404 { Write-Result fail 'Databricks connection' "404 from $url - check the endpoint name '$Model' and the base URL path" }
            default { Write-Result fail 'Databricks connection' "HTTP $($response.StatusCode) from $url : $($response.Content -replace '\s+', ' ')" }
        }
    }
    catch {
        Write-Result fail 'Databricks connection' "$url - $($_.Exception.Message)"
    }
}

# 7. Research hosts ---------------------------------------------------------------------
# The server talks HTTPS to these two hosts directly - no browser, no search CLI. On a
# corporate network they are the usual thing to be blocked or TLS-inspected.
$researchHosts = [ordered] @{
    'html.duckduckgo.com'      = 'https://html.duckduckgo.com/html/?q=mcp+test'
    'api.semanticscholar.org'  = 'https://api.semanticscholar.org/graph/v1/paper/search?query=test&limit=1'
}
foreach ($entry in $researchHosts.GetEnumerator()) {
    if ($Quick) {
        Write-Result skip "reach $($entry.Key)" '-Quick'
        continue
    }
    try {
        $probe = Invoke-WebRequest -Uri $entry.Value -TimeoutSec 45 -SkipHttpErrorCheck -MaximumRedirection 3
        switch ([int] $probe.StatusCode) {
            200 { Write-Result pass "reach $($entry.Key)" 'HTTP 200' }
            429 { Write-Result warn "reach $($entry.Key)" '429 rate limited - reachable, but this address is being throttled right now' }
            202 { Write-Result warn "reach $($entry.Key)" '202 - reachable, but a bot challenge was served instead of results' }
            403 { Write-Result warn "reach $($entry.Key)" '403 - reachable, but the request was refused (proxy or bot filtering)' }
            default { Write-Result warn "reach $($entry.Key)" "HTTP $($probe.StatusCode)" }
        }
    }
    catch {
        $message = $_.Exception.Message
        $hint = if ($message -match 'trust|SSL|certificate|secure channel') {
            'TLS inspection: this check trusts the Windows certificate store, the server trusts SSL_CERT_FILE - set it to your proxy CA bundle (see readme, Network)'
        }
        elseif ($env:HTTPS_PROXY -or $env:https_proxy) { 'HTTPS_PROXY is set - check its address' }
        else { 'if your network needs a proxy, set HTTPS_PROXY (see readme, Network)' }
        Write-Result fail "reach $($entry.Key)" "$message - $hint"
    }
}

# 8. opencode's view of the MCP servers -------------------------------------------------
if (-not $opencode) {
    Write-Result skip 'opencode mcp list' 'needs opencode'
}
elseif ($Quick) {
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

Write-Host ''
if ($script:Failures -eq 0) {
    Write-Host 'All checks passed.' -ForegroundColor Green
    exit 0
}
Write-Host "$script:Failures check(s) failed." -ForegroundColor Red
exit 1
