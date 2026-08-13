[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string]$SubscriptionId,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ResourceGroupName,

    [Parameter(Mandatory)]
    [ValidatePattern('^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.Insights/components/[^/]+$')]
    [string]$ApplicationInsightsResourceId,

    [ValidateNotNullOrEmpty()]
    [string]$DisplayName = 'Contact Center and Dataverse Operations',

    [ValidatePattern('^[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string]$WorkbookId,

    [ValidateNotNullOrEmpty()]
    [string]$Location,

    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$WorkbookPath = (Join-Path $PSScriptRoot 'Contact-Center-Dataverse-Operations.workbook')
)

$ErrorActionPreference = 'Stop'
$apiVersion = '2022-04-01'

function Invoke-AzureCliJson {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    $output = & az @Arguments --only-show-errors --output json
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI failed with exit code $LASTEXITCODE."
    }

    if ([string]::IsNullOrWhiteSpace(($output -join ''))) {
        return $null
    }

    return ($output -join [Environment]::NewLine) | ConvertFrom-Json
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI was not found. Install Azure CLI and run az login before using this script.'
}

$null = Invoke-AzureCliJson -Arguments @('account', 'show', '--subscription', $SubscriptionId)

$applicationInsights = Invoke-AzureCliJson -Arguments @(
    'resource', 'show',
    '--ids', $ApplicationInsightsResourceId
)
if ($applicationInsights.type -ine 'Microsoft.Insights/components') {
    throw "'$ApplicationInsightsResourceId' is not an Application Insights component."
}

$resourceGroup = Invoke-AzureCliJson -Arguments @(
    'group', 'show',
    '--subscription', $SubscriptionId,
    '--name', $ResourceGroupName
)
if (-not $Location) {
    $Location = $resourceGroup.location
}

$workbook = Get-Content -LiteralPath $WorkbookPath -Raw | ConvertFrom-Json
if ($workbook.version -ne 'Notebook/1.0' -or -not $workbook.items) {
    throw "'$WorkbookPath' is not a valid Notebook/1.0 workbook definition."
}

$parameterItems = @($workbook.items | Where-Object { $_.type -eq 9 })
$resourceParameters = @(
    $parameterItems.content.parameters |
        Where-Object { $_.name -eq 'ApplicationInsightsResource' }
)
if ($resourceParameters.Count -ne 1) {
    throw "Expected exactly one 'ApplicationInsightsResource' workbook parameter; found $($resourceParameters.Count)."
}

$normalizedSourceId = $applicationInsights.id
$resourceParameters[0].value = $normalizedSourceId
$workbook.fallbackResourceIds = @($normalizedSourceId)
$serializedData = $workbook | ConvertTo-Json -Depth 100 -Compress
$null = $serializedData | ConvertFrom-Json

$escapedSubscriptionId = [Uri]::EscapeDataString($SubscriptionId)
$escapedResourceGroupName = [Uri]::EscapeDataString($ResourceGroupName)
$collectionPath = "/subscriptions/$escapedSubscriptionId/resourceGroups/$escapedResourceGroupName/providers/Microsoft.Insights/workbooks"

if (-not $WorkbookId) {
    $collection = Invoke-AzureCliJson -Arguments @(
        'rest',
        '--method', 'get',
        '--uri', "https://management.azure.com${collectionPath}?api-version=$apiVersion"
    )
    $matches = @($collection.value | Where-Object { $_.properties.displayName -ceq $DisplayName })

    if ($matches.Count -gt 1) {
        throw "Found $($matches.Count) workbooks named '$DisplayName'. Specify -WorkbookId to select one explicitly."
    }

    $WorkbookId = if ($matches.Count -eq 1) {
        Split-Path -Leaf $matches[0].id
    }
    else {
        [Guid]::NewGuid().ToString()
    }
}

$resourcePath = "$collectionPath/$WorkbookId"
$requestBody = [ordered]@{
    location = $Location
    kind = 'shared'
    properties = [ordered]@{
        displayName = $DisplayName
        serializedData = $serializedData
        version = 'Notebook/1.0'
        sourceId = $normalizedSourceId
        category = 'workbook'
    }
}

$bodyPath = Join-Path ([IO.Path]::GetTempPath()) "$WorkbookId.json"
try {
    $bodyJson = $requestBody | ConvertTo-Json -Depth 100
    [IO.File]::WriteAllText($bodyPath, $bodyJson, [Text.UTF8Encoding]::new($false))

    $result = Invoke-AzureCliJson -Arguments @(
        'rest',
        '--method', 'put',
        '--uri', "https://management.azure.com${resourcePath}?api-version=$apiVersion",
        '--body', "@$bodyPath"
    )

    [pscustomobject]@{
        DisplayName = $result.properties.displayName
        WorkbookId = $WorkbookId
        ResourceId = $result.id
        SourceId = $result.properties.sourceId
    }
}
finally {
    if (Test-Path -LiteralPath $bodyPath) {
        Remove-Item -LiteralPath $bodyPath -Force
    }
}
