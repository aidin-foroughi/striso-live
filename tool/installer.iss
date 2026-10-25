; Inno Setup script for a per-user Striso Live installer (no admin rights needed).
; Built in CI (release.yml) from the repository root, after flutter build windows --release:
;   iscc /DAppVersion=1.1.0 tool\installer.iss   ->  dist\StrisoLive-1.1.0-windows-setup.exe
#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif
[Setup]
AppId={{6F0E5C3A-7B1D-4B8E-9E57-57C0F0550279}
AppName=Striso Live
AppVersion={#AppVersion}
AppPublisher=Striso
DefaultDirName={localappdata}\Programs\Striso Live
DefaultGroupName=Striso Live
PrivilegesRequired=lowest
OutputDir=..\dist
OutputBaseFilename=StrisoLive-{#AppVersion}-windows-setup
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\StrisoLive.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible

[Files]
; the whole Release folder: the app, its DLLs and the C++ runtime next to the exe (app-local:
; msvcp140, msvcp140_atomic_wait, vcruntime140, vcruntime140_1; windows/CMakeLists.txt)
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: recursesubdirs ignoreversion

[Icons]
Name: "{group}\Striso Live"; Filename: "{app}\StrisoLive.exe"
Name: "{userdesktop}\Striso Live"; Filename: "{app}\StrisoLive.exe"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; Flags: unchecked

[Run]
Filename: "{app}\StrisoLive.exe"; Description: "Start Striso Live"; Flags: nowait postinstall skipifsilent
