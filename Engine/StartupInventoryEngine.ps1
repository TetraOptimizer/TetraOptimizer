#Requires -Version 5.1
<#
.SYNOPSIS
    Tetra Optimizer - Startup Inventory Engine (Phase 1)
.DESCRIPTION
    Collects positive, read-only evidence about Windows startup entries and
    converts exact executable matches into Analyzer observations.

    SAFETY CONTRACT:
        - Read-only. Never enables, disables, creates, removes, or edits startup entries.
        - Win32_StartupCommand is treated as positive evidence only. Absence from
          this provider is NOT proof that an application is not installed or that
          no disabled startup entry exists elsewhere.
        - User/account identity is deliberately not retained in inventory records.
        - Ambiguous/composite Knowledge Base identifiers are not inferred.

    DEPENDENCIES:
        Engine/LoggerEngine.ps1, Engine/KnowledgeBaseEngine.ps1, and
        Engine/AnalyzerEngine.ps1 should already be dot-sourced by the caller.
.NOTES
    Module      : StartupInventoryEngine.ps1
    Layer       : Engine
    Build Phase : Phase 4 - System Inventory / Audit
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-TetraExecutableNameFromCommand {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [string]$Command
    )

    if ([string]::IsNullOrWhiteSpace($Command)) { return '' }

    $trimmed = $Command.Trim()
    $candidate = ''

    if ($trimmed.StartsWith('"')) {
        $closingQuote = $trimmed.IndexOf('"', 1)
        if ($closingQuote -gt 1) {
            $candidate = $trimmed.Substring(1, $closingQuote - 1)
        }
    }

    if ([string]::IsNullOrWhiteSpace($candidate)) {
        $exeMatch = [regex]::Match($trimmed, '(?i)(?:^|\s)([^\s"]+\.exe)(?:\s|$)')
        if ($exeMatch.Success) {
            $candidate = $exeMatch.Groups[1].Value
        }
    }

    if ([string]::IsNullOrWhiteSpace($candidate)) { return '' }

    try {
        return [System.IO.Path]::GetFileName($candidate)
    }
    catch {
        return ''
    }
}

function New-TetraStartupInventoryRecord {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [object]$StartupData,

        [Parameter(Mandatory = $false)]
        [string]$ObservedUtc = ((Get-Date).ToUniversalTime().ToString('o'))
    )

    $name = if ($null -eq $StartupData.Name) { '' } else { [string]$StartupData.Name }
    $command = if ($null -eq $StartupData.Command) { '' } else { [string]$StartupData.Command }
    $location = if ($null -eq $StartupData.Location) { '' } else { [string]$StartupData.Location }
    $exeName = Get-TetraExecutableNameFromCommand -Command $command

    return [PSCustomObject]@{
        RecordType       = 'Startup'
        Category         = 'Startup'
        Name             = $name
        ExecutableName   = $exeName
        Command          = $command
        Location         = $location
        UserIdentityKept = $false
        EvidenceSource   = 'Win32_StartupCommand'
        EvidenceKey      = "Name=$name;Executable=$exeName;Location=$location"
        ObservedUtc      = $ObservedUtc
    }
}

function Get-TetraStartupInventory {
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter(Mandatory = $false)]
        [AllowEmptyCollection()]
        [object[]]$StartupData = $null
    )

    try {
        $observedUtc = (Get-Date).ToUniversalTime().ToString('o')

        if ($null -eq $StartupData) {
            $StartupData = @(Get-CimInstance -ClassName Win32_StartupCommand -ErrorAction Stop)
        }

        $records = [System.Collections.Generic.List[PSCustomObject]]::new()
        foreach ($entry in @($StartupData)) {
            if ($null -eq $entry) { continue }
            $records.Add((New-TetraStartupInventoryRecord -StartupData $entry -ObservedUtc $observedUtc))
        }

        if (Get-Command -Name Write-TetraLog -ErrorAction SilentlyContinue) {
            Write-TetraLog -Level 'Info' -Module 'StartupInventoryEngine' -Action 'StartupInventory' -Target 'Win32_StartupCommand' `
                -Result 'Success' -Message "Collected $($records.Count) positive startup entry record(s) without modifying system state." | Out-Null
        }

        return $records.ToArray()
    }
    catch {
        if (Get-Command -Name Write-TetraLog -ErrorAction SilentlyContinue) {
            Write-TetraLog -Level 'Error' -Module 'StartupInventoryEngine' -Action 'StartupInventory' -Target 'Win32_StartupCommand' `
                -Result 'Failed' -Message $_.Exception.Message | Out-Null
        }

        throw "Get-TetraStartupInventory: Failed to collect startup inventory - $($_.Exception.Message)"
    }
}

function Get-TetraExactStartupIdentifier {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SystemIdentifier
    )

    $identifier = $SystemIdentifier.Trim()
    if ($identifier -match '[\\/|]') { return '' }
    if ($identifier -notmatch '^[^\\/]+\.exe$') { return '' }
    return $identifier
}

function ConvertTo-TetraStartupSystemState {
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [PSCustomObject[]]$InventoryRecords
    )

    if (-not (Get-Command -Name New-TetraSystemStateObservation -ErrorAction SilentlyContinue)) {
        throw 'ConvertTo-TetraStartupSystemState: AnalyzerEngine is not loaded; New-TetraSystemStateObservation is unavailable.'
    }

    $recordsByExecutable = @{}
    foreach ($record in @($InventoryRecords)) {
        if ($null -eq $record -or [string]::IsNullOrWhiteSpace($record.ExecutableName)) { continue }
        $key = $record.ExecutableName.ToLowerInvariant()
        if (-not $recordsByExecutable.ContainsKey($key)) {
            $recordsByExecutable[$key] = [System.Collections.Generic.List[PSCustomObject]]::new()
        }
        $recordsByExecutable[$key].Add($record)
    }

    $observations = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($kbItem in (Get-TetraKnowledgeBaseItems -Category 'Startup')) {
        $exactIdentifier = Get-TetraExactStartupIdentifier -SystemIdentifier $kbItem.SystemIdentifier
        if ([string]::IsNullOrWhiteSpace($exactIdentifier)) { continue }

        $key = $exactIdentifier.ToLowerInvariant()
        if (-not $recordsByExecutable.ContainsKey($key)) { continue }

        $matches = $recordsByExecutable[$key]
        $locations = @($matches | ForEach-Object { $_.Location } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
        $stateText = "StartupPresent; Entries=$($matches.Count)"
        if ($locations.Count -gt 0) {
            $stateText += "; Locations=$($locations -join ' | ')"
        }

        $observations.Add((New-TetraSystemStateObservation `
            -Category 'Startup' `
            -KnowledgeBaseId $kbItem.Id `
            -IsInstalled $true `
            -IsActive $true `
            -CurrentState $stateText))
    }

    return $observations.ToArray()
}

# Public Functions:
#   - Get-TetraStartupInventory
#   - ConvertTo-TetraStartupSystemState
# Internal Functions:
#   - Get-TetraExecutableNameFromCommand
#   - New-TetraStartupInventoryRecord
#   - Get-TetraExactStartupIdentifier
