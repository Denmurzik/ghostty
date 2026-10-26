# ConPTY sequence probe (M3 Task 28, input to lead decision L1)

Question: which sequences survive the inbox ConPTY on the way to Ghostty with
`GHOSTTY_WIN32_CONPTY_FLAGS` = 0 (the default) and 8
(`PSEUDOCONSOLE_PASSTHROUGH_MODE`)?

Method: `test/windows/conpty-probe/run.ps1 -Flags 0,8 -Repeat 2` (Debug
`ghostty.exe`, Windows 11 10.0.26300, Git Bash 5 cases + `printf` only, one
fresh instance per row, own sandbox/config/class `ghostty-cprobe-<hex>`, test
IPC on, `conpty flags override flags=<n>` seen in every log). Every oracle
observes Ghostty, not the shell. Each (sequence, flags) pair was run twice;
both runs agree in every row.

## Arrival table

| Sequence (case) | flags 0 | flags 8 | Oracle |
|---|---|---|---|
| Kitty graphics APC (`kitty-apc`) | dropped x2 | dropped x2 | frame dump holds no `#ff00ff` pixel; the query (`a=q`) draws no `kitty graphics response` log line; cursor did not move (see below) |
| OSC 9 notification (`osc9`) | arrived x2 | arrived x2 | log `deferred action=.desktop_notification` |
| OSC 777 notify (`osc777`) | arrived x2 | arrived x2 | log `deferred action=.desktop_notification` |
| OSC 133 A/B/C/D (`osc133`) | arrived x2 | arrived x2 | logs `deferred action=.command_finished` and `command took` (C then D reached the surface) |
| OSC 8 hyperlink (`osc8`) | arrived x2 | arrived x2 | Ctrl held, pointer on the link: system cursor is `IDC_HAND` and the log has `deferred action=.mouse_over_link` |
| OSC 22 pointer shape (`osc22`, `crosshair`) | arrived x2 | arrived x2 | pointer over the surface: system cursor is `IDC_CROSS` |

No row is `mangled`. Raw rows with evidence: `%TEMP%\conpty-probe\results.csv`
of the run (rows are `case,flags,run,verdict,evidence`).

### Log excerpts (Debug log, `ghostty.log` of the instance)

```
osc9/osc777  2026-10-26T21:05:32.830Z debug(win32_actions): deferred action=.desktop_notification milestone=M3 (SPEC section 17 M3 list)
osc133       2026-10-26T21:04:35.690Z debug(win32_actions): deferred action=.command_finished milestone=M3 (SPEC section 17 M3 list)
             2026-10-26T21:04:35.690Z debug(surface): command took 21us
osc8         2026-10-26T21:05:19.654Z debug(win32_actions): deferred action=.mouse_over_link milestone=M3 (SPEC section 17 M3 list)
osc22        pointer over the surface is IDC_CROSS (GetCursorInfo hCursor == LoadCursor(IDC_CROSS))
conpty       info(conpty): conpty flags override flags=8
```

### Kitty APC: why "dropped" and not "renderer gap"

- No frame-dump pixel of the image colour in any of the 4 runs.
- The case first sends a query (`a=q`, always answered): `StreamHandler.apcEnd`
  logs `kitty graphics response` for any answered command; no such line exists
  in any of the 4 logs, so no APC reached the stream handler.
- The placement `c=16,r=4` would move the cursor 4 rows; the line printed after
  it ("PROBE kitty sent") lands on grid row 1 in every run (row 4 if the
  APC had arrived), independent of the renderer.
- The bytes the shell wrote are correct (checked with `od -c`): `ESC _ G ... ESC \`.

Caveat: there is no way to feed Ghostty the APC around ConPTY in this harness,
so the Ghostty side of the APC path has no positive control here (the kitty
vt-smoke cases of Task 3 cover it through libghostty-vt). Flags 8 is accepted
(no fallback logged) but changed nothing for the APC: either the inbox conhost
ignores the flag or its parser still swallows APC in passthrough mode.

## Side measurements under flags 8 (Debug build, 1 run, desktop shared)

| Measure | flags 8 | flags 0 (same session) |
|---|---|---|
| `input-latency` key echo, ghostty_owned p95 | 3.030 ms | 4.148 ms |
| key echo `conpty` stage p95 | 16.046 ms | 46.703 ms |
| key echo `total` p95 | 18.796 ms | 49.972 ms |
| samples (n) / bg-cpu | 199 / 35% | 164 / 20% |
| `stream-integrity` (20 MB, writer `type`) | PASS: 367922 of 367922 lines, 0 missing/changed/extra | PASS: same |
| throughput (Debug, until next shell command) | 0.1 MB/s | 0.1 MB/s |

Debug numbers, one run each, other agents were using the machine: they show
that flags 8 breaks neither echo nor stream integrity; they are not the G1
gate (ReleaseFast, >= 200 samples x 3 runs). The conpty stage looked shorter
with 8 in this run, which the G1 re-measure must confirm.

## Reading for L1

- Needed and arriving with flags 0: OSC 9, OSC 777, OSC 133, OSC 8, OSC 22.
  Nothing changes for them; Task 28.1 would not help them.
- Kitty graphics APC: dropped with both 0 and 8 on the inbox conhost. Task 28.1
  (default flags 8) does not fix it. Per the L1 rule this is "dropped with both":
  an owner-approved gap in `feature-checklist.md` unless a newer `conpty.dll` /
  `OpenConsole.exe` pair (`GHOSTTY_WIN32_CONPTY_DLL`, not tried: no download was
  approved) forwards it; the probe re-runs unchanged against such a DLL.
- Two harness facts the oracles rely on, useful for other scenarios: OSC 8 hover
  is only recognised with Ctrl held, and a DPI-unaware PowerShell sees scaled
  pointer coordinates (the probe calls `SetProcessDpiAwarenessContext(-4)`).
