#Requires -Version 5.1
<#
.SYNOPSIS
    Tetra Optimizer - Path Helpers
.DESCRIPTION
    Shared, generic filesystem path/directory utility functions used
    across Config and Engine modules to eliminate duplicated
    "resolve sibling folder of my own script root" and "create directory
    if missing" logic.

    RESPONSIBILITY (single):
        Generic path resolution and directory creation helpers. Nothing
        project-specific, nothing business-logic related.

    WHY $PSScriptRoot CANNOT BE READ DIRECTLY INSIDE THIS FILE'S FUNCTIONS:
        $PSScriptRoot is bound to the file a function is LEXICALLY DEFINED
        in, not the file that calls it. A shared helper defined here would
        always resolve to PathHelpers.ps1's own folder if it read
        $PSScriptRoot internally - not the caller's folder. Every function
        here that needs a caller's script root therefore accepts it as an
        explicit parameter instead.

    DEPENDENCIES:
        None.
.NOTES
    Module      : PathHelpers.ps1
    Layer       : Config
    Build Phase : Foundation Validation (added during stabilization pass)
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ============================================================
# FUNCTION: Get-TetraSiblingDirectory
# ============================================================
<#
.SYNOPSIS
    Resolves a named folder that is a sibling of the project root, given
    the caller's own $PSScriptRoot.
.DESCRIPTION
    Every top-level project folder (Config, Engine, Logs, Reports, Backup,
    Data, ...) sits directly under the same project root. Each module
    file lives exactly one level below that root (e.g. Engine/LoggerEngine.ps1),
    so "project root" is always the caller's own script folder's parent.
.PARAMETER CallerScriptRoot
    Pass the caller's own $PSScriptRoot automatic variable.
.PARAMETER FolderName
    Name of the sibling folder to resolve, e.g. "Logs", "Reports".
.OUTPUTS
    System.String
.EXAMPLE
    Get-TetraSiblingDirectory -CallerScriptRoot $PSScriptRoot -FolderName 'Logs'
#>
function Get-TetraSiblingDirectory {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$CallerScriptRoot,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$FolderName
    )

    $projectRoot = Split-Path -Path $CallerScriptRoot -Parent
    return (Join-Path -Path $projectRoot -ChildPath $FolderName)
}

# ============================================================
# FUNCTION: Initialize-TetraDirectory
# ============================================================
<#
.SYNOPSIS
    Ensures a directory exists on disk, creating it if missing.
.DESCRIPTION
    Idempotent, ShouldProcess-aware. Shared by every module that owns a
    top-level project folder (Config, Logs, Reports, and - once built -
    Backup and its subfolders).
.PARAMETER Path
    The directory path to ensure exists.
.OUTPUTS
    System.String - the same Path, guaranteed to exist (unless -WhatIf was used).
.EXAMPLE
    Initialize-TetraDirectory -Path 'C:\Tetra\Logs'
#>
function Initialize-TetraDirectory {
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    try {
        if (-not (Test-Path -LiteralPath $Path)) {
            if ($PSCmdlet.ShouldProcess($Path, 'Create directory')) {
                New-Item -Path $Path -ItemType Directory -Force | Out-Null
            }
        }

        return $Path
    }
    catch {
        throw "Initialize-TetraDirectory: Failed to create '$Path' - $($_.Exception.Message)"
    }
}

# ============================================================
# MODULE API SURFACE
# ============================================================
# NOTE: Plain dot-sourced .ps1 files have no real access-control
# mechanism in PowerShell - everything dot-sourced becomes globally
# available regardless of intent. This section is a DOCUMENTED
# CONVENTION for other developers and future modules, not an enforced
# boundary.
#
# Public Functions (intended for use by other modules):
#   - Get-TetraSiblingDirectory
#   - Initialize-TetraDirectory
#
# Internal Functions:
#   (none - both functions in this file are generic utilities meant
#    for cross-module reuse)
