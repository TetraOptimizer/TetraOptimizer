#Requires -Version 5.1
<#
.SYNOPSIS
    Tetra Optimizer - Knowledge Base Engine
.DESCRIPTION
    Loads, caches, and validates the profile-aware Knowledge Base -
    reference facts about Windows components (Processes, Services,
    Startup, Drivers, Registry, Security) that the future Analyzer/Policy
    Engine will combine with live system state and a selected Profile to
    produce explainable recommendations.

    RESPONSIBILITY (single):
        Own loading, caching, and structural/referential validation of
        Data/*.json. Nothing else.

    THIS FILE MUST NEVER:
        - Contain profile-specific hardcoded decisions (no
          "if Profile -eq Gaming then recommend X"). Every item's
          RecommendedProfiles/PreserveForProfiles/IsProtected value is
          DATA read from JSON - this file only loads and validates it,
          it never interprets what a Profile should do with it. That
          reasoning belongs to the future Analyzer/Policy Engine, not here.
        - Print UI (no Write-Host). Engine layer.
        - Interact with the live Windows system in any way.

    KNOWLEDGE BASE SCHEMA (one JSON array per category file,
    Data/<Category>.json):
        Id                          : string, unique across the ENTIRE
                                       knowledge base (not just its own
                                       category - dependencies legitimately
                                       cross categories, e.g. a Process
                                       depending on a Service)
        Category                    : string, must match the file's own category
        Name                        : string, human-readable
        SystemIdentifier            : string, the actual service/process/
                                       registry-path/etc. name this entry
                                       describes
        Description, Notes          : optional free text
        Importance                  : Critical | High | Medium | Low
        RiskLevel                   : Critical | High | Medium | Low
        Reversible                  : bool
        Dependencies                : string[] - other Ids (any category)
                                       this item depends on or relates to
        RecommendedProfiles         : string[] - profiles (from
                                       Get-TetraKnownProfiles) where a
                                       change is commonly appropriate
        PreserveForProfiles         : string[] - profiles where this item
                                       should be explicitly protected/kept
        PerformanceImpact           : None | Low | Medium | High
        SecurityImpact              : None | Low | Medium | High
        IsProtected                 : bool - hard safety floor
        RequiresAdditionalValidation: bool - flags items where the future
                                       Analyzer needs extra system-state
                                       checks before recommending anything

    SAFETY INVARIANT ENFORCED BY VALIDATION (a data-integrity check, not
    a policy decision - this file only verifies the invariant holds, it
    does not decide it): an item with IsProtected=true must have an
    empty RecommendedProfiles list.

    VALIDATION SCOPE, PRECISELY:
        Test-TetraKnowledgeBaseSchema validates ONE category in isolation
        (structural fields, enum values, types, the IsProtected
        invariant, duplicate Ids within that file). It deliberately does
        NOT validate that Dependencies resolve, because a single
        category cannot know about other categories' Ids, and
        dependencies are legitimately cross-category.
        Test-TetraKnowledgeBaseIntegrity validates ALL SIX categories
        together and additionally checks that every Dependencies entry,
        across the whole knowledge base, resolves to a real Id somewhere
        in it. This two-tier design avoids false "unknown dependency"
        errors that a naive per-category-only check would produce.

    POWERSHELL 5.1 COLLECTION SAFETY:
        ConvertFrom-Json collapses a single-element JSON array to a bare
        scalar object, not a 1-element array (the same class of issue
        already found and fixed in Config.ps1's Set-TetraConfigValue).
        Every array-valued field read in this file (Dependencies,
        RecommendedProfiles, PreserveForProfiles, and the top-level
        parsed item list itself) is defensively wrapped in @() before
        use, proactively, rather than waiting to be bitten by it again.

    DEPENDENCIES:
        Config/PathHelpers.ps1 and Engine/LoggerEngine.ps1 must already
        be dot-sourced. Deliberately NOT dependent on Config.ps1,
        ReportEngine.ps1, BackupEngine.ps1, or Core/Orchestrator.ps1.
.NOTES
    Module      : KnowledgeBaseEngine.ps1
    Layer       : Engine
    Build Phase : Phase 2 - Data / Knowledge Base
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Cache: Category name -> array of loaded/validated items.
$Script:TetraKnowledgeBaseCache = @{}

# ============================================================
# FUNCTION: Get-TetraKnowledgeBaseCategories
# ============================================================
<#
.SYNOPSIS
    Returns the fixed set of valid Knowledge Base categories.
.OUTPUTS
    System.String[]
#>
function Get-TetraKnowledgeBaseCategories {
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    return @('Processes', 'Services', 'Startup', 'Drivers', 'Registry', 'Security')
}

# ============================================================
# FUNCTION: Get-TetraKnownProfiles
# ============================================================
<#
.SYNOPSIS
    Returns the fixed set of known optimization profiles.
.DESCRIPTION
    Used to validate that every item's RecommendedProfiles and
    PreserveForProfiles values reference a real profile. Adding a new
    profile later means adding it here and to the Analyzer/Policy Engine
    when built - it does not require redesigning the Knowledge Base
    schema itself.
.OUTPUTS
    System.String[]
#>
function Get-TetraKnownProfiles {
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    return @('Gaming', 'Office', 'Balanced', 'Custom')
}

# ============================================================
# FUNCTION: Get-TetraKnowledgeBaseDirectory (internal)
# ============================================================
function Get-TetraKnowledgeBaseDirectory {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    return (Get-TetraSiblingDirectory -CallerScriptRoot $PSScriptRoot -FolderName 'Data')
}

# ============================================================
# FUNCTION: Get-TetraKnowledgeBaseFilePath (internal)
# ============================================================
function Get-TetraKnowledgeBaseFilePath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Category
    )

    return (Join-Path -Path (Get-TetraKnowledgeBaseDirectory) -ChildPath "$Category.json")
}

# ============================================================
# FUNCTION: Initialize-TetraKnowledgeBaseDirectory
# ============================================================
<#
.SYNOPSIS
    Ensures the Data folder exists on disk.
.OUTPUTS
    System.String - the (now guaranteed to exist) Data directory path.
#>
function Initialize-TetraKnowledgeBaseDirectory {
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([string])]
    param()

    return (Initialize-TetraDirectory -Path (Get-TetraKnowledgeBaseDirectory))
}

# ============================================================
# FUNCTION: Test-TetraKnowledgeBaseItemSchema (internal)
# ============================================================
<#
.SYNOPSIS
    Validates a single parsed knowledge-base item's structural fields,
    enum values, types, and the IsProtected safety invariant.
.DESCRIPTION
    Pure structural validation - no analysis, no profile decisions.
    Dependency resolution is intentionally NOT checked here (see file
    header) - pass -KnownIds only when the caller has the full,
    whole-knowledge-base Id set available (Test-TetraKnowledgeBaseIntegrity).
.PARAMETER Item
    The parsed item to validate.
.PARAMETER ExpectedCategory
    The category this item is expected to belong to (its file's category).
.PARAMETER KnownIds
    Optional. When supplied, Dependencies entries are checked against
    this full set; when omitted, dependency resolution is skipped.
.OUTPUTS
    System.Management.Automation.PSCustomObject: IsValid, Errors
#>
function Test-TetraKnowledgeBaseItemSchema {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object]$Item,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedCategory,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [string[]]$KnownIds = $null
    )

    $errors        = [System.Collections.Generic.List[string]]::new()
    $validSeverity = @('Critical', 'High', 'Medium', 'Low')
    $validImpact   = @('None', 'Low', 'Medium', 'High')
    $knownProfiles = Get-TetraKnownProfiles

    if ($null -eq $Item) {
        $errors.Add('Item is null.')
        return [PSCustomObject]@{ IsValid = $false; Errors = $errors }
    }

    $requiredFields = @('Id', 'Category', 'Name', 'SystemIdentifier', 'Importance', 'RiskLevel', 'Reversible', 'Dependencies', 'RecommendedProfiles', 'PreserveForProfiles', 'PerformanceImpact', 'SecurityImpact', 'IsProtected', 'RequiresAdditionalValidation')
    foreach ($field in $requiredFields) {
        if (-not ($Item.PSObject.Properties.Name -contains $field)) {
            $errors.Add("Missing required field '$field'.")
        }
    }

    if ($errors.Count -gt 0) {
        return [PSCustomObject]@{ IsValid = $false; Errors = $errors }
    }

    if ([string]::IsNullOrWhiteSpace($Item.Id)) { $errors.Add('Id is empty.') }
    if ([string]::IsNullOrWhiteSpace($Item.Name)) { $errors.Add('Name is empty.') }
    if ([string]::IsNullOrWhiteSpace($Item.SystemIdentifier)) { $errors.Add('SystemIdentifier is empty.') }

    if ($Item.Category -ne $ExpectedCategory) {
        $errors.Add("Category '$($Item.Category)' does not match this file's expected category '$ExpectedCategory'.")
    }

    if ($validSeverity -notcontains $Item.Importance) {
        $errors.Add("Importance '$($Item.Importance)' is not one of: $($validSeverity -join ', ').")
    }
    if ($validSeverity -notcontains $Item.RiskLevel) {
        $errors.Add("RiskLevel '$($Item.RiskLevel)' is not one of: $($validSeverity -join ', ').")
    }
    if ($validImpact -notcontains $Item.PerformanceImpact) {
        $errors.Add("PerformanceImpact '$($Item.PerformanceImpact)' is not one of: $($validImpact -join ', ').")
    }
    if ($validImpact -notcontains $Item.SecurityImpact) {
        $errors.Add("SecurityImpact '$($Item.SecurityImpact)' is not one of: $($validImpact -join ', ').")
    }

    if ($Item.Reversible -isnot [bool]) { $errors.Add('Reversible must be a boolean.') }
    if ($Item.IsProtected -isnot [bool]) { $errors.Add('IsProtected must be a boolean.') }
    if ($Item.RequiresAdditionalValidation -isnot [bool]) { $errors.Add('RequiresAdditionalValidation must be a boolean.') }

    # Defensive @() wrapping - see file header note on single-element
    # JSON array collapse under PowerShell 5.1.
    $recommendedProfiles = @($Item.RecommendedProfiles)
    $preserveForProfiles = @($Item.PreserveForProfiles)
    $dependencies        = @($Item.Dependencies)

    foreach ($profile in $recommendedProfiles) {
        if ($knownProfiles -notcontains $profile) {
            $errors.Add("RecommendedProfiles contains unknown profile '$profile'.")
        }
    }
    foreach ($profile in $preserveForProfiles) {
        if ($knownProfiles -notcontains $profile) {
            $errors.Add("PreserveForProfiles contains unknown profile '$profile'.")
        }
    }

    # Safety invariant: a protected item must never be recommended for change.
    if (($Item.IsProtected -eq $true) -and ($recommendedProfiles.Count -gt 0)) {
        $errors.Add("Item is IsProtected=true but has a non-empty RecommendedProfiles ($($recommendedProfiles -join ', ')) - a protected item must never be recommended for modification.")
    }

    if ($null -ne $KnownIds) {
        foreach ($dependencyId in $dependencies) {
            if ($KnownIds -notcontains $dependencyId) {
                $errors.Add("Dependencies references unknown Id '$dependencyId'.")
            }
        }
    }

    return [PSCustomObject]@{
        IsValid = ($errors.Count -eq 0)
        Errors  = $errors
    }
}

# ============================================================
# FUNCTION: Test-TetraKnowledgeBaseSchema
# ============================================================
<#
.SYNOPSIS
    Validates one category's JSON file: file exists, is valid JSON,
    contains at least one item, every item passes structural validation,
    and no Id is duplicated within the file.
.DESCRIPTION
    Does NOT check that Dependencies resolve (see file header - that
    requires the whole knowledge base and is Test-TetraKnowledgeBaseIntegrity's
    job).
.PARAMETER Category
    One of Get-TetraKnowledgeBaseCategories.
.OUTPUTS
    System.Management.Automation.PSCustomObject: Category, IsValid,
    ItemCount, Errors
#>
function Test-TetraKnowledgeBaseSchema {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Processes', 'Services', 'Startup', 'Drivers', 'Registry', 'Security')]
        [string]$Category
    )

    $filePath = Get-TetraKnowledgeBaseFilePath -Category $Category
    $errors   = [System.Collections.Generic.List[string]]::new()

    if (-not (Test-Path -LiteralPath $filePath)) {
        $errors.Add("Knowledge base file not found: '$filePath'.")
        return [PSCustomObject]@{ Category = $Category; IsValid = $false; ItemCount = 0; Errors = $errors }
    }

    try {
        $rawContent  = Get-Content -LiteralPath $filePath -Raw -Encoding UTF8
        $parsedItems = ConvertFrom-Json -InputObject $rawContent
        
    }
    catch {
        $errors.Add("File is not valid JSON: $($_.Exception.Message)")
        return [PSCustomObject]@{ Category = $Category; IsValid = $false; ItemCount = 0; Errors = $errors }
    }

    if ($parsedItems.Count -eq 0) {
        $errors.Add('Knowledge base file contains zero items.')
        return [PSCustomObject]@{ Category = $Category; IsValid = $false; ItemCount = 0; Errors = $errors }
    }

    $seenIds  = [System.Collections.Generic.HashSet[string]]::new()
    $itemIndex = 0

    foreach ($item in $parsedItems) {
        $itemValidation = Test-TetraKnowledgeBaseItemSchema -Item $item -ExpectedCategory $Category

        if (-not $itemValidation.IsValid) {
            $itemLabel = if ($item -and ($item.PSObject.Properties.Name -contains 'Id')) { $item.Id } else { "index $itemIndex" }
            foreach ($itemError in $itemValidation.Errors) {
                $errors.Add("Item[$itemIndex] ('$itemLabel'): $itemError")
            }
        }
        elseif (-not $seenIds.Add($item.Id)) {
            $errors.Add("Item[$itemIndex]: duplicate Id '$($item.Id)' within category '$Category'.")
        }

        $itemIndex++
    }

    return [PSCustomObject]@{
        Category  = $Category
        IsValid   = ($errors.Count -eq 0)
        ItemCount = $parsedItems.Count
        Errors    = $errors
    }
}

# ============================================================
# FUNCTION: Test-TetraKnowledgeBaseIntegrity
# ============================================================
<#
.SYNOPSIS
    Validates every category's knowledge base file AND that every
    Dependencies reference, across the whole knowledge base, resolves to
    a real Id somewhere in it (including cross-category references).
.OUTPUTS
    System.Management.Automation.PSCustomObject: IsValid, TotalItemCount,
    CategoryResults, DependencyErrors
#>
function Test-TetraKnowledgeBaseIntegrity {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param()

    $categoryResults = [System.Collections.Generic.List[PSCustomObject]]::new()
    $allItemsById    = @{}

    foreach ($category in (Get-TetraKnowledgeBaseCategories)) {
        $categoryResult = Test-TetraKnowledgeBaseSchema -Category $category
        $categoryResults.Add($categoryResult)

        if ($categoryResult.IsValid) {
            $filePath   = Get-TetraKnowledgeBaseFilePath -Category $category
            $rawContent = Get-Content -LiteralPath $filePath -Raw -Encoding UTF8
            $parsed = ConvertFrom-Json -InputObject $rawContent
$items = @($parsed)

foreach ($item in $items) {
    if ($item -is [System.Array]) {
        foreach ($realItem in $item) {
            $allItemsById[$realItem.Id] = $realItem
        }
    }
    else {
        $allItemsById[$item.Id] = $item
    }
}
        }
    }

    $dependencyErrors = [System.Collections.Generic.List[string]]::new()

    $anyCategoryInvalid = [bool](
        @($categoryResults | Where-Object { -not $_.IsValid }).Count -gt 0
    )

    if (-not $anyCategoryInvalid) {
        foreach ($item in $allItemsById.Values) {

            $dependencies = @($item.Dependencies)

            foreach ($dependencyId in $dependencies) {
                if (-not $allItemsById.ContainsKey($dependencyId)) {
                    $dependencyErrors.Add(
                        "Item '$($item.Id)' ($($item.Category)) references unknown dependency Id '$dependencyId'."
                    )
                }
            }
        }
    }

    $isValid = (-not $anyCategoryInvalid) -and ($dependencyErrors.Count -eq 0)

    return [PSCustomObject]@{
        IsValid          = $isValid
        TotalItemCount   = ($categoryResults | Measure-Object -Property ItemCount -Sum).Sum
        CategoryResults  = $categoryResults
        DependencyErrors = $dependencyErrors
    }
}

# ============================================================
# FUNCTION: Get-TetraKnowledgeBaseItems
# ============================================================
<#
.SYNOPSIS
    Loads (and caches) every validated item for a category.
.DESCRIPTION
    Throws if the category's JSON file fails schema validation - this
    function never returns unvalidated or partially-invalid data.
.PARAMETER Category
    One of Get-TetraKnowledgeBaseCategories.
.PARAMETER Refresh
    Forces a re-read from disk instead of returning the cached value.
.OUTPUTS
    System.Management.Automation.PSCustomObject[]
#>
function Get-TetraKnowledgeBaseItems {
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Processes', 'Services', 'Startup', 'Drivers', 'Registry', 'Security')]
        [string]$Category,

        [Parameter(Mandatory = $false)]
        [switch]$Refresh
    )

    try {
        if (-not $Refresh -and $Script:TetraKnowledgeBaseCache.ContainsKey($Category)) {
            return $Script:TetraKnowledgeBaseCache[$Category]
        }

        $validation = Test-TetraKnowledgeBaseSchema -Category $Category
        if (-not $validation.IsValid) {
            throw "Knowledge base category '$Category' failed validation: $($validation.Errors -join ' | ')"
        }

        $filePath   = Get-TetraKnowledgeBaseFilePath -Category $Category
        $rawContent = Get-Content -LiteralPath $filePath -Raw -Encoding UTF8
        $parsedItems = ConvertFrom-Json -InputObject $rawContent
        $items = [System.Collections.Generic.List[PSCustomObject]]::new()
        foreach ($item in $parsedItems) {
            $items.Add($item)
        }
        $items = $items.ToArray()

        $Script:TetraKnowledgeBaseCache[$Category] = $items
        return $items
    }
    catch {
        Write-TetraLog -Level 'Error' -Module 'KnowledgeBaseEngine' -Action 'LoadKnowledgeBase' -Target $Category `
            -Result 'Failed' -Message $_.Exception.Message | Out-Null

        throw "Get-TetraKnowledgeBaseItems: Failed to load category '$Category' - $($_.Exception.Message)"
    }
}

# ============================================================
# FUNCTION: Get-TetraKnowledgeBaseItem
# ============================================================
<#
.SYNOPSIS
    Retrieves a single item by Id from a specific category.
.PARAMETER Category
    One of Get-TetraKnowledgeBaseCategories.
.PARAMETER Id
    The item's Id.
.OUTPUTS
    System.Management.Automation.PSCustomObject or $null if not found.
#>
function Get-TetraKnowledgeBaseItem {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Processes', 'Services', 'Startup', 'Drivers', 'Registry', 'Security')]
        [string]$Category,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Id
    )

    $items = Get-TetraKnowledgeBaseItems -Category $Category
    return ($items | Where-Object { $_.Id -eq $Id } | Select-Object -First 1)
}

# ============================================================
# MODULE API SURFACE
# ============================================================
# NOTE: documented convention, not an enforced boundary (see
# Config/PathHelpers.ps1 for the full explanation).
#
# Public Functions:
#   - Get-TetraKnowledgeBaseCategories
#   - Get-TetraKnownProfiles
#   - Initialize-TetraKnowledgeBaseDirectory (called by Bootstrap)
#   - Test-TetraKnowledgeBaseSchema
#   - Test-TetraKnowledgeBaseIntegrity
#   - Get-TetraKnowledgeBaseItems
#   - Get-TetraKnowledgeBaseItem
#
# Internal Functions:
#   - Get-TetraKnowledgeBaseDirectory
#   - Get-TetraKnowledgeBaseFilePath
#   - Test-TetraKnowledgeBaseItemSchema
