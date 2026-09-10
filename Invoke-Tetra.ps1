#Requires -Version 5.1
<#
.SYNOPSIS
    Tetra Optimizer - Production Runtime Entry Point V1
.DESCRIPTION
    Thin, preview-first entry point over PipelineEngine. It owns no scan,
    analysis, recommendation, execution, verification, or reporting logic.

    Default behavior is read-only preview. Mutation is possible only when
    -Execute is explicitly supplied and the Pipeline's existing approval,
    preflight, backup, execution, verification, and reporting contracts allow it.
#>
[CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact='High')]
param(
    [ValidateSet('Gaming','Office','Balanced','Custom')]
    [string]$Profile='Balanced',

    [AllowEmptyCollection()]
    [string[]]$RootPaths=@(),

    [switch]$IncludeFileInventory,
    [switch]$IncludeCleanup,
    [switch]$IncludeDuplicates,

    [long]$MinimumFileSizeBytes=0,
    [long]$LargeFileThresholdBytes=1073741824,
    [long]$DuplicateMinimumSizeBytes=1,
    [int]$MaxFiles=5000,
    [ValidateSet('SHA256','SHA384','SHA512')]
    [string]$DuplicateHashAlgorithm='SHA256',

    [hashtable]$CollectorOverrides=@{},
    [scriptblock]$ApprovalProvider,
    [switch]$Execute,

    # Dependency injection points are intentionally public in V1 so the same
    # runtime contract is deterministic and testable without mutating a PC.
    [scriptblock]$BackupProvider,
    [scriptblock]$DeleteProvider,
    [scriptblock]$RollbackProvider,
    [scriptblock]$PathExistsProvider,
    [scriptblock]$ScanProvider,
    [scriptblock]$AnalysisProvider,
    [scriptblock]$RecommendationProvider,
    [scriptblock]$ActionPlanProvider,
    [scriptblock]$ExecutionProvider,
    [scriptblock]$PostExecutionScanProvider,
    [scriptblock]$VerificationProvider,
    [scriptblock]$ReportProvider,

    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

$root=$PSScriptRoot
if([string]::IsNullOrWhiteSpace($root)){$root=(Get-Location).Path}
$pipelinePath=Join-Path $root 'Engine\PipelineEngine.ps1'
if(-not(Test-Path -LiteralPath $pipelinePath -PathType Leaf)){
    throw "Invoke-Tetra: Pipeline engine was not found at '$pipelinePath'."
}
. $pipelinePath

function New-TetraRuntimeResult {
    param([object]$Pipeline,[string]$Mode)
    return [PSCustomObject]@{
        RecordType='TetraRuntimeResult'
        Mode=$Mode
        Success=($null -ne $Pipeline -and [string]$Pipeline.LifecycleStatus -eq 'Complete')
        PipelineRunId=if($null -ne $Pipeline){[string]$Pipeline.PipelineRunId}else{''}
        Status=if($null -ne $Pipeline){[string]$Pipeline.Status}else{'Failed'}
        LifecycleStatus=if($null -ne $Pipeline){[string]$Pipeline.LifecycleStatus}else{'Failed'}
        MutationAttempted=if($null -ne $Pipeline){[bool]$Pipeline.MutationAttempted}else{$false}
        Pipeline=$Pipeline
        Report=if($null -ne $Pipeline){$Pipeline.Report}else{$null}
        CompletedUtc=(Get-Date).ToUniversalTime().ToString('o')
    }
}

if($MaxFiles -lt 1){throw 'Invoke-Tetra: MaxFiles must be at least 1.'}
if($Execute.IsPresent -and $null -eq $ApprovalProvider){
    throw 'Invoke-Tetra: -Execute requires an explicit -ApprovalProvider. Execution cannot invent user approval.'
}

$mode=if($Execute.IsPresent){'Execute'}else{'Preview'}
$args=@{
    Profile=$Profile
    RootPaths=$RootPaths
    IncludeFileInventory=$IncludeFileInventory.IsPresent
    IncludeCleanup=$IncludeCleanup.IsPresent
    IncludeDuplicates=$IncludeDuplicates.IsPresent
    MinimumFileSizeBytes=$MinimumFileSizeBytes
    LargeFileThresholdBytes=$LargeFileThresholdBytes
    DuplicateMinimumSizeBytes=$DuplicateMinimumSizeBytes
    MaxFiles=$MaxFiles
    DuplicateHashAlgorithm=$DuplicateHashAlgorithm
    CollectorOverrides=$CollectorOverrides
    Execute=$Execute.IsPresent
    Confirm=$false
}
foreach($name in @('ApprovalProvider','BackupProvider','DeleteProvider','RollbackProvider','PathExistsProvider','ScanProvider','AnalysisProvider','RecommendationProvider','ActionPlanProvider','ExecutionProvider','PostExecutionScanProvider','VerificationProvider','ReportProvider')){
    $value=Get-Variable -Name $name -ValueOnly
    if($null -ne $value){$args[$name]=$value}
}

if($Execute.IsPresent){
    if(-not $PSCmdlet.ShouldProcess('Tetra approved action plan','Run mutation-capable Tetra pipeline')){
        return New-TetraRuntimeResult -Pipeline $null -Mode 'ExecutionDeclined'
    }
}

$pipeline=Invoke-TetraPipeline @args
$result=New-TetraRuntimeResult -Pipeline $pipeline -Mode $mode

if($PassThru.IsPresent){return $result}
return $result.Report
