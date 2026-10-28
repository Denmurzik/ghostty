# e2e: milestone=M5 timeout=150 order=910
# jumplist: the taskbar jump list is built (hr_begin = 0, hr_commit = 0) with
# New Window, New Tab, a separator and the profile tasks; quitting deletes the
# list of the test AUMID (so no link to a test exe stays on the taskbar); with
# no instance running, `ghostty.exe +new-tab --class=<c>` starts one with that
# class.
. (Join-Path $PSScriptRoot '_common.ps1')
Import-Module (Join-Path $script:WinDir 'lib\GhosttyIpc.psm1') -Force

# The AUMIDs the app uses for its list in test mode (jumplist.aumidForRun): debug and release build.
$script:JumpListAumids = @('com.mitchellh.ghostty.windows-unofficial-debug.e2e', 'com.mitchellh.ghostty.windows-unofficial.e2e')

if (-not ('GhosttyE2e.JumpListNative' -as [type])) {
    Add-Type -Namespace GhosttyE2e -Name JumpListNative -MemberDefinition @"
[ComImport, Guid("77f10cf0-3db5-4966-b520-b7c54fd35ed6")] public class DestinationList {}
[ComImport, Guid("6332debf-87b5-4670-90c0-5e57b408a49e"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface ICustomDestinationList {
    void SetAppID([MarshalAs(UnmanagedType.LPWStr)] string id);
    [PreserveSig] int BeginList(out uint min, ref Guid riid, [MarshalAs(UnmanagedType.IUnknown)] out object removed);
    void AppendCategory([MarshalAs(UnmanagedType.LPWStr)] string name, [MarshalAs(UnmanagedType.IUnknown)] object items);
    void AppendKnownCategory(int category);
    void AddUserTasks([MarshalAs(UnmanagedType.IUnknown)] object tasks);
    void CommitList();
    void GetRemovedDestinations(ref Guid riid, [MarshalAs(UnmanagedType.IUnknown)] out object removed);
    [PreserveSig] int DeleteList([MarshalAs(UnmanagedType.LPWStr)] string id);
    void AbortList();
}
public static int Delete(string aumid) {
    int hr = 0;
    var t = new System.Threading.Thread(() => {
        try {
            var list = (ICustomDestinationList)new DestinationList();
            hr = list.DeleteList(aumid);
        } catch (Exception e) { hr = e.HResult; }
    });
    t.SetApartmentState(System.Threading.ApartmentState.STA);
    t.Start();
    t.Join();
    return hr;
}
"@
}

function Remove-E2eJumpList {
    foreach ($id in $script:JumpListAumids) { try { [void][GhosttyE2e.JumpListNative]::Delete($id) } catch {} }
}

function Get-JumpListState($Class) {
    (Get-GhosttyState -Class $Class).m5.jumplist
}

Invoke-E2eScenario 'jumplist' {
    try {
        # The shell keeps the list files under %USERPROFILE%\AppData (the sandbox's;
        # the real taskbar never sees them), where the folders do not exist yet.
        foreach ($d in 'CustomDestinations', 'AutomaticDestinations') {
            New-Item -ItemType Directory -Force -Path (Join-Path $script:Sbx.Home "AppData\Roaming\Microsoft\Windows\Recent\$d") | Out-Null
        }

        # 1. The list is built.
        $a = Start-E2eGhostty
        $st = Wait-GhosttyState -Class $a.Class -TimeoutSec 30 -Predicate {
            $j = $_.m5.jumplist
            $null -ne $j -and $j.runs -ge 1 -and $null -ne $j.hr_commit
        }
        $j = $st.m5.jumplist
        if ($j.hr_begin -ne 0) { throw "BeginList hr = $($j.hr_begin)" }
        if ($j.hr_commit -ne 0) { throw "CommitList hr = $($j.hr_commit)" }
        if ($j.hr_delete -ne 0) { throw "the test reset DeleteList hr = $($j.hr_delete)" }
        $t = @($j.titles)
        if ($t.Count -lt 4) { throw "expected at least 4 entries, got: $($t -join ' | ')" }
        if ($t[0] -ne 'New Window' -or $t[1] -ne 'New Tab' -or $t[2] -ne '-') { throw "unexpected head of the list: $($t[0..2] -join ' | ')" }
        if ($t -contains 'Default') { throw 'the Default profile has a task' }
        Write-E2eInfo "jump list: $($t -join ' | ')"

        # 2. Quitting deletes the test list.
        # The process may exit before the answer is complete.
        try { [void](Invoke-GhosttyAction -Class $a.Class -Action 'quit') } catch {}
        if (-not $a.Process.WaitForExit(15000)) { throw 'ghostty did not exit after quit' }
        $log = Get-Content -LiteralPath $a.Log -Raw -ErrorAction Stop
        if ($log -notlike '*(jumplist): deleted e2e list hr=0x0*') { throw 'the log has no "(jumplist): deleted e2e list hr=0x0" line' }

        # 3. +new-tab with no instance starts one.
        $class = 'ghostty-e2e-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        $sbx = $script:Sbx
        $vars = [ordered]@{
            USERPROFILE            = $sbx.Home
            HOME                   = $sbx.Home
            LOCALAPPDATA           = $sbx.Local
            APPDATA                = $sbx.Roaming
            TEMP                   = $sbx.Tmp
            TMP                    = $sbx.Tmp
            XDG_CONFIG_HOME        = (Join-Path $sbx.Home '.config')
            GHOSTTY_WIN32_TEST_IPC = '1'
        }
        $saved = @{}
        foreach ($n in $vars.Keys) { $saved[$n] = [Environment]::GetEnvironmentVariable($n, 'Process') }
        try {
            foreach ($n in $vars.Keys) { [Environment]::SetEnvironmentVariable($n, $vars[$n], 'Process') }
            $cli = Start-Process -FilePath $script:Exe -WorkingDirectory $script:Root -PassThru `
                -ArgumentList @('+new-tab', "--class=$class", '--working-directory=home')
        } finally {
            foreach ($n in $vars.Keys) { [Environment]::SetEnvironmentVariable($n, $saved[$n], 'Process') }
        }
        $null = $cli.Handle
        Register-OwnGhostty -ProcessId $cli.Id
        if (-not $cli.WaitForExit(15000)) { throw '+new-tab with no instance did not return within 15 s' }
        if ($cli.ExitCode -ne 0) { throw "+new-tab with no instance exited with $($cli.ExitCode)" }

        $started = $null
        $sw = [Diagnostics.Stopwatch]::StartNew()
        while ($sw.Elapsed.TotalSeconds -lt 15 -and -not $started) {
            $started = Get-CimInstance Win32_Process -Filter "Name='ghostty.exe'" |
                Where-Object { [string]$_.CommandLine -like "*--class=$class*" -and $_.ProcessId -ne $cli.Id } | Select-Object -First 1
            if (-not $started) { Start-Sleep -Milliseconds 100 }
        }
        if (-not $started) { throw "no Ghostty with class $class was started" }
        Register-OwnGhostty -ProcessId $started.ProcessId
        if ([string]$started.CommandLine -notlike '*--working-directory=home*') { throw "the started instance lost --working-directory: $($started.CommandLine)" }
        $win = $null
        $sw.Restart()
        while ($sw.Elapsed.TotalSeconds -lt 15 -and -not $win) {
            $win = Find-GhosttyWindows ([int]$started.ProcessId) | Select-Object -First 1
            if (-not $win) { Start-Sleep -Milliseconds 100 }
        }
        if (-not $win) { throw 'the started instance showed no window' }
        [void](Wait-GhosttyState -Class $class -TimeoutSec 10 -Predicate { @($_.windows).Count -eq 1 })
        try { [void](Invoke-GhosttyAction -Class $class -Action 'quit') } catch {}
        $p = Get-Process -Id $started.ProcessId -ErrorAction SilentlyContinue
        if ($p -and -not $p.WaitForExit(15000)) { throw 'the started instance did not exit after quit' }
    } finally {
        Remove-E2eJumpList
    }
}
