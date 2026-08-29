#Requires -Version 5.1
<#
.SYNOPSIS
    Tetra Optimizer - Analyzer audit recovery tests.
.DESCRIPTION
    Restores the three focused coverage cases identified during the external
    Analyzer audit without modifying production code or the existing smoke suite.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Path $PSScriptRoot -Parent
$bootstrapPath = Join-Path -Path $projectRoot -ChildPath 'Bootstrap\Initialize-Tetra.ps1'
. $bootstrapPath

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

function Invoke-RecoveryTest {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Test
    )

    try {
        & $Test | Out-Null
        $results.Add([PSCustomObject]@{ TestName = $Name; Passed = $true; ErrorMessage = '' })
    }
    catch {
        $results.Add([PSCustomObject]@{ TestName = $Name; Passed = $false; ErrorMessage = $_.Exception.Message })
    }
}

# AUDIT RECOVERY TEST 28:
# Processes KB must enumerate as eight individual PSCustomObjects rather than
# collapsing into a nested System.Object[] value under Windows PowerShell 5.1.
Invoke-RecoveryTest -Name 'Processes KB Returns Eight Individual PSCustomObjects' -Test {
    $items = @(Get-TetraKnowledgeBaseItems -Category 'Processes')
    $expectedIds = @(
        'proc-searchindexer',
        'proc-msmpeng',
        'proc-onedrive',
        'proc-widgets',
        'proc-gamebar',
        'proc-browser-background',
        'proc-teams',
        'proc-dwm'
    )

    if ($items.Count -ne 8) {
        throw "Expected 8 Processes KB items, got $($items.Count)."
    }

    foreach ($item in $items) {
        if ($item -isnot [PSCustomObject]) {
            throw "Expected every Processes KB item to be PSCustomObject, got '$($item.GetType().FullName)'."
        }
    }

    foreach ($id in $expectedIds) {
        if (@($items.Id) -notcontains $id) {
            throw "Processes KB item '$id' is missing."
        }
    }
}

# AUDIT RECOVERY TEST 29:
# A malformed generic PSCustomObject must fail closed instead of producing a
# recommendation. The current production behavior is intentionally preserved;
# this test records the boundary without changing AnalyzerEngine.ps1.
Invoke-RecoveryTest -Name 'Malformed Generic PSCustomObject Fails Closed' -Test {
    $malformedKbItem = [PSCustomObject]@{
        Id       = 'malformed-item'
        Category = 'Services'
    }
    $state = New-TetraSystemStateObservation -Category 'Services' -KnowledgeBaseId 'malformed-item' -IsInstalled $true -IsActive $true

    $threw = $false
    try {
        Invoke-TetraPolicyEvaluation -KnowledgeBaseItem $malformedKbItem -SystemState $state -Profile 'Gaming' | Out-Null
    }
    catch {
        $threw = $true
    }

    if (-not $threw) {
        throw 'Malformed Knowledge Base input unexpectedly produced a policy result instead of failing closed.'
    }
}

# AUDIT RECOVERY TEST 30:
# Empty decision collections are valid report input and must still produce a
# structurally valid, zero-decision analysis report.
Invoke-RecoveryTest -Name 'Empty Decisions Produce Valid Analysis Report' -Test {
    $report = New-TetraAnalysisReport -Profile 'Gaming' -Decisions @()

    if ($null -eq $report) {
        throw 'New-TetraAnalysisReport returned null for an empty decision collection.'
    }
    if ($report.Title -notlike '*Gaming*') {
        throw "Report title does not identify the Gaming profile: '$($report.Title)'."
    }
    if ($report.Summary -notlike '*0 decision*') {
        throw "Report summary does not identify the zero-decision result: '$($report.Summary)'."
    }

    $breakdown = @($report.Sections | Where-Object { $_.Title -eq 'Decision Breakdown' })
    $allDecisions = @($report.Sections | Where-Object { $_.Title -eq 'All Decisions' })
    if ($breakdown.Count -ne 1 -or $allDecisions.Count -ne 1) {
        throw 'Empty analysis report is missing one or more standard decision sections.'
    }
    if (@($report.Recommendations).Count -ne 0) {
        throw "Expected zero recommendations for zero decisions, got $(@($report.Recommendations).Count)."
    }
}

$failed = @($results | Where-Object { -not $_.Passed })
foreach ($result in $results) {
    $status = if ($result.Passed) { 'PASS' } else { 'FAIL' }
    Write-Host "[$status] $($result.TestName)"
    if (-not $result.Passed) {
        Write-Host "        -> $($result.ErrorMessage)"
    }
}

Write-Host "PASS: $(@($results | Where-Object { $_.Passed }).Count)/$($results.Count)"
Write-Host "FAIL: $($failed.Count)/$($results.Count)"

if ($failed.Count -gt 0) {
    exit 1
}
