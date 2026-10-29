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
| `CSI 8 ; 30 ; 100 t` (`csi8`, printed at start-up) | arrived x2 | arrived x1, dropped x1 | termio log `CSI 8 t resize request cols=100 rows=30` (the dropped run has no trace of it). conhost drops it now and then, and did in most scenario runs late in a session, after fullscreen/maximize round trips; conhost also sends its own `CSI 8 t` after every pty resize (log `CSI 8 t echo of a pty resize ignored cols=167 rows=51` 40 ms after the fullscreen resize) |

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

## DCS `tmux;` passthrough (M4 Task 2, input to C2)

Method: `run.ps1 -Flags 0,8 -Repeat 2 -Only dcs-tmux` (Debug `ghostty.exe`,
Windows 11 10.0.26300, same harness as above). `cases/probe-dcs-tmux.sh` prints
three sequences, 1.3 s apart because core rate-limits desktop notifications
to one per second (`rate limiting desktop notifications`), then a plain OSC 9
as the control. Oracle: the test-mode notifier records every notice that
reached core (`state.m3.notify.recorded`, title/body); the log line
`unknown DCS hook:` is recorded separately.

| Sequence | flags 0 | flags 8 | Oracle |
|---|---|---|---|
| `ESC P tmux; ESC ESC ] 9 ; m4-dcs-bel BEL ESC \` | arrived x2 | arrived x2 | notice body `m4-dcs-bel` (title `Ghostty`) |
| `ESC P tmux; ESC ESC ] 777;notify;m4;dcs-st ESC ESC \ ESC \` (brief's spelling) | dropped x2 | dropped x2 | no notice with body `dcs-st` |
| same, inner ST doubled as tmux requires (`ESC ESC ESC \ ESC \`) | dropped x2 | dropped x2 | no notice with body `dcs-st2` |
| plain `ESC ] 9 ; m4-plain BEL` (control) | arrived x2 | arrived x2 | notice body `m4-plain` |

`unknown DCS hook:` never appears in any of the 4 logs: Ghostty's parser never
saw a DCS with final byte `t`. Both runs agree in every row; flags 0 and 8
behave the same.

Reading: conhost does not forward the DCS as such. The BEL-terminated wrapper
arrives as the bare inner OSC 9 (conhost unwraps/re-emits the OSC), the
ST-terminated OSC 777 wrapper is lost entirely (not mangled into anything
Ghostty logs). So ConPTY gives no usable `ESC P tmux;` passthrough channel in
either mode; tmux-style DCS-wrapped payloads cannot be relied on to reach
the terminal.

## Bundled ConPTY: `Microsoft.Windows.Console.ConPTY` 1.25.260930003 (M5, headless)

Question: does the newer ConPTY (`conpty.dll` + `OpenConsole.exe` from the
official NuGet package, MIT, microsoft/terminal; Authenticode-signed by
Microsoft) forward what the inbox one drops?

Package files (x64 were probed; arm64 ship the same way, not run here):

| File | SHA-256 |
|---|---|
| `runtimes/win-x64/native/conpty.dll` | `feeef341d891643c62d30b6b07800bc70f0bc148f44cb8c3bee84aa557ae805a` |
| `build/native/runtimes/x64/OpenConsole.exe` | `3d66b23d0a71bb8eed2b77edc8b9df9bf54ce6c8fb74c863a30e760997f80586` |
| `runtimes/win-arm64/native/conpty.dll` | `151a02355227710c20c9f8f1eaf68ac4668aa09cdc921adc7ec661804d8eb1bf` |
| `build/native/runtimes/arm64/OpenConsole.exe` | `4313825a3ba634d113cc6ed3bc8ce735e3c19d360cecd985794787479469f91f` |

Method: `headless.ps1 -DllDir <dir with conpty.dll + OpenConsole.exe> -Repeat 2
-Samples 200` (Windows 11 10.0.26300). No window and no Ghostty: the script is
the terminal. It creates the pseudo console (kernel32, or the three functions
from the bundled `conpty.dll` loaded with `LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR |
SYSTEM32`), runs `cases/headless-seqs.sh` in Git Bash on it and reads the raw
output bytes, which are what Ghostty's parser would get. Every sequence sits
between text markers. The host answers DA1 (`ESC [ ?62;22c`, Ghostty's reply)
and `CSI 6 n` (with `24;77`) like a terminal. The child-process check confirms
which console ran: `conhost.exe` for inbox, `OpenConsole.exe` for bundled. Flag 8 means
`PSEUDOCONSOLE_PASSTHROUGH_MODE` to the inbox console, but
`PSEUDOCONSOLE_GLYPH_WIDTH_GRAPHEMES` to the bundled one (its `conpty.h` has no
passthrough flag any more).

| Sequence | inbox 0 | inbox 8 | bundled 0 | bundled 8 |
|---|---|---|---|---|
| Kitty graphics APC (`a=q` + `a=T`) | dropped x2 | dropped x2 | arrived x2, byte-identical | arrived x2 |
| SGR 58 (`4:3;58:2::r:g:b`, `4;58;5;n`, `4:1;58;2;r;g;b`) | mangled x2 (1 of 3; `58;5;196` turns into `\e[5m` blink) | same | arrived x2, byte-identical | arrived x2 |
| OSC 133 A/B/C/D | arrived x2 | arrived x2 | arrived x2 | arrived x2 |
| OSC 7 | arrived x2, moved (flushed later) | same | arrived x2, in place | arrived x2 |
| OSC 8 | arrived x2, rewritten (`id=<pid>-1` added) | same | arrived x2, byte-identical | arrived x2 |
| OSC 52 | arrived x2, moved | same | arrived x2, in place | arrived x2 |
| OSC 9 | arrived x2, moved | same | arrived x2, in place | arrived x2 |
| `stty size` after resize to 100x30 | `30 100` x2 | x2 | `30 100` x2 | x2 |
| app's `CSI 6 n` after a ZWJ emoji | answered by conhost (`9;6`: emoji counted 5 cells wide) | same | forwarded to the terminal | forwarded |

Key echo (cmd.exe cooked echo, write to echoed byte, 200 samples each, one
run per variant, desktop shared with other agents):

| | inbox 0 | inbox 8 | bundled 0 | bundled 8 |
|---|---|---|---|---|
| p50 | 0.27 ms | 0.34 ms | 0.29 ms | 0.24 ms |
| p95 | 15.20 ms | 15.00 ms | 0.66 ms | 0.91 ms |
| max | 16.41 ms | 16.46 ms | 0.81 ms | 4.25 ms |

The inbox p95 swings between about 0.6 and 15 ms from run to run (conhost's
16 ms paint timer). The bundled one stayed below 1 ms in all three trial runs.

What the bundled console sends that the inbox one does not, and what a terminal
must therefore answer:
- At start: `ESC [ 1 t`, `ESC [ c` (DA1), `ESC [ ? 1004 h`, `ESC [ ? 9001 h`. It
  waits for the DA1 reply. Ghostty answers DA1, and ignores `CSI 1 t`.
- `CSI 6 n`: it forwards the application's query to the terminal, and sends its
  own queries to resync its cursor after output it passed through. It then moves the
  cursor to whatever the terminal answered (`ESC [ 24;77 H` here). Ghostty answers from
  its own grid, so the cursor follows Ghostty's widths (grapheme clusters)
  instead of conhost's guess.

Unrelated to the console: once in 4 runs per console (inbox 8 and bundled 8,
same trial), the `g` of `go\r` typed 400 ms after a resize was lost before
MSYS `read` saw it. This is the known MSYS2 first-input-record-after-resize loss (feature
checklist, Task 26.4), which Ghostty works around.

Reading: the bundled ConPTY forwards Kitty graphics and SGR 58 unchanged, and
keeps OSC 7/8/52/9 in place and unrewritten. Resize works, and key echo is not slower
(p95 below 1 ms against the inbox console's timer-bound up to 15 ms). Flags: 0. The
grapheme-width flag (8) changes nothing the probe measures, and the bundled
console forwards cursor queries to Ghostty, so Ghostty's widths win either way.
A GUI check in Ghostty itself is still owed: `vt-smoke/kitty-image`,
`vt-smoke/underline-colors`.

## Kitty `a=q` reply path through ConPTY input (M7 Task 9)

Question: when the terminal answers a Kitty graphics query by writing the reply
to the ConPTY input, does the program read it? (Issue after v1, 2a, question 4.)

Method: `headless.ps1 -KittyQ -DllDir vendor/conpty/x64 -Flags 0 -Repeat 2`
(no window; the script is the terminal). When the output holds
`ESC _ G ... a=q ... ESC \`, the host writes `ESC _ G i=31;OK ESC \` to the
input, either `plain`, or `w32im`: every character of it as a win32-input-mode
key-down record `CSI 0;0;<unit>;1;0;1 _` (the R-M7-11 form). Clients: Git Bash
(`cases/headless-kittyq.sh`: the query, then `read -rs -t 2 -d '\'`, hex of what
it read; `-d '\'` stops at the final `\`, so it is not in the hex) and a native
exe (`New-FakeExe -Kind vtreader`: ENABLE_VIRTUAL_TERMINAL_INPUT, `FAKE_WAIT_MS`
2000, hex of every byte read). Bundled console: `vendor/conpty/x64`,
OpenConsole.exe / conpty.dll 1.25.2609.30003 (package 1.25.260930003). Inbox:
kernel32 on Windows 11 10.0.26300. Both runs of every cell agree.

| Console | Reply form | Git Bash read | Native read |
|---|---|---|---|
| inbox | plain | nothing (query never reached the host) | nothing (same) |
| inbox | w32im | nothing (same) | nothing (same) |
| bundled | plain | `1b5f47693d33313b4f4b1b` = `ESC _Gi=31;OK ESC` (+ `\` as the delimiter) | `1b5f47693d33313b4f4b1b5c` = `ESC _Gi=31;OK ESC \` |
| bundled | w32im | `1b5f47693d33313b4f4b1b` (same) | `1b5f47693d33313b4f4b1b5c` (same) |

Inbox: the console drops the `ESC _ G` query itself (see the arrival table
above), so the host never sees an `a=q` to answer; the reply path is not
reached and there is nothing to measure.

Verdict, bundled console:
- Git Bash: **plain arrives** (and the wrapped form arrives as the same plain bytes).
- native VT-input reader: **plain arrives** (and the wrapped form arrives as the same plain bytes).
- Neither cell loses the reply, so the wrapped form is not needed: OpenConsole
  passes the plain APC reply to the program intact, and decodes win32-input-mode
  character records back to the characters (the program sees identical bytes).

Consequence for Task 12: the condition "plain is lost and wrapped arrives" is
false for the bundled console; Task 12 is Step 4 only (no wrapping code).
Limits: this probe answers one question, whether a reply written to the
input reaches a program through ConPTY. It does not start Ghostty, so it cannot
say whether Ghostty parses the query or draws the image; `e2e/kitty-render`
covers that. The host here sends no `CSI ? 9001 h` of its own, so the
win32-input-mode cells only show how the console decodes character records.
A missing Kitty image in Claude Code is therefore not explained by a reply lost
in ConPTY input on the bundled console.
