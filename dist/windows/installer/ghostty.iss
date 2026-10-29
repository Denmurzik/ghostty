; Ghostty for Windows (unofficial port): per-user Inno Setup installer.
; Built by build.ps1, which passes: AppVersion, VerInfo (4-part), Arch
; (x64|arm64), Stage, OutDir, and optionally GhosttyTest and Sign.
; /DGhosttyTest builds the test variant (R-M6-4): its own AppId, a folder
; under %TEMP%, no uninstall key, no shortcuts, no tasks, no Restart Manager,
; no Explorer step. It keeps the running-Ghostty guards (they write nothing).
; Only that variant ever runs on a development machine.
#ifndef AppVersion
  #error AppVersion is not defined
#endif
#ifndef VerInfo
  #error VerInfo is not defined
#endif
#ifndef Arch
  #error Arch is not defined
#endif
#ifndef Stage
  #error Stage is not defined
#endif
#ifndef OutDir
  #error OutDir is not defined
#endif
#if (Arch != "x64") && (Arch != "arm64")
  #error Arch must be x64 or arm64
#endif

; Checked by dist/windows/package.ps1 against the app's own constants
; (src/os/windows_explorer.zig aumid, src/apprt/win32/tray.zig class_name).
#define AppAumid "com.mitchellh.ghostty.windows-unofficial"
#define TrayClass "GhosttyTray"

[Setup]
AppName=Ghostty
AppVerName=Ghostty {#AppVersion} (unofficial Windows port)
AppVersion={#AppVersion}
AppPublisher=Ghostty Windows port (unofficial)
AppPublisherURL=https://github.com/Denmurzik/ghostty
PrivilegesRequired=lowest
DisableProgramGroupPage=yes
MinVersion=10.0.17763
WizardStyle=modern
SetupIconFile=..\ghostty.ico
Compression=lzma2/max
SolidCompression=yes
UsedUserAreasWarning=no
OutputDir={#OutDir}
VersionInfoVersion={#VerInfo}
VersionInfoProductName=Ghostty
#if Arch == "arm64"
ArchitecturesAllowed=arm64
ArchitecturesInstallIn64BitMode=arm64
#else
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
#endif
#ifdef GhosttyTest
AppId={{B6635077-20E7-4DDF-A062-7D9F8711ADF2}
DefaultDirName={%TEMP}\GhosttyTestInstall
DisableDirPage=yes
VersionInfoDescription=Ghostty test installer
CreateUninstallRegKey=no
CloseApplications=no
OutputBaseFilename=ghostty-{#AppVersion}-windows-{#Arch}-setup-test
#else
AppId={{37134A5A-16BD-4127-9CC0-134E0CF32BA5}
DefaultDirName={autopf}\Ghostty
UninstallDisplayIcon={app}\ghostty.exe
VersionInfoDescription=Ghostty Setup
CloseApplications=yes
RestartApplications=no
OutputBaseFilename=ghostty-{#AppVersion}-windows-{#Arch}-setup
#endif
#ifdef Sign
SignTool=signtool
SignedUninstaller=yes
#endif

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

#ifndef GhosttyTest
[Tasks]
Name: "explorermenu"; Description: "Add ""Open Ghostty here"" to the Explorer folder menu"
Name: "desktopicon"; Description: "Create a &desktop shortcut"; Flags: unchecked
#endif

[InstallDelete]
; Ghostty owns both folders completely: an upgrade drops removed files.
Type: filesandordirs; Name: "{app}\share\ghostty\themes"
Type: filesandordirs; Name: "{app}\share\ghostty\shell-integration"

[Files]
Source: "{#Stage}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

#ifndef GhosttyTest
[Icons]
Name: "{autoprograms}\Ghostty"; Filename: "{app}\ghostty.exe"; WorkingDir: "{%USERPROFILE}"; AppUserModelID: "{#AppAumid}"
Name: "{autodesktop}\Ghostty"; Filename: "{app}\ghostty.exe"; WorkingDir: "{%USERPROFILE}"; AppUserModelID: "{#AppAumid}"; Tasks: desktopicon
#endif

#ifndef GhosttyTest
[Run]
Filename: "{app}\ghostty.exe"; Description: "Launch Ghostty"; WorkingDir: "{%USERPROFILE}"; Flags: postinstall nowait skipifsilent
#endif

[UninstallRun]
; Always, whether or not the Explorer task was ticked. --only-this-exe keeps a
; portable copy's entries; --all also removes the AUMID key and toast icon.
Filename: "{app}\ghostty.exe"; Parameters: "+uninstall-explorer-integration --all --only-this-exe"; Flags: runhidden waituntilterminated; RunOnceId: "ExplorerRevert"

[Code]
#ifndef GhosttyTest
procedure CurStepChanged(CurStep: TSetupStep);
var
  ResultCode: Integer;
begin
  if (CurStep = ssPostInstall) and WizardIsTaskSelected('explorermenu') then
  begin
    if not Exec(ExpandConstant('{app}\ghostty.exe'), '+install-explorer-integration',
                '', SW_HIDE, ewWaitUntilTerminated, ResultCode) or (ResultCode <> 0) then
    begin
      Log(Format('+install-explorer-integration failed (code %d: %s)', [ResultCode, SysErrorMessage(ResultCode)]));
      SuppressibleMsgBox('Ghostty was installed, but the Explorer menu entry could not be added. ' +
        'You can add it later with: ghostty.exe +install-explorer-integration',
        mbInformation, MB_OK, IDOK);
    end;
  end;
end;
#endif

// Runs before Setup's own in-use check (Restart Manager), so the guard has to
// wait here itself. Any Ghostty counts, a portable copy too.
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  Msg: String;
begin
  Msg := 'Ghostty is running. Close all Ghostty windows (and the tray icon), then click Retry.';
  Result := '';
  while FindWindowByClassName('{#TrayClass}') <> 0 do
  begin
    if WizardSilent then
    begin
      Result := Msg;
      Exit;
    end;
    if MsgBox(Msg, mbError, MB_RETRYCANCEL) = IDCANCEL then
    begin
      Result := 'Setup was stopped because Ghostty is running.';
      Exit;
    end;
  end;
end;

function InitializeUninstall(): Boolean;
begin
  Result := True;
  while FindWindowByClassName('{#TrayClass}') <> 0 do
  begin
    if SuppressibleMsgBox('Close any running Ghostty (including the tray icon) to continue.',
         mbError, MB_RETRYCANCEL, IDCANCEL) = IDCANCEL then
    begin
      Result := False;
      Exit;
    end;
  end;
end;
