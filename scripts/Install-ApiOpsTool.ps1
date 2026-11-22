<#
.SYNOPSIS
    Installs a pinned version of the APIOps CLI (@azure-tools/apiops-cli) from npm.

.DESCRIPTION
    Installs the CLI into a private folder (no global install), checks that it runs, and sets
    APIOPS_CLI_PATH for the following steps. The CLI itself is never modified: upgrading means
    changing APIOPS_CLI_VERSION. Needs Node.js 22 or later on the agent (see NODE_VERSION).

.EXAMPLE
    ./Install-ApiOpsTool.ps1 -Version 1.0.5 -DestinationPath ./tools/apiops-cli
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $Version,

    [Parameter(Mandatory)]
    [string] $DestinationPath,

    [string] $PackageName = '@azure-tools/apiops-cli'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# A pinned version keeps every run reproducible; 'latest' would change under you.
if ($Version -notmatch '^\d+\.\d+\.\d+(-[0-9A-Za-z.\-]+)?$') {
    throw "APIOPS_CLI_VERSION '$Version' must be an exact version such as 1.0.5, not a range or 'latest'."
}

$isWindowsHost = $PSVersionTable.PSEdition -eq 'Desktop' -or $IsWindows
$npm = if ($isWindowsHost) { 'npm.cmd' } else { 'npm' }

if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    throw 'Node.js was not found. The APIOps CLI needs Node.js 22 or later (NodeTool task, NODE_VERSION).'
}
$nodeVersion = & node --version
if ([int](($nodeVersion -replace '^v', '') -split '\.')[0] -lt 22) {
    throw "The APIOps CLI needs Node.js 22 or later. This agent has $nodeVersion. Check NODE_VERSION."
}

New-Item -ItemType Directory -Force -Path $DestinationPath | Out-Null

Write-Host "Installing $PackageName@$Version with Node.js $nodeVersion"
$maxAttempts = 3
for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
    & $npm install --prefix $DestinationPath --no-audit --no-fund --loglevel error "$PackageName@$Version"
    if ($LASTEXITCODE -eq 0) { break }
    if ($attempt -eq $maxAttempts) {
        throw "Could not install $PackageName@$Version after $maxAttempts attempts. Check that APIOPS_CLI_VERSION is a published version."
    }
    Write-Host "npm install failed (attempt $attempt of $maxAttempts). Retrying..."
    Start-Sleep -Seconds (5 * $attempt)
}

$binFolder = Join-Path (Join-Path $DestinationPath 'node_modules') '.bin'
$cliPath = Join-Path $binFolder $(if ($isWindowsHost) { 'apiops.cmd' } else { 'apiops' })
if (-not (Test-Path -LiteralPath $cliPath -PathType Leaf)) {
    throw "The package installed, but $cliPath was not found."
}

$installed = (& $cliPath --version) 2>&1 | Select-Object -Last 1
if ($LASTEXITCODE -ne 0) {
    throw "The APIOps CLI was installed but does not run: $installed"
}

Write-Host "Installed APIOps CLI $installed at $cliPath"
Write-Host "##vso[task.setvariable variable=APIOPS_CLI_PATH]$cliPath"
