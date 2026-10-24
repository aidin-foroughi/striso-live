# The hardware suite on Windows: builds the audio engine if needed, closes Striso Live (it holds
# the board's console), runs the bench's measurements and the hardware tests, and writes a
# timestamped JSON report and a summary to test-results\ (gitignored). Nothing plays a sound: the
# real output is only opened to play digital silence, at most 30 s per run.
#
#   powershell -File tools\hwtest.ps1 [-SoakMinutes 5] [-Markers 50] [-NoTests]
param(
  [double]$SoakMinutes = 5,
  [int]$Markers = 50,
  [switch]$NoTests
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$out = Join-Path $root 'test-results'
New-Item -ItemType Directory -Force $out | Out-Null
$json = Join-Path $out "hw-$stamp.json"
$summary = Join-Path $out "hw-$stamp.txt"

$dll = Join-Path $root 'build\striso_audio\Release\striso_audio.dll'
if (-not (Test-Path $dll)) {
  cmake -S packages/striso_audio/native -B build/striso_audio | Out-Null
  cmake --build build/striso_audio --config Release | Out-Null
}
Stop-Process -Name StrisoLive -Force -ErrorAction SilentlyContinue

Push-Location packages/striso_bench
dart pub get | Out-Null
$log = Join-Path $out "hw-$stamp.log"
dart run bin/striso_bench.dart all --n $Markers --minutes $SoakMinutes --json $json 2> $log | Out-Null
$benchExit = $LASTEXITCODE
$testExit = 0
if (-not $NoTests) {
  $env:STRISO_BENCH_REPORT = $json # the hardware tests check this report instead of measuring again
  dart test -t hardware -r expanded 2>&1 | Tee-Object -Variable t | Out-Null
  $testExit = $LASTEXITCODE
  $t | Out-File -Append $log
}
Pop-Location

$r = Get-Content $json -Raw | ConvertFrom-Json
$lines = @("Striso hardware suite $stamp", "board: $($r.board.version)", '')
foreach ($c in $r.checks) { $lines += ('{0}  {1}: {2} ({3})' -f ($(if ($c.ok) { 'ok  ' } else { 'FAIL' }), $c.name, $c.value, $c.limit)) }
$lines += ''
foreach ($n in $r.notes) { $lines += "note: $n" }
$lines += "bench exit $benchExit, tests exit $testExit; report $json"
$lines | Out-File $summary -Encoding utf8
$lines | ForEach-Object { Write-Output $_ }
if ($benchExit -ne 0 -or $testExit -ne 0) { exit 1 }
