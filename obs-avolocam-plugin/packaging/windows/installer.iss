; installer.iss - Inno Setup script for OBS AvoCam Plugin
;
; Build with: iscc installer.iss
;
; Requires:
; - Inno Setup 6.x (https://jrsoftware.org/isinfo.php)
; - Plugin DLL built in ../../build/Release/
;

#define MyAppName "OBS AvoCam Plugin"
#define MyAppVersion "1.0.0"
#define MyAppPublisher "AvoCam Team"
#define MyAppURL "https://github.com/avolocam"

[Setup]
; Basic installer info
AppId={{A7B8C9D0-E1F2-3456-7890-ABCDEF123456}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
AppUpdatesURL={#MyAppURL}

; Installation settings
DefaultDirName={userappdata}\obs-studio\plugins\obs-avolocam
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
DisableDirPage=yes

; Output settings
OutputDir=..\..\build
OutputBaseFilename=obs-avolocam-{#MyAppVersion}-setup
Compression=lzma2
SolidCompression=yes

; Installer appearance
WizardStyle=modern
SetupIconFile=..\..\data\icon.ico

; Privileges (install to user directory, no admin required)
PrivilegesRequired=lowest

; Uninstaller
UninstallDisplayName={#MyAppName}
UninstallDisplayIcon={app}\bin\64bit\obs-avolocam.dll

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Files]
; Main plugin DLL
Source: "..\..\build\Release\obs-avolocam.dll"; DestDir: "{app}\bin\64bit"; Flags: ignoreversion

; Data files (if any)
Source: "..\..\data\*"; DestDir: "{app}\data"; Flags: ignoreversion recursesubdirs createallsubdirs; Check: DataDirExists

[Code]
// Check if data directory exists
function DataDirExists: Boolean;
begin
  Result := DirExists(ExpandConstant('{src}\..\..\data'));
end;

// Initialize setup
function InitializeSetup(): Boolean;
begin
  Result := True;

  // Check if OBS is installed
  if not DirExists(ExpandConstant('{userappdata}\obs-studio')) then
  begin
    if MsgBox('OBS Studio does not appear to be installed.' + #13#10 +
              'The plugin may not work correctly.' + #13#10 + #13#10 +
              'Continue anyway?', mbConfirmation, MB_YESNO) = IDNO then
    begin
      Result := False;
    end;
  end;
end;

[Run]
; Optionally show readme or changelog after install
; Filename: "{app}\readme.txt"; Description: "View Readme"; Flags: postinstall shellexec skipifsilent

[UninstallDelete]
; Clean up empty directories
Type: dirifempty; Name: "{app}\bin\64bit"
Type: dirifempty; Name: "{app}\bin"
Type: dirifempty; Name: "{app}\data"
Type: dirifempty; Name: "{app}"

[Messages]
WelcomeLabel2=This will install [name/ver] for OBS Studio.%n%nThe plugin provides low-latency video streaming from AvoCam iOS devices.%n%nNote: OBS Studio must be installed before running this installer.
FinishedLabel=Setup has finished installing [name] on your computer.%n%nRestart OBS Studio to use the plugin.%n%nAdd a new "AvoCam Flash Source" in OBS to get started.
