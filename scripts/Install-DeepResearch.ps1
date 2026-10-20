#Requires -Version 7.0
<#
.SYNOPSIS
    Installs the deep-research MCP server for the opencode CLI, for the current user.

.DESCRIPTION
    By default this sets up the research capability only and leaves model access alone:
    opencode keeps whatever providers and models it already has, and the research agent
    runs on the model you select in opencode.

    Everything it installs lands under the user profile - no administrator rights, no
    system Python, no system PATH changes:

      uv        -> %USERPROFILE%\.local\bin        (if missing)
      opencode  -> scoop / npm prefix / %LOCALAPPDATA%\Programs\opencode (if missing)
      .venv     -> <repo>\.venv                    (created by uv sync)

    Use -ConfigureProvider only if opencode cannot reach Databricks models yet; it adds a
    "databricks" provider to your own opencode config. Skip it when a Databricks provider
    is already configured (for example by the Unity Gateway launcher) - this script will
    not touch a working setup.

.PARAMETER Global
    Register the research server, the researcher agent, and the /deep-research command in
    ~/.config/opencode so they work in every project, not just this repository.

.PARAMETER ConfigureProvider
    Add a Databricks provider to your opencode config. Needs -WorkspaceHost; prompts for a
    personal access token if -Token and DATABRICKS_TOKEN are both absent.

.PARAMETER WorkspaceHost
    Databricks workspace host, with or without the scheme, e.g.
    adb-1234567890.12.azuredatabricks.net. Only used with -ConfigureProvider.

.PARAMETER Token
    Databricks personal access token. Only used with -ConfigureProvider.

.PARAMETER Model
    Serving endpoint to register with -ConfigureProvider. Defaults to
    databricks-claude-opus-4-6.

.PARAMETER Api
    Which Databricks surface -ConfigureProvider should target: 'openai' (default,
    /serving-endpoints, bearer auth) or 'anthropic' (/serving-endpoints/anthropic/v1).

.PARAMETER Scope
    Where -ConfigureProvider keeps its environment variables: 'User' (default, persists in
    HKCU) or 'Process' (this shell only).

.EXAMPLE
    ./scripts/Install-DeepResearch.ps1
    Sets up the research server for this repository, using opencode's existing models.

.EXAMPLE
    ./scripts/Install-DeepResearch.ps1 -Global
    Same, and makes the tool, agent, and command available in every project.

.EXAMPLE
    ./scripts/Install-DeepResearch.ps1 -ConfigureProvider -WorkspaceHost adb-123.4.azuredatabricks.net
    Also adds a Databricks provider, for an opencode that has no model access yet.
#>
[CmdletBinding()]
param(
    [switch] $Global,
    [switch] $ConfigureProvider,
    [string] $WorkspaceHost,
    [string] $Token,
    [string] $Model = 'databricks-claude-opus-4-6',
    [ValidateSet('openai', 'anthropic')] [string] $Api = 'openai',
    [ValidateSet('User', 'Process')] [string] $Scope = 'User',
    [switch] $SkipOpencode,
    [switch] $SkipPython,
    [switch] $Yes
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
# PowerShell 7.4+ turns a non-zero exit code from a native command into a terminating
# error; this script inspects $LASTEXITCODE itself so it can retry and explain.
$PSNativeCommandUseErrorActionPreference = $false

$RepoRoot = Split-Path -Parent $PSScriptRoot

function Write-Step { param([string] $Message) Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Ok { param([string] $Message) Write-Host "    $Message" -ForegroundColor Green }
function Write-Note { param([string] $Message) Write-Host "    $Message" -ForegroundColor DarkGray }

function Confirm-Action {
    param([string] $Message)
    if ($Yes) { return $true }
    $answer = Read-Host "$Message [y/N]"
    return $answer -match '^(y|yes)$'
}

function Add-UserPath {
    # Appends a directory to the user's PATH (HKCU) and to this session.
    param([Parameter(Mandatory)] [string] $Directory)

    $current = [Environment]::GetEnvironmentVariable('Path', 'User')
    $entries = @()
    if ($current) { $entries = $current -split ';' | Where-Object { $_ } }
    if ($entries -notcontains $Directory) {
        [Environment]::SetEnvironmentVariable('Path', (@($entries + $Directory) -join ';'), 'User')
        Write-Ok "Added $Directory to your user PATH (new shells pick it up)."
    }
    if (($env:Path -split ';') -notcontains $Directory) { $env:Path = "$env:Path;$Directory" }
}

function Get-OpencodeConfigDirectory {
    $configHome = if ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME } else { Join-Path $env:USERPROFILE '.config' }
    return Join-Path $configHome 'opencode'
}

function Resolve-BaseUrl {
    param([Parameter(Mandatory)] [string] $HostName, [Parameter(Mandatory)] [string] $Surface)

    $trimmed = $HostName.Trim().TrimEnd('/')
    if ($trimmed -notmatch '^https?://') { $trimmed = "https://$trimmed" }
    $uri = [uri] $trimmed
    $suffix = if ($Surface -eq 'anthropic') { '/serving-endpoints/anthropic/v1' } else { '/serving-endpoints' }
    return "https://$($uri.Host)$suffix"
}

function Get-ModelDisplayName {
    # databricks-claude-opus-4-6 -> "Claude Opus 4.6 (Databricks)"
    param([Parameter(Mandatory)] [string] $EndpointName)

    $parts = ($EndpointName -replace '^databricks-', '') -split '-'
    $words = foreach ($part in $parts) {
        if ($part -match '^\d+$') { $part } else { (Get-Culture).TextInfo.ToTitleCase($part) }
    }
    $label = ($words -join ' ') -replace '(\d+) (\d+)', '$1.$2'
    return "$label (Databricks)"
}

function Install-Uv {
    Write-Step 'Checking uv (Python runtime and dependency manager)'
    if (Get-Command uv -ErrorAction SilentlyContinue) {
        Write-Ok "uv found: $((uv --version) -join ' ')"
        return
    }
    if (-not (Confirm-Action 'uv is not installed. Download and install it for this user from astral.sh?')) {
        throw 'uv is required. Install it manually (https://docs.astral.sh/uv/) and re-run.'
    }
    # Astral's installer is per-user: it writes to %USERPROFILE%\.local\bin, no elevation.
    $installer = Invoke-RestMethod -Uri 'https://astral.sh/uv/install.ps1'
    Invoke-Expression $installer
    Add-UserPath (Join-Path $env:USERPROFILE '.local\bin')
    if (-not (Get-Command uv -ErrorAction SilentlyContinue)) {
        throw 'uv was installed but is not on PATH yet. Open a new PowerShell window and re-run this script.'
    }
    Write-Ok "uv installed: $((uv --version) -join ' ')"
}

function Install-PythonEnvironment {
    Write-Step 'Creating the server environment (.venv) from uv.lock'
    Push-Location $RepoRoot
    try {
        uv sync --frozen
        if ($LASTEXITCODE -ne 0) {
            Write-Note 'uv sync --frozen failed; retrying without the lockfile constraint.'
            uv sync
            if ($LASTEXITCODE -ne 0) { throw 'uv sync failed. See the output above.' }
        }
    }
    finally { Pop-Location }
    Write-Ok "Dependencies installed into $(Join-Path $RepoRoot '.venv')"
}

function Install-Opencode {
    Write-Step 'Checking the opencode CLI'
    if (Get-Command opencode -ErrorAction SilentlyContinue) {
        Write-Ok "opencode found: $((opencode --version) -join ' ')"
        return
    }

    if (Get-Command scoop -ErrorAction SilentlyContinue) {
        if (Confirm-Action 'Install opencode with scoop (per-user, no admin)?') {
            scoop install opencode
            if (Get-Command opencode -ErrorAction SilentlyContinue) {
                Write-Ok "opencode installed: $((opencode --version) -join ' ')"
                return
            }
            Write-Note 'scoop did not produce an opencode on PATH; trying the next method.'
        }
    }

    if (Get-Command npm -ErrorAction SilentlyContinue) {
        if (Confirm-Action 'Install opencode with npm install -g opencode-ai (installs into your npm prefix, no admin)?') {
            npm install -g opencode-ai
            $npmPrefix = (npm config get prefix) -join ''
            if ($npmPrefix) { Add-UserPath $npmPrefix.Trim() }
            if (Get-Command opencode -ErrorAction SilentlyContinue) {
                Write-Ok "opencode installed: $((opencode --version) -join ' ')"
                return
            }
            Write-Note 'npm did not produce an opencode on PATH; trying the release binary.'
        }
    }

    if (-not (Confirm-Action 'Download the opencode release binary into %LOCALAPPDATA%\Programs\opencode?')) {
        throw 'opencode is required. Install it from https://opencode.ai/docs/ and re-run with -SkipOpencode.'
    }

    $arch = if ($env:PROCESSOR_ARCHITECTURE -match 'ARM64') { 'arm64' } else { 'x64' }
    $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/anomalyco/opencode/releases/latest' -Headers @{ 'User-Agent' = 'deep-research-installer' }
    $asset = $release.assets |
        Where-Object { $_.name -match '(?i)win' -and $_.name -match "(?i)($arch|amd64)" -and $_.name -match '(?i)\.zip$' } |
        Select-Object -First 1
    if (-not $asset) {
        throw "No Windows $arch zip in opencode release $($release.tag_name). Install opencode manually: https://opencode.ai/docs/"
    }

    $target = Join-Path $env:LOCALAPPDATA 'Programs\opencode'
    $zip = Join-Path ([IO.Path]::GetTempPath()) $asset.name
    Write-Note "Downloading $($asset.name) ($($release.tag_name))"
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zip
    New-Item -ItemType Directory -Force -Path $target | Out-Null
    Expand-Archive -Path $zip -DestinationPath $target -Force
    Remove-Item $zip -Force

    $exe = Get-ChildItem -Path $target -Filter 'opencode.exe' -Recurse | Select-Object -First 1
    if (-not $exe) { throw "The archive did not contain opencode.exe. Check $target." }
    Add-UserPath $exe.Directory.FullName
    Write-Ok "opencode installed: $((opencode --version) -join ' ')"
}

function Show-AvailableModels {
    # Model access belongs to the user's opencode setup, so report what it has rather
    # than configuring anything.
    Write-Step "Checking which models opencode can reach"
    if (-not (Get-Command opencode -ErrorAction SilentlyContinue)) {
        Write-Note 'opencode is not on PATH yet, so its model list cannot be read.'
        return
    }

    $listed = @()
    try { $listed = @(opencode models 2>&1 | Where-Object { $_ -and $_ -notmatch '^\s*$' }) }
    catch { Write-Note "Could not run 'opencode models': $($_.Exception.Message)"; return }
    if ($LASTEXITCODE -ne 0 -or -not $listed) {
        Write-Note "'opencode models' returned nothing. Check your opencode provider configuration."
        Write-Note 'If opencode has no Databricks access yet, re-run with -ConfigureProvider -WorkspaceHost <host>.'
        return
    }

    $claude = @($listed | Where-Object { $_ -match '(?i)claude|opus|sonnet' })
    if ($claude) {
        Write-Ok "$($listed.Count) model(s) available, including:"
        foreach ($entry in ($claude | Select-Object -First 8)) { Write-Host "      $($entry.Trim())" -ForegroundColor DarkGray }
        if ($claude.Count -gt 8) { Write-Note "...and $($claude.Count - 8) more Claude models" }
        Write-Note 'The research agent runs on whichever of these you select in opencode (/model, or --model).'
    }
    else {
        Write-Ok "$($listed.Count) model(s) available, none of them Claude by name."
        Write-Note 'If opencode has no Databricks access yet, re-run with -ConfigureProvider -WorkspaceHost <host>.'
    }
}

function Register-ResearchServer {
    # Makes the tool, agent, and command available outside this repository. Only the
    # research entries are written; everything else in the config is left alone.
    Write-Step 'Registering the research server globally (~/.config/opencode)'
    $openCodeDir = Get-OpencodeConfigDirectory
    $configPath = Join-Path $openCodeDir 'opencode.json'
    New-Item -ItemType Directory -Force -Path $openCodeDir | Out-Null

    $config = @{}
    if (Test-Path $configPath) {
        Copy-Item $configPath "$configPath.bak" -Force
        $raw = Get-Content $configPath -Raw
        if ($raw.Trim()) { $config = $raw | ConvertFrom-Json -AsHashtable }
        Write-Note "Existing config backed up to $configPath.bak"
    }

    if (-not $config.ContainsKey('$schema')) { $config['$schema'] = 'https://opencode.ai/config.json' }
    if (-not $config.ContainsKey('mcp')) { $config['mcp'] = @{} }
    $config['mcp']['deepresearch'] = @{
        type        = 'local'
        command     = @('uv', 'run', '--quiet', '--project', $RepoRoot, (Join-Path $RepoRoot 'deep_research.py'))
        cwd         = $RepoRoot
        enabled     = $true
        timeout     = 60000
        environment = @{ PYTHONUTF8 = '1'; PYTHONIOENCODING = 'utf-8'; DEEP_RESEARCH_MAX_CONTENT = '16000' }
    }
    $config | ConvertTo-Json -Depth 20 | Set-Content -Path $configPath -Encoding utf8
    Write-Ok "Registered the deepresearch server in $configPath"
    Write-Note 'No model or provider entries were added or changed.'

    foreach ($kind in @('agents', 'commands')) {
        $source = Join-Path $RepoRoot ".opencode/$kind"
        if (-not (Test-Path $source)) { continue }
        $destination = Join-Path $openCodeDir $kind
        New-Item -ItemType Directory -Force -Path $destination | Out-Null
        Copy-Item (Join-Path $source '*.md') $destination -Force
        Write-Ok "Copied $kind into $destination"
    }
}

function Register-DatabricksProvider {
    param([Parameter(Mandatory)] [string] $BaseUrl, [Parameter(Mandatory)] [string] $AccessToken)

    Write-Step "Setting the Databricks connection variables ($Scope scope)"
    $values = @{ DATABRICKS_BASE_URL = $BaseUrl; DATABRICKS_TOKEN = $AccessToken }
    foreach ($name in $values.Keys) {
        Set-Item -Path "Env:$name" -Value $values[$name]
        if ($Scope -eq 'User') { [Environment]::SetEnvironmentVariable($name, $values[$name], 'User') }
    }
    Write-Ok "DATABRICKS_BASE_URL = $BaseUrl"
    Write-Ok "DATABRICKS_TOKEN    = (set, $($AccessToken.Length) characters)"
    if ($Scope -eq 'User') {
        Write-Note 'The token is stored in your own environment (HKCU\Environment). Use -Scope Process to keep it in this shell only.'
    }

    Write-Step 'Adding the databricks provider to your opencode config'
    $openCodeDir = Get-OpencodeConfigDirectory
    $configPath = Join-Path $openCodeDir 'opencode.json'
    New-Item -ItemType Directory -Force -Path $openCodeDir | Out-Null

    $config = @{}
    if (Test-Path $configPath) {
        Copy-Item $configPath "$configPath.bak" -Force
        $raw = Get-Content $configPath -Raw
        if ($raw.Trim()) { $config = $raw | ConvertFrom-Json -AsHashtable }
        Write-Note "Existing config backed up to $configPath.bak"
    }
    if ($config.ContainsKey('provider') -and $config['provider'].ContainsKey('databricks')) {
        if (-not (Confirm-Action 'Your config already has a "databricks" provider. Overwrite it?')) {
            Write-Note 'Left the existing provider untouched.'
            return
        }
    }

    $modelEntry = @{
        name  = Get-ModelDisplayName -EndpointName $Model
        limit = @{ context = 200000; output = 64000 }
    }
    $options = @{ baseURL = $BaseUrl; apiKey = '{env:DATABRICKS_TOKEN}' }
    if ($Api -eq 'anthropic') {
        # The AI SDK Anthropic provider authenticates with x-api-key, which Databricks
        # does not accept, so the bearer header is set explicitly - and Databricks asks
        # for tool streaming to be off on this surface.
        $options['headers'] = @{ Authorization = 'Bearer {env:DATABRICKS_TOKEN}' }
        $modelEntry['options'] = @{ toolStreaming = $false }
    }

    if (-not $config.ContainsKey('$schema')) { $config['$schema'] = 'https://opencode.ai/config.json' }
    if (-not $config.ContainsKey('provider')) { $config['provider'] = @{} }
    $config['provider']['databricks'] = @{
        npm     = if ($Api -eq 'anthropic') { '@ai-sdk/anthropic' } else { '@ai-sdk/openai-compatible' }
        name    = 'Databricks Model Serving'
        options = $options
        models  = @{ $Model = $modelEntry }
    }
    if (-not $config.ContainsKey('model')) {
        $config['model'] = "databricks/$Model"
        Write-Note "Set your default model to databricks/$Model (there was none)."
    }
    elseif ($config['model'] -ne "databricks/$Model") {
        Write-Note "Left your default model as $($config['model']); select databricks/$Model with /model when you want it."
    }
    $config | ConvertTo-Json -Depth 20 | Set-Content -Path $configPath -Encoding utf8
    Write-Ok "Wrote the databricks provider to $configPath"
}

# --- run -----------------------------------------------------------------------------

Write-Host ''
Write-Host 'deep-research for opencode - per-user install' -ForegroundColor White
Write-Host "repository: $RepoRoot"
Write-Host ''

if ($WorkspaceHost -and -not $ConfigureProvider) {
    Write-Note '-WorkspaceHost was given, so also configuring the Databricks provider (-ConfigureProvider implied).'
    $ConfigureProvider = $true
}

$baseUrl = $null
if ($ConfigureProvider) {
    if (-not $WorkspaceHost) {
        $WorkspaceHost = Read-Host 'Databricks workspace host (e.g. adb-123.4.azuredatabricks.net)'
        if (-not $WorkspaceHost) { throw 'A workspace host is required with -ConfigureProvider. Omit it to use the models opencode already has.' }
    }
    $baseUrl = Resolve-BaseUrl -HostName $WorkspaceHost -Surface $Api

    if (-not $Token) {
        if ($env:DATABRICKS_TOKEN) {
            $Token = $env:DATABRICKS_TOKEN
            Write-Note 'Using DATABRICKS_TOKEN from the environment.'
        }
        else {
            $secure = Read-Host 'Databricks personal access token (input hidden)' -AsSecureString
            $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
            try { $Token = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
            finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
        }
    }
    if (-not $Token) { throw 'A Databricks personal access token is required with -ConfigureProvider.' }
}

Install-Uv
if (-not $SkipPython) { Install-PythonEnvironment } else { Write-Note 'Skipping the Python environment (-SkipPython).' }
if (-not $SkipOpencode) { Install-Opencode } else { Write-Note 'Skipping opencode (-SkipOpencode).' }
if ($Global) { Register-ResearchServer }
if ($ConfigureProvider) { Register-DatabricksProvider -BaseUrl $baseUrl -AccessToken $Token }
else { Show-AvailableModels }

Write-Host ''
Write-Step 'Done. Next steps'
Write-Host "    1. Verify everything:  ./scripts/Test-DeepResearch.ps1"
Write-Host "    2. Start researching:  ./scripts/Start-DeepResearch.ps1 -Topic 'quantum error correction'"
Write-Host "    3. Or open the TUI:    opencode --agent researcher"
Write-Host ''
if (-not $Global) {
    Write-Note 'The research tool is registered for this repository. Re-run with -Global to use it in every project.'
}
if ($ConfigureProvider -and $Api -eq 'anthropic') {
    Write-Host '    Note: the Anthropic surface needs opencode to expand {env:...} inside header values.' -ForegroundColor Yellow
    Write-Host '          If Test-DeepResearch.ps1 reports 401/403, re-run the installer without -Api anthropic.' -ForegroundColor Yellow
}
if ($Scope -eq 'User' -and $ConfigureProvider) { Write-Note 'Open a fresh PowerShell window if a tool still reports a missing variable or command.' }
Write-Host ''
