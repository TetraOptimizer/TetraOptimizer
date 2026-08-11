#Requires -Version 5.1
<#
.SYNOPSIS
    Tetra Optimizer - Core Orchestrator
.DESCRIPTION
    Orchestration/control layer above the existing Engines. Wires
    together a policy - "protect before you change, roll back
    automatically on failure" - that does not belong in any single
    existing Engine, using Config, LoggerEngine, BackupEngine, and
    ReportEngine exactly as already validated. Duplicates none of their
    logic.

    RESPONSIBILITY (single):
        Track a single active "workflow" (a named sequence of steps
        correlated under one OperationId) and execute individual steps
        with config-gated automatic backup and automatic rollback on
        failure. Nothing else - this file contains no path-validation,
        no logging machinery, no backup/restore mechanics, and no report
        rendering of its own; all of that is reused from the Engines
        below it.

    WHAT THIS FILE DELIBERATELY DOES NOT DO:
        - No UI/menus. No capability registry (nothing to register yet).
        - No nested workflows - single active slot only; starting a
          second workflow while one is active fails safely (throws)
          rather than silently overwriting state.
        - No new ID scheme - WorkflowId IS LoggerEngine's OperationId.
        - No new path-validation - PathsToProtect safety is entirely
          inherited from Backup-TetraItem's existing source-path guard.
        - No automatic report saving - Complete-TetraWorkflow returns the
          report object; the caller decides whether/how to save it.

    PROTECTED-OPERATION SAFETY MODEL:
        1. Reads Backup.AutoBackupBeforeChanges (existing Config key -
           zero Config.ps1 changes needed).
        2. If enabled and -PathsToProtect given, calls Backup-TetraItem
           (reused) before the operation runs.
        3. Executes the operation via Invoke-TetraLoggedOperation
           (reused) - inherits its timing/logging/error-handling
           automatically.
        4. If the operation throws and a backup was taken, automatically
           calls Restore-TetraBackup -Confirm:$false (reused) to undo the
           partial change, then re-throws the ORIGINAL failure with the
           rollback outcome appended - honestly, including if rollback
           itself failed. The system is never reported as protected if
           rollback did not fully succeed.

    KNOWN LIMITATION (documented, not solved): protection is opt-in per
    call. Orchestrator cannot force a caller to pass -PathsToProtect; a
    caller that omits it gets no auto-backup. This is a calling
    convention, not an enforced guarantee.

    DEPENDENCIES:
        Config/Config.ps1, Engine/LoggerEngine.ps1, Engine/BackupEngine.ps1,
        and Engine/ReportEngine.ps1 must already be dot-sourced.
.NOTES
    Module      : Orchestrator.ps1
    Layer       : Core
    Build Phase : Post-Foundation-Freeze, post-Backup-Engine - Core
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Single-slot active workflow tracker. $null when no workflow is active.
$Script:TetraCurrentWorkflow = $null

# ============================================================
# FUNCTION: ConvertTo-TetraWorkflowStepSummary (internal)
# ============================================================
<#
.SYNOPSIS
    Reshapes a workflow's tracked step records into report-section
    content.
.PARAMETER Steps
    The workflow's Steps collection.
.OUTPUTS
    System.String (if empty) or PSCustomObject[] suitable for
    Add-TetraReportSection's -Content parameter.
#>
function ConvertTo-TetraWorkflowStepSummary {
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Steps
    )

    $stepArray = @($Steps)

    if ($stepArray.Count -eq 0) {
        return 'No steps were recorded for this workflow.'
    }

    return @($stepArray | Select-Object StepName, Success, DurationMs, BackupTaken, RolledBack, RollbackSuccess, ErrorMessage)
}

# ============================================================
# FUNCTION: Start-TetraWorkflow
# ============================================================
<#
.SYNOPSIS
    Begins a new workflow - a named sequence of steps correlated under
    one OperationId (LoggerEngine's existing mechanism; no new ID scheme).
.DESCRIPTION
    Single-slot: fails safely (throws) if a workflow is already active,
    rather than silently overwriting it.
.PARAMETER Name
    A human-readable workflow name, e.g. "System Optimization".
.OUTPUTS
    System.Management.Automation.PSCustomObject: WorkflowId, Name,
    StartedUtc, Steps
#>
function Start-TetraWorkflow {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Name
    )

    try {
        if ($null -ne $Script:TetraCurrentWorkflow) {
            throw "A workflow ('$($Script:TetraCurrentWorkflow.Name)', WorkflowId '$($Script:TetraCurrentWorkflow.WorkflowId)') is already active. Call Complete-TetraWorkflow before starting a new one."
        }

        $operationContext = Start-TetraOperation -Name $Name

        $Script:TetraCurrentWorkflow = [PSCustomObject]@{
            WorkflowId = $operationContext.OperationId.ToString()
            Name       = $Name
            StartedUtc = $operationContext.StartTimeUtc
            Steps      = [System.Collections.Generic.List[PSCustomObject]]::new()
        }

        Write-TetraLog -Level 'Info' -Module 'Orchestrator' -Action 'WorkflowStarted' -Target $Script:TetraCurrentWorkflow.WorkflowId `
            -Result 'Started' -Message "Workflow '$Name' started." | Out-Null

        return $Script:TetraCurrentWorkflow
    }
    catch {
        throw "Start-TetraWorkflow: $($_.Exception.Message)"
    }
}

# ============================================================
# FUNCTION: Get-TetraCurrentWorkflow
# ============================================================
<#
.SYNOPSIS
    Returns the currently active workflow context, or $null if none is
    active.
.OUTPUTS
    System.Management.Automation.PSCustomObject or $null
#>
function Get-TetraCurrentWorkflow {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param()

    return $Script:TetraCurrentWorkflow
}

# ============================================================
# FUNCTION: Complete-TetraWorkflow
# ============================================================
<#
.SYNOPSIS
    Ends the active workflow and returns a report summarizing it.
.DESCRIPTION
    Wraps Stop-TetraOperation (reused) and New-TetraOperationReport
    (reused, from ReportEngine - not duplicated), then adds a
    Core-specific "Workflow Steps" section built from the steps actually
    tracked by Invoke-TetraProtectedOperation calls made during this
    workflow. Safe to call even after a step already threw (the
    workflow's step list still reflects everything that happened up to
    the failure). The workflow slot is always cleared, even if report
    construction itself fails, so the system never gets stuck unable to
    start a new workflow.

    Does NOT save the report to disk - the caller decides.

    If no workflow is currently active, returns $null (mirrors
    Stop-TetraOperation's own behavior when nothing is active).
.OUTPUTS
    System.Management.Automation.PSCustomObject (the report) or $null.
#>
function Complete-TetraWorkflow {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param()

    if ($null -eq $Script:TetraCurrentWorkflow) {
        Write-Verbose 'Complete-TetraWorkflow: No active workflow to complete.'
        return $null
    }

    try {
        $workflow = $Script:TetraCurrentWorkflow

        Stop-TetraOperation | Out-Null

        $report = New-TetraOperationReport -OperationId $workflow.WorkflowId -Title "Workflow Report - $($workflow.Name)"

        $stepSummary = ConvertTo-TetraWorkflowStepSummary -Steps @($workflow.Steps)
        Add-TetraReportSection -Report $report -Title 'Workflow Steps' -Content $stepSummary | Out-Null

        Write-TetraLog -Level 'Info' -Module 'Orchestrator' -Action 'WorkflowCompleted' -Target $workflow.WorkflowId `
            -Result 'Success' -Message "Workflow '$($workflow.Name)' completed with $($workflow.Steps.Count) step(s)." | Out-Null

        return $report
    }
    finally {
        # Always clear the slot, even if something above threw, so the
        # system can never get stuck unable to start a new workflow.
        $Script:TetraCurrentWorkflow = $null
    }
}

# ============================================================
# FUNCTION: Invoke-TetraProtectedOperation
# ============================================================
<#
.SYNOPSIS
    Executes a script block with config-gated automatic backup and
    automatic rollback on failure.
.DESCRIPTION
    See the file-level header for the full safety model. In summary:
    reads Backup.AutoBackupBeforeChanges; backs up -PathsToProtect first
    if enabled and provided; executes -ScriptBlock via
    Invoke-TetraLoggedOperation; on failure, automatically restores from
    the pre-change backup (if one was taken) and re-throws the ORIGINAL
    error with the rollback outcome appended, honestly, whether rollback
    succeeded or not.

    If a workflow is currently active (Start-TetraWorkflow), this step's
    outcome is automatically recorded into it. If no workflow is active,
    the step still executes normally (a standalone protected operation),
    just without being tracked as part of a larger sequence.
.PARAMETER StepName
    A descriptive name for this step, used for logging and workflow
    tracking.
.PARAMETER PathsToProtect
    Optional file paths to back up before running -ScriptBlock. Subject
    to the exact same source-path safety validation as Backup-TetraItem
    (not re-implemented here).
.PARAMETER Category
    Backup category to use if a backup is taken. Defaults to 'General'.
.PARAMETER ScriptBlock
    The operation to execute.
.OUTPUTS
    System.Management.Automation.PSCustomObject: Success, WhatIf,
    StepName, Output, BackupId
#>
function Invoke-TetraProtectedOperation {
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$StepName,

        [Parameter(Mandatory = $false)]
        [string[]]$PathsToProtect = @(),

        [Parameter(Mandatory = $false)]
        [ValidateSet('Registry', 'Services', 'Startup', 'PowerPlans', 'Drivers', 'Network', 'General')]
        [string]$Category = 'General',

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [scriptblock]$ScriptBlock
    )

    Write-TetraLog -Level 'Info' -Module 'Orchestrator' -Action 'ProtectedOperationStarted' -Target $StepName `
        -Result 'Started' -Message "Starting protected operation '$StepName'." | Out-Null

    if (-not $PSCmdlet.ShouldProcess($StepName, 'Execute protected operation')) {
        Write-TetraLog -Level 'Info' -Module 'Orchestrator' -Action 'ProtectedOperationStarted' -Target $StepName `
            -Result 'Skipped' -Message 'Protected operation skipped (WhatIf or declined) - no changes made.' | Out-Null

        $skippedStep = [PSCustomObject]@{
            StepName        = $StepName
            Success         = $false
            DurationMs      = $null
            BackupTaken     = $false
            BackupId        = $null
            RolledBack      = $false
            RollbackSuccess = $null
            ErrorMessage    = ''
        }

        if ($null -ne $Script:TetraCurrentWorkflow) {
            $Script:TetraCurrentWorkflow.Steps.Add($skippedStep)
        }

        return [PSCustomObject]@{
            Success  = $false
            WhatIf   = $true
            StepName = $StepName
            Output   = $null
            BackupId = $null
            Message  = 'No changes made (WhatIf or declined).'
        }
    }

    $autoBackupEnabled = [bool](Get-TetraConfigValueOrDefault -Path 'Backup.AutoBackupBeforeChanges' -Default $true)
    $backupResult = $null

    if ($autoBackupEnabled -and $PathsToProtect.Count -gt 0) {
        $backupResult = Backup-TetraItem -Path $PathsToProtect -Category $Category `
            -Label "Pre-change backup for step '$StepName'" -RequestedByModule 'Orchestrator'
    }

    try {
        $operationResult = Invoke-TetraLoggedOperation -Module 'Orchestrator' -Action $StepName `
            -Target ($PathsToProtect -join ', ') -ScriptBlock $ScriptBlock

        $stepRecord = [PSCustomObject]@{
            StepName        = $StepName
            Success         = $true
            DurationMs      = $operationResult.DurationMs
            BackupTaken     = ($null -ne $backupResult)
            BackupId        = if ($backupResult) { $backupResult.BackupId } else { $null }
            RolledBack      = $false
            RollbackSuccess = $null
            ErrorMessage    = ''
        }

        if ($null -ne $Script:TetraCurrentWorkflow) {
            $Script:TetraCurrentWorkflow.Steps.Add($stepRecord)
        }

        Write-TetraLog -Level 'Success' -Module 'Orchestrator' -Action 'ProtectedOperationCompleted' -Target $StepName `
            -Result 'Success' -Message "Protected operation '$StepName' completed successfully." | Out-Null

        return [PSCustomObject]@{
            Success  = $true
            WhatIf   = $false
            StepName = $StepName
            Output   = $operationResult.Output
            BackupId = $stepRecord.BackupId
        }
    }
    catch {
        $operationError = $_.Exception.Message

        Write-TetraLog -Level 'Error' -Module 'Orchestrator' -Action 'ProtectedOperationFailed' -Target $StepName `
            -Result 'Failed' -Message $operationError | Out-Null

        $rollbackSuccess = $null
        $rollbackNote    = 'No backup was taken; nothing to roll back.'

        if ($null -ne $backupResult) {
            Write-TetraLog -Level 'Warning' -Module 'Orchestrator' -Action 'AutoRollbackStarted' -Target $StepName `
                -Result 'Started' -Message "Attempting automatic rollback using backup '$($backupResult.BackupId)'." | Out-Null

            try {
                Restore-TetraBackup -Category $Category -BackupId $backupResult.BackupId -Confirm:$false | Out-Null
                $rollbackSuccess = $true
                $rollbackNote    = 'The pre-change state was automatically restored.'

                Write-TetraLog -Level 'Info' -Module 'Orchestrator' -Action 'AutoRollbackCompleted' -Target $StepName `
                    -Result 'Success' -Message $rollbackNote | Out-Null
            }
            catch {
                $rollbackSuccess = $false
                $rollbackNote    = "Automatic rollback also failed: $($_.Exception.Message)"

                Write-TetraLog -Level 'Error' -Module 'Orchestrator' -Action 'AutoRollbackFailed' -Target $StepName `
                    -Result 'Failed' -Message $rollbackNote | Out-Null
            }
        }

        $stepRecord = [PSCustomObject]@{
            StepName        = $StepName
            Success         = $false
            DurationMs      = $null
            BackupTaken     = ($null -ne $backupResult)
            BackupId        = if ($backupResult) { $backupResult.BackupId } else { $null }
            RolledBack      = ($null -ne $backupResult)
            RollbackSuccess = $rollbackSuccess
            ErrorMessage    = $operationError
        }

        if ($null -ne $Script:TetraCurrentWorkflow) {
            $Script:TetraCurrentWorkflow.Steps.Add($stepRecord)
        }

        throw "Invoke-TetraProtectedOperation: Step '$StepName' failed - $operationError ($rollbackNote)"
    }
}

# ============================================================
# MODULE API SURFACE
# ============================================================
# NOTE: documented convention, not an enforced boundary (see
# Config/PathHelpers.ps1 for the full explanation).
#
# Public Functions:
#   - Start-TetraWorkflow
#   - Get-TetraCurrentWorkflow
#   - Complete-TetraWorkflow
#   - Invoke-TetraProtectedOperation
#
# Internal Functions:
#   - ConvertTo-TetraWorkflowStepSummary
