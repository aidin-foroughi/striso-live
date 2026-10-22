# Zip the Windows release folder into a portable app: dist/StrisoLive-<version>-windows-x64.zip
# (unzip anywhere and run StrisoLive.exe). Run from tools/striso_live after
#   flutter build windows --release
$ErrorActionPreference = 'Stop'
$version = (Select-String -Path pubspec.yaml -Pattern '^version:\s*([0-9.]+)').Matches[0].Groups[1].Value
$src = 'build\windows\x64\runner\Release'
if (-not (Test-Path "$src\StrisoLive.exe")) { throw "no $src\StrisoLive.exe: run flutter build windows --release first" }
if (-not (Test-Path "$src\libusb-1.0.dll")) { throw "libusb-1.0.dll is missing from the build" }
New-Item -ItemType Directory -Force dist | Out-Null
$stage = "dist\Striso Live"
if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
Copy-Item -Recurse $src $stage
Copy-Item README.md "$stage\README.md"
$zip = "dist\StrisoLive-$version-windows-x64.zip"
if (Test-Path $zip) { Remove-Item -Force $zip }
Compress-Archive -Path $stage -DestinationPath $zip
Remove-Item -Recurse -Force $stage
Get-Item $zip | Select-Object FullName, Length
