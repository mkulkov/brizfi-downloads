param(
    [string]$Compiler,
    [string]$RuntimeDir,
    [string]$NoticesDir,
    [string]$OutputDir
)
$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$releaseDir = Join-Path $projectRoot 'build/windows/x64/runner/Release'
foreach ($required in @('brizfi.exe', 'flutter_windows.dll', 'rust_lib_brizfi.dll', 'data/flutter_assets/NOTICES.Z')) {
    if (-not (Test-Path -LiteralPath (Join-Path $releaseDir $required))) {
        throw "Missing release file: $required. Run flutter build windows --release first."
    }
}
if (-not $Compiler) {
    $compilerCandidates = @(
        (Join-Path $env:LOCALAPPDATA 'Programs/Inno Setup 6/ISCC.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6/ISCC.exe')
    )
    $Compiler = $compilerCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
}
if (-not $Compiler -or -not (Test-Path -LiteralPath $Compiler)) { throw 'Install Inno Setup 6.7.3 or pass -Compiler.' }
if (-not $RuntimeDir) {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
    $visualStudioDir = & $vswhere -latest -products '*' -property installationPath
    if ($LASTEXITCODE -ne 0 -or -not $visualStudioDir) { throw 'Visual Studio not found; pass -RuntimeDir.' }
    $redistRoot = Join-Path $visualStudioDir 'VC/Redist/MSVC'
    $runtimeVersion = Get-ChildItem -LiteralPath $redistRoot -Directory |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'x64/Microsoft.VC143.CRT') } |
        Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1
    if (-not $runtimeVersion) { throw 'Visual C++ x64 CRT not found; pass -RuntimeDir.' }
    $RuntimeDir = Join-Path $runtimeVersion.FullName 'x64/Microsoft.VC143.CRT'
}
if (-not $NoticesDir) { $NoticesDir = Join-Path $projectRoot 'artifacts/publication/brizfi-downloads' }
if (-not (Test-Path -LiteralPath (Join-Path $NoticesDir 'THIRD_PARTY_LICENSES/Flutter-NOTICES.txt'))) {
    throw 'Pass -NoticesDir containing THIRD_PARTY_NOTICES.md and THIRD_PARTY_LICENSES.'
}
if (-not $OutputDir) { $OutputDir = Join-Path $projectRoot ('artifacts/releases/' + (Get-Date -Format 'yyyy-MM-dd')) }
$versionMatch = [regex]::Match((Get-Content -LiteralPath (Join-Path $projectRoot 'pubspec.yaml') -Raw), '(?m)^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$')
if (-not $versionMatch.Success) { throw 'Expected version x.y.z+build in pubspec.yaml.' }
$appVersion = $versionMatch.Groups[1].Value
$fileVersion = $appVersion + '.' + $versionMatch.Groups[2].Value
$stageDir = Join-Path $projectRoot ('artifacts/windows-installer/stage-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stageDir -Force | Out-Null
Copy-Item -Path (Join-Path $releaseDir '*') -Destination $stageDir -Recurse
Copy-Item -LiteralPath (Join-Path $projectRoot 'LICENSE') -Destination $stageDir
Copy-Item -LiteralPath (Join-Path $NoticesDir 'THIRD_PARTY_NOTICES.md') -Destination $stageDir
Copy-Item -LiteralPath (Join-Path $NoticesDir 'THIRD_PARTY_LICENSES') -Destination $stageDir -Recurse
Copy-Item -Path (Join-Path $RuntimeDir '*.dll') -Destination $stageDir
foreach ($runtime in @('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')) {
    if (-not (Test-Path -LiteralPath (Join-Path $stageDir $runtime))) { throw "Missing CRT: $runtime" }
}
@'
BRIZFI for Windows x64

Installation is per-user and does not require administrator rights.
Start BRIZFI from the Start menu. The desktop shortcut is optional.
Uninstall using Windows Settings > Apps. Original user books are not installed
or removed by this installer. Keep BRIZFI open during local transfers.

Source code and build instructions:
https://github.com/mkulkov/brizfi-downloads
License: GPL-3.0-or-later; see LICENSE and THIRD_PARTY_NOTICES.md.
Microsoft Visual C++ runtime DLLs are included for app-local use.
'@ | Set-Content -LiteralPath (Join-Path $stageDir 'INSTALLATION.txt') -Encoding utf8
Add-Content -LiteralPath (Join-Path $stageDir 'THIRD_PARTY_NOTICES.md') -Value "`nMicrosoft Visual C++ Runtime: Microsoft Corporation, proprietary redistributable runtime, app-local x64 CRT from Visual Studio. These DLLs retain Microsoft's terms and are not relicensed under GPL. See https://learn.microsoft.com/cpp/windows/redistributing-visual-cpp-files ." -Encoding utf8
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
& $Compiler "/DStageDir=$stageDir" "/DOutputDir=$OutputDir" "/DAppVersion=$appVersion" "/DFileVersion=$fileVersion" (Join-Path $PSScriptRoot 'brizfi.iss')
if ($LASTEXITCODE -ne 0) { throw "ISCC failed: $LASTEXITCODE" }
$installerPath = Join-Path $OutputDir "BRIZFI-$appVersion-windows-x64-setup.exe"
Get-FileHash -LiteralPath $installerPath -Algorithm SHA256 |
    ForEach-Object { "$($_.Hash.ToLowerInvariant())  $([IO.Path]::GetFileName($installerPath))" } |
    Set-Content -LiteralPath ($installerPath + '.sha256') -Encoding ascii
[pscustomobject]@{ Installer = $installerPath; Stage = $stageDir; Runtime = $RuntimeDir }
