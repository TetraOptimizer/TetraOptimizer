#Requires -Version 5.1
<#
.SYNOPSIS
    Tetra Optimizer - Analyzer + Policy Engine Smoke Test Suite
.DESCRIPTION
    Lightweight, fast validation of Engine/AnalyzerEngine.ps1. Separate
    file from the Foundation (11), Backup Engine (21), Core (13), and
    Knowledge Base (25) smoke test suites, which this file never touches,
    imports logic from, or re-runs.

    Several tests construct hand-built, synthetic Knowledge Base item
    objects (via [PSCustomObject]) rather than reading real Data/*.json
    files. This is deliberate: Invoke-TetraPolicyEvaluation accepts any
    correctly-shaped item, so isolating a single rule-chain branch (e.g.
    "does RiskLevel alone trigger a downgrade, independent of
    RequiresAdditionalValidation") is only possible by constructing an
    item where every OTHER factor is held constant. No real Data/*.json
    file is ever modified by this suite.
.NOTES
    Module      : Invoke-TetraAnalyzerSmokeTests.ps1
    Layer       : Tests (developer tooling, not part of the application)
    Build Phase : Phase 3 - Analyzer + Policy/Rules Engine
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Script:TetraAnalyzerTestsDir       = $PSScriptRoot
$Script:TetraAnalyzerProjectRootDir = Split-Path -Path $Script:TetraAnalyzerTestsDir -Parent
$Script:TetraAnalyzerBootstrapPath  = Join-Path -Path $Script:TetraAnalyzerProjectRootDir -ChildPath 'Bootstrap\Initialize-Tetra.ps1'

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
# TEST HELPER: New-TetraAnalyzerTestKbItem
# ============================================================
<#
.SYNOPSIS
    Builds a synthetic, correctly-shaped Knowledge Base item for isolated
    rule-chain testing. Test-only helper - not part of any Engine API.
#>
function New-TetraAnalyzerTestKbItem {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [string]$Id = 'test-item',
        [string]$Category = 'Services',
        [string]$Importance = 'Low',
        [string]$RiskLevel = 'Low',
        [bool]$Reversible = $true,
        [string[]]$Dependencies = @(),
        [string[]]$RecommendedProfiles = @(),
        [string[]]$PreserveForProfiles = @(),
        [string]$PerformanceImpact = 'Low',
        [string]$SecurityImpact = 'None',
        [bool]$IsProtected = $false,
        [bool]$RequiresAdditionalValidation = $false,
        [string]$Notes = ''
    )

    return [PSCustomObject]@{
        Id = $Id; Category = $Category; Name = $Id; SystemIdentifier = $Id
        Importance = $Importance; RiskLevel = $RiskLevel; Reversible = $Reversible
        Dependencies = $Dependencies; RecommendedProfiles = $RecommendedProfiles; PreserveForProfiles = $PreserveForProfiles
        PerformanceImpact = $PerformanceImpact; SecurityImpact = $SecurityImpact
        IsProtected = $IsProtected; RequiresAdditionalValidation = $RequiresAdditionalValidation
        Notes = $Notes
    }
}

$Script:TetraAnalyzerSmokeTestResults = [System.Collections.Generic.List[PSCustomObject]]::new()

# ============================================================
# TEST 1: Bootstrap loads AnalyzerEngine
# ============================================================
$bootstrapTest = [PSCustomObject]@{ TestName = 'Bootstrap Loads AnalyzerEngine'; Passed = $false; DurationMs = 0.0; ErrorMessage = '' }
$bootstrapStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

try {
    . $Script:TetraAnalyzerBootstrapPath

    $bootstrapResult = Get-TetraBootstrapResult
    Assert-TetraTrue -Condition ($null -ne $bootstrapResult) -Message 'Get-TetraBootstrapResult returned $null.'
    Assert-TetraTrue -Condition $bootstrapResult.Success -Message "Bootstrap reported failure: $($bootstrapResult.FailedModules | ConvertTo-Json -Compress)"
    Assert-TetraTrue -Condition ($bootstrapResult.LoadedModules -contains 'AnalyzerEngine') -Message "'AnalyzerEngine' was not reported as loaded by Bootstrap."

    $bootstrapTest.Passed = $true
}
catch {
    $bootstrapTest.ErrorMessage = $_.Exception.Message
}
finally {
    $bootstrapStopwatch.Stop()
    $bootstrapTest.DurationMs = $bootstrapStopwatch.Elapsed.TotalMilliseconds
}

$Script:TetraAnalyzerSmokeTestResults.Add($bootstrapTest)

# ============================================================
# TEST 2: Get-TetraDecisionStates returns exactly the 5 expected states
# ============================================================
$Script:TetraAnalyzerSmokeTestResults.Add((Invoke-TetraSmokeTest -Name 'Decision States Are Exactly The Expected 5' -Test {
    $states = Get-TetraDecisionStates
    $expected = @('Recommended', 'Optional', 'Keep', 'DoNotChange', 'CriticalProtected')
    Assert-TetraTrue -Condition ($states.Count -eq 5) -Message "Expected 5 decision states, got $($states.Count)."
    foreach ($s in $expected) {
        Assert-TetraTrue -Condition ($states -contains $s) -Message "Expected decision state '$s' is missing."
    }
}))

# ============================================================
# TEST 3: New-TetraSystemStateObservation builds a correctly-shaped object
# ============================================================
$Script:TetraAnalyzerSmokeTestResults.Add((Invoke-TetraSmokeTest -Name 'System State Observation Is Correctly Shaped' -Test {
    $obs = New-TetraSystemStateObservation -Category 'Services' -KnowledgeBaseId 'svc-wsearch' -IsInstalled $true -IsActive $true -CurrentState 'Running'
    Assert-TetraTrue -Condition ($obs.Category -eq 'Services') -Message 'Category mismatch.'
    Assert-TetraTrue -Condition ($obs.KnowledgeBaseId -eq 'svc-wsearch') -Message 'KnowledgeBaseId mismatch.'
    Assert-TetraTrue -Condition ($obs.IsInstalled -eq $true) -Message 'IsInstalled mismatch.'
    Assert-TetraTrue -Condition ($obs.IsActive -eq $true) -Message 'IsActive mismatch.'
    Assert-TetraTrue -Condition (-not [string]::IsNullOrWhiteSpace($obs.ObservedUtc)) -Message 'ObservedUtc was not populated.'
}))

# ============================================================
# TEST 4: Protected item -> CriticalProtected under Gaming
# ============================================================
$Script:TetraAnalyzerSmokeTestResults.Add((Invoke-TetraSmokeTest -Name 'Protected Item Is CriticalProtected Under Gaming' -Test {
    $kbItem = Get-TetraKnowledgeBaseItem -Category 'Services' -Id 'svc-windefend'
    $state  = New-TetraSystemStateObservation -Category 'Services' -KnowledgeBaseId 'svc-windefend' -IsInstalled $true -IsActive $true

    $decision = Invoke-TetraPolicyEvaluation -KnowledgeBaseItem $kbItem -SystemState $state -Profile 'Gaming'

    Assert-TetraTrue -Condition ($decision.Decision -eq 'CriticalProtected') -Message "Expected CriticalProtected, got '$($decision.Decision)'."
    Assert-TetraTrue -Condition (-not [string]::IsNullOrWhiteSpace($decision.Reason)) -Message 'Reason was empty.'
}))

# ============================================================
# TEST 5: Protected item -> CriticalProtected under Office (profile-independent floor)
# ============================================================
$Script:TetraAnalyzerSmokeTestResults.Add((Invoke-TetraSmokeTest -Name 'Protected Item Is CriticalProtected Under Office' -Test {
    $kbItem = Get-TetraKnowledgeBaseItem -Category 'Services' -Id 'svc-windefend'
    $state  = New-TetraSystemStateObservation -Category 'Services' -KnowledgeBaseId 'svc-windefend' -IsInstalled $true -IsActive $true

    $decision = Invoke-TetraPolicyEvaluation -KnowledgeBaseItem $kbItem -SystemState $state -Profile 'Office'

    Assert-TetraTrue -Condition ($decision.Decision -eq 'CriticalProtected') -Message "Expected CriticalProtected under Office too, got '$($decision.Decision)'."
}))

# ============================================================
# TEST 6: Protected floor holds even with a synthetic non-empty RecommendedProfiles
# ============================================================
$Script:TetraAnalyzerSmokeTestResults.Add((Invoke-TetraSmokeTest -Name 'Protected Floor Enforced Independent Of Data Invariant' -Test {
    # Real KB data can never produce IsProtected=true with a non-empty
    # RecommendedProfiles (enforced by KnowledgeBaseEngine's own schema
    # validation) - this test proves the POLICY layer independently
    # enforces the same floor, in depth, rather than merely trusting
    # upstream data validation.
    $kbItem = New-TetraAnalyzerTestKbItem -Id 'test-protected-override' -IsProtected $true -RecommendedProfiles @('Gaming')
    $state  = New-TetraSystemStateObservation -Category 'Services' -KnowledgeBaseId 'test-protected-override' -IsInstalled $true -IsActive $true

    $decision = Invoke-TetraPolicyEvaluation -KnowledgeBaseItem $kbItem -SystemState $state -Profile 'Gaming'

    Assert-TetraTrue -Condition ($decision.Decision -eq 'CriticalProtected') -Message "Policy layer did not independently enforce the protected floor: got '$($decision.Decision)'."
}))

# ============================================================
# TEST 7: Not-installed component -> DoNotChange
# ============================================================
$Script:TetraAnalyzerSmokeTestResults.Add((Invoke-TetraSmokeTest -Name 'Not-Installed Component Is DoNotChange' -Test {
    $kbItem = Get-TetraKnowledgeBaseItem -Category 'Services' -Id 'svc-fax'
    $state  = New-TetraSystemStateObservation -Category 'Services' -KnowledgeBaseId 'svc-fax' -IsInstalled $false -IsActive $false

    $decision = Invoke-TetraPolicyEvaluation -KnowledgeBaseItem $kbItem -SystemState $state -Profile 'Gaming'

    Assert-TetraTrue -Condition ($decision.Decision -eq 'DoNotChange') -Message "Expected DoNotChange, got '$($decision.Decision)'."
}))

# ============================================================
# TEST 8: Not-active component -> Keep
# ============================================================
$Script:TetraAnalyzerSmokeTestResults.Add((Invoke-TetraSmokeTest -Name 'Not-Active Component Is Keep' -Test {
    $kbItem = Get-TetraKnowledgeBaseItem -Category 'Services' -Id 'svc-fax'
    $state  = New-TetraSystemStateObservation -Category 'Services' -KnowledgeBaseId 'svc-fax' -IsInstalled $true -IsActive $false

    $decision = Invoke-TetraPolicyEvaluation -KnowledgeBaseItem $kbItem -SystemState $state -Profile 'Gaming'

    Assert-TetraTrue -Condition ($decision.Decision -eq 'Keep') -Message "Expected Keep, got '$($decision.Decision)'."
}))

# ============================================================
# TEST 9: PreserveForProfiles wins over evaluation
# ============================================================
$Script:TetraAnalyzerSmokeTestResults.Add((Invoke-TetraSmokeTest -Name 'PreserveForProfiles Wins Over Recommendation' -Test {
    # svc-wsearch: RecommendedProfiles=[Gaming], PreserveForProfiles=[Office,Balanced]
    $kbItem = Get-TetraKnowledgeBaseItem -Category 'Services' -Id 'svc-wsearch'
    $state  = New-TetraSystemStateObservation -Category 'Services' -KnowledgeBaseId 'svc-wsearch' -IsInstalled $true -IsActive $true

    $decision = Invoke-TetraPolicyEvaluation -KnowledgeBaseItem $kbItem -SystemState $state -Profile 'Office'

    Assert-TetraTrue -Condition ($decision.Decision -eq 'Keep') -Message "Expected Keep (preserved) under Office, got '$($decision.Decision)'."
    Assert-TetraTrue -Condition ($decision.Reason -like '*preserved*') -Message "Reason did not mention preservation: $($decision.Reason)"
}))

# ============================================================
# TEST 10: Low-risk RecommendedProfiles item -> Recommended
# ============================================================
$Script:TetraAnalyzerSmokeTestResults.Add((Invoke-TetraSmokeTest -Name 'Low-Risk Recommended-Profile Item Is Recommended' -Test {
    # svc-fax: Low risk, Reversible=true, RequiresAdditionalValidation=false, RecommendedProfiles includes Gaming
    $kbItem = Get-TetraKnowledgeBaseItem -Category 'Services' -Id 'svc-fax'
    $state  = New-TetraSystemStateObservation -Category 'Services' -KnowledgeBaseId 'svc-fax' -IsInstalled $true -IsActive $true

    $decision = Invoke-TetraPolicyEvaluation -KnowledgeBaseItem $kbItem -SystemState $state -Profile 'Gaming'

    Assert-TetraTrue -Condition ($decision.Decision -eq 'Recommended') -Message "Expected Recommended, got '$($decision.Decision)'."
}))

# ============================================================
# TEST 11: RequiresAdditionalValidation forces Optional despite matching profile
# ============================================================
$Script:TetraAnalyzerSmokeTestResults.Add((Invoke-TetraSmokeTest -Name 'RequiresAdditionalValidation Forces Optional' -Test {
    # reg-power-throttling: RecommendedProfiles=[Gaming], RequiresAdditionalValidation=true
    $kbItem = Get-TetraKnowledgeBaseItem -Category 'Registry' -Id 'reg-power-throttling'
    $state  = New-TetraSystemStateObservation -Category 'Registry' -KnowledgeBaseId 'reg-power-throttling' -IsInstalled $true -IsActive $true

    $decision = Invoke-TetraPolicyEvaluation -KnowledgeBaseItem $kbItem -SystemState $state -Profile 'Gaming'

    Assert-TetraTrue -Condition ($decision.Decision -eq 'Optional') -Message "Expected Optional, got '$($decision.Decision)'."
    Assert-TetraTrue -Condition ($decision.Reason -like '*additional*validation*') -Message "Reason did not cite validation requirement: $($decision.Reason)"
}))

# ============================================================
# TEST 12: RiskLevel alone (isolated) forces Optional
# ============================================================
$Script:TetraAnalyzerSmokeTestResults.Add((Invoke-TetraSmokeTest -Name 'High RiskLevel Alone Forces Optional' -Test {
    $kbItem = New-TetraAnalyzerTestKbItem -Id 'test-high-risk' -RiskLevel 'High' -Reversible $true -RequiresAdditionalValidation $false -RecommendedProfiles @('Gaming')
    $state  = New-TetraSystemStateObservation -Category 'Services' -KnowledgeBaseId 'test-high-risk' -IsInstalled $true -IsActive $true

    $decision = Invoke-TetraPolicyEvaluation -KnowledgeBaseItem $kbItem -SystemState $state -Profile 'Gaming'

    Assert-TetraTrue -Condition ($decision.Decision -eq 'Optional') -Message "Expected Optional due to risk alone, got '$($decision.Decision)'."
    Assert-TetraTrue -Condition ($decision.Reason -like "*risk level is 'High'*") -Message "Reason did not isolate risk as the cause: $($decision.Reason)"
}))

# ============================================================
# TEST 13: Non-reversibility alone (isolated) forces Optional
# ============================================================
$Script:TetraAnalyzerSmokeTestResults.Add((Invoke-TetraSmokeTest -Name 'Non-Reversibility Alone Forces Optional' -Test {
    $kbItem = New-TetraAnalyzerTestKbItem -Id 'test-irreversible' -RiskLevel 'Low' -Reversible $false -RequiresAdditionalValidation $false -RecommendedProfiles @('Office')
    $state  = New-TetraSystemStateObservation -Category 'Services' -KnowledgeBaseId 'test-irreversible' -IsInstalled $true -IsActive $true

    $decision = Invoke-TetraPolicyEvaluation -KnowledgeBaseItem $kbItem -SystemState $state -Profile 'Office'

    Assert-TetraTrue -Condition ($decision.Decision -eq 'Optional') -Message "Expected Optional due to irreversibility alone, got '$($decision.Decision)'."
    Assert-TetraTrue -Condition ($decision.Reason -like '*not reversible*') -Message "Reason did not isolate reversibility as the cause: $($decision.Reason)"
}))

# ============================================================
# TEST 14: Same KB item produces different decisions under different profiles
# ============================================================
$Script:TetraAnalyzerSmokeTestResults.Add((Invoke-TetraSmokeTest -Name 'Same Item Differs Across Profiles' -Test {
    $kbItem = Get-TetraKnowledgeBaseItem -Category 'Services' -Id 'svc-wsearch'
    $state  = New-TetraSystemStateObservation -Category 'Services' -KnowledgeBaseId 'svc-wsearch' -IsInstalled $true -IsActive $true

    $gamingDecision = Invoke-TetraPolicyEvaluation -KnowledgeBaseItem $kbItem -SystemState $state -Profile 'Gaming'
    $officeDecision = Invoke-TetraPolicyEvaluation -KnowledgeBaseItem $kbItem -SystemState $state -Profile 'Office'

    Assert-TetraTrue -Condition ($gamingDecision.Decision -ne $officeDecision.Decision) -Message "Expected different decisions across profiles for the same item, got '$($gamingDecision.Decision)' for both."
}))

# ============================================================
# TEST 15: Gaming-relevant item does not leak Recommended status into Office
# ============================================================
$Script:TetraAnalyzerSmokeTestResults.Add((Invoke-TetraSmokeTest -Name 'Gaming Recommendation Does Not Leak Into Office' -Test {
    # startup-steam: RecommendedProfiles=[Office], PreserveForProfiles=[Gaming]
    $kbItem = Get-TetraKnowledgeBaseItem -Category 'Startup' -Id 'startup-steam'
    $state  = New-TetraSystemStateObservation -Category 'Startup' -KnowledgeBaseId 'startup-steam' -IsInstalled $true -IsActive $true

    $gamingDecision = Invoke-TetraPolicyEvaluation -KnowledgeBaseItem $kbItem -SystemState $state -Profile 'Gaming'
    $officeDecision = Invoke-TetraPolicyEvaluation -KnowledgeBaseItem $kbItem -SystemState $state -Profile 'Office'

    Assert-TetraTrue -Condition ($gamingDecision.Decision -eq 'Keep') -Message "Steam should be preserved (Keep) under Gaming, got '$($gamingDecision.Decision)'."
    Assert-TetraTrue -Condition ($officeDecision.Decision -eq 'Recommended') -Message "Steam should be Recommended under Office, got '$($officeDecision.Decision)'."
}))

# ============================================================
# TEST 16: Office-relevant item does not leak Recommended status into Gaming
# ============================================================
$Script:TetraAnalyzerSmokeTestResults.Add((Invoke-TetraSmokeTest -Name 'Office Recommendation Does Not Leak Into Gaming' -Test {
    # startup-teams: RecommendedProfiles=[Gaming], PreserveForProfiles=[Office]
    $kbItem = Get-TetraKnowledgeBaseItem -Category 'Startup' -Id 'startup-teams'
    $state  = New-TetraSystemStateObservation -Category 'Startup' -KnowledgeBaseId 'startup-teams' -IsInstalled $true -IsActive $true

    $gamingDecision = Invoke-TetraPolicyEvaluation -KnowledgeBaseItem $kbItem -SystemState $state -Profile 'Gaming'
    $officeDecision = Invoke-TetraPolicyEvaluation -KnowledgeBaseItem $kbItem -SystemState $state -Profile 'Office'

    Assert-TetraTrue -Condition ($gamingDecision.Decision -eq 'Recommended') -Message "Teams should be Recommended under Gaming, got '$($gamingDecision.Decision)'."
    Assert-TetraTrue -Condition ($officeDecision.Decision -eq 'Keep') -Message "Teams should be preserved (Keep) under Office, got '$($officeDecision.Decision)'."
}))

# ============================================================
# TEST 17: Balanced behaves conservatively relative to Gaming
# ============================================================
$Script:TetraAnalyzerSmokeTestResults.Add((Invoke-TetraSmokeTest -Name 'Balanced Behaves Conservatively' -Test {
    # reg-power-throttling: RecommendedProfiles=[Gaming] only, NOT Balanced.
    $kbItem = Get-TetraKnowledgeBaseItem -Category 'Registry' -Id 'reg-power-throttling'
    $state  = New-TetraSystemStateObservation -Category 'Registry' -KnowledgeBaseId 'reg-power-throttling' -IsInstalled $true -IsActive $true

    $balancedDecision = Invoke-TetraPolicyEvaluation -KnowledgeBaseItem $kbItem -SystemState $state -Profile 'Balanced'
    Assert-TetraTrue -Condition ($balancedDecision.Decision -eq 'Keep') -Message "Expected Balanced to default to Keep for a Gaming-only item, got '$($balancedDecision.Decision)'."

    # But Balanced is not blanket-conservative for everything - svc-fax
    # includes Balanced in its RecommendedProfiles and is low-risk.
    $faxItem  = Get-TetraKnowledgeBaseItem -Category 'Services' -Id 'svc-fax'
    $faxState = New-TetraSystemStateObservation -Category 'Services' -KnowledgeBaseId 'svc-fax' -IsInstalled $true -IsActive $true
    $faxDecision = Invoke-TetraPolicyEvaluation -KnowledgeBaseItem $faxItem -SystemState $faxState -Profile 'Balanced'
    Assert-TetraTrue -Condition ($faxDecision.Decision -eq 'Recommended') -Message "Expected svc-fax to still be Recommended under Balanced, got '$($faxDecision.Decision)'."
}))

# ============================================================
# TEST 18: Custom profile is accepted and safely defaults
# ============================================================
$Script:TetraAnalyzerSmokeTestResults.Add((Invoke-TetraSmokeTest -Name 'Custom Profile Accepted And Defaults Safely' -Test {
    # No real KB entry currently references Custom in either profile list,
    # so evaluation should safely default to Keep without error.
    $kbItem = Get-TetraKnowledgeBaseItem -Category 'Services' -Id 'svc-fax'
    $state  = New-TetraSystemStateObservation -Category 'Services' -KnowledgeBaseId 'svc-fax' -IsInstalled $true -IsActive $true

    $decision = Invoke-TetraPolicyEvaluation -KnowledgeBaseItem $kbItem -SystemState $state -Profile 'Custom'

    Assert-TetraTrue -Condition ($decision.Decision -eq 'Keep') -Message "Expected Keep under Custom (no matching data), got '$($decision.Decision)'."
    Assert-TetraTrue -Condition (-not [string]::IsNullOrWhiteSpace($decision.Reason)) -Message 'Reason was empty under Custom profile.'
}))

# ============================================================
# TEST 19: Dependency conflict downgrades Recommended to Optional
# ============================================================
$Script:TetraAnalyzerSmokeTestResults.Add((Invoke-TetraSmokeTest -Name 'Dependency Conflict Downgrades Recommended To Optional' -Test {
    $decisionsById = @{
        'dep-blocker' = [PSCustomObject]@{ KnowledgeBaseId = 'dep-blocker'; Decision = 'CriticalProtected' }
    }

    $result = Test-TetraDependencyConflict -Dependencies @('dep-blocker') -DecisionsById $decisionsById
    Assert-TetraTrue -Condition ($result.HasConflict -eq $true) -Message 'Conflict with a CriticalProtected dependency was not detected.'
    Assert-TetraTrue -Condition ($result.ConflictingId -eq 'dep-blocker') -Message 'Conflicting Id mismatch.'

    $noConflictResult = Test-TetraDependencyConflict -Dependencies @() -DecisionsById $decisionsById
    Assert-TetraTrue -Condition ($noConflictResult.HasConflict -eq $false) -Message 'Empty dependency list incorrectly reported a conflict.'
}))

# ============================================================
# TEST 20: Cross-category dependency resolves correctly in a full batch
# ============================================================
$Script:TetraAnalyzerSmokeTestResults.Add((Invoke-TetraSmokeTest -Name 'Cross-Category Dependency Resolves In Full Batch' -Test {
    # proc-msmpeng (Processes) depends on svc-windefend (Services) - a
    # real cross-category dependency. Running analysis over BOTH
    # categories together must not error and must produce a decision for
    # both items.
    $states = @(
        (New-TetraSystemStateObservation -Category 'Processes' -KnowledgeBaseId 'proc-msmpeng' -IsInstalled $true -IsActive $true)
        (New-TetraSystemStateObservation -Category 'Services' -KnowledgeBaseId 'svc-windefend' -IsInstalled $true -IsActive $true)
    )

    $decisions = Invoke-TetraAnalysis -Profile 'Gaming' -SystemState $states -Categories @('Processes', 'Services')

    $procDecision = $decisions | Where-Object { $_.KnowledgeBaseId -eq 'proc-msmpeng' }
    $svcDecision  = $decisions | Where-Object { $_.KnowledgeBaseId -eq 'svc-windefend' }

    Assert-TetraTrue -Condition ($null -ne $procDecision) -Message 'No decision produced for proc-msmpeng.'
    Assert-TetraTrue -Condition ($null -ne $svcDecision) -Message 'No decision produced for svc-windefend.'
    Assert-TetraTrue -Condition ($procDecision.Decision -eq 'CriticalProtected') -Message "proc-msmpeng should be CriticalProtected, got '$($procDecision.Decision)'."
    Assert-TetraTrue -Condition ($svcDecision.Decision -eq 'CriticalProtected') -Message "svc-windefend should be CriticalProtected, got '$($svcDecision.Decision)'."
}))

# ============================================================
# TEST 21: Invalid input - mismatched KnowledgeBaseId throws
# ============================================================
$Script:TetraAnalyzerSmokeTestResults.Add((Invoke-TetraSmokeTest -Name 'Mismatched KnowledgeBaseId Is Rejected' -Test {
    $kbItem = Get-TetraKnowledgeBaseItem -Category 'Services' -Id 'svc-fax'
    $wrongState = New-TetraSystemStateObservation -Category 'Services' -KnowledgeBaseId 'svc-wsearch' -IsInstalled $true -IsActive $true

    $threw = $false
    try {
        Invoke-TetraPolicyEvaluation -KnowledgeBaseItem $kbItem -SystemState $wrongState -Profile 'Gaming' | Out-Null
    }
    catch {
        $threw = $true
    }
    Assert-TetraTrue -Condition $threw -Message 'A mismatched KnowledgeBaseId/SystemState pairing was not rejected.'
}))

# ============================================================
# TEST 22: Every decision in a full-KB analysis run has a non-empty Reason
# ============================================================
$Script:TetraAnalyzerSmokeTestResults.Add((Invoke-TetraSmokeTest -Name 'Every Decision Has A Non-Empty Reason' -Test {
    $states = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($category in (Get-TetraKnowledgeBaseCategories)) {
        foreach ($item in (Get-TetraKnowledgeBaseItems -Category $category)) {
            $states.Add((New-TetraSystemStateObservation -Category $category -KnowledgeBaseId $item.Id -IsInstalled $true -IsActive $true))
        }
    }

    $decisions = Invoke-TetraAnalysis -Profile 'Gaming' -SystemState $states.ToArray()

    Assert-TetraTrue -Condition ($decisions.Count -eq 46) -Message "Expected 46 decisions across the full knowledge base, got $($decisions.Count)."
    foreach ($d in $decisions) {
        Assert-TetraTrue -Condition (-not [string]::IsNullOrWhiteSpace($d.Reason)) -Message "Decision for '$($d.KnowledgeBaseId)' has an empty Reason."
    }
}))

# ============================================================
# TEST 23: Multiple observations are handled correctly in one batch
# ============================================================
$Script:TetraAnalyzerSmokeTestResults.Add((Invoke-TetraSmokeTest -Name 'Multiple Observations Handled Correctly In One Batch' -Test {
    $states = @(
        (New-TetraSystemStateObservation -Category 'Services' -KnowledgeBaseId 'svc-fax' -IsInstalled $true -IsActive $true)
        (New-TetraSystemStateObservation -Category 'Services' -KnowledgeBaseId 'svc-sysmain' -IsInstalled $true -IsActive $false)
        (New-TetraSystemStateObservation -Category 'Services' -KnowledgeBaseId 'svc-remoteregistry' -IsInstalled $false -IsActive $false)
    )

    $decisions = Invoke-TetraAnalysis -Profile 'Gaming' -SystemState $states -Categories @('Services')

    $fax  = $decisions | Where-Object { $_.KnowledgeBaseId -eq 'svc-fax' }
    $sys  = $decisions | Where-Object { $_.KnowledgeBaseId -eq 'svc-sysmain' }
    $rreg = $decisions | Where-Object { $_.KnowledgeBaseId -eq 'svc-remoteregistry' }

    Assert-TetraTrue -Condition ($fax.Decision -eq 'Recommended') -Message "svc-fax expected Recommended, got '$($fax.Decision)'."
    Assert-TetraTrue -Condition ($sys.Decision -eq 'Keep') -Message "svc-sysmain (inactive) expected Keep, got '$($sys.Decision)'."
    Assert-TetraTrue -Condition ($rreg.Decision -eq 'DoNotChange') -Message "svc-remoteregistry (not installed) expected DoNotChange, got '$($rreg.Decision)'."
}))

# ============================================================
# TEST 24: Analyzer honestly reports 'Optional' when no observation is provided
# ============================================================
$Script:TetraAnalyzerSmokeTestResults.Add((Invoke-TetraSmokeTest -Name 'Missing Observation Reported Honestly As Optional' -Test {
    $decisions = Invoke-TetraAnalysis -Profile 'Gaming' -SystemState @() -Categories @('Drivers')

    Assert-TetraTrue -Condition ($decisions.Count -eq 6) -Message "Expected 6 decisions for Drivers category with zero observations, got $($decisions.Count)."
    foreach ($d in $decisions) {
        Assert-TetraTrue -Condition ($d.Decision -eq 'Optional') -Message "Expected Optional for '$($d.KnowledgeBaseId)' with no observation, got '$($d.Decision)'."
        Assert-TetraTrue -Condition ($d.Reason -like '*No system state observation*') -Message "Reason did not mention missing observation: $($d.Reason)"
    }
}))

# ============================================================
# TEST 25: Policy evaluation does not mutate the shared Knowledge Base item
# ============================================================
$Script:TetraAnalyzerSmokeTestResults.Add((Invoke-TetraSmokeTest -Name 'Policy Evaluation Does Not Mutate Knowledge Base Item' -Test {
    $kbItem = Get-TetraKnowledgeBaseItem -Category 'Services' -Id 'svc-wsearch'
    $originalJson = $kbItem | ConvertTo-Json -Depth 10 -Compress

    $state = New-TetraSystemStateObservation -Category 'Services' -KnowledgeBaseId 'svc-wsearch' -IsInstalled $true -IsActive $true
    Invoke-TetraPolicyEvaluation -KnowledgeBaseItem $kbItem -SystemState $state -Profile 'Gaming' | Out-Null
    Invoke-TetraPolicyEvaluation -KnowledgeBaseItem $kbItem -SystemState $state -Profile 'Office' | Out-Null

    $afterJson = $kbItem | ConvertTo-Json -Depth 10 -Compress
    Assert-TetraTrue -Condition ($originalJson -eq $afterJson) -Message 'Knowledge Base item was mutated by policy evaluation.'
}))

# ============================================================
# TEST 26: New-TetraAnalysisReport produces a valid report via ReportEngine
# ============================================================
$Script:TetraAnalyzerSmokeTestResults.Add((Invoke-TetraSmokeTest -Name 'Analysis Report Is Valid And Identifies The Profile' -Test {
    $states = @(
        (New-TetraSystemStateObservation -Category 'Services' -KnowledgeBaseId 'svc-fax' -IsInstalled $true -IsActive $true)
    )
    $decisions = Invoke-TetraAnalysis -Profile 'Gaming' -SystemState $states -Categories @('Services')
    $report = New-TetraAnalysisReport -Profile 'Gaming' -Decisions $decisions

    Assert-TetraTrue -Condition ($report.Title -like '*Gaming*') -Message "Report title does not identify the Gaming profile: $($report.Title)"
    Assert-TetraTrue -Condition ($report.Summary -like '*Gaming*') -Message "Report summary does not identify the Gaming profile: $($report.Summary)"

    $stepsSection = $report.Sections | Where-Object { $_.Title -eq 'All Decisions' }
    Assert-TetraTrue -Condition ($null -ne $stepsSection) -Message "Report is missing the 'All Decisions' section."
}))

# ============================================================
# TEST 27: AnalyzerEngine source contains no direct execution/backup calls
# ============================================================
$Script:TetraAnalyzerSmokeTestResults.Add((Invoke-TetraSmokeTest -Name 'Analyzer Never Executes System Changes (Static Check)' -Test {
    $analyzerSourcePath = Join-Path -Path $Script:TetraAnalyzerProjectRootDir -ChildPath 'Engine\AnalyzerEngine.ps1'
    $source = Get-Content -LiteralPath $analyzerSourcePath -Raw -Encoding UTF8

    $forbiddenCalls = @('Backup-TetraItem', 'Restore-TetraBackup', 'Invoke-TetraProtectedOperation', 'Remove-TetraExpiredBackups', 'Set-Service', 'Stop-Service', 'Stop-Process', 'Set-ItemProperty', 'Remove-Item')

    foreach ($forbidden in $forbiddenCalls) {
        Assert-TetraTrue -Condition ($source -notmatch [regex]::Escape($forbidden)) -Message "AnalyzerEngine.ps1 unexpectedly references '$forbidden' - the Analyzer must never execute or back up changes, only recommend them."
    }
}))

# ============================================================
# FUNCTION: Get-TetraAnalyzerSmokeTestResults
# ============================================================
function Get-TetraAnalyzerSmokeTestResults {
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param()

    return $Script:TetraAnalyzerSmokeTestResults
}

# ============================================================
# RESULTS REPORTING (console output intentional - standalone dev tooling)
# ============================================================
$passCount  = @($Script:TetraAnalyzerSmokeTestResults | Where-Object { $_.Passed }).Count
$failCount  = @($Script:TetraAnalyzerSmokeTestResults | Where-Object { -not $_.Passed }).Count
$totalCount = $Script:TetraAnalyzerSmokeTestResults.Count
$allPassed  = ($passCount -eq $totalCount)

Write-Host ''
Write-Host '===== Tetra Optimizer - Analyzer + Policy Engine Smoke Test Results =====' -ForegroundColor Cyan

foreach ($testResult in $Script:TetraAnalyzerSmokeTestResults) {
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
# EXIT BEHAVIOR (dot-source-safe - same rationale as the other four suites)
# ============================================================
$Script:TetraAnalyzerSmokeTestSummary = [PSCustomObject]@{
    PassCount  = $passCount
    FailCount  = $failCount
    TotalCount = $totalCount
    AllPassed  = $allPassed
    Overall    = if ($allPassed) { 'PASS' } else { 'FAIL' }
}

function Get-TetraAnalyzerSmokeTestSummary {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param()

    return $Script:TetraAnalyzerSmokeTestSummary
}

$Script:TetraAnalyzerSmokeTestsWereDotSourced = ($MyInvocation.InvocationName -eq '.')

if (-not $allPassed) {
    if ($Script:TetraAnalyzerSmokeTestsWereDotSourced) {
        Write-Host 'One or more Analyzer smoke tests failed. Not calling exit (script was dot-sourced) - inspect $TetraAnalyzerSmokeTestSummary or call Get-TetraAnalyzerSmokeTestSummary for the result.' -ForegroundColor DarkYellow
    }
    else {
        exit 1
    }
}
