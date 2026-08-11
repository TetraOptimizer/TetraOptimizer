#Requires -Version 5.1
<#
.SYNOPSIS
    Tetra Optimizer - Backup Engine
.DESCRIPTION
    Atomic, integrity-verified file backup and restore, with automatic
    pre-restore safety snapshots and rollback on partial restore failure.

    RESPONSIBILITY (single):
        Back up explicit file paths; verify their integrity; restore them
        safely, with a mandatory pre-restore snapshot and automatic
        rollback if a restore fails partway through. Nothing else - this
        module never decides WHAT to back up (that is every future Engine
        module's own responsibility, e.g. a future RegistryEngine backing
        up a registry export before modifying it).

    THIS FILE MUST NEVER:
        - Print UI (no Write-Host). Engine layer.
        - Silently overwrite existing data without a safety snapshot.
        - Restore from, or trust, an unvalidated manifest.

    SCOPE FOR THIS PHASE:
        Files only - no folder recursion, no registry backup, no network/
        cloud backup. A future caller wanting to back up a whole folder
        enumerates its own file list and passes it to Backup-TetraItem.

    PROTECTED DIRECTORIES (never a valid backup source, never a valid
    restore destination): Backup, Config, Engine, Bootstrap, Tests, Logs,
    Reports (all resolved relative to the project root). This prevents
    Tetra from ever backing up or overwriting its own code/data.

    STORAGE MODEL:
        Backup/<Category>/<BackupId>/manifest.json
        Backup/<Category>/<BackupId>/payload/item_<N>/<original filename>

        <BackupId> = yyyyMMdd_HHmmss_<8-char-guid-suffix>
        <Category> = one of: Registry, Services, Startup, PowerPlans,
                     Drivers, Network, General

    MANIFEST SCHEMA (persistent on-disk format - ManifestVersion exists
    specifically because this is durable data that must remain parseable
    across future Tetra version upgrades):
        ManifestVersion, BackupId, Category, Label, RequestedByModule,
        IsAutoPreRestoreSnapshot, CreatedUtc, OperationId, SessionId,
        DeviceId, TetraVersion, BuildNumber, TotalSizeBytes, ItemCount,
        Items[]: { OriginalPath, StoredRelativePath, SizeBytes, Sha256,
                   LastWriteTimeUtc }

    RESTORE SAFETY MODEL:
        1. Manifest must pass schema validation (Test-TetraBackupManifestSchema)
        2. Full integrity check (SHA-256 + size) must pass for every item
           BEFORE any write is attempted - any failure aborts entirely,
           zero writes.
        3. Every destination is validated safe (not inside a protected
           directory) and every payload path is validated to stay inside
           its own BackupId/payload directory - ALL validated before any
           write begins (never discover a bad path halfway through).
        4. A single ShouldProcess/ConfirmImpact=High gate covers the
           WHOLE restore, evaluated AFTER all read-only validation but
           BEFORE any write (including the pre-restore snapshot itself) -
           -WhatIf or a declined confirmation results in zero filesystem
           mutations of any kind.
        5. If any existing destination file would be overwritten, an
           automatic pre-restore safety snapshot is taken first (a plain
           Backup-TetraItem call, tagged IsAutoPreRestoreSnapshot=$true).
           Backup-TetraItem never calls Restore-TetraBackup, so a safety
           snapshot can never itself trigger another safety snapshot.
        6. If a restore fails partway through, every already-modified
           destination is rolled back from that snapshot. Each rollback
           attempt is individually recorded (success or failure) - a
           rollback failure is never hidden, and the final thrown message
           explicitly states "RESTORE FAILED + ROLLBACK PARTIALLY FAILED"
           if any rollback attempt did not succeed. The system is never
           reported as "restored" if rollback was incomplete.

    KNOWN LIMITATION (documented, not implemented - consistent with the
    "no concurrency system for now" decision): no file-locking/mutex
    protection against two concurrent Tetra processes backing up/
    restoring the same category simultaneously. Not a realistic primary
    scenario for a single-user desktop tool.

    DEPENDENCIES:
        Config/PathHelpers.ps1, Config/Config.ps1, Config/ProductInfo.ps1,
        and Engine/LoggerEngine.ps1 must already be dot-sourced.
        Deliberately NOT dependent on ReportEngine.ps1.
.NOTES
    Module      : BackupEngine.ps1
    Layer       : Engine
    Build Phase : Phase 1 (post-Foundation-Freeze) - Backup Engine
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ============================================================
# FUNCTION: Get-TetraBackupCategories
# ============================================================
<#
.SYNOPSIS
    Returns the fixed set of valid backup categories.
.OUTPUTS
    System.String[]
#>
function Get-TetraBackupCategories {
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    return @('Registry', 'Services', 'Startup', 'PowerPlans', 'Drivers', 'Network', 'General')
}

# ============================================================
# FUNCTION: Resolve-TetraCanonicalPath (internal)
# ============================================================
<#
.SYNOPSIS
    Resolves a path to its canonical full path, safe for paths that do
    not yet exist.
.DESCRIPTION
    Uses GetUnresolvedProviderPathFromPSPath rather than
    [System.IO.Path]::GetFullPath(), because the latter resolves relative
    paths against .NET's Environment.CurrentDirectory, which can silently
    diverge from PowerShell's own $PWD. Unlike Resolve-Path, this does
    NOT require the path to already exist - required here since restore
    destinations may legitimately not exist yet.
.PARAMETER Path
    The path to canonicalize.
.OUTPUTS
    System.String
#>
function Resolve-TetraCanonicalPath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

# ============================================================
# FUNCTION: Get-TetraBackupDirectory (internal)
# ============================================================
function Get-TetraBackupDirectory {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    return (Get-TetraSiblingDirectory -CallerScriptRoot $PSScriptRoot -FolderName 'Backup')
}

# ============================================================
# FUNCTION: Get-TetraBackupCategoryDirectory (internal)
# ============================================================
function Get-TetraBackupCategoryDirectory {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Category
    )

    return (Join-Path -Path (Get-TetraBackupDirectory) -ChildPath $Category)
}

# ============================================================
# FUNCTION: Get-TetraBackupIdDirectory (internal)
# ============================================================
function Get-TetraBackupIdDirectory {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Category,

        [Parameter(Mandatory = $true)]
        [string]$BackupId
    )

    return (Join-Path -Path (Get-TetraBackupCategoryDirectory -Category $Category) -ChildPath $BackupId)
}

# ============================================================
# FUNCTION: Get-TetraBackupPayloadDirectory (internal)
# ============================================================
function Get-TetraBackupPayloadDirectory {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Category,

        [Parameter(Mandatory = $true)]
        [string]$BackupId
    )

    return (Join-Path -Path (Get-TetraBackupIdDirectory -Category $Category -BackupId $BackupId) -ChildPath 'payload')
}

# ============================================================
# FUNCTION: Get-TetraBackupManifestFilePath (internal)
# ============================================================
function Get-TetraBackupManifestFilePath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Category,

        [Parameter(Mandatory = $true)]
        [string]$BackupId
    )

    return (Join-Path -Path (Get-TetraBackupIdDirectory -Category $Category -BackupId $BackupId) -ChildPath 'manifest.json')
}

# ============================================================
# FUNCTION: Get-TetraProtectedDirectories (internal)
# ============================================================
<#
.SYNOPSIS
    Returns the canonical full paths of every directory BackupEngine must
    never treat as a valid backup source or restore destination.
#>
function Get-TetraProtectedDirectories {
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    $backupDir      = Get-TetraBackupDirectory
    $projectRoot    = Split-Path -Path $backupDir -Parent
    $protectedNames = @('Backup', 'Config', 'Engine', 'Bootstrap', 'Tests', 'Logs', 'Reports')

    return @($protectedNames | ForEach-Object { Resolve-TetraCanonicalPath -Path (Join-Path -Path $projectRoot -ChildPath $_) })
}

# ============================================================
# FUNCTION: Test-TetraPathIsWithinDirectory (internal)
# ============================================================
<#
.SYNOPSIS
    Canonical containment check: is Path equal to, or inside, DirectoryPath?
.DESCRIPTION
    Both inputs are canonicalized and trailing separators normalized
    before comparison, and the directory-path comparison requires a
    trailing separator match so "Backup2" can never falsely match a
    "Backup" containment check.
#>
function Test-TetraPathIsWithinDirectory {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$DirectoryPath
    )

    $canonicalPath = (Resolve-TetraCanonicalPath -Path $Path).TrimEnd('\', '/')
    $canonicalDir  = (Resolve-TetraCanonicalPath -Path $DirectoryPath).TrimEnd('\', '/')

    if ($canonicalPath -eq $canonicalDir) {
        return $true
    }

    return $canonicalPath.StartsWith($canonicalDir + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)
}

# ============================================================
# FUNCTION: Assert-TetraBackupSourceSafe (internal)
# ============================================================
<#
.SYNOPSIS
    Validates a backup source path exists, is a file, and is not inside
    a protected directory. Throws on any violation.
.OUTPUTS
    System.String - the canonical resolved path, if safe.
#>
function Assert-TetraBackupSourceSafe {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Source file does not exist or is not a file: '$Path'."
    }

    $canonicalPath = Resolve-TetraCanonicalPath -Path $Path

    foreach ($protectedDir in (Get-TetraProtectedDirectories)) {
        if (Test-TetraPathIsWithinDirectory -Path $canonicalPath -DirectoryPath $protectedDir) {
            throw "Source path '$Path' is inside a protected Tetra directory ('$protectedDir') and cannot be backed up."
        }
    }

    return $canonicalPath
}

# ============================================================
# FUNCTION: Assert-TetraRestoreDestinationSafe (internal)
# ============================================================
<#
.SYNOPSIS
    Validates a restore destination path is not inside a protected
    directory. Does NOT require the path to exist (a restore destination
    may legitimately have been deleted). Throws on any violation.
.OUTPUTS
    System.String - the canonical resolved path, if safe.
#>
function Assert-TetraRestoreDestinationSafe {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $canonicalPath = Resolve-TetraCanonicalPath -Path $Path

    foreach ($protectedDir in (Get-TetraProtectedDirectories)) {
        if (Test-TetraPathIsWithinDirectory -Path $canonicalPath -DirectoryPath $protectedDir) {
            throw "Restore destination '$Path' resolves inside a protected Tetra directory ('$protectedDir') and is not allowed."
        }
    }

    return $canonicalPath
}

# ============================================================
# FUNCTION: Resolve-TetraBackupPayloadItemPath (internal)
# ============================================================
<#
.SYNOPSIS
    Resolves a manifest item's StoredRelativePath to its real payload
    file location, verifying it cannot escape that backup's own payload
    directory.
.DESCRIPTION
    Manifests are persistent files and may have been manually edited -
    this validation is required even for Tetra's own manifests, not just
    hypothetically hostile ones. Rejects rooted/absolute paths outright
    (a legitimate StoredRelativePath is always relative, e.g.
    "item_0/file.txt"), then verifies the combined, canonicalized path
    still resolves inside the payload directory.
.OUTPUTS
    System.String - the canonical, verified-safe payload file path.
#>
function Resolve-TetraBackupPayloadItemPath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Category,

        [Parameter(Mandatory = $true)]
        [string]$BackupId,

        [Parameter(Mandatory = $true)]
        [string]$StoredRelativePath
    )

    if ([System.IO.Path]::IsPathRooted($StoredRelativePath)) {
        throw "Manifest item StoredRelativePath '$StoredRelativePath' must be relative, not absolute - refusing to use a potentially tampered manifest."
    }

    $payloadDir    = Get-TetraBackupPayloadDirectory -Category $Category -BackupId $BackupId
    $combinedPath  = Join-Path -Path $payloadDir -ChildPath $StoredRelativePath
    $canonicalPath = Resolve-TetraCanonicalPath -Path $combinedPath

    if (-not (Test-TetraPathIsWithinDirectory -Path $canonicalPath -DirectoryPath $payloadDir)) {
        throw "Manifest item StoredRelativePath '$StoredRelativePath' resolves outside its backup's payload directory - refusing to use a potentially tampered manifest."
    }

    return $canonicalPath
}

# ============================================================
# FUNCTION: New-TetraBackupId (internal)
# ============================================================
function New-TetraBackupId {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $timestamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd_HHmmss')
    $shortGuid = ([guid]::NewGuid().ToString('N')).Substring(0, 8)
    return "${timestamp}_${shortGuid}"
}

# ============================================================
# FUNCTION: Initialize-TetraBackupDirectory
# ============================================================
<#
.SYNOPSIS
    Ensures the Backup folder and all category subfolders exist.
.OUTPUTS
    System.String - the Backup directory path.
#>
function Initialize-TetraBackupDirectory {
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([string])]
    param()

    $backupDir = Get-TetraBackupDirectory
    Initialize-TetraDirectory -Path $backupDir | Out-Null

    foreach ($category in (Get-TetraBackupCategories)) {
        Initialize-TetraDirectory -Path (Get-TetraBackupCategoryDirectory -Category $category) | Out-Null
    }

    return $backupDir
}

# ============================================================
# FUNCTION: Test-TetraBackupManifestSchema (internal)
# ============================================================
<#
.SYNOPSIS
    Validates a parsed manifest object has every field required to be
    trusted, without trusting it blindly.
.OUTPUTS
    System.Management.Automation.PSCustomObject: IsValid, Errors
#>
function Test-TetraBackupManifestSchema {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object]$Manifest
    )

    $errors = [System.Collections.Generic.List[string]]::new()

    if ($null -eq $Manifest) {
        $errors.Add('Manifest is null.')
        return [PSCustomObject]@{ IsValid = $false; Errors = $errors }
    }

    foreach ($field in @('ManifestVersion', 'BackupId', 'Category', 'Items')) {
        if (-not ($Manifest.PSObject.Properties.Name -contains $field)) {
            $errors.Add("Missing required field '$field'.")
        }
    }

    if ($errors.Count -gt 0) {
        return [PSCustomObject]@{ IsValid = $false; Errors = $errors }
    }

    if ([string]::IsNullOrWhiteSpace($Manifest.ManifestVersion)) { $errors.Add('ManifestVersion is empty.') }
    if ([string]::IsNullOrWhiteSpace($Manifest.BackupId)) { $errors.Add('BackupId is empty.') }
    if ([string]::IsNullOrWhiteSpace($Manifest.Category)) { $errors.Add('Category is empty.') }

    $items = @($Manifest.Items)
    if ($items.Count -eq 0) {
        $errors.Add('Items contains no entries.')
    }
    else {
        $itemIndex = 0
        foreach ($item in $items) {
            foreach ($field in @('OriginalPath', 'StoredRelativePath', 'Sha256', 'SizeBytes')) {
                $hasField = ($null -ne $item) -and ($item.PSObject.Properties.Name -contains $field) -and (-not [string]::IsNullOrWhiteSpace([string]$item.$field))
                if (-not $hasField) {
                    $errors.Add("Item[$itemIndex] is missing or has an empty required field '$field'.")
                }
            }
            $itemIndex++
        }
    }

    return [PSCustomObject]@{
        IsValid = ($errors.Count -eq 0)
        Errors  = $errors
    }
}

# ============================================================
# FUNCTION: Backup-TetraItem
# ============================================================
<#
.SYNOPSIS
    Creates one atomic, versioned, integrity-verified backup of one or
    more explicit file paths.
.DESCRIPTION
    Validates ALL source paths before any write occurs. If any source is
    invalid, the entire call is rejected and nothing is created. If any
    failure occurs during copying, the partially-created backup folder is
    deleted so no misleading half-complete backup is ever left on disk.
.PARAMETER Path
    One or more file paths to back up.
.PARAMETER Category
    One of Get-TetraBackupCategories.
.PARAMETER Label
    Optional human-readable description.
.PARAMETER RequestedByModule
    Optional caller identifier for the manifest. Defaults to "Manual".
.PARAMETER IsAutoPreRestoreSnapshot
    Marks this backup as an automatic pre-restore safety snapshot
    (used internally by Restore-TetraBackup).
.OUTPUTS
    System.Management.Automation.PSCustomObject: Success, WhatIf,
    BackupId, Category, ItemCount, Manifest
#>
function Backup-TetraItem {
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string[]]$Path,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Registry', 'Services', 'Startup', 'PowerPlans', 'Drivers', 'Network', 'General')]
        [string]$Category,

        [Parameter(Mandatory = $false)]
        [string]$Label = '',

        [Parameter(Mandatory = $false)]
        [string]$RequestedByModule = 'Manual',

        [Parameter(Mandatory = $false)]
        [switch]$IsAutoPreRestoreSnapshot
    )

    $backupId  = New-TetraBackupId
    $startTime = Get-Date

    try {
        # Validate ALL sources first - reject the entire operation before
        # any write if any single source is invalid.
        $resolvedSources = [System.Collections.Generic.List[string]]::new()
        foreach ($sourcePath in $Path) {
            $resolvedSources.Add((Assert-TetraBackupSourceSafe -Path $sourcePath))
        }

        Write-TetraLog -Level 'Info' -Module 'BackupEngine' -Action 'BackupStarted' -Target $backupId `
            -Result 'Started' -Message "Starting backup of $($resolvedSources.Count) file(s) in category '$Category'." | Out-Null

        if (-not $PSCmdlet.ShouldProcess("$($resolvedSources.Count) file(s) -> Backup/$Category/$backupId", 'Create backup')) {
            Write-TetraLog -Level 'Info' -Module 'BackupEngine' -Action 'BackupStarted' -Target $backupId `
                -Result 'Skipped' -Message 'Backup skipped (WhatIf or declined) - no changes made.' | Out-Null

            return [PSCustomObject]@{
                Success  = $false
                WhatIf   = $true
                BackupId = $backupId
                Category = $Category
                Message  = 'No changes made (WhatIf or declined).'
            }
        }

        $categoryDir = Get-TetraBackupCategoryDirectory -Category $Category
        Initialize-TetraDirectory -Path $categoryDir | Out-Null

        $payloadDir = Get-TetraBackupPayloadDirectory -Category $Category -BackupId $backupId
        Initialize-TetraDirectory -Path $payloadDir | Out-Null

        $items     = [System.Collections.Generic.List[PSCustomObject]]::new()
        $itemIndex = 0

        foreach ($resolvedSource in $resolvedSources) {
            $itemFolder = "item_$itemIndex"
            $itemDir    = Join-Path -Path $payloadDir -ChildPath $itemFolder
            New-Item -Path $itemDir -ItemType Directory -Force | Out-Null

            $fileName           = Split-Path -Path $resolvedSource -Leaf
            $destinationPath    = Join-Path -Path $itemDir -ChildPath $fileName
            $storedRelativePath = "$itemFolder/$fileName"

            Copy-Item -LiteralPath $resolvedSource -Destination $destinationPath -Force

            $hash     = (Get-FileHash -LiteralPath $destinationPath -Algorithm SHA256).Hash
            $fileInfo = Get-Item -LiteralPath $destinationPath

            $items.Add([PSCustomObject]@{
                OriginalPath       = $resolvedSource
                StoredRelativePath = $storedRelativePath
                SizeBytes          = $fileInfo.Length
                Sha256             = $hash
                LastWriteTimeUtc   = $fileInfo.LastWriteTimeUtc.ToString('o')
            })

            $itemIndex++
        }

        $productInfo = Get-TetraProductInfo
        $metadata    = Get-TetraSystemMetadata

        $manifest = [PSCustomObject]@{
            ManifestVersion          = '1.0'
            BackupId                 = $backupId
            Category                 = $Category
            Label                    = $Label
            RequestedByModule        = $RequestedByModule
            IsAutoPreRestoreSnapshot = [bool]$IsAutoPreRestoreSnapshot
            CreatedUtc               = (Get-Date).ToUniversalTime().ToString('o')
            OperationId              = Get-TetraCurrentOperationId
            SessionId                = Get-TetraSessionId
            DeviceId                 = $metadata.DeviceId
            TetraVersion             = $productInfo.Version
            BuildNumber              = $productInfo.BuildNumber
            Items                    = $items
            TotalSizeBytes           = ($items | Measure-Object -Property SizeBytes -Sum).Sum
            ItemCount                = $items.Count
        }

        $manifestPath = Get-TetraBackupManifestFilePath -Category $Category -BackupId $backupId
        $manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $manifestPath -Encoding UTF8

        $durationMs = ((Get-Date) - $startTime).TotalMilliseconds

        Write-TetraLog -Level 'Success' -Module 'BackupEngine' -Action 'BackupCompleted' -Target $backupId `
            -Result 'Success' -Message "Backup completed: $($items.Count) file(s), $($manifest.TotalSizeBytes) byte(s)." `
            -DurationMs $durationMs | Out-Null

        return [PSCustomObject]@{
            Success   = $true
            WhatIf    = $false
            BackupId  = $backupId
            Category  = $Category
            ItemCount = $items.Count
            Manifest  = $manifest
        }
    }
    catch {
        # Never leave a misleading, half-complete backup folder behind.
        try {
            $partialBackupDir = Get-TetraBackupIdDirectory -Category $Category -BackupId $backupId
            if (Test-Path -LiteralPath $partialBackupDir) {
                Remove-Item -LiteralPath $partialBackupDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        catch {
            Write-Verbose "Backup-TetraItem: Failed to clean up partial backup folder - $($_.Exception.Message)"
        }

        Write-TetraLog -Level 'Error' -Module 'BackupEngine' -Action 'BackupFailed' -Target $backupId `
            -Result 'Failed' -Message $_.Exception.Message | Out-Null

        throw "Backup-TetraItem: Failed to create backup - $($_.Exception.Message)"
    }
}

# ============================================================
# FUNCTION: Get-TetraBackupList
# ============================================================
<#
.SYNOPSIS
    Returns a lightweight summary of existing backups, optionally
    filtered by category.
.DESCRIPTION
    Corrupted/unreadable manifests are skipped individually (logged via
    -Verbose) rather than failing the entire listing.
.OUTPUTS
    System.Management.Automation.PSCustomObject[], newest first.
#>
function Get-TetraBackupList {
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter(Mandatory = $false)]
        [ValidateSet('Registry', 'Services', 'Startup', 'PowerPlans', 'Drivers', 'Network', 'General')]
        [string]$Category
    )

    try {
        $categories = if ($Category) { @($Category) } else { Get-TetraBackupCategories }
        $results    = [System.Collections.Generic.List[PSCustomObject]]::new()

        foreach ($cat in $categories) {
            $categoryDir = Get-TetraBackupCategoryDirectory -Category $cat
            if (-not (Test-Path -LiteralPath $categoryDir)) {
                continue
            }

            $backupFolders = Get-ChildItem -LiteralPath $categoryDir -Directory -ErrorAction SilentlyContinue

            foreach ($folder in $backupFolders) {
                $manifestPath = Join-Path -Path $folder.FullName -ChildPath 'manifest.json'
                if (-not (Test-Path -LiteralPath $manifestPath)) {
                    continue
                }

                try {
                    $rawManifest    = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8
                    $parsedManifest = $rawManifest | ConvertFrom-Json

                    $results.Add([PSCustomObject]@{
                        BackupId                 = $parsedManifest.BackupId
                        Category                 = $parsedManifest.Category
                        Label                    = $parsedManifest.Label
                        CreatedUtc               = $parsedManifest.CreatedUtc
                        ItemCount                = $parsedManifest.ItemCount
                        TotalSizeBytes           = $parsedManifest.TotalSizeBytes
                        IsAutoPreRestoreSnapshot = [bool]$parsedManifest.IsAutoPreRestoreSnapshot
                        ManifestPath             = $manifestPath
                    })
                }
                catch {
                    Write-Verbose "Get-TetraBackupList: Skipping unreadable manifest '$manifestPath' - $($_.Exception.Message)"
                    continue
                }
            }
        }

        return @($results | Sort-Object -Property CreatedUtc -Descending)
    }
    catch {
        throw "Get-TetraBackupList: Failed to list backups - $($_.Exception.Message)"
    }
}

# ============================================================
# FUNCTION: Get-TetraBackupManifest
# ============================================================
<#
.SYNOPSIS
    Reads and schema-validates one backup's manifest. Never trusts
    manifest.json blindly.
.OUTPUTS
    System.Management.Automation.PSCustomObject - the validated manifest.
#>
function Get-TetraBackupManifest {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Registry', 'Services', 'Startup', 'PowerPlans', 'Drivers', 'Network', 'General')]
        [string]$Category,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$BackupId
    )

    try {
        $manifestPath = Get-TetraBackupManifestFilePath -Category $Category -BackupId $BackupId

        if (-not (Test-Path -LiteralPath $manifestPath)) {
            throw "No manifest found for backup '$BackupId' in category '$Category'."
        }

        $rawManifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8

        try {
            $parsedManifest = $rawManifest | ConvertFrom-Json
        }
        catch {
            throw "Manifest for backup '$BackupId' is not valid JSON and cannot be used."
        }

        # Normalize Items to always be an array - ConvertFrom-Json
        # collapses a single-element JSON array to a bare object, not a
        # 1-element array.
        if ($parsedManifest.PSObject.Properties.Name -contains 'Items') {
            $parsedManifest.Items = @($parsedManifest.Items)
        }

        $validation = Test-TetraBackupManifestSchema -Manifest $parsedManifest
        if (-not $validation.IsValid) {
            throw "Manifest for backup '$BackupId' is malformed or incomplete: $($validation.Errors -join ' | ')"
        }

        return $parsedManifest
    }
    catch {
        throw "Get-TetraBackupManifest: $($_.Exception.Message)"
    }
}

# ============================================================
# FUNCTION: Test-TetraBackupIntegrity
# ============================================================
<#
.SYNOPSIS
    Re-hashes every stored payload file and compares it against the
    manifest, per item.
.DESCRIPTION
    A tampered/escaping StoredRelativePath is caught per-item (marked
    invalid with a clear reason) rather than throwing for the whole
    check, so a report can show exactly which item is the problem.
.OUTPUTS
    System.Management.Automation.PSCustomObject: BackupId, Category,
    IsValid, TotalItems, ValidItems, InvalidItems, ItemResults[]
#>
function Test-TetraBackupIntegrity {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Registry', 'Services', 'Startup', 'PowerPlans', 'Drivers', 'Network', 'General')]
        [string]$Category,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$BackupId
    )

    Write-TetraLog -Level 'Info' -Module 'BackupEngine' -Action 'IntegrityCheckStarted' -Target $BackupId `
        -Result 'Started' -Message "Checking integrity of backup '$BackupId'." | Out-Null

    try {
        $manifest    = Get-TetraBackupManifest -Category $Category -BackupId $BackupId
        $itemResults = [System.Collections.Generic.List[PSCustomObject]]::new()

        foreach ($item in @($manifest.Items)) {
            $itemResult = [PSCustomObject]@{
                OriginalPath       = $item.OriginalPath
                StoredRelativePath = $item.StoredRelativePath
                IsValid            = $false
                Reason             = ''
            }

            try {
                $payloadPath = Resolve-TetraBackupPayloadItemPath -Category $Category -BackupId $BackupId -StoredRelativePath $item.StoredRelativePath

                if (-not (Test-Path -LiteralPath $payloadPath -PathType Leaf)) {
                    $itemResult.Reason = 'Stored payload file is missing.'
                }
                else {
                    $actualHash = (Get-FileHash -LiteralPath $payloadPath -Algorithm SHA256).Hash
                    $actualSize = (Get-Item -LiteralPath $payloadPath).Length

                    if ($actualHash -ne $item.Sha256) {
                        $itemResult.Reason = 'SHA-256 hash mismatch - payload file content has changed.'
                    }
                    elseif ($actualSize -ne [int64]$item.SizeBytes) {
                        $itemResult.Reason = 'File size mismatch.'
                    }
                    else {
                        $itemResult.IsValid = $true
                    }
                }
            }
            catch {
                $itemResult.Reason = $_.Exception.Message
            }

            $itemResults.Add($itemResult)
        }

        $validCount   = @($itemResults | Where-Object { $_.IsValid }).Count
        $invalidCount = $itemResults.Count - $validCount
        $overallValid = ($invalidCount -eq 0)

        $result = [PSCustomObject]@{
            BackupId     = $BackupId
            Category     = $Category
            IsValid      = $overallValid
            TotalItems   = $itemResults.Count
            ValidItems   = $validCount
            InvalidItems = $invalidCount
            ItemResults  = $itemResults
        }

        if ($overallValid) {
            Write-TetraLog -Level 'Success' -Module 'BackupEngine' -Action 'IntegrityCheckCompleted' -Target $BackupId `
                -Result 'Valid' -Message "All $($itemResults.Count) item(s) verified." | Out-Null
        }
        else {
            Write-TetraLog -Level 'Error' -Module 'BackupEngine' -Action 'IntegrityCheckFailed' -Target $BackupId `
                -Result 'Invalid' -Message "$invalidCount of $($itemResults.Count) item(s) failed verification." | Out-Null
        }

        return $result
    }
    catch {
        Write-TetraLog -Level 'Error' -Module 'BackupEngine' -Action 'IntegrityCheckFailed' -Target $BackupId `
            -Result 'Failed' -Message $_.Exception.Message | Out-Null

        throw "Test-TetraBackupIntegrity: Failed to verify backup '$BackupId' - $($_.Exception.Message)"
    }
}

# ============================================================
# FUNCTION: Restore-TetraBackup
# ============================================================
<#
.SYNOPSIS
    Restores a previous backup, with mandatory integrity verification,
    an automatic pre-restore safety snapshot, and automatic rollback if
    the restore fails partway through.
.DESCRIPTION
    See the file-level header for the full restore safety model. In
    summary: all validation (manifest schema, integrity, destination
    safety) happens first and is entirely read-only; a single
    ShouldProcess/ConfirmImpact=High gate covers the whole operation
    before any write; -WhatIf or a declined confirmation makes zero
    filesystem changes.
.PARAMETER Category
    The category the backup belongs to.
.PARAMETER BackupId
    The specific backup to restore.
.OUTPUTS
    System.Management.Automation.PSCustomObject: Success, WhatIf,
    BackupId, Category, ItemsRestored, PreRestoreSnapshotId
#>
function Restore-TetraBackup {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Registry', 'Services', 'Startup', 'PowerPlans', 'Drivers', 'Network', 'General')]
        [string]$Category,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$BackupId
    )

    Write-TetraLog -Level 'Info' -Module 'BackupEngine' -Action 'RestoreStarted' -Target $BackupId `
        -Result 'Started' -Message "Starting restore of backup '$BackupId' (category '$Category')." | Out-Null

    # ---- Phase 1: fully read-only validation (manifest, integrity,
    # destination safety) - no writes anywhere in this block. ----
    try {
        $manifest = Get-TetraBackupManifest -Category $Category -BackupId $BackupId

        $integrity = Test-TetraBackupIntegrity -Category $Category -BackupId $BackupId
        if (-not $integrity.IsValid) {
            $failedItems = (@($integrity.ItemResults) | Where-Object { -not $_.IsValid } | ForEach-Object { "$($_.OriginalPath) ($($_.Reason))" }) -join '; '
            throw "Integrity check failed for $($integrity.InvalidItems) of $($integrity.TotalItems) item(s): $failedItems. Restore aborted - zero changes were made."
        }

        # Validate EVERY destination and resolve EVERY payload path before
        # any modification begins.
        $restorePlan = [System.Collections.Generic.List[PSCustomObject]]::new()
        foreach ($item in @($manifest.Items)) {
            $safeDestination = Assert-TetraRestoreDestinationSafe -Path $item.OriginalPath
            $payloadPath      = Resolve-TetraBackupPayloadItemPath -Category $Category -BackupId $BackupId -StoredRelativePath $item.StoredRelativePath

            $restorePlan.Add([PSCustomObject]@{
                PayloadPath       = $payloadPath
                Destination       = $safeDestination
                DestinationExists = (Test-Path -LiteralPath $safeDestination -PathType Leaf)
            })
        }
    }
    catch {
        Write-TetraLog -Level 'Error' -Module 'BackupEngine' -Action 'RestoreFailed' -Target $BackupId `
            -Result 'Failed' -Message "$($_.Exception.Message) (validation only - no changes were made)" | Out-Null

        throw "Restore-TetraBackup: $($_.Exception.Message) No changes were made."
    }

    # ---- Phase 2: single confirmation gate for the WHOLE restore.
    # Must occur AFTER all read-only validation but BEFORE any write,
    # including the pre-restore snapshot itself. ----
    $target = "Backup '$BackupId' ($Category) - $($restorePlan.Count) file(s)"
    if (-not $PSCmdlet.ShouldProcess($target, 'Restore backup (will create a safety snapshot of any existing destination files first)')) {
        Write-TetraLog -Level 'Info' -Module 'BackupEngine' -Action 'RestoreStarted' -Target $BackupId `
            -Result 'Skipped' -Message 'Restore skipped (WhatIf or declined) - no changes made.' | Out-Null

        return [PSCustomObject]@{
            Success  = $false
            WhatIf   = $true
            BackupId = $BackupId
            Category = $Category
            Message  = 'No changes made (WhatIf or declined).'
        }
    }

    # ---- Phase 3: automatic pre-restore safety snapshot (only for
    # destinations that currently have a file to protect). ----
    $existingDestinations = @($restorePlan | Where-Object { $_.DestinationExists } | ForEach-Object { $_.Destination })

    $preRestoreSnapshot = $null
    if ($existingDestinations.Count -gt 0) {
        $preRestoreSnapshot = Backup-TetraItem -Path $existingDestinations -Category $Category `
            -Label "Pre-restore safety snapshot before restoring $BackupId" `
            -RequestedByModule 'BackupEngine' -IsAutoPreRestoreSnapshot
    }

    # ---- Phase 4: perform the restore, tracking progress for rollback. ----
    $restoredDestinations = [System.Collections.Generic.List[string]]::new()

    try {
        foreach ($planItem in $restorePlan) {
            $destinationDir = Split-Path -Path $planItem.Destination -Parent
            if (-not (Test-Path -LiteralPath $destinationDir)) {
                Initialize-TetraDirectory -Path $destinationDir | Out-Null
            }

            Copy-Item -LiteralPath $planItem.PayloadPath -Destination $planItem.Destination -Force
            $restoredDestinations.Add($planItem.Destination)
        }
    }
    catch {
        $restoreError = $_.Exception.Message

        # ---- Phase 5: rollback everything already modified. ----
        Write-TetraLog -Level 'Warning' -Module 'BackupEngine' -Action 'RollbackStarted' -Target $BackupId `
            -Result 'Started' -Message "Restore failed after modifying $($restoredDestinations.Count) file(s); attempting rollback. Error: $restoreError" | Out-Null

        $rollbackResults = [System.Collections.Generic.List[PSCustomObject]]::new()

        foreach ($modifiedDestination in $restoredDestinations) {
            $rollbackEntry = [PSCustomObject]@{
                Destination = $modifiedDestination
                Success     = $false
                Reason      = ''
            }

            if ($null -eq $preRestoreSnapshot) {
                # Destination did not exist before restore (it was newly
                # created, not overwritten) - there is nothing to roll
                # back to. Recorded honestly, not silently skipped.
                $rollbackEntry.Reason = 'No pre-restore snapshot exists (destination did not previously exist) - nothing to roll back to.'
            }
            else {
                try {
                    $snapshotItem = @($preRestoreSnapshot.Manifest.Items) | Where-Object { $_.OriginalPath -eq $modifiedDestination } | Select-Object -First 1

                    if ($null -eq $snapshotItem) {
                        throw 'No pre-restore snapshot entry found for this destination.'
                    }

                    $snapshotPayloadPath = Resolve-TetraBackupPayloadItemPath -Category $Category -BackupId $preRestoreSnapshot.BackupId -StoredRelativePath $snapshotItem.StoredRelativePath
                    Copy-Item -LiteralPath $snapshotPayloadPath -Destination $modifiedDestination -Force
                    $rollbackEntry.Success = $true
                }
                catch {
                    $rollbackEntry.Reason = $_.Exception.Message
                }
            }

            $rollbackResults.Add($rollbackEntry)

            Write-TetraLog -Level $(if ($rollbackEntry.Success) { 'Info' } else { 'Error' }) -Module 'BackupEngine' `
                -Action 'RollbackStarted' -Target $modifiedDestination `
                -Result $(if ($rollbackEntry.Success) { 'Success' } else { 'Failed' }) `
                -Message $(if ($rollbackEntry.Success) { 'File rolled back successfully.' } else { "Rollback failed: $($rollbackEntry.Reason)" }) | Out-Null
        }

        $rollbackFailures = @($rollbackResults | Where-Object { -not $_.Success })

        if ($rollbackFailures.Count -gt 0) {
            Write-TetraLog -Level 'Error' -Module 'BackupEngine' -Action 'RollbackFailed' -Target $BackupId `
                -Result 'PartiallyFailed' -Message "$($rollbackFailures.Count) of $($rollbackResults.Count) file(s) could not be rolled back." | Out-Null
        }
        elseif ($rollbackResults.Count -gt 0) {
            Write-TetraLog -Level 'Info' -Module 'BackupEngine' -Action 'RollbackCompleted' -Target $BackupId `
                -Result 'Success' -Message "All $($rollbackResults.Count) modified file(s) were successfully rolled back." | Out-Null
        }

        Write-TetraLog -Level 'Error' -Module 'BackupEngine' -Action 'RestoreFailed' -Target $BackupId `
            -Result 'Failed' -Message $restoreError | Out-Null

        if ($rollbackFailures.Count -gt 0) {
            $failedPaths = ($rollbackFailures | ForEach-Object { $_.Destination }) -join ', '
            $rolledBackCount = $rollbackResults.Count - $rollbackFailures.Count
            throw "RESTORE FAILED + ROLLBACK PARTIALLY FAILED - $rolledBackCount of $($rollbackResults.Count) file(s) were rolled back successfully; the following $($rollbackFailures.Count) file(s) could NOT be rolled back and may be in an inconsistent state: $failedPaths. Original restore error: $restoreError"
        }
        else {
            throw "RESTORE FAILED - all $($restoredDestinations.Count) already-modified file(s) were successfully rolled back to their pre-restore state. Original restore error: $restoreError"
        }
    }

    # ---- Success ----
    Write-TetraLog -Level 'Success' -Module 'BackupEngine' -Action 'RestoreCompleted' -Target $BackupId `
        -Result 'Success' -Message "Restored $($restoredDestinations.Count) file(s) successfully." | Out-Null

    return [PSCustomObject]@{
        Success              = $true
        WhatIf               = $false
        BackupId             = $BackupId
        Category             = $Category
        ItemsRestored        = $restoredDestinations.Count
        PreRestoreSnapshotId = if ($preRestoreSnapshot) { $preRestoreSnapshot.BackupId } else { $null }
    }
}

# ============================================================
# FUNCTION: Remove-TetraExpiredBackups
# ============================================================
<#
.SYNOPSIS
    Removes backups beyond the configured retention count, per category.
.DESCRIPTION
    Normal backups and automatic pre-restore snapshots are retained
    independently (same limit applied to each group), and the effective
    keep-count is never allowed to drop below 1 when backups of that kind
    exist. If Backup.BackupRetentionCount is invalid (missing, non-
    numeric, or <= 0), cleanup is skipped entirely for safety rather than
    risking deletion of every backup under a misconfigured value.
.PARAMETER Category
    Optional - restricts cleanup to one category. Defaults to all.
.OUTPUTS
    System.Management.Automation.PSCustomObject[]: one summary per
    category processed.
#>
function Remove-TetraExpiredBackups {
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter(Mandatory = $false)]
        [ValidateSet('Registry', 'Services', 'Startup', 'PowerPlans', 'Drivers', 'Network', 'General')]
        [string]$Category
    )

    try {
        $categories          = if ($Category) { @($Category) } else { Get-TetraBackupCategories }
        $configuredRetention = Get-TetraConfigValueOrDefault -Path 'Backup.BackupRetentionCount' -Default 10

        $retentionIsValid = $true
        $retentionCount   = 0
        try {
            $retentionCount = [int]$configuredRetention
        }
        catch {
            $retentionIsValid = $false
        }
        if ($retentionCount -le 0) {
            $retentionIsValid = $false
        }

        $summaries = [System.Collections.Generic.List[PSCustomObject]]::new()

        if (-not $retentionIsValid) {
            Write-TetraLog -Level 'Warning' -Module 'BackupEngine' -Action 'RetentionCleanup' -Target 'AllCategories' `
                -Result 'Skipped' -Message "Configured Backup.BackupRetentionCount ('$configuredRetention') is invalid - skipping cleanup entirely rather than risk deleting backups under an unsafe setting." | Out-Null

            foreach ($cat in $categories) {
                $summaries.Add([PSCustomObject]@{
                    Category           = $cat
                    DeletedCount       = 0
                    RetainedCount      = @(Get-TetraBackupList -Category $cat).Count
                    RetentionLimitUsed = $null
                    Skipped            = $true
                })
            }

            return $summaries.ToArray()
        }

        # Never allow the effective keep-count to drop below 1.
        $keepCount = [Math]::Max(1, $retentionCount)

        foreach ($cat in $categories) {
            $allBackups = Get-TetraBackupList -Category $cat

            $normalBackups = @($allBackups | Where-Object { -not $_.IsAutoPreRestoreSnapshot } | Sort-Object -Property CreatedUtc -Descending)
            $autoBackups   = @($allBackups | Where-Object { $_.IsAutoPreRestoreSnapshot } | Sort-Object -Property CreatedUtc -Descending)

            $toDelete = @($normalBackups | Select-Object -Skip $keepCount) + @($autoBackups | Select-Object -Skip $keepCount)

            $deletedCount = 0
            foreach ($backupToDelete in $toDelete) {
                $backupIdDir = Get-TetraBackupIdDirectory -Category $cat -BackupId $backupToDelete.BackupId

                if ($PSCmdlet.ShouldProcess($backupIdDir, 'Delete expired backup')) {
                    Remove-Item -LiteralPath $backupIdDir -Recurse -Force -ErrorAction SilentlyContinue
                    $deletedCount++

                    Write-TetraLog -Level 'Info' -Module 'BackupEngine' -Action 'RetentionCleanup' -Target $backupToDelete.BackupId `
                        -Result 'Deleted' -Message "Deleted expired backup in category '$cat' (retention limit: $keepCount)." | Out-Null
                }
            }

            $summaries.Add([PSCustomObject]@{
                Category           = $cat
                DeletedCount       = $deletedCount
                RetainedCount      = ($normalBackups.Count + $autoBackups.Count - $deletedCount)
                RetentionLimitUsed = $keepCount
                Skipped            = $false
            })
        }

        return $summaries.ToArray()
    }
    catch {
        throw "Remove-TetraExpiredBackups: Failed to clean up expired backups - $($_.Exception.Message)"
    }
}

# ============================================================
# MODULE API SURFACE
# ============================================================
# NOTE: documented convention, not an enforced boundary (see
# Config/PathHelpers.ps1 for the full explanation).
#
# Public Functions:
#   - Get-TetraBackupCategories
#   - Initialize-TetraBackupDirectory (called by Bootstrap)
#   - Backup-TetraItem
#   - Get-TetraBackupList
#   - Get-TetraBackupManifest
#   - Test-TetraBackupIntegrity
#   - Restore-TetraBackup
#   - Remove-TetraExpiredBackups
#
# Internal Functions (implementation details):
#   - Resolve-TetraCanonicalPath
#   - Get-TetraBackupDirectory
#   - Get-TetraBackupCategoryDirectory
#   - Get-TetraBackupIdDirectory
#   - Get-TetraBackupPayloadDirectory
#   - Get-TetraBackupManifestFilePath
#   - Get-TetraProtectedDirectories
#   - Test-TetraPathIsWithinDirectory
#   - Assert-TetraBackupSourceSafe
#   - Assert-TetraRestoreDestinationSafe
#   - Resolve-TetraBackupPayloadItemPath
#   - New-TetraBackupId
#   - Test-TetraBackupManifestSchema
