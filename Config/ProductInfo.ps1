#Requires -Version 5.1
<#
.SYNOPSIS
    Tetra Optimizer - Product Info
.DESCRIPTION
    Centralized, single-source-of-truth product identity constants:
    ProductName, CompanyName, Tagline, Version, BuildNumber, ReleaseChannel.

    RESPONSIBILITY (single):
        Expose build-time product identity. Nothing else. This is NOT
        user-editable configuration (that's Config/Config.ps1) - it is
        fixed identity metadata that changes only when Tetra itself is
        rebuilt/released.

    WHY THIS EXISTS SEPARATELY FROM Config.ps1:
        Config.ps1 governs user-editable runtime settings and is subject
        to Reset-TetraConfig (factory reset). Product identity must never
        be reset, never vary per user, and must be trivially updatable in
        exactly one place when a new version ships. Hence its own file.

    DEPENDENCIES:
        None.
.NOTES
    Module      : ProductInfo.ps1
    Layer       : Config
    Build Phase : Phase 1 - Foundation (foundational addition)
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ============================================================
# PRODUCT IDENTITY CONSTANTS - single source of truth.
# Update these values here, and only here, on every release.
# ============================================================
$Script:TetraProductName    = 'Tetra Optimizer'
$Script:TetraCompanyName    = 'Tetra Studio'
$Script:TetraTagline        = 'Enterprise-Grade Windows Optimization Suite'
$Script:TetraVersionNumber  = '1.0.0'
$Script:TetraBuildNumber    = '1'
$Script:TetraReleaseChannel = 'Stable'

# ============================================================
# FUNCTION: Get-TetraProductInfo
# ============================================================
<#
.SYNOPSIS
    Returns the complete product identity object.
.OUTPUTS
    System.Management.Automation.PSCustomObject:
        ProductName, CompanyName, Tagline, Version, BuildNumber,
        ReleaseChannel, VersionDisplay
#>
function Get-TetraProductInfo {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param()

    return [PSCustomObject]@{
        ProductName    = $Script:TetraProductName
        CompanyName    = $Script:TetraCompanyName
        Tagline        = $Script:TetraTagline
        Version        = $Script:TetraVersionNumber
        BuildNumber    = $Script:TetraBuildNumber
        ReleaseChannel = $Script:TetraReleaseChannel
        VersionDisplay = "$($Script:TetraVersionNumber) (Build $($Script:TetraBuildNumber), $($Script:TetraReleaseChannel))"
    }
}

# ============================================================
# FUNCTION: Get-TetraVersionDisplayString
# ============================================================
<#
.SYNOPSIS
    Returns a single-line, human-readable version summary string.
.DESCRIPTION
    Convenience helper reused by ReportEngine's footer and, later, Core's
    "About" screen, so the exact same formatting is never duplicated.
.OUTPUTS
    System.String, e.g. "Version: 1.0.0 | Build: 1 | Channel: Stable"
#>
function Get-TetraVersionDisplayString {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $info = Get-TetraProductInfo
    return "Version: $($info.Version) | Build: $($info.BuildNumber) | Channel: $($info.ReleaseChannel)"
}

# ============================================================
# MODULE API SURFACE
# ============================================================
# NOTE: documented convention, not an enforced boundary (see
# PathHelpers.ps1 for the full explanation).
#
# Public Functions:
#   - Get-TetraProductInfo
#   - Get-TetraVersionDisplayString
#
# Internal Functions:
#   (none)
#
# KNOWN ISSUE (flagged, not fixed - does not meet the 3-occurrence
# duplication threshold under the Architecture Freeze Policy):
#   Get-TetraVersionDisplayString currently has zero callers anywhere
#   in the codebase. ReportEngine's HTML/TXT footers build an
#   equivalent "Version: X | Build: Y | Channel: Z" string inline
#   rather than calling this function. This is 2 independent
#   locations with overlapping logic (the unused function + the
#   inline footer strings), below the 3-location bar this project
#   now requires before acting. Left as-is; revisit if a third
#   consumer needing this exact format appears.
