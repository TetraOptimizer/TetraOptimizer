#Requires -Version 5.1
<#
.SYNOPSIS
    Tetra Optimizer - Logger Engine
.DESCRIPTION
    Structured, file-based logging for every system-modifying or
    analysis operation performed anywhere in Tetra Optimizer.

    RESPONSIBILITY (single):
        Persist, filter, retrieve, and expire log entries; correlate
        related entries under a shared OperationId and SessionId; enrich
        entries with session/machine/hardware/product metadata
        automatically. Nothing else.

    THIS FILE MUST NEVER:
        - Write to the console (no Write-Host). Logging is Engine-layer;
          console presentation is Core's responsibility.
        - Contain optimization/business logic beyond logging itself.

    OPERATION CONTEXT MODEL:
        A module-scoped stack tracks "in-flight" high-level operations.
        Start-TetraOperation pushes a new GUID (with an optional
        ParentOperationId if nested); every Write-TetraLog call made while
        that context is active automatically tags its entry with the
        current (innermost) OperationId. Stop-TetraOperation pops the
        context and logs its total duration. If no operation context is
        active, each standalone log entry still receives its own one-off
        OperationId (never null).

    SESSION MODEL:
        Exactly one SessionId is generated per application launch (lazily,
        on first use - dot-sourcing this file has no side effects). It is
        cached for the life of the process and automatically attached to
        every log entry, regardless of which/how many OperationIds occur
        within it. Multiple OperationIds can (and normally will) exist
        inside one SessionId.

    AUTOMATIC METADATA:
        Every entry automatically includes:
            DeviceId, MachineName, UserName, PowerShellVersion,
            OperatingSystem, OsArchitecture, CpuModel, LogicalCpuCount,
            PhysicalCoreCount, InstalledRamGB, TetraVersion, BuildNumber,
            ReleaseChannel
        Collected once via Get-TetraSystemMetadata and cached for the
        session (avoids repeated CIM/WMI queries and file reads). Engine
        callers never supply any of this.

    LOG STORAGE MODEL:
        Logs/Tetra_yyyy-MM-dd.log
            One file per calendar day (UTC), JSON Lines format (one
            JSON-serialized entry per line).

    LOG ENTRY SCHEMA:
        TimestampUtc      : string (ISO 8601)
        OperationId       : string (GUID)
        SessionId         : string (GUID)
        Level             : Verbose | Info | Success | Warning | Error
        Module            : string
        Action            : string
        Target            : string
        Result            : string
        Message           : string
        DurationMs        : double or $null
        DeviceId          : string (GUID, permanent per machine)
        MachineName       : string
        UserName          : string
        PowerShellVersion : string
        OperatingSystem   : string
        OsArchitecture    : string
        CpuModel          : string
        LogicalCpuCount   : int or $null
        PhysicalCoreCount : int or $null
        InstalledRamGB    : double or $null
        TetraVersion      : string
        BuildNumber       : string
        ReleaseChannel    : string

    PUBLIC API STABILITY:
        Write-TetraLog, Invoke-TetraLoggedOperation, Remove-TetraExpiredLogs,
        and all path helpers keep their original signatures. Get-TetraLogEntries
        gains an additional optional -SessionId filter (existing calls are
        unaffected). Existing callers require zero changes.

    DEPENDENCIES:
        Config/PathHelpers.ps1, Config/Config.ps1, Config/ProductInfo.ps1, and
        Config/DeviceIdentity.ps1 must already be dot-sourced.
.NOTES
    Module      : LoggerEngine.ps1
    Layer       : Engine
    Build Phase : Phase 1 - Foundation
    Build Step  : 2 of 32 (revised again: SessionId + DeviceId + expanded metadata; Foundation Validation pass removed duplicated path/config-fallback logic in favor of shared helpers)
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ============================================================
# MODULE-SCOPED STATE
# ============================================================

# Severity ranking used to compare the configured minimum log level
# against an individual entry's level. Higher number = more severe.
$Script:TetraLogLevelSeverityMap = [ordered]@{
    Verbose = 0
    Info    = 1
    Success = 1
    Warning = 2
    Error   = 3
}

# Stack of currently active Operation Contexts (innermost operation is on
# top). Empty when no operation is in progress.
$Script:TetraOperationStack = [System.Collections.Generic.Stack[PSCustomObject]]::new()

# Current application session (lazily created on first use). One per
# process launch; never regenerated afterward.
$Script:TetraSessionContext = $null

# Cached session metadata (machine/user/PS version/OS/hardware/product).
# Computed once on first use via Get-TetraSystemMetadata.
$Script:TetraSystemMetadataCache = $null

# ============================================================
# FUNCTION: Get-TetraVersion
# ============================================================
<#
.SYNOPSIS
    Returns the current Tetra Optimizer application version string.
.DESCRIPTION
    Thin backward-compatibility wrapper. Version identity now lives in
    Config/ProductInfo.ps1 (Get-TetraProductInfo); this function delegates
    to it so any existing caller of Get-TetraVersion keeps working
    unmodified.
.OUTPUTS
    System.String
#>
function Get-TetraVersion {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    try {
        return (Get-TetraProductInfo).Version
    }
    catch {
        Write-Verbose "Get-TetraVersion: Could not resolve product info - $($_.Exception.Message)"
        return 'Unknown'
    }
}

# ============================================================
# FUNCTION: Get-TetraSystemMetadata
# ============================================================
<#
.SYNOPSIS
    Returns (and caches) machine, hardware, and product metadata
    automatically attached to every log entry.
.DESCRIPTION
    Collects DeviceId, MachineName, UserName, PowerShellVersion,
    OperatingSystem, OsArchitecture, CpuModel, LogicalCpuCount,
    PhysicalCoreCount, InstalledRamGB, TetraVersion, BuildNumber, and
    ReleaseChannel. Computed once per session and cached, since these
    values do not change during a single run and hardware/OS lookups
    involve CIM calls on Windows PowerShell 5.1.

    Each individual sub-lookup is wrapped in its own try/catch so a single
    failed CIM query (e.g. restricted WMI access) degrades that one field
    to "Unknown" rather than breaking metadata collection entirely.
.PARAMETER Refresh
    Forces re-collection instead of returning the cached value.
.OUTPUTS
    System.Management.Automation.PSCustomObject
#>
function Get-TetraSystemMetadata {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [switch]$Refresh
    )

    if (-not $Refresh -and $null -ne $Script:TetraSystemMetadataCache) {
        return $Script:TetraSystemMetadataCache
    }

    $machineName = $env:COMPUTERNAME
    if ([string]::IsNullOrWhiteSpace($machineName)) {
        $machineName = 'Unknown'
    }

    $userName = $null
    try {
        $userName = [Environment]::UserName
    }
    catch {
        Write-Verbose "Get-TetraSystemMetadata: Could not resolve UserName - $($_.Exception.Message)"
    }
    if ([string]::IsNullOrWhiteSpace($userName)) {
        $userName = 'Unknown'
    }

    $psVersion = $PSVersionTable.PSVersion.ToString()

    $operatingSystem = 'Unknown'
    $osArchitecture  = 'Unknown'
    try {
        $osInfo = Get-CimInstance -ClassName Win32_OperatingSystem -Property Caption, Version, OSArchitecture -ErrorAction Stop
        $operatingSystem = "$($osInfo.Caption) ($($osInfo.Version))"
        $osArchitecture  = $osInfo.OSArchitecture
    }
    catch {
        Write-Verbose "Get-TetraSystemMetadata: Could not resolve OperatingSystem/OsArchitecture - $($_.Exception.Message)"
    }

    $cpuModel          = 'Unknown'
    $logicalCpuCount   = $null
    $physicalCoreCount = $null
    try {
        $cpuInfo  = @(Get-CimInstance -ClassName Win32_Processor -Property Name, NumberOfLogicalProcessors, NumberOfCores -ErrorAction Stop)
        if ($cpuInfo.Count -gt 0) {
            $cpuModel          = $cpuInfo[0].Name.Trim()
            $logicalCpuCount   = [int]($cpuInfo | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum
            $physicalCoreCount = [int]($cpuInfo | Measure-Object -Property NumberOfCores -Sum).Sum
        }
    }
    catch {
        Write-Verbose "Get-TetraSystemMetadata: Could not resolve CPU information - $($_.Exception.Message)"
    }

    $installedRamGB = $null
    try {
        $csInfo = Get-CimInstance -ClassName Win32_ComputerSystem -Property TotalPhysicalMemory -ErrorAction Stop
        $installedRamGB = [math]::Round($csInfo.TotalPhysicalMemory / 1GB, 1)
    }
    catch {
        Write-Verbose "Get-TetraSystemMetadata: Could not resolve installed RAM - $($_.Exception.Message)"
    }

    $deviceId = 'Unknown'
    try {
        $deviceId = Get-TetraDeviceId
    }
    catch {
        Write-Verbose "Get-TetraSystemMetadata: Could not resolve DeviceId - $($_.Exception.Message)"
    }

    $tetraVersion   = 'Unknown'
    $buildNumber    = 'Unknown'
    $releaseChannel = 'Unknown'
    try {
        $productInfo    = Get-TetraProductInfo
        $tetraVersion   = $productInfo.Version
        $buildNumber    = $productInfo.BuildNumber
        $releaseChannel = $productInfo.ReleaseChannel
    }
    catch {
        Write-Verbose "Get-TetraSystemMetadata: Could not resolve product info - $($_.Exception.Message)"
    }

    $Script:TetraSystemMetadataCache = [PSCustomObject]@{
        DeviceId          = $deviceId
        MachineName       = $machineName
        UserName          = $userName
        PowerShellVersion = $psVersion
        OperatingSystem   = $operatingSystem
        OsArchitecture    = $osArchitecture
        CpuModel          = $cpuModel
        LogicalCpuCount   = $logicalCpuCount
        PhysicalCoreCount = $physicalCoreCount
        InstalledRamGB    = $installedRamGB
        TetraVersion      = $tetraVersion
        BuildNumber       = $buildNumber
        ReleaseChannel    = $releaseChannel
    }

    return $Script:TetraSystemMetadataCache
}

# ============================================================
# FUNCTION: Get-TetraSessionContext
# ============================================================
<#
.SYNOPSIS
    Returns the current application session's context, creating it (once)
    on first call.
.DESCRIPTION
    Lazily generates a single SessionId per process launch and caches it.
    On creation, logs a "session started" marker entry (which itself
    carries the newly created SessionId, since the cache is populated
    before that log call is made - this is intentional and does not
    recurse indefinitely).
.OUTPUTS
    System.Management.Automation.PSCustomObject: SessionId, StartedUtc
#>
function Get-TetraSessionContext {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param()

    if ($null -eq $Script:TetraSessionContext) {
        $Script:TetraSessionContext = [PSCustomObject]@{
            SessionId  = [guid]::NewGuid().ToString()
            StartedUtc = (Get-Date).ToUniversalTime().ToString('o')
        }

        try {
            Write-TetraLog -Level 'Info' -Module 'LoggerEngine' -Action 'Start-TetraSession' `
                -Target $Script:TetraSessionContext.SessionId -Result 'Started' `
                -Message 'New application session started.' | Out-Null
        }
        catch {
            Write-Verbose "Get-TetraSessionContext: Failed to log session start - $($_.Exception.Message)"
        }
    }

    return $Script:TetraSessionContext
}

# ============================================================
# FUNCTION: Get-TetraSessionId
# ============================================================
<#
.SYNOPSIS
    Returns the current application session's SessionId.
.OUTPUTS
    System.String (GUID)
#>
function Get-TetraSessionId {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    return (Get-TetraSessionContext).SessionId
}

# ============================================================
# FUNCTION: Get-TetraCurrentOperationId
# ============================================================
<#
.SYNOPSIS
    Returns the OperationId of the currently active (innermost) operation,
    or $null if no operation context is active.
.OUTPUTS
    System.String or $null
#>
function Get-TetraCurrentOperationId {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    if ($Script:TetraOperationStack.Count -eq 0) {
        return $null
    }

    return $Script:TetraOperationStack.Peek().OperationId.ToString()
}

# ============================================================
# FUNCTION: Get-TetraCurrentOperationContext
# ============================================================
<#
.SYNOPSIS
    Returns the full context object of the currently active operation, or
    $null if none is active.
.OUTPUTS
    System.Management.Automation.PSCustomObject or $null
#>
function Get-TetraCurrentOperationContext {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param()

    if ($Script:TetraOperationStack.Count -eq 0) {
        return $null
    }

    return $Script:TetraOperationStack.Peek()
}

# ============================================================
# FUNCTION: Start-TetraOperation
# ============================================================
<#
.SYNOPSIS
    Begins a new (optionally nested) high-level operation context.
.PARAMETER Name
    A human-readable name for the operation, e.g. "System Optimization".
.OUTPUTS
    System.Management.Automation.PSCustomObject - the new context:
        OperationId, Name, ParentOperationId, StartTimeUtc
#>
function Start-TetraOperation {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Name
    )

    try {
        $parentOperationId = Get-TetraCurrentOperationId

        $context = [PSCustomObject]@{
            OperationId       = [guid]::NewGuid()
            Name              = $Name
            ParentOperationId = $parentOperationId
            StartTimeUtc      = (Get-Date).ToUniversalTime().ToString('o')
        }

        $Script:TetraOperationStack.Push($context)

        Write-TetraLog -Level 'Info' -Module 'LoggerEngine' -Action 'Start-TetraOperation' `
            -Target $Name -Result 'Started' -Message "Operation '$Name' started." | Out-Null

        return $context
    }
    catch {
        throw "Start-TetraOperation: Failed to start operation '$Name' - $($_.Exception.Message)"
    }
}

# ============================================================
# FUNCTION: Stop-TetraOperation
# ============================================================
<#
.SYNOPSIS
    Ends the currently active (innermost) operation context.
.OUTPUTS
    System.Management.Automation.PSCustomObject describing the completed
    operation, or $null if no operation was active.
#>
function Stop-TetraOperation {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param()

    if ($Script:TetraOperationStack.Count -eq 0) {
        Write-Verbose 'Stop-TetraOperation: No active operation context to stop.'
        return $null
    }

    try {
        $context      = $Script:TetraOperationStack.Peek()
        $endTimeUtc   = (Get-Date).ToUniversalTime()
        $startTimeUtc = [datetime]::Parse($context.StartTimeUtc, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
        $durationMs   = ($endTimeUtc - $startTimeUtc).TotalMilliseconds

        Write-TetraLog -Level 'Info' -Module 'LoggerEngine' -Action 'Stop-TetraOperation' `
            -Target $context.Name -Result 'Completed' -Message "Operation '$($context.Name)' completed." `
            -DurationMs $durationMs | Out-Null

        $Script:TetraOperationStack.Pop() | Out-Null

        return [PSCustomObject]@{
            OperationId       = $context.OperationId
            Name              = $context.Name
            ParentOperationId = $context.ParentOperationId
            StartTimeUtc      = $context.StartTimeUtc
            EndTimeUtc        = $endTimeUtc.ToString('o')
            DurationMs        = $durationMs
        }
    }
    catch {
        throw "Stop-TetraOperation: Failed to stop the active operation - $($_.Exception.Message)"
    }
}

# ============================================================
# FUNCTION: Get-TetraLogDirectory
# ============================================================
<#
.SYNOPSIS
    Returns the absolute path to the Logs folder.
.OUTPUTS
    System.String
#>
function Get-TetraLogDirectory {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    return (Get-TetraSiblingDirectory -CallerScriptRoot $PSScriptRoot -FolderName 'Logs')
}

# ============================================================
# FUNCTION: Initialize-TetraLogDirectory
# ============================================================
<#
.SYNOPSIS
    Ensures the Logs folder exists on disk.
.OUTPUTS
    System.String - the (now guaranteed to exist) Logs folder path.
#>
function Initialize-TetraLogDirectory {
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([string])]
    param()

    return (Initialize-TetraDirectory -Path (Get-TetraLogDirectory))
}

# ============================================================
# FUNCTION: Get-TetraLogFilePath
# ============================================================
<#
.SYNOPSIS
    Returns the absolute path to the log file for a given date.
.PARAMETER Date
    The date (UTC) whose log file path should be returned. Defaults to the
    current date.
.OUTPUTS
    System.String
#>
function Get-TetraLogFilePath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $false)]
        [ValidateNotNull()]
        [datetime]$Date = (Get-Date).ToUniversalTime()
    )

    $logDir   = Get-TetraLogDirectory
    $fileName = "Tetra_{0}.log" -f $Date.ToString('yyyy-MM-dd')
    return (Join-Path -Path $logDir -ChildPath $fileName)
}

# ============================================================
# FUNCTION: ConvertTo-TetraLogLevelSeverity
# ============================================================
<#
.SYNOPSIS
    Converts a log level name into its numeric severity ranking.
.PARAMETER Level
    One of: Verbose, Info, Success, Warning, Error.
.OUTPUTS
    System.Int32
#>
function ConvertTo-TetraLogLevelSeverity {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Verbose', 'Info', 'Success', 'Warning', 'Error')]
        [string]$Level
    )

    if (-not $Script:TetraLogLevelSeverityMap.Contains($Level)) {
        throw "ConvertTo-TetraLogLevelSeverity: Unknown log level '$Level'."
    }

    return $Script:TetraLogLevelSeverityMap[$Level]
}

# ============================================================
# FUNCTION: Test-TetraLogLevelEnabled
# ============================================================
<#
.SYNOPSIS
    Determines whether a given log level should be recorded, based on the
    configured minimum log level.
.PARAMETER Level
    The level of the entry being considered for logging.
.PARAMETER ConfiguredLevel
    The minimum level configured in Logging.LogLevel.
.OUTPUTS
    System.Boolean
#>
function Test-TetraLogLevelEnabled {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Verbose', 'Info', 'Success', 'Warning', 'Error')]
        [string]$Level,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Verbose', 'Info', 'Success', 'Warning', 'Error')]
        [string]$ConfiguredLevel
    )

    $entrySeverity      = ConvertTo-TetraLogLevelSeverity -Level $Level
    $configuredSeverity = ConvertTo-TetraLogLevelSeverity -Level $ConfiguredLevel

    return ($entrySeverity -ge $configuredSeverity)
}

# ============================================================
# FUNCTION: Write-TetraLog
# ============================================================
<#
.SYNOPSIS
    Records a single structured log entry, automatically enriched with an
    OperationId, SessionId, and full machine/hardware/product metadata.
.DESCRIPTION
    Builds a log entry object, filters it against the configured
    Logging.LogLevel, and - if Logging.LogToFile is enabled and the entry
    passes the filter - appends it as a JSON line to today's log file.

    ALWAYS returns the constructed log entry object regardless of whether
    it was written to disk.
.PARAMETER Level
    Verbose, Info, Success, Warning, or Error.
.PARAMETER Module
    Name of the calling module, e.g. "ProcessesEngine".
.PARAMETER Action
    Name of the operation performed, e.g. "Stop-Process".
.PARAMETER Target
    The specific object the action was performed against. Optional.
.PARAMETER Result
    Free-text outcome, e.g. "Success", "Failed", "Skipped". Optional.
.PARAMETER Message
    Human-readable explanation or reason. Optional.
.PARAMETER DurationMs
    How long the operation took, in milliseconds. Optional.
.OUTPUTS
    System.Management.Automation.PSCustomObject - the log entry.
#>
function Write-TetraLog {
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $false)]
        [ValidateSet('Verbose', 'Info', 'Success', 'Warning', 'Error')]
        [string]$Level = 'Info',

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Module,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Action,

        [Parameter(Mandatory = $false)]
        [string]$Target = '',

        [Parameter(Mandatory = $false)]
        [string]$Result = '',

        [Parameter(Mandatory = $false)]
        [string]$Message = '',

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [Nullable[double]]$DurationMs = $null
    )

    try {
        $operationId = Get-TetraCurrentOperationId
        if ([string]::IsNullOrEmpty($operationId)) {
            $operationId = [guid]::NewGuid().ToString()
        }

        $sessionId = Get-TetraSessionId
        $metadata  = Get-TetraSystemMetadata

        $entry = [PSCustomObject]@{
            TimestampUtc      = (Get-Date).ToUniversalTime().ToString('o')
            OperationId       = $operationId
            SessionId         = $sessionId
            Level             = $Level
            Module            = $Module
            Action            = $Action
            Target            = $Target
            Result            = $Result
            Message           = $Message
            DurationMs        = $DurationMs
            DeviceId          = $metadata.DeviceId
            MachineName       = $metadata.MachineName
            UserName          = $metadata.UserName
            PowerShellVersion = $metadata.PowerShellVersion
            OperatingSystem   = $metadata.OperatingSystem
            OsArchitecture    = $metadata.OsArchitecture
            CpuModel          = $metadata.CpuModel
            LogicalCpuCount   = $metadata.LogicalCpuCount
            PhysicalCoreCount = $metadata.PhysicalCoreCount
            InstalledRamGB    = $metadata.InstalledRamGB
            TetraVersion      = $metadata.TetraVersion
            BuildNumber       = $metadata.BuildNumber
            ReleaseChannel    = $metadata.ReleaseChannel
        }

        $configuredLevel = Get-TetraConfigValueOrDefault -Path 'Logging.LogLevel' -Default 'Info'
        $logToFile       = [bool](Get-TetraConfigValueOrDefault -Path 'Logging.LogToFile' -Default $true)

        $shouldPersist = (Test-TetraLogLevelEnabled -Level $Level -ConfiguredLevel $configuredLevel) -and $logToFile

        if ($shouldPersist) {
            Initialize-TetraLogDirectory | Out-Null
            $logFilePath = Get-TetraLogFilePath

            if ($PSCmdlet.ShouldProcess($logFilePath, "Append $Level log entry")) {
                $jsonLine = $entry | ConvertTo-Json -Depth 10 -Compress
                Add-Content -LiteralPath $logFilePath -Value $jsonLine -Encoding UTF8
            }
        }

        return $entry
    }
    catch {
        Write-Error "Write-TetraLog: Failed to record log entry - $($_.Exception.Message)"
        return [PSCustomObject]@{
            TimestampUtc = (Get-Date).ToUniversalTime().ToString('o')
            OperationId  = $null
            SessionId    = $null
            Level        = $Level
            Module       = $Module
            Action       = $Action
            Target       = $Target
            Result       = $Result
            Message      = $Message
            DurationMs   = $DurationMs
        }
    }
}

# ============================================================
# FUNCTION: Get-TetraLogEntries
# ============================================================
<#
.SYNOPSIS
    Retrieves log entries within a date range, with optional filtering.
.PARAMETER StartDate
    Earliest date (UTC) to include. Defaults to 7 days ago.
.PARAMETER EndDate
    Latest date (UTC) to include. Defaults to today.
.PARAMETER Level
    Optional filter - only return entries at exactly this level.
.PARAMETER Module
    Optional filter - only return entries from this module name.
.PARAMETER OperationId
    Optional filter - only return entries sharing this OperationId.
.PARAMETER SessionId
    Optional filter - only return entries sharing this SessionId (e.g.
    "everything that happened during the last application launch").
.OUTPUTS
    System.Management.Automation.PSCustomObject[] - possibly empty array.
#>
function Get-TetraLogEntries {
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter(Mandatory = $false)]
        [datetime]$StartDate = (Get-Date).ToUniversalTime().AddDays(-7),

        [Parameter(Mandatory = $false)]
        [datetime]$EndDate = (Get-Date).ToUniversalTime(),

        [Parameter(Mandatory = $false)]
        [ValidateSet('Verbose', 'Info', 'Success', 'Warning', 'Error')]
        [string]$Level,

        [Parameter(Mandatory = $false)]
        [string]$Module,

        [Parameter(Mandatory = $false)]
        [string]$OperationId,

        [Parameter(Mandatory = $false)]
        [string]$SessionId
    )

    try {
        if ($StartDate -gt $EndDate) {
            throw "StartDate ($StartDate) cannot be later than EndDate ($EndDate)."
        }

        Initialize-TetraLogDirectory | Out-Null
        $results = [System.Collections.Generic.List[PSCustomObject]]::new()

        $currentDate = $StartDate.Date
        while ($currentDate -le $EndDate.Date) {
            $filePath = Get-TetraLogFilePath -Date $currentDate

            if (Test-Path -LiteralPath $filePath) {
                $lines = Get-Content -LiteralPath $filePath -Encoding UTF8

                foreach ($line in $lines) {
                    if ([string]::IsNullOrWhiteSpace($line)) {
                        continue
                    }

                    try {
                        $parsedEntry = $line | ConvertFrom-Json
                    }
                    catch {
                        Write-Verbose "Get-TetraLogEntries: Skipping unparseable line in '$filePath' - $($_.Exception.Message)"
                        continue
                    }

                    if ($Level -and $parsedEntry.Level -ne $Level) {
                        continue
                    }

                    if ($Module -and $parsedEntry.Module -ne $Module) {
                        continue
                    }

                    if ($OperationId -and $parsedEntry.OperationId -ne $OperationId) {
                        continue
                    }

                    if ($SessionId -and $parsedEntry.SessionId -ne $SessionId) {
                        continue
                    }

                    $results.Add($parsedEntry)
                }
            }

            $currentDate = $currentDate.AddDays(1)
        }

        return ($results | Sort-Object -Property TimestampUtc)
    }
    catch {
        throw "Get-TetraLogEntries: Failed to retrieve log entries - $($_.Exception.Message)"
    }
}

# ============================================================
# FUNCTION: Remove-TetraExpiredLogs
# ============================================================
<#
.SYNOPSIS
    Deletes log files older than the configured retention period.
.OUTPUTS
    System.Management.Automation.PSCustomObject summarizing the cleanup:
        RetentionDays, DeletedFiles, RetainedFiles
#>
function Remove-TetraExpiredLogs {
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([PSCustomObject])]
    param()

    try {
        $retentionDays = [int](Get-TetraConfigValueOrDefault -Path 'Logging.LogRetentionDays' -Default 30)

        if ($retentionDays -lt 0) {
            throw "Logging.LogRetentionDays cannot be negative (got $retentionDays)."
        }

        $logDir     = Initialize-TetraLogDirectory
        $cutoffDate = (Get-Date).ToUniversalTime().Date.AddDays(-$retentionDays)

        $allLogFiles = Get-ChildItem -LiteralPath $logDir -Filter 'Tetra_*.log' -File -ErrorAction SilentlyContinue

        $deletedFiles  = [System.Collections.Generic.List[string]]::new()
        $retainedFiles = [System.Collections.Generic.List[string]]::new()

        foreach ($file in $allLogFiles) {
            $dateMatch = [regex]::Match($file.Name, 'Tetra_(\d{4}-\d{2}-\d{2})\.log')

            $fileDate = if ($dateMatch.Success) {
                [datetime]::ParseExact($dateMatch.Groups[1].Value, 'yyyy-MM-dd', $null)
            }
            else {
                $file.LastWriteTimeUtc.Date
            }

            if ($fileDate -lt $cutoffDate) {
                if ($PSCmdlet.ShouldProcess($file.FullName, 'Delete expired log file')) {
                    Remove-Item -LiteralPath $file.FullName -Force
                    $deletedFiles.Add($file.FullName)
                }
            }
            else {
                $retainedFiles.Add($file.FullName)
            }
        }

        return [PSCustomObject]@{
            RetentionDays = $retentionDays
            DeletedFiles  = $deletedFiles
            RetainedFiles = $retainedFiles
        }
    }
    catch {
        throw "Remove-TetraExpiredLogs: Failed to clean up expired logs - $($_.Exception.Message)"
    }
}

# ============================================================
# FUNCTION: Invoke-TetraLoggedOperation
# ============================================================
<#
.SYNOPSIS
    Executes a script block with automatic timing, error handling, and
    structured logging (including automatic OperationId/SessionId/metadata
    via Write-TetraLog).
.PARAMETER Module
    Name of the calling module, e.g. "ServicesEngine".
.PARAMETER Action
    Name of the operation being performed, e.g. "Stop-Service".
.PARAMETER Target
    The specific object the action targets. Optional.
.PARAMETER ScriptBlock
    The operation to execute and measure.
.OUTPUTS
    System.Management.Automation.PSCustomObject:
        Success, Output, DurationMs, LogEntry
#>
function Invoke-TetraLoggedOperation {
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Module,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Action,

        [Parameter(Mandatory = $false)]
        [string]$Target = '',

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [scriptblock]$ScriptBlock
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    if (-not $PSCmdlet.ShouldProcess($Target, $Action)) {
        $stopwatch.Stop()
        return [PSCustomObject]@{
            Success    = $false
            Output     = $null
            DurationMs = $stopwatch.Elapsed.TotalMilliseconds
            LogEntry   = $null
        }
    }

    try {
        $output = & $ScriptBlock
        $stopwatch.Stop()

        $logEntry = Write-TetraLog -Level 'Success' -Module $Module -Action $Action -Target $Target `
            -Result 'Success' -Message 'Operation completed successfully.' `
            -DurationMs $stopwatch.Elapsed.TotalMilliseconds

        return [PSCustomObject]@{
            Success    = $true
            Output     = $output
            DurationMs = $stopwatch.Elapsed.TotalMilliseconds
            LogEntry   = $logEntry
        }
    }
    catch {
        $stopwatch.Stop()

        $logEntry = Write-TetraLog -Level 'Error' -Module $Module -Action $Action -Target $Target `
            -Result 'Failed' -Message $_.Exception.Message `
            -DurationMs $stopwatch.Elapsed.TotalMilliseconds

        throw
    }
}

# ============================================================
# MODULE API SURFACE
# ============================================================
# NOTE: documented convention, not an enforced boundary (see
# Config/PathHelpers.ps1 for the full explanation).
#
# Public Functions (intended for use by other modules):
#   - Get-TetraVersion                 (zero current callers - see
#     TECHNICAL DEBT note below)
#   - Get-TetraSystemMetadata          (used by Bootstrap, ReportEngine)
#   - Get-TetraSessionId               (used by Bootstrap)
#   - Get-TetraCurrentOperationId      (zero current callers - part of
#     the documented Operation Context contract for future Engine
#     modules, e.g. Backup Engine tagging its own log entries)
#   - Get-TetraCurrentOperationContext (same reasoning as above)
#   - Start-TetraOperation             (used by Tests; will be used by
#     Tetra.ps1/Core to bracket whole optimization runs)
#   - Stop-TetraOperation              (same)
#   - Initialize-TetraLogDirectory     (used by Bootstrap)
#   - Write-TetraLog                  (used by Tests, ReportEngine -
#     the core logging API)
#   - Get-TetraLogEntries              (used by Tests, ReportEngine)
#   - Remove-TetraExpiredLogs          (used by Bootstrap)
#   - Invoke-TetraLoggedOperation      (zero current callers - this is
#     expected: it exists specifically for Backup/Processes/Services/
#     Drivers/etc. Engine modules, none of which are built yet. See
#     Architectural Cost note below.)
#
# Internal Functions (implementation details):
#   - Get-TetraSessionContext        (Get-TetraSessionId is the public wrapper)
#   - Get-TetraLogDirectory
#   - Get-TetraLogFilePath
#   - ConvertTo-TetraLogLevelSeverity
#   - Test-TetraLogLevelEnabled
#
# TECHNICAL DEBT (flagged, not removed this session):
#   Get-TetraVersion has zero callers anywhere in the codebase and its
#   full functionality is already covered by ProductInfo.ps1's
#   Get-TetraProductInfo. It was added purely as a backward-compatibility
#   shim before this project had shipped to anyone - meaning there was
#   never an actual prior caller to be compatible with. Candidate for
#   removal; flagging rather than deleting unilaterally since removing
#   a public function is a Breaking Change requiring explicit sign-off
#   under the new Change Classification rule, even when currently unused.
#
# ARCHITECTURAL COST NOTE - Invoke-TetraLoggedOperation:
#   Benefit: every future Engine module gets timing + try/catch +
#     structured logging in one call instead of re-implementing it.
#   Cost: one extra function, one extra indirection layer.
#   Complexity added: low (single scriptblock wrapper, no reflection,
#     no dynamic dispatch).
#   Files affected if removed: none currently (zero callers yet).
#   Verdict: retained. This was built before the Architecture Freeze
#   Policy existed; retroactively it doesn't meet the strict letter of
#   "duplicated in 3+ locations today" (nothing calls it yet), but the
#   original project specification names ~15 future Engine modules
#   (Backup, Processes, Services, Drivers, Startup, Registry, Network,
#   Security...) that will each independently need this exact
#   timing/logging/error-handling pattern - removing working,
#   low-complexity infrastructure now would only guarantee the
#   duplication reappears the moment Backup Engine is built. The
#   Freeze Policy governs NEW abstractions going forward; it is not
#   grounds for churning out already-built, harmless ones.
