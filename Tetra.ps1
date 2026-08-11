#Requires -Version 5.1
<#
.SYNOPSIS
    Tetra Optimizer - Enterprise-Grade Windows Optimization Suite
.DESCRIPTION
    Main entry point for Tetra Optimizer.

    ARCHITECTURE NOTE (Bootstrap Phase):
    This is the initial bootstrap version of Tetra.ps1. At this stage in the
    build, its ONLY responsibilities are:
        1. Validate the execution environment (Admin rights, PS version, OS).
        2. Scaffold the on-disk project folder structure if missing.
        3. Prepare the ground for Config/Logger/Engine modules to be loaded
           in later build steps.

    This file will be progressively expanded (in later steps) to:
        - Import Config
        - Initialize Logger
        - Dot-source all Engine modules
        - Dot-source all Core modules
        - Launch the Main Menu (Core/UI.ps1)

    No business logic, no system-modifying logic, and no UI menu logic
    exists in this file. That separation is intentional and permanent -
    Tetra.ps1 must always remain a thin orchestrator/entry point.
.NOTES
    Module      : Tetra.ps1 (Root Entry Point)
    Layer       : Bootstrap
    Author      : Tetra Optimizer Project
    Build Step  : 1 of N
#>

[CmdletBinding()]
param(
    # Allows launching in non-interactive/CI validation mode (used later for automated scaffold checks)
    [switch]$ValidateOnly
)

# ============================================================
# 1. STRICT MODE & GLOBAL EXECUTION SETTINGS
# ============================================================
# Strict mode catches uninitialized variables, invalid property/method
# references, and other silent-failure patterns early. Mandatory across
# the whole suite per project coding rules.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ============================================================
# 2. ROOT PATH RESOLUTION
# ============================================================
# All later modules resolve their paths relative to this root, so it is
# established once, here, at the very top of the call chain.
$Script:TetraRoot = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($Script:TetraRoot)) {
    # Fallback for edge cases (e.g. script invoked via iex/piped execution)
    $Script:TetraRoot = (Get-Location).Path
}

# ============================================================
# 3. FUNCTION: Test-TetraAdminRights
# ============================================================
<#
.SYNOPSIS
    Determines whether the current PowerShell session is running with
    Administrator privileges.
.DESCRIPTION
    Tetra Optimizer requires elevation because most Engine-layer modules
    (Registry, Services, Drivers, Network, Power) interact with system-level
    Windows components that are inaccessible to standard users.
.OUTPUTS
    System.Boolean
#>
function Test-TetraAdminRights {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    try {
        $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch {
        Write-Verbose "Test-TetraAdminRights: Failed to resolve identity - $($_.Exception.Message)"
        return $false
    }
}

# ============================================================
# 4. FUNCTION: Test-TetraEnvironment
# ============================================================
<#
.SYNOPSIS
    Validates that the host environment meets Tetra Optimizer's minimum
    requirements before any module is loaded.
.DESCRIPTION
    Checks:
        - Operating System is Windows
        - PowerShell major version >= 5
        - Administrator privileges are present
.OUTPUTS
    PSCustomObject with per-check boolean results and an overall IsValid flag.
#>
function Test-TetraEnvironment {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param()

    $isWindowsOS = $true
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        # $IsWindows only exists on PS Core (6+); Windows PowerShell 5.1 is always Windows.
        $isWindowsOS = $IsWindows
    }

    $psVersionOk = $PSVersionTable.PSVersion.Major -ge 5
    $adminOk     = Test-TetraAdminRights

    $result = [PSCustomObject]@{
        IsWindows        = $isWindowsOS
        PSVersionOk      = $psVersionOk
        PSVersionDetected = $PSVersionTable.PSVersion.ToString()
        IsAdmin          = $adminOk
        IsValid          = ($isWindowsOS -and $psVersionOk -and $adminOk)
    }

    return $result
}

# ============================================================
# 5. FUNCTION: Initialize-TetraFolderStructure
# ============================================================
<#
.SYNOPSIS
    Creates the complete Tetra Optimizer folder structure if it does not
    already exist.
.DESCRIPTION
    This is idempotent - safe to run every launch. It never deletes or
    overwrites existing folders/files; it only creates what is missing.

    Folder responsibilities (populated in later build steps):
        Assets/    - Icons, logo, UI images, fonts, animations, themes
        Backup/    - Registry/Service/Startup/Power/Driver/Network backups
        Config/    - Global configuration files
        Core/      - UI/workflow layer (menus, formatting, user interaction)
        Engine/    - Low-level system functions (no UI, no menus)
        Data/      - JSON knowledge bases (not code)
        Reports/   - Generated TXT/HTML/JSON/PDF reports
        Logs/      - Structured operation logs
        Modules/   - Reserved for future distributable module packaging
.PARAMETER RootPath
    The root directory under which the structure will be created.
.OUTPUTS
    PSCustomObject describing which folders were created vs. already existed.
#>
function Initialize-TetraFolderStructure {
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$RootPath
    )

    $requiredFolders = @(
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

    $created  = [System.Collections.Generic.List[string]]::new()
    $existing = [System.Collections.Generic.List[string]]::new()

    foreach ($folder in $requiredFolders) {
        $fullPath = Join-Path -Path $RootPath -ChildPath $folder

        if (Test-Path -LiteralPath $fullPath) {
            $existing.Add($fullPath)
            continue
        }

        if ($PSCmdlet.ShouldProcess($fullPath, 'Create directory')) {
            try {
                New-Item -Path $fullPath -ItemType Directory -Force | Out-Null
                $created.Add($fullPath)
            }
            catch {
                Write-Error "Initialize-TetraFolderStructure: Failed to create '$fullPath' - $($_.Exception.Message)"
            }
        }
    }

    return [PSCustomObject]@{
        RootPath        = $RootPath
        CreatedFolders  = $created
        ExistingFolders = $existing
        TotalRequired   = $requiredFolders.Count
    }
}

# ============================================================
# 6. FUNCTION: Show-TetraBootstrapBanner
# ============================================================
<#
.SYNOPSIS
    Displays the Tetra Optimizer startup banner and environment summary.
.DESCRIPTION
    Presentation-only. Contains no logic decisions - purely reflects the
    values already computed by Test-TetraEnvironment and
    Initialize-TetraFolderStructure. Kept here (not in Core/UI.ps1 yet)
    because Core has not been built as of this build step; this banner
    will be relocated into Core/UI.ps1 once that layer exists.
.PARAMETER EnvironmentInfo
    The object returned by Test-TetraEnvironment.
.PARAMETER FolderInfo
    The object returned by Initialize-TetraFolderStructure.
#>
function Show-TetraBootstrapBanner {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$EnvironmentInfo,

        [Parameter(Mandatory = $true)]
        [PSCustomObject]$FolderInfo
    )

    Write-Host ''
    Write-Host '========================================================' -ForegroundColor Cyan
    Write-Host '                 TETRA OPTIMIZER (Bootstrap)            ' -ForegroundColor Cyan
    Write-Host '     Enterprise-Grade Windows Optimization Suite        ' -ForegroundColor Cyan
    Write-Host '========================================================' -ForegroundColor Cyan
    Write-Host ''

    Write-Host 'Environment Check:' -ForegroundColor Yellow
    Write-Host ("  Windows OS       : {0}" -f $(if ($EnvironmentInfo.IsWindows) { 'OK' } else { 'FAIL' })) -ForegroundColor $(if ($EnvironmentInfo.IsWindows) { 'Green' } else { 'Red' })
    Write-Host ("  PowerShell {0,-6} : {1}" -f $EnvironmentInfo.PSVersionDetected, $(if ($EnvironmentInfo.PSVersionOk) { 'OK' } else { 'FAIL' })) -ForegroundColor $(if ($EnvironmentInfo.PSVersionOk) { 'Green' } else { 'Red' })
    Write-Host ("  Administrator    : {0}" -f $(if ($EnvironmentInfo.IsAdmin) { 'OK' } else { 'FAIL - Restart as Admin' })) -ForegroundColor $(if ($EnvironmentInfo.IsAdmin) { 'Green' } else { 'Red' })
    Write-Host ''

    Write-Host 'Folder Structure:' -ForegroundColor Yellow
    Write-Host ("  Required Folders : {0}" -f $FolderInfo.TotalRequired)
    Write-Host ("  Already Existed  : {0}" -f $FolderInfo.ExistingFolders.Count)
    Write-Host ("  Newly Created    : {0}" -f $FolderInfo.CreatedFolders.Count) -ForegroundColor $(if ($FolderInfo.CreatedFolders.Count -gt 0) { 'Green' } else { 'Gray' })

    if ($FolderInfo.CreatedFolders.Count -gt 0) {
        foreach ($f in $FolderInfo.CreatedFolders) {
            Write-Host ("    + {0}" -f $f) -ForegroundColor DarkGreen
        }
    }
    Write-Host ''
}

# ============================================================
# 7. MAIN BOOTSTRAP FLOW
# ============================================================
try {
    $envInfo    = Test-TetraEnvironment
    $folderInfo = Initialize-TetraFolderStructure -RootPath $Script:TetraRoot

    Show-TetraBootstrapBanner -EnvironmentInfo $envInfo -FolderInfo $folderInfo

    if (-not $envInfo.IsValid) {
        Write-Host 'Bootstrap validation FAILED. Resolve the issues above before continuing.' -ForegroundColor Red

        if (-not $ValidateOnly) {
            # Non-zero exit so calling shells/scripts can detect failure programmatically.
            exit 1
        }
    }
    else {
        Write-Host 'Bootstrap validation PASSED.' -ForegroundColor Green

        if ($ValidateOnly) {
            Write-Host '(-ValidateOnly specified: stopping after validation, no further modules loaded.)' -ForegroundColor Gray
        }
        else {
            Write-Host ''
            Write-Host 'NOTE: Config, Logger, Engine, and Core modules are not yet implemented.' -ForegroundColor DarkYellow
            Write-Host 'This build step only covers environment validation + folder scaffolding.' -ForegroundColor DarkYellow
            Write-Host 'Next build step will introduce Config/Config.ps1.' -ForegroundColor DarkYellow
        }
    }
}
catch {
    Write-Error "Tetra Optimizer bootstrap failed: $($_.Exception.Message)"
    exit 1
}
