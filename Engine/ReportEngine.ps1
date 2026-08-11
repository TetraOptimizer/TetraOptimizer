#Requires -Version 5.1
<#
.SYNOPSIS
    Tetra Optimizer - Report Engine
.DESCRIPTION
    Generates, formats, and persists reports for Tetra Optimizer.

    RESPONSIBILITY (single):
        Own the standardized Report object schema; classify reports by
        ReportType; build reports from available data sources (currently:
        logs; later: Analyzer results); render reports through a
        pluggable format registry; save them to disk with automatic
        Tetra branding. Nothing else.

    THIS FILE MUST NEVER:
        - Print UI menus or prompt for user input (that is Core's job -
          Core/ReportViewer.ps1, built in Phase 4).
        - Perform system analysis itself (that is Analyzer's job, Phase 3).

    REPORT OBJECT SCHEMA (the contract every module builds against):
        ReportId        : string (GUID)
        ReportType       : one of Get-TetraReportTypes (see below)
        Title           : string
        GeneratedUtc    : string (ISO 8601)
        OperationId     : string (GUID) or $null
        Summary         : string
        Sections        : List[PSCustomObject] - each { Title; Content }
                           Content may be a string OR any collection of
                           objects (rendered as a table in TXT/HTML).
        Recommendations : List[PSCustomObject] - each { Title; Description;
                           Severity (Info|Low|Medium|High|Critical); Category;
                           CanAutoFix; FixId; DocumentationLink; LearnMore }
        Scores          : PSCustomObject with dynamic named properties,
                           e.g. Scores.PerformanceScore, Scores.SecurityScore,
                           Scores.OverallScore (0-100 each). Populated via
                           Set-TetraReportScore.
        Metadata        : PSCustomObject from Get-TetraSystemMetadata
                           (DeviceId, MachineName, UserName, hardware info,
                           TetraVersion, BuildNumber, ReleaseChannel, etc.).

    REPORT TYPES:
        Fixed vocabulary via Get-TetraReportTypes / the ValidateSet on
        New-TetraReport's -ReportType parameter: OperationReport,
        PerformanceReport, SecurityReport, GamingReport, StartupReport,
        SystemHealthReport, DiagnosticsReport, General.
        (PowerShell 5.1's [ValidateSet] cannot reference a variable, so
        this list is necessarily duplicated between the attribute and
        Get-TetraReportTypes - the alternative, a custom
        IValidateSetValuesGenerator class, requires PS 6+.)

    EXPORT SYSTEM (pluggable renderer registry):
        Register-TetraReportRenderer -Format -Extension -FunctionName
        registers a converter function (must accept -Report and return a
        string) under a format name. Save-TetraReport / Save-TetraReportAllFormats
        / Get-TetraReportFormats all operate purely against this registry -
        none of them contain per-format logic. TXT/HTML/JSON are registered
        at the bottom of this file. Adding PDF/CSV/XML/Markdown later means
        writing ConvertTo-TetraReportPdf (etc.) and adding one
        Register-TetraReportRenderer call - no other function changes.

    BRANDING:
        Applied at RENDER time (not stored on the Report object, to keep
        content and presentation separate) - ConvertTo-TetraReportText and
        ConvertTo-TetraReportHtml both call Get-TetraProductInfo directly
        for header/footer branding.

    DEPENDENCIES:
        Config/PathHelpers.ps1, Config/Config.ps1, Engine/LoggerEngine.ps1, and
        Config/ProductInfo.ps1 must already be dot-sourced.
.NOTES
    Module      : ReportEngine.ps1
    Layer       : Engine
    Build Phase : Phase 1 - Foundation
    Build Step  : 3 of 32 (revised: ReportType, renderer registry, branding, extended Recommendations; Foundation Validation pass added path-traversal/overwrite-safety hardening to Save-TetraReport and removed duplicated path-resolution logic)
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ============================================================
# MODULE-SCOPED STATE
# ============================================================

# Fixed report-type vocabulary, mirrored from New-TetraReport's
# [ValidateSet] (see class-level note above re: PS 5.1 limitation).
$Script:TetraReportTypes = @(
    'OperationReport',
    'PerformanceReport',
    'SecurityReport',
    'GamingReport',
    'StartupReport',
    'SystemHealthReport',
    'DiagnosticsReport',
    'General'
)

# Export System: Format name -> @{ Format; Extension; FunctionName }
$Script:TetraReportRenderers = [ordered]@{}

# ============================================================
# FUNCTION: Get-TetraReportTypes
# ============================================================
<#
.SYNOPSIS
    Returns the fixed set of valid ReportType values.
.DESCRIPTION
    Exposed for introspection so Core can build filter/selection menus
    dynamically instead of hardcoding the list a third time.
.OUTPUTS
    System.String[]
#>
function Get-TetraReportTypes {
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    return $Script:TetraReportTypes
}

# ============================================================
# FUNCTION: Get-TetraReportsDirectory
# ============================================================
<#
.SYNOPSIS
    Returns the absolute path to the Reports folder.
.OUTPUTS
    System.String
#>
function Get-TetraReportsDirectory {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    return (Get-TetraSiblingDirectory -CallerScriptRoot $PSScriptRoot -FolderName 'Reports')
}

# ============================================================
# FUNCTION: Initialize-TetraReportsDirectory
# ============================================================
<#
.SYNOPSIS
    Ensures the Reports folder exists on disk.
.OUTPUTS
    System.String - the (now guaranteed to exist) Reports folder path.
#>
function Initialize-TetraReportsDirectory {
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([string])]
    param()

    return (Initialize-TetraDirectory -Path (Get-TetraReportsDirectory))
}

# ============================================================
# FUNCTION: New-TetraReport
# ============================================================
<#
.SYNOPSIS
    Creates a new, empty standardized Report object.
.PARAMETER Title
    The report's display title.
.PARAMETER ReportType
    One of Get-TetraReportTypes. Defaults to "General".
.PARAMETER Summary
    A short high-level summary. Optional, can be set later.
.PARAMETER OperationId
    Optional OperationId this report is scoped to.
.OUTPUTS
    System.Management.Automation.PSCustomObject - the new report.
#>
function New-TetraReport {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Title,

        [Parameter(Mandatory = $false)]
        [ValidateSet('OperationReport', 'PerformanceReport', 'SecurityReport', 'GamingReport', 'StartupReport', 'SystemHealthReport', 'DiagnosticsReport', 'General')]
        [string]$ReportType = 'General',

        [Parameter(Mandatory = $false)]
        [string]$Summary = '',

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [string]$OperationId = $null
    )

    try {
        return [PSCustomObject]@{
            ReportId        = [guid]::NewGuid().ToString()
            ReportType      = $ReportType
            Title           = $Title
            GeneratedUtc    = (Get-Date).ToUniversalTime().ToString('o')
            OperationId     = $OperationId
            Summary         = $Summary
            Sections        = [System.Collections.Generic.List[PSCustomObject]]::new()
            Recommendations = [System.Collections.Generic.List[PSCustomObject]]::new()
            Scores          = [PSCustomObject]@{}
            Metadata        = Get-TetraSystemMetadata
        }
    }
    catch {
        throw "New-TetraReport: Failed to create report '$Title' - $($_.Exception.Message)"
    }
}

# ============================================================
# FUNCTION: Add-TetraReportSection
# ============================================================
<#
.SYNOPSIS
    Appends a titled content section to a report.
.PARAMETER Report
    The report object to modify (from New-TetraReport).
.PARAMETER Title
    Section heading, e.g. "Level Breakdown".
.PARAMETER Content
    Either a plain string, or any collection of objects.
.OUTPUTS
    System.Management.Automation.PSCustomObject - the same report, for chaining.
#>
function Add-TetraReportSection {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Report,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Title,

        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object]$Content
    )

    try {
        $Report.Sections.Add([PSCustomObject]@{
            Title   = $Title
            Content = $Content
        })

        return $Report
    }
    catch {
        throw "Add-TetraReportSection: Failed to add section '$Title' - $($_.Exception.Message)"
    }
}

# ============================================================
# FUNCTION: Add-TetraReportRecommendation
# ============================================================
<#
.SYNOPSIS
    Appends a recommendation entry to a report.
.PARAMETER Report
    The report object to modify.
.PARAMETER Title
    Short recommendation title, e.g. "Disable unused startup entry".
.PARAMETER Description
    Full explanation of the recommendation and its rationale. Optional.
.PARAMETER Severity
    One of: Info, Low, Medium, High, Critical. Defaults to Info.
.PARAMETER Category
    Free-text grouping, e.g. "Startup", "Security", "Network". Defaults to "General".
.PARAMETER CanAutoFix
    Marks this recommendation as having an automated fix available. When
    specified, -FixId becomes required, so that a future "Apply Fix" UI
    always has something concrete to invoke.
.PARAMETER FixId
    Identifier of the automated fix routine this recommendation maps to.
    Required when -CanAutoFix is specified.
.PARAMETER DocumentationLink
    Optional URL to further documentation about this recommendation.
.PARAMETER LearnMore
    Optional free-text "learn more" explanation, separate from Description
    (e.g. deeper technical rationale vs. a short user-facing summary).
.OUTPUTS
    System.Management.Automation.PSCustomObject - the same report, for chaining.
#>
function Add-TetraReportRecommendation {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Report,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Title,

        [Parameter(Mandatory = $false)]
        [string]$Description = '',

        [Parameter(Mandatory = $false)]
        [ValidateSet('Info', 'Low', 'Medium', 'High', 'Critical')]
        [string]$Severity = 'Info',

        [Parameter(Mandatory = $false)]
        [string]$Category = 'General',

        [Parameter(Mandatory = $false)]
        [switch]$CanAutoFix,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [string]$FixId = $null,

        [Parameter(Mandatory = $false)]
        [string]$DocumentationLink = '',

        [Parameter(Mandatory = $false)]
        [string]$LearnMore = ''
    )

    try {
        if ($CanAutoFix -and [string]::IsNullOrWhiteSpace($FixId)) {
            throw 'FixId is required when -CanAutoFix is specified.'
        }

        $Report.Recommendations.Add([PSCustomObject]@{
            Title             = $Title
            Description       = $Description
            Severity          = $Severity
            Category          = $Category
            CanAutoFix        = [bool]$CanAutoFix
            FixId             = $FixId
            DocumentationLink = $DocumentationLink
            LearnMore         = $LearnMore
        })

        return $Report
    }
    catch {
        throw "Add-TetraReportRecommendation: Failed to add recommendation '$Title' - $($_.Exception.Message)"
    }
}

# ============================================================
# FUNCTION: Set-TetraReportScore
# ============================================================
<#
.SYNOPSIS
    Sets (or updates) a named score on a report, e.g. "PerformanceScore".
.PARAMETER Report
    The report object to modify.
.PARAMETER Name
    Score name, e.g. "SecurityScore", "OverallScore".
.PARAMETER Value
    Numeric score between 0 and 100 inclusive.
.OUTPUTS
    System.Management.Automation.PSCustomObject - the same report, for chaining.
#>
function Set-TetraReportScore {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Report,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [ValidateRange(0, 100)]
        [double]$Value
    )

    try {
        # NOTE (bug fix): the previous check -
        #   $Report.Scores.PSObject.Properties.Name -contains $Name
        # - relies on PowerShell's automatic member-enumeration to unroll
        # .Name across the Properties collection. When Scores has ZERO
        # properties (its state immediately after New-TetraReport, before
        # any score has ever been set), there is nothing to enumerate, and
        # under Set-StrictMode -Version Latest (active in this file) that
        # throws "The property 'Name' cannot be found on this object"
        # instead of silently returning $null/false. The indexer lookup
        # below (.Properties[$Name]) is a direct collection lookup, not
        # member-enumeration, so it correctly returns $null when absent
        # regardless of whether the collection is empty - safe under
        # strict mode in both the empty and non-empty case.
        if ($null -ne $Report.Scores.PSObject.Properties[$Name]) {
            $Report.Scores.$Name = $Value
        }
        else {
            $Report.Scores | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
        }

        return $Report
    }
    catch {
        throw "Set-TetraReportScore: Failed to set score '$Name' - $($_.Exception.Message)"
    }
}

# ============================================================
# FUNCTION: New-TetraOperationReport
# ============================================================
<#
.SYNOPSIS
    Builds a complete report summarizing everything logged under a single
    OperationId.
.PARAMETER OperationId
    The GUID (as a string) of the operation to report on.
.PARAMETER StartDate
    Earliest date (UTC) to search for matching log entries. Defaults to
    30 days ago.
.PARAMETER EndDate
    Latest date (UTC) to search. Defaults to now.
.PARAMETER Title
    Optional report title. Defaults to "Operation Report - <OperationId>".
.OUTPUTS
    System.Management.Automation.PSCustomObject - the completed report.
#>
function New-TetraOperationReport {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$OperationId,

        [Parameter(Mandatory = $false)]
        [datetime]$StartDate = (Get-Date).ToUniversalTime().AddDays(-30),

        [Parameter(Mandatory = $false)]
        [datetime]$EndDate = (Get-Date).ToUniversalTime(),

        [Parameter(Mandatory = $false)]
        [string]$Title
    )

    try {
        $parsedGuid = [guid]::Empty
        if (-not [guid]::TryParse($OperationId, [ref]$parsedGuid)) {
            throw "OperationId '$OperationId' is not a valid GUID."
        }

        if ([string]::IsNullOrWhiteSpace($Title)) {
            $Title = "Operation Report - $OperationId"
        }

        $entries = Get-TetraLogEntries -StartDate $StartDate -EndDate $EndDate -OperationId $OperationId

        $errorCount   = @($entries | Where-Object { $_.Level -eq 'Error' }).Count
        $warningCount = @($entries | Where-Object { $_.Level -eq 'Warning' }).Count
        $successCount = @($entries | Where-Object { $_.Level -eq 'Success' }).Count

        $summary = "This operation produced $($entries.Count) log entries: $successCount succeeded, $warningCount warning(s), $errorCount error(s)."

        $report = New-TetraReport -Title $Title -ReportType 'OperationReport' -OperationId $OperationId -Summary $summary

        if ($entries.Count -gt 0) {
            $levelBreakdown = $entries | Group-Object -Property Level | Select-Object Name, Count
            Add-TetraReportSection -Report $report -Title 'Level Breakdown' -Content $levelBreakdown | Out-Null

            $moduleBreakdown = $entries | Group-Object -Property Module | Select-Object Name, Count
            Add-TetraReportSection -Report $report -Title 'Module Breakdown' -Content $moduleBreakdown | Out-Null

            Add-TetraReportSection -Report $report -Title 'Log Entries' -Content $entries | Out-Null

            foreach ($errorEntry in ($entries | Where-Object { $_.Level -eq 'Error' })) {
                Add-TetraReportRecommendation -Report $report -Severity 'High' -Category $errorEntry.Module `
                    -Title "Investigate failure in $($errorEntry.Action)" `
                    -Description $errorEntry.Message | Out-Null
            }

            foreach ($warningEntry in ($entries | Where-Object { $_.Level -eq 'Warning' })) {
                Add-TetraReportRecommendation -Report $report -Severity 'Medium' -Category $warningEntry.Module `
                    -Title "Review warning in $($warningEntry.Action)" `
                    -Description $warningEntry.Message | Out-Null
            }
        }
        else {
            Add-TetraReportSection -Report $report -Title 'Log Entries' `
                -Content 'No log entries were found for this Operation ID within the specified date range.' | Out-Null
        }

        return $report
    }
    catch {
        throw "New-TetraOperationReport: Failed to build operation report - $($_.Exception.Message)"
    }
}

# ============================================================
# FUNCTION: ConvertTo-TetraReportJson
# ============================================================
<#
.SYNOPSIS
    Serializes a report object to a JSON string.
.PARAMETER Report
    The report to serialize.
.OUTPUTS
    System.String
#>
function ConvertTo-TetraReportJson {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Report
    )

    try {
        return ($Report | ConvertTo-Json -Depth 15)
    }
    catch {
        throw "ConvertTo-TetraReportJson: Failed to render JSON report - $($_.Exception.Message)"
    }
}

# ============================================================
# FUNCTION: ConvertTo-TetraReportText
# ============================================================
<#
.SYNOPSIS
    Renders a report object as a plain-text string, with automatic Tetra
    branding header/footer.
.PARAMETER Report
    The report to render.
.OUTPUTS
    System.String
#>
function ConvertTo-TetraReportText {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Report
    )

    try {
        $productInfo = Get-TetraProductInfo
        $sb = [System.Text.StringBuilder]::new()

        # ---- Branding header ----
        [void]$sb.AppendLine('========================================================')
        [void]$sb.AppendLine($productInfo.ProductName)
        [void]$sb.AppendLine("Powered by $($productInfo.CompanyName)")
        [void]$sb.AppendLine('========================================================')
        [void]$sb.AppendLine('')

        [void]$sb.AppendLine("[$($Report.ReportType)] $($Report.Title)")
        [void]$sb.AppendLine('--------------------------------------------------------')
        [void]$sb.AppendLine("Generated (UTC): $($Report.GeneratedUtc)")

        if ($Report.OperationId) {
            [void]$sb.AppendLine("Operation ID   : $($Report.OperationId)")
        }

        [void]$sb.AppendLine("Device         : $($Report.Metadata.DeviceId)")
        [void]$sb.AppendLine("Machine        : $($Report.Metadata.MachineName)")
        [void]$sb.AppendLine("User           : $($Report.Metadata.UserName)")
        [void]$sb.AppendLine('')

        if (-not [string]::IsNullOrWhiteSpace($Report.Summary)) {
            [void]$sb.AppendLine('SUMMARY')
            [void]$sb.AppendLine('--------------------------------------------------------')
            [void]$sb.AppendLine($Report.Summary)
            [void]$sb.AppendLine('')
        }

        $scoreProps = @($Report.Scores.PSObject.Properties)
        if ($scoreProps.Count -gt 0) {
            [void]$sb.AppendLine('SCORES')
            [void]$sb.AppendLine('--------------------------------------------------------')
            foreach ($p in $scoreProps) {
                [void]$sb.AppendLine(("{0,-30}: {1}" -f $p.Name, [math]::Round([double]$p.Value, 1)))
            }
            [void]$sb.AppendLine('')
        }

        foreach ($section in $Report.Sections) {
            [void]$sb.AppendLine($section.Title.ToUpperInvariant())
            [void]$sb.AppendLine('--------------------------------------------------------')

            $content = $section.Content
            if ($content -is [string]) {
                [void]$sb.AppendLine($content)
            }
            elseif ($null -ne $content) {
                [void]$sb.AppendLine(($content | Format-Table -AutoSize | Out-String -Width 200).TrimEnd())
            }

            [void]$sb.AppendLine('')
        }

        if ($Report.Recommendations.Count -gt 0) {
            [void]$sb.AppendLine('RECOMMENDATIONS')
            [void]$sb.AppendLine('--------------------------------------------------------')
            foreach ($rec in $Report.Recommendations) {
                [void]$sb.AppendLine("[$($rec.Severity)] ($($rec.Category)) $($rec.Title)")
                [void]$sb.AppendLine("    $($rec.Description)")

                if ($rec.CanAutoFix) {
                    [void]$sb.AppendLine("    Auto-Fix Available (FixId: $($rec.FixId))")
                }

                if (-not [string]::IsNullOrWhiteSpace($rec.DocumentationLink)) {
                    [void]$sb.AppendLine("    Docs: $($rec.DocumentationLink)")
                }

                if (-not [string]::IsNullOrWhiteSpace($rec.LearnMore)) {
                    [void]$sb.AppendLine("    Learn more: $($rec.LearnMore)")
                }
            }
            [void]$sb.AppendLine('')
        }

        # ---- Branding footer ----
        [void]$sb.AppendLine('========================================================')
        [void]$sb.AppendLine("Generated by $($productInfo.ProductName)")
        [void]$sb.AppendLine("Generated UTC : $($Report.GeneratedUtc)")
        [void]$sb.AppendLine("Version       : $($productInfo.Version)")
        [void]$sb.AppendLine("Build         : $($productInfo.BuildNumber)")
        [void]$sb.AppendLine("Channel       : $($productInfo.ReleaseChannel)")
        [void]$sb.AppendLine('========================================================')

        return $sb.ToString()
    }
    catch {
        throw "ConvertTo-TetraReportText: Failed to render text report - $($_.Exception.Message)"
    }
}

# ============================================================
# FUNCTION: ConvertTo-TetraReportHtml
# ============================================================
<#
.SYNOPSIS
    Renders a report object as a self-contained HTML document, with
    automatic Tetra branding header/footer.
.PARAMETER Report
    The report to render.
.OUTPUTS
    System.String
#>
function ConvertTo-TetraReportHtml {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Report
    )

    try {
        $productInfo = Get-TetraProductInfo
        $sb = [System.Text.StringBuilder]::new()

        [void]$sb.AppendLine('<!DOCTYPE html>')
        [void]$sb.AppendLine('<html lang="en">')
        [void]$sb.AppendLine('<head>')
        [void]$sb.AppendLine('<meta charset="UTF-8">')
        [void]$sb.AppendLine("<title>$([System.Net.WebUtility]::HtmlEncode($Report.Title))</title>")
        [void]$sb.AppendLine('<style>')
        [void]$sb.AppendLine(@'
body { font-family: "Segoe UI", Arial, sans-serif; background:#1e1e1e; color:#e0e0e0; margin:0; padding:24px; }
.brand-header { border-bottom:2px solid #4fc3f7; padding-bottom:12px; margin-bottom:20px; }
.brand-header .product-name { font-size:1.4em; font-weight:bold; color:#4fc3f7; }
.brand-header .tagline { color:#9e9e9e; font-size:0.85em; }
.report-type-badge { display:inline-block; background:#2d2d2d; color:#81d4fa; padding:2px 10px; border-radius:10px; font-size:0.75em; margin-bottom:6px; }
h1 { color:#4fc3f7; margin-top:4px; }
h2 { color:#81d4fa; border-bottom:1px solid #444; padding-bottom:4px; margin-top:28px; }
.meta { color:#9e9e9e; font-size:0.9em; margin-bottom:16px; line-height:1.6; }
table { border-collapse:collapse; width:100%; margin-bottom:20px; }
th, td { border:1px solid #444; padding:6px 10px; text-align:left; font-size:0.9em; }
th { background:#2d2d2d; }
tr:nth-child(even) { background:#252525; }
.severity-Critical { color:#ff5252; font-weight:bold; }
.severity-High { color:#ff8a65; font-weight:bold; }
.severity-Medium { color:#ffd54f; }
.severity-Low { color:#aed581; }
.severity-Info { color:#4fc3f7; }
.score-bar-bg { background:#333; border-radius:4px; overflow:hidden; height:14px; width:200px; display:inline-block; vertical-align:middle; }
.score-bar-fill { background:#4caf50; height:100%; }
.autofix-yes { color:#4caf50; font-weight:bold; }
.autofix-no { color:#757575; }
.brand-footer { border-top:1px solid #444; margin-top:32px; padding-top:12px; color:#9e9e9e; font-size:0.85em; }
'@)
        [void]$sb.AppendLine('</style>')
        [void]$sb.AppendLine('</head>')
        [void]$sb.AppendLine('<body>')

        # ---- Branding header ----
        [void]$sb.AppendLine('<div class="brand-header">')
        [void]$sb.AppendLine("<div class='product-name'>$([System.Net.WebUtility]::HtmlEncode($productInfo.ProductName))</div>")
        [void]$sb.AppendLine("<div class='tagline'>Powered by $([System.Net.WebUtility]::HtmlEncode($productInfo.CompanyName))</div>")
        [void]$sb.AppendLine('</div>')

        [void]$sb.AppendLine("<div class='report-type-badge'>$([System.Net.WebUtility]::HtmlEncode($Report.ReportType))</div>")
        [void]$sb.AppendLine("<h1>$([System.Net.WebUtility]::HtmlEncode($Report.Title))</h1>")
        [void]$sb.AppendLine("<div class='meta'>Generated (UTC): $($Report.GeneratedUtc)<br/>")

        if ($Report.OperationId) {
            [void]$sb.AppendLine("Operation ID: $($Report.OperationId)<br/>")
        }

        [void]$sb.AppendLine("Device: $($Report.Metadata.DeviceId)<br/>")
        [void]$sb.AppendLine("Machine: $($Report.Metadata.MachineName) | User: $($Report.Metadata.UserName)</div>")

        if (-not [string]::IsNullOrWhiteSpace($Report.Summary)) {
            [void]$sb.AppendLine("<p>$([System.Net.WebUtility]::HtmlEncode($Report.Summary))</p>")
        }

        $scoreProps = @($Report.Scores.PSObject.Properties)
        if ($scoreProps.Count -gt 0) {
            [void]$sb.AppendLine('<h2>Scores</h2>')
            [void]$sb.AppendLine('<table><tr><th>Metric</th><th>Score</th><th></th></tr>')
            foreach ($p in $scoreProps) {
                $val = [math]::Round([double]$p.Value, 1)
                [void]$sb.AppendLine("<tr><td>$($p.Name)</td><td>$val</td><td><div class='score-bar-bg'><div class='score-bar-fill' style='width:$val%;'></div></div></td></tr>")
            }
            [void]$sb.AppendLine('</table>')
        }

        foreach ($section in $Report.Sections) {
            [void]$sb.AppendLine("<h2>$([System.Net.WebUtility]::HtmlEncode($section.Title))</h2>")

            $content = $section.Content
            if ($content -is [string]) {
                [void]$sb.AppendLine("<p>$([System.Net.WebUtility]::HtmlEncode($content))</p>")
            }
            elseif ($null -ne $content) {
                $fragment = $content | ConvertTo-Html -Fragment
                [void]$sb.AppendLine(($fragment -join "`n"))
            }
        }

        if ($Report.Recommendations.Count -gt 0) {
            [void]$sb.AppendLine('<h2>Recommendations</h2>')
            [void]$sb.AppendLine('<table><tr><th>Severity</th><th>Category</th><th>Title</th><th>Description</th><th>Auto-Fix</th><th>Links</th></tr>')
            foreach ($rec in $Report.Recommendations) {
                $autoFixCell = if ($rec.CanAutoFix) {
                    "<span class='autofix-yes'>Apply Fix ($([System.Net.WebUtility]::HtmlEncode($rec.FixId)))</span>"
                }
                else {
                    "<span class='autofix-no'>Manual</span>"
                }

                $linksCell = [System.Collections.Generic.List[string]]::new()
                if (-not [string]::IsNullOrWhiteSpace($rec.DocumentationLink)) {
                    $linksCell.Add("<a href='$($rec.DocumentationLink)' style='color:#4fc3f7;'>Docs</a>")
                }
                if (-not [string]::IsNullOrWhiteSpace($rec.LearnMore)) {
                    $linksCell.Add([System.Net.WebUtility]::HtmlEncode($rec.LearnMore))
                }

                [void]$sb.AppendLine("<tr><td class='severity-$($rec.Severity)'>$($rec.Severity)</td><td>$([System.Net.WebUtility]::HtmlEncode($rec.Category))</td><td>$([System.Net.WebUtility]::HtmlEncode($rec.Title))</td><td>$([System.Net.WebUtility]::HtmlEncode($rec.Description))</td><td>$autoFixCell</td><td>$($linksCell -join ' | ')</td></tr>")
            }
            [void]$sb.AppendLine('</table>')
        }

        # ---- Branding footer ----
        [void]$sb.AppendLine('<div class="brand-footer">')
        [void]$sb.AppendLine("Generated by $([System.Net.WebUtility]::HtmlEncode($productInfo.ProductName))<br/>")
        [void]$sb.AppendLine("Generated UTC: $($Report.GeneratedUtc)<br/>")
        [void]$sb.AppendLine("Version: $($productInfo.Version) | Build: $($productInfo.BuildNumber) | Channel: $($productInfo.ReleaseChannel)")
        [void]$sb.AppendLine('</div>')

        [void]$sb.AppendLine('</body></html>')

        return $sb.ToString()
    }
    catch {
        throw "ConvertTo-TetraReportHtml: Failed to render HTML report - $($_.Exception.Message)"
    }
}

# ============================================================
# FUNCTION: Register-TetraReportRenderer
# ============================================================
<#
.SYNOPSIS
    Registers a report renderer under a format name (the Export System).
.DESCRIPTION
    This is the single extension point for adding new export formats.
    A renderer is any function that accepts -Report <PSCustomObject> and
    returns a string. To add PDF support later: write
    ConvertTo-TetraReportPdf, then call
    Register-TetraReportRenderer -Format PDF -Extension pdf -FunctionName ConvertTo-TetraReportPdf.
    No other function in this file needs to change.
.PARAMETER Format
    Short format name, e.g. "TXT", "HTML", "PDF". Case-insensitive
    (normalized to uppercase internally).
.PARAMETER Extension
    File extension to use when saving (without the leading dot).
.PARAMETER FunctionName
    Name of an existing function that renders a report to a string.
.OUTPUTS
    None.
#>
function Register-TetraReportRenderer {
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Format,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Extension,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$FunctionName
    )

    try {
        if (-not (Get-Command -Name $FunctionName -ErrorAction SilentlyContinue)) {
            throw "Renderer function '$FunctionName' does not exist. Define it before registering."
        }

        $Script:TetraReportRenderers[$Format.ToUpperInvariant()] = [PSCustomObject]@{
            Format       = $Format.ToUpperInvariant()
            Extension    = $Extension.TrimStart('.').ToLowerInvariant()
            FunctionName = $FunctionName
        }
    }
    catch {
        throw "Register-TetraReportRenderer: Failed to register renderer for '$Format' - $($_.Exception.Message)"
    }
}

# ============================================================
# FUNCTION: Get-TetraReportFormats
# ============================================================
<#
.SYNOPSIS
    Returns the list of currently registered export format names.
.OUTPUTS
    System.String[]
#>
function Get-TetraReportFormats {
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    return @($Script:TetraReportRenderers.Keys)
}

# ============================================================
# FUNCTION: Get-TetraReportRenderer
# ============================================================
<#
.SYNOPSIS
    Looks up the registered renderer info for a given format.
.PARAMETER Format
    The format name to look up (case-insensitive).
.OUTPUTS
    System.Management.Automation.PSCustomObject: Format, Extension, FunctionName
#>
function Get-TetraReportRenderer {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Format
    )

    $normalizedFormat = $Format.ToUpperInvariant()

    if (-not $Script:TetraReportRenderers.Contains($normalizedFormat)) {
        $available = (Get-TetraReportFormats) -join ', '
        throw "Get-TetraReportRenderer: Unknown report format '$Format'. Available formats: $available"
    }

    return $Script:TetraReportRenderers[$normalizedFormat]
}

# ============================================================
# FUNCTION: Save-TetraReport
# ============================================================
<#
.SYNOPSIS
    Renders a report using the registered renderer for the requested
    format and saves it to the Reports folder.
.PARAMETER Report
    The report object to save.
.PARAMETER Format
    Any format registered via Register-TetraReportRenderer (TXT, HTML,
    JSON by default).
.PARAMETER FileName
    Optional explicit file name (extension added automatically if missing).
    If omitted, a name is generated from the report's Title and a UTC
    timestamp.
.OUTPUTS
    System.String - the full path of the saved file.
#>
function Save-TetraReport {
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Report,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Format,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [string]$FileName
    )

    try {
        $rendererInfo = Get-TetraReportRenderer -Format $Format
        $reportsDir   = Initialize-TetraReportsDirectory

        if ([string]::IsNullOrWhiteSpace($FileName)) {
            $sanitizedTitle   = ($Report.Title -replace '[^\w\-]', '_')
            $timestamp        = (Get-Date).ToUniversalTime().ToString('yyyyMMdd_HHmmss')
            $resolvedFileName = "${sanitizedTitle}_$timestamp.$($rendererInfo.Extension)"
        }
        elseif (-not $FileName.EndsWith(".$($rendererInfo.Extension)", [System.StringComparison]::OrdinalIgnoreCase)) {
            $resolvedFileName = "$FileName.$($rendererInfo.Extension)"
        }
        else {
            $resolvedFileName = $FileName
        }

        # Security: a caller-supplied -FileName must never be able to escape
        # the Reports directory. Reject path separators / parent-directory
        # references outright rather than silently sanitizing them, so a
        # bad caller gets a clear error instead of a silently-redirected
        # write.
        if ($resolvedFileName -match '[\\/]' -or $resolvedFileName -match '\.\.') {
            throw "FileName '$FileName' must not contain path separators or parent-directory references."
        }

        $filePath = Join-Path -Path $reportsDir -ChildPath $resolvedFileName

        # Defense in depth: independently verify the fully-resolved path
        # still lives inside the Reports directory before writing anything.
        $resolvedFullPath   = [System.IO.Path]::GetFullPath($filePath)
        $resolvedReportsDir = [System.IO.Path]::GetFullPath($reportsDir)
        if (-not $resolvedFullPath.StartsWith($resolvedReportsDir, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Resolved report path '$resolvedFullPath' escapes the Reports directory - refusing to save."
        }

        $fileAlreadyExists = Test-Path -LiteralPath $filePath
        $content           = & $rendererInfo.FunctionName -Report $Report

        if ($PSCmdlet.ShouldProcess($filePath, "Save $($rendererInfo.Format) report")) {
            if ($fileAlreadyExists) {
                Write-TetraLog -Level 'Warning' -Module 'ReportEngine' -Action 'Save-TetraReport' `
                    -Target $filePath -Result 'Overwritten' -Message "Existing report file was overwritten: '$filePath'." | Out-Null
            }

            Set-Content -LiteralPath $filePath -Value $content -Encoding UTF8

            Write-TetraLog -Level 'Info' -Module 'ReportEngine' -Action 'Save-TetraReport' `
                -Target $filePath -Result 'Success' -Message "Saved $($rendererInfo.Format) report '$($Report.Title)'." | Out-Null
        }

        return $filePath
    }
    catch {
        Write-TetraLog -Level 'Error' -Module 'ReportEngine' -Action 'Save-TetraReport' `
            -Target $FileName -Result 'Failed' -Message $_.Exception.Message | Out-Null

        throw "Save-TetraReport: Failed to save $Format report - $($_.Exception.Message)"
    }
}

# ============================================================
# FUNCTION: Save-TetraReportAllFormats
# ============================================================
<#
.SYNOPSIS
    Saves a report in every currently registered export format.
.DESCRIPTION
    Iterates Get-TetraReportFormats rather than a hardcoded list, so
    saving "all formats" automatically picks up any format registered via
    Register-TetraReportRenderer - including future ones - with zero
    changes to this function.
.PARAMETER Report
    The report object to save.
.PARAMETER BaseFileName
    Optional shared base file name (without extension) used for every
    output file. If omitted, each format gets its own auto-generated name.
.OUTPUTS
    System.String[] - the saved file paths, in registration order.
#>
function Save-TetraReportAllFormats {
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Report,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [string]$BaseFileName
    )

    try {
        $paths = [System.Collections.Generic.List[string]]::new()

        foreach ($format in (Get-TetraReportFormats)) {
            $paths.Add((Save-TetraReport -Report $Report -Format $format -FileName $BaseFileName))
        }

        return $paths.ToArray()
    }
    catch {
        throw "Save-TetraReportAllFormats: Failed to save report in all formats - $($_.Exception.Message)"
    }
}

# ============================================================
# DEFAULT RENDERER REGISTRATION
# ============================================================
# Registered here, at dot-source time, so Save-TetraReport /
# Save-TetraReportAllFormats / Get-TetraReportFormats work immediately
# after this file is loaded. Future formats (PDF, CSV, XML, Markdown) are
# added by writing one ConvertTo-TetraReportX function and one more
# Register-TetraReportRenderer call here.
Register-TetraReportRenderer -Format 'TXT'  -Extension 'txt'  -FunctionName 'ConvertTo-TetraReportText'
Register-TetraReportRenderer -Format 'HTML' -Extension 'html' -FunctionName 'ConvertTo-TetraReportHtml'
Register-TetraReportRenderer -Format 'JSON' -Extension 'json' -FunctionName 'ConvertTo-TetraReportJson'

# ============================================================
# MODULE API SURFACE
# ============================================================
# NOTE: documented convention, not an enforced boundary (see
# Config/PathHelpers.ps1 for the full explanation).
#
# Public Functions (intended for use by other modules):
#   - Get-TetraReportTypes         (zero current callers - introspection
#     API for a future Core report-filter menu)
#   - Initialize-TetraReportsDirectory (used by Bootstrap)
#   - New-TetraReport              (used by Tests)
#   - Add-TetraReportSection       (used by Tests)
#   - Add-TetraReportRecommendation (used by Tests)
#   - Set-TetraReportScore         (used by Tests)
#   - New-TetraOperationReport     (zero current callers outside this
#     file's own design - intended for Tetra.ps1/Core once real
#     operations exist to report on)
#   - ConvertTo-TetraReportJson    (used by Tests directly, and
#     indirectly via the renderer registry)
#   - ConvertTo-TetraReportText    (same)
#   - ConvertTo-TetraReportHtml    (same)
#   - Register-TetraReportRenderer (currently only self-invoked at the
#     bottom of this file for TXT/HTML/JSON - but this IS its intended
#     public extension point for whoever adds PDF/CSV/XML/Markdown later)
#   - Get-TetraReportFormats       (used by Tests)
#   - Get-TetraReportRenderer      (used by Tests and internally by
#     Save-TetraReport)
#   - Save-TetraReport             (used by Tests)
#   - Save-TetraReportAllFormats   (used by Tests)
#
# Internal Functions (implementation details):
#   - Get-TetraReportsDirectory
