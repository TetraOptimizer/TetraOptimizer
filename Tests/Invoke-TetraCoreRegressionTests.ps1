#Requires -Version 5.1
[CmdletBinding()]param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

$root = Split-Path $PSScriptRoot -Parent
$tests = @(
    'Invoke-TetraActionPlanSmokeTests.ps1',
    'Invoke-TetraExecutionSmokeTests.ps1',
    'Invoke-TetraPipelineSmokeTests.ps1',
    'Invoke-TetraReportingSmokeTests.ps1'
)

Write-Host '===== Tetra Optimizer - Core Regression Suite =====' -ForegroundColor Cyan
$passed = 0
$failed = 0
$results = @()

foreach($test in $tests){
    $path = Join-Path $PSScriptRoot $test
    if(-not (Test-Path -LiteralPath $path)){
        $failed++
        $results += [PSCustomObject]@{Test=$test;Status='Missing';ExitCode=$null}
        Write-Host "[FAIL] $test (missing)" -ForegroundColor Red
        continue
    }

    Write-Host ''
    Write-Host "---- Running $test ----" -ForegroundColor DarkCyan
    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $path
    $code = $LASTEXITCODE
    if($code -eq 0){
        $passed++
        $results += [PSCustomObject]@{Test=$test;Status='PASS';ExitCode=$code}
        Write-Host "[PASS] $test" -ForegroundColor Green
    }
    else {
        $failed++
        $results += [PSCustomObject]@{Test=$test;Status='FAIL';ExitCode=$code}
        Write-Host "[FAIL] $test (exit $code)" -ForegroundColor Red
    }
}

Write-Host ''
Write-Host '===== Core Regression Summary =====' -ForegroundColor Cyan
$results | Format-Table -AutoSize
Write-Host "Suites PASS: $passed/$($tests.Count)" -ForegroundColor $(if($failed-eq0){'Green'}else{'Yellow'})
Write-Host "Suites FAIL: $failed/$($tests.Count)" -ForegroundColor $(if($failed-eq0){'Green'}else{'Red'})
Write-Host "Overall: $(if($failed-eq0){'PASS'}else{'FAIL'})" -ForegroundColor $(if($failed-eq0){'Green'}else{'Red'})

if($failed -gt 0){exit 1}
