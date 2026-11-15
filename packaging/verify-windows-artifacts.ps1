# Native acceptance checks for built Windows artifacts.
#
# Verifies the installer/portable files, their .sha256 siblings and (optionally)
# Authenticode. It does not install or launch the app: clean install, upgrade,
# WebView2 IPC and DPAPI checks stay manual in docs/RELEASE_ACCEPTANCE.md.
#
# Usage:
#   powershell -File packaging/verify-windows-artifacts.ps1 `
#     -Dist Windows/dist -Version 6.0.0 [-RequireSignature] [-Report out.txt]
param(
    [Parameter(Mandatory = $true)]
    [string]$Dist,
    [Parameter(Mandatory = $true)]
    [string]$Version,
    [switch]$RequireSignature,
    [string]$Report
)

$ErrorActionPreference = "Stop"
$script:Failed = 0
$script:Passed = 0
$script:Skipped = 0

function Write-Result([string]$Status, [string]$Message) {
    $line = "{0,-7} {1}" -f $Status, $Message
    Write-Host $line
    if ($Report) { Add-Content -Path $Report -Value $line -Encoding UTF8 }
    switch ($Status) {
        "PASS" { $script:Passed++ }
        "FAIL" { $script:Failed++ }
        "SKIP" { $script:Skipped++ }
    }
}

if ($Report) {
    $dir = Split-Path -Parent $Report
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
    Set-Content -Path $Report -Value "Melon Tools Windows artifact acceptance - $Version" -Encoding UTF8
}

$distPath = (Resolve-Path $Dist).Path
$names = @(
    "MelonTools-$Version-setup.exe",
    "MelonTools-$Version-win-x64-portable.exe",
    "MelonTools-$Version-win-x64.exe"
)

$hashes = @{}
foreach ($name in $names) {
    $path = Join-Path $distPath $name
    if (-not (Test-Path $path)) {
        if ($name -like "*-win-x64.exe") {
            Write-Result "SKIP" "$name is optional (legacy alias)"
        } else {
            Write-Result "FAIL" "$name is missing"
        }
        continue
    }

    $hash = (Get-FileHash -Algorithm SHA256 $path).Hash.ToLowerInvariant()
    $hashes[$name] = $hash
    Write-Result "PASS" "$name exists ($((Get-Item $path).Length) bytes)"

    $sibling = "$path.sha256"
    if (-not (Test-Path $sibling)) {
        Write-Result "FAIL" "$name.sha256 is missing"
    } else {
        $text = (Get-Content -Raw $sibling).Trim()
        if ($text -match '^([0-9a-fA-F]{64})') {
            $expected = $Matches[1].ToLowerInvariant()
            if ($expected -eq $hash) {
                Write-Result "PASS" "$name matches its .sha256 sibling"
            } else {
                Write-Result "FAIL" "$name does not match its .sha256 sibling"
            }
        } else {
            Write-Result "FAIL" "$name.sha256 has no 64-hex digest"
        }
    }

    try {
        $bytes = [IO.File]::ReadAllBytes($path)
        $peOffset = [BitConverter]::ToInt32($bytes, 0x3C)
        if ([Text.Encoding]::ASCII.GetString($bytes, $peOffset, 4) -ne "PE`0`0") {
            throw "no PE signature"
        }
        $machine = [BitConverter]::ToUInt16($bytes, $peOffset + 4)
        if ($name -like "*-setup.exe") {
            # NSIS installers are commonly 32-bit stubs even when they carry an
            # x64 application; both x86 (0x014c) and x64 (0x8664) are valid.
            if ($machine -eq 0x014c -or $machine -eq 0x8664) {
                Write-Result "PASS" ("{0} is a valid NSIS PE (0x{1:X4})" -f $name, $machine)
            } else {
                Write-Result "FAIL" ("{0} has unexpected PE machine 0x{1:X4}" -f $name, $machine)
            }
        } elseif ($machine -eq 0x8664) {
            Write-Result "PASS" "$name is a native x64 PE"
        } else {
            Write-Result "FAIL" ("{0} has PE machine 0x{1:X4}, expected x64 0x8664" -f $name, $machine)
        }
    } catch {
        Write-Result "FAIL" "$name is not a readable PE file: $($_.Exception.Message)"
    }

    $signature = Get-AuthenticodeSignature $path
    if ($signature.Status -eq "Valid") {
        Write-Result "PASS" "$name Authenticode signature is valid"
    } elseif ($RequireSignature) {
        Write-Result "FAIL" "$name is not Authenticode-signed (status: $($signature.Status))"
    } else {
        Write-Result "SKIP" "$name is not Authenticode-signed (signing unavailable)"
    }
}

if ($hashes.ContainsKey("MelonTools-$Version-win-x64-portable.exe") -and
    $hashes.ContainsKey("MelonTools-$Version-win-x64.exe") -and
    $hashes["MelonTools-$Version-win-x64-portable.exe"] -ne $hashes["MelonTools-$Version-win-x64.exe"]) {
    Write-Result "FAIL" "the legacy -win-x64.exe alias differs from the portable build"
}

if ($hashes.ContainsKey("MelonTools-$Version-setup.exe") -and
    $hashes.ContainsKey("MelonTools-$Version-win-x64-portable.exe") -and
    $hashes["MelonTools-$Version-setup.exe"] -eq $hashes["MelonTools-$Version-win-x64-portable.exe"]) {
    Write-Result "FAIL" "the NSIS setup is byte-identical to the portable exe"
}

Write-Host ""
$summary = "acceptance: $script:Passed passed, $script:Failed failed, $script:Skipped skipped; install/upgrade/WebView2 checks are manual"
Write-Host $summary
if ($Report) { Add-Content -Path $Report -Value $summary -Encoding UTF8 }
if ($script:Failed -gt 0) { throw "Windows artifact acceptance failed" }
