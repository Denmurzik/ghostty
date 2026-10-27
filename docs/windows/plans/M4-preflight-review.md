# M4 pre-flight review

Plan: `docs/windows/plans/M4-tmux-shim.md` (15 tasks, 7 waves + C1/C2/G1). This is a read-only review against
DECISIONS, SPEC §5/§10/§12/§14/§15.6/§17/§18, recon `tmux.md`, the lead rulings (a)–(c) of 2026-10-28, and the code at
`e60878000`. No builds or GUI runs were done.

Code read: `ipc/{Server,client,protocol,ops}.zig`, `App.zig`, `Tab.zig`, `Surface.zig`, `Window.zig`
(close/remove paths, minimize), `hooks.zig`, `messages.zig`, `instance.zig`, `actions/surface_actions.zig`,
`datastruct/split_tree.zig`, `terminal/dcs.zig`, `terminal/parse_table.zig`, `termio/Exec.zig` (env/PATH),
`termio/stream_handler.zig` (DCS), `src/Surface.zig` `childExited`, `os/windows_shell.zig`, `test/windows/e2e.ps1`,
and `e2e/_common.ps1`.

Totals: **3 CRITICAL, 10 IMPORTANT, 22 MINOR.**

## CRITICAL

**1. Task 9 unwraps at a layer that never sees the payload, and the unwrap may not be needed at all (Tasks 2, 9; R-M4-10).**
The VT parser leaves `dcs_passthrough` on every ESC (`parse_table.zig:436`, test "dcs_passthrough: ESC, CAN, and SUB
still exit"). So `ESC P tmux; ESC ESC ] 9 ; msg BEL ESC \` reaches `dcs.Handler` as hook `t` plus `put("mux;")`, and
then `unhook` at the first ESC. The second ESC re-enters `escape`, and `]` starts a real OSC string. That OSC 9 is
dispatched by core today. An inner OSC terminated by ST (`ESC ESC \`) also ends through `osc_string → escape`. The
plan's Task 9 design (a `t` hook state with data `mux;` that collapses `ESC ESC` to ESC, then a re-feed in
`stream_handler.dcsCommand`) cannot work: `dcs.Handler` never receives an ESC byte. Doing it for real means changing
`Parser.zig`/`parse_table.zig`, which are core VT files, upstream-sensitive, and not in the M4 core touch points.

The Task 2 oracle has the same flaw. The `unknown DCS hook:` line with final `t` (`dcs.zig:37`) only shows that the
introducer arrived. It does not show whether the notification gets through.

Fix:
- Task 2 oracle, replace it with: "arrived = `m4-dcs-probe` reaches core as a desktop notification (`state.m3.notify`, or
  the `desktop_notification` log line), next to the plain control. Also record whether the `unknown DCS hook` line
  appears." Record both rows for flags 0 and 8.
- Task 9 Step 1, before anything else: a core test that feeds the exact wrapped bytes through `terminal.Stream` with a
  recording handler, for OSC 9, OSC 777 (ST-terminated) and OSC 0. Name it `"stream: tmux passthrough OSC reaches the
  handler"`.
  - If it passes (expected), Task 9 is tests only: no `dcs.zig`/`stream_handler.zig` change, and its review is light.
  - If it fails, Task 9 stops with evidence. The lead then rules on a `Parser.zig` touch point.
- R-M4-10 and the core touch-point list: reword to match the outcome. The SPEC §12.4 line "unwrapped by core and
  re-fed" becomes "works through the parser's ESC fall-through (verified by test)" if that holds.

**2. Lead ruling (a) is not in the plan; R-M4-11 decides the opposite (Global Constraints, Tasks 8 and 15, exit checklist 7).**
Ruling (a): a Windows-only config key turns off `TMUX`/`TMUX_PANE` and the PATH prepend, for people who use a real MSYS2
tmux. Default: on. R-M4-11 says "No opt-out knob in M4", Open question 5 is still open, and no task owns `Config.zig`.

Fix:
- Replace R-M4-11 with: "`windows-tmux-shim = true|false` (default `true`, Windows only, like
  `windows-single-instance` at `Config.zig:3838`). `false`: `env.apply` sets neither `TMUX` nor `TMUX_PANE`, leaves any
  inherited `TMUX`/`TMUX_PANE` untouched (pre-M4 behaviour), and does not prepend. Exec's own exe-dir append stays, so
  `tmux.exe` remains reachable last on PATH. The key is read per surface at spawn, so a reload affects new surfaces.
  The tmux pipe is still claimed, so turning the key on by reload works without a restart."
- M4 core touch points += `src/config/Config.zig` (one Windows-only key plus its doc comment).
- Task 8: Files += `Config.zig`. `env.Options` += `enabled: bool`. Tests `"win32 tmux env: disabled sets no TMUX and does
  not prepend"` and `"win32 tmux env: disabled keeps an inherited TMUX"`. `tmux-env.ps1` gets a second Ghostty with the
  key off and asserts `TMUX` is empty.
- Exit checklist 7, line 3: "with `windows-tmux-shim = false`, a user MSYS2 tmux works as before". Task 15
  feature-checklist row; CHANGELOG mentions the key.

**3. The real Claude Code runs (Task 1 Step 3, G1, Task 15 Step 3) cannot run as written, and the plan does not reflect ruling (c).**
- **Ruling (c) is missing.** Global Constraints still require per-run owner approval, and nothing pins the model, a
  time box or config isolation.
- **No login inside the harness.** `Start-E2eGhostty` points `USERPROFILE`, `HOME`, `APPDATA` and `LOCALAPPDATA` at the
  sandbox (`_common.ps1:402`). Claude started in that Ghostty finds no `~/.claude`, no credentials and no
  `~/.claude.json`, so it goes into onboarding/login and the run hangs. `CLAUDE_CONFIG_DIR` is supported (recon §6
  forwards it), but an isolated dir has no login. Copying `.credentials.json` into it is not safe: if the copy refreshes
  the OAuth token, rotation can invalidate the owner's refresh token and log the owner out.
- **Nested-session guard.** The lead's own Claude Code exports `CLAUDECODE=1` (plus `CLAUDE_CODE_ENTRYPOINT` and
  similar), and every Ghostty the harness starts inherits it. Current Claude Code refuses to start when `CLAUDECODE` is
  set ("cannot be launched inside another Claude Code session").
- **First-run prompts.** The trust prompt for a fresh temp dir is always shown, and a fresh config may also bring up
  onboarding or theme prompts. In default permission mode, team tools may ask for permission. None of these is answered
  by the scripted typing.
- **Task 1 has no driver.** "The operator types the prompt" into a `start cmd /k` conhost: nothing automates it, and
  it runs outside the desktop lock.
- **Inconsistent invocation.** Task 1 uses `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`, Task 15 uses `--agent-teams`.

Fix: a "Real Claude run" subsection in Global Constraints that both drivers implement, and the lead picks the auth
option:
- **Auth option A (preferred if the owner provides one):** an `ANTHROPIC_API_KEY` in the driver's env plus an isolated
  `CLAUDE_CONFIG_DIR=<sandbox>\claude`. Nothing of the owner's is touched.
- **Auth option B (ruling (c) fallback):** the real `USERPROFILE`/`HOME` are passed only to that Ghostty
  (`Start-E2eGhostty -Env`). `XDG_CONFIG_HOME` and `LOCALAPPDATA` stay sandboxed, so Ghostty's config and logs stay
  isolated. No `CLAUDE_CONFIG_DIR`, and `settings.json` is never edited. `teammateMode` comes from `--teammate-mode
  tmux`, permissions from `--settings <sandbox>\settings.json`, which allows only the team tools. Afterwards the driver
  deletes only what the run created: `~/.claude/teams/<team>/`, `~/.claude/projects/<encoded sandbox path>/`, and the
  sandbox's entry in `~/.claude.json`, through a JSON edit limited to that key, or the lead accepts that entry as a
  residue.
- **Never:** copy credentials.
- **Both options:**
  - `Start-E2eGhostty -Env @{ CLAUDECODE=$null; CLAUDE_CODE_ENTRYPOINT=$null; CLAUDE_CODE_SSE_PORT=$null }` (list every
    `CLAUDE_*` the lead's env has).
  - `--model haiku` (cheapest) and a prompt that asks teammates to use the same model.
  - A unique team name `m4-<yyyyMMddHHmmss>`.
  - A hard time box: 5 min for Task 1, 8 min per Task 15 run, after which the driver kills the process tree.
  - The driver answers the trust prompt once (Enter, verified with a dump) and fails on any other prompt it sees.
  - One spelling in both tasks: `--agent-teams --teammate-mode tmux`.
- **Task 1 Step 3:** run the capture in a scenario Ghostty (M3 build, Git Bash, desktop lock), with `PATH=<sandbox
  fake tmux>;…`, `TMUX=\\.\pipe\ghostty-tmux-capture,1,0` and `TMUX_PANE=%1` passed through `-Env`. Pre-M4 Ghostty does
  not set these itself. Type with the M3 26.1 re-send-and-verify pattern instead of an operator. This also lets
  Task 1 record whether real Claude emits `ESC P tmux;` (Debug log), which is ruling (b), see item 13.
- **Task 15 inbox check:** read under the active config dir, not a hard-coded `~/.claude`.

## IMPORTANT

**4. `WM_GHOSTTY_IPC` drops tmux requests in any process without the M2 pipe, and the client then hangs (Task 8).**
`App.zig:485`: `if (self.server == null) return 0;` runs before any dispatch. R-M4-1 makes every process claim a tmux
pipe, including the standalone one after `AddressInUse` (whose `server` is null). In such a process the tmux `Pending`
is never completed. The IPC thread waits `INFINITE` on `pending.done` (`Server.zig:333`), so that pipe is dead from
then on, and each `tmux.exe` waits out its 10 s.
Fix, Task 8: route on wparam first: `1 → if (tmux_server.server == null) return 0 else tmux_Server.handle`, and `0 →`
the existing guard. Test `"win32 tmux server: standalone process answers tmux"` (fake App with `server = null` and a
tmux server). Also say where `tmux_Server.start` goes: after `if (self.forwarded) return;` (`App.zig:149`), so a
forwarding launch does not claim a pipe, and before `Window.create`.

**5. Splits in a minimized window: no `split_layout`, and new panes are created at a stale size (Tasks 10, 12).**
A minimized window has a 0×0 client rect. `Tab.layout` then frees `split_layout` and returns (`Tab.zig:282`), and the
new surface keeps the full-tab size `Surface.create` gave it. The user cannot split a minimized window, but Claude can
(teammates spawn while the owner has Ghostty minimized). Task 12 reads `tab.split_layout` for `fits`,
`pane_top/left/width/height` and `resize-pane`. A `.?` there panics, and a guessed size makes `no space` decisions
wrong.
Fix:
- Task 10: `Tab` keeps `last_content: geom.Rect`, updated by every non-empty `layout`. `splitWith`/`replaceSurface`
  compute the leaf rects from it with `SplitLayout.compute` when the window is iconic, and size the new surface from
  that.
- Task 12: every Host function that needs rects uses the same fallback (no `.?` on `split_layout`).
- Tests: `"win32 tmux registry: geometry while minimized"` (pure, over the layout helper). A `tmux-replay.ps1` step:
  minimize, then split + respawn + `display-message -p '#{pane_width}'` (non-zero), restore, then the panes are laid
  out and the marker files are written.

**6. Concurrent clients beyond two fail after 1 s with `no server running` (Task 6; review focus 1).**
The M2 server keeps one spare instance (`Server.zig:236`). With four parallel `kill-pane` calls (Claude's leader exit),
clients 3 and 4 get `ERROR_PIPE_BUSY`. A single `WaitNamedPipeW ≤ 1000 ms` then gives up while the UI thread spends
1–2 s on two `removeSurface` thread joins. The shim reports `no server running on …`, and the teammate pane stays
open after the leader exits.
Fix, Task 6 `pipe.zig`: loop `CreateFileW` → `ERROR_PIPE_BUSY` → `WaitNamedPipeW(min(1000, remaining))` until the request
deadline. Return `NoServer` only for `ERROR_FILE_NOT_FOUND`, or for busy once the deadline has passed. Use the client.zig
margin: request `deadline_ms` = client timeout − 250 ms, so the server never acts on a request the client has given up
on (`client.zig:25`). Task 8: make `close_wait_ms` a server field too (tmux: 200). Task 12's e2e uses 6 parallel
`kill-pane` with every pane alive, and asserts all exit 0 and no pane is left.

**7. The pipe name is only the PID: predictable to squat, and reused after a restart (R-M4-1, Tasks 6, 8).**
`ghostty-tmux-<pid>` can be pre-created by any process that guesses the next PIDs. Ghostty then runs without `TMUX`
(DoS). Worse: processes that outlive their Ghostty keep `TMUX`/`TMUX_PANE` (`start cmd` windows survive tab close,
DECISIONS). If a later Ghostty gets the same PID, its pane ids also start at 1. A stale `tmux kill-pane -t %3` then
passes the `GetNamedPipeServerProcessId` check and kills a pane of the new Ghostty.
Fix: name `\\.\pipe\ghostty-tmux-<pid>-<nonce>`, where nonce = 64 random bits per process (hex), and `TMUX` =
`<that>,<pid>,0` (first field still comma-free). `run.zig` takes `expected_pid` from the digits between `ghostty-tmux-`
and the next `-`. Tests in Tasks 6 and 8 updated. SPEC §10/§12.1 change in Task 15.

**8. The `tmux-replay` e2e replays fixture ids that the real host never hands out (Tasks 1, 7, 12).**
On the real host, `%N = Surface.id` and a respawn uses up a fresh `Surface.id` (R-M4-2). The live sequence is therefore
`%1`, `%2`, (id 3 used by the respawn), `%4`, not the fixture's `%1, %2, %3`. `@W` is a `Tab.id`, which is not 1 once
the harness opens tabs. Fixture lines such as `select-pane -t %3 -T beta` would hit the wrong pane or fail with
`can't find pane`.
Fix, Task 12 `tmux-replay.ps1`: keep a map. Fixture `%1` maps to the scenario's `TMUX_PANE`, fixture `@1` to the
answered `#{window_id}`, and each fixture `split-window` answer to the live answer. Every later argv is rewritten
through the map before it is sent. Task 7 `FakeHost`: respawn consumes an id like the real host, and the replay test
uses the same mapping, so the two replays agree.

**9. Labels are refreshed only after tree changes, and miss tear-off (Tasks 8, 12, 13).**
Task 12 calls `labels.optionsChanged` "after every tmux-made tree change". `set-option -w pane-border-status off`,
`set-option -p pane-border-format …` and `select-pane -T` change no tree, so Task 13's own scenario step
"`pane-border-status off` → no labels" fails. Task 13 owns neither `Registry.zig` nor `commands.zig`. Task 8's hook list
also has no `tabReparented → labels`, which Task 13's "follows … tear-off" needs (`hooks.tabReparented` exists,
`hooks.zig:171`).
Fix: Task 12 calls `labels.optionsChanged(app, window_id)` after every `set-option`, every `select-pane -T` and every
tree change (and after a respawn re-applies the title). Task 8 adds `tabReparented → labels.tabReparented(tab, from,
to)` to the hooks and to the `labels.zig` stub.

**10. The Host contract cannot report "unsupported pane command", and `commands.zig` has no owner after Task 7 (Tasks 7, 10, 12).**
The `split` and `respawn` error sets are `{NoSpace, TooSmall, SpawnFailed, OutOfMemory}` / `{SpawnFailed,
OutOfMemory}`, but `spawn.plan` returns `error.Unsupported`, and the fixed text `ghostty: unsupported pane command`
belongs to commands.zig. The hot-file chain gives `commands.zig` to 3 → 7 only, so fixing this in W4/W5 needs an
unplanned 14.n. Two more seams are not settled:
- Task 12 says `replaceSurface` re-applies the `-T` title, but `replaceSurface` (Task 10, Tab.zig) cannot see the
  Registry options.
- Task 7 says main-vertical is "30 % until a resize-pane changes it" (state), while Task 12 always builds with 0.3.

Fix:
- Task 7: add `Unsupported` to both error sets, mapped to `ghostty: unsupported pane command` exit 1. Add a test row.
- Task 12: `Host.respawn` re-applies the title and options after `replaceSurface` returns. Task 10's signature stays.
- Task 7: main-vertical always uses 0.3 (tmux would use `main-pane-width`; Claude follows with `-x 30%` anyway). Delete
  "until a resize-pane changes it".

**11. Task 11's scenario needs the real host from Task 12, and Task 8's scenario types after a split (Tasks 8, 11).**
- `tmux-send-keys.ps1` drives `split-window`/`send-keys`/`capture-pane` through the pipe. Until Task 12, every tmux
  request gets the Task 8 stub `ghostty: tmux is not ready`, so the W4 batch fails by construction.
- Task 8's `tmux-env.ps1` reads the second surface's `TMUX_PANE` after a `new_split`. That means typing into a freshly
  resized Git Bash, which the first-byte rule forbids without a gate.

Fix:
- Run `tmux-send-keys` in the W5 batch: Task 11 writes and parses it, the lead runs it after Task 12.
- `tmux-env.ps1` reads the second pane's `TMUX_PANE` without typing. Either `state.tmux.panes` lists each surface's
  spawn env value (testState records `TMUX_PANE` per surface), or the split runs `printf … > file` as its command
  through the test IPC.

**12. First-byte loss also hits the leader pane, and only a manual check covers it (Global Constraints, R-M4-6, Task 15).**
Each teammate spawn resizes the leader pane: the split of `%L`, then main-vertical. The leader is Claude inside Git
Bash, which is exactly the M3 26.4 setup. R-M4-6 gates only scripted `send-keys`. The owner's own typing in the leader
during spawns is covered only by exit checklist 7, line 2. Also, R-M4-6 keys the gate on "its tab's last tmux-made
layout change", but `tabLayoutChanged` fires for every relayout, and pane_io cannot tell tmux-made ones apart.
Fix:
- Task 12 `tmux-replay.ps1`: after each layout change, type a marker line into the leader pane (Git Bash, `printf`
  to a file) with no re-send, and record losses as a measured row. A loss is a FAIL unless 26.4 has a ruling.
- M4 acceptance (Task 15) depends on the 26.4 verdict, stated in the exit checklist.
- R-M4-6 text: "the tab's last layout change (any cause)".

**13. Ruling (b) names Task 1 as the measurement. The plan uses Task 2, whose conhost run cannot observe real Claude in Ghostty (Tasks 1, 2, C2).**
Fix: keep Task 2 as the synthetic probe, with the oracle from item 1. Add Task 1 Step 3b: with the item 3 driver (a
Debug Ghostty), record from the log whether real Claude emits `ESC P tmux;` (`unknown DCS hook` with final `t`) and
whether its notification or title reaches core. Record this in the recon section. C2 reads both rows.

## MINOR

14. **R-M4-4 prefix resolution.** Unique prefixes resolved against Ghostty's 14 commands turn tmux-ambiguous input into
    actions: `kill` → kill-pane, `resize`/`respawn` → `-pane`, `show` (a tmux alias of `show-options`) →
    show-environment. Resolve aliases and prefixes against tmux 3.5a's full command-name list (a static table in
    `cli.zig`), then answer `unknown command: <name>` for names that resolve to commands Ghostty does not have. Test
    rows: `kill`, `show`.
15. **Task 6 shim stdout.** `WriteFile` UTF-8 to a console handle shows mojibake for non-ASCII when a user runs `tmux`
    in cmd or pwsh. Use `WriteConsoleW` when `GetConsoleMode` succeeds, and raw bytes otherwise (pipes, Claude).
16. **Task 6 import-table oracle.** Zig std may import `bcryptprimitives`/`advapi32` (`ProcessPrng`). Check against an
    allowlist recorded in the report, and fail only on `user32`, `gdi32`, `ole32`, `ucrt*` and `vcruntime*`.
17. **Task 6 verification.** `tmux-cli.ps1` (milestone M4) runs before Task 8 adds `M4` to the `ValidateSet`. Write
    `E2E -Only tmux-cli`, which works today.
18. **Task 6 RAM row.** `load-buffer` with 4 MiB stdin gives a JSON-escaped copy of up to 6× in `tmux.exe`, which is over
    the 5 MB peak. Exempt `load-buffer` from the 5 MB row, or cap stdin at 512 KiB (Claude falls back to OSC 52).
19. **Wire encoding.** `argv`/`env`/`cwd` from `GetEnvironmentStringsW` and the argv are WTF-8. One unpaired surrogate
    in any env value makes the server's JSON parse fail, so every command fails. Task 6: drop env entries that are not
    valid UTF-8 (log at debug), and send stdin only if it is valid UTF-8; otherwise exit 1 (Claude falls back).
20. **Trace writes (R-M4-9, Tasks 1 and 6).** Parallel `tmux.exe` processes append to one trace file. Open it with
    `FILE_APPEND_DATA` only and write each line with a single `WriteFile`, so lines do not interleave. Task 1's fixture
    keeps `stdin` (clipboard text) in the repo: replace stdin with `"<len> bytes"` unless the call is `load-buffer` from
    the fixed prompt.
21. **`env.apply` exe_dir.** Resolve `exe_dir` independently of the pipe claim (Task 8 sets it in `start`), so the PATH
    prepend survives a failed claim. Also state that `extra` may override `PATH`, which only happens on the parser path
    (SPEC §12.3 order).
22. **Config reload drops the tmux overrides of a shim pane** (`wait-after-command`, command, cwd): core re-derives
    surface config on reload. After a reload, a teammate that exits non-zero closes instead of staying
    (`remain-on-exit failed`). Task 10: keep the plan on the surface and re-apply it where the apprt re-applies
    `Overrides` on a config change. Test `"win32 tmux spawn: reload keeps wait-after-command"`, or record it as a
    known gap.
23. **Orphan placeholder pane.** If a split completes after the client gave up (UI stalled past the deadline margin),
    the new `__idle` pane is never respawned or killed. Registry: a `__idle` pane with no `respawn-pane` within 30 s
    whose `split-window` reply was not delivered is killed. Or record it as a known gap; it is rare.
24. **`__idle` and the user.** Ctrl+Z, Enter gives EOF and exit 0, so the pane closes and Claude's next `respawn-pane`
    fails with `can't find pane`. Have `__idle` wait on its own process handle instead of reading stdin to EOF
    (`WaitForSingleObject(GetCurrentProcess())` ends only when killed), and ignore Ctrl+C with
    `SetConsoleCtrlHandler(null, TRUE)`.
25. **Task 10 quoting test.** Add a path ending in a backslash right before `'"'"'` (`'C:\a\'"'"'b'`), a command
    string without spaces that contains `*` (MSYS globs unquoted argv words; force quotes around the `-c` argument or
    show it is quoted), and a `/c/x` argument (MSYS path conversion when bash runs a native exe). Record the observed
    argv.
26. **Crash cleanup** is untested. `tmux-replay.ps1`, last step: `Stop-Process` Ghostty while two fake teammates and an
    `__idle` run. Then `Assert-NoSurvivors` (the existing helper) shows no `tmux.exe`/`bash.exe`/`sleep.exe` from the
    run after the grace period, and a `tmux.exe` call then exits 1 `no server running` within 2 s.
27. **Modal reentrancy.** tmux requests run inside modal loops (close confirm, quit confirm, title edit, size/move).
    `Window.askClose`/`handleCloseSurface` already re-look-up after the dialog. Add the e2e step "close-confirm dialog
    up for the tab, then `kill-pane` of a pane in it through tmux" to `tmux-replay`, so that path is exercised.
28. **RAM gate noise.** "≤ M3 row + 0.5 MB" for one surface is below the run-to-run spread of Private Bytes. Use the
    median of 3 runs (the M2 rule), or + 1 MB.
29. **`measure-tmux.ps1` (Task 15).** 50 `split-window` runs in one tab hit `no space`. Kill each pane and wait until
    `state.tmux.panes` drops back before the next run, and start from a maximized window.
30. **`tmux-env.ps1` is missing from the hot-file chains** (8 → 12). Add it.
31. **Module boundary.** `cli.zig`, `format.zig` and `sh_command.zig` are compiled into both the main test exe (through
    `win32.zig`) and `tmux.exe`. They must never `@import("ipc_protocol")`, which only exists in the shim build. Only
    `run.zig`, `pipe.zig` and `main.zig` may. Write this in Task 3.
32. **Wording.** `list-panes` "leader first" cannot be guaranteed when the user already had splits. It is tree order,
    like tmux's pane index order, and Claude makes the same assumption with real tmux. Say "tree order" only.
33. **Over-built.** R-M4-7 history ranges (`-S -`, negative `-S/-E`, `-J`) and the R-M4-6 queue/timer have no consumer
    in the Claude flow (recon §9: no `send-keys`/`capture-pane`). Keep `send-keys` (immediate) and `capture-pane -p`
    of the visible screen for M4. Add the gate only if `tmux-send-keys` shows losses after 26.4, and the history
    ranges when a user asks. This cuts about a third of Task 11.
34. **Task 8 size.** It is the largest opus task: two servers, env, App/Surface/hooks/messages, three stub files, e2e
    plumbing, and now the config key. Move the `Registry`/`pane_io`/`labels` stub signatures into Task 3 (the shells
    already exist there and only need App/Surface/Tab types), so Task 8 keeps the logic.
35. **Task 1 output** must state whether fixture `argv` includes the global `-S <sock>` prefix (Claude sends it on
    every inside-mode call, not on the startup probes). Task 7's replay runs `cli.parseGlobal` and gives
    `execute(rest)`; say so.

## Cross-task consistency

One row per pair of tasks that share a file or an interface, then one row per task. "OK" = checked, no conflict.

| Pair / task | Shared file or interface | Finding |
|---|---|---|
| 1 ↔ 7 | `claude-spawn.jsonl` shape, ids `%1 @1 %2 %3` | Global-flag prefix unspecified (35). FakeHost id allocation vs real respawn (8). |
| 1 ↔ 12 | fixture → `tmux-replay.ps1` | Live ids differ, so a remap is needed (8). |
| 1 ↔ 15 | recon re-check section, fixture refresh, prompt text, `claude-team.ps1` | `--agent-teams` vs env spelling; auth/isolation and driver missing (3). |
| 2 ↔ 9 | C2 verdict | Oracle measures the wrong thing; Task 9's design is at the wrong layer (1). |
| 3 ↔ 4 | shells `format.zig`, `sh_command.zig` | OK. |
| 3 ↔ 5 | `cli.Size` | OK. |
| 3 ↔ 6 | `cli.parseGlobal`, `Diag` | OK (`-L` → run.zig). Module boundary (31). |
| 3 ↔ 7 | `parseCommands`, `Target`, `CommandId` | Prefix table (14). |
| 3 ↔ 8 | shells `tmux/Server.zig`, `env.zig`, `Registry.zig`, `pane_io.zig`, `labels.zig` | OK; stubs could move to 3 (34). |
| 3 ↔ 10, 11, 12, 13 | shells `spawn.zig`, `keys.zig`, `pane_io.zig`, `Registry.zig`, `labels.zig` | OK. |
| 4 ↔ 7 | `format.expand` ctx `lookup` | OK (`window_panes` computed by commands). |
| 4 ↔ 10 | `sh_command.Parsed` | OK. |
| 4 ↔ 13 | `format.expand` of `pane-border-format` | OK. |
| 5 ↔ 7 | `layout.*` generic over the tree, FakeHost | OK. |
| 5 ↔ 10 | `SplitTree.replace` refcounts and zoom | OK: `replace` refs the new view, and the old tree's `deinit` unrefs the old one. |
| 5 ↔ 12 | `ratioFor`, `ancestorSplit`, `fits` with `split_layout` rects | Null `split_layout` when minimized (5). |
| 6 ↔ 8 | `Request` fields `args cwd env stdin pane deadline_ms`, `tmuxPipeName`, `tmuxEnvValue`, `max_request_tmux` | Busy-pipe retry and deadline margin (6); pipe nonce (7); WTF-8 (19). |
| 6 ↔ 15 | `GHOSTTY_TMUX_STATS`, RAM/latency rows | `load-buffer` peak (18). |
| 7 ↔ 10 | `commands.Spawn` → `spawn.plan` | `Unsupported` not in the Host error sets (10). |
| 7 ↔ 11 | `CaptureRequest`, `sendKeys` (raw keys, `UnknownKey`) | OK. |
| 7 ↔ 12 | Host contract, `Options`, main-vertical share | Fixed 0.3 vs "until resize" (10). The `kill` of the last pane frees the `Tab`: the Registry must re-resolve by id after every `kill`, never reuse a `Window` handle. |
| 7 ↔ 13 | `Options` window/pane maps | Refresh trigger (9). |
| 8 ↔ 10 | `Surface.zig` (`pane_id`, `CreateOptions`, `defaultTermioEnv` → `tmux_env`), `env.apply` | Sequential (W3 → W4), OK. `exe_dir` independent of the claim (21). |
| 8 ↔ 11 | `pane_io` stubs, timer `tmux_keys`, `hooks.appMessage` WM_TIMER chaining (`recovery.timer(...) orelse pane_io.onTimer`) | OK if Task 8 chains; spell it out. |
| 8 ↔ 12 | `Registry` stubs, `tmux-env.ps1` | WM_GHOSTTY_IPC guard (4). Hot-file chain entry missing (30). |
| 8 ↔ 13 | `labels` stubs, hook list | `tabReparented` missing (9). |
| 10 ↔ 11 | `Surface.created_ms` (11 may not edit Surface.zig) | OK: 11 keeps it in its own `State`. |
| 10 ↔ 12 | `Tab.splitWith`, `replaceSurface`, `SplitOptions` | Title re-apply ownership (10). Minimized sizing (5). |
| 11 ↔ 12 | `pane_io.sendKeys/capture`, `keys.encode` | Task 11 scenario can only run after 12 (11). |
| 12 ↔ 13 | `labels.optionsChanged` call sites | (9). |
| 9 ↔ 15 | feature-checklist DCS row, known gaps | Depends on item 1's outcome. |
| 13 ↔ 15 | labels row, screenshot evidence | OK. |
| Task 1 | — | No driver, no auth, `CLAUDECODE` guard, outside the desktop lock (3); stdin redaction (20). |
| Task 2 | — | Oracle (1). |
| Task 3 | — | Prefix table (14); module boundary (31). |
| Task 4 | — | OK. |
| Task 5 | — | OK. |
| Task 6 | — | Busy retry (6); console output (15); import allowlist (16); run via `-Only` (17); peak with `load-buffer` (18); WTF-8 (19). |
| Task 7 | — | Error sets, main-vertical state (10); FakeHost ids (8). |
| Task 8 | — | WM_GHOSTTY_IPC guard and start order (4); config key (2); typing after a split (11); size (34). |
| Task 9 | — | Wrong layer (1). |
| Task 10 | — | Minimized sizing (5); reload (22); quoting cases (25). |
| Task 11 | — | Scenario timing (11); over-built (33). |
| Task 12 | — | Id remap (8); label refresh (9); `kill` frees the Tab (row 7 ↔ 12); minimized (5); crash and modal steps (26, 27); leader typing (12). |
| Task 13 | — | Can only work after the item 9 fix in Tasks 8 and 12. |
| Task 14 | — | OK. |
| Task 15 | — | Ruling (c), isolation and driver (3); RAM noise (28); measure loop (29); 26.4 dependency (12). |

Waves: file sets are disjoint per wave as claimed, with at most 3 writers (W1's Tasks 1 and 2 are lead/probe runs).
After the fixes, the edits are: Task 8 gains `Config.zig`, the `tmux-send-keys` run moves to the W5 batch, and the
stubs may move to Task 3.
