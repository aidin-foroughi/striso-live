# Install or update Striso Live on Windows (x64), for the current user, without admin rights:
#
#   irm https://raw.githubusercontent.com/aidin-foroughi/striso-live/main/install-windows.ps1 | iex
#
# Downloads the latest release's StrisoLive-windows-x64.zip, checks it against its published
# SHA-256, stops a Striso Live running from the install folder, replaces the app in
# %LOCALAPPDATA%\Programs\Striso Live (the installer's folder too: its uninstaller is kept), adds a
# Start menu shortcut and starts the app. Run it again to update.
#
# Options (environment variables, set before running, e.g. $env:STRISO_LIVE_VERSION = 'v1.1.0'):
#   STRISO_LIVE_VERSION=v1.1.0   a release tag (default: the latest release)
#   STRISO_LIVE_DIR=<folder>     install into this folder
#   STRISO_LIVE_NO_OPEN=1        do not start the app afterwards
#   STRISO_LIVE_NO_SHORTCUT=1    no Start menu shortcut
#   STRISO_LIVE_DRY_RUN=1        only print what would be downloaded and where it would go
#   STRISO_LIVE_REPO=<owner/repo>, STRISO_LIVE_BASE_URL=<url>   download from elsewhere (forks, tests)
#
# Everything runs in a script block, so nothing is left behind in your PowerShell session and an
# error does not close the window.
& {
  $ErrorActionPreference = 'Stop'
  $ProgressPreference = 'SilentlyContinue'  # Invoke-WebRequest is many times faster without it

  function Say([string]$msg) { Write-Host "==> $msg" }

  try {
    $repo = if ($env:STRISO_LIVE_REPO) { $env:STRISO_LIVE_REPO } else { 'aidin-foroughi/striso-live' }
    $asset = 'StrisoLive-windows-x64.zip'
    if ($env:STRISO_LIVE_BASE_URL) {
      $base = $env:STRISO_LIVE_BASE_URL.TrimEnd('/')
    } elseif ($env:STRISO_LIVE_VERSION) {
      $base = "https://github.com/$repo/releases/download/$($env:STRISO_LIVE_VERSION)"
    } else {
      $base = "https://github.com/$repo/releases/latest/download"
    }
    $zipUrl = "$base/$asset"
    $sumUrl = "$zipUrl.sha256"
    $dest = if ($env:STRISO_LIVE_DIR) { $env:STRISO_LIVE_DIR.TrimEnd('\') } else { Join-Path $env:LOCALAPPDATA 'Programs\Striso Live' }
    $exe = Join-Path $dest 'StrisoLive.exe'

    Say 'Striso Live installer'
    Say "download:    $zipUrl"
    Say "checksum:    $sumUrl"
    Say "install to:  $dest"
    if ($env:STRISO_LIVE_DRY_RUN) { Say 'dry run: nothing downloaded or changed'; return }
    # the folder's contents are replaced: only an empty folder or an earlier install
    if ((Test-Path $dest) -and -not (Test-Path $exe) -and @(Get-ChildItem -LiteralPath $dest -Force).Count -gt 0) {
      throw "$dest is not empty and holds no Striso Live: choose another folder (STRISO_LIVE_DIR)"
    }

    # Windows PowerShell 5.1 may still default to TLS 1.0
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("striso-live-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
      $zip = Join-Path $tmp $asset
      Say "downloading $asset"
      Invoke-WebRequest -UseBasicParsing -Uri $zipUrl -OutFile $zip
      if (-not (Test-Path $zip) -or (Get-Item $zip).Length -eq 0) { throw "the download is empty: $zipUrl" }

      Say 'checking the download'
      $sumText = (Invoke-WebRequest -UseBasicParsing -Uri $sumUrl).Content
      if ($sumText -is [byte[]]) { $sumText = [Text.Encoding]::ASCII.GetString($sumText) }
      $want = ("$sumText".Trim() -split '\s+')[0].ToLowerInvariant()
      if ($want -notmatch '^[0-9a-f]{64}$') { throw "the checksum file is not a SHA-256: $sumUrl" }
      $got = (Get-FileHash -Algorithm SHA256 -Path $zip).Hash.ToLowerInvariant()
      if ($got -ne $want) { throw "checksum mismatch (expected $want, got $got): download again" }

      $x = Join-Path $tmp 'x'
      Expand-Archive -Path $zip -DestinationPath $x
      $src = Join-Path $x 'Striso Live'
      if (-not (Test-Path (Join-Path $src 'StrisoLive.exe'))) { throw 'the zip does not hold Striso Live\StrisoLive.exe' }

      # only a copy running from the install folder holds its files
      $running = @(Get-Process -Name StrisoLive -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path -like "$dest\*" })
      if ($running.Count -gt 0) {
        Say 'closing the running Striso Live'
        $running | ForEach-Object { [void]$_.CloseMainWindow() }
        $running | ForEach-Object { if (-not $_.WaitForExit(10000)) { Stop-Process -Id $_.Id -Force } }
        Start-Sleep -Milliseconds 500
      }

      Say 'installing'
      New-Item -ItemType Directory -Force -Path $dest | Out-Null
      # replace the app, keep the installer's uninstaller (unins000.exe/.dat) if there is one
      Get-ChildItem -LiteralPath $dest -Force | Where-Object { $_.Name -notlike 'unins*' } | Remove-Item -Recurse -Force
      Copy-Item -Path (Join-Path $src '*') -Destination $dest -Recurse -Force
      Get-ChildItem -LiteralPath $dest -Recurse -File | Unblock-File

      if (-not $env:STRISO_LIVE_NO_SHORTCUT) {
        $programs = [Environment]::GetFolderPath('Programs')
        $installerLink = Join-Path $programs 'Striso Live\Striso Live.lnk'
        if (-not (Test-Path $installerLink)) {
          $link = Join-Path $programs 'Striso Live.lnk'
          $shell = New-Object -ComObject WScript.Shell
          $sc = $shell.CreateShortcut($link)
          $sc.TargetPath = $exe
          $sc.WorkingDirectory = $dest
          $sc.Description = 'Striso Live'
          $sc.Save()
          Say "Start menu: $link"
        }
      }
    } finally {
      Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }

    $version = (Get-Item $exe).VersionInfo.ProductVersion
    Say "installed Striso Live $version in $dest"
    Say 'unsigned app: if SmartScreen says "Windows protected your PC", click More info, then Run anyway'
    if (-not $env:STRISO_LIVE_NO_OPEN) { Start-Process -FilePath $exe -WorkingDirectory $dest }
  } catch {
    Write-Host "error: $($_.Exception.Message)" -ForegroundColor Red
  }
}
