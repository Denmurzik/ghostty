# Shared helpers of the split scenarios (splits-basic, split-close, split-many).
# Dot-source it after _common.ps1. They read the test IPC `state` op and drive
# the app through `Invoke-GhosttyAction` (no keyboard input). Keep this file
# ASCII only (Windows PowerShell 5.1 reads a BOM-less script as ANSI).

Set-StrictMode -Version Latest

Import-Module (Join-Path $script:WinDir 'lib\GhosttyIpc.psm1') -Force

# The payload of a response: ops answer `{v, code, stdout, stderr, data}`.
function Get-IpcData($Response) {
    if ($null -ne $Response -and $Response.PSObject.Properties['data'] -and $null -ne $Response.data) { return $Response.data }
    $Response
}

# First window, its active tab and the surfaces of that tab.
function Get-SplitState($G) {
    $d = Get-IpcData (Get-GhosttyState -Class $G.Class)
    $w = @($d.windows)[0]
    $tab = @($w.tabs)[[int]$w.active_tab]
    [pscustomobject]@{ Window = $w; Tab = $tab; Surfaces = @($tab.surfaces) }
}

# rect = [l, t, r, b] in window client coordinates.
function ConvertTo-Box($Surface) {
    $r = @($Surface.rect)
    [pscustomobject]@{
        Id = [int]$Surface.id; CoreId = [string]$Surface.core_id; Visible = [bool]$Surface.visible
        Focused = [bool]$Surface.focused
        L = [int]$r[0]; T = [int]$r[1]; R = [int]$r[2]; B = [int]$r[3]
        W = [int]$r[2] - [int]$r[0]; H = [int]$r[3] - [int]$r[1]
    }
}

function Get-SurfaceBoxes($State) { @($State.Surfaces | ForEach-Object { ConvertTo-Box $_ }) }

# SplitLayout.gapPx: 4 px at 96 DPI scaled with rounding, at least 1.
function Get-SplitGap($State) {
    $dpi = [int]$State.Window.dpi
    [Math]::Max([int][Math]::Floor((4 * $dpi + 48) / 96), 1)
}

function Wait-SurfaceCount($G, [int]$Count, [double]$TimeoutSec = 10) {
    $st = Wait-Until -TimeoutSec $TimeoutSec -PollMs 100 -Condition {
        $s = Get-SplitState $G
        if ($s.Surfaces.Count -eq $Count) { $s }
    }
    if (-not $st) { throw "expected $Count surfaces, state shows $((Get-SplitState $G).Surfaces.Count) after $TimeoutSec s" }
    $st
}

# Runs one binding action; throws when the app did not perform it.
function Invoke-SplitAction($G, [string]$Action, [string]$Surface, [switch]$ExpectNotPerformed) {
    $a = @{ Class = $G.Class; Action = $Action }
    if ($Surface) { $a.Surface = $Surface }
    $r = Invoke-GhosttyAction @a
    $d = Get-IpcData $r
    $performed = if ($null -ne $d -and $d.PSObject.Properties['performed']) { [bool]$d.performed } else { $true }
    if ($ExpectNotPerformed) {
        if ($performed) { throw "action '$Action' was performed, expected not" }
    } elseif (-not $performed) {
        throw "action '$Action' was not performed"
    }
}

# Bounding box of the visible surfaces.
function Get-BoundingBox($Boxes) {
    $v = @($Boxes | Where-Object { $_.Visible })
    if ($v.Count -eq 0) { throw 'no visible surface' }
    [pscustomobject]@{
        L = ($v | Measure-Object L -Minimum).Minimum; T = ($v | Measure-Object T -Minimum).Minimum
        R = ($v | Measure-Object R -Maximum).Maximum; B = ($v | Measure-Object B -Maximum).Maximum
    }
}

# Every visible rect has w,h >= 0 and none overlaps another.
function Assert-NoOverlap($Boxes) {
    $v = @($Boxes | Where-Object { $_.Visible })
    foreach ($b in $v) {
        if ($b.W -lt 0 -or $b.H -lt 0) { throw "surface $($b.Id) has a negative size $($b.W)x$($b.H)" }
    }
    for ($i = 0; $i -lt $v.Count; $i++) {
        for ($j = $i + 1; $j -lt $v.Count; $j++) {
            $a = $v[$i]; $b = $v[$j]
            if ($a.W -le 0 -or $a.H -le 0 -or $b.W -le 0 -or $b.H -le 0) { continue }
            if ($a.L -lt $b.R -and $b.L -lt $a.R -and $a.T -lt $b.B -and $b.T -lt $a.B) {
                throw "surfaces $($a.Id) [$($a.L),$($a.T),$($a.R),$($a.B)] and $($b.Id) [$($b.L),$($b.T),$($b.R),$($b.B)] overlap"
            }
        }
    }
}
