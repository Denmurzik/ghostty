# e2e: milestone=M6 timeout=180 order=1000
# package-portable: the release zip, unpacked like a browser download (Zone.Identifier
# on the zip and on every extracted file) into a path with a space and a Cyrillic
# letter, runs from there: +version, +list-themes, a cmd session with the
# resources dir, TERM and tmux.exe from the folder, the bundled OpenConsole.exe
# running from the folder, a clean close, a moved share\ (TERM falls back with one
# warning) and no writes into the folder. Input: GHOSTTY_E2E_PACKAGE=<zip>.
. (Join-Path $PSScriptRoot '_common.ps1')

function Set-Motw([string]$Path) {
    Set-Content -LiteralPath $Path -Stream Zone.Identifier -Value "[ZoneTransfer]`r`nZoneId=3" -Encoding ASCII
}

function Get-FolderFiles([string]$Dir) {
    @(Get-ChildItem -LiteralPath $Dir -Recurse -Force -File | ForEach-Object { $_.FullName.Substring($Dir.Length) } | Sort-Object)
}

# A GUI-subsystem exe: run it to completion with stdout redirected to a file.
function Invoke-Cli([string[]]$CliArgs) {
    $o = Join-Path $script:Sbx.Tmp ([guid]::NewGuid().ToString('N') + '.out')
    $p = Start-Process -FilePath $script:Exe -ArgumentList $CliArgs -RedirectStandardOutput $o -WindowStyle Hidden -Wait -PassThru
    if ($p.ExitCode -ne 0) { throw "ghostty $CliArgs exited $($p.ExitCode)" }
    [IO.File]::ReadAllText($o)
}

# Types one line into the cmd session; its output goes to a file (code page 65001).
function Get-CmdAnswer($G, [string]$Command, [string]$Tag) {
    $out = Join-Path $script:Sbx.Tmp "$Tag.txt"
    Remove-Item -LiteralPath $out -ErrorAction SilentlyContinue
    Send-Line $G.Hwnd "$Command > `"$out`" 2>&1"
    # Complete once the last byte is a newline (cmd opens the file before it writes).
    $done = Wait-Until -TimeoutSec 20 -PollMs 100 -Condition {
        try { $b = [IO.File]::ReadAllBytes($out); $b.Length -gt 0 -and $b[$b.Length - 1] -eq 10 } catch { $false }
    }
    if (-not $done) { throw "cmd never answered '$Command'" }
    ,@((Read-ShellFile $out).Utf8 -split "`r?`n" | ForEach-Object { $_.Trim([char]0xFEFF).Trim() } | Where-Object { $_ })
}

Invoke-E2eScenario 'package-portable' {
    if (-not $env:GHOSTTY_E2E_PACKAGE) { throw 'E2E-SKIP: no package (set GHOSTTY_E2E_PACKAGE)' }
    $zipSrc = $env:GHOSTTY_E2E_PACKAGE
    if (-not (Test-Path -LiteralPath $zipSrc -PathType Leaf)) { throw "GHOSTTY_E2E_PACKAGE does not exist: $zipSrc" }

    # --- Mark-of-the-Web copy, extracted into a spaced Cyrillic path ---
    $zip = Join-Path $script:Sbx.Tmp (Split-Path -Leaf $zipSrc)
    Copy-Item -LiteralPath $zipSrc -Destination $zip
    Set-Motw $zip
    $zhe = [string][char]0x0416
    $dest = Join-Path $script:Sbx.Root "Portable $zhe"
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::ExtractToDirectory($zip, $dest)
    $kids = @(Get-ChildItem -LiteralPath $dest)
    if ($kids.Count -ne 1 -or -not $kids[0].PSIsContainer) { throw "expected one top folder in the zip, got: $($kids.Name -join ', ')" }
    $dir = $kids[0].FullName
    if ($kids[0].Name -notmatch '^ghostty-(.+)-windows-(x64|arm64)$') { throw "unexpected top folder name '$($kids[0].Name)'" }
    $version = $Matches[1]
    # Expansion does not carry the mark; Explorer's extraction does, so do the same.
    foreach ($f in Get-ChildItem -LiteralPath $dir -Recurse -File) { Set-Motw $f.FullName }
    $script:Exe = Join-Path $dir 'ghostty.exe'
    foreach ($n in 'ghostty.exe', 'tmux.exe', 'conpty.dll', 'OpenConsole.exe') {
        if (-not (Test-Path -LiteralPath (Join-Path $dir $n) -PathType Leaf)) { throw "$n is not in the extracted folder" }
    }
    $before = Get-FolderFiles $dir

    # --- CLI ---
    $ver = Invoke-Cli '+version'
    # A -Local package is named by hand and its exe carries the git version: set GHOSTTY_E2E_PACKAGE_VERSION=* to skip the match.
    $expect = if ($env:GHOSTTY_E2E_PACKAGE_VERSION) { $env:GHOSTTY_E2E_PACKAGE_VERSION } else { $version }
    if ($expect -ne '*' -and $ver -notlike "*$expect*") { throw "+version does not print '$expect': $ver" }
    $themes = @((Invoke-Cli '+list-themes', '--plain') -split "`r?`n" | Where-Object { $_ })
    if ($themes.Count -lt 100) { throw "+list-themes printed $($themes.Count) lines (<100): resources not found" }
    Write-E2eInfo "version=$version themes=$($themes.Count)"

    # --- session ---
    $cfg = "command = direct:cmd.exe /k`nconfirm-close-surface = false`n"
    $g = Start-E2eGhostty -ConfigText $cfg -NoDump
    [void](Set-ForegroundSafe -Hwnd $g.Hwnd)
    if (-not (Wait-ChildNamed $g @('cmd.exe') 20)) { throw 'cmd did not start' }
    Start-Sleep -Seconds 1
    [void](Get-CmdAnswer $g 'chcp 65001>nul' 'chcp')
    $resAll = (Get-CmdAnswer $g 'echo %GHOSTTY_RESOURCES_DIR%' 'res')
    Write-E2eInfo "resources answer: $($resAll -join ' | ')"
    $res = $resAll[0]
    if ($res -notlike "$dir*") { throw "GHOSTTY_RESOURCES_DIR '$res' is not under '$dir'" }
    $term = (Get-CmdAnswer $g 'echo %TERM%' 'term')[0]
    if ($term -ne 'xterm-ghostty') { throw "TERM is '$term'" }
    $where = (Get-CmdAnswer $g 'where tmux' 'where')[0]
    if ($where -ne (Join-Path $dir 'tmux.exe')) { throw "where tmux gave '$where', expected the extracted tmux.exe" }

    $tree = @(Get-ProcessTree $g.Pid)
    $oc = @($tree | Where-Object { $_.Name -ieq 'OpenConsole.exe' })
    if (-not $oc.Count) { throw "no OpenConsole.exe under ghostty: $(Format-Procs $tree)" }
    foreach ($p in $oc) {
        $path = (Get-CimInstance Win32_Process -Filter "ProcessId=$($p.ProcessId)").ExecutablePath
        if ($path -ne (Join-Path $dir 'OpenConsole.exe')) { throw "OpenConsole.exe runs from '$path', not from the extracted folder" }
    }

    # --- close ---
    [void]$g.Process.CloseMainWindow()
    $exit = Wait-ProcessExit $g 5
    if (-not $exit.Exited) { throw 'ghostty still running 5 s after the window was closed' }
    Assert-NoSurvivors $tree $g.Pid 8

    # --- moved share ---
    $share = Join-Path $dir 'share'
    Rename-Item -LiteralPath $share -NewName 'share.off'
    try {
        $g = Start-E2eGhostty -ConfigText $cfg -NoDump
        [void](Set-ForegroundSafe -Hwnd $g.Hwnd)
        if (-not (Wait-ChildNamed $g @('cmd.exe') 20)) { throw 'cmd did not start without share' }
        Start-Sleep -Seconds 1
        $t2 = (Get-CmdAnswer $g 'echo %TERM%' 'term2')[0]
        if ($t2 -ne 'xterm-256color') { throw "TERM without share is '$t2', expected xterm-256color" }
        $warn = @(Select-String -LiteralPath $g.Log -Pattern 'no resources dir set' -ErrorAction SilentlyContinue)
        if ($warn.Count -ne 1) { throw "expected one 'no resources dir set' warning in the log, got $($warn.Count)" }
        if (-not (Get-Process -Id $g.Pid -ErrorAction SilentlyContinue)) { throw 'ghostty crashed without share' }
        Stop-OwnGhostty
    } finally {
        Stop-OwnGhostty
        if (Test-Path -LiteralPath (Join-Path $dir 'share.off')) { Rename-Item -LiteralPath (Join-Path $dir 'share.off') -NewName 'share' }
    }

    # --- no writes ---
    $after = Get-FolderFiles $dir
    $diff = @(Compare-Object $before $after)
    if ($diff.Count) { throw "the extracted folder changed: $(($diff | ForEach-Object { $_.SideIndicator + $_.InputObject }) -join ', ')" }
}
