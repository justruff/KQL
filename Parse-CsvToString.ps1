# =============================================================================
# Parse-CsvToString.ps1
#
# Description:
#   Reads a CSV file and produces a single output string where:
#     - Each output row is a single line (real newline between rows).
#     - All column values are wrapped in double-quotes if not already quoted.
#     - Commas between columns are preserved exactly as-is.
#     - Newlines embedded INSIDE a quoted field are replaced with the literal
#       two-character sequence \n so every row collapses to one output line.
#     - Empty/blank rows are silently skipped.
#     - Optionally, the first row (header) can be skipped entirely.
#
# Usage:
#   .\Parse-CsvToString.ps1 -FilePath "C:\path\to\file.csv"
#   .\Parse-CsvToString.ps1 -FilePath "C:\path\to\file.csv" -SkipFirstRow
#
# Parameters:
#   -FilePath     : Full or relative path to the input CSV file.
#   -SkipFirstRow : Switch. If set, the first non-empty row is dropped from
#                   the output (useful for header rows).
# =============================================================================

param (
    [Parameter(Mandatory = $true, HelpMessage = "Path to the input CSV file.")]
    [string]$FilePath,

    [Parameter(Mandatory = $false, HelpMessage = "Skip the first row (e.g. a header row).")]
    [switch]$SkipFirstRow
)

# =============================================================================
# ENCODING SETUP
#
# Force UTF-8 end-to-end so characters like en dashes (–) and em dashes (—)
# survive both the file read and the string output without corruption.
#
#   $OutputEncoding          — used by PowerShell when piping to external
#                              processes or Out-File without -Encoding.
#   [Console]::OutputEncoding — used by the .NET runtime when writing to
#                              stdout directly (Write-Output, etc.).
#
# Both must be set; setting only one still causes corruption in some hosts.
# BOM-less UTF-8 (new UTF8Encoding($false)) avoids prepending a byte-order
# mark that can break downstream consumers.
# =============================================================================
$OutputEncoding           = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

# =============================================================================
# FUNCTION: Parse-CsvContent
#
# Parses the entire CSV file content (as a single string) into a list of rows,
# where each row is an array of raw field strings.
#
# Rules followed:
#   - Fields enclosed in double-quotes may contain embedded commas and newlines.
#   - A literal double-quote inside a quoted field is represented as "" (two
#     consecutive double-quotes).
#   - A newline (CR, LF, or CRLF) outside of any quoted field ends the current row.
# =============================================================================
function Parse-CsvContent {
    param (
        [string]$Content   # The full file content as one string
    )

    # List of rows; each row is a List of field strings
    $rows     = [System.Collections.Generic.List[object]]::new()
    $fields   = [System.Collections.Generic.List[string]]::new()
    $current  = [System.Text.StringBuilder]::new()
    $inQuotes = $false
    $i        = 0
    $len      = $Content.Length

    while ($i -lt $len) {
        $char = $Content[$i]

        # ------------------------------------------------------------------
        # Double-quote character
        # ------------------------------------------------------------------
        if ($char -eq '"') {
            if ($inQuotes) {
                # Peek ahead: "" inside a quoted field = escaped literal quote
                if (($i + 1) -lt $len -and $Content[$i + 1] -eq '"') {
                    [void]$current.Append('"')
                    $i += 2          # Consume both quote characters
                    continue
                }
                else {
                    # Closing quote — exit quoted mode
                    $inQuotes = $false
                    $i++
                    continue
                }
            }
            else {
                # Opening quote — enter quoted mode
                $inQuotes = $true
                $i++
                continue
            }
        }

        # ------------------------------------------------------------------
        # Comma — field separator (only when outside quotes)
        # ------------------------------------------------------------------
        if ($char -eq ',' -and -not $inQuotes) {
            $fields.Add($current.ToString())
            [void]$current.Clear()
            $i++
            continue
        }

        # ------------------------------------------------------------------
        # Newline characters (CR, LF, or CRLF)
        # ------------------------------------------------------------------
        $isCR = ($char -eq "`r")
        $isLF = ($char -eq "`n")

        if (($isCR -or $isLF) -and -not $inQuotes) {
            # Newline outside quotes = end of row
            $fields.Add($current.ToString())
            [void]$current.Clear()

            # Consume CRLF as a single row terminator
            if ($isCR -and ($i + 1) -lt $len -and $Content[$i + 1] -eq "`n") {
                $i++
            }

            $rows.Add($fields.ToArray())
            $fields = [System.Collections.Generic.List[string]]::new()
            $i++
            continue
        }

        if (($isCR -or $isLF) -and $inQuotes) {
            # Newline INSIDE a quoted field — keep it in the field value.
            # Normalise CRLF to a single LF so Format-Field only needs to
            # handle one newline style when replacing with the literal \n.
            if ($isCR -and ($i + 1) -lt $len -and $Content[$i + 1] -eq "`n") {
                [void]$current.Append("`n")   # Store as single LF
                $i += 2                        # Skip past both CR and LF
            }
            else {
                [void]$current.Append("`n")   # Lone CR or LF — normalise to LF
                $i++
            }
            continue
        }

        # ------------------------------------------------------------------
        # Any other character — append to the current field
        # ------------------------------------------------------------------
        [void]$current.Append($char)
        $i++
    }

    # ------------------------------------------------------------------
    # Handle the final field / row if the file has no trailing newline
    # ------------------------------------------------------------------
    if ($fields.Count -gt 0 -or $current.Length -gt 0) {
        $fields.Add($current.ToString())
        $rows.Add($fields.ToArray())
    }

    return $rows
}

# =============================================================================
# FUNCTION: Test-RowIsEmpty
#
# Returns $true if every field in the row is null, empty, or whitespace-only.
# =============================================================================
function Test-RowIsEmpty {
    param ([string[]]$Fields)

    foreach ($field in $Fields) {
        if (-not [string]::IsNullOrWhiteSpace($field)) {
            return $false
        }
    }
    return $true
}

# =============================================================================
# FUNCTION: Format-Field
#
# Accepts a single raw field value (already unescaped by the parser) and:
#   1. Replaces any embedded newline characters with the literal string \n
#      so the field fits on one output line.
#   2. Escapes any double-quote characters as "" (CSV standard).
#   3. Wraps the result in double-quotes.
#
# Because the parser strips surrounding quotes while building field values,
# every field arrives here as plain text and is treated uniformly.
# =============================================================================
function Format-Field {
    param ([string]$Value)

    # Replace all embedded newlines (normalised to LF by the parser) with
    # the two-character literal \n so the field stays on one line
    $value = $Value -replace "`n", '\n'

    # Escape any double-quote characters present in the value (CSV standard)
    $value = $value -replace '"', '""'

    # Wrap in double-quotes
    return '"' + $value + '"'
}

# =============================================================================
# MAIN SCRIPT LOGIC
# =============================================================================

try {
    # -------------------------------------------------------------------------
    # 1. Validate the input file exists and is a regular file
    # -------------------------------------------------------------------------
    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
        throw "File not found or is not a regular file: '$FilePath'"
    }

    # -------------------------------------------------------------------------
    # 2. Read the entire file as a single string to preserve embedded newlines
    #    inside quoted fields
    # -------------------------------------------------------------------------
    Write-Verbose "Reading file: $FilePath"

    try {
        $rawContent = Get-Content -LiteralPath $FilePath -Raw -Encoding UTF8 -ErrorAction Stop
    }
    catch {
        throw "Failed to read file '$FilePath': $_"
    }

    if ([string]::IsNullOrEmpty($rawContent)) {
        throw "The file '$FilePath' is empty."
    }

    # -------------------------------------------------------------------------
    # 3. Parse the raw CSV content into rows + fields
    # -------------------------------------------------------------------------
    $parsedRows = Parse-CsvContent -Content $rawContent

    if ($parsedRows.Count -eq 0) {
        throw "No rows were found in '$FilePath'."
    }

    # -------------------------------------------------------------------------
    # 4. Build the output, skipping empty rows and optionally the first row
    # -------------------------------------------------------------------------
    $outputLines  = [System.Collections.Generic.List[string]]::new()
    $firstRowSeen = $false

    foreach ($row in $parsedRows) {
        # Skip rows where every field is blank
        if (Test-RowIsEmpty -Fields $row) {
            Write-Verbose "Skipping empty row."
            continue
        }

        # Skip the very first non-empty row if -SkipFirstRow was requested
        if ($SkipFirstRow -and -not $firstRowSeen) {
            $firstRowSeen = $true
            Write-Verbose "Skipping first row (header): $($row -join ',')"
            continue
        }

        $firstRowSeen = $true

        # Quote every field, rejoin with commas, then append a trailing comma
        $formattedFields = $row | ForEach-Object { Format-Field -Value $_ }
        $outputLines.Add(($formattedFields -join ',') + ',')
    }

    # -------------------------------------------------------------------------
    # 5. Guard against a file that had nothing but empty/header rows
    # -------------------------------------------------------------------------
    if ($outputLines.Count -eq 0) {
        throw "No non-empty data rows were found in '$FilePath' after applying options."
    }

    # -------------------------------------------------------------------------
    # 6. Join all formatted rows with real newlines and emit the final string
    # -------------------------------------------------------------------------
    $outputString = $outputLines -join "`n"

    Write-Output $outputString

    Write-Verbose "Done. $($outputLines.Count) row(s) written."
}
catch {
    Write-Error "ERROR: $_"
    exit 1
}
