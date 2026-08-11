#Requires -Version 5.1
<#
.SYNOPSIS
    Tetra Optimizer - Core Orchestrator Smoke Test Suite
.DESCRIPTION
    Lightweight, fast validation of Core/Orchestrator.ps1. Separate file
    from the Foundation (11) and Backup Engine (21) smoke test suites,
    which this file never touches, imports logic from, or re-runs.

    Tests 3/4 temporarily change the real, persistent
    Backup.AutoBackupBeforeChanges config value on disk in order to test
    both states of that setting - the original value is captured once at
    suite start and restored in a finally block so this suite never
    leaves the user's actual Config.json altered.
.NOTES
    Module      : Invoke-TetraCoreSmokeTests.ps1
    Layer       : Tests (developer tooling, not part of the application)
    Build Phase : Core Orchestrator
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Script:TetraCoreTestsDir       = $PSScriptRoot
$Script:TetraCoreProjectRootDir = Split-Path -Path $Script:TetraCoreTestsDir -Parent
$Script:TetraCoreBootstrapPath  = Join-Path -Path $Script:TetraCoreProjectRootDir -ChildPath 'Bootstrap\Initialize-Tetra.ps1'

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

function New-TetraCoreTestFile {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $false)]
        [string]$Content = 'Tetra Core smoke test content.'
    )

    $path = Join-Path -Path $env:TEMP -ChildPath "TetraCoreSmokeTest_$([guid]::NewGuid().ToString('N')).txt"
    Set-Content -LiteralPath $path -Value $Content -Encoding UTF8 -NoNewline
    return $path
}

$Script:TetraCoreSmokeTestResults = [System.Collections.Generic.List[PSCustomObject]]::new()
$Script:TetraCoreTestTempFiles    = [System.Collections.Generic.List[string]]::new()

# ============================================================
# TEST 1: Bootstrap loads Orchestrator
# ============================================================
$bootstrapTest = [PSCustomObject]@{ TestName = 'Bootstrap Loads Orchestrator'; Passed = $false; DurationMs = 0.0; ErrorMessage = '' }
$bootstrapStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

try {
    . $Script:TetraCoreBootstrapPath

    $bootstrapResult = Get-TetraBootstrapResult
    Assert-TetraTrue -Condition ($null -ne $bootstrapResult) -Message 'Get-TetraBootstrapResult returned $null.'
    Assert-TetraTrue -Condition $bootstrapResult.Success -Message "Bootstrap reported failure: $($bootstrapResult.FailedModules | ConvertTo-Json -Compress)"
    Assert-TetraTrue -Condition ($bootstrapResult.LoadedModules -contains 'Orchestrator') -Message "'Orchestrator' was not reported as loaded by Bootstrap."

    $bootstrapTest.Passed = $true
}
catch {
    $bootstrapTest.ErrorMessage = $_.Exception.Message
}
finally {
    $bootstrapStopwatch.Stop()
    $bootstrapTest.DurationMs = $bootstrapStopwatch.Elapsed.TotalMilliseconds
}

$Script:TetraCoreSmokeTestResults.Add($bootstrapTest)

# Capture the real, persistent config value once, to restore at the end.
$Script:TetraCoreOriginalAutoBackupSetting = Get-TetraConfigValueOrDefault -Path 'Backup.AutoBackupBeforeChanges' -Default $true

# ============================================================
# TEST 2: Protected operation executes and returns success
# ============================================================
$Script:TetraCoreSmokeTestResults.Add((Invoke-TetraSmokeTest -Name 'Protected Operation Executes And Returns Success' -Test {
    $result = Invoke-TetraProtectedOperation -StepName 'SmokeTest-BasicSuccess' -ScriptBlock { return 'ok' }

    Assert-TetraTrue -Condition $result.Success -Message 'Invoke-TetraProtectedOperation did not report success.'
    Assert-TetraTrue -Condition ($result.Output -eq 'ok') -Message "Expected Output 'ok', got '$($result.Output)'."
    Assert-TetraTrue -Condition ($null -eq $result.BackupId) -Message 'BackupId should be $null when no PathsToProtect were given.'
}))

# ============================================================
# TEST 3: Backup taken when AutoBackupBeforeChanges=true + paths given
# ============================================================
$Script:TetraCoreSmokeTestResults.Add((Invoke-TetraSmokeTest -Name 'Backup Taken When AutoBackup Enabled' -Test {
    Set-TetraConfigValue -Path 'Backup.AutoBackupBeforeChanges' -Value $true | Out-Null

    $file = New-TetraCoreTestFile -Content 'auto backup enabled test'
    $Script:TetraCoreTestTempFiles.Add($file)

    $result = Invoke-TetraProtectedOperation -StepName 'SmokeTest-AutoBackupEnabled' -PathsToProtect @($file) -Category 'General' -ScriptBlock { return 'done' }

    Assert-TetraTrue -Condition $result.Success -Message 'Protected operation did not report success.'
    Assert-TetraTrue -Condition (-not [string]::IsNullOrWhiteSpace($result.BackupId)) -Message 'Expected a BackupId when AutoBackupBeforeChanges is true and paths were given.'

    $listed = Get-TetraBackupList -Category 'General' | Where-Object { $_.BackupId -eq $result.BackupId }
    Assert-TetraTrue -Condition ($null -ne $listed) -Message 'The backup taken by Invoke-TetraProtectedOperation was not found via Get-TetraBackupList.'
}))

# ============================================================
# TEST 4: Backup skipped when AutoBackupBeforeChanges=false
# ============================================================
$Script:TetraCoreSmokeTestResults.Add((Invoke-TetraSmokeTest -Name 'Backup Skipped When AutoBackup Disabled' -Test {
    Set-TetraConfigValue -Path 'Backup.AutoBackupBeforeChanges' -Value $false | Out-Null

    $file = New-TetraCoreTestFile -Content 'auto backup disabled test'
    $Script:TetraCoreTestTempFiles.Add($file)

    $result = Invoke-TetraProtectedOperation -StepName 'SmokeTest-AutoBackupDisabled' -PathsToProtect @($file) -Category 'General' -ScriptBlock { return 'done' }

    Assert-TetraTrue -Condition $result.Success -Message 'Protected operation did not report success.'
    Assert-TetraTrue -Condition ($null -eq $result.BackupId) -Message 'Expected BackupId to be $null when AutoBackupBeforeChanges is false.'
}))

# ============================================================
# TEST 5: Auto-rollback on scriptblock failure
# ============================================================
$Script:TetraCoreSmokeTestResults.Add((Invoke-TetraSmokeTest -Name 'Auto-Rollback On Scriptblock Failure' -Test {
    Set-TetraConfigValue -Path 'Backup.AutoBackupBeforeChanges' -Value $true | Out-Null

    $file = New-TetraCoreTestFile -Content 'ORIGINAL CONTENT'
    $Script:TetraCoreTestTempFiles.Add($file)

    $threw = $false
    try {
        Invoke-TetraProtectedOperation -StepName 'SmokeTest-RollbackOnFailure' -PathsToProtect @($file) -Category 'General' -ScriptBlock {
            Set-Content -LiteralPath $file -Value 'CHANGED BY FAILED OPERATION' -Encoding UTF8 -NoNewline
            throw 'Simulated operation failure.'
        } | Out-Null
    }
    catch {
        $threw = $true
        Assert-TetraTrue -Condition ($_.Exception.Message -like '*Simulated operation failure*') -Message "Re-thrown error did not contain the original failure message: $($_.Exception.Message)"
        Assert-TetraTrue -Condition ($_.Exception.Message -like '*automatically restored*') -Message "Re-thrown error did not confirm rollback: $($_.Exception.Message)"
    }

    Assert-TetraTrue -Condition $threw -Message 'Invoke-TetraProtectedOperation did not throw despite the scriptblock failing.'
    Assert-TetraTrue -Condition ((Get-Content -LiteralPath $file -Raw) -eq 'ORIGINAL CONTENT') -Message 'File was not rolled back to its original content after the simulated failure.'
}))

# ============================================================
# TEST 6: Auto-rollback failure reported honestly
# ============================================================
$Script:TetraCoreSmokeTestResults.Add((Invoke-TetraSmokeTest -Name 'Auto-Rollback Failure Is Reported Honestly' -Test {
    Set-TetraConfigValue -Path 'Backup.AutoBackupBeforeChanges' -Value $true | Out-Null

    $tempRoot = Join-Path -Path $env:TEMP -ChildPath "TetraCoreSmokeTest_RollbackFail_$([guid]::NewGuid().ToString('N'))"
    New-Item -Path $tempRoot -ItemType Directory -Force | Out-Null

    try {
        $file1 = Join-Path -Path $tempRoot -ChildPath 'file1.txt'
        Set-Content -LiteralPath $file1 -Value 'ORIGINAL1' -Encoding UTF8 -NoNewline

        $subDir = Join-Path -Path $tempRoot -ChildPath 'sub'
        New-Item -Path $subDir -ItemType Directory -Force | Out-Null
        $file2 = Join-Path -Path $subDir -ChildPath 'file2.txt'
        Set-Content -LiteralPath $file2 -Value 'ORIGINAL2' -Encoding UTF8 -NoNewline

        $threw = $false
        try {
            Invoke-TetraProtectedOperation -StepName 'SmokeTest-RollbackFailure' -PathsToProtect @($file1, $file2) -Category 'General' -ScriptBlock {
                # Modify file1 (rollback for this one would normally
                # succeed), then break file2's destination so the
                # RESTORE itself cannot write it back - forcing the
                # rollback attempt to genuinely fail for that item.
                Set-Content -LiteralPath $file1 -Value 'CHANGED1' -Encoding UTF8 -NoNewline
                Remove-Item -LiteralPath $subDir -Recurse -Force
                Set-Content -LiteralPath $subDir -Value 'blocker file, not a directory' -Encoding UTF8 -NoNewline
                throw 'Simulated failure requiring rollback.'
            } | Out-Null
        }
        catch {
            $threw = $true
            Assert-TetraTrue -Condition ($_.Exception.Message -like '*Automatic rollback also failed*') -Message "Error message did not honestly report a rollback failure: $($_.Exception.Message)"
        }

        Assert-TetraTrue -Condition $threw -Message 'Invoke-TetraProtectedOperation did not throw in the rollback-failure scenario.'
    }
    finally {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}))

# ============================================================
# TEST 7: Workflow correlates multiple steps under one OperationId
# ============================================================
$Script:TetraCoreSmokeTestResults.Add((Invoke-TetraSmokeTest -Name 'Workflow Correlates Steps Under One OperationId' -Test {
    Complete-TetraWorkflow | Out-Null   # defensive: ensure a clean slot

    $workflow = Start-TetraWorkflow -Name 'SmokeTest-Correlation'

    try {
        Invoke-TetraProtectedOperation -StepName 'SmokeTest-Correlation-Step1' -ScriptBlock { return 1 } | Out-Null
        Invoke-TetraProtectedOperation -StepName 'SmokeTest-Correlation-Step2' -ScriptBlock { return 2 } | Out-Null

        $current = Get-TetraCurrentWorkflow
        Assert-TetraTrue -Condition ($current.Steps.Count -eq 2) -Message "Expected 2 tracked steps, found $($current.Steps.Count)."

        $entries = Get-TetraLogEntries -StartDate (Get-Date).ToUniversalTime().AddMinutes(-5) -EndDate (Get-Date).ToUniversalTime().AddMinutes(5) -OperationId $workflow.WorkflowId
        Assert-TetraTrue -Condition ($entries.Count -ge 4) -Message "Expected at least 4 log entries under this WorkflowId (2 steps x start+complete), found $($entries.Count)."
    }
    finally {
        Complete-TetraWorkflow | Out-Null
    }
}))

# ============================================================
# TEST 8: Complete-TetraWorkflow produces a valid report
# ============================================================
$Script:TetraCoreSmokeTestResults.Add((Invoke-TetraSmokeTest -Name 'Complete-TetraWorkflow Produces Valid Report' -Test {
    Complete-TetraWorkflow | Out-Null

    Start-TetraWorkflow -Name 'SmokeTest-ReportGeneration' | Out-Null
    Invoke-TetraProtectedOperation -StepName 'SmokeTest-ReportGeneration-Step1' -ScriptBlock { return 'ok' } | Out-Null

    $report = Complete-TetraWorkflow

    Assert-TetraTrue -Condition ($null -ne $report) -Message 'Complete-TetraWorkflow returned $null.'
    Assert-TetraTrue -Condition (-not [string]::IsNullOrWhiteSpace($report.Title)) -Message 'Report Title is empty.'

    $stepSection = $report.Sections | Where-Object { $_.Title -eq 'Workflow Steps' }
    Assert-TetraTrue -Condition ($null -ne $stepSection) -Message "Report is missing the 'Workflow Steps' section."
}))

# ============================================================
# TEST 9: Get-TetraCurrentWorkflow reflects state / returns null when idle
# ============================================================
$Script:TetraCoreSmokeTestResults.Add((Invoke-TetraSmokeTest -Name 'Get-TetraCurrentWorkflow Reflects State Correctly' -Test {
    Complete-TetraWorkflow | Out-Null
    Assert-TetraTrue -Condition ($null -eq (Get-TetraCurrentWorkflow)) -Message 'Get-TetraCurrentWorkflow was not $null when idle.'

    Start-TetraWorkflow -Name 'SmokeTest-IdleCheck' | Out-Null
    Assert-TetraTrue -Condition ((Get-TetraCurrentWorkflow).Name -eq 'SmokeTest-IdleCheck') -Message 'Get-TetraCurrentWorkflow did not reflect the active workflow name.'

    Complete-TetraWorkflow | Out-Null
    Assert-TetraTrue -Condition ($null -eq (Get-TetraCurrentWorkflow)) -Message 'Get-TetraCurrentWorkflow was not $null after completing the workflow.'
}))

# ============================================================
# TEST 10: Complete-TetraWorkflow safely callable after a step failure
# ============================================================
$Script:TetraCoreSmokeTestResults.Add((Invoke-TetraSmokeTest -Name 'Complete-TetraWorkflow Safe After Step Failure' -Test {
    Complete-TetraWorkflow | Out-Null

    Start-TetraWorkflow -Name 'SmokeTest-FailureThenComplete' | Out-Null

    try {
        Invoke-TetraProtectedOperation -StepName 'SmokeTest-WillFail' -ScriptBlock { throw 'Intentional test failure.' } | Out-Null
    }
    catch {
        # Expected - the step itself is designed to fail.
    }

    $reportThrew = $false
    $report = $null
    try {
        $report = Complete-TetraWorkflow
    }
    catch {
        $reportThrew = $true
    }

    Assert-TetraTrue -Condition (-not $reportThrew) -Message 'Complete-TetraWorkflow threw after a step failure instead of completing safely.'
    Assert-TetraTrue -Condition ($null -ne $report) -Message 'Complete-TetraWorkflow returned $null after a step failure.'
    Assert-TetraTrue -Condition ($null -eq (Get-TetraCurrentWorkflow)) -Message 'Workflow slot was not cleared after Complete-TetraWorkflow.'
}))

# ============================================================
# TEST 11: Starting a second workflow while one is active throws
# ============================================================
$Script:TetraCoreSmokeTestResults.Add((Invoke-TetraSmokeTest -Name 'Second Workflow While Active Throws' -Test {
    Complete-TetraWorkflow | Out-Null

    Start-TetraWorkflow -Name 'SmokeTest-FirstWorkflow' | Out-Null

    $threw = $false
    try {
        Start-TetraWorkflow -Name 'SmokeTest-SecondWorkflow' | Out-Null
    }
    catch {
        $threw = $true
    }
    finally {
        Complete-TetraWorkflow | Out-Null
    }

    Assert-TetraTrue -Condition $threw -Message 'Start-TetraWorkflow did not throw when a workflow was already active.'
}))

# ============================================================
# TEST 12: Every step's logs carry SessionId/DeviceId
# ============================================================
$Script:TetraCoreSmokeTestResults.Add((Invoke-TetraSmokeTest -Name 'Protected Operation Logs Carry SessionId/DeviceId' -Test {
    $marker = "SmokeTest-Correlation-$([guid]::NewGuid().ToString('N'))"
    Invoke-TetraProtectedOperation -StepName $marker -ScriptBlock { return 'ok' } | Out-Null

    $entry = Get-TetraLogEntries -StartDate (Get-Date).ToUniversalTime().AddMinutes(-5) -EndDate (Get-Date).ToUniversalTime().AddMinutes(5) `
        -Module 'Orchestrator' | Where-Object { $_.Target -eq $marker -and $_.Action -eq 'ProtectedOperationCompleted' } | Select-Object -First 1

    Assert-TetraTrue -Condition ($null -ne $entry) -Message 'ProtectedOperationCompleted log entry was not found.'
    Assert-TetraTrue -Condition (-not [string]::IsNullOrWhiteSpace($entry.SessionId)) -Message 'Log entry is missing SessionId.'
    Assert-TetraTrue -Condition (-not [string]::IsNullOrWhiteSpace($entry.DeviceId)) -Message 'Log entry is missing DeviceId.'
}))

# ============================================================
# TEST 13: PathsToProtect inside a protected directory is rejected
# ============================================================
$Script:TetraCoreSmokeTestResults.Add((Invoke-TetraSmokeTest -Name 'Protected-Directory Source Is Rejected' -Test {
    $insideConfigDir = Join-Path -Path $Script:TetraCoreProjectRootDir -ChildPath 'Config\Config.ps1'

    $threw = $false
    try {
        Invoke-TetraProtectedOperation -StepName 'SmokeTest-ProtectedDirRejection' -PathsToProtect @($insideConfigDir) -Category 'General' -ScriptBlock { return 'should not run' } | Out-Null
    }
    catch {
        $threw = $true
        Assert-TetraTrue -Condition ($_.Exception.Message -like '*protected*') -Message "Error did not mention a protected directory: $($_.Exception.Message)"
    }

    Assert-TetraTrue -Condition $threw -Message 'Invoke-TetraProtectedOperation did not reject a source path inside the protected Config directory.'
}))

# ============================================================
# Restore the real config value to whatever it was before this suite ran.
# ============================================================
try {
    Set-TetraConfigValue -Path 'Backup.AutoBackupBeforeChanges' -Value $Script:TetraCoreOriginalAutoBackupSetting | Out-Null
}
catch {
    Write-Verbose "Failed to restore original Backup.AutoBackupBeforeChanges setting - $($_.Exception.Message)"
}

# ============================================================
# TEST CLEANUP: remove temp source files created during this run
# ============================================================
foreach ($tempFile in $Script:TetraCoreTestTempFiles) {
    if (Test-Path -LiteralPath $tempFile) {
        Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
    }
}

# ============================================================
# FUNCTION: Get-TetraCoreSmokeTestResults
# ============================================================
function Get-TetraCoreSmokeTestResults {
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param()

    return $Script:TetraCoreSmokeTestResults
}

# ============================================================
# RESULTS REPORTING (console output intentional - standalone dev tooling)
# ============================================================
$passCount  = @($Script:TetraCoreSmokeTestResults | Where-Object { $_.Passed }).Count
$failCount  = @($Script:TetraCoreSmokeTestResults | Where-Object { -not $_.Passed }).Count
$totalCount = $Script:TetraCoreSmokeTestResults.Count
$allPassed  = ($passCount -eq $totalCount)

Write-Host ''
Write-Host '===== Tetra Optimizer - Core Orchestrator Smoke Test Results =====' -ForegroundColor Cyan

foreach ($testResult in $Script:TetraCoreSmokeTestResults) {
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
# EXIT BEHAVIOR (dot-source-safe - same rationale as the other two suites)
# ============================================================
$Script:TetraCoreSmokeTestSummary = [PSCustomObject]@{
    PassCount  = $passCount
    FailCount  = $failCount
    TotalCount = $totalCount
    AllPassed  = $allPassed
    Overall    = if ($allPassed) { 'PASS' } else { 'FAIL' }
}

function Get-TetraCoreSmokeTestSummary {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param()

    return $Script:TetraCoreSmokeTestSummary
}

$Script:TetraCoreSmokeTestsWereDotSourced = ($MyInvocation.InvocationName -eq '.')

if (-not $allPassed) {
    if ($Script:TetraCoreSmokeTestsWereDotSourced) {
        Write-Host 'One or more Core Orchestrator smoke tests failed. Not calling exit (script was dot-sourced) - inspect $TetraCoreSmokeTestSummary or call Get-TetraCoreSmokeTestSummary for the result.' -ForegroundColor DarkYellow
    }
    else {
        exit 1
    }
}
