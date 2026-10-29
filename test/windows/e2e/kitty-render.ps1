# e2e: milestone=M7 timeout=180 order=1110
# kitty-render: a Kitty graphics image reaches the screen through the
# bundled ConPTY (issues-after-v1 2a). The image is 2 magenta pixels
# (f=24, s=2, v=1) stretched to 8x2 cells at row 0, col 0; the frame dump
# is checked for magenta in exactly that rectangle.
#   1. pwsh with `windows-conpty = auto` (the bundled OpenConsole): the
#      rectangle is magenta, and the pane's console child is OpenConsole.exe.
#   2. Git Bash with `windows-conpty = bundled`: the same through printf.
#   3. Git Bash with `auto` (the inbox ConPTY drops APC): no magenta. This is
#      the documented limit; it PASSES when the image is absent.
#   4. `a=q` in pwsh: Ghostty answers (the sandbox log has
#      `kitty graphics response`). Whether the program receives the answer
#      is the a=q probe's question, not this scenario's.
. (Join-Path $PSScriptRoot '_common.ps1')
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\GhosttyIpc.psm1') -Force

Invoke-E2eScenario 'kitty-render' {
    $tmp = $script:Sbx.Tmp
    $tmpFwd = $tmp -replace '\\', '/'
    $noPad = "window-padding-x = 0`nwindow-padding-y = 0`nwindow-padding-balance = false`nconfirm-close-surface = false`n"

    # ESC _ G <control> ; <payload> ESC \  -- 2 magenta pixels, 8x2 cells.
    $imageApc = @('a=T,f=24,s=2,v=1,c=8,r=2', '/wD//wD/')
    $queryApc = @('i=31,s=1,v=1,a=q,t=d,f=24', 'AAAA')
    $box = @{}

    function Write-LfFile([string]$Path, [string[]]$Lines) {
        [IO.File]::WriteAllText($Path, (($Lines -join "`n") + "`n"), (New-Object Text.UTF8Encoding $false))
    }

    # pwsh: clear, write the sequence, drop a marker file, sleep.
    function New-PwshScript([string]$Name, [string[]]$Apc) {
        $path = Join-Path $tmp "$Name.ps1"
        Write-LfFile $path @(
            '$e = [string][char]27'
            '[Console]::Out.Write($e + "[2J" + $e + "[H")'
            ('[Console]::Out.Write($e + "_G' + $Apc[0] + ';' + $Apc[1] + '" + $e + [string][char]92)')
            '[Console]::Out.Flush()'
            ('Set-Content -LiteralPath "' + $tmpFwd + '/' + $Name + '.done" -Value done')
            'Start-Sleep -Seconds 600'
        )
        $path
    }
    function New-BashScript([string]$Name, [string[]]$Apc) {
        $path = Join-Path $tmp "$Name.sh"
        Write-LfFile $path @(
            "printf '\e[2J\e[H'"
            "printf '\e_G$($Apc[0]);$($Apc[1])\e\\'"
            ('echo done > "' + $tmpFwd + '/' + $Name + '.done"')
            'exec sleep 600'
        )
        $path
    }

    function Get-Cell($G) {
        # The condition runs in a child scope: its value is what Wait-Until returns.
        $w = Wait-Until -TimeoutSec 15 -PollMs 150 -Condition {
            $s = Get-GhosttyState -Class $G.Class
            $d = if ($s.PSObject.Properties['data']) { $s.data } else { $s }
            $x = @($d.windows)[0]
            if ($x -and [int]$x.cell[0] -gt 0 -and [int]$x.cell[1] -gt 0) { $x }
        }
        if (-not $w) { throw 'no cell size in the state' }
        , @([int]$w.cell[0], [int]$w.cell[1])
    }
    # Share of pixels within 24 of #ff00ff in the 8x2-cell rectangle at 0,0.
    function Measure-Magenta($D, [int[]]$Cell) {
        $w = [Math]::Min($D.Width, 8 * $Cell[0])
        $h = [Math]::Min($D.Height, 2 * $Cell[1])
        $hit = 0
        for ($y = 0; $y -lt $h; $y++) {
            $row = if ($D.TopDown) { $y } else { $D.Height - 1 - $y }
            $o = 54 + $row * $D.Width * 4
            for ($x = 0; $x -lt $w; $x++) {
                $i = $o + $x * 4
                if ([Math]::Abs([int]$D.Bytes[$i + 2] - 255) -le 24 -and [int]$D.Bytes[$i + 1] -le 24 -and [Math]::Abs([int]$D.Bytes[$i] - 255) -le 24) { $hit++ }
            }
        }
        [pscustomobject]@{ Hit = $hit; Total = $w * $h; Share = if ($w * $h) { $hit / [double]($w * $h) } else { 0.0 } }
    }

    function Close-Pane($G) {
        [void](Invoke-GhosttyAction -Class $G.Class -Action 'close_all_windows')
        [void](Wait-ProcessExit $G 8)
    }

    # --- 1. pwsh on the bundled console ---------------------------------------
    $k1 = New-PwshScript 'k1' $imageApc
    $cfg = "command = direct:powershell.exe -NoProfile -NoLogo -File $($k1 -replace '\\', '/')`nwindows-conpty = auto`n$noPad"
    $g = Start-E2eGhostty -ConfigText $cfg
    if (-not (Wait-File (Join-Path $tmp 'k1.done') 30)) { throw 'the pwsh script never ran' }
    $cell = Get-Cell $g
        $d = Wait-Dump $g {
        param($d)
        $box.m1 = Measure-Magenta $d $cell
        $box.m1.Share -ge 0.9
    } 15
    $m = $box.m1
    Save-Evidence -Tag 'pwsh-bundled' -G $g -Window
    if (-not $d) { throw ("pwsh/bundled: {0} of {1} pixels ({2:P0}) of the 8x2-cell rectangle are magenta, expected >= 90 %" -f $m.Hit, $m.Total, $m.Share) }
    Write-E2eInfo ("pwsh/bundled: {0:P0} of the 8x2-cell rectangle is magenta (cell {1}x{2})" -f $m.Share, $cell[0], $cell[1])
    $oc = @(Get-ProcessTree $g.Pid | Where-Object { $_.Name -ieq 'OpenConsole.exe' })
    if (-not $oc.Count) { throw "pwsh/bundled: no OpenConsole.exe under ghostty: $(Format-Procs @(Get-ProcessTree $g.Pid))" }
    $ocPath = (Get-CimInstance Win32_Process -Filter "ProcessId=$($oc[0].ProcessId)").ExecutablePath
    Write-E2eInfo "pwsh/bundled: console host $ocPath"
    Close-Pane $g

    # --- 2. Git Bash with windows-conpty = bundled -----------------------------
    $k2 = New-BashScript 'k2' $imageApc
    $g = Start-BashE2e -ExtraConfig ("windows-conpty = bundled`n" + $noPad)
    Send-Line $g.Hwnd 'bash "$TEMP/k2.sh"'
    if (-not (Wait-File (Join-Path $tmp 'k2.done') 30)) { throw 'the Git Bash script never ran' }
    $cell = Get-Cell $g
    $d = Wait-Dump $g {
        param($d)
        $box.m2 = Measure-Magenta $d $cell
        $box.m2.Share -ge 0.9
    } 15
    $m = $box.m2
    Save-Evidence -Tag 'bash-bundled' -G $g -Window
    if (-not $d) { throw ("bash/bundled: {0} of {1} pixels ({2:P0}) of the 8x2-cell rectangle are magenta, expected >= 90 %" -f $m.Hit, $m.Total, $m.Share) }
    Write-E2eInfo ("bash/bundled: {0:P0} of the rectangle is magenta" -f $m.Share)
    Close-Pane $g

    # --- 3. Git Bash with auto (inbox): the documented limit ---------------------
    $k3 = New-BashScript 'k3' $imageApc
    $g = Start-BashE2e -ExtraConfig ("windows-conpty = auto`n" + $noPad)
    Send-Line $g.Hwnd 'bash "$TEMP/k3.sh"'
    if (-not (Wait-File (Join-Path $tmp 'k3.done') 30)) { throw 'the Git Bash script never ran' }
    Start-Sleep -Seconds 2
    $cell = Get-Cell $g
    $d = Read-Dump $g.Dump
    if (-not $d) { throw 'no frame dump' }
    $m = Measure-Magenta $d $cell
    Save-Evidence -Tag 'bash-inbox' -G $g -Window
    if ($m.Hit -gt 0) {
        throw ("bash/auto: {0} magenta pixels in the rectangle; the inbox console was expected to drop the image (if it forwards it now, the limit is gone: update the docs)" -f $m.Hit)
    }
    Write-E2eInfo 'bash/auto: no magenta pixel (the documented inbox limit)'
    Close-Pane $g

    # --- 4. a=q in pwsh: Ghostty answers ----------------------------------------
    $k4 = New-PwshScript 'k4' $queryApc
    $cfg = "command = direct:powershell.exe -NoProfile -NoLogo -File $($k4 -replace '\\', '/')`nwindows-conpty = auto`n$noPad"
    $g = Start-E2eGhostty -ConfigText $cfg
    if (-not (Wait-File (Join-Path $tmp 'k4.done') 30)) { throw 'the a=q script never ran' }
    $answered = Wait-Until -TimeoutSec 10 -PollMs 250 -Condition {
        (Test-Path -LiteralPath $g.Log) -and ((Get-Content -LiteralPath $g.Log -Raw -ErrorAction SilentlyContinue) -match 'kitty graphics response')
    }
    Save-Evidence -Tag 'pwsh-query' -G $g
    if (-not $answered) { throw "a=q: the log has no 'kitty graphics response' ($($g.Log))" }
    Write-E2eInfo 'a=q: Ghostty answered (log: kitty graphics response)'
    Close-Pane $g
}
