# M2 final review, part A: the win32 apprt

Range `0305564be..windows` (HEAD `72c857715`). Reviewer: final-rev-a (opus). Scope: `src/apprt/win32/**`, `pkg/win32/**` and a sanity pass over `test/windows/**`. Core, renderer, termio, latency and `open_url` security belong to part B; they appear here only where they meet the apprt. The review is read-only. Evidence run at HEAD: `zig build test -Dtest-filter="win32 "` through the test-lock, 91/91 steps green (cached). `zig fmt --check` on the scope fails on one file (see M1). No GUI runs.

Passes made:
1. Lifetime of Window, Tab and Surface across close, tear-off, re-dock, multi-window, tray, quit and teardown (`tearing_down` plus `serviceSentMessages`).
2. Re-entrancy of every modal (close, close-all and quit confirmations, clipboard confirmation) against posted IPC, drop, close and drag messages.
3. Uniqueness of message and timer ids.
4. Threading: the UI thread against the IPC pipe thread and the OLE drop callbacks, and which surface fields the renderer and IO threads can reach.
5. Security of IPC elevation and integrity, and of the drop payload.
6. The bindings rule, dead code, TODOs and fmt.
7. Ledger triage.

## Strengths

- **Teardown and close re-entrancy is sound.** Every path that runs a dialog re-checks after the modal loop. `askClose` uses `fromUserData(hwnd) != self`, `handleCloseSurface` looks the surface up again by id, `handleCloseAll` makes a fresh copy of the window list, and `QuitGate` drops nested requests. I traced shell exit behind a close dialog, close-all while another window's dialog is up, and a last tab closed during the window's own close dialog. Each one ends in a single `destroy` with no use-after-free. While a window is `tearing_down` it answers sent messages only through `DefWindowProc`, and it swallows `WM_CLOSE` (`Window.zig:1086`). `serviceSentMessages` uses `PM_QS_SENDMESSAGE`, so posted IPC, drop and close messages can never run in the middle of a teardown.
- **Tear-off and re-dock keep ownership simple.** `detachTab` → `setWindow` → `insertTab` moves only HWND parents. The surfaces' `window` field is UI-thread-only by contract, and the render and IO threads use `app` (`Surface.zig:62-68`). The present target is re-armed with a generation counter (`bumpPresentTarget`). A close posted to a window the tab has since left is forwarded by surface id or tab id (`Window.zig:1018-1054`). `hitAt` skips windows that are `tearing_down`. `WindowFromPoint` ignores disabled windows, so a tab cannot be dropped into a window whose close dialog is open.
- **The IPC thread really only moves bytes.** It reads one bounded frame (`max_request_m2`), posts `WM_GHOSTTY_IPC` and waits on `done`/`quit`, and it never calls `SendMessage`. Two references plus a `completed` flag make `complete` and `stop` race-free. `stop` runs only after the message loop has ended (`App.terminate`), and `WM_GHOSTTY_IPC` after `stopServer` is ignored (`App.zig:426`).
- **The elevation boundary is layered.** The pipe name carries a `-u-` or `-a-` marker. The DACL lists only the user's SID, and an elevated server adds a `NW;;;HI` label. The server's peer check compares user, elevation and integrity level (`instance.zig:139-157`), and the client checks the server's process the same way before it writes anything. `--command=` and `-e` are refused on both sides (`ops.zig:139`). The test ops are gated by an environment variable that is removed from the process environment at startup (`ops.zig:43-50`).
- **The drop path does not trust a posted pointer** (payload ids, `drop.zig:295-299,480-487`). It filters unsafe paths before quoting (`pathIsSafe`), and the OLE callbacks only copy data and post.
- **Message ids sit in one table with a uniqueness test** (`messages.zig`). `WM_APP+11` (`CLOSE_ALL`) was taken from the reserved range with a ruling. Every registered message (`TaskbarCreated`, `TaskbarButtonCreated`) is compared at run time and cannot collide.
- **Theme and config changes skip windows that are being created or torn down** (`theme.zig:306-315`). The tray forwards `WM_SETTINGCHANGE`, so a light/dark switch with no window open still applies.
- **Harness owner-safety holds.** Every launch gets a per-scenario `--class=ghostty-e2e-<hex>`, the CLI scenarios target that class, scripts kill only the processes they started, and the desktop-lock busy case exits 2 with SKIP.

## Issues

### BLOCKER

None.

### IMPORTANT

**I1. A background window takes activation when one of its shells exits or a split closes.** Code: `Tab.zig:227-230` (`focus`), `Tab.zig:464`, `Window.zig:501` (`removeTab` → `selectTab` → `focus = true`), `Tab.zig:415` (`split`).
- **Mechanism.** `Tab.focus` calls `SetFocus` unconditionally. When the target is a child of a top-level window that is not active, `SetFocus` activates that window, because both windows belong to the same UI thread. The code says so itself at `Window.zig:437-438`, and `detachTab` guards against it (`Window.zig:511-512`). The removal paths do not. `handleCloseSurface` → `Tab.removeSurface` reaches either `self.focus()` (split case) or `Window.removeTab` → `selectTab(index)` → `focus = true` (last surface of a tab).
- **Failure.** Two Ghostty windows: A in the foreground with the user typing, and B behind it running `make; exit` in one of two tabs (or a split). When B's shell exits, B is activated and comes in front of A. The user's next keystrokes go into B. In M4 the tmux shim will make this frequent: Claude Code teammate panes are created and closed in windows the user is not looking at. This was carried to Task 21 in the ledger ("SetFocus without active-window check can activate a background top-level when a shell exits there") and is still open at HEAD.
- **Fix (about 10 lines, now).** Give `Tab.focus` the guard `if (win32.user32.GetActiveWindow() != self.window.hwnd) return;` and keep `tab.focused` as the record of intent. On activation, `DefWindowProc(WM_ACTIVATE)` → `WM_SETFOCUS` on the top-level → `Window.zig:1149-1151` already forwards focus to the active tab, so nothing else changes. The explicit `Window.activate()` path calls `tab.focus()` only after `SetForegroundWindow` has succeeded, so the guard passes there. Test: with two windows, post `WM_GHOSTTY_CLOSE_SURFACE` to the background window's split and assert that `GetForegroundWindow()` is unchanged. This fits next to `windows-multi.ps1`.

### MINOR

**M1. `zig fmt --check` fails.** Code: `src/apprt/win32/actions/tab_actions.zig:71`. Zig 0.17 fmt rewrites `@intFromEnum(mode)` to `@backingInt(mode)` (the rest of the tree already uses `@backingInt`). A CI fmt gate (M6) would fail. Fix now: run `zig fmt` on the file.

**M2. The wheel forward can block the UI thread on another Ghostty process.** Code: `mouse.zig:362-371, 427-436`; the predicate is `isSurfaceWindow` at `mouse.zig:476`.
- The predicate compares only the class name `GhosttySurface`, and window classes of other processes report the same name. A standalone Ghostty (any launch with arguments is a separate process, by owner decision) or an elevated one under the pointer gets a synchronous cross-process `SendMessageW`.
- If that process is busy, for example joining 16 panes or stuck, this UI thread blocks with no timeout. Toward an elevated process the send fails silently under UIPI.
- Fix now: also require `GetWindowThreadProcessId(target, null) == GetCurrentThreadId()`.

**M3. The progress bar of a moved tab stays on the old window's taskbar button.** Code: `Tab.zig:498-509` (`setWindow`) and `taskbar.zig:77` (`surfaceClosed`). After a tear-off or re-dock, `reporter` still names the moved surface on the source window, so the source keeps the bar until the 15 s stale timer. Later reports light the target's button too, and two bars show for one job. Fix now (2 lines): in `setWindow`, call `taskbar.surfaceClosed(old_window, entry.view.id)` before reassigning `window`.

**M4. Content added while a close question is up is destroyed without being asked about.** Code: `Window.zig:1005-1016` (`handleClose`) and `1056-1062` (`handleCloseTab`, modes `.other`/`.right`).
- `needsConfirmClose()` is evaluated before the dialog. After "Yes", everything that is there at that moment is destroyed.
- An IPC `new-tab` handled inside the dialog loop is lost: `core_surface` 0 resolves to the last focused surface, which is in this window. So is a tab inserted to the right during a "close tabs to the right" question.
- The ledger's Task 6b deferred minor ("close-tab loop also closes tabs added behind the dialog") is the same root cause.
- Fresh shells rarely need confirmation, so this is minor today. Fix (M3): snapshot the target tab ids before asking, and after "Yes" close only those. Tabs added since are asked about separately.

**M5. `prompt_title` for a surface writes `surface.title`, which the shell's next OSC 0/2 overwrites.** Code: `title_edit.zig:290-303`. GTK keeps a separate `title_override` (`src/apprt/gtk/class/surface.zig:622, 1482, 2001`), so a user-renamed pane keeps its name. Here it reverts at the next prompt (Git Bash sets the title on every prompt), which breaks the "features 1:1" rule. Fix (M3): add `Surface.title_override` that wins in `getTitle` and `Tab.title`, and clear it with an empty edit.

**M6. Timer ids are missing from the shared table.** Code: `taskbar.zig:26` (`stale_timer_id = 0x2600` on the top-level window) and `Surface.zig:55` (`resize_timer_id = 1` on the surface class). They do not collide today: the window table has only the reserved `strip_autoscroll = 1`, and surfaces own no other timer. But the "one table" rule in `messages.zig:1-3` is not true, and the ledger carry ("move taskbar stale timer id 0x2600 into messages.zig") was not done. Fix now: add `timers.window.taskbar_stale` and `timers.surface.resize` and import them. Also make `clipboard.WM_GHOSTTY_CLIPBOARD_READ` an alias, as `App` does.

**M7. Local externs break the bindings rule (D6, "Core … never" / "hand-written in pkg/win32").** Code: `frame.zig:51-52` (`EnableMenuItem`, `GetSystemMenu`), `theme.zig:21` (`GetSysColor`), `title_edit.zig:27` (`CreateFontW`). Fix now: append them to `pkg/win32/user32.zig` and `pkg/win32/gdi32.zig` with the usual optional returns. These are mechanical changes.

**M8. `WM_GHOSTTY_IPC` trusts a posted pointer.** Code: `App.zig:424-429`. Any process at the same integrity level can post `WM_APP+5` to the message-only window with an arbitrary `lparam`, and the UI thread dereferences it. Task 38 changed the drop path to ids for exactly this reason. This is not a privilege boundary (a same-IL same-user process can already write our memory), so it is consistency and robustness only. Fix (M3): a small UI-thread map from id to `*Pending`, filled by `Server.serve` through a locked queue. Alternatively, accept it and document the asymmetry in `messages.zig`.

**M9. Leftovers and dead code.**
- `Window.zig:889` has a stale `// TODO(task14)` comment (the loop it mentions is gone).
- `drop.zig:479` doc says "lparam is a `*Payload`"; it is an id.
- Unused declarations: `taskbar.setProgress` (`:48`), `dialogs.confirmClose` (`:31`), `tray.sync` (`:98`), `resize_overlay.corner_px` (`:28`), `App.builtin`, `Chrome.Allocator`, `drop.HWND`, and the `win32`/`log` imports in `split_actions.zig`, `surface_actions.zig` and `window_actions.zig`.
- `Window.zig:889-893` `setMinimized` doc mismatch.
- `App.init` never undoes `BufferedPaintInit` on its error paths (`App.zig:109`, ledger Task 18).
- Fix now, in one cleanup commit.

**M10. The M2 exit checklist text has drifted from the rulings** (`docs/windows/plans/M2-tabs-splits-windows.md:1349-1359`).
- Item 2 says 43/25/2; the test pins 44/24/2 (`actions.zig:137-139`), because `open_url` became implemented in Task 34.4.
- Item 8 says the drop "highlights the target pane"; the Task 38 ruling removed the highlight (macOS has none).
- Fix now: amend the checklist so that acceptance is not judged against stale lines.

**M11. The last tab's window stays visible and empty while the tab's threads are joined.** Code: `Window.zig:493-496`. `removeTab` destroys the last tab before the posted `WM_CLOSE` runs, and the window is not hidden. For a 16-pane tab this is a visible empty frame for about 100 ms. `beginTeardown` hides first for exactly this reason. Fix now: `ShowWindow(self.hwnd, SW_HIDE)` before `tab.destroy()` in that branch.

### Style (macOS rule)

The resize overlay and the split divider follow macOS (style audit `d6546fefa`, Task 16). The tab strip and the caption keep the Win11 look, and "macOS-like tab bar" is a scheduled M3 polish task under a ruling. The scrollbar is native and always visible, also an interim per ruling. The system-menu fallback and tray menu strings are hard-coded English. The top-level class brush is black (`Window.zig:133`), so a light theme flashes black before the first frame; the brush should follow `theme.palette`. That belongs to the M3 polish task. No new deviation has gone unrecorded.

## Deferred minors triage (apprt, `pkg/win32` and harness items from the ledger)

Fix now (the M2 fix wave, together with I1 and M1–M3, M6, M7, M9–M11):

| Ledger item | Why now |
|---|---|
| T26 / Surface follow-up: taskbar timer id 0x2600 local | = M6 |
| T38: stale doc on `handle` | = M9 |
| T3: unused imports/decls in `actions/*_actions.zig`; long `=>` lines vs zig fmt | = M1/M9 (fmt now fails) |
| T18: `BufferedPaintInit` not undone on init errors | = M9, one `errdefer` |
| T6a: `Tab.title()` `@constCast`; T19: `@constCast` in `cancelForTab` | make `SplitTree.iterator`/`locate` callable on `*const`, or keep a `focusedSurfaceConst`; trivial |
| T20: `pipe_owner` duplicates `serving()` | drop the field, use `serving()` |
| T1: `HKEY_CURRENT_USER` zero-extended | sign-extend to match the SDK (works today, cheap to make exact) |

Defer to M3 (task named):

| Ledger item | M3 home |
|---|---|
| T6b: close-tab loop closes tabs added behind the dialog; readonly close dropped during a dialog | = M4, M3 close/lifecycle hardening (with TaskDialog follow-ups) |
| T27: paste-confirm TDM fallback, Esc/Alt+C untested, any failing HRESULT → MessageBox | M3 dialogs/overlay host task |
| T8: `.failed` ends the IPC thread instead of recreating the instance; `.retry` without backoff/log; NO_DATA test timing | M3 IPC hardening (the tmux pipe server in M4 reuses `Server`) |
| T11: `@panic` on double OOM in `ops.reply` | same IPC hardening task (return a static frame) |
| T5: sid not sanitized in `pipeName`; `encodeResponse` `data_json` unvalidated; missing protocol tests | same IPC hardening task |
| T20: no unit test of the early-answer path; `absolutizeWorkingDirectory` `C:foo`/`\foo` | same IPC hardening task |
| M8 (IPC pointer) | same IPC hardening task |
| T13: `pwd` stored per window | M3 window-subtitle task |
| T10: `compute` re-forces the active tab into view (undoes wheel scroll); negative minimize x below ~150 px | M3 "macOS-like tab bar" polish |
| T16: DBLCLK in the divider grab zone reaches core; T-junction slop overlap; `Chrome.zig` fallback divider colour | M3 decor pass (unfocused-split dimming) |
| T17: fallback menu texts English; SetCapture on caption-button down; focus return after menu not asserted | M3 tab-bar polish / localization note |
| T18: GDI FillRect fallback alpha 0 on Mica; DeviceLost/hover/pressed tests | M3 device-loss recovery task |
| T24: `HWND_TOPMOST` on owned popup; `paintLabel` without DeviceLost retry; width heuristic; `last_surface` pointer dedupe | M3 overlay host (resize overlay moves there) |
| T25: no THUMBTRACK dedupe; line/page from async offset; reload doesn't add/remove the bar | M3 overlay scroller (replaces the native bar) |
| T26: COM created for a no-op remove; `TaskbarButtonCreated` not allowed through UIPI on top-levels when elevated; error/pause carry-over untested | M3 notifications task |
| T28: `tray.visible` true after a failed `NIM_ADD` | M3 notifications task (state op should report `added` separately) |
| T31: ghost `registerClass` failure without own log; grab not rescaled on ghost `WM_DPICHANGED`; no cancel tests | M3 tab-bar polish |
| T32: close posted to an already destroyed source lost; re-SetWindowPos may cross monitors; close+open during a drag keeps the count equal (reorders the wrong tab, no UAF); no unit tests for refocus/restoreOrder | M3 tab-bar polish (track the dragged tab by id, not pointer + count) |
| T22: e2e `size_limit` null case; redundant FRAMECHANGED | M3 e2e upkeep (34.9 is reviewing placement) |
| T21: DPI scaling of moved tabs not unit-tested; weak cascade check | M3 e2e upkeep |
| T38: cygwin/System32 detection only with backslashes; `\\?\` unquoted for cmd; `\\wsl.localhost` | M3 drop follow-up (with text drops) |
| T15: `open_config` via sync `ShellExecuteW` (may show "Open with", skips the notepad fallback) | M3 config UX (use `ShellExecuteExW` + `SEE_MASK_NOASYNC \| SEE_MASK_FLAG_NO_UI`) |
| T19: wheel over top-level gaps swallowed; no e2e for wheel-over-strip / double-click-on-close | M3 tab-bar polish |
| T7: draw test silent SkipZigTest; `delimiterCount` u32 vs INT32 | M3 bindings sweep |
| T4 (harness): `ExtraArgs` drops empty strings; `-NoConfig` class check after launch; lock-wait expiry not in results; `measure-ram -dirty` on untracked files; `Get-FreeRamGb` ignores standby | M3 harness upkeep (Task 33/35 successor) |
| 34.10 note: frame-hittest passes `$null`/`""` to `FindWindowEx` for `#32768` | done in `72c857715`; drop |

Drop (no action):
- T2: timer-uniqueness test asserts only values; geom alias; no RED run. Superseded by M6.
- T6a: `close_confirmed` never read. It is read now (`Window.zig:1008`).
- T9: negative-bounds and NaN guards. These are unreachable with the Task 22 min window size and are covered by the clamp tests.
- T14: `applyOcclusion` visible while `split_layout` is null. It self-heals on the next layout.
- T15: stale `theme.zig:313` doc and `settingChanged` with wparam 0. Both are fixed: the tray calls `settingChangedMsg`.
- T31: 256-byte title cut splits UTF-8. This is harmless: `Chrome.toUtf16` shortens to a code-point boundary.
- T12: spike-only items. The spike is a throwaway tool.
- T36: unbalanced `timeEndPeriod`. Fixed in 34.12.

## Declined to judge

- Real multi-monitor, mixed-DPI tear-off, Mica, snap layouts and Explorer-restart behaviour (no GUI runs; owner checklist item 8).
- The full COM vtable layouts in `pkg/win32` beyond the slot-count tests.
- Whether `SetFocus` on a hidden or minimized background window activates it on every Windows build. I1 is argued from the in-code note at `Window.zig:437` and the ledger carry, not reproduced.
- Core, renderer, termio, latency and `open_url` (part B).

## Verdict (part A)

**Ready with fixes.** There is no blocker. Close, teardown and tear-off lifetimes, IPC threading and the elevation boundary hold across tasks. Before M2 acceptance:
1. Fix I1 (focus steal from background windows). It is a real multi-window bug and will get worse with the M4 tmux shim.
2. Run the cheap fix wave: M1 fmt, M2 wheel thread check, M3 taskbar handoff, M6 timer table, M7 externs, M9 cleanup, M10 checklist text, M11 hide-before-join.
3. Everything else rolls into M3 as triaged above.
