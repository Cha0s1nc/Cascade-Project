; The Flutter app's Windows installer (Inno Setup 6). flutter.yml runs it:
;
;   iscc /DAppVersion=2.5.0 /DNumericVersion=2.5.0.123 /DSourceDir=<Release folder> /O<out> cascade.iss
;
; Per user, no admin prompt, so a future updater can run it silently
; (/VERYSILENT). It installs beside the Electron app, never over it: its own
; AppId, folder and Start menu name. The output name carries no version on
; purpose: see PLATFORM_FILES.flutter in desktop/src/core/release-plan.ts.

#ifndef AppVersion
  #define AppVersion "0.1.0"
#endif
#ifndef NumericVersion
  #define NumericVersion "0.1.0.0"
#endif
#ifndef SourceDir
  #define SourceDir "..\..\build\windows\x64\runner\Release"
#endif

[Setup]
; Never change this: it is how Windows knows an update is the same app.
AppId={{E5138FAB-B9E6-43D8-B4FB-6A3CF2FB7623}
AppName=Cascade Flutter
AppVersion={#AppVersion}
AppVerName=Cascade Flutter {#AppVersion}
AppPublisher=cha0s_1nc
AppPublisherURL=https://cascade.chaosinc.xyz
VersionInfoVersion={#NumericVersion}
DefaultDirName={localappdata}\Programs\Cascade Flutter
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
LicenseFile=..\..\..\shared\assets\installer-license.txt
SetupIconFile=..\..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\cascade.exe
UninstallDisplayName=Cascade Flutter
OutputBaseFilename=Cascade-Flutter-Setup-x64
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes

[Tasks]
Name: desktopicon; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[InstallDelete]
; The bundle's assets from an older version: what a new one dropped must not linger.
Type: filesandordirs; Name: "{app}\data"

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\Cascade Flutter"; Filename: "{app}\cascade.exe"
Name: "{autodesktop}\Cascade Flutter"; Filename: "{app}\cascade.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\cascade.exe"; Description: "{cm:LaunchProgram,Cascade Flutter}"; Flags: nowait postinstall skipifsilent
