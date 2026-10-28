# e2e: milestone=M4 timeout=60 order=700
# tmux-cli: the `tmux.exe` shim on its own, no Ghostty and no window. It
# answers -V locally, refuses to run without a server, starts fast and
# small, imports only kernel32 and ntdll, and its trace lines never
# interleave.
. (Join-Path $PSScriptRoot '_common.ps1')

$script:TmuxExe = Join-Path (Split-Path -Parent $script:Exe) 'tmux.exe'

# Runs tmux.exe with a clean environment (no inherited TMUX / TMUX_PANE /
# trace) plus $Env. Returns the exit code, the raw stdout bytes, stderr and
# the wall time of the process.
function Start-Tmux([string[]]$TmuxArgs, [hashtable]$Env = @{}) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $script:TmuxExe
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $true
    $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = $script:Sbx.Tmp
    # .NET Framework (Windows PowerShell 5.1) has no ArgumentList.
    $psi.Arguments = (@($TmuxArgs | ForEach-Object { '"' + ($_ -replace '"', '\"') + '"' }) -join ' ')
    foreach ($n in 'TMUX', 'TMUX_PANE', 'GHOSTTY_TMUX_TRACE', 'GHOSTTY_TMUX_STATS') {
        [void]$psi.EnvironmentVariables.Remove($n)
    }
    foreach ($k in $Env.Keys) { $psi.EnvironmentVariables[$k] = [string]$Env[$k] }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $p = [System.Diagnostics.Process]::Start($psi)
    $p.StandardInput.Close()
    [pscustomobject]@{ Process = $p; Watch = $sw }
}

function Wait-Tmux($Run) {
    $p = $Run.Process
    $ms = New-Object System.IO.MemoryStream
    $copy = $p.StandardOutput.BaseStream.CopyToAsync($ms)
    $errTask = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit(15000)) { try { $p.Kill() } catch {}; throw 'tmux.exe did not exit within 15 s' }
    $copy.Wait()
    $Run.Watch.Stop()
    [pscustomobject]@{
        Code   = $p.ExitCode
        Stdout = $ms.ToArray()
        Stderr = $errTask.Result
        WallMs = $Run.Watch.Elapsed.TotalMilliseconds
    }
}

function Invoke-Tmux([string[]]$TmuxArgs, [hashtable]$Env = @{}) {
    Wait-Tmux (Start-Tmux $TmuxArgs $Env)
}

# DLL names (lower case, comma separated) in the import directory of a PE file.
function Get-PeImports([string]$Path) {
    $b = [System.IO.File]::ReadAllBytes($Path)
    $pe = [BitConverter]::ToInt32($b, 0x3C)
    if ([BitConverter]::ToUInt32($b, $pe) -ne 0x00004550) { throw "$Path is not a PE file" }
    $nsec = [BitConverter]::ToUInt16($b, $pe + 6)
    $optSize = [BitConverter]::ToUInt16($b, $pe + 20)
    $opt = $pe + 24
    $magic = [BitConverter]::ToUInt16($b, $opt)
    $ddOff = if ($magic -eq 0x20B) { $opt + 112 } else { $opt + 96 }
    $impRva = [BitConverter]::ToUInt32($b, $ddOff + 8)
    $secs = $opt + $optSize
    function RvaToOff([uint32]$rva) {
        for ($i = 0; $i -lt $nsec; $i++) {
            $s = $secs + 40 * $i
            $va = [BitConverter]::ToUInt32($b, $s + 12)
            $vs = [Math]::Max([BitConverter]::ToUInt32($b, $s + 8), [BitConverter]::ToUInt32($b, $s + 16))
            if ($rva -ge $va -and $rva -lt $va + $vs) { return [int]($rva - $va + [BitConverter]::ToUInt32($b, $s + 20)) }
        }
        throw "RVA $rva is in no section"
    }
    $names = New-Object System.Collections.Generic.List[string]
    if ($impRva -eq 0) { return '' }
    $d = RvaToOff $impRva
    while ($true) {
        $nameRva = [BitConverter]::ToUInt32($b, $d + 12)
        if ($nameRva -eq 0) { break }
        $o = RvaToOff $nameRva
        $e = $o
        while ($b[$e] -ne 0) { $e++ }
        $names.Add([System.Text.Encoding]::ASCII.GetString($b, $o, $e - $o).ToLowerInvariant())
        $d += 20
    }
    $names -join ','
}

# Import names that are not on the allowlist.
function Get-ImportsOutsideAllowlist([string[]]$Imports) {
    $allowed = 'kernel32.dll', 'ntdll.dll', 'advapi32.dll'   # advapi32: the user identity of the external pipe (R-M5-14)
    @($Imports | Where-Object { $allowed -notcontains $_ })
}

Invoke-E2eScenario 'tmux-cli' {
    if (-not (Test-Path -LiteralPath $script:TmuxExe)) { throw "missing $script:TmuxExe (run zig build first)" }

    # -V is answered locally.
    $r = Invoke-Tmux @('-V')
    $text = [System.Text.Encoding]::UTF8.GetString($r.Stdout)
    if ($r.Code -ne 0) { throw "-V exited with $($r.Code)" }
    if ($text -cne "tmux 3.5a`n") { throw "-V printed '$($text -replace "`n", '\n')'" }

    # No TMUX and no -S: the external (user) pipe of an instance class that does
    # not exist, so no server (R-M5-14; the class keeps the owner's Ghostty out of it).
    $r = Invoke-Tmux @('display-message', '-p', 'x') @{ GHOSTTY_TMUX_CLASS = 'ghostty-e2e-no-such-class' }
    if ($r.Code -ne 1) { throw "no server: exit $($r.Code), expected 1" }
    if ($r.Stderr -ne "no server running on default`n") { throw "no server: stderr '$($r.Stderr)'" }

    # A pipe that does not exist is "no server" too, quickly.
    $ghost = '\\.\pipe\ghostty-tmux-1-0000000000000000'
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-Tmux @('-S', $ghost, 'list-panes')
    if ($r.Code -ne 1 -or $r.Stderr -notlike 'no server running on *') { throw "missing pipe: exit $($r.Code) stderr '$($r.Stderr)'" }
    if ($sw.ElapsedMilliseconds -gt 3000) { throw "missing pipe took $($sw.ElapsedMilliseconds) ms" }

    # 50 x -V with stats. Gated: the shim's own wall time (process start
    # excluded) p95 < 50 ms and peak private < 5 MB. The spawn wall time
    # (includes the .NET process start of this harness) is gated at 50 ms
    # only for a non-Debug tmux.exe and is recorded otherwise.
    $walls = New-Object System.Collections.Generic.List[double]
    $own = New-Object System.Collections.Generic.List[double]
    $peaks = New-Object System.Collections.Generic.List[int]
    $mode = ''
    for ($i = 0; $i -lt 50; $i++) {
        $r = Invoke-Tmux @('-V') @{ GHOSTTY_TMUX_STATS = '1' }
        if ($r.Code -ne 0) { throw "-V run $i exited with $($r.Code)" }
        if ($r.Stderr -notmatch 'tmux-stats peak_private_kb=(\d+) wall_ms=(\d+) build=(\w+)') { throw "run ${i}: no stats line in '$($r.Stderr)'" }
        $peaks.Add([int]$Matches[1])
        $own.Add([double]$Matches[2])
        $mode = $Matches[3]
        $walls.Add($r.WallMs)
    }
    function Get-P95([object[]]$v) { $x = @($v | Sort-Object); $x[[int][Math]::Ceiling(0.95 * $x.Count) - 1] }
    $p95 = Get-P95 $walls
    $ownP95 = Get-P95 $own
    $median = @($walls | Sort-Object)[[int]($walls.Count / 2)]
    $peak = ($peaks | Measure-Object -Maximum).Maximum
    Write-E2eInfo ('tmux.exe ({0}) -V x50: spawn wall median {1:N1} ms, p95 {2:N1} ms; own wall p95 {3:N1} ms; peak private {4} KB' -f $mode, $median, $p95, $ownP95, $peak)
    if ($ownP95 -ge 50) { throw ('own wall p95 {0:N1} ms is not under 50 ms' -f $ownP95) }
    if ($peak -ge 5120) { throw "peak private $peak KB is not under 5 MB" }
    if ($mode -ne 'debug' -and $p95 -ge 50) { throw ('spawn wall p95 {0:N1} ms is not under 50 ms ({1})' -f $p95, $mode) }

    # Import table: an allowlist, exactly a subset of kernel32, ntdll and advapi32.
    $imports = @((Get-PeImports $script:TmuxExe) -split ',' | Where-Object { $_ })
    if ($imports -notcontains 'kernel32.dll') { throw "import parser found no kernel32 in: $($imports -join ' ')" }
    Write-E2eInfo ('tmux.exe imports: ' + ($imports -join ', '))
    $extra = @(Get-ImportsOutsideAllowlist $imports)
    if ($extra.Count -gt 0) { throw "tmux.exe imports outside {kernel32.dll, ntdll.dll, advapi32.dll}: $($extra -join ', ')" }

    # Trace: one whole JSON line per invocation, also under parallel runs.
    $trace = Join-Path $script:Sbx.Tmp 'trace.jsonl'
    $r = Invoke-Tmux @('-V') @{ GHOSTTY_TMUX_TRACE = $trace }
    $lines = @(Get-Content -LiteralPath $trace -Encoding UTF8)
    if ($lines.Count -ne 1) { throw "trace has $($lines.Count) lines after one run" }
    $j = $lines[0] | ConvertFrom-Json
    if ($j.code -ne 0 -or $j.argv[0] -ne '-V') { throw "trace line is wrong: $($lines[0])" }
    foreach ($f in 't', 'argv', 'cwd', 'pane', 'code', 'ms', 'stdout_len', 'stdin_len') {
        if (-not $j.PSObject.Properties[$f]) { throw "trace line lacks '$f': $($lines[0])" }
    }

    Remove-Item -LiteralPath $trace
    $runs = @(1..8 | ForEach-Object { Start-Tmux @('-V') @{ GHOSTTY_TMUX_TRACE = $trace } })
    foreach ($run in $runs) { $res = Wait-Tmux $run; if ($res.Code -ne 0) { throw "parallel run exited with $($res.Code)" } }
    $lines = @(Get-Content -LiteralPath $trace -Encoding UTF8)
    if ($lines.Count -ne 8) { throw "8 parallel runs wrote $($lines.Count) trace lines" }
    foreach ($l in $lines) {
        try { [void]($l | ConvertFrom-Json) } catch { throw "trace line is not whole JSON: $l" }
    }
}
