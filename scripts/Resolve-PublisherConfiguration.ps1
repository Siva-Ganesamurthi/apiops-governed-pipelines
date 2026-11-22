<#
.SYNOPSIS
    Replaces {#TOKEN#} placeholders in a publisher configuration with variable values.
    The APIOps CLI does not replace placeholders itself, so this runs before it.

.DESCRIPTION
    Reads the target's publisher configuration, replaces each {#NAME#} placeholder with the
    pipeline variable NAME, and writes the result outside the repository. Sets
    APIOPS_PUBLISHER_CONFIGURATION to the resolved file (or to empty when there is none).
    The bracketed form {#[NAME]#} used in the APIOps CLI documentation works too.

    Unlike a warn-and-continue token task, this script fails when:
      - a placeholder has no matching variable (the literal {#...#} would reach APIM), or
      - a placeholder is not inside double quotes (values are escaped for "..." strings).
    Placeholders on comment lines are ignored. Values are never written to the log.

    Secret variables are not visible to scripts unless mapped in the step's env: block.
    Prefer Key Vault references for secrets.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $SourcePath,
    [Parameter(Mandatory)] [string] $DestinationPath,
    [string] $TokenPrefix = '{#',
    [string] $TokenSuffix = '#}'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) {
    Write-Host "No publisher configuration at $SourcePath. Publishing without overrides."
    Write-Host '##vso[task.setvariable variable=APIOPS_PUBLISHER_CONFIGURATION]'
    return
}

$pattern = [regex]::Escape($TokenPrefix) + '\s*\[?\s*([A-Za-z0-9_.\-]+)\s*\]?\s*' + [regex]::Escape($TokenSuffix)
$tokenRegex = New-Object System.Text.RegularExpressions.Regex($pattern)
$quoteRegex = New-Object System.Text.RegularExpressions.Regex('(?<!\\)"')

$problems = New-Object System.Collections.Generic.List[string]
$resolved = New-Object System.Collections.Generic.HashSet[string]

$content = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $SourcePath).ProviderPath)
$newline = if ($content.Contains("`r`n")) { "`r`n" } else { "`n" }
$lines = $content -split "`r?`n"

for ($index = 0; $index -lt $lines.Count; $index++) {
    $line = $lines[$index]
    if ($line.TrimStart().StartsWith('#')) { continue }

    $lineNumber = $index + 1
    $lines[$index] = $tokenRegex.Replace($line, [System.Text.RegularExpressions.MatchEvaluator] {
            param($match)

            $name = $match.Groups[1].Value
            $quotesBefore = $quoteRegex.Matches($line.Substring(0, $match.Index)).Count
            if ($quotesBefore % 2 -eq 0) {
                $problems.Add("Line ${lineNumber}: placeholder $($match.Value) must be inside double quotes.")
                return $match.Value
            }

            # Azure Pipelines exposes variables to scripts in upper case with '.' replaced by '_'.
            $environmentName = $name.ToUpperInvariant().Replace('.', '_')
            $value = [Environment]::GetEnvironmentVariable($environmentName)
            if ([string]::IsNullOrEmpty($value)) {
                $problems.Add("Line ${lineNumber}: no value for $name. Add it to the variable group (secret variables must also be mapped in the step's env: block).")
                return $match.Value
            }

            [void] $resolved.Add($name)
            return $value.Replace('\', '\\').Replace('"', '\"')
        })
}

if ($problems.Count -gt 0) {
    foreach ($problem in $problems) {
        Write-Host "##vso[task.logissue type=error]$problem"
    }
    throw "Publisher configuration $SourcePath has $($problems.Count) unresolved placeholder(s). Nothing was published."
}

$destinationFolder = Split-Path -Parent $DestinationPath
if ($destinationFolder) { New-Item -ItemType Directory -Force -Path $destinationFolder | Out-Null }
[System.IO.File]::WriteAllText($DestinationPath, ($lines -join $newline), (New-Object System.Text.UTF8Encoding($false)))

Write-Host "Resolved $($resolved.Count) placeholder variable(s) in $SourcePath."
foreach ($name in ($resolved | Sort-Object)) { Write-Host "  - $name" }
Write-Host "##vso[task.setvariable variable=APIOPS_PUBLISHER_CONFIGURATION]$DestinationPath"
