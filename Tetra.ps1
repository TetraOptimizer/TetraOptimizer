#Requires -Version 5.1
<#
.SYNOPSIS
    Tetra Optimizer - Production Entry Point V1
.DESCRIPTION
    Official thin production entry point for Tetra Optimizer.

    Tetra.ps1 validates the Windows/PowerShell environment, initializes the
    dependency-safe Tetra foundation, and delegates the complete
    Scan -> Analyze -> Recommend -> Approval -> Execute -> Verify -> Report
    lifecycle to PipelineEngine. Preview is the default and is read-only with
    respect to Windows/system state.

    No system mutation is implemented in this file. Mutation-capable execution
    requires -Execute plus an explicit ApprovalProvider and remains governed by
    PipelineEngine/ExecutionEngine preflight, backup, verification and rollback.
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

    # Public dependency-injection points keep the production contract testable.
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

function Test-TetraProductionEnvironment {
    [CmdletBinding()]
    param()

    $isWindows=$true
    if($PSVersionTable.PSVersion.Major -ge 6){$isWindows=$IsWindows}

    $isAdmin=$false
    try {
        $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
        $principal=New-Object Security.Principal.WindowsPrincipal($identity)
        $isAdmin=$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        $isAdmin=$false
    }

    return [PSCustomObject]@{
        IsWindows=[bool]$isWindows
        PowerShellVersion=$PSVersionTable.PSVersion.ToString()
        PowerShellSupported=($PSVersionTable.PSVersion.Major -ge 5)
        IsAdministrator=[bool]$isAdmin
        IsValid=([bool]$isWindows -and $PSVersionTable.PSVersion.Major -ge 5)
    }
}

function New-TetraProductionResult {
    param([object]$Pipeline,[string]$Mode,[object]$Environment)
    return [PSCustomObject]@{
        RecordType='TetraRuntimeResult'
        Mode=$Mode
        Success=($null -ne $Pipeline -and [string]$Pipeline.LifecycleStatus -eq 'Complete')
        PipelineRunId=if($null -ne $Pipeline){[string]$Pipeline.PipelineRunId}else{''}
        Status=if($null -ne $Pipeline){[string]$Pipeline.Status}else{'Failed'}
        LifecycleStatus=if($null -ne $Pipeline){[string]$Pipeline.LifecycleStatus}else{'Failed'}
        MutationAttempted=if($null -ne $Pipeline){[bool]$Pipeline.MutationAttempted}else{$false}
        Environment=$Environment
        Pipeline=$Pipeline
        Report=if($null -ne $Pipeline){$Pipeline.Report}else{$null}
        CompletedUtc=(Get-Date).ToUniversalTime().ToString('o')
    }
}

if($MaxFiles -lt 1){throw 'Tetra: MaxFiles must be at least 1.'}
if($Execute.IsPresent -and $null -eq $ApprovalProvider){
    throw 'Tetra: -Execute requires an explicit -ApprovalProvider. Execution cannot invent user approval.'
}

$environment=Test-TetraProductionEnvironment
if(-not $environment.IsValid){
    throw "Tetra: Unsupported runtime environment. Windows=$($environment.IsWindows); PowerShell=$($environment.PowerShellVersion)."
}

# Production requires the validated foundation load order (Config, Logger,
# Knowledge Base, Analyzer, etc.). Tetra.ps1 remains the public entry point;
# Bootstrap is used only as the internal dependency loader/initializer.
$bootstrapPath=Join-Path $root 'Bootstrap\Initialize-Tetra.ps1'
if(-not(Test-Path -LiteralPath $bootstrapPath -PathType Leaf)){
    throw "Tetra: Foundation bootstrap was not found at '$bootstrapPath'."
}
. $bootstrapPath

$pipelinePath=Join-Path $root 'Engine\PipelineEngine.ps1'
if(-not(Test-Path -LiteralPath $pipelinePath -PathType Leaf)){
    throw "Tetra: Pipeline engine was not found at '$pipelinePath'."
}
. $pipelinePath

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
    if(-not $environment.IsAdministrator){
        throw 'Tetra: execution mode requires an elevated Administrator PowerShell session.'
    }
    if(-not $PSCmdlet.ShouldProcess('Tetra approved action plan','Run mutation-capable Tetra pipeline')){
        return New-TetraProductionResult -Pipeline $null -Mode 'ExecutionDeclined' -Environment $environment
    }
}

$pipeline=Invoke-TetraPipeline @args
$result=New-TetraProductionResult -Pipeline $pipeline -Mode $mode -Environment $environment

if($PassThru.IsPresent){return $result}
return $result.Report
