<#
.SYNOPSIS
    Lints every extracted OpenAPI definition with Spectral and writes JUnit results.

.DESCRIPTION
    Finds every specification.yaml / .yml / .json under the artifacts folder (including
    workspace APIs), lints them with a pinned Spectral CLI and the repository ruleset, and
    writes JUnit XML for the PublishTestResults task.

    Modes:
      advisory  Issues are reported as a warning and the step ends "succeeded with issues".
      blocking  Any issue at error severity fails the step, so no pull request is opened.

    Start with advisory, fix existing APIs, then switch to blocking.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $ArtifactsPath,
    [Parameter(Mandatory)] [string] $RulesetPath,
    [Parameter(Mandatory)] [string] $ResultsPath,
    [Parameter(Mandatory)] [string] $SpectralVersion,

    [ValidateSet('advisory', 'blocking')]
    [string] $Mode = 'advisory',

    [string] $InstallPath = (Join-Path ([System.IO.Path]::GetTempPath()) 'apiops-spectral')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$isWindowsHost = $PSVersionTable.PSEdition -eq 'Desktop' -or $IsWindows

if (-not (Test-Path -LiteralPath $ArtifactsPath -PathType Container)) {
    throw "Artifacts folder $ArtifactsPath does not exist. Did the extractor run?"
}
if (-not (Test-Path -LiteralPath $RulesetPath -PathType Leaf)) {
    throw "Spectral ruleset $RulesetPath does not exist."
}

$specifications = @(
    Get-ChildItem -LiteralPath $ArtifactsPath -Recurse -File |
        Where-Object { $_.Name -match '^specification\.(ya?ml|json)$' } |
        Sort-Object FullName |
        ForEach-Object { $_.FullName }
)

if ($specifications.Count -eq 0) {
    Write-Host 'No OpenAPI definitions were extracted, so there is nothing to lint.'
    return
}
Write-Host "Linting $($specifications.Count) API definition(s) with Spectral $SpectralVersion ($Mode mode)."

# Install a pinned Spectral CLI into a private folder (no global install needed).
$npm = if ($isWindowsHost) { 'npm.cmd' } else { 'npm' }
& $npm install --prefix $InstallPath --no-audit --no-fund --loglevel error "@stoplight/spectral-cli@$SpectralVersion"
if ($LASTEXITCODE -ne 0) {
    throw "Could not install @stoplight/spectral-cli@$SpectralVersion."
}
$spectral = Join-Path (Join-Path (Join-Path $InstallPath 'node_modules') '.bin') $(if ($isWindowsHost) { 'spectral.cmd' } else { 'spectral' })

$resultsFolder = Split-Path -Parent $ResultsPath
if ($resultsFolder) { New-Item -ItemType Directory -Force -Path $resultsFolder | Out-Null }
if (Test-Path -LiteralPath $ResultsPath) { Remove-Item -LiteralPath $ResultsPath -Force }

$arguments = @('lint') + $specifications + @(
    '--ruleset', $RulesetPath,
    '--fail-severity', 'error',
    '--format', 'stylish',
    '--format', 'junit',
    '--output.junit', $ResultsPath
)
& $spectral @arguments
$exitCode = $LASTEXITCODE

if (-not (Test-Path -LiteralPath $ResultsPath -PathType Leaf)) {
    throw "Spectral did not produce results (exit code $exitCode). Check the ruleset and the output above."
}

[xml] $junit = Get-Content -LiteralPath $ResultsPath -Raw
$failures = 0
foreach ($suite in $junit.SelectNodes('//testsuite')) {
    $value = $suite.GetAttribute('failures')
    if ($value) { $failures += [int] $value }
}

if ($exitCode -eq 0) {
    Write-Host 'Spectral found no error-severity issues. Any warnings are listed above.'
    return
}

$message = "Spectral found $failures error-severity issue(s) in the API definitions. See the Tests tab."
if ($Mode -eq 'blocking') {
    Write-Host "##vso[task.logissue type=error]$message"
    exit 1
}

Write-Host "##vso[task.logissue type=warning]$message"
Write-Host '##vso[task.complete result=SucceededWithIssues;]Lint issues found (advisory mode).'
exit 0
