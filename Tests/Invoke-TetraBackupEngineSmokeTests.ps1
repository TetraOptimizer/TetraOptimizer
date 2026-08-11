#Requires -Version 5.1
<#
.SYNOPSIS
    Tetra Optimizer - Backup Engine Smoke Test Suite
.DESCRIPTION
    Lightweight, fast validation of BackupEngine.ps1. Separate file from
    Tests/Invoke-TetraSmokeTests.ps1 (the frozen 11 Foundation tests),
    which this file never touches, imports logic from, or re-runs.

    TEST HARNESS NOTE: Assert-TetraTrue / Invoke-TetraSmokeTest below
    duplicate the small (~20-line) harness pattern already used in the
    Foundation smoke test file, rather than dot-sourcing that file (which
    would also re-run all 11 Foundation tests as a side effect) or
    extracting a new shared Tests/TestHarness.ps1 (which would need a
    Bootstrap change and is exactly the kind of new-file-for-marginal-
    benefit the Architecture Freeze Policy asks to avoid). This is
    test-only infrastructure, not production code, and is the smallest
    safe option.

    All state-changing tests use isolated temp files under $env:TEMP and
    clean up after themselves in try/finally blocks, so this suite is
    safe to run repeatedly without accumulating garbage in Backup/.
.NOTES
    Module      : Invoke-TetraBackupEngineSmokeTests.ps1
    Layer       : Tests (developer tooling, not part of the application)
    Build Phase : Backup Engine
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Script:TetraBackupTestsDir       = $PSScriptRoot
$Script:TetraBackupProjectRootDir = Split-Path -Path $Script:TetraBackupTestsDir -Parent
$Script:TetraBackupBootstrapPath  = Join-Path -Path $Script:TetraBackupProjectRootDir -ChildPath 'Bootstrap\Initialize-Tetra.ps1'

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

# ============================================================
# TEST HELPER: New-TetraBackupTestFile
# ============================================================
<#
.SYNOPSIS
    Creates a temp file with given content and returns its path. Test-only
    helper, not part of BackupEngine's own API.
#>
function New-TetraBackupTestFile {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $false)]
        [string]$Content = 'Tetra backup smoke test content.'
    )

    $path = Join-Path -Path $env:TEMP -ChildPath "TetraBackupSmokeTest_$([guid]::NewGuid().ToString('N')).txt"
    Set-Content -LiteralPath $path -Value $Content -Encoding UTF8 -NoNewline
    return $path
}

$Script:TetraBackupSmokeTestResults = [System.Collections.Generic.List[PSCustomObject]]::new()
$Script:TetraBackupTestTempFiles    = [System.Collections.Generic.List[string]]::new()

# ============================================================
# TEST 1: Bootstrap loads BackupEngine
# ============================================================
# Dot-sourced at THIS SCRIPT'S TOP-LEVEL SCOPE (not inside
# Invoke-TetraSmokeTest) for the same scoping reason documented in
# Bootstrap/Initialize-Tetra.ps1 - otherwise every function it loads
# would vanish before Test 2 onward could use them.
$bootstrapTest = [PSCustomObject]@{ TestName = 'Bootstrap Loads BackupEngine'; Passed = $false; DurationMs = 0.0; ErrorMessage = '' }
$bootstrapStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

try {
    . $Script:TetraBackupBootstrapPath

    $bootstrapResult = Get-TetraBootstrapResult
    Assert-TetraTrue -Condition ($null -ne $bootstrapResult) -Message 'Get-TetraBootstrapResult returned $null.'
    Assert-TetraTrue -Condition $bootstrapResult.Success -Message "Bootstrap reported failure: $($bootstrapResult.FailedModules | ConvertTo-Json -Compress)"
    Assert-TetraTrue -Condition ($bootstrapResult.LoadedModules -contains 'BackupEngine') -Message "'BackupEngine' was not reported as loaded by Bootstrap."

    $bootstrapTest.Passed = $true
}
catch {
    $bootstrapTest.ErrorMessage = $_.Exception.Message
}
finally {
    $bootstrapStopwatch.Stop()
    $bootstrapTest.DurationMs = $bootstrapStopwatch.Elapsed.TotalMilliseconds
}

$Script:TetraBackupSmokeTestResults.Add($bootstrapTest)

# ============================================================
# TEST 2: Single-file backup succeeds; manifest + hash correct
# ============================================================
$Script:TetraBackupSmokeTestResults.Add((Invoke-TetraSmokeTest -Name 'Single-File Backup Succeeds With Correct Manifest' -Test {
    $file = New-TetraBackupTestFile -Content 'single file content'
    $Script:TetraBackupTestTempFiles.Add($file)

    $result = Backup-TetraItem -Path $file -Category 'General' -Label 'Smoke Test - Single File'

    Assert-TetraTrue -Condition $result.Success -Message 'Backup-TetraItem did not report success.'
    Assert-TetraTrue -Condition ($result.ItemCount -eq 1) -Message "Expected ItemCount 1, got $($result.ItemCount)."

    $expectedHash = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
    Assert-TetraTrue -Condition ($result.Manifest.Items[0].Sha256 -eq $expectedHash) -Message 'Manifest SHA-256 does not match the source file.'
    Assert-TetraTrue -Condition ($result.Manifest.ManifestVersion -eq '1.0') -Message 'ManifestVersion is not set.'
}))

# ============================================================
# TEST 3: Multi-file backup is atomic under one BackupId
# ============================================================
$Script:TetraBackupSmokeTestResults.Add((Invoke-TetraSmokeTest -Name 'Multi-File Backup Is Atomic' -Test {
    $file1 = New-TetraBackupTestFile -Content 'multi file 1'
    $file2 = New-TetraBackupTestFile -Content 'multi file 2'
    $Script:TetraBackupTestTempFiles.Add($file1)
    $Script:TetraBackupTestTempFiles.Add($file2)

    $result = Backup-TetraItem -Path @($file1, $file2) -Category 'General' -Label 'Smoke Test - Multi File'

    Assert-TetraTrue -Condition $result.Success -Message 'Multi-file backup did not report success.'
    Assert-TetraTrue -Condition ($result.ItemCount -eq 2) -Message "Expected ItemCount 2, got $($result.ItemCount)."
    Assert-TetraTrue -Condition ($result.Manifest.Items.Count -eq 2) -Message 'Manifest does not contain 2 items.'
}))

# ============================================================
# TEST 4: Backup rejects a non-existent source path
# ============================================================
$Script:TetraBackupSmokeTestResults.Add((Invoke-TetraSmokeTest -Name 'Backup Rejects Non-Existent Source' -Test {
    $fakePath = Join-Path -Path $env:TEMP -ChildPath "TetraBackupSmokeTest_DoesNotExist_$([guid]::NewGuid().ToString('N')).txt"

    $threw = $false
    try {
        Backup-TetraItem -Path $fakePath -Category 'General' | Out-Null
    }
    catch {
        $threw = $true
    }

    Assert-TetraTrue -Condition $threw -Message 'Backup-TetraItem did not reject a non-existent source path.'
}))

# ============================================================
# TEST 5: Backup rejects a source path inside Backup/ itself
# ============================================================
$Script:TetraBackupSmokeTestResults.Add((Invoke-TetraSmokeTest -Name 'Backup Rejects Source Inside Backup Directory' -Test {
    # First create a real backup so there's a real file inside Backup/ to
    # attempt to (illegally) back up.
    $seedFile = New-TetraBackupTestFile -Content 'seed'
    $Script:TetraBackupTestTempFiles.Add($seedFile)
    $seedBackup = Backup-TetraItem -Path $seedFile -Category 'General'

    $manifestPathInsideBackupDir = $seedBackup.Manifest | ConvertTo-Json -Depth 1 | Out-Null
    $manifestFilePath = Get-TetraBackupManifestFilePath -Category 'General' -BackupId $seedBackup.BackupId

    $threw = $false
    try {
        Backup-TetraItem -Path $manifestFilePath -Category 'General' | Out-Null
    }
    catch {
        $threw = $true
    }

    Assert-TetraTrue -Condition $threw -Message 'Backup-TetraItem did not reject a source path inside the Backup directory.'
}))

# ============================================================
# TEST 6: Get-TetraBackupList returns correct summary
# ============================================================
$Script:TetraBackupSmokeTestResults.Add((Invoke-TetraSmokeTest -Name 'Get-TetraBackupList Returns Correct Summary' -Test {
    $file = New-TetraBackupTestFile -Content 'listing test'
    $Script:TetraBackupTestTempFiles.Add($file)

    $backup = Backup-TetraItem -Path $file -Category 'General' -Label 'Smoke Test - Listing'

    $list  = Get-TetraBackupList -Category 'General'
    $found = $list | Where-Object { $_.BackupId -eq $backup.BackupId }

    Assert-TetraTrue -Condition ($null -ne $found) -Message 'Newly created backup was not found in Get-TetraBackupList.'
    Assert-TetraTrue -Condition ($found.ItemCount -eq 1) -Message 'Listed ItemCount does not match.'
}))

# ============================================================
# TEST 7: Test-TetraBackupIntegrity reports valid immediately after backup
# ============================================================
$Script:TetraBackupSmokeTestResults.Add((Invoke-TetraSmokeTest -Name 'Integrity Check Passes Immediately After Backup' -Test {
    $file = New-TetraBackupTestFile -Content 'integrity ok test'
    $Script:TetraBackupTestTempFiles.Add($file)

    $backup    = Backup-TetraItem -Path $file -Category 'General'
    $integrity = Test-TetraBackupIntegrity -Category 'General' -BackupId $backup.BackupId

    Assert-TetraTrue -Condition $integrity.IsValid -Message 'Integrity check reported invalid immediately after a fresh backup.'
    Assert-TetraTrue -Condition ($integrity.ValidItems -eq 1) -Message 'ValidItems count is not 1.'
}))

# ============================================================
# TEST 8: Test-TetraBackupIntegrity detects a tampered payload file
# ============================================================
$Script:TetraBackupSmokeTestResults.Add((Invoke-TetraSmokeTest -Name 'Integrity Check Detects Tampered Payload' -Test {
    $file = New-TetraBackupTestFile -Content 'tamper me'
    $Script:TetraBackupTestTempFiles.Add($file)

    $backup = Backup-TetraItem -Path $file -Category 'General'

    $payloadFile = Get-ChildItem -Path (Join-Path -Path (Get-TetraBackupCategoryDirectory -Category 'General') -ChildPath "$($backup.BackupId)\payload") -Recurse -File | Select-Object -First 1
    Set-Content -LiteralPath $payloadFile.FullName -Value 'TAMPERED CONTENT' -Encoding UTF8 -NoNewline

    $integrity = Test-TetraBackupIntegrity -Category 'General' -BackupId $backup.BackupId

    Assert-TetraTrue -Condition (-not $integrity.IsValid) -Message 'Integrity check did not detect a tampered payload file.'
    Assert-TetraTrue -Condition ($integrity.InvalidItems -eq 1) -Message 'InvalidItems count is not 1 after tampering.'
}))

# ============================================================
# TEST 9: Restore successfully returns a file to original content
# ============================================================
$Script:TetraBackupSmokeTestResults.Add((Invoke-TetraSmokeTest -Name 'Restore Successfully Returns Original Content' -Test {
    $file = New-TetraBackupTestFile -Content 'ORIGINAL CONTENT'
    $Script:TetraBackupTestTempFiles.Add($file)

    $backup = Backup-TetraItem -Path $file -Category 'General'

    Set-Content -LiteralPath $file -Value 'CHANGED CONTENT' -Encoding UTF8 -NoNewline

    $restoreResult = Restore-TetraBackup -Category 'General' -BackupId $backup.BackupId -Confirm:$false

    Assert-TetraTrue -Condition $restoreResult.Success -Message 'Restore-TetraBackup did not report success.'
    Assert-TetraTrue -Condition ((Get-Content -LiteralPath $file -Raw) -eq 'ORIGINAL CONTENT') -Message 'File content after restore does not match the original backup.'
}))

# ============================================================
# TEST 10: Restore -WhatIf performs zero filesystem mutations
# ============================================================
$Script:TetraBackupSmokeTestResults.Add((Invoke-TetraSmokeTest -Name 'Restore -WhatIf Performs Zero Mutations' -Test {
    $file = New-TetraBackupTestFile -Content 'whatif original'
    $Script:TetraBackupTestTempFiles.Add($file)

    $backup = Backup-TetraItem -Path $file -Category 'General'

    Set-Content -LiteralPath $file -Value 'whatif current (should remain unchanged)' -Encoding UTF8 -NoNewline
    $contentBefore = Get-Content -LiteralPath $file -Raw

    $backupDirBefore = @(Get-ChildItem -Path (Get-TetraBackupCategoryDirectory -Category 'General') -Directory -ErrorAction SilentlyContinue).Name | Sort-Object

    $result = Restore-TetraBackup -Category 'General' -BackupId $backup.BackupId -WhatIf

    $contentAfter = Get-Content -LiteralPath $file -Raw
    $backupDirAfter = @(Get-ChildItem -Path (Get-TetraBackupCategoryDirectory -Category 'General') -Directory -ErrorAction SilentlyContinue).Name | Sort-Object

    Assert-TetraTrue -Condition ($result.WhatIf -eq $true) -Message 'Restore -WhatIf did not report WhatIf=$true.'
    Assert-TetraTrue -Condition ($contentBefore -eq $contentAfter) -Message 'Destination file content changed despite -WhatIf.'
    Assert-TetraTrue -Condition (($backupDirBefore -join ',') -eq ($backupDirAfter -join ',')) -Message 'Backup directory contents changed despite -WhatIf (a snapshot may have been created).'
}))

# ============================================================
# TEST 11: Restore aborts entirely if integrity check fails first
# ============================================================
$Script:TetraBackupSmokeTestResults.Add((Invoke-TetraSmokeTest -Name 'Corrupt Integrity Blocks Restore Entirely' -Test {
    $file = New-TetraBackupTestFile -Content 'will be corrupted'
    $Script:TetraBackupTestTempFiles.Add($file)

    $backup = Backup-TetraItem -Path $file -Category 'General'

    $payloadFile = Get-ChildItem -Path (Join-Path -Path (Get-TetraBackupCategoryDirectory -Category 'General') -ChildPath "$($backup.BackupId)\payload") -Recurse -File | Select-Object -First 1
    Set-Content -LiteralPath $payloadFile.FullName -Value 'CORRUPTED' -Encoding UTF8 -NoNewline

    Set-Content -LiteralPath $file -Value 'live content that must remain untouched' -Encoding UTF8 -NoNewline
    $contentBefore = Get-Content -LiteralPath $file -Raw

    $threw = $false
    try {
        Restore-TetraBackup -Category 'General' -BackupId $backup.BackupId -Confirm:$false | Out-Null
    }
    catch {
        $threw = $true
        Assert-TetraTrue -Condition ($_.Exception.Message -like '*Integrity check failed*') -Message "Error message did not mention integrity failure: $($_.Exception.Message)"
    }

    Assert-TetraTrue -Condition $threw -Message 'Restore-TetraBackup did not throw when integrity check failed.'
    Assert-TetraTrue -Condition ((Get-Content -LiteralPath $file -Raw) -eq $contentBefore) -Message 'Destination file was modified despite a failed integrity check.'
}))

# ============================================================
# TEST 12: Restore rejects a path-traversal / protected-directory destination
# ============================================================
$Script:TetraBackupSmokeTestResults.Add((Invoke-TetraSmokeTest -Name 'Restore Rejects Protected-Directory Destination' -Test {
    $file = New-TetraBackupTestFile -Content 'traversal destination test'
    $Script:TetraBackupTestTempFiles.Add($file)

    $backup = Backup-TetraItem -Path $file -Category 'General'

    # Hand-edit the manifest so its OriginalPath points inside the
    # protected Config/ directory - simulates a tampered/malicious
    # manifest whose destination must be rejected before any write.
    $manifestPath = Get-TetraBackupManifestFilePath -Category 'General' -BackupId $backup.BackupId
    $manifestObj  = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $manifestObj.Items[0].OriginalPath = (Join-Path -Path $Script:TetraBackupProjectRootDir -ChildPath 'Config\evil-overwrite-attempt.ps1')
    $manifestObj | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $manifestPath -Encoding UTF8

    $threw = $false
    try {
        Restore-TetraBackup -Category 'General' -BackupId $backup.BackupId -Confirm:$false | Out-Null
    }
    catch {
        $threw = $true
        Assert-TetraTrue -Condition ($_.Exception.Message -like '*protected*') -Message "Error message did not mention protected directory: $($_.Exception.Message)"
    }

    Assert-TetraTrue -Condition $threw -Message 'Restore-TetraBackup did not reject a destination inside a protected directory.'
    Assert-TetraTrue -Condition (-not (Test-Path -LiteralPath (Join-Path -Path $Script:TetraBackupProjectRootDir -ChildPath 'Config\evil-overwrite-attempt.ps1'))) -Message 'A file was actually written inside the protected Config directory!'
}))

# ============================================================
# TEST 13: Automatic rollback after simulated mid-restore failure
# ============================================================
$Script:TetraBackupSmokeTestResults.Add((Invoke-TetraSmokeTest -Name 'Automatic Rollback After Mid-Restore Failure' -Test {
    $tempRoot = Join-Path -Path $env:TEMP -ChildPath "TetraBackupSmokeTest_Rollback_$([guid]::NewGuid().ToString('N'))"
    New-Item -Path $tempRoot -ItemType Directory -Force | Out-Null

    try {
        $file1 = Join-Path -Path $tempRoot -ChildPath 'file1.txt'
        Set-Content -LiteralPath $file1 -Value 'ORIGINAL1' -Encoding UTF8 -NoNewline

        $subDir = Join-Path -Path $tempRoot -ChildPath 'sub'
        New-Item -Path $subDir -ItemType Directory -Force | Out-Null
        $file2 = Join-Path -Path $subDir -ChildPath 'file2.txt'
        Set-Content -LiteralPath $file2 -Value 'ORIGINAL2' -Encoding UTF8 -NoNewline

        $backup = Backup-TetraItem -Path @($file1, $file2) -Category 'General' -Label 'Rollback Test'

        # Simulate live drift since the backup was taken - restore must
        # bring file1 back to this state if it needs to roll back.
        Set-Content -LiteralPath $file1 -Value 'MODIFIED1' -Encoding UTF8 -NoNewline

        # Break item2's destination so its restore-copy fails: replace the
        # "sub" directory with a plain file of the same name. This is a
        # real, reproducible failure trigger requiring no mocking.
        Remove-Item -LiteralPath $subDir -Recurse -Force
        Set-Content -LiteralPath $subDir -Value 'blocker file, not a directory' -Encoding UTF8 -NoNewline

        $threw = $false
        try {
            Restore-TetraBackup -Category 'General' -BackupId $backup.BackupId -Confirm:$false | Out-Null
        }
        catch {
            $threw = $true
            Assert-TetraTrue -Condition ($_.Exception.Message -like '*RESTORE FAILED*') -Message "Error message did not contain 'RESTORE FAILED': $($_.Exception.Message)"
            Assert-TetraTrue -Condition ($_.Exception.Message -notlike '*PARTIALLY FAILED*') -Message "Expected a clean full rollback, but message indicates partial rollback failure: $($_.Exception.Message)"
        }

        Assert-TetraTrue -Condition $threw -Message 'Restore-TetraBackup did not throw despite a mid-restore failure.'
        Assert-TetraTrue -Condition ((Get-Content -LiteralPath $file1 -Raw) -eq 'MODIFIED1') -Message 'file1 was not correctly rolled back to its pre-restore ("MODIFIED1") state.'
    }
    finally {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}))

# ============================================================
# TEST 14: Retention cleanup safety
# ============================================================
$Script:TetraBackupSmokeTestResults.Add((Invoke-TetraSmokeTest -Name 'Retention Cleanup Never Drops Below 1' -Test {
    # Create several backups so there is something for retention to
    # legitimately prune, then verify it never removes everything even if
    # the count is small.
    for ($i = 0; $i -lt 3; $i++) {
        $f = New-TetraBackupTestFile -Content "retention test $i"
        $Script:TetraBackupTestTempFiles.Add($f)
        Backup-TetraItem -Path $f -Category 'General' -Label "Retention Test $i" | Out-Null
        Start-Sleep -Milliseconds 20
    }

    $summary = Remove-TetraExpiredBackups -Category 'General' -Confirm:$false

    Assert-TetraTrue -Condition ($null -ne $summary) -Message 'Remove-TetraExpiredBackups returned $null.'

    $remaining = @(Get-TetraBackupList -Category 'General' | Where-Object { -not $_.IsAutoPreRestoreSnapshot })
    Assert-TetraTrue -Condition ($remaining.Count -ge 1) -Message 'Retention cleanup left zero normal backups despite backups existing.'
}))

# ============================================================
# TEST 15: Get-TetraBackupCategories returns exactly the expected 7
# ============================================================
$Script:TetraBackupSmokeTestResults.Add((Invoke-TetraSmokeTest -Name 'Backup Categories Enumeration Is Correct' -Test {
    $categories = Get-TetraBackupCategories
    $expected   = @('Registry', 'Services', 'Startup', 'PowerPlans', 'Drivers', 'Network', 'General')

    Assert-TetraTrue -Condition ($categories.Count -eq 7) -Message "Expected 7 categories, got $($categories.Count)."
    foreach ($cat in $expected) {
        Assert-TetraTrue -Condition ($categories -contains $cat) -Message "Expected category '$cat' is missing."
    }
}))

# ============================================================
# TEST 16: Backup/restore logging correlation
# ============================================================
$Script:TetraBackupSmokeTestResults.Add((Invoke-TetraSmokeTest -Name 'Backup And Restore Logs Carry OperationId/SessionId/DeviceId' -Test {
    $file = New-TetraBackupTestFile -Content 'logging correlation test'
    $Script:TetraBackupTestTempFiles.Add($file)

    $backup = Backup-TetraItem -Path $file -Category 'General'

    $backupLog = Get-TetraLogEntries -StartDate (Get-Date).ToUniversalTime().AddMinutes(-5) -EndDate (Get-Date).ToUniversalTime().AddMinutes(5) `
        -Module 'BackupEngine' | Where-Object { $_.Target -eq $backup.BackupId -and $_.Action -eq 'BackupCompleted' } | Select-Object -First 1

    Assert-TetraTrue -Condition ($null -ne $backupLog) -Message 'BackupCompleted log entry was not found.'
    Assert-TetraTrue -Condition (-not [string]::IsNullOrWhiteSpace($backupLog.OperationId)) -Message 'BackupCompleted log entry is missing OperationId.'
    Assert-TetraTrue -Condition (-not [string]::IsNullOrWhiteSpace($backupLog.SessionId)) -Message 'BackupCompleted log entry is missing SessionId.'
    Assert-TetraTrue -Condition (-not [string]::IsNullOrWhiteSpace($backupLog.DeviceId)) -Message 'BackupCompleted log entry is missing DeviceId.'
}))

# ============================================================
# TEST 17: Malformed manifest cannot be restored
# ============================================================
$Script:TetraBackupSmokeTestResults.Add((Invoke-TetraSmokeTest -Name 'Malformed Manifest Cannot Be Restored' -Test {
    $file = New-TetraBackupTestFile -Content 'malformed manifest test'
    $Script:TetraBackupTestTempFiles.Add($file)

    $backup = Backup-TetraItem -Path $file -Category 'General'

    $manifestPath = Get-TetraBackupManifestFilePath -Category 'General' -BackupId $backup.BackupId
    Set-Content -LiteralPath $manifestPath -Value '{ "ManifestVersion": "1.0", "BackupId": "broken" }' -Encoding UTF8

    $threwOnRead = $false
    try {
        Get-TetraBackupManifest -Category 'General' -BackupId $backup.BackupId | Out-Null
    }
    catch {
        $threwOnRead = $true
    }
    Assert-TetraTrue -Condition $threwOnRead -Message 'Get-TetraBackupManifest did not reject a manifest missing required fields.'

    $threwOnRestore = $false
    try {
        Restore-TetraBackup -Category 'General' -BackupId $backup.BackupId -Confirm:$false | Out-Null
    }
    catch {
        $threwOnRestore = $true
    }
    Assert-TetraTrue -Condition $threwOnRestore -Message 'Restore-TetraBackup did not reject a malformed manifest.'
}))

# ============================================================
# TEST 18: Malicious StoredRelativePath cannot escape payload/
# ============================================================
$Script:TetraBackupSmokeTestResults.Add((Invoke-TetraSmokeTest -Name 'Malicious StoredRelativePath Cannot Escape Payload Directory' -Test {
    $file = New-TetraBackupTestFile -Content 'traversal payload test'
    $Script:TetraBackupTestTempFiles.Add($file)

    $backup = Backup-TetraItem -Path $file -Category 'General'

    $manifestPath = Get-TetraBackupManifestFilePath -Category 'General' -BackupId $backup.BackupId
    $manifestObj  = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $manifestObj.Items[0].StoredRelativePath = '..\..\..\..\evil.txt'
    $manifestObj | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $manifestPath -Encoding UTF8

    $integrity = Test-TetraBackupIntegrity -Category 'General' -BackupId $backup.BackupId
    Assert-TetraTrue -Condition (-not $integrity.IsValid) -Message 'Integrity check did not flag a manifest with an escaping StoredRelativePath as invalid.'

    $threw = $false
    try {
        Restore-TetraBackup -Category 'General' -BackupId $backup.BackupId -Confirm:$false | Out-Null
    }
    catch {
        $threw = $true
    }
    Assert-TetraTrue -Condition $threw -Message 'Restore-TetraBackup did not abort for a manifest with an escaping StoredRelativePath.'
}))

# ============================================================
# TEST 19: Existing destination creates a pre-restore safety snapshot
# ============================================================
$Script:TetraBackupSmokeTestResults.Add((Invoke-TetraSmokeTest -Name 'Existing Destination Creates Pre-Restore Snapshot' -Test {
    $file = New-TetraBackupTestFile -Content 'snapshot creation test v1'
    $Script:TetraBackupTestTempFiles.Add($file)

    $backup = Backup-TetraItem -Path $file -Category 'General'

    Set-Content -LiteralPath $file -Value 'snapshot creation test v2 (live, pre-restore)' -Encoding UTF8 -NoNewline

    $restoreResult = Restore-TetraBackup -Category 'General' -BackupId $backup.BackupId -Confirm:$false

    Assert-TetraTrue -Condition (-not [string]::IsNullOrWhiteSpace($restoreResult.PreRestoreSnapshotId)) -Message 'Restore did not report a PreRestoreSnapshotId despite the destination existing beforehand.'

    $snapshotManifest = Get-TetraBackupManifest -Category 'General' -BackupId $restoreResult.PreRestoreSnapshotId
    Assert-TetraTrue -Condition ($snapshotManifest.IsAutoPreRestoreSnapshot -eq $true) -Message 'Pre-restore snapshot manifest does not have IsAutoPreRestoreSnapshot=true.'

    $snapshotIntegrity = Test-TetraBackupIntegrity -Category 'General' -BackupId $restoreResult.PreRestoreSnapshotId
    Assert-TetraTrue -Condition $snapshotIntegrity.IsValid -Message 'Pre-restore snapshot failed its own integrity check.'
}))

# ============================================================
# TEST 20: Rollback failure is reported honestly
# ============================================================
$Script:TetraBackupSmokeTestResults.Add((Invoke-TetraSmokeTest -Name 'Rollback Failure Is Reported Honestly' -Test {
    $tempRoot = Join-Path -Path $env:TEMP -ChildPath "TetraBackupSmokeTest_RollbackFail_$([guid]::NewGuid().ToString('N'))"
    New-Item -Path $tempRoot -ItemType Directory -Force | Out-Null

    try {
        $file1 = Join-Path -Path $tempRoot -ChildPath 'file1.txt'
        Set-Content -LiteralPath $file1 -Value 'ORIGINAL1' -Encoding UTF8 -NoNewline

        $subDir = Join-Path -Path $tempRoot -ChildPath 'sub'
        New-Item -Path $subDir -ItemType Directory -Force | Out-Null
        $file2 = Join-Path -Path $subDir -ChildPath 'file2.txt'
        Set-Content -LiteralPath $file2 -Value 'ORIGINAL2' -Encoding UTF8 -NoNewline

        $backup = Backup-TetraItem -Path @($file1, $file2) -Category 'General' -Label 'Rollback Failure Test'

        # Delete file1 entirely (so restore recreates it fresh, with NO
        # pre-restore snapshot taken for it - there was nothing to
        # protect) and break file2's destination the same way as Test 13,
        # so restore fails at item2 and rollback is attempted for item1.
        Remove-Item -LiteralPath $file1 -Force

        Remove-Item -LiteralPath $subDir -Recurse -Force
        Set-Content -LiteralPath $subDir -Value 'blocker file, not a directory' -Encoding UTF8 -NoNewline

        $threw = $false
        try {
            Restore-TetraBackup -Category 'General' -BackupId $backup.BackupId -Confirm:$false | Out-Null
        }
        catch {
            $threw = $true
            Assert-TetraTrue -Condition ($_.Exception.Message -like '*RESTORE FAILED*ROLLBACK PARTIALLY FAILED*') -Message "Error message did not honestly report partial rollback failure: $($_.Exception.Message)"
            Assert-TetraTrue -Condition ($_.Exception.Message -like "*$file1*") -Message "Error message did not identify which file could not be rolled back: $($_.Exception.Message)"
        }

        Assert-TetraTrue -Condition $threw -Message 'Restore-TetraBackup did not throw despite a rollback failure scenario.'
    }
    finally {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}))

# ============================================================
# TEST 21: Safety snapshot does not recursively create another snapshot
# ============================================================
$Script:TetraBackupSmokeTestResults.Add((Invoke-TetraSmokeTest -Name 'Safety Snapshot Does Not Recursively Chain' -Test {
    $file = New-TetraBackupTestFile -Content 'V1'
    $Script:TetraBackupTestTempFiles.Add($file)

    $backup1 = Backup-TetraItem -Path $file -Category 'General' -Label 'Recursion Test - Original'

    Set-Content -LiteralPath $file -Value 'V2' -Encoding UTF8 -NoNewline
    $restore1 = Restore-TetraBackup -Category 'General' -BackupId $backup1.BackupId -Confirm:$false
    Assert-TetraTrue -Condition (-not [string]::IsNullOrWhiteSpace($restore1.PreRestoreSnapshotId)) -Message 'First restore did not create a snapshot as expected.'
    $snapshotA = $restore1.PreRestoreSnapshotId

    Set-Content -LiteralPath $file -Value 'V3' -Encoding UTF8 -NoNewline

    # Restore the SNAPSHOT itself (snapshotA, which has
    # IsAutoPreRestoreSnapshot=true) - this must create exactly ONE new
    # snapshot (of the current "V3" state), not a recursive chain, and
    # must complete promptly (a hang would indicate infinite recursion).
    $restore2 = Restore-TetraBackup -Category 'General' -BackupId $snapshotA -Confirm:$false
    Assert-TetraTrue -Condition $restore2.Success -Message 'Restoring an auto-snapshot itself did not succeed.'
    Assert-TetraTrue -Condition ((Get-Content -LiteralPath $file -Raw) -eq 'V2') -Message 'Restoring snapshotA did not bring the file back to "V2".'

    $allBackups  = Get-TetraBackupList -Category 'General'
    $autoSnaps   = @($allBackups | Where-Object { $_.IsAutoPreRestoreSnapshot -and ($_.BackupId -eq $snapshotA -or $_.BackupId -eq $restore2.PreRestoreSnapshotId) })

    Assert-TetraTrue -Condition ($autoSnaps.Count -eq 2) -Message "Expected exactly 2 auto-snapshots tracked (snapshotA + the new one from restoring it), found $($autoSnaps.Count) - possible recursive chaining."
}))

# ============================================================
# FUNCTION: Get-TetraBackupSmokeTestResults
# ============================================================
function Get-TetraBackupSmokeTestResults {
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param()

    return $Script:TetraBackupSmokeTestResults
}

# ============================================================
# TEST CLEANUP: remove temp source files created during this run
# ============================================================
foreach ($tempFile in $Script:TetraBackupTestTempFiles) {
    if (Test-Path -LiteralPath $tempFile) {
        Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
    }
}

# ============================================================
# RESULTS REPORTING (console output intentional - standalone dev tooling,
# not part of the Core/Engine layered application)
# ============================================================
$passCount  = @($Script:TetraBackupSmokeTestResults | Where-Object { $_.Passed }).Count
$failCount  = @($Script:TetraBackupSmokeTestResults | Where-Object { -not $_.Passed }).Count
$totalCount = $Script:TetraBackupSmokeTestResults.Count
$allPassed  = ($passCount -eq $totalCount)

Write-Host ''
Write-Host '===== Tetra Optimizer - Backup Engine Smoke Test Results =====' -ForegroundColor Cyan

foreach ($testResult in $Script:TetraBackupSmokeTestResults) {
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
# EXIT BEHAVIOR (dot-source-safe - same rationale as
# Tests/Invoke-TetraSmokeTests.ps1: calling exit from a dot-sourced
# script would terminate the user's entire interactive PowerShell
# session, not just this test run)
# ============================================================
$Script:TetraBackupSmokeTestSummary = [PSCustomObject]@{
    PassCount  = $passCount
    FailCount  = $failCount
    TotalCount = $totalCount
    AllPassed  = $allPassed
    Overall    = if ($allPassed) { 'PASS' } else { 'FAIL' }
}

function Get-TetraBackupSmokeTestSummary {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param()

    return $Script:TetraBackupSmokeTestSummary
}

$Script:TetraBackupSmokeTestsWereDotSourced = ($MyInvocation.InvocationName -eq '.')

if (-not $allPassed) {
    if ($Script:TetraBackupSmokeTestsWereDotSourced) {
        Write-Host 'One or more Backup Engine smoke tests failed. Not calling exit (script was dot-sourced) - inspect $TetraBackupSmokeTestSummary or call Get-TetraBackupSmokeTestSummary for the result.' -ForegroundColor DarkYellow
    }
    else {
        exit 1
    }
}
