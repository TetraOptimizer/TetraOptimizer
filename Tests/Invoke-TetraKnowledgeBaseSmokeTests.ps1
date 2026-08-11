#Requires -Version 5.1
<#
.SYNOPSIS
    Tetra Optimizer - Knowledge Base Smoke Test Suite
.DESCRIPTION
    Lightweight, fast validation of Engine/KnowledgeBaseEngine.ps1 and the
    six Data/*.json knowledge base files. Separate file from the
    Foundation (11), Backup Engine (21), and Core (13) smoke test suites,
    which this file never touches, imports logic from, or re-runs.

    FILE-TAMPERING TEST SAFETY: Tests 20/21/25 temporarily modify real
    Data/*.json files on disk (to test malformed-JSON, missing-file, and
    broken-cross-category-dependency handling) and ALWAYS restore the
    original content in a finally block, mirroring the same
    tamper-then-restore discipline already used in the Backup Engine
    suite. No test in this file ever leaves a Data/*.json file altered
    after the suite completes.
.NOTES
    Module      : Invoke-TetraKnowledgeBaseSmokeTests.ps1
    Layer       : Tests (developer tooling, not part of the application)
    Build Phase : Phase 2 - Data / Knowledge Base
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Script:TetraKbTestsDir       = $PSScriptRoot
$Script:TetraKbProjectRootDir = Split-Path -Path $Script:TetraKbTestsDir -Parent
$Script:TetraKbBootstrapPath  = Join-Path -Path $Script:TetraKbProjectRootDir -ChildPath 'Bootstrap\Initialize-Tetra.ps1'

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

$Script:TetraKbSmokeTestResults = [System.Collections.Generic.List[PSCustomObject]]::new()

# ============================================================
# TEST 1: Bootstrap loads KnowledgeBaseEngine
# ============================================================
$bootstrapTest = [PSCustomObject]@{ TestName = 'Bootstrap Loads KnowledgeBaseEngine'; Passed = $false; DurationMs = 0.0; ErrorMessage = '' }
$bootstrapStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

try {
    . $Script:TetraKbBootstrapPath

    $bootstrapResult = Get-TetraBootstrapResult
    Assert-TetraTrue -Condition ($null -ne $bootstrapResult) -Message 'Get-TetraBootstrapResult returned $null.'
    Assert-TetraTrue -Condition $bootstrapResult.Success -Message "Bootstrap reported failure: $($bootstrapResult.FailedModules | ConvertTo-Json -Compress)"
    Assert-TetraTrue -Condition ($bootstrapResult.LoadedModules -contains 'KnowledgeBaseEngine') -Message "'KnowledgeBaseEngine' was not reported as loaded by Bootstrap."

    $bootstrapTest.Passed = $true
}
catch {
    $bootstrapTest.ErrorMessage = $_.Exception.Message
}
finally {
    $bootstrapStopwatch.Stop()
    $bootstrapTest.DurationMs = $bootstrapStopwatch.Elapsed.TotalMilliseconds
}

$Script:TetraKbSmokeTestResults.Add($bootstrapTest)

# ============================================================
# TEST 2: All six categories load successfully
# ============================================================
$Script:TetraKbSmokeTestResults.Add((Invoke-TetraSmokeTest -Name 'All Six Categories Load Successfully' -Test {
    foreach ($category in (Get-TetraKnowledgeBaseCategories)) {
        $items = Get-TetraKnowledgeBaseItems -Category $category
        Assert-TetraTrue -Condition (@($items).Count -gt 0) -Message "Category '$category' loaded zero items."
    }
}))

# ============================================================
# TEST 3: All six JSON files exist on disk
# ============================================================
$Script:TetraKbSmokeTestResults.Add((Invoke-TetraSmokeTest -Name 'All Six Knowledge Base Files Exist' -Test {
    foreach ($category in (Get-TetraKnowledgeBaseCategories)) {
        $filePath = Get-TetraKnowledgeBaseFilePath -Category $category
        Assert-TetraTrue -Condition (Test-Path -LiteralPath $filePath) -Message "File missing for category '$category': $filePath"
    }
}))

# ============================================================
# TEST 4: All six JSON files parse correctly
# ============================================================
$Script:TetraKbSmokeTestResults.Add((Invoke-TetraSmokeTest -Name 'All Six JSON Files Parse Correctly' -Test {
    foreach ($category in (Get-TetraKnowledgeBaseCategories)) {
        $filePath = Get-TetraKnowledgeBaseFilePath -Category $category
        $raw = Get-Content -LiteralPath $filePath -Raw -Encoding UTF8
        $parsed = $null
        $threw = $false
        try { $parsed = $raw | ConvertFrom-Json } catch { $threw = $true }
        Assert-TetraTrue -Condition (-not $threw) -Message "Category '$category' file failed to parse as JSON."
        Assert-TetraTrue -Condition ($null -ne $parsed) -Message "Category '$category' parsed to null."
    }
}))

# ============================================================
# TEST 5: Every real item has all required schema fields
# ============================================================
$Script:TetraKbSmokeTestResults.Add((Invoke-TetraSmokeTest -Name 'Required Schema Fields Present On All Real Items' -Test {
    foreach ($category in (Get-TetraKnowledgeBaseCategories)) {
        $validation = Test-TetraKnowledgeBaseSchema -Category $category
        Assert-TetraTrue -Condition $validation.IsValid -Message "Category '$category' failed schema validation: $($validation.Errors -join ' | ')"
    }
}))

# ============================================================
# TEST 6: Enum values are valid across all real items
# ============================================================
$Script:TetraKbSmokeTestResults.Add((Invoke-TetraSmokeTest -Name 'Enum Values Valid Across All Real Items' -Test {
    $validSeverity = @('Critical', 'High', 'Medium', 'Low')
    $validImpact   = @('None', 'Low', 'Medium', 'High')

    foreach ($category in (Get-TetraKnowledgeBaseCategories)) {
        foreach ($item in (Get-TetraKnowledgeBaseItems -Category $category)) {
            Assert-TetraTrue -Condition ($validSeverity -contains $item.Importance) -Message "Item '$($item.Id)' has invalid Importance '$($item.Importance)'."
            Assert-TetraTrue -Condition ($validSeverity -contains $item.RiskLevel) -Message "Item '$($item.Id)' has invalid RiskLevel '$($item.RiskLevel)'."
            Assert-TetraTrue -Condition ($validImpact -contains $item.PerformanceImpact) -Message "Item '$($item.Id)' has invalid PerformanceImpact '$($item.PerformanceImpact)'."
            Assert-TetraTrue -Condition ($validImpact -contains $item.SecurityImpact) -Message "Item '$($item.Id)' has invalid SecurityImpact '$($item.SecurityImpact)'."
        }
    }
}))

# ============================================================
# TEST 7: Boolean fields are true booleans across all real items
# ============================================================
$Script:TetraKbSmokeTestResults.Add((Invoke-TetraSmokeTest -Name 'Boolean Fields Are Valid Across All Real Items' -Test {
    foreach ($category in (Get-TetraKnowledgeBaseCategories)) {
        foreach ($item in (Get-TetraKnowledgeBaseItems -Category $category)) {
            Assert-TetraTrue -Condition ($item.Reversible -is [bool]) -Message "Item '$($item.Id)' Reversible is not a boolean."
            Assert-TetraTrue -Condition ($item.IsProtected -is [bool]) -Message "Item '$($item.Id)' IsProtected is not a boolean."
            Assert-TetraTrue -Condition ($item.RequiresAdditionalValidation -is [bool]) -Message "Item '$($item.Id)' RequiresAdditionalValidation is not a boolean."
        }
    }
}))

# ============================================================
# TEST 8: Array fields remain arrays after loading
# ============================================================
$Script:TetraKbSmokeTestResults.Add((Invoke-TetraSmokeTest -Name 'Array Fields Remain Arrays After Loading' -Test {
    foreach ($category in (Get-TetraKnowledgeBaseCategories)) {
        foreach ($item in (Get-TetraKnowledgeBaseItems -Category $category)) {
            $deps = @($item.Dependencies)
            $recs = @($item.RecommendedProfiles)
            $pres = @($item.PreserveForProfiles)
            Assert-TetraTrue -Condition ($deps -is [array]) -Message "Item '$($item.Id)' Dependencies did not wrap to an array."
            Assert-TetraTrue -Condition ($recs -is [array]) -Message "Item '$($item.Id)' RecommendedProfiles did not wrap to an array."
            Assert-TetraTrue -Condition ($pres -is [array]) -Message "Item '$($item.Id)' PreserveForProfiles did not wrap to an array."
        }
    }
}))

# ============================================================
# TEST 9: Single-element arrays are handled correctly (no scalar collapse)
# ============================================================
$Script:TetraKbSmokeTestResults.Add((Invoke-TetraSmokeTest -Name 'Single-Element Arrays Do Not Collapse To Scalars' -Test {
    # svc-bits has exactly one Dependencies entry ("svc-wuauserv") - a
    # direct, real regression test for the exact PS 5.1 collapse class of
    # bug already found and fixed in Config.ps1's Set-TetraConfigValue.
    $item = Get-TetraKnowledgeBaseItem -Category 'Services' -Id 'svc-bits'
    Assert-TetraTrue -Condition ($null -ne $item) -Message 'svc-bits not found.'

    $deps = @($item.Dependencies)
    Assert-TetraTrue -Condition ($deps.Count -eq 1) -Message "Expected exactly 1 dependency for svc-bits, got $($deps.Count) - possible scalar collapse."
    Assert-TetraTrue -Condition ($deps[0] -eq 'svc-wuauserv') -Message "svc-bits dependency mismatch: got '$($deps[0])'."
}))

# ============================================================
# TEST 10: Duplicate IDs are rejected
# ============================================================
$Script:TetraKbSmokeTestResults.Add((Invoke-TetraSmokeTest -Name 'Duplicate IDs Are Rejected' -Test {
    $category = 'Security'
    $filePath = Get-TetraKnowledgeBaseFilePath -Category $category
    $originalContent = Get-Content -LiteralPath $filePath -Raw -Encoding UTF8

    try {
        $items = @($originalContent | ConvertFrom-Json)
        $duplicated = @($items) + @($items[0])   # duplicate the first item's Id
        $duplicated | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $filePath -Encoding UTF8

        $validation = Test-TetraKnowledgeBaseSchema -Category $category
        Assert-TetraTrue -Condition (-not $validation.IsValid) -Message 'Schema validation did not reject a duplicate Id.'
        Assert-TetraTrue -Condition (($validation.Errors -join ' ') -like '*duplicate*') -Message "Error did not mention duplicate: $($validation.Errors -join ' | ')"
    }
    finally {
        Set-Content -LiteralPath $filePath -Value $originalContent -Encoding UTF8 -NoNewline
    }
}))

# ============================================================
# TEST 11: Invalid/missing Id is rejected
# ============================================================
$Script:TetraKbSmokeTestResults.Add((Invoke-TetraSmokeTest -Name 'Item With Empty Id Is Rejected' -Test {
    $badItem = [PSCustomObject]@{
        Id = ''; Category = 'Services'; Name = 'Bad'; SystemIdentifier = 'Bad'
        Importance = 'Low'; RiskLevel = 'Low'; Reversible = $true
        Dependencies = @(); RecommendedProfiles = @(); PreserveForProfiles = @()
        PerformanceImpact = 'None'; SecurityImpact = 'None'
        IsProtected = $false; RequiresAdditionalValidation = $false
    }

    $result = Test-TetraKnowledgeBaseItemSchema -Item $badItem -ExpectedCategory 'Services'
    Assert-TetraTrue -Condition (-not $result.IsValid) -Message 'Item with empty Id was not rejected.'
}))

# ============================================================
# TEST 12: Missing required fields are rejected
# ============================================================
$Script:TetraKbSmokeTestResults.Add((Invoke-TetraSmokeTest -Name 'Missing Required Fields Are Rejected' -Test {
    $incompleteItem = [PSCustomObject]@{
        Id = 'test-incomplete'; Category = 'Services'; Name = 'Incomplete Item'
        # SystemIdentifier, Importance, RiskLevel, and everything else intentionally omitted.
    }

    $result = Test-TetraKnowledgeBaseItemSchema -Item $incompleteItem -ExpectedCategory 'Services'
    Assert-TetraTrue -Condition (-not $result.IsValid) -Message 'Item missing required fields was not rejected.'
    Assert-TetraTrue -Condition ($result.Errors.Count -gt 0) -Message 'No errors were reported for the incomplete item.'
}))

# ============================================================
# TEST 13: Invalid category is rejected by parameter validation
# ============================================================
$Script:TetraKbSmokeTestResults.Add((Invoke-TetraSmokeTest -Name 'Invalid Category Is Rejected' -Test {
    $threw = $false
    try {
        Get-TetraKnowledgeBaseItems -Category 'NotARealCategory' | Out-Null
    }
    catch {
        $threw = $true
    }
    Assert-TetraTrue -Condition $threw -Message 'An invalid category was not rejected.'
}))

# ============================================================
# TEST 14: Invalid Importance value is rejected
# ============================================================
$Script:TetraKbSmokeTestResults.Add((Invoke-TetraSmokeTest -Name 'Invalid Importance Value Is Rejected' -Test {
    $badItem = [PSCustomObject]@{
        Id = 'test-bad-importance'; Category = 'Services'; Name = 'Bad'; SystemIdentifier = 'Bad'
        Importance = 'Ultra'; RiskLevel = 'Low'; Reversible = $true
        Dependencies = @(); RecommendedProfiles = @(); PreserveForProfiles = @()
        PerformanceImpact = 'None'; SecurityImpact = 'None'
        IsProtected = $false; RequiresAdditionalValidation = $false
    }

    $result = Test-TetraKnowledgeBaseItemSchema -Item $badItem -ExpectedCategory 'Services'
    Assert-TetraTrue -Condition (-not $result.IsValid) -Message 'Invalid Importance value was not rejected.'
}))

# ============================================================
# TEST 15: Invalid RiskLevel value is rejected
# ============================================================
$Script:TetraKbSmokeTestResults.Add((Invoke-TetraSmokeTest -Name 'Invalid RiskLevel Value Is Rejected' -Test {
    $badItem = [PSCustomObject]@{
        Id = 'test-bad-risk'; Category = 'Services'; Name = 'Bad'; SystemIdentifier = 'Bad'
        Importance = 'Low'; RiskLevel = 'Extreme'; Reversible = $true
        Dependencies = @(); RecommendedProfiles = @(); PreserveForProfiles = @()
        PerformanceImpact = 'None'; SecurityImpact = 'None'
        IsProtected = $false; RequiresAdditionalValidation = $false
    }

    $result = Test-TetraKnowledgeBaseItemSchema -Item $badItem -ExpectedCategory 'Services'
    Assert-TetraTrue -Condition (-not $result.IsValid) -Message 'Invalid RiskLevel value was not rejected.'
}))

# ============================================================
# TEST 16: Invalid PerformanceImpact value is rejected
# ============================================================
$Script:TetraKbSmokeTestResults.Add((Invoke-TetraSmokeTest -Name 'Invalid PerformanceImpact Value Is Rejected' -Test {
    $badItem = [PSCustomObject]@{
        Id = 'test-bad-perf'; Category = 'Services'; Name = 'Bad'; SystemIdentifier = 'Bad'
        Importance = 'Low'; RiskLevel = 'Low'; Reversible = $true
        Dependencies = @(); RecommendedProfiles = @(); PreserveForProfiles = @()
        PerformanceImpact = 'Extreme'; SecurityImpact = 'None'
        IsProtected = $false; RequiresAdditionalValidation = $false
    }

    $result = Test-TetraKnowledgeBaseItemSchema -Item $badItem -ExpectedCategory 'Services'
    Assert-TetraTrue -Condition (-not $result.IsValid) -Message 'Invalid PerformanceImpact value was not rejected.'
}))

# ============================================================
# TEST 17: Invalid SecurityImpact value is rejected
# ============================================================
$Script:TetraKbSmokeTestResults.Add((Invoke-TetraSmokeTest -Name 'Invalid SecurityImpact Value Is Rejected' -Test {
    $badItem = [PSCustomObject]@{
        Id = 'test-bad-secimpact'; Category = 'Services'; Name = 'Bad'; SystemIdentifier = 'Bad'
        Importance = 'Low'; RiskLevel = 'Low'; Reversible = $true
        Dependencies = @(); RecommendedProfiles = @(); PreserveForProfiles = @()
        PerformanceImpact = 'None'; SecurityImpact = 'Extreme'
        IsProtected = $false; RequiresAdditionalValidation = $false
    }

    $result = Test-TetraKnowledgeBaseItemSchema -Item $badItem -ExpectedCategory 'Services'
    Assert-TetraTrue -Condition (-not $result.IsValid) -Message 'Invalid SecurityImpact value was not rejected.'
}))

# ============================================================
# TEST 18: IsProtected -> RecommendedProfiles invariant is enforced
# ============================================================
$Script:TetraKbSmokeTestResults.Add((Invoke-TetraSmokeTest -Name 'Protected Item With RecommendedProfiles Is Rejected' -Test {
    $badItem = [PSCustomObject]@{
        Id = 'test-bad-protected'; Category = 'Services'; Name = 'Bad'; SystemIdentifier = 'Bad'
        Importance = 'Critical'; RiskLevel = 'Critical'; Reversible = $true
        Dependencies = @(); RecommendedProfiles = @('Gaming'); PreserveForProfiles = @()
        PerformanceImpact = 'None'; SecurityImpact = 'High'
        IsProtected = $true; RequiresAdditionalValidation = $false
    }

    $result = Test-TetraKnowledgeBaseItemSchema -Item $badItem -ExpectedCategory 'Services'
    Assert-TetraTrue -Condition (-not $result.IsValid) -Message 'IsProtected=true with non-empty RecommendedProfiles was not rejected.'

    # Also confirm the real, shipped data has zero violations of this invariant.
    foreach ($category in (Get-TetraKnowledgeBaseCategories)) {
        foreach ($item in (Get-TetraKnowledgeBaseItems -Category $category)) {
            if ($item.IsProtected -eq $true) {
                $recs = @($item.RecommendedProfiles)
                Assert-TetraTrue -Condition ($recs.Count -eq 0) -Message "Real item '$($item.Id)' is IsProtected=true but has non-empty RecommendedProfiles."
            }
        }
    }
}))

# ============================================================
# TEST 19: Profile metadata is valid across all real items
# ============================================================
$Script:TetraKbSmokeTestResults.Add((Invoke-TetraSmokeTest -Name 'Profile Metadata Valid Across All Real Items' -Test {
    $knownProfiles = Get-TetraKnownProfiles
    Assert-TetraTrue -Condition ($knownProfiles.Count -eq 4) -Message "Expected 4 known profiles, got $($knownProfiles.Count)."

    foreach ($category in (Get-TetraKnowledgeBaseCategories)) {
        foreach ($item in (Get-TetraKnowledgeBaseItems -Category $category)) {
            foreach ($p in @($item.RecommendedProfiles)) {
                Assert-TetraTrue -Condition ($knownProfiles -contains $p) -Message "Item '$($item.Id)' RecommendedProfiles has unknown profile '$p'."
            }
            foreach ($p in @($item.PreserveForProfiles)) {
                Assert-TetraTrue -Condition ($knownProfiles -contains $p) -Message "Item '$($item.Id)' PreserveForProfiles has unknown profile '$p'."
            }
        }
    }
}))

# ============================================================
# TEST 20: Malformed JSON is rejected (real file, tamper + restore)
# ============================================================
$Script:TetraKbSmokeTestResults.Add((Invoke-TetraSmokeTest -Name 'Malformed JSON Is Rejected' -Test {
    $category = 'Security'
    $filePath = Get-TetraKnowledgeBaseFilePath -Category $category
    $originalContent = Get-Content -LiteralPath $filePath -Raw -Encoding UTF8

    try {
        Set-Content -LiteralPath $filePath -Value '{ this is not valid json [[[' -Encoding UTF8

        $validation = Test-TetraKnowledgeBaseSchema -Category $category
        Assert-TetraTrue -Condition (-not $validation.IsValid) -Message 'Malformed JSON was not rejected.'
        Assert-TetraTrue -Condition (($validation.Errors -join ' ') -like '*JSON*') -Message "Error did not mention JSON: $($validation.Errors -join ' | ')"
    }
    finally {
        Set-Content -LiteralPath $filePath -Value $originalContent -Encoding UTF8 -NoNewline
    }
}))

# ============================================================
# TEST 21: Missing Knowledge Base file is handled safely (rename + restore)
# ============================================================
$Script:TetraKbSmokeTestResults.Add((Invoke-TetraSmokeTest -Name 'Missing Knowledge Base File Is Handled Safely' -Test {
    $category = 'Drivers'
    $filePath = Get-TetraKnowledgeBaseFilePath -Category $category
    $backupPath = "$filePath.smoketest_backup"

    try {
        Move-Item -LiteralPath $filePath -Destination $backupPath -Force

        $validation = Test-TetraKnowledgeBaseSchema -Category $category
        Assert-TetraTrue -Condition (-not $validation.IsValid) -Message 'Missing file was not reported as invalid.'
        Assert-TetraTrue -Condition (($validation.Errors -join ' ') -like '*not found*') -Message "Error did not mention 'not found': $($validation.Errors -join ' | ')"

        $threw = $false
        try {
            Get-TetraKnowledgeBaseItems -Category $category -Refresh | Out-Null
        }
        catch {
            $threw = $true
        }
        Assert-TetraTrue -Condition $threw -Message 'Get-TetraKnowledgeBaseItems did not throw for a missing file.'
    }
    finally {
        if (Test-Path -LiteralPath $backupPath) {
            Move-Item -LiteralPath $backupPath -Destination $filePath -Force
        }
        # Force a fresh read next time this category is requested, since
        # the cache must not serve data from before this tamper/restore.
        Get-TetraKnowledgeBaseItems -Category $category -Refresh | Out-Null
    }
}))

# ============================================================
# TEST 22: Invalid entry structure (empty object) is rejected
# ============================================================
$Script:TetraKbSmokeTestResults.Add((Invoke-TetraSmokeTest -Name 'Empty Object Entry Is Rejected' -Test {
    $emptyItem = [PSCustomObject]@{}

    $result = Test-TetraKnowledgeBaseItemSchema -Item $emptyItem -ExpectedCategory 'Services'
    Assert-TetraTrue -Condition (-not $result.IsValid) -Message 'An empty object item was not rejected.'
    Assert-TetraTrue -Condition ($result.Errors.Count -ge 10) -Message "Expected many missing-field errors for a fully empty item, got $($result.Errors.Count)."
}))

# ============================================================
# TEST 23: Category field mismatch is rejected
# ============================================================
$Script:TetraKbSmokeTestResults.Add((Invoke-TetraSmokeTest -Name 'Category Field Mismatch Is Rejected' -Test {
    $mismatchedItem = [PSCustomObject]@{
        Id = 'test-category-mismatch'; Category = 'Services'; Name = 'Bad'; SystemIdentifier = 'Bad'
        Importance = 'Low'; RiskLevel = 'Low'; Reversible = $true
        Dependencies = @(); RecommendedProfiles = @(); PreserveForProfiles = @()
        PerformanceImpact = 'None'; SecurityImpact = 'None'
        IsProtected = $false; RequiresAdditionalValidation = $false
    }

    # Item declares Category=Services but we validate it as Processes.
    $result = Test-TetraKnowledgeBaseItemSchema -Item $mismatchedItem -ExpectedCategory 'Processes'
    Assert-TetraTrue -Condition (-not $result.IsValid) -Message 'A Category field mismatch was not rejected.'
}))

# ============================================================
# TEST 24: Complete Knowledge Base loads and validates successfully
# ============================================================
$Script:TetraKbSmokeTestResults.Add((Invoke-TetraSmokeTest -Name 'Complete Knowledge Base Loads And Validates Successfully' -Test {
    $integrity = Test-TetraKnowledgeBaseIntegrity

    Assert-TetraTrue -Condition $integrity.IsValid -Message "Knowledge base integrity check failed. Category errors: $(($integrity.CategoryResults | Where-Object { -not $_.IsValid } | ForEach-Object { $_.Errors -join '; ' }) -join ' || '). Dependency errors: $($integrity.DependencyErrors -join ' | ')"
    Assert-TetraTrue -Condition ($integrity.TotalItemCount -eq 46) -Message "Expected 46 total items, got $($integrity.TotalItemCount)."
    Assert-TetraTrue -Condition ($integrity.CategoryResults.Count -eq 6) -Message "Expected 6 category results, got $($integrity.CategoryResults.Count)."
}))

# ============================================================
# TEST 25: Cross-category dependency validation (positive + negative)
# ============================================================
$Script:TetraKbSmokeTestResults.Add((Invoke-TetraSmokeTest -Name 'Cross-Category Dependency Validation (Positive And Negative)' -Test {
    # Positive: proc-msmpeng (Processes) legitimately depends on
    # svc-windefend (Services) - a real cross-category reference that
    # must resolve without error.
    $positiveCheck = Test-TetraKnowledgeBaseIntegrity
    Assert-TetraTrue -Condition $positiveCheck.IsValid -Message 'Real cross-category dependencies did not validate cleanly.'
    Assert-TetraTrue -Condition ($positiveCheck.DependencyErrors.Count -eq 0) -Message "Expected zero dependency errors on real data, got: $($positiveCheck.DependencyErrors -join ' | ')"

    # Negative: temporarily corrupt Processes.json so proc-msmpeng
    # references a dependency Id that does not exist anywhere in the
    # knowledge base, and confirm Test-TetraKnowledgeBaseIntegrity - not
    # Test-TetraKnowledgeBaseSchema, which cannot see other files -
    # catches it.
    $category = 'Processes'
    $filePath = Get-TetraKnowledgeBaseFilePath -Category $category
    $originalContent = Get-Content -LiteralPath $filePath -Raw -Encoding UTF8

    try {
        $items = @($originalContent | ConvertFrom-Json)
        $target = $items | Where-Object { $_.Id -eq 'proc-msmpeng' } | Select-Object -First 1
        Assert-TetraTrue -Condition ($null -ne $target) -Message 'proc-msmpeng not found in Processes.json for the negative test setup.'

        $target.Dependencies = @('this-id-does-not-exist-anywhere')
        $items | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $filePath -Encoding UTF8

        $negativeCheck = Test-TetraKnowledgeBaseIntegrity
        Assert-TetraTrue -Condition (-not $negativeCheck.IsValid) -Message 'A broken cross-category dependency was not detected.'
        Assert-TetraTrue -Condition ($negativeCheck.DependencyErrors.Count -ge 1) -Message 'No dependency error was recorded for the broken reference.'
        Assert-TetraTrue -Condition (($negativeCheck.DependencyErrors -join ' ') -like '*this-id-does-not-exist-anywhere*') -Message "Dependency error did not name the broken Id: $($negativeCheck.DependencyErrors -join ' | ')"
    }
    finally {
        Set-Content -LiteralPath $filePath -Value $originalContent -Encoding UTF8 -NoNewline
        Get-TetraKnowledgeBaseItems -Category $category -Refresh | Out-Null
    }
}))

# ============================================================
# FUNCTION: Get-TetraKbSmokeTestResults
# ============================================================
function Get-TetraKbSmokeTestResults {
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param()

    return $Script:TetraKbSmokeTestResults
}

# ============================================================
# RESULTS REPORTING (console output intentional - standalone dev tooling)
# ============================================================
$passCount  = @($Script:TetraKbSmokeTestResults | Where-Object { $_.Passed }).Count
$failCount  = @($Script:TetraKbSmokeTestResults | Where-Object { -not $_.Passed }).Count
$totalCount = $Script:TetraKbSmokeTestResults.Count
$allPassed  = ($passCount -eq $totalCount)

Write-Host ''
Write-Host '===== Tetra Optimizer - Knowledge Base Smoke Test Results =====' -ForegroundColor Cyan

foreach ($testResult in $Script:TetraKbSmokeTestResults) {
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
# EXIT BEHAVIOR (dot-source-safe - same rationale as the other three suites)
# ============================================================
$Script:TetraKbSmokeTestSummary = [PSCustomObject]@{
    PassCount  = $passCount
    FailCount  = $failCount
    TotalCount = $totalCount
    AllPassed  = $allPassed
    Overall    = if ($allPassed) { 'PASS' } else { 'FAIL' }
}

function Get-TetraKbSmokeTestSummary {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param()

    return $Script:TetraKbSmokeTestSummary
}

$Script:TetraKbSmokeTestsWereDotSourced = ($MyInvocation.InvocationName -eq '.')

if (-not $allPassed) {
    if ($Script:TetraKbSmokeTestsWereDotSourced) {
        Write-Host 'One or more Knowledge Base smoke tests failed. Not calling exit (script was dot-sourced) - inspect $TetraKbSmokeTestSummary or call Get-TetraKbSmokeTestSummary for the result.' -ForegroundColor DarkYellow
    }
    else {
        exit 1
    }
}
