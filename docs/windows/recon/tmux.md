# tmux CLI contract for the Ghostty Windows `tmux.exe` shim

Source of truth: Claude Code 2.1.310 (`C:\Users\user\.local\bin\claude.exe`, Bun-compiled, JS embedded as text).
Everything below was extracted from the embedded source (TmuxBackend class at byte offset ~278720905,
spawn logic at ~278822500..278858800, backend registry at ~267896728, env helpers at ~252932000).
Re-extract with: `grep -a -b -o -F 'class $hi{type="tmux"' claude.exe`, then `dd skip=<off> count=<n>`.
Minified names (`$hi`, `gRr`, `Qde`, `d()`, `l()`) are from this build only.

## 1. Verdict

- **No `process.platform === "win32"` gate exists** in backend detection, spawn, or TmuxBackend. The only
  Windows-specific text is the "no pane backend" hint (`case "windows"`: "requires WSL"), shown only when
  `tmux -V` fails and `TMUX` is unset. Tmux mode works on Windows if a `tmux` binary answers.
- Agent teams gate: env `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` (any truthy) or flag `--agent-teams`, plus
  remote flag `tengu_amber_flint` (default true). Teammates inherit `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`.
- `teammateMode` values: `auto | tmux | iterm2 | in-process`. Module default constant is `"in-process"`
  (`D7n`), so the user must set `teammateMode: "tmux"` (or `auto`) in settings or pass `--teammate-mode`.
- `auto` + `TMUX` set => pane mode (tmux backend). `auto` + no TMUX and no iTerm2 => in-process.
  `tmux` explicit => pane mode always; backend detection failure THROWS (no fallback).
  `auto` and backend detection throws => silent fallback to in-process + notification
  "Couldn't open a teammate pane - running in-process instead".
- Not in pane mode when: non-interactive session (`ye()`), `teammateMode=in-process`, or an agent type
  registered at runtime by a plugin (then error).
- Teammate lifecycle is NOT polled via tmux (no `pane_dead`, `pane_pid`, `capture-pane`, `send-keys` for
  teammates). Coordination is file/mailbox based (`~/.claude/teams/...` inbox). tmux is used only to
  create/titled/colour/layout/respawn/kill panes.

## 2. Backend selection (what makes the shim reachable)

```
ajn():                                  # detectBackend, cached
  mode == "iterm2" -> iTerm backend (needs it2)         [irrelevant]
  insideTmux = !!process.env.TMUX  (snapshotted at module load!)
  if insideTmux           -> TmuxBackend, isNative=true         # NO tmux call made
  elif inITerm2 ...                                              [irrelevant]
  else if (await at("tmux", ["-V"])).code === 0 -> TmuxBackend (external mode)   # stdout ignored
  else throw Error(x())  # "To use agent swarms, you need tmux which requires WSL..."
```

- `isAvailable()` = `tmux -V` exit 0 (stdout never parsed; still print `tmux 3.5a`).
- `isRunningInside()` = `!!TMUX`. `TMUX_PANE` is read separately (`aBr()`), also snapshotted at load.
- `TMUX` env format: `<socket-path>,<server-pid>,<session-idx>`. Claude takes **text before the first comma**
  (`Ze(d, ",")` = `indexOf` + `slice`) as the socket and passes it as **`-S <socket>`** before every
  inside-mode command (`d(args) = at("tmux", ["-S", sock, ...args])`; if sock empty, no `-S`).
  => The shim's `TMUX` value must have a comma-free first field. Recommended:
  `TMUX=\\.\pipe\ghostty-tmux-<ghostty-pid>,<ghostty-pid>,0`. `-S <that path>` must be accepted and used to
  locate the named pipe. Unknown `-S` values: still try to connect (do not error on format).
- `-L <name>` (external mode only): `l(args) = at("tmux", ["-L", "claude-swarm-" + process.pid, ...args])`.

## 3. Constants

| name | value |
|---|---|
| session (external mode) | `claude-swarm` |
| window (external mode) | `swarm-view` |
| external socket | `claude-swarm-<claude pid>` (`-L`) |
| initial pane command (`urt`) | `cat` |
| legacy per-teammate window name | `teammate-<sanitized-name>` (`use_splitpane:false` path only) |
| colours | red->`red`, blue->`blue`, green->`green`, yellow->`yellow`, purple->`magenta`, orange->`colour208`, pink->`colour205`, cyan->`cyan` |

All tmux calls are `execFile`-style argv arrays (no shell). Default timeout 10 min; failure to spawn/ENOENT
yields `{code:1, stdout:"", stderr:""}`. cwd = Claude's original cwd. Output handling: `stdout.trim()`,
then `.split("\n").filter(Boolean)` => **write LF only, never CRLF** (a trailing `\r` would corrupt pane ids
like `%3\r` used later in `-t`).

## 4. Command table: INSIDE mode (primary target: `TMUX` + `TMUX_PANE` set)

`[S]` = prefixed with `-S <sock>` (shown once). Exit 0 required unless noted; any non-zero => failure path.
Stdout is only parsed where marked. "pane id" = `%N` (monotonic, never reused), "window id" = `@N`.

| # | tmux command (args exactly as sent) | stdout / exit | Ghostty-side semantics |
|---|---|---|---|
| 1 | `[S] display-message -p "#{pane_id}"` (only if `TMUX_PANE` unset) | `%N\n`; exit 0 | id of caller's pane. Normally NOT called: Claude uses env `TMUX_PANE` directly. |
| 2 | `[S] display-message -t %L -p "#{window_id}"` (note `-t` before `-p`; cached per backend) | `@N\n` | window (tab) containing leader pane `%L`. `-t` absent => use caller `TMUX_PANE`. |
| 3 | `[S] list-panes -t @W -F "#{pane_id}"` | one `%N` per line, **index/creation order, leader first** | panes of that tab. Code assumes `[0]` is the leader and `slice(1)` are teammates. Non-zero => "Could not determine pane count" error. |
| 4 | `[S] split-window -d -t %L -h -l 70% -P -F "#{pane_id}" -- cat` (first teammate: window had exactly 1 pane) | `%N\n` of NEW pane; exit 0 | Horizontal split of leader pane (`-h` = side by side), NEW pane gets 70% width (leader keeps 30%). `-d` = do not move focus. `-P -F` print new pane id. `-- cat` = initial command (see section 7). |
| 5 | `[S] split-window -d -t %T <-v|-h> -P -F "#{pane_id}" -- cat` (2nd+ teammate). `T = teammates[floor((g-1)/2)]` (g = existing teammates, falls back to last); `-v` if g odd else `-h` | `%N\n` | Split target teammate pane, 50/50, no focus change. On failure stderr is inspected: contains `no space` or `too small` => friendly "no room for another tmux split". Emit tmux-exact text: `no space for new pane` / `create pane failed: pane too small`, exit 1. |
| 6 | `[S] set-option -p -t %N window-style "bg=default,fg=<colour>"` | no output | per-pane style (teammate text fg colour). Cosmetic; accept, store, may ignore. |
| 7 | `[S] set-option -p -t %N pane-border-style "fg=<colour>"` | -- | cosmetic; accept + store. |
| 8 | `[S] set-option -p -t %N pane-active-border-style "fg=<colour>"` | -- | cosmetic; accept + store. |
| 9 | `[S] select-pane -t %N -T "<name>"` | -- | set pane title (name = sanitized teammate name `[A-Za-z0-9_-]`). Must NOT change focus (real tmux does not when `-T` given). Map to Ghostty surface title override. |
| 10 | `[S] set-option -p -t %N pane-border-format "#[fg=<colour>,bold] #{pane_title} #[default]"` | -- | Accept + store. Ideal rendering: coloured title label on the pane. Not required for correctness. |
| 11 | `[S] list-panes -t @W -F "#{pane_id}"` then, if >2 panes: `[S] select-layout -t @W main-vertical` then `[S] resize-pane -t %<first listed pane> -x 30%` | -- (results unchecked, errors swallowed) | `main-vertical`: first pane (leader) is the big left column, all others stacked vertically on the right. `resize-pane -x 30%`: leader width = 30% of window width. Skipped when <=2 panes (case 4 already set 30/70). |
| 12 | (first teammate only) `[S] set-option -w -t @W pane-border-status top` | -- | window option; accept + store; optional header strip per pane. |
| 13 | `[S] set-option -p -t %N remain-on-exit failed` (result ignored) | -- | pane stays open (showing exit status) only if its command exited NON-zero; exit 0 closes pane. Must be recorded BEFORE case 14 and survive respawn. |
| 14 | `[S] respawn-pane -k -t %N -- "<shell command string>"` | exit 0 required, else Claude throws `Failed to send command to pane %N: <stderr>` | `-k` kill whatever runs in pane, start command in SAME pane id. ONE argv element = shell string (see section 6). Pane id must stay valid. |
| 15 | `[S] kill-pane -t %N` | exit 0 = true; non-zero tolerated | close pane, re-flow siblings; closing last pane of a window closes the window. Called on spawn failure rollback, teammate shutdown approval, abort, and `cleanupSessionTeams` at leader exit (`Promise.allSettled`). Pane already gone => exit 1 with `can't find pane: %N` is fine. |

Notes:
- Order per spawn (serialized by an in-process lock): 2 -> 3 -> (4|5) -> 6,7,8 -> 9,10 -> [3 then 11] -> 12(first only) -> 13 -> 14.
  Pane `%N` returned by 4/5 is used for all later calls.
- `-S` and `-t` targets seen: `%N` (pane), `@N` (window). No `session:window.pane`, no `-t {last}` etc.
- Args are real argv: `-F` strings contain `#`, `{}`, spaces; border-format contains spaces and `#[...]`.
  Parse argv with standard Windows rules (`CommandLineToArgvW` / Zig `std.process.args`).

## 5. Command table: EXTERNAL mode (`TMUX` unset, `tmux -V` ok) and legacy path

External mode only matters when Claude runs outside a Ghostty-spawned shell (no TMUX). All use
`-L claude-swarm-<claude pid>` (call it `[L]`). Needs the shim to find/launch a running Ghostty
(well-known pipe name) and treat the `-L` name as an isolated "server" namespace mapped to one Ghostty window.

| tmux command | stdout / exit | semantics |
|---|---|---|
| `tmux -V` | any; exit 0 | availability probe only |
| `[L] has-session -t claude-swarm` | exit 0 exists / 1 not (stderr `can't find session: claude-swarm`) | per-namespace session registry |
| `[L] new-session -d -s claude-swarm -n swarm-view -P -F "#{pane_id}" -- cat` (cwd=Claude cwd; no `-x/-y` in this build) | `%N\n` | create detached session with window `swarm-view`, pane runs `cat` |
| `[L] list-windows -t claude-swarm -F "#{window_name}"` | names per line | does `swarm-view` exist |
| `[L] list-panes -t claude-swarm:swarm-view -F "#{pane_id}"` | `%N` lines | target syntax `session:window-name` |
| `[L] new-window -t claude-swarm -n swarm-view -P -F "#{pane_id}" -- cat` | `%N\n` | new window in session |
| `[L] list-panes -t claude-swarm:swarm-view -F "#{pane_id}"` / `[L] split-window -d -t %P <-v|-h> -P -F "#{pane_id}" -- cat` | pane ids | grid growth: split pane `floor((n-1)/2)` of existing; `-v` if n odd else `-h` |
| first pane: reuse pane returned by new-session; `[L] set-option -w -t claude-swarm:swarm-view pane-border-status top` | -- | |
| `[L] select-layout -t claude-swarm:swarm-view tiled` (when >1 pane) | -- | equal grid (rows x cols), no leader column |
| `[L] set-option -p -t %N remain-on-exit failed`; `[L] respawn-pane -k -t %N -- "<cmd>"`; `[L] kill-pane -t %N` | as inside | `sendCommandToPane(..., useExternal=true)` uses `-L` |

Legacy path (`use_splitpane:false`, rarely used; NO `-L`/`-S`, extra `env` = filtered process env, `extendEnv:false`):
`has-session -t claude-swarm`; `new-session -d -s claude-swarm`; `new-window -t claude-swarm -n teammate-<name> -P -F "#{pane_id}" -- cat`;
`set-option -p -t %N remain-on-exit failed`; `respawn-pane -k -t %N -- <cmd>`; `kill-pane -t %N`.
Default spawn is the split-pane path (`use_splitpane !== false`).

## 6. Pane command: what runs, shell, quoting

Built in `spawnTeammate` (`ge`), identical shape for all paths:

```
cd <Q(cwd)> && env <ENVS> <Q(exe...)> <IDENT> [<FLAGS>]
Q(x)  = POSIX single-quote quoting for ALL platforms: token unchanged if it matches ^[A-Za-z0-9_./:=@+,-]+$,
        '' for empty, else '...' with embedded ' as '"'"'      (backslash is NOT in the safe set)
ENVS  = CLAUDECODE=1 CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 [CLAUDE_CODE_HOST_GATEWAY_LINEAGE=1]
        + forwarded provider/proxy vars: CLAUDE_CODE_USE_BEDROCK|VERTEX|FOUNDRY|..., ANTHROPIC_BASE_URL,
          AWS_*, GOOGLE_CLOUD_PROJECT, HTTPS_PROXY/HTTP_PROXY/NO_PROXY (+lowercase), CLAUDE_CONFIG_DIR,
          CLAUDE_CODE_REMOTE, DISABLE_TELEMETRY, ... (each only if set: NAME=<Q(value)>)
        + CLAUDE_SECURESTORAGE_CONFIG_DIR, CLAUDE_CODE_AUTO_MODE_TIER (if set)
        + CLAUDE_CODE_ATTRIBUTION_PROJECT=<Q(value or "")>     # always present
exe   = [process.env.CLAUDE_CODE_TEAMMATE_COMMAND] or [process.execPath] (+ optional process-wrapper prefix)
IDENT = --agent-id <name>@<team> --agent-name <name> --team-name <team> --agent-color <colour>
        --parent-session-id <uuid> [--plan-mode-required] [--agent-type <t>]
FLAGS = [--dangerously-skip-permissions | --permission-mode acceptEdits|auto] [--proactivity ..]
        [--disallowed-tools ..] [--tools ..] [--model ..] [--effort ..] [--settings ..] [--plugin-dir ..]
        [--mcp-config ..] [--strict-mcp-config] [--chrome|--no-chrome] [--restricted] ...
```

Windows example (what the shim receives as the single argv after `--`):

```
cd 'C:\D\den4ik\Ghostty' && env CLAUDECODE=1 CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 CLAUDE_CODE_ATTRIBUTION_PROJECT='' 'C:\Users\user\.local\bin\claude.exe' --agent-id researcher@my-team --agent-name researcher --team-name my-team --agent-color red --parent-session-id 3f2c... --model claude-sonnet-5-5
```

Facts for the shim:
- It is a **POSIX sh script, one line** (a control-char guard `\p{Cc}` rejects any newline/tab/etc.; Claude
  throws before calling tmux). On tmux/Linux it is run by `default-shell -c`. On Windows cmd.exe / PowerShell
  cannot run `cd X && env A=B prog` (no `env`), and Ghostty's default Windows shell is `cmd.exe`
  (`src/termio/Exec.zig:767`) -> **the shim must not hand the string to the pane's default shell.**
- Recommended execution: (a) primary = native mini-interpreter for exactly this grammar:
  `cd <word> && env (NAME=word)* <word>+`, POSIX single-quote/`'"'"'` tokenizer, no expansions; spawn the
  program directly with ConPTY cwd + env overrides. Deterministic, no Git Bash startup, no MSYS path/env
  mangling. (b) fallback for anything that does not parse: `bash.exe -c <string>` from Git for Windows
  (locate via `CLAUDE_CODE_GIT_BASH_PATH`, then `git --exec-path`/`where git` -> `..\..\bin\bash.exe`,
  then `%ProgramFiles%\Git\bin\bash.exe`); Claude Code itself requires Git Bash on Windows, so it exists.
  (c) last resort `cmd.exe /d /s /c`.
- `cd 'C:\...'` with backslashes is fine in Git Bash; `'C:\Users\...\claude.exe'` runs natively.
- Spawn-time env of the new pane (tmux semantics): server/global env (here: Ghostty process env + PATH with
  shim dir prepended) + `TMUX=<pipe>,<pid>,0` + `TMUX_PANE=%N` + `TERM_PROGRAM=ghostty`. Provider vars
  listed in ENVS are re-injected explicitly; but `ANTHROPIC_API_KEY`, OAuth tokens, user PATH edits made in
  the leader's shell are NOT forwarded. Decision needed: inherit Ghostty env only (faithful) vs. overlay the
  calling `tmux.exe` client's env on respawn (more forgiving on Windows; recommended as superset,
  explicit `-e` flags unused by Claude).
- `remain-on-exit failed` + exit status: teammate exits 0 on normal shutdown -> pane auto-closes;
  non-zero -> pane stays for debugging.
- `CLAUDE_CODE_TEAMMATE_COMMAND` (env) overrides the executable (also forms a wrapper prefix); useful for
  testing the shim end-to-end with a fake teammate.

## 7. The placeholder `cat`

Every pane is created with `-- cat` and replaced milliseconds later by `respawn-pane -k`. On Windows `cat`
is not guaranteed on PATH. The shim must special-case a command string exactly `cat` (and `sleep`-like idle
commands): do NOT launch a shell; start an idle placeholder (spawn the shim itself in `--idle` mode that
blocks on stdin, or create the surface with a deferred/no child). Best design for Ghostty: keep a stable
pane-id -> surface indirection in the shim server so `respawn-pane` can either (1) restart the pty child in the
same surface or (2) create a new surface in the same split slot and re-point the pane id. Pane id and split
geometry must be unchanged after respawn.

## 8. Format variables

| variable | where used | value |
|---|---|---|
| `#{pane_id}` | `-F` of split-window/new-window/new-session/list-panes; `display-message` | `%<n>` monotonic, unique per server; no trailing whitespace |
| `#{window_id}` | `display-message`, `-F` of nothing else | `@<n>` |
| `#{window_name}` | `list-windows -F` (external) | `swarm-view` etc. |
| `#{pane_title}` | only INSIDE the `pane-border-format` value Claude sets (never queried) | pane title |
| `#{session_name}:#{window_id}.#{pane_id}` | startup probe (see 9) | must match `^[A-Za-z0-9_.-]{1,64}:@?\d{1,6}\.%?\d{1,6}$`, e.g. `0:@1.%3` |
| 8-field probe | startup probe (see 9) | see below |

`display-message -p`: print only the expanded format + `\n`. `-t` accepts pane `%N`/window `@N`.
Format engine needed: `#{var}` substitution only (no conditionals, no `#(...)`, no `#[...]` expansion needed).

## 9. Startup-time tmux calls when `TMUX` is set (not teammate related, but run in every Claude session)

All through bare `tmux` found via PATH (they do NOT use `-S`), short timeouts => shim must start fast
(<100 ms) and never hang.

| call | timeout | expected | failure effect |
|---|---|---|---|
| `tmux display-message -p [-t $TMUX_PANE] "#{client_termtype}\t#{allow-passthrough}\t#{focus-events}\t#{pane_top}\t#{pane_left}\t#{status}\t#{status-position}\t#{window_bigger}"` (TAB-joined; TMUX_PANE branch only if set) | 1000 ms | exactly 8 TAB-separated fields; `pane_top`,`pane_left` digits; trailing `\n` | wrong shape or non-zero => inline-image capability treated as unknown (images off). Safe answer: `xterm-ghostty\toff\t0\t0\t0\ton\tbottom\t0`. |
| `tmux show-environment -g` | 250 ms | exit 0; stdout lines `NAME=value`; Claude only checks for `CLAUDE_CODE_CHILD_SESSION=` | non-zero => "unknown"; empty + exit 0 => "absent". Return empty, exit 0. |
| `tmux display-message -p -t $TMUX_PANE "#{session_name}:#{window_id}.#{pane_id}"` | 1000 ms | regex above | no value => feature skipped (used for session bookkeeping). |
| `tmux display-message -p "#{client_control_mode}"` (ONLY if `TERM_PROGRAM` is unset; Ghostty sets it, so skipped) | 2000 ms | `0`/`1` | -- |
| clipboard copy: `tmux [-S sock] load-buffer -w -` (stdin = text) then retry `load-buffer -` | 2000 ms | exit 0 = handled | non-zero => Claude falls back to its own OSC 52 emission. Recommended: implement: store buffer, and with `-w` set the Windows clipboard (via Ghostty or Win32). |
| `tmux -V` (external mode only) | default | exit 0 | -- |

`show-options -g prefix`, `new-session -A`, `attach-session`, `switch-client`, `has-session`, `send-keys`,
`capture-pane`, `kill-session`: appear only in the `claude --worktree --tmux` launcher and dev scripts, NOT in
teammate flow. `send-keys` / `capture-pane` are NOT used by the TmuxBackend. Optional later.

## 10. Terminal probes (DECRPM 1016 / XTVERSION) vs TMUX

- Claude sends a startup probe batch (DECRPM 2026, kitty graphics query, DECRPM 1016 mouse-pixels, XTVERSION).
  1016 only decides `mousePixels`; unrelated to teammates.
- If `TMUX` is set, `versionName = XTVERSION name`; images require `versionName.startsWith("tmux ")`.
  Ghostty answers `ghostty <ver>` (src/termio/stream_handler.zig reportXtversion) => Claude reports
  "TMUX is set, but the terminal did not answer as tmux" and **disables inline kitty/iTerm image
  rendering**. Cosmetic loss only; do not spoof XTVERSION.
- `Tan()` (multiplexer detect) returns `"tmux"` whenever `TMUX` is set. Then `P0()` wraps terminal
  escapes in a DCS passthrough: `ESC P tmux; <seq with ESC doubled> ESC \`. Used for: OSC 52 clipboard
  (sent BOTH plain and wrapped, so plain works), and terminal notifications (OSC 9 / OSC 99 kitty / OSC 777),
  window-title/progress style OSCs sent via `JGe()/cL()` (ONLY wrapped). Ghostty ignores
  `DCS tmux;` (src/terminal/dcs.zig only handles `DCS 1000 p`) => **those notifications are silently lost**
  while `TMUX` is set. Recommendation: implement `ESC P tmux; ... ESC \` unwrap in Ghostty's DCS handler
  (re-feed the unescaped payload to the parser) - small, matches tmux `allow-passthrough on`.
- `P()` returns `[]` args when `TMUX` is set: `tmux load-buffer` is invoked with NO `-S` for clipboard.

## 11. Ghostty reuse inventory (repo C:\D\den4ik\Ghostty)

State of repo: no Windows apprt yet (`src/apprt/`: `gtk`, `none`, `embedded`, `browser`; `Runtime.default` is
`none` on Windows). `src/pty.zig` already has a `WindowsPty` (ConPTY via `CreatePseudoConsole`, overlapped
named pipes; `src/os/windows.zig` has the Win32 bindings). `termio/Exec.zig` already builds the child env
(`TERM`, `TERM_PROGRAM=ghostty`, `GHOSTTY_BIN_DIR`, PATH) and has Windows branches; default Windows command
is `cmd.exe`.

| piece | file | reusable for the pipe IPC? |
|---|---|---|
| IPC action schema | `src/apprt/ipc.zig` | `Target {class, detect}` + `Action {new_window, new_tab, toggle_quick_terminal}`; C-ABI mirrored in `include/ghostty.h`. Too small: no split/pane/respawn/kill/title/list. Extend with new keys (append to end of enum, update header) or use a separate pipe protocol. |
| CLI entry | `src/cli/new_window.zig`, `new_tab.zig`, `toggle_quick_terminal.zig`, `src/cli/ghostty.zig` (`+action` dispatch, `performIpc` call) | Good template for arg parsing (`src/cli/args.zig`, `parseManuallyHook`), cwd capture, `--working-directory`. Each calls `apprt.App.performIpc(alloc, target, action, value)`; `none.zig`/`embedded.zig` return `false` ("not supported"). A Windows apprt must implement `performIpc` over a named pipe. |
| GTK transport | `src/apprt/gtk/App.zig:76` `performIpc`, `src/apprt/gtk/ipc/{DBus,new_window,new_tab,toggle_quick_terminal}.zig` | D-Bus GApplication `org.gtk.Actions.Activate`. Fire-and-forget; no return values (the shim needs replies: pane ids, lists, exit codes). Only the pattern (client resolves target instance, serializes args) is reusable, not the code. |
| tmux control-mode CLIENT | `src/terminal/tmux/{control,layout,output,viewer}.zig`, DCS `1000p` in `src/terminal/dcs.zig` | Ghostty consuming a REAL tmux over `-CC`. No server side. Reusable pieces: `layout.zig` (`Layout.parse`, `Checksum.calculate` CRC16 -> useful to emit `#{window_layout}`), `output.zig` `Variable` set (names of format variables incl. `pane_id` `%N`, `window_id` `@N`, `session_id` `$N`, `window_layout`) as a reference for formatting. Not usable as transport. |
| ConPTY/process | `src/pty.zig` (`WindowsPty`), `src/os/windows.zig`, `src/os/pipe.zig` (Windows CreatePipe) | Needed for pane spawn/respawn; named-pipe server must use `CreateNamedPipeW` (already declared in windows.zig exp.kernel32). |
| env/PATH | `src/termio/Exec.zig:~690-720` | Currently APPENDS exe dir to PATH (last priority). Shim dir must be PREPENDED (and `TMUX`, `TMUX_PANE` set per surface). |

Proposed IPC (for implementer): named pipe `\\.\pipe\ghostty-tmux-<ghostty-pid>` (matches `TMUX` first
field), message-mode, request = JSON/length-prefixed `{argv:[...], env_pane, cwd, client_env?}`, response =
`{code, stdout, stderr}`; server executes the tmux command against a registry
`{pane_id <-> surface, window_id <-> tab, session}` on the Ghostty main thread. The shim stays a thin
argv-forwarder (fast startup matters, see section 9 timeouts); all semantics live in Ghostty.

## 12. Risks / open items / blockers

1. **No blocker from Claude Code**: tmux mode is not disabled on win32. Requirement from the user side:
   `teammateMode: "tmux"` (or `auto` with `TMUX` set) and `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`
   (or `--agent-teams`).
2. **Pane command is POSIX sh** (see 6). Biggest Windows risk. Implement native parser + Git Bash fallback.
3. `TMUX`/`TMUX_PANE` are snapshotted at Claude start: they must already be in the env of every Ghostty
   surface shell, including after re-exec / new tabs; `TMUX_PANE` must equal the surface's real pane id
   (`%N` valid in the registry), otherwise cases 2-5 fail (`can't find pane`).
4. Child resolution of `tmux`: Bun spawn resolves `tmux` -> `tmux.exe` via PATH; ship a real `.exe` (not
   `.cmd`/`.bat`), directory prepended to PATH in every surface (the leader's `claude.exe` inherits it).
5. LF-only stdout; no BOM, no banners; deterministic `list-panes` order; monotonic never-reused ids.
6. `respawn-pane` identity: same pane id and geometry after respawn; `-k` must kill the placeholder.
7. Layout: `main-vertical` + `resize-pane -x 30%` needs Ghostty split-tree restructure (leader column left,
   N teammates stacked right). If not feasible, degrade: keep alternating -v/-h splits, treat select-layout/
   resize-pane as accepted no-ops (exit 0). Claude ignores their results.
8. `split-window -l 70%` percentage semantics (size of NEW pane); `no space for new pane` when min pane size
   violated (Claude prints a tailored message).
9. Env propagation difference (section 6): decide client-env overlay vs faithful server env.
10. DCS `tmux;` passthrough dropped by Ghostty (notifications lost with TMUX set); XTVERSION says ghostty =>
    inline images disabled. Both are Ghostty-side improvements, not shim work.
11. External mode (TMUX unset) requires the shim to discover a running Ghostty and map `-L` namespaces; lower
    priority since sessions inside Ghostty always have TMUX.
12. Cleanup: at leader exit Claude issues `kill-pane` for every recorded teammate pane in parallel while its
    own pane/window may be closing; server must tolerate concurrent requests and missing panes.
13. Version drift: strings above are from 2.1.310; format tuples and the cat/respawn protocol have been stable
    but should be re-verified on updates (re-run the extraction recipe at top).
