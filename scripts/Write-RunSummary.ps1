<#
.SYNOPSIS
    Adds a short markdown summary to the run's Summary tab.

.DESCRIPTION
    Shows the target, the mode and, for extractions, how many resources of each type were
    extracted, so reviewers see the scope before opening the pull request diff.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Extract', 'Publish')]
    [string] $Operation,

    [Parameter(Mandatory)] [string] $Region,
    [Parameter(Mandatory)] [string] $Environment,
    [string] $ServiceName = '',
    [string] $ArtifactsPath = '',
    [string] $PublishMode = '',
    [string] $DryRun = 'False',
    [string] $CommitId = '',
    [string] $OutputPath = (Join-Path ([System.IO.Path]::GetTempPath()) 'apiops-summary.md')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Format-Value([string] $Value) {
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value -match '^\$\([^)]*\)$') { return '-' }
    return $Value
}

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add("## APIOps $($Operation.ToLowerInvariant()): $Region / $Environment")
$lines.Add('')
$lines.Add('| | |')
$lines.Add('|---|---|')
$lines.Add("| APIM instance | $(Format-Value $ServiceName) |")

if ($Operation -eq 'Publish') {
    $isDryRun = $false
    [void] [bool]::TryParse($DryRun, [ref]$isDryRun)
    $lines.Add("| Mode | $(Format-Value $PublishMode) |")
    $lines.Add("| Dry run | $(if ($isDryRun) { 'Yes - nothing was changed' } else { 'No' }) |")
    $lines.Add("| Commit | $(Format-Value $CommitId) |")
}

if ($Operation -eq 'Extract' -and $ArtifactsPath -and (Test-Path -LiteralPath $ArtifactsPath -PathType Container)) {
    $lines.Add('')
    $lines.Add('### Extracted resources')
    $lines.Add('')
    $lines.Add('| Type | Count |')
    $lines.Add('|---|---|')

    $folders = @(Get-ChildItem -LiteralPath $ArtifactsPath -Directory | Sort-Object Name)
    foreach ($folder in $folders) {
        $count = @(Get-ChildItem -LiteralPath $folder.FullName -Directory).Count
        $lines.Add("| $($folder.Name) | $count |")
    }
    if (Test-Path -LiteralPath (Join-Path $ArtifactsPath 'policy.xml')) {
        $lines.Add('| global policy | 1 |')
    }
    if ($folders.Count -eq 0) {
        $lines.Add('| (nothing extracted) | 0 |')
    }

    $apisPath = Join-Path $ArtifactsPath 'apis'
    if (Test-Path -LiteralPath $apisPath) {
        $apis = @(Get-ChildItem -LiteralPath $apisPath -Directory | Sort-Object Name | ForEach-Object { $_.Name })
        if ($apis.Count -gt 0) {
            $lines.Add('')
            $lines.Add("**APIs:** $(($apis | Select-Object -First 50) -join ', ')$(if ($apis.Count -gt 50) { ', ...' })")
        }
    }
}

$outputFolder = Split-Path -Parent $OutputPath
if ($outputFolder) { New-Item -ItemType Directory -Force -Path $outputFolder | Out-Null }
[System.IO.File]::WriteAllText($OutputPath, ($lines -join "`n") + "`n", (New-Object System.Text.UTF8Encoding($false)))

Write-Host ($lines -join "`n")
Write-Host "##vso[task.uploadsummary]$OutputPath"
