<#
.SYNOPSIS
    Checks that a publish run is safe and will actually publish something.

.DESCRIPTION
    - Release-branch guard: outside Development, only runs queued from the release branch
      may publish. Pair this with a Branch control check on the Azure DevOps environment.
    - The artifacts folder must exist (run the extractor and merge its pull request first).
    - In 'changes-in-latest-commit' mode, warns when the latest commit changed nothing under
      the artifacts folder. The CLI would then publish nothing, which is easy to mistake for
      a successful deployment.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $RepositoryPath,
    [string] $ArtifactsFolder = 'apim-artifacts',

    [Parameter(Mandatory)]
    [ValidateSet('changes-in-latest-commit', 'all-artifacts')]
    [string] $Mode,

    [Parameter(Mandatory)] [string] $SourceBranch,
    [string] $ReleaseBranch = 'main',
    [string] $EnforceReleaseBranch = 'True'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-Git {
    $gitArguments = $args
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $output = & git @gitArguments 2>&1 | ForEach-Object { "$_" } }
    finally { $ErrorActionPreference = $previous }
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = @($output) }
}

$enforce = $false
if (-not [bool]::TryParse($EnforceReleaseBranch, [ref]$enforce)) {
    throw "EnforceReleaseBranch must be True or False, not '$EnforceReleaseBranch'."
}

$expectedRef = "refs/heads/$ReleaseBranch"
if ($enforce -and $SourceBranch -ne $expectedRef) {
    Write-Host "##vso[task.logissue type=error]Publishing to this environment is only allowed from '$ReleaseBranch'. This run was queued from '$SourceBranch'."
    exit 1
}
Write-Host "Branch check passed ($SourceBranch)."

$artifactsPath = Join-Path $RepositoryPath $ArtifactsFolder
if (-not (Test-Path -LiteralPath $artifactsPath -PathType Container)) {
    Write-Host "##vso[task.logissue type=error]There is no '$ArtifactsFolder' folder on this branch yet. Run the extractor and merge its pull request first."
    exit 1
}

if ($Mode -eq 'all-artifacts') {
    Write-Host "Mode: all artifacts. Every file under $ArtifactsFolder/ will be published (nothing is deleted in APIM)."
    return
}

$head = Invoke-Git -C $RepositoryPath rev-parse --short HEAD
$parent = Invoke-Git -C $RepositoryPath rev-parse --verify --quiet 'HEAD~1'
if ($parent.ExitCode -ne 0) {
    Write-Host "Commit $($head.Output -join '') has no parent. Every artifact will be published as new."
    return
}

$diff = Invoke-Git -C $RepositoryPath diff --name-status 'HEAD~1' HEAD -- $ArtifactsFolder
if ($diff.ExitCode -ne 0) {
    throw "git diff failed: $($diff.Output -join "`n")"
}
$changes = @($diff.Output | Where-Object { $_ })

if ($changes.Count -eq 0) {
    $message = "The latest commit ($($head.Output -join '')) changed nothing under $ArtifactsFolder/. Nothing will be published. To publish every artifact, run again with 'all-artifacts'."
    Write-Host "##vso[task.logissue type=warning]$message"
    Write-Host '##vso[task.complete result=SucceededWithIssues;]No artifact changes in the latest commit.'
    return
}

Write-Host "The latest commit ($($head.Output -join '')) changes $($changes.Count) artifact file(s):"
$changes | Select-Object -First 50 | ForEach-Object { Write-Host "  $_" }
if ($changes.Count -gt 50) { Write-Host "  ...and $($changes.Count - 50) more." }
