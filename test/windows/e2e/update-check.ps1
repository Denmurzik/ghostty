# e2e: milestone=M5 timeout=420 order=968
# update-check: the update check against a fake release server on 127.0.0.1
# (GHOSTTY_WIN32_UPDATE_URL, honoured in test mode only). Every check is the
# `check_for_updates` action. Cases: a newer release (one recorded toast, a
# second check adds none, the dialog is dismissed through the test message),
# the same release, an HTML body, HTTP 403, a server that never answers
# (failed within 11 s), a stopped server, a quit during a silent check (<= 3 s),
# a build without -win.N (the "local build" outcome), and a test-mode Ghostty
# without the override (no `update: fetching` line, not even after 70 s).
# Every `update: fetching` line must name 127.0.0.1. No real network.
# Keep this file ASCII only.
. (Join-Path $PSScriptRoot '_common.ps1')
. (Join-Path $PSScriptRoot '_m5_fakeserver.ps1')
Import-Module (Join-Path $script:WinDir 'lib\GhosttyIpc.psm1') -Force

$script:Fixtures = Join-Path $script:Root 'src\apprt\win32\update\testdata'
function Get-Fixture([string]$Name) { Join-Path $script:Fixtures "$Name.json" }

function Get-Update($G) { (Get-GhosttyState -Class $G.Class).m5.update }

function Get-FetchLines($G) {
    if (-not (Test-Path -LiteralPath $G.Log)) { return @() }
    @(Select-String -LiteralPath $G.Log -Pattern 'update: fetching' | ForEach-Object { $_.Line })
}

# Presses the "Close" button of the update dialog (WM_USER + 102, button 2).
function Close-UpdateDialog($G, [string]$What) {
    $dlg = Wait-Until -TimeoutSec 10 -PollMs 100 -Condition {
        [GhosttyE2e.Win]::TopLevel([uint32]$G.Pid, 'GhosttyDialog') | Where-Object { [GhosttyE2e.Win]::IsWindowVisible($_) } | Select-Object -First 1
    }
    if (-not $dlg) { throw "$What : no dialog (GhosttyDialog) within 10 s, state: $((Get-Update $G) | ConvertTo-Json -Compress -Depth 5)" }
    [void][GhosttyE2e.Win]::PostMessageW($dlg, 0x400 + 102, [IntPtr]2, [IntPtr]::Zero)
    $gone = Wait-Until -TimeoutSec 10 -PollMs 100 -Condition { -not [GhosttyE2e.Win]::IsWindow($dlg) }
    if (-not $gone) { throw "$What : the dialog did not close" }
}

# Runs one manual check and waits for its result (and dismisses the dialog).
function Invoke-Check($G, [string]$What, [double]$ResultSec = 15) {
    $before = (Get-Update $G).results
    $sw = [Diagnostics.Stopwatch]::StartNew()
    if (-not (Invoke-GhosttyAction -Class $G.Class -Action 'check_for_updates')) { throw "$What : check_for_updates was not performed" }
    $u = Wait-Until -TimeoutSec $ResultSec -PollMs 100 -Condition {
        $s = Get-Update $G
        if ($s.results -gt $before) { $s }
    }
    if (-not $u) { throw "$What : no result within $ResultSec s" }
    $elapsed = $sw.Elapsed.TotalSeconds
    Close-UpdateDialog $G $What
    [pscustomobject]@{ State = (Get-Update $G); Seconds = $elapsed }
}

function Get-RecordedTotal($G) { [int](Get-GhosttyState -Class $G.Class).m3.notify.total }

Invoke-E2eScenario 'update-check' {
    $fetchLines = @()
    $servers = @()
    try {
        # --- Instance A: the cases with a current release number of 3. -----------
        $srv = Start-FakeRelease -Body (Get-Fixture 'newer')
        $servers += $srv
        $g = Start-E2eGhostty -Env @{ GHOSTTY_WIN32_UPDATE_URL = $srv.Url; GHOSTTY_WIN32_TEST_CURRENT_N = '3' }

        $r = Invoke-Check $g 'newer'
        $last = $r.State.last
        if ($last.kind -ne 'newer' -or $last.n -ne 4 -or -not $last.manual) { throw "newer: last is $($last | ConvertTo-Json -Compress)" }
        if ($r.State.toasts -ne 1 -or (Get-RecordedTotal $g) -ne 1) { throw "newer: expected one toast, state $($r.State | ConvertTo-Json -Compress -Depth 5)" }
        $toast = @((Get-GhosttyState -Class $g.Class).m3.notify.recorded)[0]
        if ($toast.title -ne 'Ghostty 1.3.2-dev-win.4 is available' -or $toast.body -ne 'Open the release page') {
            throw "newer: toast is '$($toast.title)' / '$($toast.body)'"
        }
        $req = @($srv.Requests.ToArray())[0]
        if ($req -notmatch 'GET /repos/Denmurzik/ghostty/releases\?per_page=20' -or $req -notmatch 'UA=Ghostty/\S+ \(Windows\)' -or $req -notmatch 'Accept=application/vnd\.github\+json') {
            throw "newer: request was '$req'"
        }
        $state = Join-Path $script:Sbx.Local 'ghostty\update.json'
        if (-not (Test-Path -LiteralPath $state)) { throw 'newer: no update.json was written' }
        if ((Get-Content -LiteralPath $state -Raw) -notmatch '"notified":4') { throw "newer: update.json is $(Get-Content -LiteralPath $state -Raw)" }

        $r = Invoke-Check $g 'newer again'
        if ($r.State.toasts -ne 1 -or (Get-RecordedTotal $g) -ne 1) { throw "newer again: a second toast was shown, state $($r.State | ConvertTo-Json -Compress -Depth 5)" }
        if ($r.State.last.kind -ne 'newer') { throw "newer again: last is $($r.State.last | ConvertTo-Json -Compress)" }

        Set-FakeRelease $srv -Body (Get-Fixture 'same')
        $r = Invoke-Check $g 'same'
        if ($r.State.last.kind -ne 'current') { throw "same: last is $($r.State.last | ConvertTo-Json -Compress)" }

        Set-FakeRelease $srv -Body (Get-Fixture 'html')
        $r = Invoke-Check $g 'html'
        if ($r.State.last.kind -ne 'failed') { throw "html: last is $($r.State.last | ConvertTo-Json -Compress)" }
        if ($r.State.toasts -ne 1) { throw 'html: a toast was shown' }

        Set-FakeRelease $srv -Body (Get-Fixture 'newer') -Status 403
        $r = Invoke-Check $g '403'
        if ($r.State.last.kind -ne 'failed' -or $r.State.last.error -notmatch '403') { throw "403: last is $($r.State.last | ConvertTo-Json -Compress)" }

        # A server that accepts and never answers: failed within 11 s.
        Set-FakeRelease $srv -Silent
        $r = Invoke-Check $g 'silent' 14
        if ($r.State.last.kind -ne 'failed') { throw "silent: last is $($r.State.last | ConvertTo-Json -Compress)" }
        if ($r.Seconds -gt 11) { throw "silent: failed after $([math]::Round($r.Seconds, 1)) s, expected within 11 s" }
        Write-E2eInfo "silent server: failed after $([math]::Round($r.Seconds, 1)) s ($($r.State.last.error))"

        # A stopped server: the connection is refused.
        Stop-FakeRelease $srv
        $r = Invoke-Check $g 'stopped'
        if ($r.State.last.kind -ne 'failed') { throw "stopped: last is $($r.State.last | ConvertTo-Json -Compress)" }
        if ($r.State.toasts -ne 1) { throw 'stopped: a toast was shown' }

        $fetchLines = @(Get-FetchLines $g)
        if ($fetchLines.Count -lt 7) { throw "expected a fetching line per check (7), got $($fetchLines.Count)" }
        Invoke-GhosttyAction -Class $g.Class -Action 'quit' | Out-Null
        [void](Wait-ProcessExit $g 10)

        # --- Instance B: a quit during a check that never gets an answer. ---------
        $srv = Start-FakeRelease -Body (Get-Fixture 'newer') -Silent
        $servers += $srv
        $g = Start-E2eGhostty -Env @{ GHOSTTY_WIN32_UPDATE_URL = $srv.Url; GHOSTTY_WIN32_TEST_CURRENT_N = '3' }
        if (-not (Invoke-GhosttyAction -Class $g.Class -Action 'check_for_updates')) { throw 'quit: check_for_updates was not performed' }
        $accepted = Wait-Until -TimeoutSec 10 -PollMs 50 -Condition { (Get-FakeAccepted $srv) -ge 1 }
        if (-not $accepted) { throw 'quit: the fetch never reached the server' }
        $sw = [Diagnostics.Stopwatch]::StartNew()
        Invoke-GhosttyAction -Class $g.Class -Action 'quit' | Out-Null
        $exit = Wait-ProcessExit $g 10
        if (-not $exit.Exited) { throw 'quit: ghostty did not exit within 10 s of a quit during a check' }
        # The worker's own bound is 2 s; 1 s is allowed for the rest of the teardown.
        if ($sw.Elapsed.TotalSeconds -gt 3) { throw "quit: exit took $([math]::Round($sw.Elapsed.TotalSeconds, 1)) s, expected at most 3 s" }
        Write-E2eInfo "quit during a silent check: exited after $([math]::Round($sw.Elapsed.TotalSeconds, 1)) s"
        $fetchLines = @(Get-FetchLines $g)

        # --- Instance C: no current release number (a local build). ---------------
        $srv = Start-FakeRelease -Body (Get-Fixture 'newer')
        $servers += $srv
        $g = Start-E2eGhostty -Env @{ GHOSTTY_WIN32_UPDATE_URL = $srv.Url }
        $r = Invoke-Check $g 'local'
        if ($r.State.last.kind -ne 'local' -or $r.State.last.n -ne 4) { throw "local: last is $($r.State.last | ConvertTo-Json -Compress)" }
        if ($r.State.toasts -ne 0) { throw 'local: a toast was shown' }
        $fetchLines = @(Get-FetchLines $g)
        Invoke-GhosttyAction -Class $g.Class -Action 'quit' | Out-Null
        [void](Wait-ProcessExit $g 10)

        # --- Instance D: test mode without the override never fetches. ------------
        $g = Start-E2eGhostty -Env @{ GHOSTTY_WIN32_TEST_CURRENT_N = '3' }
        $r = Invoke-Check $g 'no override'
        if ($r.State.last.kind -ne 'failed') { throw "no override: last is $($r.State.last | ConvertTo-Json -Compress)" }
        Start-Sleep -Seconds 70
        $u = Get-Update $g
        if ($u.fetches -ne 0) { throw "no override: $($u.fetches) fetch(es) started" }
        # The sandbox shares one log file: nothing may have been added by this instance.
        if ((Get-FetchLines $g).Count -ne $fetchLines.Count) { throw 'no override: this instance logged an `update: fetching` line' }
        Invoke-GhosttyAction -Class $g.Class -Action 'quit' | Out-Null
        [void](Wait-ProcessExit $g 10)

        # --- Every fetched URL is loopback. ---------------------------------------
        foreach ($line in $fetchLines) {
            if ($line -notmatch 'update: fetching http://127\.0\.0\.1:\d+/') { throw "a fetch went elsewhere: $line" }
        }
    } finally {
        foreach ($s in $servers) { try { Stop-FakeRelease $s } catch { } }
    }
}
