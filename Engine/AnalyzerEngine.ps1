#Requires -Version 5.1
<#
.SYNOPSIS
    Tetra Optimizer - Analyzer + Policy/Rules Engine
.DESCRIPTION
    Combines live Windows system state (supplied by the caller - see
    input contract below), Knowledge Base metadata, and a selected
    Optimization Profile into an explainable decision for every
    evaluated component: Recommended, Optional, Keep, DoNotChange, or
    CriticalProtected, each with a Reason string.

    RESPONSIBILITY (single):
        Reason about (state + Knowledge Base + Profile) and produce
        decisions. Nothing else.

    THIS FILE MUST NEVER:
        - Execute, back up, restore, or otherwise modify anything on the
          live system. It has NO dependency on BackupEngine or
          Core/Orchestrator - that absence is the architectural proof
          that Profile selection cannot directly execute changes. A
          future System Engine (not built yet) is responsible for taking
          a 'Recommended' decision, backing up via BackupEngine, and
          applying it via the Orchestrator's protected-operation mechanism.
        - Contain hardcoded profile-to-action mappings (no
          "if Profile -eq Gaming then decision = X for item Y"). Every
          decision is derived from the KNOWLEDGE BASE'S OWN metadata
          (Importance, RiskLevel, Reversible, Dependencies,
          RecommendedProfiles, PreserveForProfiles, PerformanceImpact,
          SecurityImpact, IsProtected, RequiresAdditionalValidation)
          combined with the supplied system state - never a lookup table
          keyed by profile name.
        - Print UI (no Write-Host). Engine layer.

    SYSTEM STATE INPUT CONTRACT (this is deliberate - see design note):
        No System Engine exists yet to collect real Windows state. Rather
        than have the Analyzer reach into the OS itself (which would be
        a System Engine's job, not an Analyzer's, and would make this
        file impossible to test meaningfully before those Engines exist),
        the Analyzer accepts state as a parameter, entirely agnostic to
        its source. New-TetraSystemStateObservation defines the one
        shape every future System Engine (Processes, Services, Startup,
        Drivers, Registry, Security) will populate when it collects real
        state. This means zero changes to this file will be required once
        those Engines exist - they will simply become real callers instead
        of the smoke test suite being the only caller.

    POLICY RULE CHAIN (Invoke-TetraPolicyEvaluation, per single item):
        1. IsProtected=true            -> CriticalProtected (hard floor,
           no exceptions, evaluated first, regardless of profile)
        2. Not installed               -> DoNotChange
        3. Profile in PreserveForProfiles -> Keep (preservation wins over
           recommendation)
        4. Not currently active        -> Keep (nothing to optimize)
        5. Profile in RecommendedProfiles:
             - High/Critical RiskLevel, RequiresAdditionalValidation=true,
               or Reversible=false -> downgrade to Optional with reason
             - otherwise           -> Recommended
        6. No signal either way        -> Keep (safe default; per the
           project's safety principle, insufficient confidence means
           Keep/Optional/DoNotChange, never an aggressive recommendation)

        A second pass (inside Invoke-TetraAnalysis, batch-level - a single
        item's evaluation cannot see other items) downgrades a
        'Recommended' item to 'Optional' if any of its Dependencies
        resolved to a blocking decision (CriticalProtected or
        DoNotChange) - changing something whose dependency is protected
        or absent is exactly the kind of workload-affecting risk the
        project's safety principle calls out. This is a single-level
        check, not a multi-level cascade - documented as a known scope
        limit, not built out further without a concrete need.

    DEPENDENCIES:
        Engine/KnowledgeBaseEngine.ps1, Engine/LoggerEngine.ps1, and
        Engine/ReportEngine.ps1 must already be dot-sourced. Deliberately
        NOT dependent on BackupEngine.ps1 or Core/Orchestrator.ps1.
.NOTES
    Module      : AnalyzerEngine.ps1
    Layer       : Engine
    Build Phase : Phase 3 - Analyzer + Policy/Rules Engine
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ============================================================
# FUNCTION: Get-TetraDecisionStates
# ============================================================
<#
.SYNOPSIS
    Returns the fixed set of possible policy decisions.
.OUTPUTS
    System.String[]
#>
function Get-TetraDecisionStates {
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    return @('Recommended', 'Optional', 'Keep', 'DoNotChange', 'CriticalProtected')
}

# ============================================================
# FUNCTION: New-TetraSystemStateObservation
# ============================================================
<#
.SYNOPSIS
    Constructs one correctly-shaped system state observation.
.DESCRIPTION
    The single source of truth for the state object's shape. Every
    future System Engine that collects real Windows state should build
    its observations through this function rather than constructing
    ad-hoc objects, so the shape never drifts.
.PARAMETER Category
    One of Get-TetraKnowledgeBaseCategories.
.PARAMETER KnowledgeBaseId
    The Knowledge Base item Id this observation corresponds to.
.PARAMETER IsInstalled
    Whether the component is present on this system at all.
.PARAMETER IsActive
    Whether the component is currently running/enabled/active.
.PARAMETER CurrentState
    Optional free-text description, e.g. "Running", "Stopped".
.OUTPUTS
    System.Management.Automation.PSCustomObject
#>
function New-TetraSystemStateObservation {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Processes', 'Services', 'Startup', 'Drivers', 'Registry', 'Security')]
        [string]$Category,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$KnowledgeBaseId,

        [Parameter(Mandatory = $true)]
        [bool]$IsInstalled,

        [Parameter(Mandatory = $true)]
        [bool]$IsActive,

        [Parameter(Mandatory = $false)]
        [string]$CurrentState = ''
    )

    return [PSCustomObject]@{
        Category        = $Category
        KnowledgeBaseId = $KnowledgeBaseId
        IsInstalled     = $IsInstalled
        IsActive        = $IsActive
        CurrentState    = $CurrentState
        ObservedUtc     = (Get-Date).ToUniversalTime().ToString('o')
    }
}

# ============================================================
# FUNCTION: Invoke-TetraPolicyEvaluation
# ============================================================
<#
.SYNOPSIS
    Evaluates ONE Knowledge Base item, under ONE system state
    observation, for ONE profile, and returns an explainable decision.
.DESCRIPTION
    See the file-level header for the full rule chain. This function is
    intentionally single-item-scoped - it cannot see other items, so it
    cannot perform dependency-conflict checks (that requires the whole
    batch and is handled by Invoke-TetraAnalysis).
.PARAMETER KnowledgeBaseItem
    A single item as returned by Get-TetraKnowledgeBaseItem/Items.
.PARAMETER SystemState
    A single observation as returned by New-TetraSystemStateObservation.
.PARAMETER Profile
    One of Get-TetraKnownProfiles.
.OUTPUTS
    System.Management.Automation.PSCustomObject: KnowledgeBaseId,
    Category, Profile, Decision, Reason
#>
function Invoke-TetraPolicyEvaluation {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$KnowledgeBaseItem,

        [Parameter(Mandatory = $true)]
        [PSCustomObject]$SystemState,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Gaming', 'Office', 'Balanced', 'Custom')]
        [string]$Profile
    )

    try {
        if ($KnowledgeBaseItem.Id -ne $SystemState.KnowledgeBaseId) {
            throw "SystemState.KnowledgeBaseId '$($SystemState.KnowledgeBaseId)' does not match KnowledgeBaseItem.Id '$($KnowledgeBaseItem.Id)'."
        }

        # ---- Step 1: hard safety floor - no exceptions, evaluated first. ----
        if ($KnowledgeBaseItem.IsProtected -eq $true) {
            return [PSCustomObject]@{
                KnowledgeBaseId = $KnowledgeBaseItem.Id
                Category        = $KnowledgeBaseItem.Category
                Profile         = $Profile
                Decision        = 'CriticalProtected'
                Reason          = 'This component is marked as protected and must never be recommended for modification, regardless of the selected profile.'
            }
        }

        # ---- Step 2: not installed - nothing applicable. ----
        if ($SystemState.IsInstalled -eq $false) {
            return [PSCustomObject]@{
                KnowledgeBaseId = $KnowledgeBaseItem.Id
                Category        = $KnowledgeBaseItem.Category
                Profile         = $Profile
                Decision        = 'DoNotChange'
                Reason          = 'Component is not installed/present on this system; no optimization action is applicable.'
            }
        }

        $preserveForProfiles = @($KnowledgeBaseItem.PreserveForProfiles)
        $recommendedProfiles = @($KnowledgeBaseItem.RecommendedProfiles)

        # ---- Step 3: explicit preservation wins over recommendation. ----
        if ($preserveForProfiles -contains $Profile) {
            $noteSuffix = if ([string]::IsNullOrWhiteSpace($KnowledgeBaseItem.Notes)) { '' } else { " $($KnowledgeBaseItem.Notes)" }
            return [PSCustomObject]@{
                KnowledgeBaseId = $KnowledgeBaseItem.Id
                Category        = $KnowledgeBaseItem.Category
                Profile         = $Profile
                Decision        = 'Keep'
                Reason          = "This component is explicitly preserved for the '$Profile' profile.$noteSuffix"
            }
        }

        # ---- Step 4: not currently active - nothing to optimize. ----
        if ($SystemState.IsActive -eq $false) {
            return [PSCustomObject]@{
                KnowledgeBaseId = $KnowledgeBaseItem.Id
                Category        = $KnowledgeBaseItem.Category
                Profile         = $Profile
                Decision        = 'Keep'
                Reason          = 'Component is installed but not currently active; no change needed.'
            }
        }

        # ---- Step 5: profile-relevant candidate for change. ----
        if ($recommendedProfiles -contains $Profile) {
            $downgradeReasons = [System.Collections.Generic.List[string]]::new()

            if (@('Critical', 'High') -contains $KnowledgeBaseItem.RiskLevel) {
                $downgradeReasons.Add("its risk level is '$($KnowledgeBaseItem.RiskLevel)'")
            }
            if ($KnowledgeBaseItem.RequiresAdditionalValidation -eq $true) {
                $downgradeReasons.Add('it requires additional system-state validation before a confident recommendation can be made')
            }
            if ($KnowledgeBaseItem.Reversible -eq $false) {
                $downgradeReasons.Add('the change is not reversible')
            }

            if ($downgradeReasons.Count -gt 0) {
                return [PSCustomObject]@{
                    KnowledgeBaseId = $KnowledgeBaseItem.Id
                    Category        = $KnowledgeBaseItem.Category
                    Profile         = $Profile
                    Decision        = 'Optional'
                    Reason          = "Relevant to the '$Profile' profile, but marked Optional rather than Recommended because $($downgradeReasons -join ' and '). Review before applying."
                }
            }

            return [PSCustomObject]@{
                KnowledgeBaseId = $KnowledgeBaseItem.Id
                Category        = $KnowledgeBaseItem.Category
                Profile         = $Profile
                Decision        = 'Recommended'
                Reason          = "Recommended for the '$Profile' profile: $($KnowledgeBaseItem.PerformanceImpact) performance impact, $($KnowledgeBaseItem.RiskLevel) risk, and the change is reversible."
            }
        }

        # ---- Step 6: safe default - no strong signal either way. ----
        return [PSCustomObject]@{
            KnowledgeBaseId = $KnowledgeBaseItem.Id
            Category        = $KnowledgeBaseItem.Category
            Profile         = $Profile
            Decision        = 'Keep'
            Reason          = "No specific guidance for the '$Profile' profile; defaulting to Keep per the project's safety principle of preferring caution over an unjustified recommendation."
        }
    }
    catch {
        throw "Invoke-TetraPolicyEvaluation: Failed to evaluate '$($KnowledgeBaseItem.Id)' - $($_.Exception.Message)"
    }
}

# ============================================================
# FUNCTION: Test-TetraDependencyConflict (internal)
# ============================================================
<#
.SYNOPSIS
    Checks whether any of an item's Dependencies resolved to a blocking
    decision (CriticalProtected or DoNotChange) elsewhere in the same
    analysis batch.
.PARAMETER Dependencies
    The item's Dependencies array (other Knowledge Base Ids).
.PARAMETER DecisionsById
    Hashtable of Id -> decision object for every item already evaluated
    in this batch.
.OUTPUTS
    System.Management.Automation.PSCustomObject: HasConflict,
    ConflictingId, ConflictingDecision
#>
function Test-TetraDependencyConflict {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$Dependencies,

        [Parameter(Mandatory = $true)]
        [hashtable]$DecisionsById
    )

    $blockingStates = @('CriticalProtected', 'DoNotChange')

    foreach ($dependencyId in $Dependencies) {
        if ($DecisionsById.ContainsKey($dependencyId)) {
            $dependencyDecision = $DecisionsById[$dependencyId]
            if ($blockingStates -contains $dependencyDecision.Decision) {
                return [PSCustomObject]@{
                    HasConflict         = $true
                    ConflictingId       = $dependencyId
                    ConflictingDecision = $dependencyDecision.Decision
                }
            }
        }
    }

    return [PSCustomObject]@{
        HasConflict         = $false
        ConflictingId        = $null
        ConflictingDecision  = $null
    }
}

# ============================================================
# FUNCTION: Invoke-TetraAnalysis
# ============================================================
<#
.SYNOPSIS
    Evaluates every Knowledge Base item (across the requested categories)
    that has a matching system state observation, for one profile, and
    applies the batch-level dependency-conflict downgrade pass.
.DESCRIPTION
    Items with no matching observation are still reported - as 'Optional'
    with a reason noting the missing data - rather than silently omitted,
    so a caller always sees a complete, honest picture.
.PARAMETER Profile
    One of Get-TetraKnownProfiles.
.PARAMETER SystemState
    Array of observations from New-TetraSystemStateObservation.
.PARAMETER Categories
    Optional - restrict analysis to specific categories. Defaults to all
    six.
.OUTPUTS
    System.Management.Automation.PSCustomObject[] - one decision per
    evaluated Knowledge Base item.
#>
function Invoke-TetraAnalysis {
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Gaming', 'Office', 'Balanced', 'Custom')]
        [string]$Profile,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [PSCustomObject[]]$SystemState,

        [Parameter(Mandatory = $false)]
        [string[]]$Categories = (Get-TetraKnowledgeBaseCategories)
    )

    try {
        Write-TetraLog -Level 'Info' -Module 'AnalyzerEngine' -Action 'AnalysisStarted' -Target $Profile `
            -Result 'Started' -Message "Starting analysis for profile '$Profile' across $($Categories.Count) categor$(if ($Categories.Count -eq 1) { 'y' } else { 'ies' })." | Out-Null

        $stateByKbId = @{}
        foreach ($state in @($SystemState)) {
            $stateByKbId[$state.KnowledgeBaseId] = $state
        }

        $decisions   = [System.Collections.Generic.List[PSCustomObject]]::new()
        $kbItemsById = @{}

        foreach ($category in $Categories) {
            foreach ($kbItem in (Get-TetraKnowledgeBaseItems -Category $category)) {
                $kbItemsById[$kbItem.Id] = $kbItem

                if (-not $stateByKbId.ContainsKey($kbItem.Id)) {
                    $decisions.Add([PSCustomObject]@{
                        KnowledgeBaseId = $kbItem.Id
                        Category        = $kbItem.Category
                        Profile         = $Profile
                        Decision        = 'Optional'
                        Reason          = 'No system state observation was provided for this component; insufficient data for a confident recommendation.'
                    })
                    continue
                }

                $decisions.Add((Invoke-TetraPolicyEvaluation -KnowledgeBaseItem $kbItem -SystemState $stateByKbId[$kbItem.Id] -Profile $Profile))
            }
        }

        # Second pass: batch-level dependency-conflict downgrade.
        $decisionsById = @{}
        foreach ($d in $decisions) { $decisionsById[$d.KnowledgeBaseId] = $d }

        foreach ($d in $decisions) {
            if ($d.Decision -ne 'Recommended') { continue }
            if (-not $kbItemsById.ContainsKey($d.KnowledgeBaseId)) { continue }

            $dependencies = @($kbItemsById[$d.KnowledgeBaseId].Dependencies)
            if ($dependencies.Count -eq 0) { continue }

            $conflict = Test-TetraDependencyConflict -Dependencies $dependencies -DecisionsById $decisionsById
            if ($conflict.HasConflict) {
                $d.Decision = 'Optional'
                $d.Reason   = "Originally Recommended, but downgraded to Optional because its dependency '$($conflict.ConflictingId)' resolved to '$($conflict.ConflictingDecision)' - changing this component could affect that dependency."
            }
        }

        Write-TetraLog -Level 'Success' -Module 'AnalyzerEngine' -Action 'AnalysisCompleted' -Target $Profile `
            -Result 'Success' -Message "Analysis completed: $($decisions.Count) decision(s) produced." | Out-Null

        return $decisions.ToArray()
    }
    catch {
        Write-TetraLog -Level 'Error' -Module 'AnalyzerEngine' -Action 'AnalysisFailed' -Target $Profile `
            -Result 'Failed' -Message $_.Exception.Message | Out-Null

        throw "Invoke-TetraAnalysis: Failed to complete analysis - $($_.Exception.Message)"
    }
}

# ============================================================
# FUNCTION: New-TetraAnalysisReport
# ============================================================
<#
.SYNOPSIS
    Builds a report summarizing an analysis run, reusing ReportEngine
    entirely (New-TetraReport, Add-TetraReportSection,
    Add-TetraReportRecommendation) - no report-rendering logic is
    duplicated here.
.PARAMETER Profile
    The profile the analysis was run under.
.PARAMETER Decisions
    The decisions returned by Invoke-TetraAnalysis.
.OUTPUTS
    System.Management.Automation.PSCustomObject - the report (not saved
    to disk; the caller decides whether/how to save it, same convention
    as Core/Orchestrator's Complete-TetraWorkflow).
#>
function New-TetraAnalysisReport {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Gaming', 'Office', 'Balanced', 'Custom')]
        [string]$Profile,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [PSCustomObject[]]$Decisions
    )

    try {
        $report = New-TetraReport -Title "Optimization Analysis - $Profile Profile" -ReportType 'General' `
            -Summary "Analysis produced $(@($Decisions).Count) decision(s) for the '$Profile' profile."

        $decisionBreakdown = @($Decisions) | Group-Object -Property Decision | Select-Object Name, Count
        Add-TetraReportSection -Report $report -Title 'Decision Breakdown' -Content $decisionBreakdown | Out-Null
        Add-TetraReportSection -Report $report -Title 'All Decisions' -Content $Decisions | Out-Null

        foreach ($decision in $Decisions) {
            if ($decision.Decision -eq 'Recommended') {
                Add-TetraReportRecommendation -Report $report -Title "Consider optimizing: $($decision.KnowledgeBaseId)" `
                    -Description $decision.Reason -Severity 'Low' -Category $decision.Category | Out-Null
            }
            elseif ($decision.Decision -eq 'Optional') {
                Add-TetraReportRecommendation -Report $report -Title "Review: $($decision.KnowledgeBaseId)" `
                    -Description $decision.Reason -Severity 'Info' -Category $decision.Category | Out-Null
            }
        }

        return $report
    }
    catch {
        throw "New-TetraAnalysisReport: Failed to build analysis report - $($_.Exception.Message)"
    }
}

# ============================================================
# MODULE API SURFACE
# ============================================================
# NOTE: documented convention, not an enforced boundary (see
# Config/PathHelpers.ps1 for the full explanation).
#
# Public Functions:
#   - Get-TetraDecisionStates
#   - New-TetraSystemStateObservation
#   - Invoke-TetraPolicyEvaluation
#   - Invoke-TetraAnalysis
#   - New-TetraAnalysisReport
#
# Internal Functions:
#   - Test-TetraDependencyConflict
#
# KNOWN LIMITATION (flagged, not implemented): dependency-conflict
# downgrading is a single pass, not a multi-level cascade (if A depends
# on B, and B was itself downgraded due to ITS OWN dependency C, A is not
# automatically re-checked). No current KB data exercises a chain deeper
# than one level; revisit if/when real data requires it rather than
# building unbounded graph traversal now.
#
# DESIGN DECISION FLAGGED FOR APPROVAL (not made unilaterally): analysis
# reports currently use ReportType='General' because none of
# ReportEngine's existing types (OperationReport, PerformanceReport, etc.)
# fit "analysis/recommendation report" well, and adding a new ReportType
# would require touching the frozen ReportEngine.ps1. Deferred rather
# than done without explicit sign-off.
