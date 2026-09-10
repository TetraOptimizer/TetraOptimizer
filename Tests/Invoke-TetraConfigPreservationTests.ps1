#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$ConfigScriptPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($ConfigScriptPath)) {
    $ConfigScriptPath = Join-Path (Split-Path -Path $PSScriptRoot -Parent) 'Config\Config.ps1'
}
$sourcePath = (Resolve-Path -LiteralPath $ConfigScriptPath).ProviderPath
$tempParent = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd([char[]]'\/')
$runName = 'TetraConfigPreservation-' + [guid]::NewGuid().ToString('N')
$runRoot = Join-Path $tempParent $runName
[System.IO.Directory]::CreateDirectory($runRoot) | Out-Null
$script:passed = 0
$script:failed = 0
$script:caseNumber = 0

function Test-Case {
    param([string]$Name, [scriptblock]$Body)
    $script:caseNumber++
    $caseRoot = Join-Path $runRoot ('case-' + $script:caseNumber)
    [System.IO.Directory]::CreateDirectory($caseRoot) | Out-Null
    # Load the real configuration implementation in its own module session.
    # Only filesystem location and the directory helper are redirected.
    $module = New-Module -ArgumentList $sourcePath,$caseRoot -ScriptBlock {
        param($implementationPath, $fixturePath)
        . $implementationPath
        $script:FixtureDirectory = $fixturePath
        function Get-TetraConfigDirectory { return $script:FixtureDirectory }
        function Initialize-TetraDirectory {
            [CmdletBinding(SupportsShouldProcess=$true)]
            param([string]$Path)
            if ([System.IO.Path]::GetFullPath($Path) -ne $script:FixtureDirectory) {
                throw 'Test attempted to initialize a directory outside its fixture.'
            }
            if ($PSCmdlet.ShouldProcess($Path, 'Create fixture directory')) {
                [System.IO.Directory]::CreateDirectory($Path) | Out-Null
            }
            return $Path
        }
        function Assert {
            param([bool]$Condition, [string]$Message)
            if (-not $Condition) { throw $Message }
        }
        function FileHash {
            param([string]$Path)
            return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
        }
        function New-PersonalFixture {
            param([switch]$ReferenceOnly, [switch]$LiveOnly)
            $referencePath = Get-TetraDefaultConfigFilePath
            $livePath = Get-TetraConfigFilePath
            $encoding = New-Object System.Text.UTF8Encoding($false)
            if (-not $LiveOnly) {
                $referenceText = '{"PersonalSetting":"keep-me","Whitespace":"  keep  "}' + [char]10
                [System.IO.File]::WriteAllText($referencePath, $referenceText, $encoding)
                [System.IO.File]::SetLastWriteTimeUtc($referencePath, [datetime]'2020-01-02T03:04:05Z')
            }
            if (-not $ReferenceOnly) {
                $live = Get-TetraDefaultConfig
                $live.General.Language = 'ar'
                [System.IO.File]::WriteAllText($livePath, ($live | ConvertTo-Json -Depth 10), $encoding)
            }
            return [PSCustomObject]@{Reference=$referencePath; Live=$livePath}
        }
        Export-ModuleMember -Function *
    }
    try {
        & $module $Body
        $script:passed++
        Write-Host "[PASS] $Name" -ForegroundColor Green
    } catch {
        $script:failed++
        Write-Host "[FAIL] $Name -- $($_.Exception.Message)" -ForegroundColor Red
    } finally {
        Remove-Module -ModuleInfo $module -Force -ErrorAction SilentlyContinue
    }
}

Write-Host '===== Tetra Configuration Preservation Tests =====' -ForegroundColor Cyan
Write-Host ("PowerShell: " + $PSVersionTable.PSVersion.ToString())
try {
    Test-Case 'Existing reference bytes and timestamp, and live settings, survive initialization' {
        $fixture = New-PersonalFixture
        $referenceHash = FileHash $fixture.Reference
        $referenceTime = [System.IO.File]::GetLastWriteTimeUtc($fixture.Reference)
        $liveHash = FileHash $fixture.Live
        $result = Initialize-TetraConfig -Confirm:$false
        Assert ((FileHash $fixture.Reference) -eq $referenceHash) 'Existing DefaultConfig.json was overwritten.'
        Assert ([System.IO.File]::GetLastWriteTimeUtc($fixture.Reference) -eq $referenceTime) 'Reference timestamp changed.'
        Assert ((FileHash $fixture.Live) -eq $liveHash) 'Existing complete live configuration changed.'
        Assert ($result.General.Language -eq 'ar') 'Personal live setting was lost.'
    }
    Test-Case 'Repeated initialization leaves existing reference and live files unchanged' {
        $fixture = New-PersonalFixture
        $referenceHash = FileHash $fixture.Reference
        $liveHash = FileHash $fixture.Live
        Initialize-TetraConfig -Confirm:$false | Out-Null
        Initialize-TetraConfig -Confirm:$false | Out-Null
        Assert ((FileHash $fixture.Reference) -eq $referenceHash) 'Repeated initialization changed the reference.'
        Assert ((FileHash $fixture.Live) -eq $liveHash) 'Repeated initialization changed the live configuration.'
    }
    Test-Case 'First initialization creates valid reference and live defaults' {
        $result = Initialize-TetraConfig -Confirm:$false
        $reference = Get-Content -LiteralPath (Get-TetraDefaultConfigFilePath) -Raw | ConvertFrom-Json
        $live = Get-Content -LiteralPath (Get-TetraConfigFilePath) -Raw | ConvertFrom-Json
        Assert ($reference.Metadata.ConfigVersion -eq '1.0.0') 'Reference schema missing.'
        Assert ($reference.General.SafeMode -eq $true) 'Reference safety default missing.'
        Assert ($live.General.Language -eq 'en') 'Live default missing.'
        Assert ($result.General.Language -eq $live.General.Language) 'Returned configuration differs from live defaults.'
    }
    Test-Case 'Missing live configuration is created without replacing a personal reference' {
        $fixture = New-PersonalFixture -ReferenceOnly
        $referenceHash = FileHash $fixture.Reference
        Initialize-TetraConfig -Confirm:$false | Out-Null
        Assert ((FileHash $fixture.Reference) -eq $referenceHash) 'Reference was replaced while creating live configuration.'
        Assert (Test-Path -LiteralPath $fixture.Live -PathType Leaf) 'Live configuration was not created.'
    }
    Test-Case 'Missing reference is created without replacing existing live settings' {
        $fixture = New-PersonalFixture -LiveOnly
        $liveHash = FileHash $fixture.Live
        $result = Initialize-TetraConfig -Confirm:$false
        Assert (Test-Path -LiteralPath $fixture.Reference -PathType Leaf) 'Missing reference was not created.'
        Assert ((FileHash $fixture.Live) -eq $liveHash) 'Live configuration was replaced.'
        Assert ($result.General.Language -eq 'ar') 'Personal live setting was lost.'
    }
    Test-Case 'Force resets only live configuration and preserves the personal reference' {
        $fixture = New-PersonalFixture
        $referenceHash = FileHash $fixture.Reference
        $result = Initialize-TetraConfig -Force -Confirm:$false
        Assert ((FileHash $fixture.Reference) -eq $referenceHash) 'Force replaced the personal reference.'
        Assert ($result.General.Language -eq 'en') 'Force no longer resets live settings.'
        $live = Get-Content -LiteralPath $fixture.Live -Raw | ConvertFrom-Json
        Assert ($live.General.Language -eq 'en') 'Reset live configuration was not saved.'
    }
    Test-Case 'WhatIf preserves an existing reference and does not create live configuration' {
        $fixture = New-PersonalFixture -ReferenceOnly
        $referenceHash = FileHash $fixture.Reference
        Initialize-TetraConfig -WhatIf | Out-Null
        Assert ((FileHash $fixture.Reference) -eq $referenceHash) 'WhatIf changed the reference.'
        Assert (-not (Test-Path -LiteralPath $fixture.Live)) 'WhatIf created live configuration.'
    }
    Test-Case 'WhatIf on first initialization creates neither configuration file' {
        Initialize-TetraConfig -WhatIf | Out-Null
        Assert (-not (Test-Path -LiteralPath (Get-TetraDefaultConfigFilePath))) 'WhatIf created the reference.'
        Assert (-not (Test-Path -LiteralPath (Get-TetraConfigFilePath))) 'WhatIf created live configuration.'
    }
} finally {
    # Delete only this run's own, verified temporary directory.
    $resolvedRunRoot = [System.IO.Path]::GetFullPath($runRoot)
    $resolvedParent = [System.IO.Path]::GetDirectoryName($resolvedRunRoot).TrimEnd([char[]]'\/')
    if ($resolvedParent -ne $tempParent -or [System.IO.Path]::GetFileName($resolvedRunRoot) -ne $runName) {
        throw 'Refusing cleanup outside the verified temporary test directory.'
    }
    if (Test-Path -LiteralPath $resolvedRunRoot) {
        Remove-Item -LiteralPath $resolvedRunRoot -Recurse -Force
    }
}
Write-Host ''
Write-Host ("PASS: {0}/8" -f $script:passed)
Write-Host ("FAIL: {0}/8" -f $script:failed)
Write-Host ("Overall: " + $(if ($script:failed -eq 0) {'PASS'} else {'FAIL'}))
if ($script:failed -gt 0) { exit 1 }
