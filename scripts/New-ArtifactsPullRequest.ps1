<#
.SYNOPSIS
    Opens an Azure Repos pull request with freshly extracted APIM artifacts.

.DESCRIPTION
    1. Clones the target branch (shallow).
    2. Creates apiops/extract-<region>-<environment>-<buildId>.
    3. Mirrors the extracted files over the artifacts folder, so deletions in APIM become
       deletions in Git.
    4. Stops quietly if nothing changed.
    5. Commits as the person who queued the run, pushes, and opens a squash-merge pull
       request that deletes its source branch when completed.

    Authenticates with the job access token (SYSTEM_ACCESSTOKEN). The project's build
    service identity needs Contribute, Create branch and Contribute to pull requests.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $ExtractedPath,
    [Parameter(Mandatory)] [string] $Region,
    [Parameter(Mandatory)] [string] $Environment,
    [string] $ArtifactsFolder = 'apim-artifacts',
    [string] $TargetBranch = 'main',
    [string] $LintResultsPath = '',
    [string] $WorkingDirectory = (Join-Path ([System.IO.Path]::GetTempPath()) 'apiops-pr'),

    # Defaults come from predefined Azure Pipelines variables; override them for local testing.
    [string] $RepositoryUri = $env:BUILD_REPOSITORY_URI,
    [string] $RepositoryId = $env:BUILD_REPOSITORY_ID,
    [string] $RepositoryProvider = $env:BUILD_REPOSITORY_PROVIDER,
    [string] $CollectionUri = $env:SYSTEM_COLLECTIONURI,
    [string] $ProjectId = $env:SYSTEM_TEAMPROJECTID,
    [string] $BuildId = $env:BUILD_BUILDID,
    [string] $RequestedFor = $env:BUILD_REQUESTEDFOR,
    [string] $RequestedForEmail = $env:BUILD_REQUESTEDFOREMAIL,

    # Push the branch but don't call the pull request API (for local testing).
    [switch] $SkipPullRequest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$token = $env:SYSTEM_ACCESSTOKEN

# Runs git without turning its progress messages on stderr into PowerShell errors.
function Invoke-Git {
    $gitArguments = $args
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & git @gitArguments 2>&1 | ForEach-Object { "$_" }
    }
    finally {
        $ErrorActionPreference = $previous
    }
    if ($LASTEXITCODE -ne 0) {
        $shown = ($gitArguments -join ' ') -replace '(?i)(authorization: bearer )\S+', '$1***'
        throw "git $shown failed with exit code $LASTEXITCODE.`n$($output -join "`n")"
    }
    return $output
}

# Mirrors $Source into $Destination: afterwards both hold the same files.
function Sync-ArtifactsFolder([string] $Source, [string] $Destination) {
    if (-not (Test-Path -LiteralPath $Destination)) {
        New-Item -ItemType Directory -Path $Destination | Out-Null
    }

    Get-ChildItem -LiteralPath $Destination -Recurse -File -Force | Remove-Item -Force

    $sourceRoot = (Resolve-Path -LiteralPath $Source).ProviderPath.TrimEnd('\', '/')
    Get-ChildItem -LiteralPath $sourceRoot -Recurse -File -Force |
        ForEach-Object {
            $relativePath = $_.FullName.Substring($sourceRoot.Length).TrimStart('\', '/')
            $targetPath = Join-Path $Destination $relativePath
            $targetFolder = Split-Path -Parent $targetPath
            if (-not (Test-Path -LiteralPath $targetFolder)) {
                New-Item -ItemType Directory -Path $targetFolder -Force | Out-Null
            }
            Copy-Item -LiteralPath $_.FullName -Destination $targetPath -Force
        }
}

function Get-LintSummary([string] $Path) {
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return 'Not run (no API definitions, or linting is disabled).'
    }
    [xml] $junit = Get-Content -LiteralPath $Path -Raw
    $failures = 0
    foreach ($suite in $junit.SelectNodes('//testsuite')) {
        $value = $suite.GetAttribute('failures')
        if ($value) { $failures += [int] $value }
    }
    if ($failures -eq 0) { return 'No error-severity issues.' }
    return "$failures error-severity issue(s). See the Tests tab of the build."
}

if ($RepositoryProvider -and $RepositoryProvider -ne 'TfsGit') {
    throw "This step opens pull requests in Azure Repos. The repository provider is '$RepositoryProvider'."
}
if (-not (Test-Path -LiteralPath $ExtractedPath -PathType Container)) {
    throw "Extracted artifacts not found at $ExtractedPath."
}
if (-not $RepositoryUri) { throw 'RepositoryUri is empty (BUILD_REPOSITORY_URI).' }
if (-not $BuildId) { throw 'BuildId is empty (BUILD_BUILDID).' }

$authArguments = @()
if ($token) { $authArguments = @('-c', "http.extraheader=AUTHORIZATION: bearer $token") }

if (Test-Path -LiteralPath $WorkingDirectory) {
    Remove-Item -LiteralPath $WorkingDirectory -Recurse -Force
}

Write-Host "Cloning $TargetBranch..."
Invoke-Git @authArguments clone --quiet --depth 1 --branch $TargetBranch $RepositoryUri $WorkingDirectory | Out-Null

$branchName = "apiops/extract-$Region-$Environment-$BuildId".ToLowerInvariant()
Invoke-Git -C $WorkingDirectory checkout --quiet -b $branchName | Out-Null

Write-Host "Syncing extracted artifacts into $ArtifactsFolder/..."
Sync-ArtifactsFolder -Source $ExtractedPath -Destination (Join-Path $WorkingDirectory $ArtifactsFolder)

Invoke-Git -C $WorkingDirectory add --all | Out-Null
$changes = @(Invoke-Git -C $WorkingDirectory diff --cached --name-status | Where-Object { $_ })
if ($changes.Count -eq 0) {
    Write-Host "No changes: $ArtifactsFolder/ on $TargetBranch already matches $Region/$Environment."
    return
}

$added = @($changes | Where-Object { $_ -match '^A' }).Count
$modified = @($changes | Where-Object { $_ -match '^[MRT]' }).Count
$deleted = @($changes | Where-Object { $_ -match '^D' }).Count
Write-Host "Changes: $added added, $modified modified, $deleted deleted."

$authorName = if ($RequestedFor) { $RequestedFor } else { 'APIOps pipeline' }
$authorEmail = if ($RequestedForEmail) { $RequestedForEmail } else { 'apiops-pipeline@noreply.local' }
$title = "APIOps: changes from $Region/$Environment (build $BuildId)"

Invoke-Git -C $WorkingDirectory -c "user.name=$authorName" -c "user.email=$authorEmail" commit --quiet -m $title | Out-Null
Write-Host "Pushing $branchName..."
Invoke-Git -C $WorkingDirectory @authArguments push --quiet --set-upstream origin $branchName | Out-Null

if ($SkipPullRequest) {
    Write-Host 'SkipPullRequest set: branch pushed, no pull request created.'
    return
}

foreach ($required in @('RepositoryId', 'CollectionUri', 'ProjectId')) {
    if (-not (Get-Variable -Name $required -ValueOnly)) { throw "$required is empty." }
}
if (-not $token) {
    throw 'SYSTEM_ACCESSTOKEN is empty. Map it in the step: env: SYSTEM_ACCESSTOKEN: $(System.AccessToken)'
}

$collection = $CollectionUri.TrimEnd('/')
$buildUrl = "$collection/$ProjectId/_build/results?buildId=$BuildId"
$description = @"
Extracted by the APIOps CLI from **$Region / $Environment**.

| | |
|---|---|
| Changed files | $added added, $modified modified, $deleted deleted |
| API lint | $(Get-LintSummary $LintResultsPath) |
| Build | [$BuildId]($buildUrl) |

Review the diff before merging. Merging updates the desired state that the publisher deploys.
"@

$body = @{
    sourceRefName     = "refs/heads/$branchName"
    targetRefName     = "refs/heads/$TargetBranch"
    title             = $title
    description       = $description
    completionOptions = @{
        mergeStrategy      = 'squash'
        deleteSourceBranch = $true
    }
} | ConvertTo-Json -Depth 5

$uri = "$collection/$ProjectId/_apis/git/repositories/$RepositoryId/pullrequests?api-version=7.1"
try {
    $pullRequest = Invoke-RestMethod -Method Post -Uri $uri -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) `
        -ContentType 'application/json; charset=utf-8' -Headers @{ Authorization = "Bearer $token" }
}
catch {
    throw "Could not create the pull request. Check that the build service identity has 'Contribute to pull requests' on the repository. $($_.Exception.Message)"
}

$pullRequestUrl = "$($pullRequest.repository.webUrl)/pullrequest/$($pullRequest.pullRequestId)"
Write-Host "Pull request $($pullRequest.pullRequestId) created: $pullRequestUrl"
Write-Host "##vso[task.setvariable variable=APIOPS_PULL_REQUEST_URL]$pullRequestUrl"

$summaryPath = Join-Path ([System.IO.Path]::GetTempPath()) 'apiops-pull-request.md'
Set-Content -LiteralPath $summaryPath -Encoding UTF8 -Value @"
## Pull request

[$title]($pullRequestUrl)
"@
Write-Host "##vso[task.uploadsummary]$summaryPath"
