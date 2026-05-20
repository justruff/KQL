#Requires -Version 7.0
<#
.SYNOPSIS
    Generates an Azure Dashboard ARM/JSON file from templates and a CSV table list.

.DESCRIPTION
    Reads an outer ARM template, an inner JSON snippet template, a CSV of table names,
    and a PowerShell config script (ConfigDashboard.ps1). Replaces placeholders and
    assembles the final dashboard JSON.

.PARAMETER ConfigScript
    Path to the PowerShell configuration script that assigns WORKBOOK_NAME and
    RESOURCE_NAME. Defaults to ConfigDashboard.ps1 in the same directory as this script.

.PARAMETER CsvFile
    Path to the CSV file whose first column contains table names (row 1 is a header).

.PARAMETER OuterTemplate
    Path to the blank Azure Dashboard ARM template JSON file.
    Must contain the literal:  "items": []

.PARAMETER InnerTemplate
    Path to the JSON snippet template file containing the placeholder TBLNAME.

.EXAMPLE
    .\New-AzDashboardGenerator.ps1 `
        -CsvFile       ".\tables.csv" `
        -OuterTemplate ".\outer_template.json" `
        -InnerTemplate ".\inner_template.json"

.EXAMPLE
    .\New-AzDashboardGenerator.ps1 `
        -ConfigScript  ".\ConfigDashboard.ps1" `
        -CsvFile       ".\tables.csv" `
        -OuterTemplate ".\outer_template.json" `
        -InnerTemplate ".\inner_template.json"
#>

[CmdletBinding()]
param (
    # ConfigScript defaults to ConfigDashboard.ps1 next to this script
    [Parameter()][string] $ConfigScript = (Join-Path $PSScriptRoot 'ConfigDashboard.ps1'),
    [Parameter(Mandatory)][string] $CsvFile,
    [Parameter(Mandatory)][string] $OuterTemplate,
    [Parameter(Mandatory)][string] $InnerTemplate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Helper: abort with a clear message
# ---------------------------------------------------------------------------
function Exit-WithError ([string]$Message) {
    Write-Error $Message
    exit 1
}

# ---------------------------------------------------------------------------
# 1. Validate that every required file exists
# ---------------------------------------------------------------------------
foreach ($file in @($ConfigScript, $CsvFile, $OuterTemplate, $InnerTemplate)) {
    if (-not (Test-Path -LiteralPath $file)) {
        Exit-WithError "Required file not found: '$file'"
    }
}

# ---------------------------------------------------------------------------
# 2. Load configuration by dot-sourcing ConfigDashboard.ps1
#    The script must assign: $WORKBOOK_NAME  and  $RESOURCE_NAME
# ---------------------------------------------------------------------------
Write-Verbose "Dot-sourcing config script: $ConfigScript"

# Dot-source into the current scope so the variables become available here
. $ConfigScript

# Validate that the config script actually defined the required variables
if ([string]::IsNullOrWhiteSpace($WORKBOOK_NAME)) {
    Exit-WithError "Config script did not define a non-empty `$WORKBOOK_NAME."
}
if ([string]::IsNullOrWhiteSpace($RESOURCE_NAME)) {
    Exit-WithError "Config script did not define a non-empty `$RESOURCE_NAME."
}

$workbookName = $WORKBOOK_NAME
$resourceName = $RESOURCE_NAME
Write-Verbose "WORKBOOK_NAME = $workbookName"
Write-Verbose "RESOURCE_NAME = $resourceName"

# ---------------------------------------------------------------------------
# 3. Read the outer ARM template as plain text, then substitute config values
#    Replacements are case-sensitive (OrdinalIgnoreCase is NOT used).
# ---------------------------------------------------------------------------
Write-Verbose "Reading outer template: $OuterTemplate"
$outerText = Get-Content -LiteralPath $OuterTemplate -Raw

# Case-sensitive replacement using .NET String.Replace (ordinal, case-sensitive by default)
$outerText = $outerText.Replace('WORKBOOK_NAME', $workbookName)
$outerText = $outerText.Replace('RESOURCE_NAME', $resourceName)

# ---------------------------------------------------------------------------
# 4. Read the inner snippet template as plain text
# ---------------------------------------------------------------------------
Write-Verbose "Reading inner template: $InnerTemplate"
$innerTemplateText = Get-Content -LiteralPath $InnerTemplate -Raw

# ---------------------------------------------------------------------------
# 5. Read the CSV, skip the header row, iterate data rows
# ---------------------------------------------------------------------------
Write-Verbose "Reading CSV: $CsvFile"

# Import-Csv automatically skips the header row and uses it as property names.
# We reference the first column by its header name, captured below.
$csvRows = Import-Csv -LiteralPath $CsvFile

if ($csvRows.Count -eq 0) {
    Exit-WithError "CSV file contains no data rows."
}

# Grab the name of the first column (whatever the header says)
$firstColumnName = ($csvRows[0].PSObject.Properties.Name)[0]
Write-Verbose "CSV first column header: '$firstColumnName'"

# ---------------------------------------------------------------------------
# 6. Build the items array content by processing each CSV row
# ---------------------------------------------------------------------------
$snippets = [System.Collections.Generic.List[string]]::new()

foreach ($row in $csvRows) {
    $tableName = $row.$firstColumnName

    # Skip rows where the table name is blank
    if ([string]::IsNullOrWhiteSpace($tableName)) {
        Write-Warning "Skipping CSV row with empty table name."
        continue
    }

    Write-Verbose "Processing table: $tableName"

    # Case-sensitive replacement of TBLNAME with the actual table name
    $snippet = $innerTemplateText.Replace('TBLNAME', $tableName)

    $snippets.Add($snippet)
}

if ($snippets.Count -eq 0) {
    Exit-WithError "No valid table names found in the CSV file."
}

# ---------------------------------------------------------------------------
# 7. Join snippets with commas between them (no trailing comma on the last one)
# ---------------------------------------------------------------------------
$joinedSnippets = $snippets -join ","

# Wrap in the items array structure that will replace the placeholder
$itemsReplacement = '"items": [' + $joinedSnippets + ']'

# ---------------------------------------------------------------------------
# 8. Replace only the FIRST occurrence of "items": [] in the outer template
# ---------------------------------------------------------------------------
$placeholder = '"items": []'

$placeholderIndex = $outerText.IndexOf($placeholder, [System.StringComparison]::Ordinal)

if ($placeholderIndex -lt 0) {
    Exit-WithError 'The outer template does not contain the expected placeholder: "items": []'
}

$finalJson = $outerText.Substring(0, $placeholderIndex) `
           + $itemsReplacement `
           + $outerText.Substring($placeholderIndex + $placeholder.Length)

# ---------------------------------------------------------------------------
# 9. Output: print to console and save to dashboard.json beside this script
# ---------------------------------------------------------------------------
Write-Output $finalJson

# Resolve the output path relative to the script's own directory
$scriptDir     = $PSScriptRoot
$outputPath    = Join-Path -Path $scriptDir -ChildPath 'dashboard.json'

$finalJson | Set-Content -LiteralPath $outputPath -Encoding UTF8 -NoNewline

Write-Host "`nDashboard JSON saved to: $outputPath" -ForegroundColor Green
