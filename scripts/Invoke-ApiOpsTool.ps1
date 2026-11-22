<#
.SYNOPSIS
    Runs the APIOps CLI (apiops extract or apiops publish) against one target.

.DESCRIPTION
    Runs inside the AzureCLI@2 task, which has already signed in with the target's service
    connection. The CLI's DefaultAzureCredential picks up that Azure CLI session, so no token
    or client secret is handled here (workload identity federation works as is).

    Turns pipeline values into CLI flags and only adds optional ones when they apply:
      --filter        extract, only when the target has an extractor configuration.
      --overrides     publish, only when the target has a publisher configuration.
      --commit-id and --delete-unmatched
                      publish in 'changes-in-latest-commit' mode: put what the commit added or
                      changed, delete what it removed, nothing else.
      --dry-run       publish dry runs.

    Fails with a clear message when a required value is missing from the variable group,
    instead of letting the CLI run against an empty or literal "$(VARIABLE)" value.

    Any non-zero exit fails the step, including exit code 1 (partial success). A partial
    extract would open a pull request that deletes the resources that failed, and a partial
    publish leaves the instance out of step with the repository.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('extract', 'publish')]
    [string] $Command,

    [Parameter(Mandatory)] [string] $CliPath,
    [Parameter(Mandatory)] [string] $ServiceName,
    [Parameter(Mandatory)] [string] $ResourceGroupName,
    [Parameter(Mandatory)] [string] $ArtifactsPath,
    [string] $SubscriptionId = '',
    [string] $FilterPath = '',
    [string] $OverridesPath = '',

    [ValidateSet('', 'changes-in-latest-commit', 'all-artifacts')]
    [string] $PublishMode = '',

    [string] $CommitId = '',
    [string] $DryRun = 'False',

    [ValidateSet('debug', 'info', 'warn', 'error')]
    [string] $LogLevel = 'info'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-PipelineValue {
    param(
        [string] $Name,
        [string] $Value,
        [switch] $Required
    )

    # An undefined pipeline variable reaches the script as the literal text "$(NAME)".
    $isEmpty = [string]::IsNullOrWhiteSpace($Value) -or $Value -match '^\$\([^)]*\)$'
    if ($isEmpty -and $Required) {
        throw "$Name has no value. Check that the variable group for this target defines it."
    }
    if ($isEmpty) { return '' }
    return $Value.Trim()
}

$CliPath = Get-PipelineValue -Name 'APIOPS_CLI_PATH' -Value $CliPath -Required
if (-not (Test-Path -LiteralPath $CliPath -PathType Leaf)) {
    throw "APIOps CLI not found at $CliPath. Did the install step run?"
}

$service = Get-PipelineValue -Name 'APIM_NAME' -Value $ServiceName -Required
$resourceGroup = Get-PipelineValue -Name 'APIM_RESOURCE_GROUP' -Value $ResourceGroupName -Required
$artifacts = Get-PipelineValue -Name 'Artifacts path' -Value $ArtifactsPath -Required

# The CLI needs a subscription. Use the variable group's, else the service connection's default.
$subscription = Get-PipelineValue -Name 'AZURE_SUBSCRIPTION_ID' -Value $SubscriptionId
if ($subscription) {
    Write-Host 'Using AZURE_SUBSCRIPTION_ID from the variable group.'
}
else {
    $subscription = az account show --query id --output tsv
    if ($LASTEXITCODE -ne 0 -or -not $subscription) {
        throw 'Could not read the default subscription of the service connection. Set AZURE_SUBSCRIPTION_ID in the variable group.'
    }
    Write-Host "Using the service connection's default subscription."
}
$parsed = [guid]::Empty
if (-not [guid]::TryParse($subscription.Trim(), [ref]$parsed)) {
    throw "Subscription ID '$subscription' is not a valid GUID."
}

$cliArguments = @(
    $Command,
    '--resource-group', $resourceGroup,
    '--service-name', $service,
    '--subscription-id', $parsed.ToString(),
    '--log-level', $LogLevel
)

if ($Command -eq 'extract') {
    $cliArguments += @('--output', $artifacts)

    $filter = Get-PipelineValue -Name 'Filter path' -Value $FilterPath
    if ($filter -and (Test-Path -LiteralPath $filter -PathType Leaf)) {
        $cliArguments += @('--filter', (Resolve-Path -LiteralPath $filter).ProviderPath)
        Write-Host "Using extractor configuration $filter"
    }
    else {
        Write-Host 'No extractor configuration for this target. Extracting everything.'
    }
}
else {
    if (-not (Test-Path -LiteralPath $artifacts -PathType Container)) {
        throw "Artifacts folder $artifacts does not exist."
    }
    $cliArguments += @('--source', $artifacts)

    $overrides = Get-PipelineValue -Name 'Overrides path' -Value $OverridesPath
    if ($overrides) {
        $cliArguments += @('--overrides', $overrides)
        Write-Host 'Using the resolved publisher configuration for this target.'
    }
    else {
        Write-Host 'No publisher configuration for this target. Publishing without overrides.'
    }

    switch ($PublishMode) {
        'changes-in-latest-commit' {
            $commit = Get-PipelineValue -Name 'Commit ID' -Value $CommitId -Required
            # With --commit-id, --delete-unmatched only deletes what this commit removed.
            $cliArguments += @('--commit-id', $commit, '--delete-unmatched')
            Write-Host "Publishing the artifacts changed in commit $commit, and deleting the ones it removed."
        }
        'all-artifacts' {
            Write-Host 'Publishing every artifact in the folder. Nothing is deleted in APIM.'
        }
        default {
            throw 'PublishMode is required for publish.'
        }
    }

    $isDryRun = $false
    if (-not [bool]::TryParse($DryRun, [ref]$isDryRun)) {
        throw "DryRun must be True or False, not '$DryRun'."
    }
    if ($isDryRun) {
        $cliArguments += '--dry-run'
        Write-Host 'Dry run: the CLI lists what it would create, update or delete, and changes nothing.'
    }
}

# The CLI must not pick up a stale value from the agent's environment.
[Environment]::SetEnvironmentVariable('COMMIT_ID', $null)

Write-Host "Running: apiops $($cliArguments -join ' ')"
& $CliPath @cliArguments
$exitCode = $LASTEXITCODE

switch ($exitCode) {
    0 { Write-Host "apiops $Command completed." }
    1 { throw "apiops $Command finished with partial failures (exit code 1). See the errors above. Treated as a failure so nothing incomplete moves on." }
    default { throw "apiops $Command failed with exit code $exitCode." }
}
