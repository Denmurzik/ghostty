# M3 final whole-branch review

Range `4df054888..HEAD` (HEAD `4a402e89a`, branch `windows`). Excluded: the upstream merge `ee9f196c4` (upstream side),
M4 files (`src/tmux_shim/**`, `src/apprt/win32/tmux/**`, `GhosttyTmuxShim.zig`, the tmux ipc/protocol parts,
`split_tree.zig` `replace`, M4 docs, `test/windows/tmux*`), and the Windows 11 dialogs, which have not landed yet.
Items parked in the ledger are not raised again unless they turned out worse than recorded.

## Verification run by the reviewer (test-lock, `-j6`, HEAD `4a402e89a`)

| Command | Result |
|---|---|
| `zig build test -Dtest-filter="win32 "` (includes the action classification test) | exit 0 |
| `zig build test -Dapp-runtime=none -Dtest-filter="renderer: " "d3d11 " "shadertoy" "windows directwrite"` | exit 0 |
| `zig build -Dtarget=x86_64-linux-gnu -Dapp-runtime=none` (Linux recipe) | exit 0 |
| `zig build -Demit-lib-vt` | exit 0 |

These cover exit-checklist item 1, which Task 27 had left unrun, except the "3× in a row" requirement (the `win32 `
filter ran once) and the `pkg/win32` tests.

## Cross-task integration: verified sound

- **Message ids:** `WM_APP+1..+15` are unique, and the M3 ids are +12..+15. No `WM_USER` is used. The only registered
  messages are TaskbarCreated and TaskbarButtonCreated.
- **Timer ids:** unique for each window class. The msg window uses 1–4. The top level uses 1, 2, 0x2600/0x2601 and
  0x2700/0x2701. The tab uses 1. The surface uses 1–3. The overlay popup uses 1–4. The inspector and the resize overlay
  use 1 each. Every `WM_TIMER` hook returns null for ids it does not own.
- **Heap payloads:** palette commands, pending dialogs and drops are drained on window destroy, and on the msg window at
  exit. The composition hand-off carries only a generation number. Per-surface popups are destroyed before the
  window's `.destroying`. `tabReparented` moves every popup of the tab. The tab animation copies titles and holds no tab
  pointers.
- **Key→pty path:** the added cost per key is flag checks plus the resize-prime `pending` branch (`Exec.zig:462`).
  Nothing on it blocks.
- **Idle:** the scrollbar fade, tab animation, quick-terminal slide, toast and recovery timers stop themselves.
- **Upstream-shared files:**
  - `generic.zig`, `Thread.zig`, `message.zig` and `Surface.zig` get additions that are `@hasDecl`-gated or neutral:
    `redraw`, `recoverDevice`, `HealthReport`, the 1x1 front texture, and `has_custom_shaders` requiring a post
    pipeline.
  - In `Exec.zig` and `stream_handler.zig`, the Windows arms are comptime-gated.
  - Every `Config.zig` default change is comptime-gated.
  - The core does not touch `src/terminal/*` beyond one test.
- **Security:**
  - `open_url` always returns true.
  - Links refuse UNC paths, `\\?\`, `\\.\`, ADS, 8.3 names, mapped drives and drive-relative paths.
  - OSC 7 refuses `//` paths, devices and `..` above the root.
  - Drops go through the paste-confirm path.
  - The IPC pipe has a DACL for the current user, gets a High-integrity label when elevated, and has
    `PIPE_REJECT_REMOTE_CLIENTS`. Test ops are env-gated, refused when elevated, and their variable is scrubbed from
    children.
  - Toast XML is escaped.
  - `notify` and `shell_open` record instead of acting in test mode.
  - Every saved screenshot passes the grid and z-order guard.

## Findings

### Critical

None.

### Important

1. **Title updates starve while a program sets its title more often than every 75 ms.**
   - Where: `src/apprt/win32/Window.zig:828-833`.
   - Problem: `surfaceTitleChanged` re-arms `SetTimer(title_debounce, 75 ms)` on every `set_title`. Re-arming the same
     id restarts the countdown. A spinner or progress bar in the title, or `while :; do printf '\e]0;%s\a' …; done`,
     therefore keeps the caption, the title row and the tab strip frozen on the old title until the output stops.
   - Fix: debounce with a fixed window. Arm the timer only when it is not already armed (keep a `title_timer_armed`
     flag, cleared in `titleDebounced`), so a stream of titles refreshes at least every 75 ms.

2. **The M3 acceptance record and the changelog contradict the landed 26.4 and 26.5 results.**
   - `docs/windows/m3/acceptance.md:9-11` still says the Git Bash input-loss item "is pending the Task 26.4 verdict".
     Line 100 of the same file says it is done.
   - The `SPEC.md` §17 M3 paragraph (line ~634) still speaks of "the open Git Bash input-loss item".
   - The RAM table (`acceptance.md:143,145`) and the RAM bullet in `CHANGELOG.md` give the pre-26.5 numbers (overlays
     +2.1 / over by 1.1 MB; inspector after close +3.6 / over by 1.6 MB). The ledger records the 26.5 outcome: inspector
     after close about +1.9 MB mean (2 of 5 samples over +2); overlays +0.4 MB warm and about +2 MB cold for the first
     paint, flagged as an "owner-visible note in M3 acceptance". That note is not in any doc, and `ram-baseline.csv`
     has no 26.5 rows.
   - Fix:
     - Change the status line to "26.4 worked around (26.4.1)".
     - Drop "open" from SPEC §17.
     - Add the 26.5 rows to `ram-baseline.csv`, and update the two acceptance rows and the CHANGELOG bullet with the
       26.5 numbers (inspector: borderline; overlays: warm passes, cold first paint about +2 MB).

3. **The CHANGELOG list "Core changes outside Windows-only code" is incomplete.** It matters for upstreaming.
   - Where: `docs/windows/CHANGELOG.md:102-111` lists only the `redraw` message, `has_custom_shaders`,
     `toggle_quick_terminal`, `Face.name` and the font additions.
   - Missing:
     - `src/termio/Exec.zig`: the resize prime; `PWD` is no longer exported to children on Windows; a
       synchronously completed `ReadFile` now takes its count from `GetOverlappedResult`.
     - `src/termio/stream_handler.zig`: OSC 7 on Windows is translated through `pwd_path`, and a non-local path resets
       the pwd. The `resetPwd` refactor touches every platform.
     - `src/os/hostname.zig`: NetBIOS and DNS names, compared case-insensitively.
     - `src/renderer/Thread.zig`: `recoverDevice` runs on every render callback, and animation `.draw` ticks call
       `waitFrameSlot`. Both are no-ops off D3D11.
     - `src/config/Config.zig`: `background-blur` defaults to `true` on Windows, and `shell-integration` gains
       `pwsh`/`cmd`.
     - `src/font/face/freetype.zig`: names on the Unicode platform (`TT_PLATFORM_APPLE_UNICODE`) are decoded as
       UTF-16BE. This behaviour change affects every platform and is an upstream candidate.
   - Fix: add these lines.

### Minor

4. **A link confirmation can leak, or be dropped after its tab moved to another window.**
   - Where: `src/apprt/win32/shell_open.zig:615` (`job.window` is captured at submit) and `:712-735` (`postConfirm`).
   - Leak: the worker can post after `link.windowDestroying` has drained, and before `WM_NCDESTROY`. A message posted to
     a dying window is never delivered, so the `ConfirmPayload` leaks.
   - Drop: after a tab move, `postedDialog` only searches the old window and silently drops the confirmation.
   - Fix: post to `app.msg_hwnd`, which lives as long as the app and is already drained at `appStopping`. Resolve
     `surface_id` across `app.windows` the way `notify.clicked` does.

5. **Quitting can hang behind a slow link.**
   - Where: `src/apprt/win32/shell_open.zig:652`.
   - Problem: `appStopping` calls `t.join()` on the worker, which may be inside `ShellExecuteEx` or a slow handler.
   - Fix: a bounded wait (`WaitForSingleObject(handle, 2000)`), then detach.

6. **The device-loss sweep takes each lost surface's `draw_mutex` on the UI thread.**
   - Where: `src/apprt/win32/recovery.zig:263-267` (`customShadersConfigured`).
   - Problem: it does this to read one bool, exactly when render threads may be inside a reset frame. This is a
     different path from the parked `markUnhealthy` item.
   - Fix: publish `has_custom_shaders` as an atomic, or cache it on the apprt `Surface` at config time.

7. **`export_terminal_io` writes the whole file on the UI thread.**
   - Where: `src/apprt/win32/export_io.zig:150,160-175`.
   - Problem: the write uses `MOVEFILE_WRITE_THROUGH` after the dialog. A large IO log stalls the window.
   - Fix: write on a worker thread. A post-back toast reports the result.

8. **One timer id is unused.**
   - Where: `src/apprt/win32/messages.zig:73-74`.
   - Problem: `timers.surface.decor` (2) is documented as "Expiry of the bell border", but nothing arms it. The bell is
     cleared on key and focus, per the Task 6 ruling.
   - Fix: remove the id, or reword the comment as reserved. Keep the id table at `:153` consistent.

9. **After an out-of-memory failure in `tabReparented`, a reusable popup keeps a pointer to the old window.**
   - Where: `src/apprt/win32/overlay.zig:566-569`.
   - Problem: when `reown` fails, `p.destroy()` runs but `p.window` stays `from`. The next `ensureWindow` of the
     scrollbar, link label, key indicator or search bar would parent to `from`, which may be freed by then.
   - Fix: set `p.window = to` after `p.destroy()`.

10. **A dangerous-extension reveal skips the reparse-point check.**
    - Where: `src/apprt/win32/shell_open.zig:322-327`. The same gap exists in `proxy_icon.zig:155`
      (`SHCreateItemFromParsingName` on an OSC 7 directory).
    - Problem: `.reveal` returns before `exists` and `final_path`. A cloned repo's `tool.exe` symlink to
      `\\host\s\tool.exe`, revealed in Explorer, lets the shell contact the share. The precondition is the same as the
      parked symlink item, but here the touch comes from the action, not from validation.
    - Fix: reuse `final_path` (or a component walk with `FILE_ATTRIBUTE_REPARSE_POINT`) before both the reveal and the
      icon fetch. Refuse when the target is not drive-local.

11. **The scheme refuse list and the extension denylist are thin.**
    - Schemes, `shell_open.zig:145-147`: only `ms-msdt` and `search-ms` are refused. Add `search`, `ms-officecmd`,
      `ms-cxh`, `ms-cxh-full`, `ms-appinstaller`, `mk`, `its` and `ms-its`.
    - Extensions, `shell_open.zig:79-94`: add `.pfx .p12 .p7b .p7c .der .sst .stl .psc1 .iqy .slk .xla .xlam .msu .one
      .onepkg .vsto .xbap`.
    - All of these are list additions.

12. **There are two device-name checks.**
    - Where: `src/apprt/win32/link_policy.zig:96-105` misses `COM¹-³` and `LPT¹-³`, which `pwd_path.isDeviceName`
      covers.
    - Impact: mitigated today, because `GetFullPathNameW` turns these names into `\\.\…`, which is refused.
    - Fix: share one function.

13. **No `SEM_FAILCRITICALERRORS`.**
    - Problem: an OSC 7 path or link on an empty removable drive (a card reader) can make the UI thread (proxy icon) or
      the link worker raise the system "No disk" dialog or stall. This is not tested.
    - Fix: call `SetThreadErrorMode(SEM_FAILCRITICALERRORS)` on the UI and link worker threads, and skip removable
      drives in `folderIcon`.

14. **Carry to the Windows 11 dialogs task:** `dialogs.zig:136` labels the link confirm button `&Allow`.
    - Problem: the confirm appears asynchronously after a click, so a user who keeps typing "a" could accept it.
    - Fix: drop the mnemonic, or ignore input for about 500 ms after the dialog shows. Apply this in the new dialog
      module.

15. **Capture guard: translucent configurations.**
    - Where: `test/windows/e2e/_common.ps1:1031` (`Test-CaptureZOrderClear`).
    - Problem: the guard accepts foreign windows below Ghostty. That is correct for opaque windows, but they would show
      through `background-opacity < 1`.
    - Impact: no leak today. Every translucent capture has a full-size backdrop of our own beneath, and
      `new-tab-flash.ps1:41` keeps statistics only.
    - Fix: when the scenario's config is translucent, `Save-WindowShot` must require our own covering window directly
      beneath.
    - Related (pre-M3, `5dcc05ace`): `Save-ClipboardText` keeps the owner's clipboard text in plain text under
      `%TEMP%\ghostty-e2e`. Protect it with DPAPI and delete it after the restore.

16. **The plan text is stale.**
    - `docs/windows/plans/M3-feature-parity.md:119` still lists message ids `+11..+14`, but the shipped ids are
      `+12..+15`. The acceptance open items mention this, but the plan was never amended.

## Verdict

**READY_WITH_FIXES**: no Critical findings.
- Finding 1 is a user-visible bug with a five-line fix.
- Findings 2-3 are documentation fixes needed for an honest owner record and for upstream tracking.
- Findings 4-16 can be batched into one polish round or recorded as M5 carries.
- Finding 14 belongs to the Windows 11 dialogs task.
