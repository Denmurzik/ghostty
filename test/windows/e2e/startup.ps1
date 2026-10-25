# startup: the window appears within 1.5 s, a shell child runs and starts in
# %USERPROFILE%.
. (Join-Path $PSScriptRoot '_common.ps1')

Invoke-E2eScenario 'startup' {
    $limitMs = 1500

    # A cold first start (fresh exe, disk cache) may be slower: the best of
    # two starts counts, both are reported.
    $g = Start-E2eGhostty
    $times = @($g.StartupMs)
    if ($g.StartupMs -gt $limitMs) {
        Stop-OwnGhostty
        $g = Start-E2eGhostty
        $times += $g.StartupMs
    }
    Write-E2eInfo ("window after {0} ms (limit {1} ms)" -f ($times -join ' ms, then '), $limitMs)
    if (($times | Measure-Object -Minimum).Minimum -gt $limitMs) {
        throw "window took $($times -join ' / ') ms, limit $limitMs ms"
    }

    $shell = Get-ShellProcess $g
    if (-not $shell) {
        throw "no bash.exe/pwsh.exe/cmd.exe child of ghostty (pid $($g.Pid)); tree: $(Format-Procs (Get-ProcessTree $g.Pid))"
    }
    Write-E2eInfo "shell child: $($shell.Name) pid $($shell.ProcessId)"

    Wait-BashReady $g
    Send-Line $g.Hwnd 'pwd -W > "$TEMP/gt-cwd.txt"'
    $file = Join-Path $g.Sandbox.Tmp 'gt-cwd.txt'
    if (-not (Wait-File $file 20)) { throw 'pwd -W output never appeared' }

    $cwd = (Get-Content -LiteralPath $file -Raw).Trim().Replace('/', '\').TrimEnd('\')
    $want = $g.Sandbox.Home.TrimEnd('\')
    if ($cwd -ne $want) { throw "shell cwd is '$cwd', expected USERPROFILE '$want'" }
    Save-Evidence 'shell' $g
}
