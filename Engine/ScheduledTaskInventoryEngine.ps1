#Requires -Version 5.1
<#
.SYNOPSIS
    Tetra Optimizer - Scheduled Task Inventory Engine
.DESCRIPTION
    Collects read-only scheduled-task evidence. Task actions are summarized by
    executable name by default; arguments are not retained.

    SAFETY CONTRACT:
        - Read-only. Never register, unregister, enable, disable, start, or stop tasks.
        - Principal/user identity is not retained.
        - Action arguments are not retained.
        - Windows-owned task paths are identified as evidence, not classified as removable.
        - Absence from a snapshot is never interpreted as safe-to-remove evidence.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-TetraScheduledTaskPropertyValue {
    param([object]$InputObject, [string]$Name, [object]$DefaultValue = $null)
    if ($null -eq $InputObject) { return $DefaultValue }
    $p = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $p -or $null -eq $p.Value) { return $DefaultValue }
    return $p.Value
}

function Get-TetraScheduledTaskExecutableName {
    param([AllowNull()][object]$Execute)
    if ($null -eq $Execute) { return '' }
    $text = ([string]$Execute).Trim().Trim('"')
    if ([string]::IsNullOrWhiteSpace($text)) { return '' }
    try { return [System.IO.Path]::GetFileName($text) } catch { return $text }
}

function New-TetraScheduledTaskInventoryRecord {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][object]$Task, [string]$ObservedUtc = ((Get-Date).ToUniversalTime().ToString('o')))

    $name = [string](Get-TetraScheduledTaskPropertyValue $Task 'TaskName' '')
    $path = [string](Get-TetraScheduledTaskPropertyValue $Task 'TaskPath' '\')
    $state = [string](Get-TetraScheduledTaskPropertyValue $Task 'State' 'Unknown')
    $settings = Get-TetraScheduledTaskPropertyValue $Task 'Settings' $null
    $enabled = $true
    if ($null -ne $settings) {
        $enabledValue = Get-TetraScheduledTaskPropertyValue $settings 'Enabled' $null
        if ($null -ne $enabledValue) { $enabled = [bool]$enabledValue }
    }

    $actionExecutables = [System.Collections.Generic.List[string]]::new()
    foreach ($action in @(Get-TetraScheduledTaskPropertyValue $Task 'Actions' @())) {
        $exe = Get-TetraScheduledTaskExecutableName (Get-TetraScheduledTaskPropertyValue $action 'Execute' '')
        if (-not [string]::IsNullOrWhiteSpace($exe) -and -not $actionExecutables.Contains($exe)) { $actionExecutables.Add($exe) }
    }

    $triggerTypes = [System.Collections.Generic.List[string]]::new()
    foreach ($trigger in @(Get-TetraScheduledTaskPropertyValue $Task 'Triggers' @())) {
        $typeName = $trigger.GetType().Name
        if (-not [string]::IsNullOrWhiteSpace($typeName) -and -not $triggerTypes.Contains($typeName)) { $triggerTypes.Add($typeName) }
    }

    $isWindowsPath = $path.StartsWith('\Microsoft\Windows\', [System.StringComparison]::OrdinalIgnoreCase)

    return [PSCustomObject]@{
        RecordType = 'ScheduledTask'
        Category = 'ScheduledTasks'
        TaskName = $name
        TaskPath = $path
        FullTaskName = ($path + $name)
        State = $state
        Enabled = $enabled
        IsWindowsOwnedPath = $isWindowsPath
        ActionExecutables = $actionExecutables.ToArray()
        ActionCount = @((Get-TetraScheduledTaskPropertyValue $Task 'Actions' @())).Count
        TriggerTypes = $triggerTypes.ToArray()
        TriggerCount = @((Get-TetraScheduledTaskPropertyValue $Task 'Triggers' @())).Count
        ActionArgumentsCaptured = $false
        PrincipalIdentityCaptured = $false
        EvidenceSource = 'ScheduledTasks'
        EvidenceKey = ($path + $name)
        ObservedUtc = $ObservedUtc
    }
}

function Get-TetraScheduledTaskInventory {
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param([AllowEmptyCollection()][object[]]$TaskData = $null)

    try {
        if ($null -eq $TaskData) { $TaskData = @(Get-ScheduledTask -ErrorAction Stop) }
        $utc = (Get-Date).ToUniversalTime().ToString('o')
        $records = [System.Collections.Generic.List[PSCustomObject]]::new()
        foreach ($task in @($TaskData)) {
            if ($null -eq $task) { continue }
            $record = New-TetraScheduledTaskInventoryRecord -Task $task -ObservedUtc $utc
            if ([string]::IsNullOrWhiteSpace($record.TaskName)) { continue }
            $records.Add($record)
        }
        if (Get-Command Write-TetraLog -ErrorAction SilentlyContinue) {
            Write-TetraLog -Level 'Info' -Module 'ScheduledTaskInventoryEngine' -Action 'TaskInventory' -Target 'TaskScheduler' -Result 'Success' -Message "Collected $($records.Count) scheduled task record(s) without modifying system state." | Out-Null
        }
        return $records.ToArray()
    }
    catch {
        if (Get-Command Write-TetraLog -ErrorAction SilentlyContinue) {
            Write-TetraLog -Level 'Error' -Module 'ScheduledTaskInventoryEngine' -Action 'TaskInventory' -Target 'TaskScheduler' -Result 'Failed' -Message $_.Exception.Message | Out-Null
        }
        throw "Get-TetraScheduledTaskInventory: Failed to collect scheduled task inventory - $($_.Exception.Message)"
    }
}

# Public Functions:
#   - Get-TetraScheduledTaskInventory
# Internal Functions:
#   - New-TetraScheduledTaskInventoryRecord
#   - Get-TetraScheduledTaskExecutableName
