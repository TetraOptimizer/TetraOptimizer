#Requires -Version 5.1
<#
.SYNOPSIS
    Tetra Optimizer - Foundation Smoke Test Suite
.DESCRIPTION
    Lightweight, fast (seconds, not minutes) validation that the
    foundation loads correctly and behaves as documented. Intended to be
    run after any change to Bootstrap, Config, or Engine foundation files,
    before building further on top of them.

    SCOPE NOTE:
        This is standalone developer tooling - it is not part of the
        Core/Engine layered application (it is not shipped, it is not
        loaded by Tetra.ps1). It is therefore intentionally exempt from
        the "no Write-Host outside Core" rule: its entire purpose is to
        report results to a human running it from a console.

    WHAT IS VERIFIED:
        1. Bootstrap loads every module in the manifest, in order
        2. Load manifest has no ordering/circular-dependency violations
        3. ProductInfo returns a complete, non-empty identity
        4. DeviceIdentity is stable across calls and persisted to disk
        5. Logger enriches every entry (OperationId, SessionId, DeviceId,
           TetraVersion)
        6. Logger's Operation Context correctly correlates entries under
           one OperationId
        7. Logger's Get-TetraLogEntries round-trips a just-written entry
        8. Report Engine builds, renders (TXT/HTML/JSON), and saves reports
        9. Save-TetraReport's path-traversal guard rejects unsafe filenames
        10. Renderer registration exposes exactly the expected formats and
            rejects unknown ones

    EXIT CODE:
        0 if all tests passed, 1 otherwise - safe to use in CI/build
        scripts.
.NOTES
    Module      : Invoke-TetraSmokeTests.ps1
    Layer       : Tests (developer tooling, not part of the application)
    Build Phase : Foundation Validation
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Script:TetraTestsDir       = $PSScriptRoot
$Script:TetraProjectRootDir = Split-Path -Path $Script:TetraTestsDir -Parent
$Script:TetraBootstrapPath  = Join-Path -Path $Script:TetraProjectRootDir -ChildPath 'Bootstrap\Initialize-Tetra.ps1'

# ============================================================
# FUNCTION: Assert-TetraTrue
# ============================================================
<#
.SYNOPSIS
    Throws with a clear message if a condition is false. Shared assertion
    helper so individual tests don't each re-implement "if not X, throw".
.PARAMETER Condition
    The boolean condition being asserted.
.PARAMETER Message
    The failure message to throw if Condition is false.
#>
function Assert-TetraTrue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Condition,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

# ============================================================
# FUNCTION: Invoke-TetraSmokeTest
# ============================================================
<#
.SYNOPSIS
    Runs a single named test scriptblock, catching and recording any
    failure rather than stopping the whole suite.
.PARAMETER Name
    Human-readable test name.
.PARAMETER Test
    Scriptblock containing the test body. Should throw (e.g. via
    Assert-TetraTrue) to indicate failure; returning normally means pass.
.OUTPUTS
    System.Management.Automation.PSCustomObject: TestName, Passed,
    DurationMs, ErrorMessage
#>
function Invoke-TetraSmokeTest {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [scriptblock]$Test
    )

    $result = [PSCustomObject]@{
        TestName     = $Name
        Passed       = $false
        DurationMs   = 0.0
        ErrorMessage = ''
    }

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        & $Test | Out-Null
        $result.Passed = $true
    }
    catch {
        $result.Passed       = $false
        $result.ErrorMessage = $_.Exception.Message
    }
    finally {
        $stopwatch.Stop()
        $result.DurationMs = $stopwatch.Elapsed.TotalMilliseconds
    }

    return $result
}

$Script:TetraSmokeTestResults = [System.Collections.Generic.List[PSCustomObject]]::new()

# ============================================================
# TEST 1: Bootstrap loads every module, in order
# ============================================================
# NOTE: the dot-source below is intentionally at THIS SCRIPT'S TOP-LEVEL
# SCOPE (not inside Invoke-TetraSmokeTest), for the same scoping reason
# documented in Initialize-Tetra.ps1 - otherwise every function it loads
# would vanish before Test 2 onward could use them.
$bootstrapTest = [PSCustomObject]@{ TestName = 'Bootstrap Loads All Modules In Order'; Passed = $false; DurationMs = 0.0; ErrorMessage = '' }
$bootstrapStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

try {
    . $Script:TetraBootstrapPath

    $bootstrapResult = Get-TetraBootstrapResult
    Assert-TetraTrue -Condition ($null -ne $bootstrapResult) -Message 'Get-TetraBootstrapResult returned $null.'
    Assert-TetraTrue -Condition $bootstrapResult.Success -Message "Bootstrap reported failure: $($bootstrapResult.FailedModules | ConvertTo-Json -Compress)"

    foreach ($expectedModule in @('PathHelpers', 'ProductInfo', 'DeviceIdentity', 'Config', 'LoggerEngine', 'ReportEngine')) {
        Assert-TetraTrue -Condition ($bootstrapResult.LoadedModules -contains $expectedModule) -Message "Module '$expectedModule' was not reported as loaded."
    }

    $bootstrapTest.Passed = $true
}
catch {
    $bootstrapTest.ErrorMessage = $_.Exception.Message
}
finally {
    $bootstrapStopwatch.Stop()
    $bootstrapTest.DurationMs = $bootstrapStopwatch.Elapsed.TotalMilliseconds
}

$Script:TetraSmokeTestResults.Add($bootstrapTest)

# ============================================================
# TEST 2: Load manifest has no ordering/circular-dependency violations
# ============================================================
$Script:TetraSmokeTestResults.Add((Invoke-TetraSmokeTest -Name 'Load Manifest Has No Circular/Out-Of-Order Dependencies' -Test {
    $manifest   = Get-TetraLoadManifest
    $validation = Test-TetraLoadManifestOrder -Manifest $manifest
    Assert-TetraTrue -Condition $validation.IsValid -Message "Manifest has ordering violations: $($validation.Violations -join ' | ')"
}))

# ============================================================
# TEST 3: ProductInfo returns a complete, non-empty identity
# ============================================================
$Script:TetraSmokeTestResults.Add((Invoke-TetraSmokeTest -Name 'ProductInfo Returns Complete Identity' -Test {
    $info = Get-TetraProductInfo
    Assert-TetraTrue -Condition (-not [string]::IsNullOrWhiteSpace($info.ProductName)) -Message 'ProductName is empty.'
    Assert-TetraTrue -Condition (-not [string]::IsNullOrWhiteSpace($info.CompanyName)) -Message 'CompanyName is empty.'
    Assert-TetraTrue -Condition (-not [string]::IsNullOrWhiteSpace($info.Version)) -Message 'Version is empty.'
    Assert-TetraTrue -Condition (-not [string]::IsNullOrWhiteSpace($info.BuildNumber)) -Message 'BuildNumber is empty.'
    Assert-TetraTrue -Condition (-not [string]::IsNullOrWhiteSpace($info.ReleaseChannel)) -Message 'ReleaseChannel is empty.'
    Assert-TetraTrue -Condition ($info.VersionDisplay -like "*$($info.Version)*") -Message 'VersionDisplay does not contain Version.'
}))

# ============================================================
# TEST 4: DeviceIdentity is stable across calls and persisted to disk
# ============================================================
$Script:TetraSmokeTestResults.Add((Invoke-TetraSmokeTest -Name 'DeviceId Is Stable And Persisted' -Test {
    $first  = Get-TetraDeviceId
    $second = Get-TetraDeviceId
    Assert-TetraTrue -Condition (-not [string]::IsNullOrWhiteSpace($first)) -Message 'DeviceId is empty.'
    Assert-TetraTrue -Condition ($first -eq $second) -Message 'DeviceId is not stable across calls.'

    $parsedGuid = [guid]::Empty
    Assert-TetraTrue -Condition ([guid]::TryParse($first, [ref]$parsedGuid)) -Message 'DeviceId is not a valid GUID.'

    $identityFilePath = Get-TetraDeviceIdentityFilePath
    Assert-TetraTrue -Condition (Test-Path -LiteralPath $identityFilePath) -Message 'DeviceIdentity.json was not created on disk.'
}))

# ============================================================
# TEST 5: Logger enriches every entry automatically
# ============================================================
$Script:TetraSmokeTestResults.Add((Invoke-TetraSmokeTest -Name 'Write-TetraLog Enriches Entries Automatically' -Test {
    $marker = [guid]::NewGuid().ToString()
    $entry  = Write-TetraLog -Level 'Info' -Module 'SmokeTest' -Action 'Enrichment Check' -Target $marker -Result 'Success' -Message 'Smoke test entry.'

    Assert-TetraTrue -Condition (-not [string]::IsNullOrWhiteSpace($entry.OperationId)) -Message 'OperationId missing from log entry.'
    Assert-TetraTrue -Condition (-not [string]::IsNullOrWhiteSpace($entry.SessionId)) -Message 'SessionId missing from log entry.'
    Assert-TetraTrue -Condition (-not [string]::IsNullOrWhiteSpace($entry.DeviceId)) -Message 'DeviceId missing from log entry.'
    Assert-TetraTrue -Condition (-not [string]::IsNullOrWhiteSpace($entry.TetraVersion)) -Message 'TetraVersion missing from log entry.'
}))

# ============================================================
# TEST 6: Operation Context correlates entries under one OperationId
# ============================================================
$Script:TetraSmokeTestResults.Add((Invoke-TetraSmokeTest -Name 'Operation Context Correlates Log Entries' -Test {
    $context = Start-TetraOperation -Name 'Smoke Test Operation'
    Write-TetraLog -Level 'Info' -Module 'SmokeTest' -Action 'Inside Operation' -Result 'Success' -Message 'Nested log entry.' | Out-Null
    $completed = Stop-TetraOperation

    Assert-TetraTrue -Condition ($completed.OperationId -eq $context.OperationId) -Message 'Stop-TetraOperation returned a mismatched OperationId.'

    $opEntries = Get-TetraLogEntries -StartDate (Get-Date).ToUniversalTime().AddMinutes(-5) -EndDate (Get-Date).ToUniversalTime().AddMinutes(5) -OperationId $context.OperationId.ToString()
    Assert-TetraTrue -Condition ($opEntries.Count -ge 2) -Message "Expected at least 2 log entries for this OperationId, found $($opEntries.Count)."
}))

# ============================================================
# TEST 7: Get-TetraLogEntries round-trips a just-written entry
# ============================================================
$Script:TetraSmokeTestResults.Add((Invoke-TetraSmokeTest -Name 'Log Entries Round-Trip Correctly' -Test {
    $marker = [guid]::NewGuid().ToString()
    Write-TetraLog -Level 'Info' -Module 'SmokeTest' -Action 'RoundTrip Check' -Target $marker -Result 'Success' -Message 'Round trip test.' | Out-Null

    $found = Get-TetraLogEntries -StartDate (Get-Date).ToUniversalTime().AddMinutes(-5) -EndDate (Get-Date).ToUniversalTime().AddMinutes(5) -Module 'SmokeTest' |
        Where-Object { $_.Target -eq $marker }

    Assert-TetraTrue -Condition ($null -ne $found) -Message 'Written log entry could not be retrieved via Get-TetraLogEntries.'
}))

# ============================================================
# TEST 8: Report Engine builds and renders TXT/HTML/JSON
# ============================================================
$Script:TetraSmokeTestResults.Add((Invoke-TetraSmokeTest -Name 'Report Engine Builds And Renders Reports' -Test {
    $report = New-TetraReport -Title 'Smoke Test Report' -ReportType 'General' -Summary 'Automated smoke test report.'
    Add-TetraReportSection -Report $report -Title 'Sample Section' -Content 'Sample content.' | Out-Null
    Add-TetraReportRecommendation -Report $report -Title 'Sample Recommendation' -Description 'Sample description.' `
        -Severity 'Low' -CanAutoFix -FixId 'SMOKE-TEST-FIX' | Out-Null
    Set-TetraReportScore -Report $report -Name 'OverallScore' -Value 90 | Out-Null

    $textContent = ConvertTo-TetraReportText -Report $report
    $htmlContent = ConvertTo-TetraReportHtml -Report $report
    $jsonContent = ConvertTo-TetraReportJson -Report $report

    Assert-TetraTrue -Condition (-not [string]::IsNullOrWhiteSpace($textContent)) -Message 'TXT rendering is empty.'
    Assert-TetraTrue -Condition (-not [string]::IsNullOrWhiteSpace($htmlContent)) -Message 'HTML rendering is empty.'
    Assert-TetraTrue -Condition (-not [string]::IsNullOrWhiteSpace($jsonContent)) -Message 'JSON rendering is empty.'
    Assert-TetraTrue -Condition ($textContent -like '*Smoke Test Report*') -Message 'TXT rendering is missing the report title.'
}))

# ============================================================
# TEST 9: Save-TetraReportAllFormats saves real files, then cleans up
# ============================================================
$Script:TetraSmokeTestResults.Add((Invoke-TetraSmokeTest -Name 'Save-TetraReportAllFormats Saves Files To Disk' -Test {
    $report = New-TetraReport -Title 'Smoke Test Save Report' -ReportType 'General'
    Add-TetraReportSection -Report $report -Title 'Data' -Content 'x' | Out-Null

    $savedPaths = Save-TetraReportAllFormats -Report $report -BaseFileName 'SmokeTestSaveReport_TEMP'

    try {
        Assert-TetraTrue -Condition ($savedPaths.Count -eq 3) -Message "Expected 3 saved files, got $($savedPaths.Count)."
        foreach ($path in $savedPaths) {
            Assert-TetraTrue -Condition (Test-Path -LiteralPath $path) -Message "Saved report file does not exist: $path"
        }
    }
    finally {
        # Clean up test artifacts so repeated smoke test runs don't
        # accumulate garbage in the real Reports/ folder.
        foreach ($path in $savedPaths) {
            if (Test-Path -LiteralPath $path) {
                Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
            }
        }
    }
}))

# ============================================================
# TEST 10: Save-TetraReport rejects path-traversal filenames
# ============================================================
$Script:TetraSmokeTestResults.Add((Invoke-TetraSmokeTest -Name 'Save-TetraReport Rejects Path Traversal' -Test {
    $report = New-TetraReport -Title 'Smoke Test Traversal Report' -ReportType 'General'

    $threwAsExpected = $false
    try {
        Save-TetraReport -Report $report -Format 'TXT' -FileName '..\..\evil' | Out-Null
    }
    catch {
        $threwAsExpected = $true
    }

    Assert-TetraTrue -Condition $threwAsExpected -Message 'Save-TetraReport did not reject a path-traversal FileName as expected.'
}))

# ============================================================
# TEST 11: Renderer registration is correct and rejects unknown formats
# ============================================================
$Script:TetraSmokeTestResults.Add((Invoke-TetraSmokeTest -Name 'Renderer Registration Is Correct' -Test {
    $formats = Get-TetraReportFormats
    foreach ($expectedFormat in @('TXT', 'HTML', 'JSON')) {
        Assert-TetraTrue -Condition ($formats -contains $expectedFormat) -Message "Expected format '$expectedFormat' is not registered."
    }

    $txtRenderer = Get-TetraReportRenderer -Format 'TXT'
    Assert-TetraTrue -Condition ($txtRenderer.FunctionName -eq 'ConvertTo-TetraReportText') -Message 'TXT format is mapped to the wrong function.'

    $threwForUnknownFormat = $false
    try {
        Get-TetraReportRenderer -Format 'PDF' | Out-Null
    }
    catch {
        $threwForUnknownFormat = $true
    }

    Assert-TetraTrue -Condition $threwForUnknownFormat -Message 'Requesting an unregistered format did not throw as expected.'
}))

# ============================================================
# FUNCTION: Get-TetraSmokeTestResults
# ============================================================
<#
.SYNOPSIS
    Returns the full set of smoke test results for programmatic
    consumption (e.g. a future CI pipeline).
.OUTPUTS
    System.Management.Automation.PSCustomObject[]
#>
function Get-TetraSmokeTestResults {
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param()

    return $Script:TetraSmokeTestResults
}

# ============================================================
# RESULTS REPORTING (console output intentional - see file header)
# ============================================================
$passCount  = @($Script:TetraSmokeTestResults | Where-Object { $_.Passed }).Count
$failCount  = @($Script:TetraSmokeTestResults | Where-Object { -not $_.Passed }).Count
$totalCount = $Script:TetraSmokeTestResults.Count
$allPassed  = ($passCount -eq $totalCount)

Write-Host ''
Write-Host '===== Tetra Optimizer - Foundation Smoke Test Results =====' -ForegroundColor Cyan

foreach ($testResult in $Script:TetraSmokeTestResults) {
    $status = if ($testResult.Passed) { 'PASS' } else { 'FAIL' }
    $color  = if ($testResult.Passed) { 'Green' } else { 'Red' }

    Write-Host ("[{0}] {1} ({2} ms)" -f $status, $testResult.TestName, [math]::Round($testResult.DurationMs, 1)) -ForegroundColor $color

    if (-not $testResult.Passed) {
        Write-Host ("        -> $($testResult.ErrorMessage)") -ForegroundColor DarkYellow
    }
}

Write-Host ''
Write-Host ("PASS: {0}/{1}" -f $passCount, $totalCount) -ForegroundColor Green
Write-Host ("FAIL: {0}/{1}" -f $failCount, $totalCount) -ForegroundColor $(if ($failCount -eq 0) { 'Green' } else { 'Red' })
Write-Host ("Overall: {0}" -f $(if ($allPassed) { 'PASS' } else { 'FAIL' })) -ForegroundColor $(if ($allPassed) { 'Green' } else { 'Red' })
Write-Host ''

# ============================================================
# EXIT BEHAVIOR (dot-source-safe)
# ============================================================
# $MyInvocation.InvocationName is '.' when this script was invoked via
# dot-sourcing (". .\Invoke-TetraSmokeTests.ps1"), vs. the script's own
# path/name when run normally (".\Invoke-TetraSmokeTests.ps1").
#
# WHY THE DOT-SOURCED PATH MUST NOT CALL exit:
# Dot-sourcing runs this script's code directly in the CALLER'S OWN
# session scope (that's what makes its functions available afterward -
# see the scoping notes in Bootstrap/Initialize-Tetra.ps1). `exit` does
# not distinguish "end this script" from "end this scope": called from
# a dot-sourced script, it terminates the entire host process - i.e. the
# user's interactive PowerShell window - not just the test run. Running
# as a normal (non-dot-sourced) child script, `exit` correctly ends only
# that child process, which is exactly the behavior CI/automation needs
# for a non-zero exit code to be detected. So: dot-sourced -> never call
# exit, expose the result through a variable/function instead; normal
# execution -> exit is safe and still used, preserving CI behavior.
$Script:TetraSmokeTestSummary = [PSCustomObject]@{
    PassCount   = $passCount
    FailCount   = $failCount
    TotalCount  = $totalCount
    AllPassed   = $allPassed
    Overall     = if ($allPassed) { 'PASS' } else { 'FAIL' }
}

function Get-TetraSmokeTestSummary {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param()

    return $Script:TetraSmokeTestSummary
}

$Script:TetraSmokeTestsWereDotSourced = ($MyInvocation.InvocationName -eq '.')

if (-not $allPassed) {
    if ($Script:TetraSmokeTestsWereDotSourced) {
        Write-Host 'One or more smoke tests failed. Not calling exit (script was dot-sourced) - inspect $TetraSmokeTestSummary or call Get-TetraSmokeTestSummary for the result.' -ForegroundColor DarkYellow
    }
    else {
        exit 1
    }
}
