#Requires -Version 5.1
<#
.SYNOPSIS
    Tetra Optimizer - Device Identity
.DESCRIPTION
    Generates and persists a permanent, machine-level DeviceId.

    RESPONSIBILITY (single):
        Own the lifecycle of exactly one persistent identifier: generate
        it once, store it, and return the same value on every future call
        for the lifetime of this installation. Nothing else.

    WHY THIS IS A SEPARATE FILE FROM Config.ps1:
        Config.json is user-editable and subject to Reset-TetraConfig
        (factory reset). DeviceId must survive a factory reset - it
        identifies the machine, not a user preference - so it is stored
        in its own file that no other function in this project is allowed
        to overwrite except Get-TetraDeviceId itself on first run.

    STORAGE MODEL:
        Config/DeviceIdentity.json: { DeviceId, CreatedUtc }
        Created once. Read on every subsequent call (with in-memory caching
        for the current session).

    DEPENDENCIES:
        None.
.NOTES
    Module      : DeviceIdentity.ps1
    Layer       : Config
    Build Phase : Phase 1 - Foundation (foundational addition)
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Script:TetraDeviceIdCache = $null

# ============================================================
# FUNCTION: Get-TetraDeviceIdentityFilePath
# ============================================================
<#
.SYNOPSIS
    Returns the absolute path to the DeviceIdentity.json file.
.DESCRIPTION
    This file lives in <ProjectRoot>/Config/DeviceIdentity.ps1, so the
    identity file is resolved in the same folder.
.OUTPUTS
    System.String
#>
function Get-TetraDeviceIdentityFilePath {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    return (Join-Path -Path $PSScriptRoot -ChildPath 'DeviceIdentity.json')
}

# ============================================================
# FUNCTION: Get-TetraDeviceId
# ============================================================
<#
.SYNOPSIS
    Returns this machine's permanent DeviceId, generating and persisting
    one on first call if it does not already exist.
.PARAMETER Refresh
    Forces a re-read from disk instead of returning the in-memory cache
    (does NOT regenerate the Id - it is permanent by design).
.OUTPUTS
    System.String - a GUID.
#>
function Get-TetraDeviceId {
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([string])]
    param(
        [switch]$Refresh
    )

    try {
        if (-not $Refresh -and $null -ne $Script:TetraDeviceIdCache) {
            return $Script:TetraDeviceIdCache
        }

        $identityPath = Get-TetraDeviceIdentityFilePath

        if (Test-Path -LiteralPath $identityPath) {
            $raw    = Get-Content -LiteralPath $identityPath -Raw -Encoding UTF8
            $parsed = $raw | ConvertFrom-Json

            if (($parsed.PSObject.Properties.Name -contains 'DeviceId') -and -not [string]::IsNullOrWhiteSpace($parsed.DeviceId)) {
                $Script:TetraDeviceIdCache = $parsed.DeviceId
                return $Script:TetraDeviceIdCache
            }
        }

        # No valid identity file yet - generate and persist a new permanent DeviceId.
        $newDeviceId    = [guid]::NewGuid().ToString()
        $identityObject = [PSCustomObject]@{
            DeviceId   = $newDeviceId
            CreatedUtc = (Get-Date).ToUniversalTime().ToString('o')
        }

        if ($PSCmdlet.ShouldProcess($identityPath, 'Create permanent device identity')) {
            $identityObject | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $identityPath -Encoding UTF8
        }

        $Script:TetraDeviceIdCache = $newDeviceId
        return $Script:TetraDeviceIdCache
    }
    catch {
        throw "Get-TetraDeviceId: Failed to resolve device identity - $($_.Exception.Message)"
    }
}

# ============================================================
# MODULE API SURFACE
# ============================================================
# NOTE: documented convention, not an enforced boundary (see
# PathHelpers.ps1 for the full explanation).
#
# Public Functions:
#   - Get-TetraDeviceId
#   - Get-TetraDeviceIdentityFilePath  (used by Tests for on-disk
#     verification; kept public rather than internal since a
#     legitimate external consumer already exists)
#
# Internal Functions:
#   (none)
