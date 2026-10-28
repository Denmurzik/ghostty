# M4 — Built-in tmux shim (Claude Code agent teams in Ghostty splits): Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Claude Code started in a Ghostty pane with `teammateMode: "tmux"` (or `auto`) opens its teammates as native Ghostty splits. `tmux.exe` (bundled next to `ghostty.exe`) forwards each tmux command over a per-process named pipe to Ghostty, which runs it on the UI thread against its tabs and split trees. `TMUX`/`TMUX_PANE` are set and the shim directory is first on `PATH` in every surface (opt-out: `windows-tmux-shim = false`). Exit gate: the real agent-team run of SPEC §15.6b passes twice in a row.

**Architecture:** `tmux.exe` is a thin console exe (std plus the std-only IPC `protocol.zig` module). It parses tmux's global flags, answers `-V` locally, and sends `{argv, cwd, env, stdin, pane}` as one `op: "tmux"` request to `\\.\pipe\ghostty-tmux-<pid>-<nonce>`. It then prints the reply verbatim and exits with its code. Ghostty serves that pipe with a second instance of the M2 `ipc/Server.zig` (posted to the UI thread with wparam tag 1). The UI thread parses the argv (`src/tmux_shim/cli.zig`) and runs it through `tmux/commands.zig`, which is written against a duck-typed `Host`. The real host (`tmux/Registry.zig`) maps panes to surfaces (`%N` = `Surface.pane_id`), windows to tabs (`@N` = `Tab.id`), layouts onto `SplitTree`, and pane commands onto new surfaces. A fake host lets the recorded Claude Code spawn sequence replay headless in a unit test.

**Tech Stack:** Zig 0.17.0, MSVC ABI, Win32 named pipes (overlapped server from M2, overlapped client in the shim), ConPTY through core termio, Git for Windows `bash.exe -c` for pane commands (R2), PowerShell e2e harness.

**Spec:** `docs/windows/SPEC.md` (with `docs/windows/DECISIONS.md` the authority):
- §2 (M4 files), §3 (`tmux.exe` build), §5 (the UI thread executes tmux commands; IPC thread), §7.2 (`defaultTermioEnv`)
- §8.5 (DCS `tmux;`, `SplitTree.replace`), §10 (PATH prepend, `TMUX`, `TMUX_PANE`), §12 (whole), §14 (the `tmux.exe` row)
- §15.2 / §15.6, §16 R11, §17 M4, §18.5 (wire format), §18.14 (the job object only lists processes)

Contract: `docs/windows/recon/tmux.md` (Claude Code 2.1.310; the installed build is 2.1.311, which Task 1 re-checks). DECISIONS "Built-in tmux", lead rulings R1 (client env overlay) and R2 (Git Bash `bash -c`, minimal parser fallback). Ledger rulings `.superpowers/sdd/M4-tmux-shim/progress.md`: (a) opt-out key, (b) DCS gap, (c) real Claude runs + option B. Pre-flight: `docs/windows/plans/M4-preflight-review.md` (dispositions at the end).

**Starts after M3 acceptance** (Task 27 landed). Task numbers are identities, not order: the wave table is the execution order. M3 Task 26.4 (Git Bash loses the first byte typed after a pty resize) is in flight. M4 acceptance needs its verdict (exit checklist 3), and the R-M4-6 constants follow it.

**Revision 2 (plan-m4, 2026-10-28):** applies the pre-flight review (3 CRITICAL, 10 IMPORTANT, 22 MINOR) and the ledger rulings (a)–(c) + option B. R-M4-11 (no knob) is replaced by the `windows-tmux-shim` key. Task 9 becomes a test-first verification of the parser's ESC fall-through. The pipe name gains a nonce. Stub signatures move from Task 8 to Task 3.

## Global Constraints

Carried from M1–M3 (every task implicitly includes these):

- Zig 0.17.0 at `C:\tools\zig-x86_64-windows-0.17.0\zig.exe` (full path). Shell: Git Bash. Target ABI MSVC. Minimum OS Windows 11 22H2.
- **UI thread owns** every HWND, tab, split tree and surface. The IPC thread only moves bytes. Cross-thread hand-off goes only through `PostMessageW` to the message window; never `SendMessage` from a non-UI thread. Every tmux command runs on the UI thread, inside the `WM_GHOSTTY_IPC` handler, and answers through `ipc.Server.complete`.
- Core edits are platform-neutral or Windows-gated, and only those listed in "M4 core touch points" are allowed. A cause found outside them is not fixed in the task: the implementer stops with evidence, and the lead schedules an `n.1` task.
- Use the Zig 0.17 std idioms of the touched file (`global.io()`, `std.Io`, `GetTickCount64` for deadlines). No `std.time.Timer`/`std.Thread.sleep`.
- Commits: no `Co-Authored-By` or similar trailers. Never `python -` (also not `python3 -` with a heredoc).
- Worktree bootstrap: `cmd //c mklink /J "<worktree>\zig-pkg" "C:\D\den4ik\Ghostty\zig-pkg"`. A worktree's first (cold) build runs with `run_in_background` under `timeout 1500` through the test-lock.

M4-specific:

- **Module boundary.**
  - `tmux.exe` imports only std, `src/tmux_shim/*` and the module `ipc_protocol` (= `src/apprt/win32/ipc/protocol.zig`, std only, §18.5). No `pkg/win32`, SharedDeps, libc or `src/os`. Its Win32 calls are its own `extern` declarations in `src/tmux_shim/win.zig`.
  - Only `src/tmux_shim/{main,run,pipe,win}.zig` may `@import("ipc_protocol")`. `cli.zig`, `format.zig` and `sh_command.zig` are std-only, because they are also compiled into the main test exe through `src/apprt/win32.zig`.
  - The import table is checked against an allowlist (Task 6). It fails on `user32`, `gdi32`, `ole32`, `ucrt*` and `vcruntime*`.
- **`tmux.exe` I/O.** It never creates a window. It reads stdin only for `load-buffer … -`; `__idle` does not read stdin. To a console handle it writes with `WriteConsoleW`; to a pipe or file it writes raw UTF-8 bytes.
- **Output bytes are tmux-exact.**
  - LF only, no BOM, no banner.
  - A trailing `\n` after `-P`/`-p`/`list-*` output, and none elsewhere.
  - Pane ids `%N` and window ids `@N` are decimal, with no padding and no whitespace.
- **Flag policy (R-M4-4).** Every command parses tmux 3.5a's full getopt template (table in Task 3).
  - A flag with no visible effect in Ghostty is accepted and ignored. It is logged at debug as `tmux: ignored flag -X of <cmd>`.
  - A flag whose semantics Ghostty does not implement fails with `<cmd>: -X is not supported by Ghostty`, exit 1.
  - A flag outside the template fails with `command <cmd>: unknown flag -X`, exit 1.
  - Nothing is silently half-done.
- **Error texts are fixed:** `can't find pane: <t>`, `can't find window: <t>`, `no space for new pane`, `create pane failed: pane too small`, `unknown command: <name>`, `ambiguous command: <name>, could be: <a>, <b>`, `pane <%N> still active`, `no server running on <path>`, `ghostty: unsupported pane command`, `ghostty: request too large`, `ghostty: server timed out`, `ghostty: invalid UTF-8 on stdin`, `protocol version mismatch`. Claude Code matches the substrings `no space` and `too small`, so those two never change.
- **Pipe security (SPEC §12.1, R-M4-1).**
  - Name: `\\.\pipe\ghostty-tmux-<pid>-<nonce>`, where nonce = 64 random bits per process in hex. The name is not guessable, and a stale `TMUX` from a dead Ghostty never meets a later Ghostty with the same pid.
  - Created with `FILE_FLAG_FIRST_PIPE_INSTANCE`, `PIPE_REJECT_REMOTE_CLIENTS`, DACL `D:P(A;;GA;;;<user SID>)` (plus `S:(ML;;NW;;;HI)` when elevated). These come exactly from `ipc.Server.claim`.
  - The server rejects a peer of another user, elevation or integrity (`instance.peerMatchesAs`).
  - The shim opens with `SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION`, and refuses a server whose `GetNamedPipeServerProcessId` differs from the pid in the name.
  - No TCP and no remote access. The tmux pipe answers only `op: "tmux"`, and the M2 per-user pipe never answers `tmux`.
- **Owner safety (M2/M3 rules, extended):**
  - e2e scenarios run only through `test/windows/e2e.ps1`, with the shared desktop lock and a per-scenario `class`.
  - Tests call `tmux.exe` by its full `zig-out\bin` path and never add it to the session `PATH`.
  - `Invoke-Tmux` (Task 8) removes `TMUX`, `TMUX_PANE` and `GHOSTTY_TMUX_TRACE` from the env it passes, and always passes `-S` with the pipe of the scenario's own Ghostty (`state.tmux.pipe`). The owner's running Ghostty is never addressed.
  - Fake teammates are bash one-liners inside the scenario sandbox. Trace files stay in the sandbox.
  - Evidence images come only from the guarded capture helpers (`Save-Evidence -Window`, `Save-WindowShot`, `Assert-CaptureRectClear`), never from a full-screen grab (M3 Task 15b ruling).
- **Real Claude Code run** (ledger ruling (c) + option B; Task 1 Step 3, G1, Task 15 Step 3). All three use the shared driver `test/windows/lib/ClaudeRun.psm1` (Task 1 creates it). That driver:
  - Starts the scenario Ghostty with `Start-E2eGhostty -Env` that passes the **real** `USERPROFILE` and `HOME` to that one instance only (Claude finds the owner's login). `XDG_CONFIG_HOME`, `APPDATA`, `LOCALAPPDATA` and the Ghostty class stay sandboxed.
  - Never copies, reads or writes credentials, `settings.json` or `CLAUDE_CONFIG_DIR`.
  - Removes from the child env `CLAUDECODE`, `CLAUDE_CODE_ENTRYPOINT`, `CLAUDE_CODE_SSE_PORT` and every other `CLAUDE_*` variable present in the driver's own env (they are listed in the run report). This avoids the nested-session guard.
  - Invokes, in one spelling everywhere:
    ```
    claude --agent-teams --teammate-mode tmux --model haiku --permission-mode default --settings '<json>'
    ```
    `<json>` is inline JSON allowing only the team and messaging tools, with `teammateMode: "tmux"` as a fallback if the flag is hidden. Task 1 Step 0 checks the spelling against `claude --help` and records any fallback (env `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`) in the module.
  - Runs in a fresh work dir `%TEMP%\ghostty-claude-<run>` with a unique team name `m4-<yyyyMMddHHmmss>`. The prompt is fixed (in the module) and asks the teammates to use the same model, to touch no files, and to stop after one message each.
  - Pre-trusts the work dir through a CLI option if `claude --help` lists one. Otherwise the driver answers the trust prompt once (Enter, verified by a dump) and fails on any other prompt it sees.
  - Types with the M3 26.1 re-send-and-verify pattern. Hard time box: 10 min per run, after which the driver kills the process tree (`Get-ProcessTree`).
  - Afterwards removes **only** the files this run created under `~/.claude/projects/<key of the work dir>` (files listed before and after, deleted by exact path). `~/.claude/teams/<team>/` and the work dir's entry in `~/.claude.json` stay and are reported as residue.
  - No per-run owner approval (ruling (c)). The run report records the model, the duration and the residue.
- **Pane-input robustness (M3 lesson, Task 26.4).** Git Bash loses the first byte typed after its pty resizes, and M4 splits resize panes. No test types into a pane right after a split, except through the R-M4-6 gate (`send-keys`) or the M3 26.1 re-send-and-verify pattern. The single exception is the measurement step of `tmux-replay.ps1` (Task 12), which types into the leader without a re-send on purpose and records losses.

Speed rules (owner, 2026-10-26; unchanged from M3):

- **Builds and tests use `-j6`**, strictly one at a time through the test-lock. Bash timeout 600000. Prefer a focused `-Dtest-filter`; never run the full suite locally.
- **Implementers run unit tests + `LOCK ZIG build -j6` only.** A task that owns a GUI scenario writes it (header, owner-safety rules) and makes it parse:
  ```
  powershell -NoProfile -Command "[ScriptBlock]::Create((Get-Content -Raw <file>)) | Out-Null"
  ```
  It does not run the scenario. The lead runs the scenarios of a wave as one batch and routes failures back as fix rounds. Implementer-run exceptions: Task 2 (ConPTY probe, as M3 Task 28), Task 6 (`tmux-cli.ps1` has no window, run with `E2E -Only tmux-cli`).
- **Up to 3 writers in flight** (one test-lock). A task starts as soon as its dependencies have landed and its files do not collide with in-flight tasks.
- **Every task: unit tests + at most one e2e scenario.**
- **Review tier** (stated per task): `light` = one batched sonnet review per batch; `opus` = per-task review for concurrency, lifetimes, security or process spawning.

Command abbreviations (expand literally; shell state does not persist):
- `LOCK` = `bash "%USERPROFILE%/.claude/mods/teamlead/skills/teamlead/scripts/test-lock" --`
- `ZIG` = `"C:/tools/zig-x86_64-windows-0.17.0/zig.exe"`
- `E2E` = `powershell -NoProfile -ExecutionPolicy Bypass -File test/windows/e2e.ps1` (lead only, after `LOCK ZIG build -j6`)
- Test name prefixes: `tmux shim ` (`src/tmux_shim/*`), `win32 tmux ` (`src/apprt/win32/tmux/*`), `SplitTree: ` (core), `stream: tmux passthrough` (core).

### M4 core touch points (complete list)

- `src/datastruct/split_tree.zig`: `SplitTree.replace` (platform-neutral, SPEC §8.5). Task 5.
- `src/config/Config.zig`: one Windows-only key, `windows-tmux-shim` with its doc comment, next to `windows-single-instance`. Task 8.
- `src/os/windows_shell.zig`: `findGitBash` becomes `pub` (a Windows-only file). Task 10.
- `build.zig` and `src/build/main.zig`: register `GhosttyTmuxShim` (Windows target and the `win32` runtime only). Task 6.
- `src/terminal/stream.zig` test block only (Task 9): a new test, no behaviour change. If that test shows the passthrough does not reach the handler, Task 9 stops. A `Parser.zig`/`parse_table.zig` change would need a lead ruling and a new touch point.
- **Not touch points:**
  - `src/termio/Exec.zig`: Exec skips its own PATH append when `PATH` already holds the exe dir (`Exec.zig:744-750`), so the apprt's `defaultTermioEnv` does the prepend alone.
  - `src/terminal/dcs.zig`, `src/termio/stream_handler.zig`: no unwrap code (pre-flight 1).

### RAM budget (owner: low RAM)

Private Bytes, ReleaseFast, hardware adapter, measured with `test/windows/measure-ram.ps1` (`-Tag`/`-Actions`/`-Sample` from M3 Task 3). Each gated row is the median of 3 runs (the M2 rule). The baseline is the M3 acceptance rows, re-measured the same day.

| Item | Budget | Measured by |
|---|---|---|
| default config, 1 window 1 surface (tmux pipe + IPC thread idle) | ≤ M3 row + 1 MB | Task 15 |
| agent-team layout: leader + 2 respawned panes, 30 s after the last respawn | ≤ `one-surface` + 2 × the M2 per-split cost + 1 MB | Task 15 (`-Sample before@… team@…`, driven by `tmux.exe` with fake teammates) |
| after `kill-pane` of both teammates, 30 s idle | within +10 % of the pre-team value (M2 close-10 rule) | Task 15 |
| `tmux.exe` per invocation, every command except `load-buffer` | ≤ 5 MB peak private, ≤ 100 ms wall p95 over 50 runs (SPEC §14); target for `-V` < 50 ms | Task 6 (`GHOSTTY_TMUX_STATS=1`), Task 15 |
| `tmux.exe load-buffer` with the 512 KiB stdin cap | ≤ 8 MB peak private (recorded) | Task 15 |
| `tmux.exe __idle` placeholder resident | ≤ 2 MB private | Task 15 |

### Latency budget

- **Key echo must not regress.** Ghostty-owned p95 stays within +0.5 ms of the M3 acceptance value (same-day re-measure, ≥ 200 samples × 3 runs, default config). M4 adds no code to the `WM_KEYDOWN` → pty write path; the only per-surface addition is `defaultTermioEnv` at spawn.
- **tmux round trip** (ReleaseFast, wall time of `tmux.exe` from process start to exit, 50 runs each). Debug values are recorded, not gated.
  - `display-message -p '#{pane_id}'` ≤ 30 ms p95.
  - `split-window -d -P -F '#{pane_id}' -- cat` ≤ 300 ms p95.
  - `respawn-pane -k` ≤ 300 ms p95.
- **Startup probes.** The probes of recon §9 have a 250 ms timeout (`show-environment -g`). The tmux server never blocks its queue longer than its 500 ms read timeout on a silent client (R-M4-1), and no command defers its reply.

## Review Focus

1. **Leader exit with parallel `kill-pane`** (recon §12.12): six concurrent clients against a server with one spare pipe instance. Some panes may already be gone, and the caller's own pane or tab may close mid-reply.
   - Expected: every client gets through (`ERROR_PIPE_BUSY` → `WaitNamedPipeW` retried with backoff until the request deadline), and requests are answered in arrival order.
   - A missing pane gives exit 1 `can't find pane`. A reply whose client vanished is dropped. Ghostty never crashes or leaves an empty tab, and the Registry never reuses a `Tab` handle after a kill.
   - Tests: Task 6 `pipe busy retries until the deadline`; Task 7 `kill-pane twice and kill of a pane in a closed tab`; Task 12 e2e (6 parallel `kill-pane`, all alive → all exit 0, nothing left).
2. **Respawn identity.** After `respawn-pane -k`, the pane keeps its id, leaf position, geometry, focus, `remain-on-exit` and `select-pane -T` title. The `tmux.exe __idle` placeholder process is gone, a second respawn works, and `TMUX_PANE` in the new process equals the old id. The same holds while the window is minimized.
   - Tests: Task 5 `replace keeps shape, ratios and zoom`; Task 7 `respawn keeps id and options`; Task 12 e2e (marker file holds `%N`; the minimized step).
3. **Pane command quoting through MSYS.** Claude's one-line POSIX string goes into `bash.exe -c <string>` through the MS-CRT command line Ghostty builds. Cygwin's argv parser also treats single quotes and globs specially, and does path conversion. The string carries paths with spaces, a trailing backslash before `'"'"'`, `*`, `/c/x`, and non-ASCII. The program must receive exactly the intended argv.
   - Test: Task 10 `bash -c receives Claude's command line verbatim` (real Git Bash; skipped without it).
4. **Environment precedence.**
   - The leader's `TMUX_PANE`, `TMUX`, `GHOSTTY_SURFACE_ID` and `=C:` entries in the client env never reach a teammate.
   - Keys merge case-insensitively (`Path`/`PATH`), and the shim dir stays first in `PATH`.
   - `windows-tmux-shim = false` restores pre-M4 behaviour exactly.
   - A user MSYS2 `tmux` in Git's `/usr/bin` would shadow ours in a login shell.
   - Tests: Task 8 env tests; `tmux-env.ps1` asserts `command -v tmux`. If a shadowing tmux is found, the scenario fails with its path, and the lead files a fix through the bash integration's MSYS branch.
5. **UI-thread stalls and stuck clients.** The server serves one client at a time. A connected-but-silent client, a large `load-buffer`, or a slow surface creation must not starve the 250 ms startup probes. A request whose deadline passed while queued must not act. The client's deadline sits 250 ms before its own timeout.
   - Tests: Task 8 `silent tmux client releases the queue within 600 ms`; Task 6 `request deadline has the client margin`; Task 7 `expired request does nothing`.

## Rulings (plan-m4, 2026-10-28; lead/owner may overturn — recorded in SPEC §18 by Task 15)

- **R-M4-1 One server implementation, two pipes** (amends SPEC §2's `tmux/Server.zig` scope, §10 and §12.1's pipe name and limits).
  - The tmux pipe is a second `ipc.Server` (M2) instance with new fields:

    | Field | Meaning | tmux value |
    |---|---|---|
    | `post_tag` | `WM_GHOSTTY_IPC` wparam: 0 = per-user pipe, 1 = tmux | 1 |
    | `max_request` | largest accepted request; the frame limit stays 16 MiB | `protocol.max_request_tmux` = 4 MiB |
    | `io_timeout_ms` | read timeout | 500 |
    | `close_wait_ms` | close wait | 200 |

  - `tmux/Server.zig` only claims, starts, stops and routes. `App.msgWndProc` routes on wparam *before* the `server == null` guard.
  - Every non-forwarding Ghostty process claims its own tmux pipe, including a standalone process whose M2 claim hit `AddressInUse`. The claim runs after `if (self.forwarded) return;` and before `Window.create`.
  - If the claim fails, `TMUX` is not set in that process and one warning is logged.
  - Name `ghostty-tmux-<pid>-<nonce>`; `TMUX` = `<pipe>,<pid>,0` (the first field stays comma-free).
  - Cost if wrong: a dedicated server thread, local to `tmux/Server.zig`.
- **R-M4-2 Ids without a separate registry table** (amends §12.2 "registry").
  - `Surface.pane_id: u32` = `Surface.id` at creation, so every surface has a valid `%N` (process-wide monotonic, never reused).
  - A respawn creates the new surface with `pane_id` = the old one. Its own fresh `id` is used up and never becomes a pane id; live pane ids may therefore skip numbers.
  - Window `@N` = `Tab.id`, which survives tear-off. Session = the process (`session_name` = `0`, `session_id` = `$0`).
  - Lookups scan `app.windows` → tabs → tree (tens of panes at most), re-resolved by id after every mutation.
  - `Registry.State` holds only per-pane/window options, exit state, buffers and the send-keys queue, keyed by id.
  - Cost if wrong: a hash map id → `*Surface`.
- **R-M4-3 Headless semantics.** `tmux/commands.zig` runs against a duck-typed `Host` (Task 7). The SPEC §12.5 replay test drives the Claude sequence recorded in Task 1 through `FakeHost`, which is built on `SplitTree(FakePane)` and the same `layout.zig`. `FakeHost` allocates ids like the real host: a respawn uses one up. Cost if wrong: none for users.
- **R-M4-4 Flag and command policy** as in Global Constraints.
  - Supported commands (inside mode, SPEC §12.2 + recon §4/§9, plus `send-keys`/`capture-pane`): `split-window respawn-pane kill-pane select-layout resize-pane select-pane set-option display-message list-panes list-windows show-environment load-buffer send-keys capture-pane`.
  - Names, aliases and unique prefixes resolve against tmux 3.5a's **full** command table (static in `cli.zig`). A name that resolves to a tmux command Ghostty does not have answers `unknown command: <name>`; `kill` and `show` are ambiguous as in tmux.
  - Command sequences separated by an argv element `;` run in order and stop at the first error.
  - `new-session`, `attach`, `has-session` and `kill-server` belong to external mode (M5).
  - Cost if wrong: one table row per added command.
- **R-M4-5 Pane spawn** (SPEC §12.3, R1, R2), decided by `tmux/spawn.zig` (Task 10):
  - The command string exactly `cat` → argv `{<exe dir>\tmux.exe, "__idle"}`.
  - An empty command → Ghostty's configured command, as for a normal split.
  - Otherwise, if Git Bash resolves (`CLAUDE_CODE_GIT_BASH_PATH` from the client env if that file exists, else `windows_shell.findGitBash(client env)`) → `{bash, "-c", string}`.
  - Otherwise `sh_command.parse` → direct argv, the cwd from `cd`, and the `env` assignments as extra env (which may override `PATH`).
  - cwd = the `-c` start-dir, else the `cd` target (parser path only), else the client cwd.
  - Every shim-created pane gets `wait-after-command = true`, so that `remain-on-exit` decides in `show_child_exited`.
  - Known gap: a config reload re-derives surface config, so a shim pane loses its `wait-after-command` like every other per-surface override in the win32 apprt today. After a reload, a teammate that exits non-zero closes instead of staying.
  - Cost if wrong: R2's.
- **R-M4-6 send-keys gate.** `send-keys` answers exit 0 at once (tmux also only queues). The bytes go into a per-pane queue, flushed by the msg-window timer `tmux_keys` (25 ms) once both hold:
  - the pane is at least `gate_age_ms` = 300 old;
  - its tab's last layout change, **from any cause** (every `tabLayoutChanged`), is at least `gate_settle_ms` = 150 old.

  Order across and within panes is kept, and a pane that closes drops its queue. This answers the lead's requirement that `send-keys` right after `split-window` is robust (Git Bash first-byte loss). If Task 26.4 lands a Ghostty-side fix, the lead may set both constants to 0. Cost if wrong: up to 300 ms of extra latency for scripted `send-keys` only.
- **R-M4-7 `capture-pane` subset (M4):** visible screen only.
  - `-p` prints; without it, the text goes to the buffer.
  - `-t` targets a pane.
  - `-q`, `-N`, `-T` and `-J` are accepted and ignored (rows are dumped as displayed).
  - `-S`, `-E`, `-e`, `-C`, `-P`, `-a`, `-b` and `-M` → not supported (no consumer in the Claude flow; history ranges come when a user asks).
  - The text comes from core's `Screen.dumpString` over the viewport, under `renderer_state.mutex`.
- **R-M4-8 Pane title and styles.**
  - `select-pane -T` pins the surface's user title (`Surface.setUserTitle`, the same as a user rename). `Host.respawn` re-applies it after `replaceSurface`.
  - `set-option -p/-w/-g` values are stored verbatim per pane, window and global.
  - Only two option groups have effects: `remain-on-exit` (pane → window → global; `on|off|failed`, default `off`) and the `pane-border-*` options (the Task 13 label).
  - After every `set-option`, every `select-pane -T` and every tree change, the Registry calls `labels.optionsChanged`.
- **R-M4-9 Trace and stats.**
  - `GHOSTTY_TMUX_TRACE=<file>` makes `tmux.exe` append one JSON line per invocation: `{t, argv, cwd, pane, code, ms, stdout_len, stdin_len}`. The file is opened with `FILE_APPEND_DATA` only, and each line goes out in a single `WriteFile`, so parallel lines do not interleave. Stdin content is never traced.
  - The trace is diagnostic only. It is the SPEC R11 drift recorder: Task 15 compares a live trace with the Task 1 fixture.
  - `GHOSTTY_TMUX_STATS=1` prints `tmux-stats peak_private_kb=<n> wall_ms=<n>` to stderr at exit (`K32GetProcessMemoryInfo` `PeakPagefileUsage`).
- **R-M4-10 DCS `tmux;` passthrough** (ledger ruling (b)).
  - **Parser.** Ghostty's parser leaves `dcs_passthrough` on every ESC. The inner sequence of `ESC P tmux; ESC ESC ] … ESC \` is therefore expected to be dispatched as a normal OSC already (pre-flight 1). Task 9 proves this with a core `Stream` test and adds no unwrap code.
  - **ConPTY.** Whether the wrapped sequence survives the inbox ConPTY is measured synthetically by Task 2 and with real Claude by Task 1 Step 3b. If it is dropped, "Claude notifications/titles lost while `TMUX` is set" is a documented M4 gap.
  - SPEC §12.4 is reworded by Task 15 to match.
- **R-M4-11 Opt-out key** (ledger ruling (a)): `windows-tmux-shim = true|false`, default `true`, Windows only (like `windows-single-instance`).
  - With `false`, `env.apply` sets neither `TMUX` nor `TMUX_PANE`, leaves any inherited `TMUX`/`TMUX_PANE` untouched (pre-M4 behaviour), and does not prepend. Exec's own exe-dir append stays, so `tmux.exe` remains reachable last on PATH.
  - The key is read per surface at spawn, so a reload affects new surfaces. The tmux pipe is still claimed, so turning the key on by reload works without a restart.

## Waves (parallelism)

≤ 3 tasks per wave. File sets inside a wave are strictly disjoint (checked against every `Files:` list and the hot-file chains below).

| Wave | Tasks | Depends on |
|---|---|---|
| W1 | 1 contract re-check, Claude-run driver, live capture · 2 DCS-through-ConPTY probe · 3 argv parser, file shells, stub signatures | — |
| C1 | **Lead decision point:** Task 1's diff against recon. No differences → continue. Differences → the lead amends the Task 3/4/7 tables (one-line plan commit) before W3 | 1 |
| W2 | 4 format expansion + `sh_command` · 5 `SplitTree.replace` + layouts · 6 wire fields + `tmux.exe` | 3 (4, 6) |
| C2 | **Lead decision point:** Task 2's row and Task 1 Step 3b. DCS content arrives → `dcs-tmux` e2e in Task 9. Dropped → gap recorded, Task 9 is unit tests only | 1, 2 |
| W3 | 7 command semantics + replay · 8 tmux pipe, routing, pane ids, env, opt-out key · 9 DCS passthrough verification (core test) | C1+3+4+5 (7); 3+6 (8); C2 (9) |
| W4 | 10 pane spawn (`spawn.zig`, Surface, Tab) · 11 send-keys + capture-pane | 4+5+7+8 (10); 3+7+8 (11) |
| W5 | 12 real host (`Registry.zig`), remain-on-exit, load-buffer, `tmux-replay` e2e. The W5 batch also runs Task 11's `tmux-send-keys` | 7+10+11 |
| G1 | **Lead checkpoint:** `E2E -Milestone M4` (Debug); one real Claude Code agent-team run (driver, option B) in a Debug Ghostty with `GHOSTTY_TMUX_TRACE`, trace diffed with Task 1's fixture. Failures → 14.n | 12 |
| W6 | 13 pane border labels · 14.n integration fixes (≤ 2 alongside 13, disjoint) | 12 (13); G1 (14.n) |
| W7 | 15 RAM/latency rows, Claude Code run ×2, SPEC/recon/checklist, acceptance (alone) | 13, 14.*, M3 26.4 verdict |

Hot-file chains (every file touched by more than one task; any file not listed has a single owner):
- **apprt:**
  - `src/apprt/win32.zig` (test imports of every M4 file): 3 only.
  - `tmux/Registry.zig` 3 → 12; `tmux/pane_io.zig` 3 → 11; `tmux/labels.zig` 3 → 13. Task 3 writes the stubs with their final signatures; Task 8 only calls them.
  - `tmux/keys.zig` 3 → 11; `tmux/commands.zig`, `tmux/FakeHost.zig` 3 → 7; `tmux/layout.zig` 3 → 5; `tmux/spawn.zig` 3 → 10; `tmux/env.zig`, `tmux/Server.zig` 3 → 8.
  - `src/tmux_shim/format.zig`, `sh_command.zig` 3 → 4.
  - `Surface.zig` 8 → 10; `Tab.zig` 10 only; `App.zig`, `hooks.zig`, `messages.zig`, `ipc/Server.zig` 8 only; `ipc/protocol.zig` 6 only; `actions/surface_actions.zig` 12 only.
- **core:** `src/config/Config.zig` 8 only; `src/datastruct/split_tree.zig` 5 only; `src/terminal/stream.zig` (test) 9 only; `src/os/windows_shell.zig` 10 only.
- **tests/docs:**
  - `test/windows/e2e.ps1` (`ValidateSet` += `M4`) and `test/windows/e2e/_tmux.ps1` (helpers): 8 only. Later tasks put extra helpers in their own scenario file.
  - `test/windows/e2e/tmux-env.ps1` 8 → 12.
  - `test/windows/lib/ClaudeRun.psm1` 1 → (G1 lead fixes) → 15.
  - `docs/windows/recon/tmux.md` 1 → 15. `src/apprt/win32/tmux/testdata/claude-spawn.jsonl` 1 → (G1 lead refresh) → 15.
  - `test/windows/README.md` and `docs/windows/{SPEC.md, feature-checklist.md, CHANGELOG.md, ram-baseline.csv, latency-baseline.csv}`: 15 (+ lead rulings).

Message and timer ids (`messages.zig`, Task 8): no new message. The tmux pipe reuses `WM_GHOSTTY_IPC` with wparam `1`. Timer `messages.timers.msg_window.tmux_keys = 4` (R-M4-6). `hooks.appMessage` chains it after `recovery` (`recovery … orelse pane_io.onTimer`).

---

### Task 1: Claude Code tmux contract — re-check, Claude-run driver, live capture

**Review:** lead (docs, driver, fixture).

**Files:** Create `test/windows/lib/ClaudeRun.psm1` (the shared real-run driver of Global Constraints), `test/windows/tmux-capture/fake_tmux.zig` (std only, throwaway answerer), `test/windows/tmux-capture/run.ps1`, `src/apprt/win32/tmux/testdata/claude-spawn.jsonl`; Modify `docs/windows/recon/tmux.md` (new section "Re-check <date>, Claude Code <version>").

**Interfaces:**
- Produces:
  - `ClaudeRun.psm1`:
    - `Start-ClaudeRun -Ghostty <exe> -ExtraEnv <hashtable> -TimeBoxMin 10 -Prompt <text> -TeamName <name>` returns `{G, WorkDir, Team, ProjectsBefore}`.
    - `Wait-ClaudeRun`, `Stop-ClaudeRun` (kills the process tree, removes the run's new files under `~/.claude/projects/<key>` and nothing else, returns the residue list).
    - `$ClaudeRunPrompt` (the fixed prompt).
  - `claude-spawn.jsonl`: one JSON object per line, `{"argv":[…],"stdin":null|"<n> bytes"}`, in call order. It covers the startup probes (recon §9) and the spawn of 2 teammates in inside mode (the order in recon §4 notes), up to and including leader-exit cleanup.
    - `argv` is the full argv after `tmux` including the global `-S <sock>` prefix, which Claude sends on inside-mode calls but not on the startup probes. Task 7's replay runs `cli.parseGlobal` and passes `rest` to `execute`.
    - Ids are the ones the fake answered: leader `%1`, window `@1`, new panes `%2`, `%3`.
    - Stdin content is replaced by `"<n> bytes"` (it may hold clipboard text).

- [ ] **Step 0: CLI check.** Run `claude --version` and `claude --help`. Record the spelling of `--agent-teams`, `--teammate-mode`, `--model`, `--permission-mode` and `--settings`, and any trust option. Fallbacks for hidden flags: `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`, and `teammateMode` inside the `--settings` JSON. Write the result into `ClaudeRun.psm1`.
- [ ] **Step 1: Static re-check.** Run the extraction recipe from the recon header against `%USERPROFILE%\.local\bin\claude.exe`. Diff against recon §2–§9:
  - backend detection and the `TMUX` snapshot;
  - command table rows 1–15 (argv shapes, `-t` before `-p`, `-l 70%`, the `-v`/`-h` alternation);
  - ENVS/IDENT and the initial command `cat`;
  - the stderr substrings `no space`/`too small`;
  - format strings and startup probes;
  - the nested-session guard on `CLAUDECODE`.

  Record every difference (or "none").
- [ ] **Step 2: Fake answerer.** `run.ps1` builds `fake_tmux.zig` into the run's sandbox as `tmux.exe` (`ZIG build-exe -O ReleaseSmall`; not part of `zig build`). For every call it appends `{argv, stdin_len}` to `$env:GHOSTTY_TMUX_TRACE` (`FILE_APPEND_DATA`, one `WriteFile` per line). Answers:
  - `-V` → `tmux 3.5a\n`.
  - `display-message`:
    - with `#{pane_id}` → `%1`;
    - with `#{window_id}` → `@1`;
    - the 8-field probe → `xterm-ghostty\toff\t0\t0\t0\ton\tbottom\t0`;
    - `#{session_name}:#{window_id}.#{pane_id}` → `0:@1.%1`.
  - `list-panes` → `%1` plus the panes created so far.
  - `split-window … -P` → `%2`, then `%3`.
  - `show-environment` → empty.
  - Everything else → exit 0, no output.
- [ ] **Step 3: Live capture** (desktop lock, run by the lead, no per-run approval: ruling (c)). `run.ps1`:
  - uses `Start-ClaudeRun` with an M3 Debug Ghostty (Git Bash);
  - passes `-ExtraEnv @{ PATH = "<sandbox>;$env:PATH"; TMUX = '\\.\pipe\ghostty-tmux-capture-0,1,0'; TMUX_PANE = '%1'; GHOSTTY_TMUX_TRACE = '<sandbox>\trace.jsonl' }` (a pre-M4 Ghostty sets none of these itself);
  - after both spawns appear in the trace, types `/exit` (re-send-and-verify), so the cleanup `kill-pane` calls are captured too;
  - ends with `Stop-ClaudeRun`.
- [ ] **Step 3b: DCS by real Claude** (input to C2). From the same run's Debug log, record:
  - whether Claude emitted `ESC P tmux;` (an `unknown DCS hook` line with final `t`);
  - whether its notification or title OSC reached core (`desktop_notification` / title log lines).
- [ ] **Step 4:** Write `claude-spawn.jsonl` from the trace. Keep argv and stdin length only; keep Claude's dynamic values (uuid, `--parent-session-id`, team name) inside the `respawn-pane` string, which Task 7 matches by prefix up to `--agent-id`. Add the recon section: version, date, CLI spellings, static diff, live trace summary, DCS observation (3b), and differences → plan impact.
- [ ] **Step 5: Commit** `git commit -m "docs(windows): re-check the Claude Code tmux contract on <version>; Claude-run driver; live spawn trace fixture"`.

### Task 2: DCS `tmux;` passthrough through ConPTY — synthetic probe (input to C2)

**Review:** lead (as M3 Task 28).

**Files:** Create `test/windows/conpty-probe/cases/probe-dcs-tmux.sh`; Modify `test/windows/conpty-probe/RESULT.md` (new rows + log excerpt) and `test/windows/conpty-probe/run.ps1` (`-Only`, and the notification oracle if missing).

- [ ] **Step 1:** The case prints three sequences. A wrapped OSC 9 with BEL terminator:
  ```
  printf '\033Ptmux;\033\033]9;m4-dcs-bel\a\033\\'
  ```
  A wrapped OSC 777 with ST terminator:
  ```
  printf '\033Ptmux;\033\033]777;notify;m4;dcs-st\033\033\\\033\\'
  ```
  And as a control, a plain:
  ```
  printf '\033]9;m4-plain\a'
  ```
- [ ] **Step 2: Run** `powershell -File test/windows/conpty-probe/run.ps1 -Flags 0,8 -Repeat 2 -Only dcs-tmux` (Debug). Oracle per wrapped sequence: **arrived** = its text reaches core as a desktop notification (`state.m3.notify` or the `desktop_notification` log line) next to the plain control. Separately record whether the `unknown DCS hook:` line with final `t` appears.
- [ ] **Step 3:** Add the rows (flags 0 / 8, ×2, both oracles) and the log excerpt to `RESULT.md`.
- [ ] **Step 4: Commit** `git commit -m "test(windows): ConPTY probe for DCS tmux passthrough"`.

### Task 3: tmux argv parser (`cli.zig`), M4 file shells, stub signatures

**Review:** light.

**Files:**
- Create `src/tmux_shim/cli.zig` (real).
- Create shells, each with a one-line `//!` naming its owner task: `src/tmux_shim/{format,sh_command}.zig` (→ 4), `src/apprt/win32/tmux/{commands,FakeHost}.zig` (→ 7), `layout.zig` (→ 5), `Server.zig` and `env.zig` (→ 8), `spawn.zig` (→ 10), `keys.zig` (→ 11).
- Create stubs with their final signatures (bodies: no-op or `false`/stub reply): `tmux/Registry.zig` (→ 12), `tmux/pane_io.zig` (→ 11), `tmux/labels.zig` (→ 13).
- Modify `src/apprt/win32.zig`: test imports of all of the above, Windows-gated like the M3 imports.

**Interfaces:**
- Produces (`cli.zig`, std only, never imports `ipc_protocol`):
  ```zig
  pub const Global = struct { socket_path: ?[]const u8 = null, socket_name: ?[]const u8 = null, version: bool = false, rest: []const []const u8 };
  pub fn parseGlobal(argv: []const []const u8, diag: *Diag) error{Usage}!Global; // argv without argv[0]; template "2c:CDdf:hlL:NqS:T:uUvV"; -c/-C/-D/-T → Usage "<flag> is not supported by Ghostty"; -2 -d -f -h -l -N -q -u -U -v ignored
  pub const CommandId = enum { split_window, respawn_pane, kill_pane, select_layout, resize_pane, select_pane, set_option, display_message, list_panes, list_windows, show_environment, load_buffer, send_keys, capture_pane };
  pub const Command = struct {
      id: CommandId,
      flags: std.StaticBitSet(128),            // indexed by the flag byte
      values: [128]?[]const u8,                // value of a flag that takes one (last wins, like tmux)
      positional: []const []const u8,
      pub fn has(self: *const Command, f: u8) bool;
      pub fn value(self: *const Command, f: u8) ?[]const u8;
  };
  pub fn parseCommands(arena: Allocator, argv: []const []const u8, diag: *Diag) error{ Usage, OutOfMemory }![]Command; // split at argv elements ";"
  pub const Diag = struct { buf: [256]u8 = undefined, len: usize = 0, pub fn message(self: *const Diag) []const u8 };
  pub const Target = union(enum) { none, pane: u32, window: u32, invalid: []const u8 };
  pub fn parseTarget(s: ?[]const u8) Target;            // "%N", "@N", "@N.%M" → pane M, "" / null → none; anything else → invalid
  pub const Size = union(enum) { cells: u32, percent: u8 };
  pub fn parseSize(s: []const u8) ?Size;                 // "70%" → percent 70 (1…100), "30" → cells 30, else null
  pub fn commandName(id: CommandId) []const u8;          // "split-window", …
  ```
  - **Name resolution** uses a static table of tmux 3.5a's full command names and aliases. The exact name or alias wins. Otherwise, a unique prefix among all tmux names resolves. If the resolved tmux command is not one of the 14 → `unknown command: <name>`. Ambiguous → `ambiguous command: <name>, could be: <list>`.
  - **Templates** (tmux 3.5a `cmd-*.c` `.args`; the implementer copies them from the tmux 3.5a source when it is available and records any difference):

    | Command | Template |
    |---|---|
    | `split-window` | `"bc:de:fF:hIl:p:Pt:vZ"` |
    | `respawn-pane` | `"c:e:kt:"` |
    | `kill-pane` | `"at:"` |
    | `select-layout` | `"Enopt:"` |
    | `resize-pane` | `"DLMRTt:Ux:y:Z"` |
    | `select-pane` | `"DdegLlMmP:RT:t:UZ"` |
    | `set-option` | `"aFgopqst:uUw"` |
    | `display-message` | `"aCc:d:lINpt:F:v"` |
    | `list-panes` | `"aF:f:O:rst:"` |
    | `list-windows` | `"aF:f:O:rt:"` |
    | `show-environment` | `"hgst:"` |
    | `load-buffer` | `"b:t:w"` |
    | `send-keys` | `"c:FHKlMN:Rt:X"` |
    | `capture-pane` | `"ab:CeE:JNpPqS:Tt:"` |

  - **Stub signatures** (final; owners fill the bodies, nobody renames):
    ```zig
    // Registry.zig (→ 12)
    pub const State = struct {};                              // App.tmux; 12 adds fields with defaults
    pub const Reply = struct { code: ipc.protocol.Code, stdout: []const u8, stderr: []const u8 };
    pub fn run(app: *App, req: ipc.protocol.Request, arena: Allocator) Reply;            // stub: .failed, "ghostty: tmux is not ready"
    pub fn surfaceDestroying(surface: *Surface) void;
    pub fn childExited(surface: *Surface, info: apprt.surface.Message.ChildExited) bool; // stub: false
    pub fn appStopping(app: *App) void;
    // pane_io.zig (→ 11)
    pub const State = struct {};                              // App.tmux_keys
    pub fn layoutChanged(tab: *Tab) void;  pub fn onTimer(app: *App) void;  pub fn surfaceDestroying(surface: *Surface) void;
    // labels.zig (→ 13)
    pub const State = struct {};                              // App.tmux_labels
    pub fn optionsChanged(app: *App, window_id: u32) void;  pub fn tabLayoutChanged(tab: *Tab) void;  pub fn tabShown(tab: *Tab, shown: bool) void;
    pub fn tabReparented(tab: *Tab, from: *Window, to: *Window) void;  pub fn windowChanged(window: *Window, change: hooks.WindowChange) void;
    pub fn surfaceDestroying(surface: *Surface) void;
    ```

- [ ] **Step 1: Failing tests** in `cli.zig`:
  ```zig
  test "tmux shim cli: global -S then command" { // {"-S", "\\\\.\\pipe\\ghostty-tmux-7-ab", "display-message", "-p", "#{pane_id}"} → socket_path set, rest.len == 3 }
  test "tmux shim cli: -V wins" {}                 // {"-V"} → version; {"-L","x","-V"} → version
  test "tmux shim cli: Claude spawn argv" {}       // split-window -d -t %1 -h -l 70% -P -F "#{pane_id}" -- cat → flags d,h,P; t="%1"; l="70%"; F="#{pane_id}"; positional {"cat"}
  test "tmux shim cli: -t before -p" {}            // display-message -t %3 -p "#{window_id}"
  test "tmux shim cli: aliases and prefixes" {}    // "splitw", "split-w", "lsp" resolve; "kill" and "show" → ambiguous; "new-session" → "unknown command: new-session"
  test "tmux shim cli: unknown flag and command" {} // "kill-pane -Q" → "command kill-pane: unknown flag -Q"; "frobnicate" → "unknown command: frobnicate"
  test "tmux shim cli: missing value" {}           // "split-window -t" → "command split-window: -t expects an argument"
  test "tmux shim cli: sequence" {}                // {"set-option","-p","-t","%2","a","b",";","kill-pane","-t","%2"} → 2 commands
  test "tmux shim cli: -- ends flags" {}           // respawn-pane -k -t %2 -- "cd 'C:\\x' && env A=1 'y' -z" → positional[0] is the whole string
  test "tmux shim cli: targets and sizes" {}       // "%12" pane 12, "@3" window 3, "@3.%4" pane 4, "0:1" invalid; "70%" percent, "30" cells, "0%"/"101%"/"x" null
  ```
- [ ] **Step 2: Run** `LOCK ZIG build test -j6 -Dtest-filter="tmux shim cli"` → FAIL.
- [ ] **Step 3: Implement** the parser in getopt style: clustered flags `-dh`, `-tVALUE` and `-t VALUE`, `--`. No allocation except the command slice in `arena`. Then the shells, the stubs and the test imports.
- [ ] **Step 4: Verify** the filter passes; `LOCK ZIG build -j6` passes.
- [ ] **Step 5: Commit** `git commit -m "feat(tmux): tmux argv parser, M4 file shells and stub signatures"`

### Task 4: Format expansion and pane-command parser

**Review:** light.

**Files:** Modify (fill the shells) `src/tmux_shim/format.zig`, `src/tmux_shim/sh_command.zig` (both std only).

**Interfaces:**
- Produces:
  ```zig
  // format.zig
  pub fn expand(w: *std.Io.Writer, fmt: []const u8, ctx: anytype) std.Io.Writer.Error!void;
      // ctx has `fn lookup(ctx, name: []const u8) ?[]const u8`. "#{name}" → lookup or "" ; "##" → "#"; "#D #P #T #S #I #W" → pane_id pane_index
      // pane_title session_name window_index window_name; "#[…]" and any other "#x" copied verbatim; an unterminated "#{" is copied verbatim
  // sh_command.zig — grammar  [cd W &&] [env (NAME=W)*] W+   (POSIX quoting: '…', "…" with \" \\ \$ \` escapes, \x outside quotes; no expansions)
  pub const Parsed = struct { cwd: ?[]const u8, env: []const []const u8, argv: []const []const u8 };
  pub fn parse(arena: Allocator, s: []const u8) error{ Unsupported, OutOfMemory }!Parsed;
      // Unsupported: empty, unbalanced quote, or any unquoted $ ` * ? [ ; | & < > ( ) ~ other than the single "&&" after cd, a control character, "cd" without "&&"
  ```
- [ ] **Step 1: Failing tests:**
  - `"tmux shim format: Claude probe"`: the 8-field TAB probe expands to `xterm-ghostty\toff\t0\t0\t0\ton\tbottom\t0` with the matching lookup.
  - `"tmux shim format: unknown var is empty"`, `"tmux shim format: ## and #[ ] and short aliases"`, `"tmux shim format: unterminated"`.
  - `"tmux shim sh_command: recon §6 Windows example"`: the exact string from recon §6 gives cwd `C:\D\den4ik\Ghostty`, env `{CLAUDECODE=1, CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1, CLAUDE_CODE_ATTRIBUTION_PROJECT=}`, argv[0] `%USERPROFILE%\.local\bin\claude.exe`, and keeps `--agent-id researcher@my-team`.
  - `"tmux shim sh_command: quote escape"`: `'it'"'"'s'` → `it's`. Also `'C:\a\'"'"'b'` → `C:\a\'b`.
  - `"tmux shim sh_command: double quotes"`: `"a \"b\" \$c"` → `a "b" $c`.
  - `"tmux shim sh_command: unsupported"`: `$HOME`, `a; b`, `a | b`, `` `x` ``, `a*`, a newline, and `cd x` without `&&` → `error.Unsupported`.
  - `"tmux shim sh_command: no cd, no env"`: `'C:\p q\x.exe' -a` → argv `{C:\p q\x.exe, -a}`, cwd null.
- [ ] **Step 2: Run** `LOCK ZIG build test -j6 -Dtest-filter="tmux shim format"` and `"tmux shim sh_command"` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Verify** both filters pass.
- [ ] **Step 5: Commit** `git commit -m "feat(tmux): #{} format expansion and the POSIX one-liner parser"`

### Task 5: `SplitTree.replace` (core) and tmux layouts

**Review:** light (the core change is small; the reviewer checks refcounts).

**Files:** Modify `src/datastruct/split_tree.zig` (add `replace` + tests); Modify (fill) `src/apprt/win32/tmux/layout.zig`.

**Interfaces:**
- Produces:
  ```zig
  // split_tree.zig — copy of the tree with the leaf at `at` holding `view`; refs every view of the new tree (as `split` does); zoom kept
  pub fn replace(self: *const Self, gpa: Allocator, at: Node.Handle, view: *View) Allocator.Error!Self;   // asserts nodes[at] is a leaf
  // tmux/layout.zig — generic over a SplitTree type; pure
  pub fn mainVertical(comptime Tree: type, gpa: Allocator, leader: *Tree.View, others: []const *Tree.View, leader_share: f16) !Tree;
      // root horizontal split: left = leader (ratio leader_share), right = others stacked top→bottom, equal heights (chain ratios 1/k)
  pub fn tiled(comptime Tree: type, gpa: Allocator, views: []const *Tree.View) !Tree;
      // cols = ceil(sqrt(n)), rows = ceil(n / cols); rows equal, columns in a row equal; row-major order of `views`
  pub fn ancestorSplit(comptime Tree: type, tree: *const Tree, at: Tree.Node.Handle, layout: Tree.Split.Layout) ?struct { split: Tree.Node.Handle, pane_first: bool };
  pub fn ratioFor(size: cli.Size, window_px: i32, span_px: i32, cell_px: u32, pane_first: bool) ?f16;
      // percent → share of window_px; cells → cells*cell_px; converted into the left/top share of the span; null if outside (0, 1)
  pub fn newPaneRatio(size: ?cli.Size, span_px: i32, cell_px: u32, new_first: bool) ?f16; // -l: size of the NEW pane; null size → 0.5
  pub fn fits(span_px: i32, ratio: f16, gap_px: i32, min_px: i32) bool;                     // both sides ≥ min_px after the split
  ```
- [ ] **Step 1: Failing tests:**
  - `"SplitTree: replace keeps shape, ratios and zoom"`: A|(B/C) with B zoomed; replace B by D → same node count and ratios, D zoomed, and B's ref count drops after the old tree's deinit.
  - `"SplitTree: replace root leaf"`.
  - `"win32 tmux layout: main-vertical leader 30% and equal stack"`: 4 views → `SplitLayout` rects over 1000×600 with gap 4. The leader width is within ±1 px of 0.3 × (1000 − 4); the 3 right panes have equal heights ±1.
  - `"win32 tmux layout: tiled 5 panes is 3+2"`.
  - `"win32 tmux layout: new pane 70% to the right"`: `newPaneRatio(70%, …, false)` = 0.3.
  - `"win32 tmux layout: resize -x 30% on the right child"`.
  - `"win32 tmux layout: fits refuses below two cells"`.
- [ ] **Step 2: Run** `LOCK ZIG build test -j6 -Dtest-filter="SplitTree: replace"` and `"win32 tmux layout"` → FAIL.
- [ ] **Step 3: Implement.** Layouts use `SplitTree.init` + `split` on single-leaf trees, built bottom-up.
- [ ] **Step 4: Verify** both filters pass; `LOCK ZIG build -j6 -Demit-lib-vt` passes.
- [ ] **Step 5: Commit** `git commit -m "feat(core): SplitTree.replace; tmux main-vertical and tiled layouts"`

### Task 6: Wire fields for tmux and `tmux.exe`

**Review:** opus (pipe client security, process startup budget).

**Files:**
- Modify `src/apprt/win32/ipc/protocol.zig`:
  - Request fields `cwd: []const u8 = ""`, `env: []const []const u8 = &.{}`, `stdin: ?[]const u8 = null`, `pane: []const u8 = ""`.
  - `pub const max_request_tmux: u32 = 4 << 20`; `pub const max_stdin_tmux: u32 = 512 << 10`.
  - `pub fn tmuxPipeName(buf: []u8, pid: u32, nonce: u64) ![]const u8` → `\\.\pipe\ghostty-tmux-<pid>-<16 hex>`.
  - `pub fn tmuxEnvValue(buf: []u8, pipe: []const u8, pid: u32) ![]const u8` → `<pipe>,<pid>,0`.
  - `pub fn pidFromTmuxPipe(name: []const u8) ?u32`: the digits between `ghostty-tmux-` and the next `-`.
- Create `src/tmux_shim/main.zig` (entry and process glue only), `run.zig` (testable logic), `pipe.zig` (client transport), `win.zig` (externs), and `src/build/GhosttyTmuxShim.zig`.
- Modify `src/build/main.zig` (export) and `build.zig`: install `tmux.exe` next to `ghostty.exe` when the target is Windows and the runtime is `win32`; add the step `test-tmux-shim`.
- Create `test/windows/e2e/tmux-cli.ps1` (no window).

**Interfaces:**
- Consumes: `cli.parseGlobal`, `cli.Diag` (Task 3); `protocol.encodeRequest`, `parseResponse`, frame helpers.
- Produces:
  ```zig
  // run.zig
  pub const Env = struct { tmux: ?[]const u8, tmux_pane: ?[]const u8, trace: ?[]const u8, stats: bool,
      block: []const []const u8 /* "K=V": '='-prefixed and non-UTF-8 entries removed (debug note in trace) */ };
  pub const Outcome = struct { code: u8, stdout: []const u8, stderr: []const u8 };
  pub const client_timeout_ms = 10_000;  pub const deadline_margin_ms = 250;   // request deadline = start + timeout − margin (client.zig rule)
  pub fn run(arena: Allocator, argv: []const []const u8, env: Env, cwd: []const u8, transport: anytype, stdin: anytype) !Outcome;
      // order: -V → "tmux 3.5a\n" (no IPC); -L without -S → "no server running on <name>" 1 (external mode is M5);
      // pipe = -S value, else first field of TMUX, else "no server running on default" 1; expected_pid = protocol.pidFromTmuxPipe(pipe);
      // stdin read only for load-buffer with last positional "-": > max_stdin_tmux → "ghostty: request too large" 1, not valid UTF-8 →
      // "ghostty: invalid UTF-8 on stdin" 1 (Claude falls back to OSC 52); request {v:1, op:"tmux", args: Global.rest, cwd, env: block,
      // stdin, pane: TMUX_PANE or "", deadline_ms}; response code ok → 0, anything else → 1; stdout/stderr verbatim
  pub const TransportError = error{ NoServer, NotOurServer, Timeout, BrokenPipe, ProtocolError, OutOfMemory };
      // NoServer/NotOurServer → "no server running on <pipe>"; Timeout → "ghostty: server timed out"; others → "ghostty: lost connection to <pipe>"
  // pipe.zig — CreateFileW(GENERIC_READ|WRITE, FILE_FLAG_OVERLAPPED|SECURITY_SQOS_PRESENT|SECURITY_IDENTIFICATION) in a loop until the
  // deadline: ERROR_PIPE_BUSY → WaitNamedPipeW(min(remaining, backoff)), backoff 50 → 100 → 200 → 400 → 800 → 1000 ms;
  // ERROR_FILE_NOT_FOUND → NoServer at once; busy past the deadline → Timeout; GetNamedPipeServerProcessId must equal expected_pid
  // when given; overlapped write/read with the deadline
  pub fn request(alloc: Allocator, name: []const u8, expected_pid: ?u32, payload: []const u8, deadline_ms: u64) TransportError![]u8;
  // main.zig — argv via std.process.argsAlloc (WTF-8), env via GetEnvironmentStringsW; output: WriteConsoleW (UTF-16) when GetConsoleMode
  // succeeds on the handle, else raw WriteFile; "__idle" as the only argument → SetConsoleCtrlHandler(null, TRUE) and
  // WaitForSingleObject(GetCurrentProcess(), INFINITE) (ends only when killed; no stdin read); trace + stats (R-M4-9)
  ```
- [ ] **Step 1: Failing tests** (in `run.zig`/`pipe.zig`, run by `test-tmux-shim`):
  - `"tmux shim run: -V needs no server"`.
  - `"tmux shim run: no TMUX and no -S"`: exit 1, stderr `no server running on default\n`.
  - `"tmux shim run: -S beats TMUX"`, `"tmux shim run: expected pid from pipe name"` (`ghostty-tmux-42-00ff…` → 42; `ghostty-tmux-x` → null).
  - `"tmux shim run: request fields"`: the fake transport captures the payload. `op` = `tmux`; `args` = the command argv; `pane` = `%3`; the env block has no `=C:` entry and no entry with an unpaired surrogate; `deadline_ms` = start + 9750.
  - `"tmux shim run: response mapping"`: ok + `"%5\n"` → stdout `%5\n`, code 0; failed → code 1, stderr verbatim; bad JSON → 1 `ghostty: lost connection to …`.
  - `"tmux shim run: load-buffer reads stdin only when asked"`: `display-message` with a stdin that panics if read → OK.
  - `"tmux shim run: load-buffer caps and UTF-8"`: 512 KiB + 1 → too large; invalid UTF-8 → exit 1.
  - `"tmux shim pipe: server pid mismatch is NotOurServer"`: a test server on its own thread with a std-only overlapped pipe; `expected_pid` = pid + 1.
  - `"tmux shim pipe: busy retries until the deadline"`: a test server with one instance that is held busy for 1500 ms; the client gets through (not `NoServer`).
- [ ] **Step 2: Run** `LOCK ZIG build test-tmux-shim -j6` → FAIL.
- [ ] **Step 3: Implement.** The exe uses the build's optimize mode, the console subsystem, `strip` in release modes, and no libc. The scenario `tmux-cli.ps1` (`# e2e: milestone=M4 timeout=60 order=700`) has no Ghostty and no window. It checks:
  - `tmux.exe -V` → exactly `tmux 3.5a\n`, exit 0;
  - no `TMUX` → exit 1 `no server running on default`;
  - 50× `-V` with `GHOSTTY_TMUX_STATS=1` → p95 wall < 50 ms and peak private < 5 MB (recorded);
  - the PE import table (a small parser in the scenario) has no `user32`, `gdi32`, `ole32`, `ucrt*` or `vcruntime*` (the full list goes in the report);
  - `GHOSTTY_TMUX_TRACE` writes one JSON line into the sandbox, and 8 parallel invocations give 8 whole lines.
- [ ] **Step 4: Verify** `test-tmux-shim` passes; `LOCK ZIG build -j6` installs `zig-out\bin\tmux.exe`; the implementer runs `E2E -Only tmux-cli` → PASS; `LOCK ZIG build -j6 -Demit-lib-vt` passes.
- [ ] **Step 5: Commit** `git commit -m "feat(tmux): tmux.exe shim and the tmux wire fields"`

### Task 7: Command semantics (`commands.zig`) and the headless replay test

**Review:** opus (the whole tmux contract lives here).

**Files:** Modify (fill) `src/apprt/win32/tmux/commands.zig`, `src/apprt/win32/tmux/FakeHost.zig` (test-only host).

**Interfaces:**
- Consumes: `cli.*` (3), `format.expand` (4), `layout.*` (5), `claude-spawn.jsonl` (1).
- Produces:
  ```zig
  pub const Context = struct { caller_pane: ?u32, cwd: []const u8, env: []const []const u8, stdin: ?[]const u8, now_ms: u64, deadline_ms: u64 };
  pub const Output = struct { code: u8 = 0, stdout: std.ArrayList(u8) = .empty, stderr: std.ArrayList(u8) = .empty };
  pub fn execute(comptime Host: type, host: *Host, arena: Allocator, argv: []const []const u8, ctx: Context, out: *Output) Allocator.Error!void;
      // argv = cli.Global.rest; ctx.deadline_ms passed → nothing executed, code 1 "ghostty: server timed out"
  pub const Direction = enum { right, down, left, up };          // -h → right, -v → down, -b flips to left/up
  pub const Spawn = struct { command: ?[]const u8, cwd: []const u8, client_env: []const []const u8, extra_env: []const []const u8 /* -e */, start_dir: ?[]const u8 /* -c */ };
  pub const SplitRequest = struct { direction: Direction, size: ?cli.Size, focus: bool, spawn: Spawn };
  pub const Layout = enum { main_vertical, tiled };
  pub const main_vertical_share: f16 = 0.3;                     // fixed (tmux would use main-pane-width; Claude follows with -x 30%)
  pub const ResizeRequest = struct { x: ?cli.Size, y: ?cli.Size };
  pub const CaptureRequest = struct { to_stdout: bool };        // R-M4-7: visible screen only
  pub const Vars = struct { pane_id: u32, window_id: u32, window_index: u32, window_name: []const u8, pane_index: u32, pane_active: bool,
      pane_title: []const u8, pane_top: u32, pane_left: u32, pane_width: u32, pane_height: u32, pane_pid: u32, pane_dead: bool,
      pane_current_path: []const u8 };
      // fixed: session_name "0", session_id "$0", client_termtype "xterm-ghostty", allow-passthrough "off", focus-events "0",
      // status "on", status-position "bottom", window_bigger "0", client_control_mode "0"; window_panes = panes().len (computed here)
  pub const Options = struct {   // owned by the host (Registry.State in production)
      global: Map, windows: std.AutoHashMapUnmanaged(u32, Map), panes: std.AutoHashMapUnmanaged(u32, Map), buffer: ?[]u8, // Map = StringArrayHashMapUnmanaged([]const u8)
      pub fn remainOnExit(self: *const Options, pane: u32, window: u32) enum { off, on, failed };
      pub fn dropPane(self: *Options, gpa: Allocator, pane: u32) void;
      pub fn deinit(self: *Options, gpa: Allocator) void;
  };
  // Host contract (duck-typed; FakeHost and Registry.Host implement exactly this). A Window handle is valid only until the next
  // mutating call (split/respawn/kill/layout); execute re-resolves by id after each.
  //   Pane, Window: handle types;  fn findPane(*Host, u32) ?Pane;  fn findWindow(*Host, u32) ?Window;  fn fallbackPane(*Host) ?Pane (focused)
  //   fn windowOf(*Host, Pane) Window;  fn panes(*Host, Allocator, Window) ![]Pane (tree order);  fn activePane(*Host, Window) Pane
  //   fn vars(*Host, Pane) Vars;  fn windowId(*Host, Window) u32;  fn exited(*Host, Pane) bool
  //   fn split(*Host, Pane, SplitRequest) error{ NoSpace, TooSmall, Unsupported, SpawnFailed, OutOfMemory }!Pane
  //   fn respawn(*Host, Pane, Spawn) error{ Unsupported, SpawnFailed, OutOfMemory }!void   (re-applies title/options itself)
  //   fn kill(*Host, Pane) void;  fn focus(*Host, Pane) void
  //   fn setTitle(*Host, Pane, []const u8) !void;  fn layout(*Host, Window, Layout) !void;  fn resize(*Host, Pane, ResizeRequest) !void;  fn toggleZoom(*Host, Pane) void
  //   fn options(*Host) *Options;  fn optionsChanged(*Host, window_id: u32) void;  fn gpa(*Host) Allocator;  fn setClipboard(*Host, []const u8) !void
  //   fn sendKeys(*Host, Pane, keys: []const []const u8, literal: bool, hex: bool, repeat: u32) error{ UnknownKey, OutOfMemory }!void
  //   fn capture(*Host, Pane, CaptureRequest, *std.Io.Writer) !void
  ```
  Semantics (beyond SPEC §12.2):
  - **Targets.** `%N` → pane. `@N` → its active pane (for pane commands) or the window. `none` → `caller_pane`, then `fallbackPane`. `invalid` or missing → `can't find pane: <t>` / `can't find window: <t>`.
  - **Errors.** `Unsupported` → `ghostty: unsupported pane command`, exit 1. `NoSpace` → `no space for new pane`. `TooSmall` → `create pane failed: pane too small`.
  - **`split-window`.** Positional args joined with one space form the command. With `-P` it prints `-F` (default `#{session_name}:#{window_index}.#{pane_index}`) + `\n`. `-f` and `-I` → not supported. `-Z`, `-e` and `-c` are honoured through `Spawn`.
  - **`respawn-pane`.** Without `-k` on a live pane → `pane %N still active`.
  - **`kill-pane`.** `-a` = every other pane of the window.
  - **`select-layout`.**
    - `main-vertical` → `layout(.main_vertical)`; the leader is `panes()[0]` (tree order, like tmux's pane index order), at `main_vertical_share`.
    - `tiled` → `layout(.tiled)`.
    - Other names → exit 0, no change (SPEC).
    - `-n/-o/-p/-E` → not supported.
  - **`resize-pane`.** `-x`/`-y` → `resize`. `-Z` → `toggleZoom`. `-L/-R/-U/-D/-M/-T` → not supported.
  - **`select-pane`.** `-T` → `setTitle` (no focus change) then `optionsChanged`. Without `-T` → `focus`. `-L/-R/-U/-D/-l/-m/-M/-Z` → not supported. `-P/-d/-e/-g` ignored.
  - **`set-option`.** Scope `-p/-w/-g/-s` (default pane if `-t` is a pane, else global). `-u` unsets, `-a` appends; `-q/-F/-o` ignored. Exit 0 even for names tmux would reject (lenient, R-M4-8). Then `optionsChanged`.
  - **`display-message`.** Without `-p` → exit 0, no output. `-a/-I/-C/-c/-l` → not supported.
  - **`list-panes`.** Default `-F` is `#{pane_index}: [#{pane_width}x#{pane_height}] #{pane_id}`; `-a`/`-s` = every window. **`list-windows`** default: `#{window_index}: #{window_name} (#{window_panes} panes) #{window_id}`.
  - **`show-environment`** → exit 0, empty.
  - **`load-buffer`.** Needs positional `-` and stdin (else not supported). Stores `buffer`; `-w` → `setClipboard`.
  - **`send-keys`.** Positional keys and `-l`/`-H`/`-N` go to `sendKeys` unencoded. `-R`, `-X`, `-M`, `-K`, `-c` → not supported; `-F` ignored.
  - **`capture-pane`** → `capture` (R-M4-7).
- [ ] **Step 1: Failing tests.** `FakeHost` = windows of `SplitTree(FakePane)` over 1000×600 px, cell 10×20, gap 4. Ids come from one counter shared by panes, and a respawn uses one up like the real host. It records every spawn.
  - `"win32 tmux commands: replay Claude spawn fixture"`. Runs every line of `claude-spawn.jsonl` in order. Each argv goes through `cli.parseGlobal`, and `rest` is rewritten through an id map:
    - fixture `%1` → the fake leader;
    - fixture `@1` → the answered `#{window_id}`;
    - each fixture `split-window` answer → the live answer.

    This is the same mapping as Task 12's e2e. Asserts per line:
    - exit 0;
    - the stdout of `display-message`/`list-panes`/`split-window` matches the mapped fixture answers byte for byte (`%N\n`, the probe string, `0:@W.%L`);
    - after the second spawn's `select-layout` + `resize-pane`, the tree is leader | (alpha / beta) with leader share 0.30 ± 0.005;
    - both teammates have a title, `remain-on-exit failed`, and a respawn whose command starts with `cd '`;
    - after the cleanup lines only the leader remains.
  - `"win32 tmux commands: split refuses below two cells"` (stderr contains `no space`).
  - `"win32 tmux commands: kill-pane twice and kill of a pane in a closed tab"`.
  - `"win32 tmux commands: respawn keeps id and options"`, `"win32 tmux commands: respawn without -k on a live pane"`.
  - `"win32 tmux commands: unsupported pane command"`: the host returns `Unsupported` → exit 1 with the fixed text.
  - `"win32 tmux commands: select-pane -T does not move focus"`, `"win32 tmux commands: -d keeps focus, no -d focuses"`.
  - `"win32 tmux commands: unsupported flags fail loudly"` (`split-window -f` → `split-window: -f is not supported by Ghostty`).
  - `"win32 tmux commands: set-option and select-pane -T report optionsChanged"`.
  - `"win32 tmux commands: unknown target"`, `"win32 tmux commands: sequence stops at first error"`, `"win32 tmux commands: expired request does nothing"`.
  - `"win32 tmux commands: remain-on-exit resolution pane > window > global"`, `"win32 tmux commands: list-panes order is tree order"`.
- [ ] **Step 2: Run** `LOCK ZIG build test -j6 -Dtest-filter="win32 tmux commands"` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Verify** the filter passes.
- [ ] **Step 5: Commit** `git commit -m "feat(tmux): command semantics against a host, Claude spawn replay test"`

### Task 8: tmux pipe server, routing, pane ids, `TMUX`/`TMUX_PANE`/PATH, opt-out key

**Review:** opus (pipe security, env precedence, server lifetime).

**Files:**
- Modify `src/apprt/win32/ipc/Server.zig`: the fields `post_tag: usize = 0`, `max_request: u32 = protocol.max_request_m2`, `io_timeout_ms: u32 = 2000` and `close_wait_ms: u32 = 1000` replace the constants. `PostMessageW` sends `post_tag` as wparam.
- Modify (fill) `src/apprt/win32/tmux/Server.zig`, `src/apprt/win32/tmux/env.zig`.
- Modify `src/apprt/win32/App.zig`:
  - fields;
  - `tmux_Server.start` right after `if (self.forwarded) return;` and before `Window.create`;
  - stop next to `stopServer`;
  - `WM_GHOSTTY_IPC` routes on wparam first: `1` → `if (self.tmux_server.server == null) return 0` else `tmux_Server.handle`; `0` → the existing guard and handler.
- Modify `src/apprt/win32/Surface.zig` (`pane_id`, `CreateOptions.pane_id`, `defaultTermioEnv`), `src/apprt/win32/hooks.zig` (calls listed below), `src/apprt/win32/messages.zig` (timer `tmux_keys = 4`, uniqueness test).
- Modify `src/config/Config.zig`: `@"windows-tmux-shim": bool = true`, with a doc comment covering R-M4-11, next to `windows-single-instance`.
- Modify `test/windows/e2e.ps1` (`ValidateSet` += `M4`). Create `test/windows/e2e/_tmux.ps1` (`Invoke-Tmux`, `Get-TmuxPanes`) and `test/windows/e2e/tmux-env.ps1`.

**Interfaces:**
- Consumes: `protocol.tmuxPipeName`, `tmuxEnvValue`, `max_request_tmux` (6); the stubs `Registry`, `pane_io`, `labels` (3).
- Produces:
  ```zig
  // tmux/Server.zig
  pub const State = struct { server: ?*ipc.Server = null, pipe: ?[]u8 = null /* UTF-8 name */, exe_dir: ?[]u8 = null };
  pub fn start(app: *App) void;  // exe_dir resolved first (std.process.executablePath → dirname), independent of the claim; nonce from
                                 // std.crypto.random; claim + start (post_tag 1, max_request_tmux, io_timeout 500, close_wait 200);
                                 // claim failure → log.warn once, pipe stays null
  pub fn stop(app: *App) void;   // after the message loop, like App.stopServer
  pub fn handle(app: *App, pending: *ipc.Server.Pending) void;  // parse; v mismatch → 3; op != "tmux" → 2 "unknown op"; else Registry.run
  pub fn testState(app: *App, jw: *std.json.Stringify) !void;
      // "tmux":{"pipe":…, "panes":[{"pane":"%N","surface":id,"tab":id,"window":id,"env_tmux_pane":"%N"|null}]}
  // tmux/env.zig — pure; map keys are case-insensitive on Windows (asserted by a test; if std's Map is not, apply() normalises)
  pub const Options = struct { enabled: bool, pipe: ?[]const u8, server_pid: u32, pane_id: u32, exe_dir: ?[]const u8,
      client_env: []const []const u8 = &.{}, extra: []const []const u8 = &.{} };
  pub fn apply(map: *std.process.Environ.Map, opts: Options) !void;
      // enabled == false: client_env and extra overlays only; TMUX/TMUX_PANE/PATH untouched (pre-M4)
      // 1 client_env overlay ("=…" entries and keys TMUX, TMUX_PANE, GHOSTTY_SURFACE_ID, GHOSTTY_LOG skipped)
      // 2 TMUX = tmuxEnvValue, TMUX_PANE = "%<pane_id>" (both removed when pipe == null)
      // 3 PATH = exe_dir + ";" + PATH without other entries equal to exe_dir (case-insensitive, trailing '\' ignored); skipped if exe_dir == null
      // 4 extra overlay (same skip list; may override PATH — parser path only, SPEC §12.3 order)
  // Surface.zig
  pane_id: u32,                            // = id unless CreateOptions.pane_id
  env_tmux_pane: ?u32 = null,              // what defaultTermioEnv set (test state only)
  // CreateOptions gains  pane_id: ?u32 = null
  pub fn defaultTermioEnv(self: *const Surface) !std.process.Environ.Map; // environMap() + env.apply(.{ enabled = config windows-tmux-shim, … })
  ```
  - **App fields:** `tmux_server: tmux_Server.State = .{}`, `tmux: Registry.State = .{}`, `tmux_keys: pane_io.State = .{}`, `tmux_labels: labels.State = .{}`.
  - **Hook calls added:**

    | Hook | Calls |
    |---|---|
    | `appStopping` | `Registry.appStopping` |
    | `appMessage` (`WM_TIMER tmux_keys`) | `pane_io.onTimer`, chained after recovery |
    | `surfaceDestroying` | `pane_io`, `labels`, then `Registry` (last) |
    | `tabLayoutChanged` | `pane_io.layoutChanged`, `labels.tabLayoutChanged` |
    | `tabShown` | `labels.tabShown` |
    | `tabReparented` | `labels.tabReparented` |
    | `windowChanged` | `labels.windowChanged` |
    | `testState` | `tmux_Server.testState` |
- [ ] **Step 1: Failing tests:**
  - `"win32 tmux env: order and precedence"`. The client env has `TMUX_PANE=%1`, `TMUX=x`, `PATH=C:\u`, `=C:=C:\` and `GHOSTTY_SURFACE_ID=1`. The result has:
    - `TMUX_PANE=%7`;
    - `TMUX=\\.\pipe\ghostty-tmux-42-<nonce>,42,0`;
    - PATH `C:\g;C:\u`;
    - no `=C:` key and no `GHOSTTY_SURFACE_ID` (core sets it later).
  - `"win32 tmux env: Path and PATH merge"`, `"win32 tmux env: exe dir moved to front, not duplicated"`, `"win32 tmux env: no pipe removes TMUX"`, `"win32 tmux env: extra overrides client env"`.
  - `"win32 tmux env: disabled sets no TMUX and does not prepend"`, `"win32 tmux env: disabled keeps an inherited TMUX"`.
  - `"win32 tmux server: tmux pipe answers only op tmux"`: an `ipc.Server` test with `TestUi` and `post_tag 1`; `new-window` → code 2.
  - `"win32 tmux server: standalone process answers tmux"`: the routing helper `routeIpc(wparam, main_server, tmux_server)` sends tag 1 to tmux with `server == null`, and tag 0 to nothing.
  - `"win32 tmux server: silent tmux client releases the queue within 600 ms"`: a raw client connects and writes nothing; a second `Call` completes < 600 ms after the first connected.
  - `"win32 tmux server: 4 MiB limit"` (header 4 MiB + 1 → `bad_request`).
  - `"win32 skeleton: M4 timer id unique"`.
  - `"win32 config: windows-tmux-shim defaults to true"`.
- [ ] **Step 2: Run** `LOCK ZIG build test -j6 -Dtest-filter="win32 tmux"` (and `"win32 ipc"`, `"win32 skeleton"`, `"win32 config"`) → FAIL.
- [ ] **Step 3: Implement.** Scenario `tmux-env.ps1` (`order=710`, Git Bash config):
  - It types once into the first pane, after `Wait-BashReady` and before any split:
    ```
    printf '%s|%s|%s\n' "$TMUX" "$TMUX_PANE" "$(command -v tmux)" > <file>
    ```
    It asserts `TMUX` = `<state.tmux.pipe>,<pid>,0` (the name has `-<16 hex>`), `TMUX_PANE` = the pane of that surface, and tmux = `<zig-out\bin>/tmux` in MSYS form.
  - A second surface (`new_split` via the test IPC) is checked **without typing**: its `env_tmux_pane` in `state.tmux.panes` differs and equals its `pane`.
  - `Invoke-Tmux $g display-message -p x` → exit 1, `ghostty: tmux is not ready` (stub; Task 12 changes this assertion).
  - A second Ghostty with `windows-tmux-shim = false` and an inherited `TMUX=outer` → the file shows `outer|` and `command -v tmux` is not first on PATH.
- [ ] **Step 4: Verify** the filters pass; `LOCK ZIG build -j6`.
- [ ] **Step 5: Commit** `git commit -m "feat(win32): tmux pipe server, pane ids, TMUX/TMUX_PANE, shim dir first on PATH, windows-tmux-shim"`

### Task 9: DCS `tmux;` passthrough — verify the parser's ESC fall-through (core test first)

**Review:** light.

**Files:** Modify `src/terminal/stream.zig` (test block only). Create `test/windows/e2e/dcs-tmux.ps1` only if C2 = content arrives.

- [ ] **Step 1: The evidence test (before anything else).** Name: `"stream: tmux passthrough OSC reaches the handler"`. It feeds the exact wrapped bytes through `terminal.Stream` with a recording handler. Cases:
  - OSC 9 + BEL: `ESC P tmux; ESC ESC ] 9 ; m4 BEL ESC \`
  - OSC 777 + ST: `… ESC ESC ] 777 ; notify ; a ; b ESC ESC \ ESC \`
  - OSC 0 (title)

  Asserts: each inner OSC is dispatched exactly once with its payload; nothing else is printed to the screen (no `mux;` text, no stray `\`). Run `LOCK ZIG build test-lib-vt -j6 -Dtest-filter="stream: tmux passthrough"`.
- [ ] **Step 2: Decide from the result.**
  - **PASS (expected):** the task stays tests-only. Add `"stream: tmux passthrough nested and oversize"`: a doubly wrapped sequence prints nothing harmful, and a 1 MiB payload does not hang. No `dcs.zig`/`stream_handler.zig` change. Record the parser path (`parse_table.zig:436`) in the commit message for Task 15's SPEC rewording.
  - **FAIL:** stop. Report the failing bytes and the handler log to the lead, who rules on a `Parser.zig` touch point (new task 9.1). Do not change core here.
- [ ] **Step 3 (C2 = content arrives through ConPTY):** scenario `dcs-tmux.ps1` (`order=750`, Git Bash) prints the Task 2 BEL case and asserts that `state.m3.notify` recorded `m4-dcs-bel`.
- [ ] **Step 4: Verify** the filter passes; `LOCK ZIG build -j6 -Demit-lib-vt`.
- [ ] **Step 5: Commit** `git commit -m "test(terminal): tmux DCS passthrough reaches the OSC handler through the parser's ESC fall-through"`

### Task 10: Pane spawn — Git Bash, `sh_command`, idle placeholder; `Tab.splitWith`/`replaceSurface`

**Review:** opus (process spawning, quoting, surface lifetime).

**Files:** Modify (fill) `src/apprt/win32/tmux/spawn.zig`. Modify:
- `src/apprt/win32/Surface.zig`: `CreateOptions.tmux: ?*const spawn.Plan`, applied to the surface config; the overlay is kept for `defaultTermioEnv`.
- `src/apprt/win32/Tab.zig`: `splitWith`, `replaceSurface`, `last_content`, `leafRects`.
- `src/os/windows_shell.zig`: `pub fn findGitBash`.

**Interfaces:**
- Consumes: `sh_command.parse` (4), `SplitTree.replace` (5), `commands.Spawn` (7), `env.apply`, `Surface.pane_id` (8).
- Produces:
  ```zig
  // spawn.zig
  pub const Plan = struct { argv: ?[]const [:0]const u8 /* null = configured command */, cwd: []const u8,
      client_env: []const []const u8, extra_env: []const []const u8 /* -e then sh_command env */ };
  pub const Probe = struct { exists: *const fn (path: []const u8) bool, git_bash: *const fn (arena: Allocator, env: []const []const u8) ?[]const u8 };
  pub fn plan(arena: Allocator, s: commands.Spawn, exe_dir: []const u8, probe: Probe) error{ Unsupported, OutOfMemory }!Plan; // R-M4-5
  // Surface.create with opts.tmux: config.command = .{ .direct = argv } (if non-null), config.@"working-directory" = .{ .path = cwd },
  // config.@"wait-after-command" = true; self.tmux_env = owned copies of client_env + extra_env; defaultTermioEnv passes them to env.apply
  // Tab.zig
  last_content: geom.Rect = .{},          // set by every layout() with a non-empty client rect
  pub fn leafRects(self: *Tab, alloc: Allocator) !SplitLayout.Layout(Surface.Tree);
      // split_layout when present; else SplitLayout.compute over last_content (minimized window); never null
  pub const SplitOptions = struct { ratio: f16 = 0.5, focus: bool = true, pane_id: ?u32 = null, tmux: ?*const spawn.Plan = null };
  pub fn splitWith(self: *Tab, at: *Surface, direction: Surface.Tree.Split.Direction, opts: SplitOptions) SplitError!*Surface; // `split` = splitWith(.{})
  pub fn replaceSurface(self: *Tab, old: *Surface, plan: *const spawn.Plan) SplitError!*Surface;
      // new surface (parent = old, pane_id = old.pane_id), tree.replace, layout, focus moves if old was focused, old hidden then released
      // (its pseudo console closes; SPEC §18.14 semantics), hooks.tabLayoutChanged
  // Both size the new surface from leafRects when the window is iconic, so it never starts at the stale full-tab size.
  ```
- [ ] **Step 1: Failing tests:**
  - `"win32 tmux spawn: cat is the idle placeholder"` → `{<exe>\tmux.exe, __idle}`.
  - `"win32 tmux spawn: CLAUDE_CODE_GIT_BASH_PATH wins"`, `"win32 tmux spawn: Git Bash -c"`.
  - `"win32 tmux spawn: no Git Bash uses the parser"`: the recon §6 example → direct argv, cwd from `cd`, env extras.
  - `"win32 tmux spawn: -c start dir beats client cwd"`, `"win32 tmux spawn: empty command is the configured one"`, `"win32 tmux spawn: unparsable without Git Bash"` → `Unsupported`.
  - `"win32 tab: leaf rects while minimized"`: pure over `SplitLayout.compute` with a stored `last_content`.
  - `"win32 tmux spawn: bash -c receives Claude's command line verbatim"`. Uses real Git Bash (`SkipZigTest` without it), a temp dir named `тест m4` with a space, and the exact core path: `Command.direct` → `windows_cmdline.writeCommandLine` → `CreateProcessW`. Strings, each with its expected stdout:
    - (a) gives `a b|C:\p q|x y|it's|`:
      ```
      cd '<dir>' && env A='x y' B='it'"'"'s' '<git>\usr\bin\printf.exe' '%s|' 'a b' 'C:\p q' "$A" "$B"
      ```
    - (b) gives the literal `C:\a\'b|`:
      ```
      '<printf>' '%s|' 'C:\a\'"'"'b'
      ```
    - (c) is a string without spaces, containing `*`, so MSYS globbing is checked. It gives `*|`:
      ```
      '<printf>' '%s|' '*'
      ```
    - (d) gives `/c/x|`, so a native exe gets no MSYS path conversion of a quoted `/c/x`:
      ```
      '<printf>' '%s|' '/c/x'
      ```

    Record the observed argv in the report. If (c) or (d) differ, `spawn.plan` sets `MSYS_NO_PATHCONV=1`/`MSYS2_ARG_CONV_EXCL=*` in the pane's extra env. That is decided and tested here.
- [ ] **Step 2: Run** `LOCK ZIG build test -j6 -Dtest-filter="win32 tmux spawn"` and `"win32 tab"` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Verify** pass; `"windows shell"` still passes; `LOCK ZIG build -j6`.
- [ ] **Step 5: Commit** `git commit -m "feat(win32): tmux pane spawn (Git Bash, one-liner parser, idle placeholder), split with options, surface replace"`

### Task 11: `send-keys` and `capture-pane`

**Review:** light.

**Files:** Modify (fill) `src/apprt/win32/tmux/keys.zig` and `src/apprt/win32/tmux/pane_io.zig`. Create `test/windows/e2e/tmux-send-keys.ps1` (written and parsed here; the lead runs it in the W5 batch, after Task 12).

**Interfaces:**
- Consumes: `commands.CaptureRequest` (7); `Surface.pane_id`, App fields, timer id (8); core `Surface.performBindingAction(.{ .text = … })` and `Screen.dumpString`.
- Produces:
  ```zig
  // keys.zig — tmux key names → bytes: Enter "\r", Escape "\x1b", Tab "\t", BTab "\x1b[Z", BSpace "\x7f", Space " ",
  // Up/Down/Right/Left "\x1b[A/B/C/D", Home "\x1b[H", End "\x1b[F", PageUp/PPage "\x1b[5~", PageDown/NPage "\x1b[6~", IC "\x1b[2~", DC "\x1b[3~",
  // F1–F12 xterm, C-x → ctrl byte, M-x → ESC x; an unknown token is sent literally (tmux); -l literal; -H hex bytes; -N repeat
  pub fn encode(arena: Allocator, args: []const []const u8, literal: bool, hex: bool, repeat: u32) error{ UnknownKey, OutOfMemory }![]u8; // UnknownKey only for bad -H hex
  pub fn toTextAction(arena: Allocator, bytes: []const u8) ![]const u8;   // Zig-string escapes for input.Binding.Action.text
  // pane_io.zig
  pub const State = struct { queue: std.ArrayList(Item) = .empty, timer_armed: bool = false,
      tab_changed_ms: std.AutoHashMapUnmanaged(u32, u64) = .empty, pane_seen_ms: std.AutoHashMapUnmanaged(u32, u64) = .empty };
  pub const gate_age_ms = 300; pub const gate_settle_ms = 150;         // R-M4-6 (every tabLayoutChanged counts)
  pub fn sendKeys(app: *App, surface: *Surface, bytes: []const u8) !void; // queue + arm timer (25 ms); flush in order when the gate opens
  pub fn gateOpen(created_ms: u64, tab_changed_ms: u64, now_ms: u64) bool;
  pub fn capture(surface: *Surface, req: commands.CaptureRequest, w: *std.Io.Writer) !void; // viewport rows, LF line ends, trailing blanks trimmed per line
  ```
  A pane's creation time is the first `layoutChanged` that sees it (`pane_seen_ms`), so `Surface.zig` (Task 10's file in this wave) is not edited.
- [ ] **Step 1: Failing tests:** `"win32 tmux keys: names, C- and M-, unknown literal"`, `"win32 tmux keys: -l and -H and -N"`, `"win32 tmux keys: text action escapes round-trip"` (through `configpkg.string.parse`), `"win32 tmux pane_io: gate"` (table: age 299/300, settle 149/150), `"win32 tmux pane_io: order kept across panes"`, `"win32 tmux pane_io: closed pane drops its queue"`, `"win32 tmux pane_io: capture visible screen"` (a core `Terminal` test instance).
- [ ] **Step 2: Run** `LOCK ZIG build test -j6 -Dtest-filter="win32 tmux keys"` and `"win32 tmux pane_io"` → FAIL.
- [ ] **Step 3: Implement.** Scenario `tmux-send-keys.ps1` (`order=730`, Git Bash) runs 20 iterations of:
  - `Invoke-Tmux split-window -d -P -F '#{pane_id}'`, then immediately `Invoke-Tmux send-keys -t %N 'echo tok-<i> > <file-i>' Enter`;
  - asserts the file holds exactly `tok-<i>` (the first-byte guard), and that `capture-pane -p -t %N` contains `tok-<i>`;
  - kills the pane.
- [ ] **Step 4: Verify** pass; the scenario parses; `LOCK ZIG build -j6`.
- [ ] **Step 5: Commit** `git commit -m "feat(win32): tmux send-keys with a post-resize gate and capture-pane"`

### Task 12: Real host — commands on Ghostty tabs and surfaces, remain-on-exit, load-buffer; `tmux-replay` e2e

**Review:** opus (UI-thread lifetimes: kill/respawn inside an IPC handler, closing the caller's own pane).

**Files:** Modify (fill) `src/apprt/win32/tmux/Registry.zig`. Modify `src/apprt/win32/actions/surface_actions.zig` (`show_child_exited` → `Registry.childExited`, otherwise unchanged) and `test/windows/e2e/tmux-env.ps1` (stub assertion → a real `display-message`). Create `test/windows/e2e/tmux-replay.ps1`.

**Interfaces:**
- Consumes:
  - `commands.execute`, the Host contract and `Options` (7);
  - `spawn.plan`, `Tab.splitWith`, `Tab.replaceSurface`, `Tab.leafRects` (10);
  - `pane_io.sendKeys`/`capture`, `keys.encode` (11);
  - `layout.*` (5);
  - `labels.optionsChanged` (3 stub);
  - `clipboard.write(app.msg_hwnd, text)`;
  - `Tab.dragMinPx` for `fits`;
  - `Window.removeTab` through `Tab.removeSurface`.
- Produces:
  ```zig
  pub const State = struct { options: commands.Options = .{}, exited: std.AutoHashMapUnmanaged(u32, i32) = .empty /* pane → exit code */,
      shim_panes: std.AutoHashMapUnmanaged(u32, void) = .empty };
  pub const Host = struct { app: *App, /* Pane = *Surface, Window = *Tab; implements the Task 7 contract */ };
  pub fn run(app: *App, req: ipc.protocol.Request, arena: Allocator) Reply;   // parseGlobal is not needed (the shim strips it); caller_pane from req.pane
  pub fn exitAction(remain: enum { off, on, failed }, exit_code: i32, shim_pane: bool) enum { close, keep, core };
  pub fn childExited(surface: *Surface, info: apprt.surface.Message.ChildExited) bool;
      // exitAction: close → post WM_GHOSTTY_CLOSE_SURFACE (process_active false), return true; keep → record exited, return false
      // (core shows its message, wait-after-command); core (not a shim pane) → false
  pub fn surfaceDestroying(surface: *Surface) void;   // drops pane options unless another live surface holds the same pane_id (respawn)
  ```
  Host specifics:
  - **Geometry** (`fits`, `vars`, `resize`) always comes from `tab.leafRects`, never from `split_layout` directly (no `.?`). This works in a minimized window.
  - **`split`** maps `Direction` → `Surface.Tree.Split.Direction`, computes the ratio with `layout.newPaneRatio`, and refuses with `layout.fits` (`TooSmall` for an invalid size, `NoSpace` when the pane is too small). `spawn.plan` `Unsupported` → `Unsupported`.
  - **`respawn`** = `replaceSurface`, then re-applies the stored title (`setUserTitle` + `window.surfaceTitleChanged`) and keeps the options.
  - **`kill`** = `tab.removeSurface` (no confirmation). A kill of the caller's own pane completes the reply first and then removes the surface (posted close). Handles are re-resolved by id afterwards.
  - **`layout(.main_vertical)`** builds with `layout.mainVertical(Surface.Tree, …, commands.main_vertical_share)` + `tab.replaceTree`.
  - **`vars`.** `pane_top/left/width/height` are in cells from the leaf rect and `window.cell_size`; `pane_pid` = the direct child's pid (0 if unknown).
  - **`optionsChanged`** → `labels.optionsChanged`. It is also called after every tree change and after a respawn.
- [ ] **Step 1: Failing tests:** `"win32 tmux registry: childExited decision table"` (`exitAction`), `"win32 tmux registry: options survive respawn and drop on kill"` (pure over `Options` + a fake liveness callback), `"win32 tmux registry: caller pane from request"`, `"win32 tmux registry: geometry while minimized"` (pure: `vars` and `fits` from `leafRects` over a stored `last_content`).
- [ ] **Step 2: Run** `LOCK ZIG build test -j6 -Dtest-filter="win32 tmux registry"` → FAIL.
- [ ] **Step 3: Implement.** Scenario `tmux-replay.ps1` (`order=720`, Git Bash, `surfaces=3`) runs the Task 1 fixture through the real `tmux.exe` and the scenario pipe, with `TMUX_PANE` = the first pane. Every argv is rewritten through the id map of Task 7 (fixture `%1` → `TMUX_PANE`, `@1` → the answered window id, each split answer → the live answer) before it is sent. Steps:
  1. **Fake teammates.** Each respawn string is replaced by:
     ```
     cd '<sandbox>' && env CLAUDECODE=1 '<git bash>' -c 'printf "%s\n" "$TMUX_PANE" > <sandbox>/<pane>.txt; exec sleep 600'
     ```
  2. **Assertions on the spawn.**
     - stdout bytes are exactly `%N\n`, without `\r`;
     - `state.tmux.panes` has 3 panes;
     - the leader box width is 30 % ± 1 cell of the content width;
     - the teammate boxes have equal height ± 1 px;
     - each marker file holds its own `%N`.
  3. **Leader typing (measured, no re-send).** After each layout change, type `printf 'k<n>\n' >> <sandbox>/leader.txt` into the leader once. Record lost lines as a row. A loss is a FAIL unless 26.4 has a ruling that accepts it.
  4. **Minimized.** `SW_MINIMIZE` the window, then `split-window` + `respawn-pane` + `display-message -p '#{pane_width}'` (non-zero). Restore; the panes are laid out and the marker file is written.
  5. **Exit handling.**
     - Teammate A runs `exit 0` → its pane closes (`remain-on-exit failed`).
     - Respawn B with `exit 3` → the pane stays, and the core exit message is in the dump.
  6. **Modal.** With the close-confirm dialog up for the tab (`close_surface` on a pane with a running process), `kill-pane` of another pane in that tab → exit 0; then dismiss the dialog.
  7. **Parallel kill.** Spawn 6 more fake panes (in a maximized window, killing as needed to stay within `no space`). Then 6 parallel `kill-pane` of 6 live panes → all exit 0, no pane left but the leader. 2 more of the same ids → exit 1 `can't find pane`.
  8. **Clipboard.** `load-buffer -w -` with stdin `m4-clip` sets the clipboard (saved and restored with `Save-ClipboardText`/`Restore-ClipboardText`).
  9. **Crash cleanup.** With two fake teammates and one `__idle` running, `Stop-Process` Ghostty. Then:
     - `Assert-NoSurvivors` shows no `tmux.exe`/`bash.exe`/`sleep.exe` from the run after the grace period;
     - a `tmux.exe` call exits 1 `no server running` within 2 s.
- [ ] **Step 4: Verify** pass; `LOCK ZIG build -j6`.
- [ ] **Step 5: Commit** `git commit -m "feat(win32): tmux commands on Ghostty splits — real host, remain-on-exit, load-buffer"`

### Task 13: Pane border labels (M4 polish, SPEC §12.2)

**Review:** light (visual; screenshot in the report).

**Files:** Modify (fill) `src/apprt/win32/tmux/labels.zig`. Create `test/windows/e2e/tmux-labels.ps1`.

**Interfaces:**
- Consumes: `commands.Options` (window `pane-border-status`, pane `pane-border-format`/`pane-border-style`), `format.expand`, the M3 `overlay.zig` click-through label popups, and the hook calls of Task 8 + the `optionsChanged` call sites of Task 12.
- Produces: `labels.State` (one label popup per labelled pane), with the Task 3 stub functions filled.
- **Visibility.** A label shows only while the tab's window option `pane-border-status` is `top`/`bottom` and the pane's expanded `pane-border-format` is not empty. It is hidden for hidden tabs and when the pane is narrower than the label + 2 cells.
- **Text and colour.** `#[…]` runs are stripped from the text. The first `fg=` in the format (else in `pane-border-style`) colours it; tmux colour names and `colourN` map to the terminal palette.
- **Placement.** A pill in the pane's top-right (`top`) or bottom-right (`bottom`) corner, inset by the split gap, in the macOS overlay style (M3 `overlay` metrics). It follows layout, tab switch, tear-off (`tabReparented`), DPI and zoom.
- [ ] **Step 1: Failing tests:** `"win32 tmux labels: text and colour from Claude's border format"` (`#[fg=red,bold] alpha #[default]` → text `alpha`, palette red), `"win32 tmux labels: colour208 and default"`, `"win32 tmux labels: hidden when status off or pane too narrow"`.
- [ ] **Step 2: Run** `LOCK ZIG build test -j6 -Dtest-filter="win32 tmux labels"` → FAIL.
- [ ] **Step 3: Implement.** Scenario `tmux-labels.ps1` (`order=740`):
  - set up two panes with Claude's options;
  - check that `state.tmux` lists the visible labels with rects inside each pane rect;
  - take one guarded window shot;
  - `set-option -w pane-border-status off` → no labels;
  - `select-pane -T beta2` → the label text updates;
  - tear the tab off into a new window → the labels follow.
- [ ] **Step 4: Verify** pass; `LOCK ZIG build -j6`.
- [ ] **Step 5: Commit** `git commit -m "feat(win32): tmux pane border labels"`

### Task 14: M4 end-to-end run (lead) and 14.n fixes

**Files:** none planned; bug notes only. Each 14.n fix touches exactly the files its bug note names (≤ 2 alongside Task 13, disjoint).

- [ ] **Step 1:** Run, in order:
  - `LOCK ZIG build -j6`; `E2E -Milestone M4 -EvidenceDir %TEMP%\m4-evidence` (Debug).
  - ReleaseFast build `--prefix zig-out-rf`; set `$env:GHOSTTY_E2E_EXE` = the RF exe; `E2E -Milestone M4`.
  - `E2E -Milestone all` once, for M1–M3 regressions from the env change.
- [ ] **Step 2:** For every FAIL write a bug note (scenario, build, symptom, log excerpt, evidence path). Unit counts: `-Dtest-filter="tmux shim "`, `"win32 tmux "`, `"SplitTree"`, `test-lib-vt -Dtest-filter="stream: tmux"`, `test-tmux-shim`.
- [ ] **Step 3 (14.n template):** reproduce; a pure-logic bug gets a failing unit test first; fix; the lead re-runs the scenario in the next batch; commit `git commit -m "fix(tmux): <bug summary>"`.

### Task 15: RAM and latency rows, Claude Code agent-team run ×2, docs, M4 acceptance

**Review:** lead.

**Files:** Create `test/windows/claude-team.ps1` (uses `ClaudeRun.psm1`; not an `e2e/` scenario) and `test/windows/measure-tmux.ps1`. Modify:
- `test/windows/lib/ClaudeRun.psm1` (only fixes found at G1);
- `docs/windows/ram-baseline.csv`, `docs/windows/latency-baseline.csv`;
- `docs/windows/feature-checklist.md`: rows for the tmux shim commands, agent teams, the TMUX env, `windows-tmux-shim`, DCS passthrough and border labels;
- `docs/windows/recon/tmux.md` (live-trace diff);
- `src/apprt/win32/tmux/testdata/claude-spawn.jsonl` (only if the live trace differs and the lead accepts the new shape);
- `test/windows/README.md` (M4 scenarios, the real-run driver, owner-safety additions);
- `docs/windows/SPEC.md`:
  - §2 the M4 file list as built;
  - §10/§12.1 pipe name with nonce and the limits (R-M4-1);
  - §12.2 ids (R-M4-2);
  - §12.4 DCS per R-M4-10 and C2;
  - §17 M4 done with the commit;
  - §18 rulings R-M4-1…11;
- `docs/windows/CHANGELOG.md` (M4 section, the `windows-tmux-shim` key, known gaps).

- [ ] **Step 1: RAM rows** (ReleaseFast, median of 3):
  - `one-surface` default;
  - `tmux-team` (`-Sample before@… team@… killed30s@…`, driven by `measure-tmux.ps1` with fake teammates);
  - the `tmux.exe` peak (`display-message`, and `load-buffer` with 512 KiB) and the `__idle` private.

  Gate each row against § RAM budget. Over → DONE_WITH_CONCERNS with numbers; the owner decides.
- [ ] **Step 2: Latency rows.** Key echo (default config, gate per § Latency budget). `measure-tmux.ps1` runs from a maximized window, 50 runs each of `display-message`, `split-window … -- cat` and `respawn-pane -k` (fake teammate). It kills each new pane and waits until `state.tmux.panes` drops back before the next run.
- [ ] **Step 3: Claude Code agent-team run (SPEC §15.6b), ×2 in a row**, through `claude-team.ps1` → `ClaudeRun.psm1`: option B, `haiku`, 10 min cap, `GHOSTTY_TMUX_TRACE` into the sandbox, ReleaseFast Ghostty, Git Bash. Pass requires all of:
  - 3 panes in main-vertical (leader 30 % ± 1 cell);
  - each teammate pane titled with its name (`state` titles);
  - both teammates' messages present in the inbox files under `<active Claude config dir>\teams\<team>\` (read-only check; the config dir is `CLAUDE_CONFIG_DIR` if set, else `%USERPROFILE%\.claude`);
  - after Claude's shutdown and `/exit`, only the leader pane remains, and no `claude.exe`/`tmux.exe` process from the run survives (`Get-ProcessTree` diff);
  - the trace matches the fixture's argv shapes (ids and Claude's dynamic values masked);
  - `Stop-ClaudeRun` removed only the run's `projects/<key>` files, and the residue is listed in the report.

  The owner also gets the run as their own manual check (exit checklist 8).
- [ ] **Step 4:** ARM64 cross-build `LOCK ZIG build -Dtarget=aarch64-windows-gnu -j6` (both exes) → record.
- [ ] **Step 5:** Record the exit checklist (below); commit `git commit -m "docs(windows): M4 acceptance — tmux shim RAM, latency, Claude Code agent-team runs"`.

## M4 exit checklist

1. **Builds and unit tests.** `LOCK ZIG build -j6` and the ReleaseFast build succeed and install `tmux.exe` next to `ghostty.exe`. These pass: `test-tmux-shim`; `-Dtest-filter="tmux shim "`; `"win32 tmux "` 3× in a row; `"SplitTree"`; `test-lib-vt -Dtest-filter="stream: tmux"`; `"win32 ipc"`. `-Demit-lib-vt` and the Linux recipe build.
2. **e2e.** `E2E -Milestone M4` is green on Debug and ReleaseFast: `tmux-cli`, `tmux-env`, `tmux-replay`, `tmux-send-keys`, `tmux-labels`, plus `dcs-tmux` if C2 = arrives. `E2E -Milestone all` has no new failures.
3. **Leader typing.** The `tmux-replay` leader-typing row shows no lost bytes, or the M3 26.4 verdict accepts what it shows. M4 is not accepted before 26.4 has a verdict.
4. **Real run.** The Claude Code agent-team run (Task 15 Step 3) passes twice in a row. Its trace is diffed with the Task 1 fixture, and the recon is updated.
5. **Budgets.** `tmux.exe` ≤ 5 MB peak private and ≤ 100 ms wall p95 (not `load-buffer`). RAM rows are within § RAM budget. Key-echo latency is within +0.5 ms of M3.
6. **Feature checklist.** The M4 rows of `feature-checklist.md` have evidence and status ✅, or are a documented gap (DCS passthrough if C2 = dropped).
7. **SPEC.** §17 M4 is marked done; §18 has rulings R-M4-1…11; §10/§12.1/§12.2/§12.4 are amended; the recon has its re-check sections.
8. **Owner manual checklist** (PASS/FAIL per line):
   - In the owner's daily Ghostty, with `teammateMode: "tmux"` in their own settings, a real team of 2–3 teammates opens splits, titles and labels, and closes cleanly.
   - Typing in the leader while teammates spawn loses no keys.
   - With `windows-tmux-shim = false`, a user MSYS2 tmux works as before.
   - Without Claude: `tmux split-window -h` and `tmux kill-pane` from Git Bash behave like Ghostty splits.
9. **Changelog** with the `windows-tmux-shim` key and the known gaps:
   - external mode (`TMUX` unset, `-L`) is M5;
   - no `new-session`/`attach`;
   - `select-layout` other than main-vertical/tiled is a no-op;
   - `capture-pane` covers the visible screen only;
   - DCS passthrough if dropped by ConPTY;
   - images stay disabled under `TMUX` (XTVERSION is not spoofed, SPEC §12.4);
   - a config reload drops a shim pane's `wait-after-command` (R-M4-5);
   - a split answered after its client timed out leaves an `__idle` pane;
   - the `send-keys` gate (R-M4-6).

## Self-review

- **Spec coverage:**

  | Requirement | Tasks |
  |---|---|
  | §12.1 shim steps | 6 (connect loop with backoff instead of a single ≤ 1000 ms wait: pre-flight 6) |
  | §12.1 server | 8 (M2 `ipc/Server.zig` reused, R-M4-1) |
  | §12.1/§18.5 wire | 6 |
  | §12.2 ids, rows 1–15, error texts, split ratio/`-d`, respawn via `SplitTree.replace`, kill, main-vertical + `resize-pane -x 30%`, tiled, others no-op, `select-pane -T`, options, `remain-on-exit failed`, format variables, `show-environment`, `load-buffer -w`, placeholder `cat` | 3, 4, 5, 7, 10, 12 |
  | §12.2 labels | 13 |
  | §12.3 R1/R2 | 8, 10 |
  | §12.4 DCS | 2, 1 Step 3b, 9 (R-M4-10) |
  | §12.4 XTVERSION | gap list |
  | §12.4 external mode | M5 |
  | §12.5 | 3, 4, 7, 12 |
  | §10 | 8 (+ opt-out key R-M4-11) |
  | §3 | 6 |
  | §14 | 6, 15 |
  | §15.6 (a) | 12 |
  | §15.6 (b) | 15 (driver from Task 1) |
  | §16 R11 | 1, R-M4-9, 15 |
  | Ledger (a) | R-M4-11, 8 |
  | Ledger (b) | R-M4-10, 1, 2, 9 |
  | Ledger (c) + option B | Global Constraints, 1, G1, 15 |
  | Lead: `send-keys`/`capture-pane` | 11 |
  | Lead: early live capture | 1 |
  | Lead: first-byte loss | R-M4-6, 11, 12 step 3 |
  | Lead: guarded captures | Global Constraints, 13 |
- **Waves against `Files:`:**

  | Wave | Task | Files |
  |---|---|---|
  | W1 | 1 | `ClaudeRun.psm1`, `tmux-capture/*`, testdata, recon |
  | W1 | 2 | `conpty-probe/*` |
  | W1 | 3 | `cli.zig`, shells, stubs, `win32.zig` |
  | W2 | 4 | `format.zig`, `sh_command.zig` |
  | W2 | 5 | `split_tree.zig`, `layout.zig` |
  | W2 | 6 | `protocol.zig`, `src/tmux_shim/{main,run,pipe,win}.zig`, build files, `tmux-cli.ps1` |
  | W3 | 7 | `commands.zig`, `FakeHost.zig` |
  | W3 | 8 | `ipc/Server.zig`, `tmux/{Server,env}.zig`, `App.zig`, `Surface.zig`, `hooks.zig`, `messages.zig`, `Config.zig`, `e2e.ps1`, `_tmux.ps1`, `tmux-env.ps1` |
  | W3 | 9 | `stream.zig` (tests), `dcs-tmux.ps1` |
  | W4 | 10 | `spawn.zig`, `Surface.zig`, `Tab.zig`, `windows_shell.zig` |
  | W4 | 11 | `keys.zig`, `pane_io.zig`, `tmux-send-keys.ps1` |
  | W5 | 12 | `Registry.zig`, `surface_actions.zig`, `tmux-env.ps1`, `tmux-replay.ps1` |
  | W6 | 13 | `labels.zig`, `tmux-labels.ps1` |

  No file appears in two tasks of one wave.
- **Type names defined once:**

  | Task | Names |
  |---|---|
  | 3 | `cli.{Global,Command,CommandId,Diag,Target,Size}`; stub signatures of `Registry`, `pane_io`, `labels` |
  | 4 | `format.expand`, `sh_command.Parsed` |
  | 5 | `layout.*` |
  | 6 | `run.{Env,Outcome}`, `protocol.max_request_tmux/max_stdin_tmux/tmuxPipeName/tmuxEnvValue/pidFromTmuxPipe` |
  | 7 | `commands.{Context,Output,Spawn,SplitRequest,Direction,Layout,ResizeRequest,CaptureRequest,Vars,Options,main_vertical_share}` + Host contract |
  | 8 | `tmux_Server.State`, `env.Options` |
  | 10 | `spawn.{Plan,Probe}`, `Tab.{SplitOptions,leafRects,last_content}` |
  | 11 | `pane_io.gate_*`, `keys.encode` |
  | 12 | `Registry.{Host,exitAction}` |

  Task 7 never calls `keys.encode`: the Host takes raw keys, and Task 12 encodes them.
- **Proportion:** the code blocks are signatures and test names only.

### Open questions → rulings

1. *A separate tmux server thread or a second M2 server?* → the second M2 server, with per-pipe fields (R-M4-1).
2. *A registry table or the id on the surface?* → the id on the surface (R-M4-2).
3. *Lenient or strict flags?* → full templates; loud failure only for unimplemented semantics (R-M4-4).
4. *`send-keys` after a split losing bytes?* → a product-side gate (R-M4-6), tuned by 26.4.
5. *Opt-out knob?* → yes, `windows-tmux-shim` (ledger ruling (a), R-M4-11).
6. *DCS lost through ConPTY?* → a documented gap if measured so (ledger ruling (b), R-M4-10).
7. *Real Claude runs?* → allowed, option B, haiku, 10 min cap (ledger ruling (c)).

## Pre-flight dispositions

Review: `docs/windows/plans/M4-preflight-review.md` (3 CRITICAL, 10 IMPORTANT, 22 MINOR). Result: 3/3 CRITICAL applied (3 with the lead's option B), 10/10 IMPORTANT applied, 19/22 MINOR applied, 1 partial, 2 recorded as known gaps instead of code.

| # | Sev. | Disposition |
|---|---|---|
| 1 | CRITICAL | Applied. Task 2 oracle = the inner notification arrives (+ hook line recorded). Task 9 starts with the `Stream` test and stays tests-only on PASS; on FAIL it stops for a lead ruling on `Parser.zig`. `dcs.zig`/`stream_handler.zig` are removed from the touch points; R-M4-10 is reworded. |
| 2 | CRITICAL | Applied (ledger ruling (a)). R-M4-11 = `windows-tmux-shim`; `Config.zig` touch point; Task 8 env `enabled` + 2 tests + a second Ghostty in `tmux-env`; exit checklist 8 and the changelog. |
| 3 | CRITICAL | Applied with the lead's option B (no API key known). A "Real Claude Code run" constraint: real `USERPROFILE`/`HOME` for that one Ghostty only, CLI flags instead of `settings.json`, `CLAUDECODE`/`CLAUDE_*` removed, trust prompt answered by the driver unless a CLI option exists, cleanup only of the run's `projects/<key>` files, credentials never copied, `haiku`, a 10 min cap. The shared driver `ClaudeRun.psm1` is built in Task 1 (Step 0 checks the CLI spelling). One invocation spelling. The Task 15 inbox check uses the active config dir. |
| 4 | IMPORTANT | Applied. Routing on wparam before the `server == null` guard; the start position after `forwarded` and before `Window.create`; test `standalone process answers tmux`. |
| 5 | IMPORTANT | Applied. `Tab.last_content` + `leafRects` (Task 10); the Host never reads `split_layout` directly (Task 12); tests `leaf rects while minimized`, `geometry while minimized`; the minimized step in `tmux-replay`. |
| 6 | IMPORTANT | Applied. The busy-retry loop with backoff until the deadline; `NoServer` only on not-found; the 250 ms deadline margin; `close_wait_ms` field (tmux 200); unit test `busy retries until the deadline`; e2e 6 parallel `kill-pane`, all alive → all 0. |
| 7 | IMPORTANT | Applied. Pipe `ghostty-tmux-<pid>-<nonce>`, `pidFromTmuxPipe`, tests; SPEC §10/§12.1 change in Task 15. |
| 8 | IMPORTANT | Applied. An id map in both the Task 7 replay and the Task 12 e2e; FakeHost uses up an id per respawn. |
| 9 | IMPORTANT | Applied. `optionsChanged` after `set-option`, `select-pane -T`, every tree change and respawn (Host contract + Task 12); `tabReparented → labels` in the hooks and the stub; the Task 13 scenario covers `status off`, a `-T` update and tear-off. |
| 10 | IMPORTANT | Applied. `Unsupported` is in both error sets with its test; `Host.respawn` re-applies the title; main-vertical fixed at `main_vertical_share` 0.3. |
| 11 | IMPORTANT | Applied. `tmux-send-keys` is run by the lead in the W5 batch; `tmux-env` reads the second pane's `TMUX_PANE` from `state.tmux.panes[].env_tmux_pane` without typing. |
| 12 | IMPORTANT | Applied. A leader-typing measurement step in `tmux-replay`; exit checklist 3 makes acceptance depend on the 26.4 verdict; R-M4-6 says "any cause". |
| 13 | IMPORTANT | Applied. Task 1 Step 3b records real Claude's `ESC P tmux;` and whether its OSC reaches core; C2 reads Tasks 1 and 2. |
| 14 | MINOR | Applied: resolution against tmux's full command table; test rows `kill`, `show`, `new-session`. |
| 15 | MINOR | Applied: `WriteConsoleW` on console handles. |
| 16 | MINOR | Applied: a denylist for the import check, with the full list in the report. |
| 17 | MINOR | Applied: `E2E -Only tmux-cli`. |
| 18 | MINOR | Applied: stdin cap 512 KiB (`max_stdin_tmux`); `load-buffer` gets its own RAM row (≤ 8 MB, recorded). |
| 19 | MINOR | Applied: non-UTF-8 env entries dropped; invalid stdin → exit 1. |
| 20 | MINOR | Applied: `FILE_APPEND_DATA` + one `WriteFile` per line, parallel-lines check in `tmux-cli`; stdin is never traced, and the fixture stores `"<n> bytes"`. |
| 21 | MINOR | Applied: `exe_dir` is resolved before and independently of the claim; `extra` may override PATH (documented). |
| 22 | MINOR | Not fixed: recorded as a known gap (R-M4-5, changelog). The win32 apprt re-applies no per-surface override on reload today (`Overrides` are applied only in `Surface.create`), and core closes on exit whenever `wait_after_command` is false, so a fix would need core changes outside M4's touch points. |
| 23 | MINOR | Not fixed: recorded as a known gap (changelog). It is rare: it needs a UI stall past the 9.75 s client deadline. A 30 s reaper adds state and timers for a case no test can produce reliably. |
| 24 | MINOR | Applied: `__idle` waits on its own process handle and ignores Ctrl+C. |
| 25 | MINOR | Applied: Task 10 quoting cases (b)–(d), with the MSYS env fallback decided there. |
| 26 | MINOR | Applied: crash-cleanup step in `tmux-replay`. |
| 27 | MINOR | Applied: modal close-confirm step in `tmux-replay`. |
| 28 | MINOR | Applied: median of 3 and + 1 MB. |
| 29 | MINOR | Applied: `measure-tmux` kills between runs and starts from a maximized window. |
| 30 | MINOR | Applied: `tmux-env.ps1` 8 → 12 in the chains. |
| 31 | MINOR | Applied: the module boundary in Global Constraints and Task 3. |
| 32 | MINOR | Applied: "tree order" only. |
| 33 | MINOR | Partial. The `capture-pane` history ranges and `-J` were dropped (R-M4-7: visible screen only). The `send-keys` gate stays: the lead's M4 brief requires `send-keys` right after `split-window` to be robust against the Git Bash first-byte loss, and the gate is what makes `tmux-send-keys` deterministic. |
| 34 | MINOR | Applied: the stub signatures moved to Task 3; Task 8 keeps the logic. |
| 35 | MINOR | Applied: the fixture argv includes the global `-S` prefix where Claude sends it; the replay calls `parseGlobal` and passes `rest`. |
