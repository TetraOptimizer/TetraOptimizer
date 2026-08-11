#Requires -Version 5.1
<#
.SYNOPSIS
    Tetra Optimizer - Bootstrap Loader
.DESCRIPTION
    The single, authoritative entry point for loading Tetra Optimizer's
    foundation. No other file, and no human, should ever need to manually
    dot-source Config/Engine files in the correct order - this file is
    that order, enforced and validated.

    RESPONSIBILITY (single):
        Load every foundation module in dependency-safe order; validate
        the environment (PowerShell version, OS), the load manifest
        itself (no circular/out-of-order dependencies), and the required
        folder structure; then perform one-time post-load initialization
        (configuration, log/report directories, log retention cleanup,
        cache warm-up). Nothing else - this file contains no business
        logic of its own.

    CRITICAL POWERSHELL SCOPING NOTE:
        Dot-sourcing (". $path") performed INSIDE A FUNCTION confines the
        loaded functions to that function's local scope - they vanish once
        the function returns, and would be invisible to whatever dot-sourced
        this bootstrap file. For that reason, the actual module-loading
        loop below executes at THIS FILE'S OWN TOP-LEVEL SCOPE, not inside
        a function. try/catch blocks do not introduce a new scope in
        PowerShell, so wrapping each dot-source in try/catch for error
        reporting is safe and does not break this propagation.

        Practical implication: this file must itself be dot-sourced by its
        caller (". .\Bootstrap\Initialize-Tetra.ps1"), never invoked as
        ".\Bootstrap\Initialize-Tetra.ps1" (which would run it as a child
        script and discard everything it loaded when it returns).

    LOAD MANIFEST (dependency-ordered):
        1. Config/PathHelpers.ps1    - no dependencies
        2. Config/ProductInfo.ps1    - no dependencies
        3. Config/DeviceIdentity.ps1 - no dependencies
        4. Config/Config.ps1         - depends on: PathHelpers
        5. Engine/LoggerEngine.ps1   - depends on: Config, ProductInfo, DeviceIdentity
        6. Engine/ReportEngine.ps1   - depends on: Config, LoggerEngine, ProductInfo,
                                        PathHelpers
        This order is validated programmatically at bootstrap time by
        Test-TetraLoadManifestOrder (see below) - it is not just a comment
        that can silently go stale.

    POST-LOAD INITIALIZATION SEQUENCE:
        1. Validate PowerShell version / OS (Test-TetraBootstrapPrerequisites)
        2. Validate load manifest ordering (Test-TetraLoadManifestOrder)
        3. Create required top-level project folders
        4. Dot-source each module in manifest order
        5. Initialize configuration (Initialize-TetraConfig)
        6. Initialize Logs/Reports directories
        7. Run log retention cleanup (Remove-TetraExpiredLogs)
        8. Warm the session + system metadata caches (avoids paying the
           CIM-query cost on whatever the first real operation happens to be)

    WHAT THIS FILE DELIBERATELY DOES NOT DO:
        - Check for Administrator privileges. That is an application-level
          concern (Tetra.ps1's responsibility once rebuilt in Phase 5),
          not a module-loading concern - loading functions into memory
          does not require elevation, only some of the operations those
          functions later perform do.
        - Launch any UI. Bootstrap prepares the environment; Core/UI.ps1
          (Phase 4) is responsible for anything user-facing.

    DEPENDENCIES:
        None of its own - by design, Bootstrap must be loadable with zero
        prerequisites, since it IS the thing that loads everything else.
.NOTES
    Module      : Initialize-Tetra.ps1
    Layer       : Bootstrap
    Build Phase : Foundation Validation
#>

[CmdletBinding()]
param(
    # Skips Initialize-TetraConfig during post-load initialization. Useful
    # for tooling (e.g. smoke tests) that wants full control over when
    # configuration is first touched.
    [switch]$SkipConfigInitialization,

    # Skips Remove-TetraExpiredLogs during post-load initialization.
    [switch]$SkipLogRetentionCleanup
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Script:TetraBootstrapDir = $PSScriptRoot
$Script:TetraProjectRoot  = Split-Path -Path $Script:TetraBootstrapDir -Parent

# ============================================================
# FUNCTION: Get-TetraLoadManifest
# ============================================================
<#
.SYNOPSIS
    Returns the ordered list of foundation modules to load, along with
    their declared dependencies.
.DESCRIPTION
    This is the single source of truth for load order. Adding a new
    foundation module means adding one entry here - Test-TetraLoadManifestOrder
    will immediately catch it if its DependsOn references something not
    already present earlier in the list.
.OUTPUTS
    System.Management.Automation.PSCustomObject[]: Name, RelativePath, DependsOn
#>
function Get-TetraLoadManifest {
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param()

    return @(
        [PSCustomObject]@{ Name = 'PathHelpers';    RelativePath = 'Config\PathHelpers.ps1';    DependsOn = @() }
        [PSCustomObject]@{ Name = 'ProductInfo';    RelativePath = 'Config\ProductInfo.ps1';    DependsOn = @() }
        [PSCustomObject]@{ Name = 'DeviceIdentity'; RelativePath = 'Config\DeviceIdentity.ps1'; DependsOn = @() }
        [PSCustomObject]@{ Name = 'Config';         RelativePath = 'Config\Config.ps1';         DependsOn = @('PathHelpers') }
        [PSCustomObject]@{ Name = 'LoggerEngine';   RelativePath = 'Engine\LoggerEngine.ps1';   DependsOn = @('Config', 'ProductInfo', 'DeviceIdentity') }
        [PSCustomObject]@{ Name = 'ReportEngine';   RelativePath = 'Engine\ReportEngine.ps1';   DependsOn = @('Config', 'LoggerEngine', 'ProductInfo', 'PathHelpers') }
        [PSCustomObject]@{ Name = 'BackupEngine';   RelativePath = 'Engine\BackupEngine.ps1';   DependsOn = @('Config', 'LoggerEngine', 'ProductInfo', 'PathHelpers') }
        [PSCustomObject]@{ Name = 'Orchestrator';   RelativePath = 'Core\Orchestrator.ps1';     DependsOn = @('Config', 'LoggerEngine', 'BackupEngine', 'ReportEngine') }
        [PSCustomObject]@{ Name = 'KnowledgeBaseEngine'; RelativePath = 'Engine\KnowledgeBaseEngine.ps1'; DependsOn = @('PathHelpers', 'LoggerEngine') }
        [PSCustomObject]@{ Name = 'AnalyzerEngine'; RelativePath = 'Engine\AnalyzerEngine.ps1'; DependsOn = @('KnowledgeBaseEngine', 'LoggerEngine', 'ReportEngine') }
    )
}

# ============================================================
# FUNCTION: Test-TetraLoadManifestOrder
# ============================================================
<#
.SYNOPSIS
    Validates that a load manifest is correctly ordered: no entry may
    depend on a module that has not already appeared earlier in the list.
.DESCRIPTION
    This single check simultaneously serves two purposes:
        1. Ordering validation - catches "module B added above module A,
           but B depends on A" mistakes.
        2. Circular-dependency detection - a true cycle (A depends on B,
           B depends on A) can never satisfy this check no matter how the
           manifest is ordered, so it is caught here rather than
           discovered later as a runtime "command not found" error deep
           inside some Engine module.
.PARAMETER Manifest
    The manifest array to validate (see Get-TetraLoadManifest).
.OUTPUTS
    System.Management.Automation.PSCustomObject: IsValid, Violations
#>
function Test-TetraLoadManifestOrder {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject[]]$Manifest
    )

    $seenNames  = [System.Collections.Generic.List[string]]::new()
    $violations = [System.Collections.Generic.List[string]]::new()

    foreach ($entry in $Manifest) {
        foreach ($dependency in $entry.DependsOn) {
            if ($seenNames -notcontains $dependency) {
                $violations.Add("Module '$($entry.Name)' depends on '$dependency', which has not been loaded yet (or does not exist in the manifest).")
            }
        }
        $seenNames.Add($entry.Name)
    }

    return [PSCustomObject]@{
        IsValid    = ($violations.Count -eq 0)
        Violations = $violations
    }
}

# ============================================================
# FUNCTION: Test-TetraBootstrapPrerequisites
# ============================================================
<#
.SYNOPSIS
    Validates that the current PowerShell session meets Tetra's minimum
    environment requirements before any module is loaded.
.DESCRIPTION
    Checks PowerShell major version (>= 5) and that the host OS is Windows.
    Administrator-rights checking is deliberately NOT included here (see
    file-level header note) - that is an application-launch concern, not
    a module-loading concern.
.OUTPUTS
    System.Management.Automation.PSCustomObject: PSVersionOk, PSVersionDetected,
    IsWindows, IsValid
#>
function Test-TetraBootstrapPrerequisites {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param()

    $psVersionOk = $PSVersionTable.PSVersion.Major -ge 5

    $isWindowsOs = $true
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        # $IsWindows only exists on PowerShell Core (6+); Windows PowerShell
        # 5.1 always runs on Windows.
        $isWindowsOs = $IsWindows
    }

    return [PSCustomObject]@{
        PSVersionOk       = $psVersionOk
        PSVersionDetected = $PSVersionTable.PSVersion.ToString()
        IsWindows         = $isWindowsOs
        IsValid           = ($psVersionOk -and $isWindowsOs)
    }
}

# ============================================================
# FUNCTION: Get-TetraRequiredFolders
# ============================================================
<#
.SYNOPSIS
    Returns the complete set of top-level project folders Tetra Optimizer
    requires, relative to the project root.
.OUTPUTS
    System.String[]
#>
function Get-TetraRequiredFolders {
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    return @(
        'Assets',
        'Backup',
        'Backup\Registry',
        'Backup\Services',
        'Backup\Startup',
        'Backup\PowerPlans',
        'Backup\Drivers',
        'Backup\Network',
        'Config',
        'Core',
        'Engine',
        'Data',
        'Reports',
        'Logs',
        'Modules'
    )
}

# ============================================================
# FUNCTION: Get-TetraBootstrapResult
# ============================================================
<#
.SYNOPSIS
    Returns the result object from the most recent bootstrap run.
.DESCRIPTION
    Available after this file has been dot-sourced. Callers (Tetra.ps1,
    smoke tests, diagnostics) use this to confirm bootstrap succeeded
    before proceeding, and to inspect exactly what loaded/failed.
.OUTPUTS
    System.Management.Automation.PSCustomObject
#>
function Get-TetraBootstrapResult {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param()

    return $Script:TetraBootstrapResult
}

# ============================================================
# BOOTSTRAP EXECUTION (top-level scope - see CRITICAL POWERSHELL
# SCOPING NOTE at the top of this file)
# ============================================================

$Script:TetraBootstrapResult = [PSCustomObject]@{
    StartedUtc        = (Get-Date).ToUniversalTime().ToString('o')
    PrerequisiteCheck = $null
    ManifestCheck     = $null
    LoadedModules     = [System.Collections.Generic.List[string]]::new()
    FailedModules     = [System.Collections.Generic.List[PSCustomObject]]::new()
    CreatedFolders    = [System.Collections.Generic.List[string]]::new()
    Success           = $false
    CompletedUtc      = $null
}

# ---- Step 1: Environment prerequisites ----
$Script:TetraBootstrapResult.PrerequisiteCheck = Test-TetraBootstrapPrerequisites

if (-not $Script:TetraBootstrapResult.PrerequisiteCheck.IsValid) {
    $Script:TetraBootstrapResult.CompletedUtc = (Get-Date).ToUniversalTime().ToString('o')
    throw "Initialize-Tetra: Bootstrap prerequisites not met (PowerShell $($Script:TetraBootstrapResult.PrerequisiteCheck.PSVersionDetected), IsWindows=$($Script:TetraBootstrapResult.PrerequisiteCheck.IsWindows))."
}

# ---- Step 2: Load manifest ordering / circular-dependency validation ----
$Script:TetraLoadManifest = Get-TetraLoadManifest
$Script:TetraBootstrapResult.ManifestCheck = Test-TetraLoadManifestOrder -Manifest $Script:TetraLoadManifest

if (-not $Script:TetraBootstrapResult.ManifestCheck.IsValid) {
    $Script:TetraBootstrapResult.CompletedUtc = (Get-Date).ToUniversalTime().ToString('o')
    throw "Initialize-Tetra: Load manifest has unmet dependency ordering: $($Script:TetraBootstrapResult.ManifestCheck.Violations -join ' | ')"
}

# ---- Step 3: Required folder scaffold ----
foreach ($folder in (Get-TetraRequiredFolders)) {
    $fullFolderPath = Join-Path -Path $Script:TetraProjectRoot -ChildPath $folder

    if (-not (Test-Path -LiteralPath $fullFolderPath)) {
        New-Item -Path $fullFolderPath -ItemType Directory -Force | Out-Null
        $Script:TetraBootstrapResult.CreatedFolders.Add($fullFolderPath)
    }
}

# ---- Step 4: Load each module, in manifest order, at THIS TOP-LEVEL SCOPE ----
foreach ($moduleEntry in $Script:TetraLoadManifest) {
    $fullModulePath = Join-Path -Path $Script:TetraProjectRoot -ChildPath $moduleEntry.RelativePath

    if (-not (Test-Path -LiteralPath $fullModulePath)) {
        $Script:TetraBootstrapResult.FailedModules.Add([PSCustomObject]@{
            Name  = $moduleEntry.Name
            Path  = $fullModulePath
            Error = 'File not found.'
        })
        continue
    }

    try {
        . $fullModulePath
        $Script:TetraBootstrapResult.LoadedModules.Add($moduleEntry.Name)
    }
    catch {
        $Script:TetraBootstrapResult.FailedModules.Add([PSCustomObject]@{
            Name  = $moduleEntry.Name
            Path  = $fullModulePath
            Error = $_.Exception.Message
        })
    }
}

$Script:TetraAllModulesLoaded = ($Script:TetraBootstrapResult.FailedModules.Count -eq 0)

# ---- Step 5-8: Post-load initialization (only if every module loaded) ----
if ($Script:TetraAllModulesLoaded) {

    if (-not $SkipConfigInitialization) {
        try {
            Initialize-TetraConfig | Out-Null
        }
        catch {
            $Script:TetraBootstrapResult.FailedModules.Add([PSCustomObject]@{
                Name  = 'Configuration'
                Path  = $null
                Error = $_.Exception.Message
            })
        }
    }

    try {
        Initialize-TetraLogDirectory | Out-Null
        Initialize-TetraReportsDirectory | Out-Null
    }
    catch {
        $Script:TetraBootstrapResult.FailedModules.Add([PSCustomObject]@{
            Name  = 'DirectoryInitialization'
            Path  = $null
            Error = $_.Exception.Message
        })
    }

    if (-not $SkipLogRetentionCleanup) {
        try {
            Remove-TetraExpiredLogs | Out-Null
        }
        catch {
            # Retention cleanup failing is not fatal to bootstrap - logging
            # can still function even if old-file cleanup did not run.
            Write-Verbose "Initialize-Tetra: Log retention cleanup failed - $($_.Exception.Message)"
        }
    }

    try {
        # Warm the session + system metadata caches once, now, rather than
        # paying the CIM-query cost on whatever the first real log call
        # happens to be.
        Get-TetraSessionId | Out-Null
        Get-TetraSystemMetadata | Out-Null
    }
    catch {
        Write-Verbose "Initialize-Tetra: Cache warm-up failed - $($_.Exception.Message)"
    }
}

$Script:TetraBootstrapResult.CompletedUtc = (Get-Date).ToUniversalTime().ToString('o')
$Script:TetraBootstrapResult.Success      = ($Script:TetraBootstrapResult.FailedModules.Count -eq 0)

# ============================================================
# MODULE API SURFACE
# ============================================================
# NOTE: documented convention, not an enforced boundary (see
# Config/PathHelpers.ps1 for the full explanation).
#
# Public Functions:
#   - Get-TetraLoadManifest       (used by Tests)
#   - Test-TetraLoadManifestOrder (used by Tests)
#   - Get-TetraBootstrapResult    (used by Tests; the standard way any
#     caller confirms bootstrap succeeded before proceeding)
#
# Internal Functions:
#   - Test-TetraBootstrapPrerequisites (only used within this file's
#     own top-level execution flow)
#   - Get-TetraRequiredFolders          (same)
