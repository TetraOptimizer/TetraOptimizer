#Requires -Version 5.1
[CmdletBinding()]param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

$root = Split-Path $PSScriptRoot -Parent
$tests = @(
    [PSCustomObject]@{ File='Invoke-TetraActionPlanSmokeTests.ps1'; ExpectedTests=17 },
    [PSCustomObject]@{ File='Invoke-TetraExecutionSmokeTests.ps1'; ExpectedTests=19 },
    [PSCustomObject]@{ File='Invoke-TetraPipelineSmokeTests.ps1'; ExpectedTests=17 },
    [PSCustomObject]@{ File='Invoke-TetraReportingSmokeTests.ps1'; ExpectedTests=12 },
    [PSCustomObject]@{ File='Invoke-TetraPostExecutionVerificationSmokeTests.ps1'; ExpectedTests=14 },
    [PSCustomObject]@{ File='Invoke-TetraPipelinePostExecutionIntegrationSmokeTests.ps1'; ExpectedTests=12 }
)

Write-Host '===== Tetra Optimizer - Full Core Regression Gate =====' -ForegroundColor Cyan
$passed = 0
$failed = 0
$expectedTotal = 0
$results = @()

foreach($entry in $tests){
    $test = [string]$entry.File
    $expectedTotal += [int]$entry.ExpectedTests
    $path = Join-Path $PSScriptRoot $test

    if(-not (Test-Path -LiteralPath $path)){
        $failed++
        $results += [PSCustomObject]@{Test=$test;ExpectedTests=$entry.ExpectedTests;Status='Missing';ExitCode=$null}
        Write-Host "[FAIL] $test (missing)" -ForegroundColor Red
        continue
    }

    Write-Host ''
    Write-Host "---- Running $test ----" -ForegroundColor DarkCyan
    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $path
    $code = $LASTEXITCODE

    if($code -eq 0){
        $passed++
        $results += [PSCustomObject]@{Test=$test;ExpectedTests=$entry.ExpectedTests;Status='PASS';ExitCode=$code}
        Write-Host "[PASS] $test" -ForegroundColor Green
    }
    else {
        $failed++
        $results += [PSCustomObject]@{Test=$test;ExpectedTests=$entry.ExpectedTests;Status='FAIL';ExitCode=$code}
        Write-Host "[FAIL] $test (exit $code)" -ForegroundColor Red
    }
}

Write-Host ''
Write-Host '===== Full Core Regression Summary =====' -ForegroundColor Cyan
$results | Format-Table -AutoSize
Write-Host "Suites PASS: $passed/$($tests.Count)" -ForegroundColor $(if($failed -eq 0){'Green'}else{'Yellow'})
Write-Host "Suites FAIL: $failed/$($tests.Count)" -ForegroundColor $(if($failed -eq 0){'Green'}else{'Red'})
Write-Host "Expected test coverage: $expectedTotal tests across $($tests.Count) suites" -ForegroundColor Cyan
Write-Host "Overall: $(if($failed -eq 0){'PASS'}else{'FAIL'})" -ForegroundColor $(if($failed -eq 0){'Green'}else{'Red'})

if($failed -gt 0){exit 1}
