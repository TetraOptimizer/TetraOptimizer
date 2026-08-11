#Requires -Version 5.1
<#
.SYNOPSIS
    Tetra Optimizer - Configuration Layer
.DESCRIPTION
    Centralized, self-healing configuration management for Tetra Optimizer.

    RESPONSIBILITY (single):
        Own the schema, persistence, retrieval, and mutation of Tetra's
        global configuration. Nothing else.

    THIS FILE MUST NEVER:
        - Write to the console (no Write-Host). Config is not UI.
        - Access Windows system state (no Get-Process/Get-Service/registry/CIM/WMI).
        - Contain optimization/business logic. It only stores/returns settings
          that OTHER modules use to decide their own behavior.

    PERSISTENCE MODEL:
        Config/Config.json        - Live, user-editable configuration.
                                     Created once from defaults; never silently
                                     overwritten afterward (only via explicit
                                     Save-TetraConfig / Set-TetraConfigValue /
                                     Reset-TetraConfig calls).
        Config/DefaultConfig.json - Reference copy of the in-code defaults.
                                     Regenerated every Initialize-TetraConfig
                                     call. Safe to overwrite - it is never the
                                     live configuration, only a reset/diff
                                     reference.

    DEPENDENCIES:
        Config/PathHelpers.ps1 (added during Foundation Validation - provides
        Initialize-TetraDirectory, used instead of duplicating inline
        directory-creation logic). Otherwise, this remains the foundation
        every other module (Logger, ReportEngine, BackupEngine, and all
        later Engine/Core modules) reads settings from.
.NOTES
    Module      : Config.ps1
    Layer       : Config
    Build Phase : Phase 1 - Foundation
    Build Step  : 1 of 32
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ============================================================
# MODULE-SCOPED STATE
# ============================================================

# Semantic version of the configuration schema itself. Bump this whenever
# a section/key is added or restructured, so future migration logic
# (added when actually needed) has something concrete to key off.
$Script:TetraConfigSchemaVersion = '1.0.0'

# In-memory cache of the loaded configuration. Avoids re-reading/re-parsing
# Config.json on every single Get-TetraConfigValue call. Invalidated
# explicitly via -Refresh or automatically replaced by Save-TetraConfig.
$Script:TetraConfigCache = $null

# ============================================================
# FUNCTION: Get-TetraConfigDirectory
# ============================================================
<#
.SYNOPSIS
    Returns the absolute path to the Config folder.
.DESCRIPTION
    Single source of truth for "where does Config live on disk". Every other
    path-resolution function in this file builds on top of this one, so the
    location is defined exactly once.
.OUTPUTS
    System.String
#>
function Get-TetraConfigDirectory {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    return $PSScriptRoot
}

# ============================================================
# FUNCTION: Get-TetraConfigFilePath
# ============================================================
<#
.SYNOPSIS
    Returns the absolute path to the live Config.json file.
.OUTPUTS
    System.String
#>
function Get-TetraConfigFilePath {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    return (Join-Path -Path (Get-TetraConfigDirectory) -ChildPath 'Config.json')
}

# ============================================================
# FUNCTION: Get-TetraDefaultConfigFilePath
# ============================================================
<#
.SYNOPSIS
    Returns the absolute path to the reference DefaultConfig.json file.
.OUTPUTS
    System.String
#>
function Get-TetraDefaultConfigFilePath {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    return (Join-Path -Path (Get-TetraConfigDirectory) -ChildPath 'DefaultConfig.json')
}

# ============================================================
# FUNCTION: ConvertTo-TetraPSCustomObject
# ============================================================
<#
.SYNOPSIS
    Recursively converts hashtables/ordered dictionaries (and any nested
    hashtables/arrays within them) into PSCustomObject graphs.
.DESCRIPTION
    PowerShell 5.1's ConvertFrom-Json always returns nested PSCustomObject
    graphs (there is no -AsHashtable parameter on PS 5.1). To keep the
    in-code default configuration structurally identical to whatever is
    loaded from disk - so downstream merge/compare logic never has to deal
    with two different object shapes - defaults are authored as ordered
    hashtables (readable) and converted through this function before use.

    This function is intentionally generic and reusable: any future module
    that needs to turn a hand-authored hashtable literal into a
    JSON-serializable PSCustomObject graph can reuse it instead of writing
    its own converter.
.PARAMETER InputObject
    The hashtable, ordered dictionary, array, or scalar to convert.
.OUTPUTS
    System.Management.Automation.PSCustomObject, an array, or a scalar,
    depending on the shape of the input.
#>
function ConvertTo-TetraPSCustomObject {
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object]$InputObject
    )

    if ($null -eq $InputObject) {
        return $null
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        $result = [PSCustomObject]@{}
        foreach ($key in $InputObject.Keys) {
            $convertedValue = ConvertTo-TetraPSCustomObject -InputObject $InputObject[$key]
            $result | Add-Member -NotePropertyName $key -NotePropertyValue $convertedValue -Force
        }
        return $result
    }
    elseif (($InputObject -is [System.Collections.IEnumerable]) -and (-not ($InputObject -is [string]))) {
        $convertedItems = @()
        foreach ($item in $InputObject) {
            $convertedItems += ,(ConvertTo-TetraPSCustomObject -InputObject $item)
        }
        return ,$convertedItems
    }
    else {
        return $InputObject
    }
}

# ============================================================
# FUNCTION: Get-TetraDefaultConfig
# ============================================================
<#
.SYNOPSIS
    Returns the complete, hard-coded default configuration graph.
.DESCRIPTION
    This is the single authoritative definition of every configuration key
    Tetra Optimizer recognizes, organized into sections:

        Metadata          - Schema version and timestamps.
        General            - Language, Theme, OptimizationLevel, SafeMode, ExpertMode.
        Logging            - LogLevel, LogRetentionDays, LogToConsole, LogToFile.
        Scan               - DeepScan, ScanTimeoutSeconds, IncludeSystemFiles.
        Gaming             - GameModePriority, NetworkOptimizationForGaming,
                              DisableBackgroundAppsDuringGaming.
        AIRecommendation   - Enabled, ConfidenceThreshold, MaxRecommendationsPerScan.
        Backup             - AutoBackupBeforeChanges, BackupRetentionCount.

    Every other function in this file treats this as read-only ground truth
    for (a) first-time config creation and (b) schema-gap healing.
.OUTPUTS
    System.Management.Automation.PSCustomObject
#>
function Get-TetraDefaultConfig {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param()

    $nowUtc = (Get-Date).ToUniversalTime().ToString('o')

    $defaults = [ordered]@{
        Metadata = [ordered]@{
            ConfigVersion   = $Script:TetraConfigSchemaVersion
            CreatedUtc      = $nowUtc
            LastModifiedUtc = $nowUtc
        }
        General = [ordered]@{
            # ISO 639-1 code. Core/UI.ps1 (built later) will read this to decide
            # which language strings to render.
            Language          = 'en'
            # Cosmetic only - consumed by Core/UI.ps1 once themes exist.
            Theme             = 'Dark'
            # One of: Conservative | Balanced | Aggressive. Analyzer/Engine
            # modules use this to decide how strongly to recommend changes.
            OptimizationLevel = 'Balanced'
            # When $true, Engine modules must refuse to execute any operation
            # tagged as high-risk without additional explicit confirmation.
            SafeMode          = $true
            # When $true, Core menus expose advanced/manual options that are
            # hidden from a first-time user.
            ExpertMode        = $false
        }
        Logging = [ordered]@{
            # One of: Verbose | Info | Warning | Error.
            LogLevel         = 'Info'
            LogRetentionDays = 30
            LogToConsole     = $true
            LogToFile        = $true
        }
        Scan = [ordered]@{
            DeepScan           = $false
            ScanTimeoutSeconds = 300
            IncludeSystemFiles = $false
        }
        Gaming = [ordered]@{
            GameModePriority                  = $true
            NetworkOptimizationForGaming      = $true
            DisableBackgroundAppsDuringGaming = $false
        }
        AIRecommendation = [ordered]@{
            Enabled                   = $true
            # Recommendations below this confidence score are omitted/flagged
            # as low-confidence by the Analyzer (built in Phase 3).
            ConfidenceThreshold       = 0.75
            MaxRecommendationsPerScan = 20
        }
        Backup = [ordered]@{
            AutoBackupBeforeChanges = $true
            BackupRetentionCount    = 10
        }
    }

    return (ConvertTo-TetraPSCustomObject -InputObject $defaults)
}

# ============================================================
# FUNCTION: Merge-TetraConfigSchema
# ============================================================
<#
.SYNOPSIS
    Recursively heals a loaded configuration object against the current
    default schema, adding any missing sections/keys without touching
    existing user-set values.
.DESCRIPTION
    Called every time configuration is loaded from disk. This is what lets
    the schema grow over time (new modules adding new default settings)
    without ever breaking an existing user's Config.json or silently
    discarding their customizations.
.PARAMETER Loaded
    The configuration object as read from Config.json.
.PARAMETER Default
    The current in-code default configuration (from Get-TetraDefaultConfig).
.OUTPUTS
    PSCustomObject with two properties:
        Config      - The (possibly mutated in-place) loaded configuration.
        WasModified - Boolean; $true if any key/section was added.
#>
function Merge-TetraConfigSchema {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Loaded,

        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Default
    )

    $wasModified = $false

    foreach ($property in $Default.PSObject.Properties) {
        $name         = $property.Name
        $defaultValue = $property.Value

        if (-not ($Loaded.PSObject.Properties.Name -contains $name)) {
            $Loaded | Add-Member -NotePropertyName $name -NotePropertyValue $defaultValue -Force
            $wasModified = $true
            continue
        }

        $loadedValue = $Loaded.$name

        $defaultIsObject = $defaultValue -is [System.Management.Automation.PSCustomObject]
        $loadedIsObject  = $loadedValue -is [System.Management.Automation.PSCustomObject]

        if ($defaultIsObject -and $loadedIsObject) {
            $nestedResult = Merge-TetraConfigSchema -Loaded $loadedValue -Default $defaultValue
            if ($nestedResult.WasModified) {
                $wasModified = $true
            }
        }
        # If default is an object but loaded is NOT (corrupted/edited by hand),
        # we deliberately do not overwrite - a corrupted section is surfaced
        # by validation elsewhere rather than silently replaced here.
    }

    return [PSCustomObject]@{
        Config      = $Loaded
        WasModified = $wasModified
    }
}

# ============================================================
# FUNCTION: Initialize-TetraConfig
# ============================================================
<#
.SYNOPSIS
    Ensures the Config folder, DefaultConfig.json, and Config.json all exist,
    creating whatever is missing from the in-code defaults.
.DESCRIPTION
    Idempotent. Safe to call on every Tetra Optimizer launch.

    - DefaultConfig.json is ALWAYS (re)written from the current in-code
      defaults, since it is a pure reference file, not user data.
    - Config.json is created from defaults ONLY if it does not already exist,
      or if -Force is specified. An existing Config.json is otherwise left
      untouched by this function (schema healing happens in Get-TetraConfig).
.PARAMETER Force
    If specified, overwrites an existing Config.json with fresh defaults.
    Intended for explicit "factory reset" flows only.
.OUTPUTS
    System.Management.Automation.PSCustomObject - the resulting live configuration.
#>
function Initialize-TetraConfig {
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([PSCustomObject])]
    param(
        [switch]$Force
    )

    try {
        Initialize-TetraDirectory -Path (Get-TetraConfigDirectory) | Out-Null

        $configPath        = Get-TetraConfigFilePath
        $defaultConfigPath = Get-TetraDefaultConfigFilePath
        $defaultConfig     = Get-TetraDefaultConfig

        if ($PSCmdlet.ShouldProcess($defaultConfigPath, 'Write reference default configuration')) {
            $defaultConfig | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $defaultConfigPath -Encoding UTF8
        }

        $configMissing = -not (Test-Path -LiteralPath $configPath)

        if ($configMissing -or $Force) {
            if ($PSCmdlet.ShouldProcess($configPath, 'Create live configuration from defaults')) {
                $defaultConfig | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $configPath -Encoding UTF8
            }
            $Script:TetraConfigCache = $defaultConfig
            return $defaultConfig
        }

        return Get-TetraConfig -Refresh
    }
    catch {
        throw "Initialize-TetraConfig: Failed to initialize configuration - $($_.Exception.Message)"
    }
}

# ============================================================
# FUNCTION: Get-TetraConfig
# ============================================================
<#
.SYNOPSIS
    Loads (or returns the cached) live configuration object, healing any
    schema gaps against the current defaults.
.PARAMETER Refresh
    Forces a re-read from disk instead of returning the in-memory cache.
.OUTPUTS
    System.Management.Automation.PSCustomObject
#>
function Get-TetraConfig {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [switch]$Refresh
    )

    try {
        if (-not $Refresh -and $null -ne $Script:TetraConfigCache) {
            return $Script:TetraConfigCache
        }

        $configPath = Get-TetraConfigFilePath

        if (-not (Test-Path -LiteralPath $configPath)) {
            return Initialize-TetraConfig
        }

        $rawJson = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8
        $loaded  = $rawJson | ConvertFrom-Json

        $defaultConfig = Get-TetraDefaultConfig
        $mergeResult   = Merge-TetraConfigSchema -Loaded $loaded -Default $defaultConfig

        if ($mergeResult.WasModified) {
            Save-TetraConfig -Config $mergeResult.Config | Out-Null
        }
        else {
            $Script:TetraConfigCache = $mergeResult.Config
        }

        return $Script:TetraConfigCache
    }
    catch {
        throw "Get-TetraConfig: Failed to load configuration - $($_.Exception.Message)"
    }
}

# ============================================================
# FUNCTION: Save-TetraConfig
# ============================================================
<#
.SYNOPSIS
    Persists a configuration object to Config.json and refreshes the cache.
.PARAMETER Config
    The full configuration object to persist.
.OUTPUTS
    System.Management.Automation.PSCustomObject - the saved configuration.
#>
function Save-TetraConfig {
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Config
    )

    try {
        $configPath = Get-TetraConfigFilePath

        if ($Config.PSObject.Properties.Name -contains 'Metadata') {
            $Config.Metadata.LastModifiedUtc = (Get-Date).ToUniversalTime().ToString('o')
        }

        if ($PSCmdlet.ShouldProcess($configPath, 'Save configuration')) {
            $Config | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $configPath -Encoding UTF8
        }

        $Script:TetraConfigCache = $Config
        return $Config
    }
    catch {
        throw "Save-TetraConfig: Failed to save configuration - $($_.Exception.Message)"
    }
}

# ============================================================
# FUNCTION: Get-TetraConfigNodeByPath
# ============================================================
<#
.SYNOPSIS
    Internal helper: walks a dot-separated path of property names through a
    PSCustomObject graph and returns the node found at the end (or $null).
.DESCRIPTION
    Shared by Get-TetraConfigValue (walks the FULL path to fetch a leaf value)
    and Set-TetraConfigValue (walks all but the last segment to find the
    parent node to mutate). Factored out here specifically to avoid
    duplicating path-walking logic between the two.
.PARAMETER Config
    The root object to walk.
.PARAMETER PathSegments
    Ordered array of property names to traverse.
.OUTPUTS
    System.Object or $null if any segment along the path does not exist.
#>
function Get-TetraConfigNodeByPath {
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Config,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$PathSegments
    )

    $node = $Config

    foreach ($segment in $PathSegments) {
        if ($null -eq $node) {
            return $null
        }

        if ($node -isnot [System.Management.Automation.PSCustomObject]) {
            return $null
        }

        if (-not ($node.PSObject.Properties.Name -contains $segment)) {
            return $null
        }

        $node = $node.$segment
    }

    return $node
}

# ============================================================
# FUNCTION: Get-TetraConfigValue
# ============================================================
<#
.SYNOPSIS
    Retrieves a single configuration value by dot-separated path.
.DESCRIPTION
    Example: Get-TetraConfigValue -Path "Logging.LogLevel"
.PARAMETER Path
    Dot-separated section/key path, e.g. "General.SafeMode".
.OUTPUTS
    System.Object - the value found, or $null if the path does not exist.
#>
function Get-TetraConfigValue {
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    try {
        $config   = Get-TetraConfig
        $segments = $Path.Split('.')
        $value    = Get-TetraConfigNodeByPath -Config $config -PathSegments $segments

        if ($null -eq $value) {
            Write-Verbose "Get-TetraConfigValue: Path '$Path' was not found in the current configuration."
        }

        return $value
    }
    catch {
        throw "Get-TetraConfigValue: Failed to retrieve value for '$Path' - $($_.Exception.Message)"
    }
}

# ============================================================
# FUNCTION: Set-TetraConfigValue
# ============================================================
<#
.SYNOPSIS
    Sets a single configuration value by dot-separated path and persists it.
.DESCRIPTION
    Example: Set-TetraConfigValue -Path "General.ExpertMode" -Value $true

    If the leaf key does not yet exist under the resolved parent node, it is
    added (supports extending the schema at runtime); if the PARENT section
    itself does not exist, this throws rather than guessing/creating an
    arbitrary new top-level section.
.PARAMETER Path
    Dot-separated section/key path, e.g. "Gaming.GameModePriority".
.PARAMETER Value
    The new value to assign.
.OUTPUTS
    System.Management.Automation.PSCustomObject - the full, updated configuration.
#>
function Set-TetraConfigValue {
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object]$Value
    )

    try {
        $config   = Get-TetraConfig
        $segments = $Path.Split('.')

        if ($segments.Count -lt 1) {
            throw "Invalid configuration path '$Path'."
        }

        $leafName        = $segments[$segments.Count - 1]
        $parentSegments  = @(if ($segments.Count -gt 1) { $segments[0..($segments.Count - 2)] } else { @() })

        $parentNode = if ($parentSegments.Count -eq 0) {
            $config
        }
        else {
            Get-TetraConfigNodeByPath -Config $config -PathSegments $parentSegments
        }

        if ($null -eq $parentNode) {
            $knownSections = (Get-TetraDefaultConfig).PSObject.Properties.Name -join ', '
            throw "Configuration path '$Path' is invalid - parent section does not exist. Known top-level sections: $knownSections"
        }

        if ($PSCmdlet.ShouldProcess($Path, "Set configuration value")) {
            if ($parentNode.PSObject.Properties.Name -contains $leafName) {
                $parentNode.$leafName = $Value
            }
            else {
                $parentNode | Add-Member -NotePropertyName $leafName -NotePropertyValue $Value -Force
            }

            Save-TetraConfig -Config $config | Out-Null
        }

        return $config
    }
    catch {
        throw "Set-TetraConfigValue: Failed to set '$Path' - $($_.Exception.Message)"
    }
}

# ============================================================
# FUNCTION: Reset-TetraConfig
# ============================================================
<#
.SYNOPSIS
    Restores the live configuration to the current in-code defaults.
.DESCRIPTION
    Intended for an explicit "Factory Reset" action in the future Settings
    menu (Core layer). Overwrites Config.json entirely - unlike normal
    loading/merging, this is a deliberate, user-confirmed destructive action.
.OUTPUTS
    System.Management.Automation.PSCustomObject - the restored default configuration.
#>
function Reset-TetraConfig {
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([PSCustomObject])]
    param()

    try {
        $defaultConfig = Get-TetraDefaultConfig

        if ($PSCmdlet.ShouldProcess((Get-TetraConfigFilePath), 'Reset configuration to defaults')) {
            return Save-TetraConfig -Config $defaultConfig
        }

        return $defaultConfig
    }
    catch {
        throw "Reset-TetraConfig: Failed to reset configuration - $($_.Exception.Message)"
    }
}

# ============================================================
# FUNCTION: Get-TetraConfigValueOrDefault
# ============================================================
<#
.SYNOPSIS
    Retrieves a configuration value by dot-separated path, falling back to
    a caller-supplied default if the path is missing OR if configuration
    cannot be read at all (e.g. called before Config.json exists).
.DESCRIPTION
    Extracted during the Foundation Validation pass: this was previously
    a duplicated try/catch pattern inside LoggerEngine (repeated for
    Logging.LogLevel, Logging.LogToFile, Logging.LogRetentionDays). Every
    future Engine module reading a config-driven setting should use this
    instead of re-implementing the same fallback logic.
.PARAMETER Path
    Dot-separated section/key path, e.g. "Logging.LogLevel".
.PARAMETER Default
    Value to return if the path is missing or configuration is unavailable.
.OUTPUTS
    System.Object - the configured value, or Default.
.EXAMPLE
    Get-TetraConfigValueOrDefault -Path 'Logging.LogLevel' -Default 'Info'
#>
function Get-TetraConfigValueOrDefault {
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object]$Default
    )

    try {
        $value = Get-TetraConfigValue -Path $Path

        if ($null -eq $value) {
            return $Default
        }

        return $value
    }
    catch {
        Write-Verbose "Get-TetraConfigValueOrDefault: Falling back to default for '$Path' - $($_.Exception.Message)"
        return $Default
    }
}

# ============================================================
# MODULE API SURFACE
# ============================================================
# NOTE: documented convention, not an enforced boundary (see
# PathHelpers.ps1 for the full explanation).
#
# Public Functions (intended for use by other modules):
#   - Initialize-TetraConfig       (called by Bootstrap)
#   - Get-TetraConfig              (zero current external callers -
#     kept public as the primary "read full config" entry point for
#     a future Core Settings screen)
#   - Save-TetraConfig             (zero current external callers -
#     kept public for a future Core Settings "save" action)
#   - Get-TetraConfigValue         (zero current external callers as
#     of this session - LoggerEngine now goes through
#     Get-TetraConfigValueOrDefault instead - but this remains the
#     fundamental single-value read API for callers that need a
#     required setting with no fallback)
#   - Set-TetraConfigValue         (zero current external callers -
#     kept public for a future Core Settings "change a value" action)
#   - Reset-TetraConfig            (zero current external callers -
#     kept public for a future Core "factory reset" action)
#   - Get-TetraConfigValueOrDefault (used by LoggerEngine; the
#     recommended API for any future Engine module reading a
#     config-driven setting with a safe fallback)
#
# Internal Functions (implementation details - do not call from
# outside this file; may change without notice):
#   - Get-TetraConfigDirectory
#   - Get-TetraConfigFilePath
#   - Get-TetraDefaultConfigFilePath
#   - ConvertTo-TetraPSCustomObject
#   - Get-TetraDefaultConfig
#   - Merge-TetraConfigSchema
#   - Get-TetraConfigNodeByPath
