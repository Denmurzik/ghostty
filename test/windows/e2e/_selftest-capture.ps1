# Self-test of the capture guard's pure part (no GUI, no desktop access).
#   powershell -NoProfile -File test/windows/e2e/_selftest-capture.ps1
# ASCII only.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_common.ps1')
$fail = 0
function Check([string]$What, [bool]$Ok) {
    if ($Ok) { Write-Host "PASS $What" } else { Write-Host "FAIL $What"; $script:fail++ }
}
function Win([int]$L, [int]$T, [int]$R, [int]$B, [string]$Kind) {
    [pscustomobject]@{ L = $L; T = $T; R = $R; B = $B; Pid = 1; Own = ($Kind -ne 'foreign'); SeeThrough = ($Kind -eq 'glass') }
}
function Problem($wins) { Get-CaptureZOrderProblem @($wins) 100 100 400 300 }

# Opaque ours on top, a foreign window below it: hidden.
Check 'foreign below an opaque window of ours is hidden' ($null -eq (Problem @((Win 100 100 500 400 'own'), (Win 0 0 2000 1000 'foreign'))))
# A foreign window above ours: shown.
Check 'foreign above ours shows' ($null -ne (Problem @((Win 0 0 2000 1000 'foreign'), (Win 100 100 500 400 'own'))))
# Translucent ours on top: the foreign one below shows through.
Check 'foreign below a translucent window shows through' ($null -ne (Problem @((Win 100 100 500 400 'glass'), (Win 0 0 2000 1000 'foreign'))))
# Translucent ours over an opaque backdrop of ours: the foreign window is below the backdrop.
Check 'a backdrop under a translucent window hides the foreign one' ($null -eq (Problem @((Win 100 100 500 400 'glass'), (Win 80 80 520 420 'own'), (Win 0 0 2000 1000 'foreign'))))
# The backdrop is only above part of the foreign window's piece in the rect.
Check 'a backdrop that covers only part of the rect does not hide' ($null -ne (Problem @((Win 100 100 300 400 'glass'), (Win 100 100 300 400 'own'), (Win 0 0 2000 1000 'foreign'))))
# Nothing of ours in the rect.
Check 'no window of ours in the rect' ($null -ne (Problem @((Win 0 0 2000 1000 'foreign'))))
# A foreign window outside the rect does not matter.
Check 'foreign outside the rect is ignored' ($null -eq (Problem @((Win 100 100 500 400 'own'), (Win 900 900 1000 1000 'foreign'))))

Check 'translucent config: opacity' (Test-ConfigTranslucent "font-size = 12`nbackground-opacity = 0.5`n")
Check 'translucent config: blur' (Test-ConfigTranslucent "background-blur = true")
Check 'translucent config: command line' (Test-ConfigTranslucent '--background-opacity=0.9')
Check 'opaque config' (-not (Test-ConfigTranslucent "background = #000000`nfont-size = 12`n"))

if ($fail -gt 0) { Write-Host "$fail check(s) failed"; exit 1 }
Write-Host 'capture self-test OK'
