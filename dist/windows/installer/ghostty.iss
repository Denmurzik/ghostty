; Ghostty for Windows (unofficial port): per-user Inno Setup installer.
; Built by build.ps1, which passes: AppVersion, VerInfo (4-part), Arch
; (x64|arm64), Stage, OutDir, and optionally GhosttyTest and Sign.
; /DGhosttyTest builds the test variant (R-M6-4): its own AppId, a folder
; under %TEMP%, no uninstall key, no shortcuts, no tasks, no Restart Manager,
; no Explorer step, no menu-package code. It keeps the running-Ghostty guards (they write nothing).
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
function GetTickCount(): Cardinal; external 'GetTickCount@kernel32.dll stdcall';

// The Windows 11 folder-menu package (R-M7-13). Every PowerShell call uses the
// full path, runs hidden and waited; paths sit in single quotes, doubled inside.
function PsExe(): String;
begin
  Result := ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe');
end;

function PsQuote(const S: String): String;
var
  T: String;
begin
  T := S;
  StringChangeEx(T, '''', '''''', True);
  // PowerShell also takes these as single quotes.
  StringChangeEx(T, #$2018, #$2018#$2018, True);
  StringChangeEx(T, #$2019, #$2019#$2019, True);
  StringChangeEx(T, #$201A, #$201A#$201A, True);
  StringChangeEx(T, #$201B, #$201B#$201B, True);
  Result := '''' + T + '''';
end;

function RunPs(const Command: String): Integer;
var
  ResultCode: Integer;
begin
  if not Exec(PsExe(), '-NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "' + Command + '"',
              '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then
    ResultCode := -1;
  Result := ResultCode;
end;

// Removes the package only when it is registered for this {app}. No package: nothing
// happens. A package registered from another (portable) folder is left alone and
// logged (exit 3); only one registration per user is possible. The result is
// ignored beyond the log.
procedure RemoveMenuPackage();
var
  App: String;
  Code: Integer;
begin
  App := RemoveBackslash(ExpandConstant('{app}'));
  Code := RunPs(
    '$ErrorActionPreference = ''Stop''; try { ' +
    '$p = Get-AppxPackage -Name Ghostty.ExplorerMenu | Select-Object -First 1; if (-not $p) { exit 0 }; ' +
    '$app = ' + PsQuote(App) + '; $locs = @($p.InstallLocation); ' +
    'try { [void][Windows.Management.Deployment.PackageManager, Windows.Management.Deployment, ContentType=WindowsRuntime]; ' +
    '$q = (New-Object Windows.Management.Deployment.PackageManager).FindPackageForUser('''', $p.PackageFullName); ' +
    'if ($q.EffectiveExternalLocation) { $locs += $q.EffectiveExternalLocation.Path } } catch { }; ' +
    '$mine = @($locs | Where-Object { $_ -and ($_.TrimEnd(''\'') -ieq $app) }); ' +
    'if (-not $mine) { exit 3 }; ' +
    'Remove-AppxPackage -ErrorAction Stop -Package $p.PackageFullName; exit 0 } catch { exit 1 }');
  if Code = 3 then
    Log('Ghostty.ExplorerMenu is registered from another folder; left in place')
  else if Code <> 0 then
    Log(Format('Removing Ghostty.ExplorerMenu failed (code %d)', [Code]));
end;

function MenuDll(): String;
begin
  Result := ExpandConstant('{app}\ghostty-explorer.dll');
end;

// A DLL that Explorer holds cannot be deleted but can be renamed on the same volume.
function MoveDllAside(): Boolean;
var
  Dll: String;
begin
  Dll := MenuDll();
  Result := not FileExists(Dll);
  if Result then Exit;
  Result := DeleteFile(Dll);
  if not Result then
    Result := RenameFile(Dll, Dll + '.old-' + IntToStr(GetTickCount()));
end;

procedure DeleteOldMenuDlls();
var
  Rec: TFindRec;
  Dir: String;
begin
  Dir := ExpandConstant('{app}');
  if FindFirst(Dir + '\ghostty-explorer.dll.old-*', Rec) then
  begin
    try
      repeat
        if (Rec.Attributes and FILE_ATTRIBUTE_DIRECTORY) = 0 then
          DeleteFile(Dir + '\' + Rec.Name);
      until not FindNext(Rec);
    finally
      FindClose(Rec);
    end;
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  ResultCode: Integer;
  WinVer: TWindowsVersion;
  App: String;
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

    // Windows 11 top-level entry. A failure leaves the classic verb in place.
    GetWindowsVersionEx(WinVer);
    if WinVer.Build >= 22000 then
    begin
      App := ExpandConstant('{app}');
      // A registration from another folder would make Add-AppxPackage fail.
      RemoveMenuPackage();
      ResultCode := RunPs('try { Add-AppxPackage -ErrorAction Stop -Path ' + PsQuote(App + '\ghostty-explorer.msix') +
        ' -ExternalLocation ' + PsQuote(App) +
        ' -AllowUnsigned -ForceUpdateFromAnyVersion; exit 0 } catch { exit 1 }');
      if ResultCode <> 0 then
      begin
        Log(Format('Add-AppxPackage failed (code %d)', [ResultCode]));
        SuppressibleMsgBox('Ghostty was installed, but the Windows 11 folder-menu entry could not be added ' +
          '(the classic "Show more options" entry still works). ' +
          'The package may need Developer Mode to be turned on in Windows settings.',
          mbInformation, MB_OK, IDOK);
      end;
    end;
  end;
  if CurStep = ssPostInstall then
    DeleteOldMenuDlls();
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
#ifndef GhosttyTest
  // Upgrade: Explorer may hold the previous menu DLL. Drop the package, then
  // delete the DLL or move it aside; never offer Ignore.
  if FileExists(MenuDll()) then
  begin
    RemoveMenuPackage();
    Msg := 'Explorer is still using the Ghostty menu. Close all File Explorer windows, then click Retry.';
    while not MoveDllAside() do
    begin
      if WizardSilent then
      begin
        Result := Msg;
        Exit;
      end;
      if MsgBox(Msg, mbError, MB_RETRYCANCEL) = IDCANCEL then
      begin
        Result := 'Setup was stopped because Explorer is using the Ghostty menu.';
        Exit;
      end;
    end;
  end;
#endif
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

#ifndef GhosttyTest
// usUninstall fires before the [UninstallRun] entries, so the package is removed
// here (only when it is registered for this folder). A DLL that
// Explorer still holds is moved aside; usPostUninstall deletes the leftovers
// and the folder if nothing else is in it (RemoveDir keeps a non-empty one).
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usUninstall then
  begin
    RemoveMenuPackage();
    MoveDllAside();
  end;
  if CurUninstallStep = usPostUninstall then
  begin
    DeleteOldMenuDlls();
    RemoveDir(ExpandConstant('{app}'));
  end;
end;
#endif
