# M2 — Tabs, splits, multiple windows, custom titlebar: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `ghostty.exe` on Windows 11 hosts many top-level windows, each with a custom DWM titlebar (Mica, own caption buttons, snap layouts) that doubles as a Direct2D/DirectWrite tab strip; every tab holds a core `SplitTree` of terminal surfaces; a second launch opens a window in the running instance over a named pipe; every apprt action is implemented or explicitly deferred; with the last window closed Ghostty keeps running in the notification area, and closing a tab ends only that tab's shell and its console clients, and tabs can be dragged out into new windows or onto other windows with their processes intact (owner decisions 2026-10-26).

**Architecture:** `App` → `Window` (top-level HWND, custom frame, strip painted with D2D into the extended-frame client area) → `Tab` (one container child HWND per tab, holds `SplitTree(Surface)`) → `Surface` (child HWND + flip-model swap chain, unchanged from M1). Window procedures dispatch to small feature modules (`frame`, `strip_input`, `theme`, `taskbar`, `Chrome`) through hooks wired once in Task 6; action handling moves from `App.performAction` to `actions.zig` plus per-area handler files. A per-user/session/class named pipe served by one IPC thread carries single-instance requests now and the tmux shim in M4.

**Tech Stack:** Zig 0.17.0, MSVC ABI, Win32 (user32/dwmapi/uxtheme/comctl32/shell32/advapi32/winmm), Direct2D 1.0 + DirectWrite (COM, hand-written in `pkg/win32`), core `src/datastruct/split_tree.zig`, named pipes (overlapped), PowerShell e2e harness.

**Spec:** `docs/windows/SPEC.md` (authority with `docs/windows/DECISIONS.md` incl. "Owner decisions (2026-10-26)"; M2 rulings in SPEC §18 items 5–15). Inputs: `docs/windows/recon/apprt.md` §2 (action table), §3 (GTK structure); M1 plan and ledger `.superpowers/sdd/M1-core-and-window/progress.md` (carry-overs, table at the end).

## Global Constraints

Carried from M1 (every task implicitly includes these):

- Zig 0.17.0 at `C:\tools\zig-x86_64-windows-0.17.0\zig.exe` (always the full path). Shell: Git Bash. Target ABI MSVC (R3). Minimum OS Windows 11 22H2.
- Pure Win32 + DWM apprt in `src/apprt/win32`; no WinUI, no GTK, no .NET (R5). Chrome = Direct2D + DirectWrite; text inputs = native `EDIT` controls (SPEC D7).
- Code stays upstreamable: Windows code in its own dirs; core edits platform-gated and listed. **M2 core touch points (complete list):** `src/config/Config.zig` (new `windows-single-instance` option — Task 20; Windows default `quit-after-last-window-closed = false` — Task 28); `src/Command.zig` + `src/termio/Exec.zig` Windows-only process teardown (Task 29).
- Config path, default shell, cache/log locations exactly as M1 (DECISIONS, SPEC §18.4).
- Commits: no `Co-Authored-By` or similar trailers.
- Bindings: hand-written in `pkg/win32` (D6), append-only, W-variants, nullable returns as optionals, `callconv(.winapi)`; COM interfaces list ALL vtable slots with a slot-count test against SDK 10.0.26100 headers. Core (`src/os`, `src/termio`, `src/config`, `src/font`) never imports `win32`.
- Zig 0.17 std: no `std.time.Timer`/`std.Thread.sleep`; use the Io idioms of the touched file (`global.io()`, `std.Io.Timestamp.now(io, .awake)`, `io.sleep`).
- Worktree bootstrap: `cmd //c mklink /J "<worktree>\zig-pkg" "C:\D\den4ik\Ghostty\zig-pkg"` before the first build; a worktree's first (cold) build runs with `run_in_background` under `timeout 1500` through the test-lock.

New or changed for M2:

- **Builds `-j2`** (lead ruling, M1 ledger; `-j1` for a full `zig build` that OOMs). Strictly one build/test at a time through the test-lock. Bash timeout 600000 on every build/test command. Check free RAM before a full-suite run; prefer focused `-Dtest-filter`.
- **Timing acceptance only on ReleaseFast** (`--prefix zig-out-rf`, `$env:GHOSTTY_E2E_EXE`); Debug timings are reference only.
- **GUI tests only through the runner** `test/windows/e2e.ps1` (or `Invoke-GuiScenario`) holding the shared desktop lock `%TEMP%\gui-e2e.lock`. Never send input, take focus, or capture the screen outside a scenario.
- **Owner safety:** every launched Ghostty runs in the e2e sandbox with its own `class = ghostty-e2e-<hex>` so its pipe can never reach, or be reached by, the owner's Ghostty; scripts kill only processes they started; never change system settings (display scaling, theme, default apps), never broadcast `WM_SETTINGCHANGE`, never write the owner's registry or `%USERPROFILE%\.config`; keyboard layouts and clipboard restored as in M1; screenshots only of Ghostty windows. DPI and colour-scheme changes are simulated through the test-only IPC ops (SPEC §18.8).
- **Every confirmation dialog runs from a posted-message handler**, never inside `performAction`, a core callback or an IPC op handler (dialog loops re-enter the window procedure).
- **UI thread owns** every HWND, the D2D/DWrite objects and the tab/split model; the IPC thread only moves bytes and posts `WM_GHOSTTY_IPC`; it never calls `SendMessage`.
- **RAM:** one D2D factory, one DWrite factory and one DC render target per process (UI thread); no per-window D3D device for chrome unless Task 12's spike rules otherwise.
- Test names start with `win32 ` (apprt + bindings), `d3d11 ` (renderer). Renderer test commands pass `-Dapp-runtime=none`.

Command abbreviations (expand literally; shell state does not persist):
- `LOCK` = `bash "%USERPROFILE%/.claude/mods/teamlead/skills/teamlead/scripts/test-lock" --`
- `ZIG` = `"C:/tools/zig-x86_64-windows-0.17.0/zig.exe"`
- `E2E` = `powershell -NoProfile -ExecutionPolicy Bypass -File test/windows/e2e.ps1` (after `LOCK ZIG build -j2`)
- Run everything from the task's worktree root.

## Review Focus

1. **Closing things in every order:** last split of a tab, last tab of a window, last window; a shell `exit` while its close-confirm dialog is open; closing a tab whose surfaces stream output; closing from a keybind, the strip, Alt+F4 and the IPC. Expected: no use-after-free, focus lands on a live surface, the process ends only when the last window goes (and `quit-after-last-window-closed` allows it) → tests in Task 6 (`focusAfterRemove`, close decision), Task 14 (`split-close` e2e), Task 21 (`windows-multi` e2e), Task 27 (`close-confirm` e2e incl. shell exit behind the dialog), Task 28 (`tray` e2e: last window closed → process stays, New Window / Quit from the tray), Task 29 (`close-tree`, `tab-close-tree`: the tab's console clients end, `start cmd` windows and GUI apps survive), Task 32 (`tab-drag`: drag out, drag back, Esc; the source window closes when emptied, process pids unchanged).
2. **Many and tiny:** 30 tabs (strip overflow), 16 panes, a 200×150 window, a split dragged to its minimum. Expected: no negative/zero-width rects except hidden leaves, the active tab always visible, no zero-size swap chain draw, no crash → Task 9 (`tiny bounds`, `rounding sums`), Task 10 (`overflow keeps active visible`), Task 14 (`split-many` e2e), Task 16 (drag clamp test).
3. **Single instance in the wild:** no server, a stale pipe, a server blocked in a modal dialog, two launches at once, a `--working-directory` with spaces and Cyrillic, an owner instance of another build/class. Expected: the second launch either forwards and exits 0 within 2 s or runs standalone; never hangs, never reaches another class/session → Task 5 (pipe name, sanitize), Task 8 (busy/timeout/no-server tests), Task 20 (`single-instance` e2e with `C:\…\Рабочая папка`).
4. **DPI with hidden state:** a DPI change while a tab is hidden, a split zoomed, the window maximized or fullscreen. Expected: every surface (hidden ones too) and the strip use the new scale; maximize stays within the new monitor's work area → Task 23 (unit + `dpi-sim` e2e with a hidden tab and a zoomed split).
5. **Custom frame behaves like a native window:** maximized window does not overflow the monitor, top-edge resize works when restored, double-click caption maximizes, Alt+Space opens the system menu, snap flyout on the maximize button, keyboard focus returns to the terminal after any strip click. Expected as on any Win11 app → Task 17 (`frame-hittest` e2e: NCHITTEST codes, maximized rect), Task 19 (focus after click).

## Waves (parallelism)

≤ 3 tasks per wave; file sets inside a wave are strictly disjoint.

| Wave | Tasks | Depends on |
|---|---|---|
| W1 | 1 pkg/win32 Win32 extras · 2 M2 skeleton (stubs, ids, dump-id seam) · 3 action dispatch + coverage | — |
| W2 | 4 test infra · 5 IPC protocol + Overrides · 6 Window/Tab/Surface model | 2 (4, 5, 6); 3 (6) |
| W3 | 7 pkg/win32 D2D + DirectWrite · 8 IPC transport · 9 SplitLayout | 1 (7, 8); 5 (8); 2 (9) |
| W4 | 10 TabStrip model · 11 IPC ops + test oracle · 12 chrome spike | 2 (10); 4+5+6+8 (11); 7 (12) |
| W5 | 13 tabs · 14 splits · 15 theme + config reload | 6+11 (13, 15); 6+9+11 (14) |
| W6 | 16 divider drag + focus-follows-mouse · 17 custom frame · 18 chrome painter | 14 (16); 10+12 (17); 7+10+12+15 (18) |
| W7 | 19 strip input + inline rename · 20 single-instance + performIpc · 21 multi-window | 13+17+18 (19); 8+11 (20); 13 (21) |
| W8 | 22 placement toggles · 23 per-monitor DPI · 24 resize overlay | 17 (22); 17+18 (23); 18 (24) |
| W9 | 25 scrollbar · 26 bell + taskbar progress · 27 TaskDialog confirmations | 6 (25); 18 (26); 1 (27) |
| W10 | 28 tray + last-window lifecycle · 30 re-parent-safe present target · 31 tab drag state machine + ghost | 20+21 (28); 6 (30); 18 (31) |
| W11 | 29 tab-close process semantics · 32 tab tear-off and re-dock | 11+13 (29); 19+21+30+31 (32) |
| W12 | 33 M2 e2e full run (alone) | all above |
| W13 | 34.n integration fixes (≤ 3 at a time, disjoint) | 33 |
| W14 | 35 RAM rows, screenshots, M2 acceptance (alone) | 34.* |

Hot-file ownership by wave (any file not listed has a single owner): `src/apprt/win32/App.zig` 3→6→11→18→20→28; `src/config/Config.zig` 20→28; `ipc/ops.zig` 11→28; `Window.zig` 6→13→21→23→32; `Tab.zig` 6→14→16→32; `Surface.zig` 2→6→23→25→30; `Chrome.zig` 2→18; `strip_input.zig` 2→19→32; `mouse.zig` 1→16; `actions/app_actions.zig` 3→15→21→28; `actions/window_actions.zig` 3→6→13→19→22→26; `actions/tab_actions.zig` 3→13→21; `actions/split_actions.zig` 3→14; `actions/surface_actions.zig` 3→6→25; `dialogs.zig` 2→27; `instance.zig` 8→20; `pkg/win32/main.zig`+`build.zig` 1→7; `src/renderer/D3D11.zig` 2→4→30; `test/windows/e2e/_common.ps1` 4→29→35; `e2e/close-tree.ps1` 4→29; `lib/Harness.psm1`, `measure-ram.ps1`, `README.md` 4→35; `test/windows/lib/GhosttyIpc.psm1` 11 only; `src/apprt/win32.zig` 2 only. A task that needs one more `pkg/win32` declaration after W3 appends it at the end of the right file's section; a rebase conflict there is resolved by the second lander.

Private message ids (`messages.zig`, Task 2): `WM_APP+1` wakeup, `+2` clipboard read, `+3` quit timer (M1, unchanged); `+4` `WM_GHOSTTY_IPC` (msg window), `+5` `WM_GHOSTTY_CLOSE_SURFACE` (top-level), `+6` `WM_GHOSTTY_CLOSE_TAB` (top-level), `+7` `WM_GHOSTTY_QUIT_CONFIRM` (top-level), `+8` `WM_GHOSTTY_TITLE_EDIT_DONE` (top-level), `+9` `WM_GHOSTTY_TRAY` (tray window callback), `+10..+15` reserved M3.

---

### Task 1: `pkg/win32` Win32 extras for M2 + scattered externs moved in

**Files:**
- Modify: `pkg/win32/user32.zig`, `pkg/win32/kernel32.zig`, `pkg/win32/dwmapi.zig`, `pkg/win32/ole32.zig`, `pkg/win32/gdi32.zig`, `pkg/win32/main.zig`, `pkg/win32/build.zig`, `pkg/win32/test_user32.zig`
- Create: `pkg/win32/advapi32.zig`, `pkg/win32/shell32.zig`, `pkg/win32/comctl32.zig`, `pkg/win32/uxtheme.zig`, `pkg/win32/winmm.zig`
- Modify (extern moves only): `src/apprt/win32/util.zig` (RegGetValueW), `src/apprt/win32/clipboard.zig` (EnumClipboardFormats), `src/apprt/win32/mouse.zig` (SystemParametersInfoW, GetClassNameW), `src/renderer/d3d11/SwapChain.zig` (WaitForSingleObjectEx, CloseHandle)
- Modify: `src/build/SharedDeps.zig` Windows block (link list += `comctl32 shell32 uxtheme winmm d2d1 dwrite`; link the system libs only for artifacts that import `win32`, not for lib-vt consumers — M1 Task 5 minor)

**Interfaces:**
- Produces (all later M2 tasks rely on these names; nothing else in `pkg/win32` is edited before Task 7):
  - `user32`: `SetParent GetParent GetAncestor IsZoomed IsIconic IsWindowVisible GetWindowPlacement SetWindowPlacement MonitorFromWindow MonitorFromPoint GetMonitorInfoW BeginDeferWindowPos DeferWindowPos EndDeferWindowPos SetScrollInfo GetScrollInfo ShowScrollBar FlashWindowEx RegisterWindowMessageW GetClassNameW SystemParametersInfoW SystemParametersInfoForDpi EnumClipboardFormats MapWindowPoints GetDC ReleaseDC GetWindowTextW GetWindowTextLengthW RedrawWindow SetForegroundWindow ShowWindowAsync TrackMouseEvent(TME_NONCLIENT) GetSystemMetrics`; types `WINDOWPLACEMENT MONITORINFO SCROLLINFO FLASHWINFO NCCALCSIZE_PARAMS`; constants `WM_NCCALCSIZE WM_NCHITTEST WM_NCMOUSEMOVE WM_NCMOUSELEAVE WM_NCLBUTTONDOWN WM_NCLBUTTONUP WM_NCLBUTTONDBLCLK WM_NCRBUTTONUP WM_NCACTIVATE WM_ACTIVATE WM_SETTINGCHANGE WM_THEMECHANGED WM_VSCROLL WM_MBUTTONUP WM_LBUTTONDBLCLK WM_CONTEXTMENU WM_SYSCOMMAND WM_WINDOWPOSCHANGED WM_ENTERSIZEMOVE`, all `HT*` codes, `SC_MINIMIZE SC_MAXIMIZE SC_RESTORE SC_CLOSE`, `SB_* SIF_* ESB_*`, `FLASHW_*`, `MONITOR_DEFAULTTONEAREST`, `SWP_FRAMECHANGED SWP_SHOWWINDOW SWP_HIDEWINDOW`, `HWND_TOPMOST HWND_NOTOPMOST`, `WS_POPUP WS_CLIPCHILDREN WS_VSCROLL WS_EX_TOOLWINDOW WS_EX_NOACTIVATE WS_EX_TOPMOST`, `ES_AUTOHSCROLL`, `SM_CXFRAME SM_CYFRAME SM_CXPADDEDBORDER`, `SPI_GETWHEELSCROLLLINES`.
  - `kernel32`: `CreateNamedPipeW ConnectNamedPipe DisconnectNamedPipe CreateFileW WaitNamedPipeW ReadFile WriteFile FlushFileBuffers GetOverlappedResult CancelIoEx CreateEventW SetEvent ResetEvent WaitForSingleObjectEx WaitForMultipleObjects CloseHandle GetCurrentProcessId ProcessIdToSessionId GetNamedPipeServerProcessId LocalFree`; `OVERLAPPED SECURITY_ATTRIBUTES`; `PIPE_ACCESS_DUPLEX FILE_FLAG_OVERLAPPED FILE_FLAG_FIRST_PIPE_INSTANCE PIPE_TYPE_BYTE PIPE_READMODE_BYTE PIPE_WAIT PIPE_REJECT_REMOTE_CLIENTS PIPE_UNLIMITED_INSTANCES ERROR_PIPE_BUSY ERROR_PIPE_CONNECTED ERROR_IO_PENDING ERROR_FILE_NOT_FOUND ERROR_ACCESS_DENIED ERROR_BROKEN_PIPE ERROR_SEM_TIMEOUT WAIT_OBJECT_0 WAIT_TIMEOUT INFINITE GENERIC_READ GENERIC_WRITE OPEN_EXISTING`.
  - `advapi32`: `RegGetValueW OpenProcessToken GetTokenInformation ConvertSidToStringSidW ConvertStringSecurityDescriptorToSecurityDescriptorW`, `TOKEN_QUERY`, `TokenUser`, `TOKEN_USER`, `SDDL_REVISION_1`, `HKEY_CURRENT_USER`, `RRF_RT_REG_DWORD`.
  - `shell32`: `ShellExecuteW`, `ITaskbarList3` (full slot list; typed `HrInit SetProgressValue SetProgressState`), `CLSID_TaskbarList`, `TBPF_NOPROGRESS TBPF_INDETERMINATE TBPF_NORMAL TBPF_ERROR TBPF_PAUSED`; `Shell_NotifyIconW`, `NOTIFYICONDATAW`, `NIM_ADD NIM_MODIFY NIM_DELETE NIM_SETVERSION`, `NIF_MESSAGE NIF_ICON NIF_TIP NIF_SHOWTIP`, `NOTIFYICON_VERSION_4`, `NIN_SELECT NIN_KEYSELECT`; user32 also `CreatePopupMenu AppendMenuW TrackPopupMenuEx DestroyMenu LoadImageW DestroyIcon`, `MF_STRING MF_SEPARATOR TPM_RETURNCMD TPM_RIGHTBUTTON TPM_BOTTOMALIGN IMAGE_ICON LR_DEFAULTCOLOR SM_CXSMICON WM_COMMAND`; for the drag ghost `UpdateLayeredWindow GetCapture BLENDFUNCTION ULW_ALPHA AC_SRC_ALPHA WS_EX_LAYERED WS_EX_TRANSPARENT GA_ROOT WM_CAPTURECHANGED VK_ESCAPE`. `ole32`: `CoCreateInstance`, `CLSCTX_INPROC_SERVER`.
  - `comctl32`: `TaskDialogIndirect`, `TASKDIALOGCONFIG` (`extern struct` with `align(1)` fields — the SDK declares it under `pshpack1.h`), `TASKDIALOG_BUTTON`, `TDF_*`, `TDCBF_*`, `IDOK IDCANCEL`, `InitCommonControlsEx`, `SetWindowSubclass DefSubclassProc RemoveWindowSubclass`, `SUBCLASSPROC`.
  - `uxtheme`: `BufferedPaintInit BufferedPaintUnInit BeginBufferedPaint EndBufferedPaint BufferedPaintClear SetWindowTheme`, `BP_PAINTPARAMS`, `BPBF_TOPDOWNDIB`.
  - `dwmapi`: `DwmExtendFrameIntoClientArea DwmDefWindowProc DwmGetWindowAttribute`, `MARGINS`, `DWMSBT_AUTO=0 DWMSBT_NONE=1 DWMSBT_MAINWINDOW=2 DWMSBT_TRANSIENTWINDOW=3 DWMSBT_TABBEDWINDOW=4`, `DWMWA_CAPTION_COLOR`, `DWMWCP_*`.
  - `gdi32`: `CreateCompatibleDC CreateDIBSection SelectObject DeleteObject DeleteDC CreateSolidBrush FillRect`, `BITMAPINFO BITMAPINFOHEADER DIB_RGB_COLORS BI_RGB`. `winmm`: `PlaySoundW SND_ASYNC SND_FILENAME SND_NODEFAULT SND_PURGE`.
- [ ] **Step 1: Failing tests** in `pkg/win32/test_user32.zig`:
  ```zig
  test "win32 comctl32: TASKDIALOGCONFIG is byte-packed" { // @sizeOf == value printed by a throwaway `zig cc` program including commctrl.h (x64: record it in the test with that provenance comment) }
  test "win32 shell32: ITaskbarList3 slot count" { // 3 IUnknown + 18 own = 21 (verify against shobjidl_core.h) }
  test "win32 advapi32: current user SID string starts with S-1-5-" {}
  test "win32 kernel32: named pipe loopback" { // CreateNamedPipeW(\\.\pipe\ghostty-test-<pid>, OVERLAPPED) + CreateFileW client; write 5 bytes, read 5 bytes }
  test "win32 dwmapi: MARGINS size" { // 16 }
  test "win32 shell32: NOTIFYICONDATAW size" { // value printed by a throwaway `zig cc` program including shellapi.h (x64), with that provenance comment }
  ```
- [ ] **Step 2: Run** `LOCK ZIG build test -j2 --build-file pkg/win32/build.zig` → FAIL (missing declarations).
- [ ] **Step 3: Implement** the declarations; replace the five local externs in apprt/renderer files with the package ones (no behaviour change).
- [ ] **Step 4: Verify** package tests PASS; `LOCK ZIG build -j2` PASS; `grep -rn 'extern "' src/apprt/win32 src/renderer/d3d11` → no output.
- [ ] **Step 5: Commit** `git commit -m "feat(win32): M2 Win32 bindings (pipes, DWM frame, taskbar, task dialog, buffered paint) and move local externs into pkg/win32"`

### Task 2: M2 skeleton — feature-module stubs, message ids, dump-id seam, close kinds

**Files:**
- Create (stubs, exact contents per Interfaces): `src/apprt/win32/{geom,messages,Overrides,instance,SplitLayout,TabStrip,frame,Chrome,strip_input,title_edit,theme,placement,scrollbar,bell,taskbar,resize_overlay,tab_drag,drag_ghost}.zig`, `src/apprt/win32/ipc/{protocol,Server,client,ops}.zig`
- Modify: `src/apprt/win32.zig` (test block imports every new file), `src/apprt/win32/dialogs.zig` (add `CloseKind`, `confirmCloseKind`), `src/apprt/win32/Surface.zig` (`d3d11PresentTarget` sets `id`), `src/renderer/D3D11.zig` (`PresentTarget.id: u32`)

**Interfaces:**
- Produces (later tasks replace bodies, never names or field types):
  ```zig
  // geom.zig (real)
  pub const Rect = struct { x: i32 = 0, y: i32 = 0, w: i32 = 0, h: i32 = 0,
      pub fn contains(r, px: i32, py: i32) bool; pub fn right(r) i32; pub fn bottom(r) i32;
      pub fn fromRECT(win32 RECT) Rect; pub fn toRECT(r) RECT; pub fn scale(v: i32, dpi: u32) i32 /* round(v*dpi/96) */ };
  // messages.zig (real): the ids listed above the task list.
  // Overrides.zig: data real, functions stubbed (Task 5)
  command: ?configpkg.Command = null, shell_integration: ?configpkg.Config.ShellIntegration = null,
  working_directory: ?[:0]const u8 = null, title: ?[:0]const u8 = null,
  pub const none: Overrides = .{};
  pub fn parse(arena: Allocator, args: []const []const u8) ParseError!Overrides;   // stub: .none
  pub fn apply(self: Overrides, config: *configpkg.Config) !void;                  // stub: no-op
  pub fn forwardable(args: []const []const u8) bool;                               // stub: false
  // TabStrip.zig: types real, compute/hitTest stubbed (Task 10)
  pub const Mode = enum { hidden, tabs_only, titlebar };
  pub const Part = union(enum) { nowhere, caption, resize_top, tab: usize, tab_close: usize, new_tab, minimize, maximize, close };
  pub const Metrics = struct { height: i32, tab_min_w: i32, tab_max_w: i32, tab_pad: i32, close_w: i32, new_tab_w: i32,
      caption_btn_w: i32, min_drag_w: i32, resize_band: i32, drag_threshold: i32, pub fn forDpi(dpi: u32) Metrics };
  pub const Layout = struct { mode: Mode = .hidden, show_tabs: bool = false, bounds: geom.Rect = .{},
      tabs: std.ArrayList(geom.Rect) = .empty, new_tab: ?geom.Rect = null, minimize: ?geom.Rect = null,
      maximize: ?geom.Rect = null, close: ?geom.Rect = null, caption: geom.Rect = .{}, title: ?geom.Rect = null,
      clip: geom.Rect = .{}, scroll: i32 = 0,
      pub fn compute(self: *Layout, alloc: Allocator, m: Metrics, width: i32, mode: Mode, show_tabs: bool, count: usize, active: usize) !void,
      pub fn hitTest(self: *const Layout, m: Metrics, x: i32, y: i32, maximized: bool) Part,
      pub fn deinit(self: *Layout, alloc: Allocator) void };
  pub const Drag = struct { tab: usize, start_x: i32, grab_dx: i32, active: bool = false, current: usize };
  // stub compute: bounds = {0,0,width, mode==.hidden ? 0 : m.height}, nothing else; hitTest → .nowhere
  // frame.zig (Task 17)
  pub const Decorations = enum { client, server, none };
  pub const State = struct { decorations: Decorations = .server, hover: TabStrip.Part = .nowhere, pressed: TabStrip.Part = .nowhere, nc_tracking: bool = false };
  pub fn handle(window: *Window, msg: u32, wparam: WPARAM, lparam: LPARAM) ?LRESULT;  // stub: null
  pub fn apply(window: *Window) void;                                                  // stub: no-op
  pub fn stripMode(window: *const Window) TabStrip.Mode;  // stub: .hidden
  // Stub bodies may use only M1 `Window` fields (hwnd, app): Task 6 adds the rest in the next wave.
  // Chrome.zig (Task 18): per-window painter state + process-wide resources
  pub fn paint(window: *Window, hdc: HDC, dirty: geom.Rect) void;  // stub: no-op (the class brush paints)
  pub fn invalidate(window: *Window) void;                          // stub: InvalidateRect(window.hwnd, null, FALSE); Task 18: strip bounds only
  pub fn deinitShared() void;                                       // stub: no-op
  // strip_input.zig (Task 19)
  pub const State = struct { drag: ?TabStrip.Drag = null, hover: TabStrip.Part = .nowhere, tracking: bool = false,
      drop_index: ?usize = null };   // drop_index: insertion marker drawn while another window's tab is dragged over this strip (Task 32)
  pub fn handle(window: *Window, msg: u32, wparam: WPARAM, lparam: LPARAM) ?LRESULT;  // stub: null
  // theme.zig (Task 15)
  pub const Color = struct { r: u8, g: u8, b: u8, a: u8 = 255 };
  pub const Palette = struct { dark: bool, mica: bool, strip_bg: Color, tab_active_bg: Color, tab_hover_bg: Color,
      text: Color, text_inactive: Color, button_hover_bg: Color, button_pressed_bg: Color,
      close_hover_bg: Color = .{ .r = 0xC4, .g = 0x2B, .b = 0x1C }, close_hover_text: Color = .{ .r = 255, .g = 255, .b = 255 }, divider: Color };
  pub fn palette(window: *const Window) Palette;          // stub: fixed dark palette, mica = false
  pub fn applyToWindow(window: *Window) void;             // stub: M1 behaviour (DWMWA_USE_IMMERSIVE_DARK_MODE from util.systemUsesDarkTheme)
  pub fn handle(window: *Window, msg: u32, wparam: WPARAM, lparam: LPARAM) ?LRESULT;  // stub: null
  pub fn schemeChanged(app: *App, scheme: apprt.ColorScheme) void;                     // stub: no-op
  // placement.zig (Task 22)
  pub const State = struct { fullscreen: bool = false, topmost: bool = false, saved_valid: bool = false,
      saved_rect: geom.Rect = .{}, saved_show_cmd: u32 = 0, saved_style: usize = 0,
      initial_size: ?struct { width: u32, height: u32 } = null };   // own fields, not WINDOWPLACEMENT: Task 1 adds that type in the same wave
  pub fn applyStartup(window: *Window) void;              // stub: no-op
  // scrollbar.zig (Task 25)
  pub const State = struct { total: u64 = 0, offset: u64 = 0, len: u64 = 0, enabled: bool = false };
  // taskbar.zig (Task 26)
  pub const State = struct { progress: ?terminal.osc.Command.ProgressReport = null };
  pub fn handle(window: *Window, msg: u32, wparam: WPARAM, lparam: LPARAM) ?LRESULT;  // stub: null
  // resize_overlay.zig (Task 24)
  pub const State = struct { hwnd: ?HWND = null, armed: bool = false };
  pub fn notify(surface: *Surface, cols: u32, rows: u32) void;  // stub: no-op
  pub fn deinit(state: *State) void;                            // stub: no-op
  // dialogs.zig
  pub const CloseKind = enum { surface, tab, window, all_windows, app };
  pub fn confirmCloseKind(owner: HWND, kind: CloseKind) bool;   // M1 MessageBoxW with a kind-specific sentence
  // D3D11.zig: PresentTarget gains `id: u32` (apprt Surface.id); Surface.d3d11PresentTarget fills it.
  ```
  `instance.zig`, `SplitLayout.zig`, `title_edit.zig`, `bell.zig`, `tab_drag.zig`, `drag_ghost.zig`, `ipc/*.zig`: doc comment only (owners create their API).
- [ ] **Step 1: Failing tests** `"win32 skeleton: private message ids are unique and above M1's"` (all `messages.*` distinct, each > `WM_APP + 3`, < `WM_APP + 16`); `"win32 geom: rect contains and scale"` (`{10,10,20,20}` contains (10,10) not (30,30); `scale(40, 144) == 60`, `scale(1, 120) == 1`).
- [ ] **Step 2: Run** `LOCK ZIG build test -j2 -Dtest-filter="win32 skeleton"` and `"win32 geom"` → FAIL.
- [ ] **Step 3: Implement** stubs exactly as listed.
- [ ] **Step 4: Verify** PASS; `LOCK ZIG build -j2` PASS; `E2E -Milestone M1` is not available yet — run `powershell -NoProfile -File test/windows/e2e-m1.ps1 -Only startup,render` → PASS (dumps still found: Task 4 renames them, M1 index naming unchanged here).
- [ ] **Step 5: Commit** `git commit -m "feat(win32): M2 module skeleton, private message ids, present-target id"`

### Task 3: Action dispatch with full coverage classification

**Files:**
- Modify: `src/apprt/win32/App.zig` (`performAction` → `actions.perform`; move M1 arms out; test for wakeup re-arm — M1 Task 14 minor)
- Create: `src/apprt/win32/actions.zig`, `src/apprt/win32/actions/{app_actions,window_actions,tab_actions,split_actions,surface_actions}.zig`

**Interfaces:**
- Consumes: M1 `App`, `Window` (one surface), `mouse.refreshCursor`.
- Produces:
  ```zig
  // actions.zig
  pub fn perform(app: *App, target: apprt.Target, comptime action: apprt.Action.Key, value: apprt.Action.Value(action)) !bool;
  pub const Status = union(enum) { implemented, deferred: struct { milestone: []const u8, reason: []const u8 }, unsupported: []const u8 };
  pub fn status(comptime key: apprt.Action.Key) Status;   // comptime table, one entry per key
  ```
  Every arm calls one handler `fn(app: *App, target: apprt.Target, value) !bool` in the area file named below; M2 handlers are stubs returning `false` until their task. Deferred and unsupported arms `log.debug` and return `false`.

  | Area file (owner task) | Actions |
  |---|---|
  | `app_actions` | `quit` (M1 move; 21 adds confirm), `new_window`, `close_all_windows`, `goto_window`, `present_terminal` (21); `reload_config`, `config_change`, `open_config`, `color_change` (15); `quit_timer` (M1 move → `app.startQuitTimer/stopQuitTimer`) |
  | `window_actions` | `close_window`, `initial_size`, `size_limit`, `cell_size` (M1 move; 6 adapts); `set_window_title` (13); `toggle_maximize`, `toggle_fullscreen`, `toggle_window_decorations`, `float_window`, `reset_window_size`, `resize_window` (22, delegating to `placement`); `prompt_title` (19, → `title_edit.prompt`); `ring_bell`, `progress_report` (26) |
  | `tab_actions` | `new_tab`, `close_tab`, `goto_tab`, `move_tab`, `set_tab_title`, `set_title` (M1 move), `copy_title_to_clipboard`, `pwd` (13); `move_tab_to_new_window` (21) |
  | `split_actions` | `new_split`, `goto_split`, `resize_split`, `equalize_splits`, `toggle_split_zoom` (14) |
  | `surface_actions` | `mouse_shape`, `mouse_visibility`, `render`, `show_child_exited` (M1 move; `show_child_exited` keeps returning false = core handles it per `wait-after-command`); `scrollbar` (25) |

  Deferred (milestone, reason): `toggle_quick_terminal`, `toggle_command_palette`, `inspector`, `render_inspector`, `export_terminal_io`, `desktop_notification`, `command_finished`, `mouse_over_link`, `open_url` (core's opener stays the fallback), `start_search`, `end_search`, `search_total`, `search_selected`, `key_sequence`, `key_table`, `renderer_health`, `readonly`, `toggle_background_opacity`, `toggle_visibility` → `"M3"` (SPEC §17 M3 list); `check_for_updates`, `show_on_screen_keyboard`, `secure_input`, `undo`, `redo` → `"M5"` (Windows extras / analogs of macOS-only features); `selection_changed` → `"post-v1"` (UI Automation). Unsupported: `toggle_tab_overview` ("no tab overview on Windows; not required by DECISIONS"), `show_gtk_inspector` ("GTK only").
- [ ] **Step 1: Failing tests** in `actions.zig`:
  ```zig
  test "win32 actions: every Action.Key is classified" { // inline for over @typeInfo(apprt.Action.Key).@"enum".fields: status(key) compiles; count == 70 }
  test "win32 actions: M2 scope list matches the plan" { // the 43 implemented keys above report .implemented; the 25 deferred report their milestone; the 2 unsupported report .unsupported }
  test "win32 app: wakeup re-arms after the queued message is handled" { // wakeup → drain one WM_GHOSTTY_WAKEUP via msgWndProc → wakeup posts again }
  ```
- [ ] **Step 2: Run** `LOCK ZIG build test -j2 -Dtest-filter="win32 actions"` → FAIL.
- [ ] **Step 3: Implement**; M1 behaviour of the moved arms is unchanged (they still use `window.surface`; Task 6 adapts them).
- [ ] **Step 4: Verify** PASS; `LOCK ZIG build -j2`; `powershell -NoProfile -File test/windows/e2e-m1.ps1 -Only startup,ctrl-c,shell-exit` → PASS.
- [ ] **Step 5: Commit** `git commit -m "refactor(win32): action dispatch table with coverage classification for every action"`

### Task 4: Test infrastructure — discovering runner, per-scenario class, dumps outside the context lock

**Files:**
- Create: `test/windows/e2e.ps1`
- Modify: `test/windows/e2e-m1.ps1` (thin wrapper: `& e2e.ps1 -Milestone M1 @PSBoundParameters`), every `test/windows/e2e/*.ps1` (one header line), `test/windows/e2e/_common.ps1`, `test/windows/lib/Harness.psm1`, `test/windows/measure-ram.ps1`, `test/windows/README.md`, `docs/windows/ram-baseline.csv` (LF line endings only)
- Modify: `src/renderer/d3d11/Frame.zig`, `src/renderer/D3D11.zig` (dump: read back into a CPU buffer under the context lock, write the BMP after `drawFrameEnd` unlocks; file name `surface-<PresentTarget.id>.bmp`, headless index unchanged), `src/renderer/d3d11/Device.zig` (comptime `@sizeOf`/`@offsetOf` assert for `DXGI_ADAPTER_DESC` use — M1 Task 30 minor)

**Interfaces:**
- Consumes: Task 2 (`PresentTarget.id`).
- Produces:
  - Scenario header (first comment line of each `e2e/*.ps1`, `_*.ps1` excluded): `# e2e: milestone=M1 timeout=150 order=30`. The 18 M1 scripts get `milestone=M1` and orders 10…180 in the current `e2e-m1.ps1` order.
  - `e2e.ps1 [-Milestone M1|M2|all] [-Only a,b] [-EvidenceDir d]`: discovers scripts, sorts by `order`, keeps every M1 runner behaviour (GUI lock held for the run and handed down in `GHOSTTY_E2E_LOCK_ID`, clipboard backup/restore, per-scenario timeout kill, `results.txt`/`info.txt`); exit code `0` = no FAIL and ≥ 1 PASS, `1` = any FAIL, `2` = every scenario SKIPped (M1 Task 28 minor).
  - `_common.ps1`: `Start-E2eGhostty` appends `class = ghostty-e2e-<8 hex>` (fresh per scenario, stored in `$G.Class`) and `quit-after-last-window-closed = true` (scenarios that expect the process to end keep their meaning after Task 28 flips the Windows default; `-KeepDefaultQuit` omits it) to the config text and sets `GHOSTTY_WIN32_TEST_IPC=1`; `$G.Dump` = `surface-1.bmp`; `Get-DumpPath($G, [int]$SurfaceId)`; `-ExtraArgs [string[]]` passed to the exe; `-NoTestIpc` leaves `GHOSTTY_WIN32_TEST_IPC` unset.
  - `measure-ram.ps1`: same class isolation (`class = ghostty-ram-<hex>`); CSV `commit` = `git rev-parse --short HEAD` at measure time plus `-dirty` when the tree is dirty (M1 Task 30 minor); LF output.
- [ ] **Step 1: Failing test** `"d3d11 frame: dump is written after the context lock is released"` — fixture with a dump dir: a second thread blocks on `device.lockContext()` while frame 1 completes; assert it acquires the lock before the BMP file exists (the file appears after `drawFrameEnd`), and the file is `surface-7.bmp` when `PresentTarget.id = 7`.
- [ ] **Step 2: Run** `LOCK ZIG build test -j2 -Dapp-runtime=none -Dtest-filter="d3d11 frame"` → FAIL.
- [ ] **Step 3: Implement** renderer change and scripts.
- [ ] **Step 4: Verify** PASS; `LOCK ZIG build -j2`; `E2E -Milestone M1` → 18 PASS (or SKIP when not interactive, exit 2); `powershell -NoProfile -File test/windows/e2e-m1.ps1 -Only render` → PASS.
- [ ] **Step 5: Commit** `git commit -m "test(windows): discovering e2e runner, per-scenario instance class, frame dumps outside the context lock"`

### Task 5: IPC wire protocol and new-surface overrides (pure)

**Files:** Modify (replace stubs) `src/apprt/win32/ipc/protocol.zig`, `src/apprt/win32/Overrides.zig`.

**Interfaces:**
- Consumes: Task 2 stubs; GTK `src/apprt/gtk/class/Overrides.zig` (semantics of `parse`) and `src/apprt/gtk/class/surface.zig` (`applyCommandOverrides`, working-directory finalize, ~3570-3585) for `apply`.
- Produces:
  ```zig
  // ipc/protocol.zig — std only, no other imports (tmux.exe imports it as a module in M4)
  pub const version: u32 = 1;
  pub const max_frame: u32 = 16 << 20;
  pub fn writeFrame(w: *std.Io.Writer, payload: []const u8) !void;       // u32 LE length + bytes
  pub fn readFrame(r: *std.Io.Reader, alloc: Allocator) ![]u8;          // error.FrameTooLarge, error.EndOfStream
  pub const Code = enum(u8) { ok = 0, failed = 1, bad_request = 2, version_mismatch = 3 };
  pub const Request = struct { v: u32, op: []const u8, args: []const []const u8 = &.{}, core_surface: []const u8 = "0",
      surface: u32 = 0, window: u32 = 0, action: []const u8 = "", dpi: u32 = 0, scheme: []const u8 = "" };
  pub fn parseRequest(arena: Allocator, bytes: []const u8) error{ BadRequest, OutOfMemory }!Request; // unknown fields ignored
  pub fn encodeRequest(alloc: Allocator, req: Request) ![]u8;
  pub fn encodeResponse(alloc: Allocator, code: Code, stdout: []const u8, stderr: []const u8, data_json: ?[]const u8) ![]u8;
  pub const Response = struct { code: Code, stdout: []const u8, stderr: []const u8, data_json: ?[]const u8 };
  pub fn parseResponse(arena: Allocator, bytes: []const u8) !Response;
  pub fn sanitizeClass(buf: []u8, class: []const u8) []const u8;  // [A-Za-z0-9._-] kept, others '_', max 80 bytes
  pub fn pipeName(buf: []u8, sid: []const u8, session: u32, class: []const u8) ![]const u8; // "\\\\.\\pipe\\ghostty-<sid>-<session>-<sanitized>"
  ```
  Ops (SPEC §18.5): `new-window` {args}, `new-tab` {core_surface, args}, `toggle-quick-terminal`; test-only (SPEC §18.8) `state`, `action` {surface, action}, `dpi` {window, dpi}, `color-scheme` {scheme}. Response `{"v":1,"code":N,"stdout":"…","stderr":"…","data":<json>|null}`.
  `Overrides.parse` accepts `--working-directory=`, `--title=`, `--command=`, `--shell-integration=`, and `-e <argv…>` exactly like GTK; `forwardable(args)` = every arg is one of the first four forms (no `-e`, nothing else).
- [ ] **Step 1: Failing tests**
  ```zig
  test "win32 ipc protocol: frame roundtrip and limits" { // "{}" roundtrip; length 16 MiB + 1 → error.FrameTooLarge; truncated header → error.EndOfStream }
  test "win32 ipc protocol: request parse ignores unknown fields" { // {"v":1,"op":"new-window","args":["--title=a"],"zzz":3} → op/args }
  test "win32 ipc protocol: bad request" { // "not json" and {"op":1} → error.BadRequest }
  test "win32 ipc protocol: response with data" { // encodeResponse(.ok, "", "", "{\"a\":1}") parses back with data_json "{\"a\":1}" }
  test "win32 ipc protocol: pipe name sanitizes class" { // ("S-1-5-21-1", 1, "com.mitchellh.ghostty") → \\.\pipe\ghostty-S-1-5-21-1-1-com.mitchellh.ghostty; class "a b/ж" → "a_b___" (UTF-8 bytes each '_'); 200-byte class → 80 }
  test "win32 overrides: working directory with spaces and Cyrillic" { // "--working-directory=C:\\Users\\Анна Ли\\x y" kept verbatim }
  test "win32 overrides: -e collects the rest" { // {"-e","vim","a b"} → command direct {"vim","a b"} }
  test "win32 overrides: forwardable" { // {"--title=x","--working-directory=C:\\a"} true; {"--font-size=20"} false; {"-e","x"} false; {} true }
  ```
- [ ] **Step 2: Run** `LOCK ZIG build test -j2 -Dtest-filter="win32 ipc protocol"` and `"win32 overrides"` → FAIL.
- [ ] **Step 3: Implement** with `std.json` (parse into the struct with `ignore_unknown_fields`); `apply` mirrors GTK.
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `git commit -m "feat(win32): IPC frame/JSON protocol and new-surface overrides"`

### Task 6: Window → Tab → SplitTree(Surface) model, close flow, feature hooks

**Files:**
- Create: `src/apprt/win32/Tab.zig`
- Modify: `src/apprt/win32/Window.zig`, `src/apprt/win32/Surface.zig`, `src/apprt/win32/App.zig`, `src/apprt/win32/actions/window_actions.zig`, `src/apprt/win32/actions/surface_actions.zig`

**Interfaces:**
- Consumes: Task 2 stubs (`frame`, `Chrome`, `strip_input`, `theme`, `taskbar`, `placement`, `resize_overlay`, `TabStrip`, `messages`, `Overrides`, `dialogs.confirmCloseKind`), Task 3 area files.
- Produces (consumed by Tasks 11, 13–27):
  ```zig
  // Surface.zig
  pub const Tree = SplitTree(Surface);
  pub const class_name: [:0]const u16;                                  // now pub (mouse.zig reuses it, Task 16)
  pub const CreateOptions = struct { parent: ?*CoreSurface = null, overrides: Overrides = .none, context: apprt.surface.NewSurfaceContext };
  pub fn create(tab: *Tab, opts: CreateOptions) !*Surface;  // refs = 0; config = apprt.surface.newConfig + overrides.apply + font-size inheritance (window-inherit-font-size, as GTK font_size_request)
  pub fn ref(self: *Surface, alloc: Allocator) Allocator.Error!*Surface; // SplitTree view contract
  pub fn unref(self: *Surface, alloc: Allocator) void;                  // destroy() at 0
  pub fn eql(a: *const Surface, b: *const Surface) bool;
  // new fields: tab: *Tab, refs: u32, bell_ringing: bool = false, scrollbar: scrollbar.State = .{}
  // close(process_active) posts messages.WM_GHOSTTY_CLOSE_SURFACE to window.hwnd (wparam = id, lparam = process_active)
  // focus-in sets tab.focused = self, clears bell_ringing, Chrome.invalidate(window); applySize calls resize_overlay.notify(self, grid cols, rows) after a successful sizeCallback
  // Tab.zig
  pub const CreateOptions = struct { parent: ?*CoreSurface = null, overrides: Overrides = .none, context: apprt.surface.NewSurfaceContext = .tab };
  window: *Window, hwnd: HWND /* class GhosttyTab, WS_CHILD|WS_CLIPCHILDREN|WS_CLIPSIBLINGS */, tree: Surface.Tree,
  focused: ?*Surface, title_override: ?[:0]u8, id: u32,
  pub fn create(window: *Window, opts: CreateOptions) !*Tab;    // container + first surface
  pub fn destroy(self: *Tab) void;                              // tree.deinit releases every surface
  pub fn focusedSurface(self: *Tab) ?*Surface;                  // focused if still in tree, else first leaf
  pub fn focus(self: *Tab) void;
  pub fn setVisible(self: *Tab, visible: bool) void;            // ShowWindow + occlusionCallback per surface; layout on show
  pub fn layout(self: *Tab) void;                               // this task: the single leaf fills the container
  pub fn replaceTree(self: *Tab, tree: Surface.Tree) void;      // deinit old, store, layout
  pub fn removeSurface(self: *Tab, s: *Surface) void;           // focusAfterRemove, tree.remove, empty → window.removeTab(self)
  pub fn title(self: *const Tab) []const u8;                    // title_override orelse focused surface title orelse "Ghostty"
  pub fn bellRinging(self: *const Tab) bool;
  pub fn needsConfirmClose(self: *const Tab) bool;              // any surface core.needsConfirmQuit()
  pub fn setWindow(self: *Tab, window: *Window) void;           // SetParent + every surface.window = window
  pub fn focusAfterRemove(comptime T: type, tree: *const T, at: T.Node.Handle, alloc: Allocator) !?T.Node.Handle; // previous_wrapped else next_wrapped, never `at`
  // Window.zig
  pub const CreateOptions = struct { parent: ?*CoreSurface = null, overrides: Overrides = .none, first_tab: bool = true };
  hwnd, app, id: u32, tabs: std.ArrayList(*Tab), active_tab: usize, dpi: u32, title_override: ?[:0]u8,
  strip: TabStrip.Layout, strip_input: strip_input.State, frame: frame.State, placement: placement.State,
  taskbar: taskbar.State, overlay: resize_overlay.State, size_limit, cell_size, confirming_close: bool, close_confirmed: bool,
  pub fn create(app: *App, opts: CreateOptions) !*Window;  // hidden; style WS_OVERLAPPEDWINDOW|WS_CLIPCHILDREN; calls theme.applyToWindow, frame.apply
  pub fn show(self: *Window) void;                         // placement.applyStartup then ShowWindow
  pub fn activeTab(self: *Window) ?*Tab;
  pub fn addTab(self: *Window, opts: Tab.CreateOptions) !*Tab;  // this task: append + select
  pub fn selectTab(self: *Window, index: usize) void;           // hide old, show new, focus, refreshTitle, layout strip
  pub fn removeTab(self: *Window, tab: *Tab) void;              // destroy; select neighbour; none left → requestClose(true)
  pub fn tabIndex(self: *const Window, tab: *const Tab) ?usize;
  pub fn showTabs(self: *const Window) bool;                    // this task: tabs.len > 1 (Task 13 applies window-show-tab-bar)
  pub fn layout(self: *Window) void;  // m = TabStrip.Metrics.forDpi(dpi); strip.compute(width, frame.stripMode(self), showTabs(), …); content = client below strip.bounds; active container SetWindowPos; Chrome.invalidate
  pub fn contentRect(self: *const Window) geom.Rect;
  pub fn refreshTitle(self: *Window) void;                      // SetWindowTextW(title_override orelse active tab title)
  pub fn requestClose(self: *Window, confirmed: bool) void;     // sets close_confirmed, posts WM_CLOSE (replaces the spoofable wparam marker)
  pub fn needsConfirmClose(self: *const Window) bool;
  pub fn findSurface(self: *Window, id: u32) ?*Surface;
  pub fn applyDpi(self: *Window, dpi: u32, suggested: ?win32.foundation.RECT) void; // M1 logic moved; Task 23 fixes ordering
  // wndProc dispatch order: frame.handle → strip_input.handle → theme.handle → taskbar.handle → own cases; WM_PAINT → Chrome.paint;
  // WM_ACTIVATE tracks app.last_active; WM_GHOSTTY_CLOSE_SURFACE / WM_GHOSTTY_CLOSE_TAB / WM_CLOSE use closeDecision + dialogs.confirmCloseKind (confirming_close guard incl. Surface.close — M1 Task 21 minor)
  pub fn closeDecision(confirmed: bool, needs_confirm: bool) enum { close, ask };
  // App.zig: windows: ArrayList(*Window), last_active: ?*Window, pub fn windowFor(core: *CoreSurface) ?*Window, pub fn surfaceFor(core) ?*Surface (= core.rt_surface)
  ```
  The window-procedure dead `SIZE_MINIMIZED` child branch and the `terminate()` spin on a failing `DestroyWindow` go away; `Window.create`'s error path removes itself by pointer (M1 Task 14/21 minors). Area handlers now route through `target.surface.rt_surface` (`mouse_shape` etc. act on that surface, not `window.surface`).
- [ ] **Step 1: Failing tests**
  ```zig
  test "win32 window: close decision" { // (true, true) → close; (false, true) → ask; (false, false) → close }
  test "win32 tab: focus after removing a leaf" { // TestView tree A | (B / C): remove B → A; remove A (first leaf) → B; single leaf → null }
  ```
- [ ] **Step 2: Run** `LOCK ZIG build test -j2 -Dtest-filter="win32 window"` and `"win32 tab"` → FAIL.
- [ ] **Step 3: Implement.** Destroy order stays SPEC §6.4 (surfaces before their container, containers before the top-level).
- [ ] **Step 4: Verify** PASS; `LOCK ZIG build -j2`; `E2E -Milestone M1` → all PASS (regression gate: close-tree, shell-exit, close-while-streaming, resize-while-streaming on ReleaseFast).
- [ ] **Step 5: Commit** `git commit -m "feat(win32): window/tab/split-tree model with refcounted surfaces and posted close flow"`

### Task 7: `pkg/win32` Direct2D + DirectWrite bindings

**Files:** Create `pkg/win32/d2d1.zig`, `pkg/win32/dwrite.zig`, `pkg/win32/test_d2d.zig`; Modify `pkg/win32/main.zig`, `pkg/win32/build.zig`.

**Interfaces:**
- Consumes: Task 1 (`gdi32` DIB functions).
- Produces: `d2d1`: `D2D1CreateFactory` (single-threaded), `ID2D1Factory` (full slots; typed `CreateDCRenderTarget CreateHwndRenderTarget`), `ID2D1RenderTarget` (full slots; typed `CreateSolidColorBrush Clear FillRectangle FillRoundedRectangle DrawLine DrawTextLayout PushAxisAlignedClip PopAxisAlignedClip SetTextAntialiasMode BeginDraw EndDraw SetTransform`), `ID2D1DCRenderTarget.BindDC`, `ID2D1HwndRenderTarget.Resize`, `ID2D1SolidColorBrush.SetColor`, structs `D2D1_RENDER_TARGET_PROPERTIES D2D1_PIXEL_FORMAT D2D1_COLOR_F D2D1_RECT_F D2D1_ROUNDED_RECT D2D1_HWND_RENDER_TARGET_PROPERTIES D2D1_MATRIX_3X2_F`, enums (`D2D1_ALPHA_MODE_PREMULTIPLIED`, `D2D1_RENDER_TARGET_TYPE_SOFTWARE/DEFAULT`, `D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE`); `dwrite`: `DWriteCreateFactory`, `IDWriteFactory` (typed `CreateTextFormat CreateTextLayout CreateEllipsisTrimmingSign`), `IDWriteTextFormat` (typed `SetTextAlignment SetParagraphAlignment SetWordWrapping SetTrimming`), `IDWriteTextLayout` (typed `GetMetrics SetMaxWidth`), `IDWriteInlineObject`, `DWRITE_TRIMMING DWRITE_TEXT_METRICS`, enums.
- [ ] **Step 1: Failing tests** in `test_d2d.zig`:
  ```zig
  test "win32 d2d: vtable slot counts" { // ID2D1Factory 17, ID2D1RenderTarget 57, ID2D1DCRenderTarget 58, IDWriteFactory 24, IDWriteTextFormat 28 — recount against d2d1.h / dwrite.h of SDK 10.0.26100 and fix the numbers here if the header differs }
  test "win32 d2d: DC render target draws into a premultiplied DIB" {
      // 64x32 top-down 32bpp DIB, software DC target, Clear(0,0,0,0), FillRectangle(0,0,16,32, opaque red), DrawTextLayout("Ab", Segoe UI 14) at x=24
      // pixel (8,16) == BGRA {0,0,255,255}; pixel (62,2).a == 0; some pixel in x∈[24,60) has a > 0
  }
  ```
- [ ] **Step 2: Run** `LOCK ZIG build test -j2 --build-file pkg/win32/build.zig` → FAIL.
- [ ] **Step 3: Implement**; link `d2d1 dwrite` in the package build.
- [ ] **Step 4: Run** → PASS (all package tests).
- [ ] **Step 5: Commit** `git commit -m "feat(win32): Direct2D and DirectWrite bindings with a headless DC render test"`

### Task 8: IPC transport — pipe server thread, client, per-user pipe name

**Files:** Modify (replace stubs) `src/apprt/win32/ipc/Server.zig`, `src/apprt/win32/ipc/client.zig`, `src/apprt/win32/instance.zig`.

**Interfaces:**
- Consumes: Task 1 (kernel32/advapi32), Task 5 (`protocol.readFrame/writeFrame/pipeName`).
- Produces:
  ```zig
  // instance.zig (Task 20 adds the single-instance decision)
  pub fn currentUserSid(alloc: Allocator) ![]u8;                  // "S-1-5-…" (OpenProcessToken/TokenUser/ConvertSidToStringSidW)
  pub fn defaultClass() []const u8;                               // "com.mitchellh.ghostty", Debug builds "com.mitchellh.ghostty-debug"
  pub fn pipeNameFor(alloc: Allocator, class: ?[]const u8) ![:0]u16; // protocol.pipeName(sid, ProcessIdToSessionId(GetCurrentProcessId()), class orelse defaultClass())
  // ipc/Server.zig
  pub const Pending = struct { request: []u8, response: ?[]u8 = null, done: HANDLE, refs: std.atomic.Value(u8) = .init(2) };
  pub fn start(alloc: Allocator, name: [:0]const u16, msg_hwnd: HWND) error{ AddressInUse, SecurityFailed, Unexpected, OutOfMemory }!*Server;
  pub fn stop(self: *Server) void;               // quit event, CancelIoEx, join, completes queued WM_GHOSTTY_IPC with code 1
  pub fn complete(pending: *Pending, response: []u8) void;   // UI thread: store, SetEvent, release ref
  pub fn release(pending: *Pending, alloc: Allocator) void;  // last ref frees
  // ipc/client.zig
  pub const Error = error{ NoServer, Timeout, BrokenPipe, ProtocolError, OutOfMemory };
  pub fn request(alloc: Allocator, name: [:0]const u16, payload: []const u8, timeout_ms: u32) Error![]u8;
  ```
  Server: first instance with `FILE_FLAG_FIRST_PIPE_INSTANCE` (failure `ERROR_ACCESS_DENIED` → `error.AddressInUse`), `PIPE_TYPE_BYTE|PIPE_READMODE_BYTE|PIPE_REJECT_REMOTE_CLIENTS`, DACL SDDL `D:P(A;;GA;;;<sid>)`; one IPC thread (64 KiB stack): overlapped connect, read one frame (≤ 2 s), post `WM_GHOSTTY_IPC` (lparam = `*Pending`), wait `done` or quit (no timeout; a modal UI keeps dispatching posted messages), write the response frame, flush, disconnect. A second listening instance is created as soon as a client connects, so a concurrent client connects and waits for its turn. Client: `CreateFileW` with `WaitNamedPipeW` retry on `ERROR_PIPE_BUSY` until `timeout_ms`; `ERROR_FILE_NOT_FOUND` → `NoServer`; `GetNamedPipeServerProcessId` → `AllowSetForegroundWindow(pid)` before writing (so the server may raise its new window).
- [ ] **Step 1: Failing tests** (real pipes named `…-test-<pid>-<n>`; a test message-only window plays the UI thread, pumping `WM_GHOSTTY_IPC` and answering `{"echo":<request>}`)
  ```zig
  test "win32 ipc server: request roundtrip" {}
  test "win32 ipc server: second server on the same name is AddressInUse" {}
  test "win32 ipc server: two concurrent clients are both answered in order" {}
  test "win32 ipc client: no server" { // NoServer within 50 ms }
  test "win32 ipc client: busy server times out" { // UI does not answer; client timeout 300 ms → Timeout; stop() afterwards completes the pending request without leaking (testing allocator) }
  test "win32 ipc server: oversized frame is answered with bad_request and disconnected" {}
  test "win32 instance: pipe name has sid, session and class" { // starts with \\.\pipe\ghostty-S-1-5-, contains -<session>-com.mitchellh.ghostty }
  ```
- [ ] **Step 2: Run** `LOCK ZIG build test -j2 -Dtest-filter="win32 ipc"` and `"win32 instance"` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS, 3 consecutive runs (no flake).
- [ ] **Step 5: Commit** `git commit -m "feat(win32): named-pipe IPC server thread and client with per-user/session/class pipe names"`

### Task 9: SplitLayout — rectangles, dividers and drag ratios from a SplitTree (pure)

**Files:** Modify (replace stub) `src/apprt/win32/SplitLayout.zig`.

**Interfaces:**
- Consumes: core `SplitTree` (`nodes`, `zoomed`, `Split{layout, ratio, left, right}`), `geom.Rect`.
- Produces:
  ```zig
  pub fn Layout(comptime Tree: type) type { return struct {
      pub const Leaf = struct { handle: Tree.Node.Handle, view: *Tree.View, rect: geom.Rect, visible: bool };
      pub const Divider = struct { split: Tree.Node.Handle, layout: Tree.Split.Layout, rect: geom.Rect, span: geom.Rect };
      leaves: []Leaf, dividers: []Divider,
      pub fn compute(alloc: Allocator, tree: *const Tree, bounds: geom.Rect, gap: i32) !@This();
      pub fn deinit(self: *@This(), alloc: Allocator) void;
      pub fn leafFor(self: *const @This(), view: *const Tree.View) ?Leaf;
      pub fn dividerAt(self: *const @This(), x: i32, y: i32) ?usize;
  }; }
  pub fn ratioForDrag(layout_kind: enum { horizontal, vertical }, span: geom.Rect, gap: i32, pos: i32, min_px: i32) f16; // clamp so both sides ≥ min_px
  pub fn resizeRatio(direction: enum { left, right, up, down }, amount: u16, bounds: geom.Rect) f16; // GTK split_tree.zig resize: ±amount/width|height, clamp [-1,1]
  pub fn gapPx(dpi: u32) i32;   // geom.scale(4, dpi), min 1
  ```
  Algorithm: a split of span length L gives the left/top child `floor((L - gap) * ratio)` px, the gap, the remainder to the right/bottom child (sizes sum to L exactly); a child size below 0 clamps to 0. Zoomed tree: the zoomed leaf gets `bounds`, every other leaf `visible = false`, no dividers.
- [ ] **Step 1: Failing tests** (local `TestView` with `ref/unref/eql`)
  ```zig
  test "win32 splitlayout: single leaf fills" {}
  test "win32 splitlayout: horizontal 0.5 with gap 4 in 1001 px" { // left w 498, divider x 498 w 4, right x 502 w 499 }
  test "win32 splitlayout: rounding sums to bounds for nested splits" { // 3 levels, random ratios 0.1..0.9 → leaves tile bounds minus dividers exactly, no overlap }
  test "win32 splitlayout: tiny bounds produce no negative sizes" { // bounds 3x3, gap 4 → every w,h ≥ 0 }
  test "win32 splitlayout: zoom hides siblings" {}
  test "win32 splitlayout: divider hit and drag ratio clamp" { // dividerAt on gap → index; ratioForDrag beyond span end → (L-gap-min)/(L-gap) }
  test "win32 splitlayout: resizeRatio matches GTK" { // right 100 in 1000 → 0.1; up 50 in 500 → -0.1; 5000 → 1 }
  ```
- [ ] **Step 2: Run** `LOCK ZIG build test -j2 -Dtest-filter="win32 splitlayout"` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `git commit -m "feat(win32): split layout geometry over the core SplitTree"`

### Task 10: TabStrip — strip geometry, hit testing, drag reorder (pure)

**Files:** Modify (replace stub bodies) `src/apprt/win32/TabStrip.zig`.

**Interfaces:**
- Consumes: Task 2 types (unchanged).
- Produces: real `Metrics.forDpi` (at 96 dpi: `height 40, tab_min_w 72, tab_max_w 240, tab_pad 10, close_w 28, new_tab_w 40, caption_btn_w 46, min_drag_w 48, resize_band 6, drag_threshold 4`, each `geom.scale`d), `Layout.compute`, `Layout.hitTest`, and
  ```zig
  pub fn scrollBy(self: *Layout, delta: i32) void;                         // clamp to [0, overflow]
  pub fn dragUpdate(drag: *Drag, layout: *const Layout, x: i32) ?struct { from: usize, to: usize }; // activates after drag_threshold; target = slot whose centre range holds x - grab_dx + w/2
  pub fn dragOffset(drag: *const Drag, layout: *const Layout, x: i32) i32;   // painter x for the dragged tab
  ```
  Rules: caption buttons (titlebar mode only) at the right edge, close rightmost; `available = width - tab_pad - new_tab_w - min_drag_w - buttons`; tab width `clamp(available / count, tab_min_w, tab_max_w)`; overflow → `tab_min_w`, `scroll` keeps the active tab inside `clip`; `new_tab` follows the last tab (or sits at the clip end on overflow); `caption` = the gap between `new_tab` and the buttons; with `show_tabs == false` in titlebar mode: no tab rects, `title` = `[tab_pad, new_tab.x)`, `new_tab` just left of the buttons. `tab_close` is the right `close_w` of a tab and only hit for the active or hovered tab, and only when the tab is ≥ 2×`close_w` wide. `resize_top` when not maximized and `y < resize_band` (titlebar mode).
- [ ] **Step 1: Failing tests**
  ```zig
  test "win32 tabstrip: metrics scale with dpi" { // 144 dpi → height 60, caption_btn_w 69 }
  test "win32 tabstrip: three tabs in 1200 px titlebar" { // widths 240, tab 0 x 10, buttons [1062..1200], caption between new_tab and 1062 }
  test "win32 tabstrip: overflow keeps active visible" { // 30 tabs, width 800, active 29 → tabs[29] inside clip; scrollBy(-10000) → scroll 0 }
  test "win32 tabstrip: hit test parts" { // caption, each button, tab body vs tab_close (active only), new_tab, resize_top only when !maximized }
  test "win32 tabstrip: narrow tab has no close hit" {}
  test "win32 tabstrip: drag reorder after threshold" { // begin on tab 0, move 3 px → null; move past tab 1 centre → {0,1}; further → {1,2} }
  test "win32 tabstrip: hidden mode has zero height" {}
  ```
- [ ] **Step 2: Run** `LOCK ZIG build test -j2 -Dtest-filter="win32 tabstrip"` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `git commit -m "feat(win32): tab strip layout, hit testing and drag reorder model"`

### Task 11: IPC ops on the UI thread, server start, test oracle

**Files:**
- Modify (replace stub): `src/apprt/win32/ipc/ops.zig`
- Modify: `src/apprt/win32/App.zig` (start the server after the first window: `instance.pipeNameFor(config.class)`; `AddressInUse` → log info and run without one; `msgWndProc` handles `WM_GHOSTTY_IPC`; `terminate` stops it first)
- Create: `test/windows/lib/GhosttyIpc.psm1`, `test/windows/e2e/ipc-state.ps1`

**Interfaces:**
- Consumes: Tasks 5, 6, 8; `input.Binding.Action.parse`, `CoreSurface.performBindingAction`, `CoreApp.findSurfaceByID`.
- Produces:
  ```zig
  pub fn handle(app: *App, alloc: Allocator, request: []const u8) []u8;  // never fails: errors become a response
  pub fn testOpsEnabled() bool;   // env GHOSTTY_WIN32_TEST_IPC == "1" at process start (cached)
  // App fields: server: ?*ipc.Server = null, pub fn serving(self) bool
  ```
  Op semantics: `new-window` → `Overrides.parse(args)` → `Window.create(app, .{ .overrides })`, show, `SetForegroundWindow`; `new-tab` → `core_surface` id (decimal string, `"0"` = focused) → that surface's window `addTab(.{ .parent, .overrides })`, none → new window; `toggle-quick-terminal` → code 1 `quick terminal is not available yet`. Test ops (code 2 `unknown op` unless `testOpsEnabled`): `action` → surface (`0` = `core_app.focusedSurface() orelse app.last_active.activeTab().focusedSurface()`), `performBindingAction(parse(action))`, data `{"performed":bool}`; `dpi` → `window.applyDpi(dpi, null)`; `color-scheme` → `theme.schemeChanged(app, …)`; `state` → data:
  ```json
  {"class":"…","serving":true,"windows":[{"id":1,"hwnd":"0x…","title":"…","dpi":96,"maximized":false,"minimized":false,
    "fullscreen":false,"topmost":false,"decorations":"server","client":[l,t,r,b],"window":[l,t,r,b],"cell":[w,h],
    "progress":null,"active_tab":0,
    "strip":{"mode":"hidden","bounds":[…],"tabs":[[…]],"new_tab":null,"minimize":null,"maximize":null,"close":null,"caption":[…]},
    "tabs":[{"id":1,"title":"…","zoomed":false,"bell":false,
      "surfaces":[{"id":1,"core_id":"…","hwnd":"0x…","rect":[l,t,r,b],"visible":true,"focused":true,"title":"…",
                   "scale":1.0,"scrollbar":{"total":0,"offset":0,"len":0}}]}]}]}
  ```
  (rects in window client coordinates; `client`/`window` in screen coordinates; `core_id` as a string because it is a u64).
  `GhosttyIpc.psm1`: `Get-GhosttyPipeName -Class` (SID from `WindowsIdentity`, session from `Get-Process -Id $PID`), `Invoke-GhosttyIpc -Class -Request <hashtable> [-TimeoutMs 5000]` → parsed response, `Get-GhosttyState -Class`, `Invoke-GhosttyAction -Class -Action <s> [-Surface <id>]`, `Wait-GhosttyState -Class -Predicate {…} [-TimeoutSec]`, `Send-MouseClick -Hwnd -X -Y [-Button left|middle] [-Double]`, `Send-MouseDrag -Hwnd -X -Y (-ToX -ToY | -ToScreenX -ToScreenY) [-Steps 1] [-HoldMs 0] [-EscapeBeforeRelease]` (start in client coordinates of `-Hwnd`, `SendInput` absolute moves in `Steps` increments; only inside a scenario).
- [ ] **Step 1: Failing test** `"win32 ipc ops: unknown and test ops are refused without the env flag"` (`pub var test_ops_override: ?bool = null` in ops.zig, set to false by the test; `handle` with an `undefined` app pointer must not touch it for these requests → `state` and `action` answer code 2; malformed JSON → code 2; `v:2` → code 3).
- [ ] **Step 2: Run** `LOCK ZIG build test -j2 -Dtest-filter="win32 ipc ops"` → FAIL.
- [ ] **Step 3: Implement** ops, server start, the PowerShell module, scenario `ipc-state` (`milestone=M2 order=200`): start Ghostty, `Get-GhosttyState` → 1 window, 1 tab, 1 surface whose `hwnd` equals the child of `$G.Hwnd`; `Invoke-GhosttyAction 'text:echo ipc-ok> %TEMP%\gt-ipc.txt\r'` → file contains `ipc-ok`; a second start with `Start-E2eGhostty -NoTestIpc` → `state` answers code 2.
- [ ] **Step 4: Verify** unit PASS; `LOCK ZIG build -j2`; `E2E -Only ipc-state` → PASS.
- [ ] **Step 5: Commit** `git commit -m "feat(win32): IPC ops on the UI thread, pipe server lifecycle and a test-state oracle"`

### Task 12: Chrome spike — Mica + child swap chains + D2D strip (risk R9)

**Files:** Create `test/windows/chrome-spike/build.zig`, `test/windows/chrome-spike/main.zig`, `test/windows/chrome-spike/run.ps1`.

**Interfaces:**
- Consumes: Task 7 bindings, `pkg/win32` d3d11/dxgi.
- Produces: a decision (written into the commit body and the report; the lead records it as SPEC §18.9): painter backend `dc` (software `ID2D1DCRenderTarget` bound to a `BeginBufferedPaint` DC, premultiplied alpha, grayscale text AA) or `hwnd` (`ID2D1HwndRenderTarget`), or fallback `opaque` (no Mica; R9 fallback). The spike exe: top-level `WS_OVERLAPPEDWINDOW|WS_CLIPCHILDREN`, `WM_NCCALCSIZE` removing the caption (keeping side/bottom frames), `DwmExtendFrameIntoClientArea(top = 40)`, `DWMWA_SYSTEMBACKDROP_TYPE = DWMSBT_MAINWINDOW`, dark mode; a child HWND below the strip with a FLIP_DISCARD swap chain cleared to `#102030` and presented at 60 Hz for 8 s; strip painted by `--variant=none|dc|hwnd` (transparent clear, one rounded tab rect `#102030`, DWrite text "Spike Tab", caption glyphs U+E921/U+E922/U+E8BB in Segoe Fluent Icons); `WM_NCHITTEST` returns `HTMAXBUTTON` over the max glyph.
- [ ] **Step 1:** Build `LOCK ZIG build -j2 --build-file test/windows/chrome-spike/build.zig`.
- [ ] **Step 2:** `run.ps1` (Harness, desktop lock, SKIP when not interactive) runs each variant: foreground the window, `CopyFromScreen` of the window rect to `%TEMP%\chrome-spike-<variant>.png`, sample: strip background pixel ≠ `#000000` and ≠ the child colour (backdrop visible), child pixel `#102030` ±2, text pixels present; `PrivateMemorySize64` after 5 s per variant (`none` is the baseline); hover the max button 1 s and capture again (snap flyout visible = manual look, recorded).
- [ ] **Step 3: Decide** — `dc` if its strip shows the backdrop and text correctly and its RAM delta ≤ 3 MB; else `hwnd` if correct and ≤ 8 MB; else `opaque`. Attach the PNGs and the RAM table to the report.
- [ ] **Step 4: Commit** `git commit -m "test(windows): chrome spike for Mica, child swap chains and Direct2D strip painting"` (body: variant table + decision)

### Task 13: Tabs

**Files:**
- Modify: `src/apprt/win32/Window.zig` (`addTab` honours `window-new-tab-position`; `moveTab`; `showTabs` from `window-show-tab-bar`; title refresh on tab/surface title changes), `src/apprt/win32/actions/tab_actions.zig`, `src/apprt/win32/actions/window_actions.zig` (`set_window_title`)
- Create: `test/windows/e2e/tabs-basic.ps1`, `test/windows/e2e/tabs-keys.ps1`

**Interfaces:**
- Consumes: Task 6 model, Task 11 oracle.
- Produces:
  ```zig
  pub fn moveTab(self: *Window, from: usize, to: usize) void;   // reorder, keep the same tab active, Chrome.invalidate
  pub fn newTabIndex(position: configpkg.Config.WindowNewTabPosition, active: usize, count: usize) usize; // pure: current → active+1, end → count
  pub fn showTabsFor(setting: configpkg.Config.WindowShowTabBar, count: usize) bool; // pure: always → true, never → false, auto → count > 1
  pub fn gotoIndex(target: apprt.action.GotoTab, current: usize, count: usize) ?usize; // pure, GTK window.zig selectTab semantics; null when unchanged
  pub fn moveIndex(amount: isize, current: usize, count: usize) ?usize;  // pure, GTK moveTab (wraps), null when count == 1
  ```
  Handlers: `new_tab` (surface target → its window, parent = target; app target → `app.last_active` else a new window), `close_tab` `this|other|right` (posts `WM_GHOSTTY_CLOSE_TAB` with mode + tab id; the handler confirms once with `CloseKind.tab` if any affected tab `needsConfirmClose`), `goto_tab`, `move_tab`, `set_tab_title` (tab override; empty clears), `set_title` (surface title; refresh tab/window titles when it is the active tab's focused surface), `set_window_title` (window override), `copy_title_to_clipboard` (`clipboard.write` of the surface title; false when none), `pwd` (stored on the surface for `window-subtitle`; returns true). Return `false` whenever nothing changed (performable bindings then reach the shell).
- [ ] **Step 1: Failing tests** `"win32 window: new tab index"`, `"win32 window: show tabs setting"`, `"win32 window: goto tab index matches GTK"` (prev wraps 0→count-1; next wraps; last; n=0 → null; n > count → last; same → null), `"win32 window: move tab wraps"`.
- [ ] **Step 2: Run** `LOCK ZIG build test -j2 -Dtest-filter="win32 window"` → FAIL.
- [ ] **Step 3: Implement**; scenarios (`milestone=M2`): `tabs-basic` (order 210; via `Invoke-GhosttyAction`: `new_tab` ×2 → 3 tabs active 2; `goto_tab:1` → active 0, only tab 0's surface `visible`; `move_tab:1` → tab order ids swapped; `text:title tab-A\r` in tab 0 → tab 0 title `tab-A` and window caption (`GetWindowText`) `tab-A`; `set_tab_title:fixed` → title `fixed`; `close_tab:right` → 1 tab left; `close_tab:this` on the last tab → process exits ≤ 3 s), `tabs-keys` (order 220; real keys `ctrl+shift+t`, `ctrl+tab`, `ctrl+shift+w` with cmd → tab counts 2, active 0/1, 1).
- [ ] **Step 4: Verify** unit PASS; `E2E -Only tabs-basic,tabs-keys` → PASS.
- [ ] **Step 5: Commit** `git commit -m "feat(win32): tabs — new/close/goto/move, titles and tab-bar visibility"`

### Task 14: Splits

**Files:**
- Modify: `src/apprt/win32/Tab.zig` (`layout` through `SplitLayout` with `DeferWindowPos`, hidden leaves `SWP_HIDEWINDOW` + occlusion, cached `split_layout`), `src/apprt/win32/actions/split_actions.zig`
- Create: `test/windows/e2e/splits-basic.ps1`, `test/windows/e2e/split-close.ps1`, `test/windows/e2e/split-many.ps1`

**Interfaces:**
- Consumes: Tasks 6, 9, 11.
- Produces:
  ```zig
  // Tab.zig
  split_layout: ?SplitLayout.Layout(Surface.Tree) = null,
  pub fn split(self: *Tab, at: *Surface, direction: Surface.Tree.Split.Direction) !*Surface; // new surface (context .split, parent at), tree.split(…, 0.5, …), focus it
  pub fn handleOf(self: *const Tab, s: *const Surface) ?Surface.Tree.Node.Handle;
  ```
  Handlers: `new_split` (right/down/left/up), `goto_split` (`previous/next` → `previous_wrapped/next_wrapped`, directions → `.spatial`, as GTK `split_tree.zig`; false when the result is the same surface), `resize_split` (`SplitLayout.resizeRatio` over the container bounds → `tree.resize`), `equalize_splits` (`tree.equalize`), `toggle_split_zoom` (`tree.zoom(handle)` / `zoom(null)`; false with a single leaf). Removal keeps Task 6's `focusAfterRemove`; zoom of a removed leaf is cleared.
- [ ] **Step 1: Failing test** `"win32 tab: split layout hides zoomed-out leaves"` (pure helper `visibilityChanges(old: []const Leaf, new: []const Leaf) []struct{ view, visible }` that drives the occlusion calls; zoom on → others false; off → true).
- [ ] **Step 2: Run** `LOCK ZIG build test -j2 -Dtest-filter="win32 tab"` → FAIL.
- [ ] **Step 3: Implement**; scenarios (`milestone=M2`): `splits-basic` (order 230: `new_split:right`, `new_split:down` → 3 surfaces, rects tile the content area with gaps of `gapPx(dpi)`; `goto_split:left` → focused = first; `resize_split:right,100` → left width +100 ±2; `equalize_splits` → left ≈ half; `toggle_split_zoom` → one visible surface with the full content rect, then back), `split-close` (order 240: `text:exit\r` in the focused split of three → 2 surfaces, focus on a live one, no orphan `cmd.exe` of the closed one after 3 s), `split-many` (order 250: 15 × `new_split` alternating right/down → 16 surfaces, every visible rect w,h ≥ 0, no overlap, no `error` lines in `ghostty.log`, window still answers `WM_NULL` ≤ 2 s).
- [ ] **Step 4: Verify** unit PASS; `E2E -Only splits-basic,split-close,split-many` → PASS.
- [ ] **Step 5: Commit** `git commit -m "feat(win32): splits over the core SplitTree — create, close, goto, resize, equalize, zoom"`

### Task 15: Theme, system colour scheme, config reload, open_config

**Files:**
- Modify (replace stubs): `src/apprt/win32/theme.zig`, `src/apprt/win32/actions/app_actions.zig` (`reload_config`, `config_change`, `open_config`, `color_change`)
- Create: `test/windows/e2e/theme.ps1`, `test/windows/e2e/config-reload.ps1`

**Interfaces:**
- Consumes: Task 6 hooks; Task 11 `color-scheme` op; GTK `application.zig reloadConfig` and `openConfig` (path helper) for semantics.
- Produces:
  ```zig
  pub fn compute(config: *const configpkg.Config, system_dark: bool, active: bool) Palette;  // pure
  pub fn isDark(config: *const configpkg.Config, system_dark: bool) bool;                    // window-theme: light/dark explicit; auto/system → system; ghostty → luminance(background) < 0.5
  var system_dark: ?bool = null;                    // module state, UI thread only; null until first read
  pub fn palette(window: *const Window) Palette;    // compute(app.config, system_dark, window is foreground)
  pub fn applyToWindow(window: *Window) void;       // first call: read util.systemUsesDarkTheme into system_dark and call core_app.colorSchemeEvent once;
                                                    // DWMWA_USE_IMMERSIVE_DARK_MODE = isDark; SetWindowTheme(surface hwnds, "DarkMode_Explorer"|null) for scrollbars; Chrome.invalidate
  pub fn schemeChanged(app: *App, scheme: apprt.ColorScheme) void; // system_dark; core_app.colorSchemeEvent; every surface colorSchemeCallback; applyToWindow all
  // handle: WM_SETTINGCHANGE with lParam string "ImmersiveColorSet" → re-read AppsUseLightTheme → schemeChanged; WM_ACTIVATE → Chrome.invalidate
  ```
  This task does not edit `App.zig` (not its wave).
  Palette values: dark → `text #FFFFFF`, `text_inactive #9E9E9E`, `tab_hover_bg #FFFFFF a=0x10`, `button_hover_bg #FFFFFF a=0x15`, `button_pressed_bg #FFFFFF a=0x0B`, `strip_bg #202020`, `divider #3C3C3C`; light → `text #000000 a=0xE4`, `text_inactive #5C5C5C`, `tab_hover_bg #000000 a=0x0A`, `button_hover_bg #000000 a=0x09`, `button_pressed_bg #000000 a=0x06`, `strip_bg #F3F3F3`, `divider #C8C8C8`; `tab_active_bg` = config `background`; `split-divider-color` overrides `divider`; `mica = (Task 12 decision ≠ opaque) and window-theme ≠ ghostty`, `strip_bg.a = 0` when mica; `window-theme = ghostty` → `strip_bg = window-titlebar-background orelse background`, `text = window-titlebar-foreground orelse foreground`.
  `reload_config` soft → `core_app.updateConfig(app, &app.config)` (app target) or `core.updateConfig` (surface target); hard → `Config.load`, `updateConfig`, then replace `app.config` (old freed after the call). `config_change` (app target) → `applyToWindow` + `layout` for every window. `open_config` → the GTK path helper, `ShellExecuteW("open")`, on `SE_ERR_NOASSOC` (31) `notepad.exe <path>`. `color_change` → `Chrome.invalidate` for the surface's window (window-theme ghostty follows OSC 11).
- [ ] **Step 1: Failing tests** `"win32 theme: dark and light palettes"`, `"win32 theme: ghostty theme follows background luminance"` (bg `#FAFAFA` → light, `#101010` → dark), `"win32 theme: titlebar colours only with window-theme ghostty"`, `"win32 theme: mica clears strip alpha"`.
- [ ] **Step 2: Run** `LOCK ZIG build test -j2 -Dtest-filter="win32 theme"` → FAIL.
- [ ] **Step 3: Implement**; scenarios: `theme` (order 260: two theme files in the sandbox config dir, `gt-light` with `background = #f0f0f0` and `gt-dark` with `background = #101010`, config `theme = light:<abs path gt-light>,dark:<abs path gt-dark>`; `color-scheme` op light → dump background = light value; dark → dark value; `DwmGetWindowAttribute(DWMWA_USE_IMMERSIVE_DARK_MODE)` matches), `config-reload` (order 270: edit the sandbox config `background = #203040`, `Invoke-GhosttyAction reload_config` → dump pixel `#203040`).
- [ ] **Step 4: Verify** unit PASS; `E2E -Only theme,config-reload` → PASS.
- [ ] **Step 5: Commit** `git commit -m "feat(win32): window theme, system colour scheme, config reload and open_config"`

### Task 16: Split divider drag, divider paint, focus-follows-mouse

**Files:**
- Modify: `src/apprt/win32/Tab.zig` (container `WM_ERASEBKGND`/`WM_PAINT` fill = `theme.palette(window).divider`; `WM_SETCURSOR` size cursors over dividers; `WM_LBUTTONDOWN/MOUSEMOVE/LBUTTONUP` drag with capture → `tree.resizeInPlace` + `layout` at most every 16 ms, final layout on release, focus back to the focused surface), `src/apprt/win32/mouse.zig` (`focus-follows-mouse`: `WM_MOUSEMOVE` over an unfocused surface of the foreground window → `SetFocus`; reuse `Surface.class_name`; `refreshCursor` handles the captured surface — M1 Task 24 minors)
- Create: `test/windows/e2e/split-divider-drag.ps1`

**Interfaces:**
- Consumes: Tasks 9, 14.
- Produces: `pub fn dragMinPx(cell: apprt.action.CellSize) i32` in Tab.zig (= 2 cells of the axis, min 16 px).
- [ ] **Step 1: Failing test** `"win32 tab: drag minimum is two cells"` (`{w 9, h 18}` horizontal → 18, vertical → 36; zero cell → 16).
- [ ] **Step 2: Run** `LOCK ZIG build test -j2 -Dtest-filter="win32 tab"` → FAIL.
- [ ] **Step 3: Implement**; scenario `split-divider-drag` (order 280: two splits; `Send-MouseDrag` from the divider centre +150 px → left width +150 ±3; drag to x=1 → left width ≥ `dragMinPx`; config `focus-follows-mouse = true`: move the cursor over the right surface → state `focused` moves without a click).
- [ ] **Step 4: Verify** unit PASS; `E2E -Only split-divider-drag,splits-basic` → PASS.
- [ ] **Step 5: Commit** `git commit -m "feat(win32): split divider drag and paint, focus-follows-mouse"`

### Task 17: Custom frame — caption removal, hit testing, caption buttons, snap layouts, Mica

**Files:**
- Modify (replace stubs): `src/apprt/win32/frame.zig`
- Create: `test/windows/e2e/frame-hittest.ps1`

**Interfaces:**
- Consumes: Task 10 (`hitTest`), Task 12 decision (Mica or opaque), Task 15 palette (`mica`).
- Produces:
  ```zig
  pub fn decorationsFor(setting: configpkg.Config.WindowDecoration) Decorations;   // auto|client → client, server, none
  pub fn ncHitCode(part: TabStrip.Part, x: i32, width: i32, resize_band: i32) u32; // caption→HTCAPTION, minimize→HTMINBUTTON, maximize→HTMAXBUTTON, close→HTCLOSE, resize_top→HTTOPLEFT|HTTOP|HTTOPRIGHT by x, others→HTCLIENT
  pub fn frameInsets(dpi: u32, maximized: bool, decorations: Decorations) struct { left: i32, top: i32, right: i32, bottom: i32 }; // client: restored = {frame, 0, frame, frame}; maximized = frame on all four (SM_CXFRAME + SM_CXPADDEDBORDER at dpi); none = 0; fullscreen handled by placement
  ```
  `handle`: `WM_NCCALCSIZE` (wparam TRUE, decorations client/none) applies `frameInsets` to `rgrc[0]` and returns 0; `WM_NCHITTEST` → `DefWindowProcW` for side/bottom borders, then strip `hitTest` → `ncHitCode`; `WM_NCMOUSEMOVE/WM_NCMOUSELEAVE` hover with `TrackMouseEvent(TME_NONCLIENT|TME_LEAVE)` → `frame.hover`, `Chrome.invalidate`; `WM_NCLBUTTONDOWN` on min/max/close → `pressed`, return 0 (DefWindowProc must not draw classic buttons); `WM_NCLBUTTONUP` on the pressed part → `WM_SYSCOMMAND SC_MINIMIZE | SC_MAXIMIZE/SC_RESTORE | SC_CLOSE`; everything else (caption drag, double-click maximize, right-click system menu) → `DefWindowProcW`; `WM_NCACTIVATE` → invalidate. `apply`: `frame.decorations = decorationsFor(config)`, `DwmExtendFrameIntoClientArea(top = strip height when palette.mica else 0)`, `DWMWA_SYSTEMBACKDROP_TYPE = mica ? DWMSBT_MAINWINDOW : DWMSBT_NONE`, `SetWindowPos(SWP_FRAMECHANGED)`, `window.layout()`. `stripMode`: fullscreen → hidden; client → titlebar; none → tabs_only if `showTabs()` else hidden; server → tabs_only if `showTabs()` else hidden. `WS_SYSMENU` stays (Alt+Space).
- [ ] **Step 1: Failing tests** `"win32 frame: decorations mapping"`, `"win32 frame: hit codes incl. top corners"`, `"win32 frame: insets restored vs maximized at 96 and 144 dpi"` (values from `GetSystemMetricsForDpi`, asserted structurally: maximized top == side inset > 0, restored top == 0).
- [ ] **Step 2: Run** `LOCK ZIG build test -j2 -Dtest-filter="win32 frame"` → FAIL.
- [ ] **Step 3: Implement**; scenario `frame-hittest` (order 290: `SendMessage(WM_NCHITTEST)` at screen points from the state strip rects → caption 2, max 9, min 8, close 20, tab 1, top edge 12 when restored; `toggle_maximize` via action → window rect ⊆ monitor work area expanded by the frame inset and the client rect fully on the monitor; double-click caption point (`Send-MouseClick -Double`) → maximized toggles; Alt+Space → a `#32768` menu window appears, Esc closes it).
- [ ] **Step 4: Verify** unit PASS; `E2E -Only frame-hittest` → PASS; screenshot of the titlebar attached.
- [ ] **Step 5: Commit** `git commit -m "feat(win32): custom DWM frame with own caption buttons, snap layouts hit testing and Mica"`

### Task 18: Chrome painter — tab strip and caption buttons with Direct2D/DirectWrite

**Files:**
- Modify (replace stubs): `src/apprt/win32/Chrome.zig`
- Modify: `src/apprt/win32/App.zig` (`terminate` calls `Chrome.deinitShared()`; `BufferedPaintInit/UnInit` around the loop)
- Create: `test/windows/e2e/chrome-paint.ps1`

**Interfaces:**
- Consumes: Tasks 7, 10, 12 (backend), 15 (palette).
- Produces:
  ```zig
  pub const Shared = struct { d2d: *ID2D1Factory, dwrite: *IDWriteFactory, target: *ID2D1DCRenderTarget (dc backend), formats: per-dpi cache { title, icons } };
  pub fn shared() !*Shared;            // lazy, UI thread
  pub fn paint(window: *Window, hdc: HDC, dirty: geom.Rect) void;  // never fails visibly: on error FillRect with palette.strip_bg and log once
  pub fn drawCaption(target, palette, layout, frame_state)  // internal
  pub fn paintTabChip(hdc: HDC, size: geom.Rect, title: []const u8, palette: theme.Palette, dpi: u32) void; // one active-style tab into a premultiplied DIB (drag ghost, Task 31)
  // drop marker: when window.strip_input.drop_index is set, a 2-px bar in palette.text at that insertion slot
  ```
  Drawing: clear strip to `palette.strip_bg` (transparent with Mica); inactive tabs text `text_inactive`, hovered tab fill `tab_hover_bg`; active tab rounded-top rect (radius `geom.scale(6)`) filled `tab_active_bg` merging into the content; titles DWrite `Segoe UI Variable Text` (fallback `Segoe UI`) 12 DIP, ellipsis trimming, grayscale AA over transparent areas; bell glyph U+EA8F before the title when `tab.bellRinging()` and `bell-features.title`; close glyph U+E8BB on active/hovered tabs; new-tab U+E710; caption buttons min U+E921, max U+E922 / restore U+E923 (`IsZoomed`), close U+E8BB in `Segoe Fluent Icons` (fallback `Segoe MDL2 Assets`) 10 DIP; hover/pressed fills from `frame.hover/pressed`, close hover `close_hover_bg` + `close_hover_text`; dragged tab drawn at `TabStrip.dragOffset`; `title` rect (tabs hidden) shows `window.title_override orelse active tab title`. Format cache keyed by DPI; brushes created per paint (one solid brush, `SetColor`).
- [ ] **Step 1: Failing test** `"win32 chrome: paints a strip into a DIB"` (headless: a fake 600×40 `TabStrip.Layout` with 2 tabs, dark palette with mica, paint into a 32bpp DIB through the same code path as `paint` (`paintInto(hdc, size, inputs)` internal fn): active tab pixel ≈ `tab_active_bg`, a pixel left of tab 0 has alpha 0, close button area of the active tab contains non-transparent pixels).
- [ ] **Step 2: Run** `LOCK ZIG build test -j2 -Dtest-filter="win32 chrome"` → FAIL.
- [ ] **Step 3: Implement**; scenario `chrome-paint` (order 300: 3 tabs; foreground; `CopyFromScreen` of the strip → active tab colour ≈ config background ±6, inactive tab rects contain text pixels (luminance variance > threshold), cursor over the close caption button → its rect is mostly `#C42B1C` ±10; PNG saved to the evidence dir).
- [ ] **Step 4: Verify** unit PASS; `E2E -Only chrome-paint,frame-hittest` → PASS; screenshots (dark + light config) attached and inspected.
- [ ] **Step 5: Commit** `git commit -m "feat(win32): Direct2D tab strip and caption button painting"`

### Task 19: Strip mouse input and inline title editing

**Files:**
- Modify (replace stubs): `src/apprt/win32/strip_input.zig`, `src/apprt/win32/title_edit.zig`, `src/apprt/win32/actions/window_actions.zig` (`prompt_title` → `title_edit.prompt`)
- Create: `test/windows/e2e/tab-strip-mouse.ps1`, `test/windows/e2e/tab-rename.ps1`

**Interfaces:**
- Consumes: Tasks 10, 13, 17, 18.
- Produces:
  ```zig
  // strip_input.handle: WM_LBUTTONDOWN (tab → selectTab + begin drag; tab_close → post WM_GHOSTTY_CLOSE_TAB this; new_tab → addTab(parent = active surface)),
  // WM_MOUSEMOVE (hover + TrackMouseEvent leave; dragUpdate → window.moveTab), WM_LBUTTONUP (end drag, focus active surface),
  // WM_MBUTTONUP on a tab → close that tab, WM_LBUTTONDBLCLK on a tab → title_edit.begin(.tab), WM_MOUSEWHEEL over the strip → strip.scrollBy,
  // WM_MOUSELEAVE → hover nowhere; every handled message ends with the active surface focused
  // title_edit.zig
  pub const Kind = enum { surface, tab, window };
  pub fn begin(window: *Window, kind: Kind, rect: geom.Rect, initial: []const u8) void; // EDIT child of the top-level (ES_AUTOHSCROLL, Segoe UI at dpi), subclassed: Enter commits, Esc / focus loss cancels; commit posts WM_GHOSTTY_TITLE_EDIT_DONE
  pub fn prompt(app: *App, target: apprt.Target, value: apprt.action.PromptTitle) bool;  // tab → over the tab rect; surface/window → over strip.title or caption rect
  // commit: tab → tab.title_override (empty clears), surface → surface title override, window → window.title_override; refreshTitle + invalidate
  ```
- [ ] **Step 1: Failing test** `"win32 title edit: commit text normalisation"` (pure `normalize(text) ?[]const u8`: trims, CR/LF removed, empty → null (clears)).
- [ ] **Step 2: Run** `LOCK ZIG build test -j2 -Dtest-filter="win32 title edit"` → FAIL.
- [ ] **Step 3: Implement**; scenarios: `tab-strip-mouse` (order 310: click `new_tab` → 2 tabs; click tab 0 → active 0 and its surface `focused`; drag tab 0 past tab 1 → order swapped; middle-click tab 1 → 1 tab; after each click `GetFocus`-equivalent state shows a focused surface), `tab-rename` (order 320: double-click tab → an `Edit` child of the window exists; type `renamed` + Enter → tab title `renamed`; again + Esc → unchanged; `Invoke-GhosttyAction prompt_surface_title` → edit appears, Enter commits).
- [ ] **Step 4: Verify** unit PASS; `E2E -Only tab-strip-mouse,tab-rename` → PASS.
- [ ] **Step 5: Commit** `git commit -m "feat(win32): tab strip mouse interaction and inline title editing"`

### Task 20: Single instance and `performIpc`

**Files:**
- Modify: `src/apprt/win32/instance.zig` (decision + forward), `src/apprt/win32/App.zig` (`init` forwards before any window; `run`/`terminate` honour `forwarded`; `performIpc`), `src/config/Config.zig` (core touch point: the new option only)
- Create: `test/windows/e2e/single-instance.ps1`, `test/windows/e2e/ipc-cli.ps1`

**Interfaces:**
- Consumes: Tasks 5, 8, 11.
- Produces:
  ```zig
  // Config.zig: `@"windows-single-instance": WindowsSingleInstance = .detect,` (enum { detect, true, false }; doc: Windows only, see SPEC §18.6)
  // instance.zig
  pub fn shouldForward(mode: configpkg.Config.WindowsSingleInstance, args: []const []const u8, initial_command: bool) bool;
  //   false → false; true → !initial_command; detect → !initial_command and Overrides.forwardable(args)
  pub fn forwardNewWindow(alloc: Allocator, name: [:0]const u16, args: []const []const u8) bool; // client.request new-window, timeout 1000 ms, code ok → true
  // App: forwarded: bool; performIpc: new_window/new_tab/toggle_quick_terminal → client.request on pipeNameFor(target.class or default);
  //      NoServer → stderr "ghostty: no running Ghostty instance (class <c>)" + error.IPCFailed
  ```
  The args forwarded are `global.args()` minus argv[0]; the second process's cwd is not forwarded (SPEC §18.6).
- [ ] **Step 1: Failing tests** `"win32 instance: forward decision"` (detect + `{}` → true; detect + `{"--working-directory=C:\\x"}` → true; detect + `{"--font-size=20"}` → false; any + initial_command → false; false → false).
- [ ] **Step 2: Run** `LOCK ZIG build test -j2 -Dtest-filter="win32 instance"` → FAIL.
- [ ] **Step 3: Implement**; scenarios: `single-instance` (order 330: A started; B = same exe, same sandbox and class, `--working-directory=<sandbox>\Рабочая папка` → B exits 0 ≤ 2 s, A has 2 windows, the new shell's cwd is that dir (echo oracle via `text:cd > %TEMP%\gt-si.txt\r`); B with `--font-size=20` → B keeps running as a separate process (killed at the end); config `windows-single-instance = false` → separate process), `ipc-cli` (order 340: `ghostty.exe +new-window --class=<class>` exits 0 and A gains a window; unknown class → exit ≠ 0 and stderr names the class).
- [ ] **Step 4: Verify** unit PASS; `LOCK ZIG build test -j2 -Dapp-runtime=none -Dtest-filter="config"` PASS; `E2E -Only single-instance,ipc-cli,shell-exit` → PASS.
- [ ] **Step 5: Commit** `git commit -m "feat(win32): single-instance forwarding and performIpc over the named pipe"`

### Task 21: Multiple windows

**Files:**
- Modify: `src/apprt/win32/actions/app_actions.zig` (`new_window`, `close_all_windows`, `goto_window`, `present_terminal`, `quit` posts `WM_GHOSTTY_QUIT_CONFIRM` to `app.last_active` or the first window; no window → `PostQuitMessage` at once), `src/apprt/win32/actions/tab_actions.zig` (`move_tab_to_new_window`), `src/apprt/win32/Window.zig` (`placeInitial`, `create` with `first_tab = false`, `detachTab`)
- Create: `test/windows/e2e/windows-multi.ps1`

**Interfaces:**
- Consumes: Tasks 6, 13; `window-position-x/y`.
- Produces:
  ```zig
  pub fn cascadeOrigin(parent: geom.Rect, work: geom.Rect, step: i32, size: struct { w: i32, h: i32 }) struct { x: i32, y: i32 }; // pure: parent + step, wraps to work.x/y when it would leave the work area
  pub fn placeInitial(self: *Window, parent: ?*Window) void;  // window-position-x/y on the first window; later windows cascade by the caption height from the parent (or last active)
  pub fn detachTab(self: *Window, tab: *Tab) void;           // remove from list without destroying
  ```
  Handlers: `new_window` (surface target → parent = target, context `.window`; app target → no parent), `close_all_windows` (one `CloseKind.all_windows` confirm if any window needs it, then close all confirmed), `goto_window` (`previous/next` over `app.windows` order, wraps, `SetForegroundWindow`; false with one window), `present_terminal` (restore if iconic, `SetForegroundWindow`, select the surface's tab, focus it), `move_tab_to_new_window` (false when the window has one tab; new window `first_tab = false`, `detachTab` + `tab.setWindow(new)` (SetParent of the container), select, show), `quit` (`WM_GHOSTTY_QUIT_CONFIRM`, handled in `Window.zig` → `CloseKind.app` confirm when `core_app.needsConfirmQuit()` → `PostQuitMessage`).
- [ ] **Step 1: Failing test** `"win32 window: cascade wraps inside the work area"`.
- [ ] **Step 2: Run** `LOCK ZIG build test -j2 -Dtest-filter="win32 window"` → FAIL.
- [ ] **Step 3: Implement**; scenario `windows-multi` (order 360: `new_window` → 2 windows, second window origin = first + step; `goto_window:next` → `GetForegroundWindow` changes (interactive only); two tabs in window 1, `move_tab_to_new_window` → 3 windows, the moved surface's `hwnd` unchanged and its shell alive (echo oracle); `close_window` → 2; `close_all_windows` → process exits ≤ 3 s).
- [ ] **Step 4: Verify** unit PASS; `E2E -Only windows-multi,tabs-basic` → PASS.
- [ ] **Step 5: Commit** `git commit -m "feat(win32): multiple windows — create, cascade, goto, present, move tab to new window"`

### Task 22: Placement toggles — maximize, fullscreen, float, decorations, window size

**Files:**
- Modify (replace stub): `src/apprt/win32/placement.zig`; `src/apprt/win32/actions/window_actions.zig` (arms delegate here)
- Create: `test/windows/e2e/maximize-fullscreen.ps1`

**Interfaces:**
- Consumes: Task 17 (`frame.apply`, `stripMode`), `window.placement.initial_size` (stored by `Window.setInitialSize`, Task 6).
- Produces:
  ```zig
  pub fn toggleMaximize(window: *Window) bool;            // IsZoomed ? SW_RESTORE : SW_MAXIMIZE
  pub fn toggleFullscreen(window: *Window) bool;          // save WINDOWPLACEMENT + GWL_STYLE, style WS_POPUP|WS_VISIBLE, monitor rect (MONITOR_DEFAULTTONEAREST), strip hidden; restore exactly
  pub fn toggleDecorations(window: *Window) bool;         // frame.decorations client|server ↔ none, frame.apply
  pub fn setFloat(window: *Window, mode: apprt.action.FloatWindow) bool; // HWND_TOPMOST / NOTOPMOST
  pub fn resetSize(window: *Window) bool;                 // re-apply initial_size; false if none
  pub fn resizeClient(window: *Window, width: u32, height: u32) bool; // ignored (false) when maximized or fullscreen; 0 keeps that dimension
  pub fn applyStartup(window: *Window) void;              // config `maximize` → SW_MAXIMIZE, `fullscreen` → toggleFullscreen after show
  pub fn fullscreenRect(monitor: geom.Rect) geom.Rect;    // pure identity today, tested to pin the contract
  ```
  `macos_non_native*` fullscreen variants behave like `native`.
- [ ] **Step 1: Failing test** `"win32 placement: resize keeps a zero dimension"` (pure `targetClient(current, requested) {w,h}`) and `"win32 placement: fullscreen covers the monitor"`.
- [ ] **Step 2: Run** `LOCK ZIG build test -j2 -Dtest-filter="win32 placement"` → FAIL.
- [ ] **Step 3: Implement**; scenario `maximize-fullscreen` (order 370: `toggle_fullscreen` → window rect == monitor rect, state `strip.mode = hidden`, `fullscreen = true`; again → original rect ±1; `toggle_maximize` twice → maximized then restored; `float_window:on` → `WS_EX_TOPMOST`; `toggle_window_decorations` → `decorations = none`, NCHITTEST at the former close-button point ≠ 20; config `fullscreen = true` start → fullscreen at launch).
- [ ] **Step 4: Verify** unit PASS; `E2E -Only maximize-fullscreen,frame-hittest` → PASS.
- [ ] **Step 5: Commit** `git commit -m "feat(win32): maximize, fullscreen, float, decorations toggle and window size actions"`

### Task 23: Per-monitor DPI for windows, tabs and chrome

**Files:**
- Modify: `src/apprt/win32/Window.zig` (`applyDpi`: update `dpi`, strip metrics, every surface of every tab (hidden ones too) `content_scale` + `contentScaleCallback` **before** `SetWindowPos(suggested)`; maximize re-applied on the new monitor), `src/apprt/win32/dpi.zig`, `src/apprt/win32/Surface.zig` (`WM_DPICHANGED_AFTERPARENT` takes the parent's dpi and skips a repeat; size change applied in the same tick as the scale — M1 Tasks 21 and 29.2 minors)
- Create: `test/windows/e2e/dpi-sim.ps1`

**Interfaces:**
- Consumes: Tasks 17, 18 (metrics, format cache by DPI), Task 11 `dpi` op.
- Produces: `pub fn scaledWindowRect(rect: geom.Rect, old_dpi: u32, new_dpi: u32) geom.Rect` in `dpi.zig` (pure: keeps the top-left, scales size; used when `suggested == null`).
- [ ] **Step 1: Failing tests** `"win32 dpi: scaled window rect"` (`{100,100,800,600}` 96→144 → `{100,100,1200,900}`), `"win32 dpi: content scale for 120/144/192"`.
- [ ] **Step 2: Run** `LOCK ZIG build test -j2 -Dtest-filter="win32 dpi"` → FAIL.
- [ ] **Step 3: Implement**; scenario `dpi-sim` (order 380: 2 tabs (second hidden) and a zoomed split in tab 1; `dpi` op 144 → every surface `scale = 1.5` (hidden ones included), strip `bounds.h = 60`, window `cell` height ≈ 1.5× ±1; dump of the visible surface saved; 192 → 2.0; back to 96 → original cell size; screenshots at 96/144/192 saved for Task 35).
- [ ] **Step 4: Verify** unit PASS; `E2E -Only dpi-sim,resize` → PASS.
- [ ] **Step 5: Commit** `git commit -m "fix(win32): per-monitor DPI updates every surface and the chrome before resizing"`

### Task 24: Resize overlay

**Files:** Modify (replace stub) `src/apprt/win32/resize_overlay.zig`; Create `test/windows/e2e/resize-overlay.ps1`.

**Interfaces:**
- Consumes: `Chrome.shared()` (text), Task 6 hook `notify(surface, cols, rows)`, config `resize-overlay`, `resize-overlay-position`, `resize-overlay-duration`; GTK `resize_overlay.zig` for the text format and `after-first` rule.
- Produces: an owned popup per window (class `GhosttyResizeOverlay`, `WS_POPUP`, `WS_EX_NOACTIVATE|WS_EX_TOOLWINDOW`, never focused) painted with D2D (rounded rect, palette colours), placed per position inside the surface rect, hidden by a window timer after the duration; `pub fn placement(pos: configpkg.Config.ResizeOverlayPosition, surface: geom.Rect, size: struct { w: i32, h: i32 }, margin: i32) geom.Rect` (pure).
- [ ] **Step 1: Failing test** `"win32 overlay: placement for each position"` (center, top-left, top-right, bottom-left, bottom-right, top-center, bottom-center inside a 800×600 surface with margin 8).
- [ ] **Step 2: Run** `LOCK ZIG build test -j2 -Dtest-filter="win32 overlay"` → FAIL.
- [ ] **Step 3: Implement**; scenario `resize-overlay` (order 390: `resize-overlay = always`, `resize-overlay-duration = 1s`; `Set-WindowSize` → a visible `GhosttyResizeOverlay` window of the pid within 1 s, hidden after 2.5 s; focus stays on the surface; `never` → no overlay window ever visible).
- [ ] **Step 4: Verify** unit PASS; `E2E -Only resize-overlay` → PASS.
- [ ] **Step 5: Commit** `git commit -m "feat(win32): resize overlay popup"`

### Task 25: Native scrollbar

**Files:** Modify (replace stub) `src/apprt/win32/scrollbar.zig`; Modify `src/apprt/win32/Surface.zig` (`WS_VSCROLL` at creation when `scrollbar = system`; `WM_VSCROLL` → `scrollbar.handle`), `src/apprt/win32/actions/surface_actions.zig` (`scrollbar` arm); Create `test/windows/e2e/scrollbar.ps1`.

**Interfaces:**
- Consumes: `terminal.Scrollbar` (`total`, `offset`, `len`), `performBindingAction(.{ .scroll_to_row = n })`.
- Produces:
  ```zig
  pub fn update(surface: *Surface, value: terminal.Scrollbar) bool;   // store, SetScrollInfo(SIF_ALL|SIF_DISABLENOSCROLL) — always visible, never reflows (SPEC §18.11)
  pub fn handle(surface: *Surface, wparam: WPARAM) void;               // SB_LINEUP/DOWN ±1, PAGEUP/DOWN ±len, THUMBTRACK/THUMBPOSITION (GetScrollInfo nTrackPos, 32-bit), TOP/BOTTOM → scroll_to_row
  pub fn toScrollInfo(value: terminal.Scrollbar) win32.user32.SCROLLINFO; // pure: nMin 0, nMax total-1 (clamped to i32), nPage len, nPos offset; total > i32 range scales proportionally
  pub fn rowFor(code: u16, track: i32, state: State) ?u64;               // pure
  ```
- [ ] **Step 1: Failing tests** `"win32 scrollbar: scroll info from terminal scrollbar"` (incl. total 10^10 scaled), `"win32 scrollbar: row for each SB code"`.
- [ ] **Step 2: Run** `LOCK ZIG build test -j2 -Dtest-filter="win32 scrollbar"` → FAIL.
- [ ] **Step 3: Implement**; scenario `scrollbar` (order 400: `cmd /c "for /L %i in (1,1,300) do @echo %i"` via `text:` → state `scrollbar.total > len`; `PostMessage(surface, WM_VSCROLL, SB_TOP)` → `offset == 0` and the dump shows the first lines; `scrollbar = never` → no `WS_VSCROLL` in the surface style).
- [ ] **Step 4: Verify** unit PASS; `E2E -Only scrollbar,resize` → PASS.
- [ ] **Step 5: Commit** `git commit -m "feat(win32): native always-visible scrollbar bound to the terminal scrollback"`

### Task 26: Bell and taskbar progress

**Files:** Modify (replace stubs) `src/apprt/win32/bell.zig`, `src/apprt/win32/taskbar.zig`; Modify `src/apprt/win32/actions/window_actions.zig` (`ring_bell`, `progress_report`); Create `test/windows/e2e/bell-progress.ps1`.

**Interfaces:**
- Consumes: `bell-features` (`system`, `audio`, `attention`, `title`; `border` deferred to M3 with DComp overlays), `bell-audio-path`; `terminal.osc.Command.ProgressReport`; Task 18 bell glyph.
- Produces:
  ```zig
  pub fn ring(surface: *Surface) bool;   // title: surface.bell_ringing = true (cleared on focus, Task 6) + refreshTitle prefix "🔔 " on the window caption + invalidate;
                                         // attention: FlashWindowEx(FLASHW_TRAY|FLASHW_TIMERNOFG) when the window is not foreground;
                                         // system: MessageBeep(MB_OK); audio: PlaySoundW(path, SND_ASYNC|SND_FILENAME|SND_NODEFAULT) (WAV only, volume ignored — SPEC §18.13)
  pub fn setProgress(window: *Window, report: terminal.osc.Command.ProgressReport) bool; // ITaskbarList3 (created lazily after the "TaskbarButtonCreated" message), state map remove→NOPROGRESS, set→NORMAL, error→ERROR, indeterminate→INDETERMINATE, pause→PAUSED; value 0–100; stored in window.taskbar.progress
  pub fn tbpfFor(state) u32;             // pure
  // taskbar.handle: RegisterWindowMessageW("TaskbarButtonCreated") → (re)create the interface and re-apply the stored progress
  ```
  Progress is per window: the last report from any surface of the window wins; a surface closing with progress set clears it when it was the reporter. Mirror GTK's timeout behaviour for stale reports if `gtk/class/surface.zig` has one.
- [ ] **Step 1: Failing tests** `"win32 taskbar: progress state map"`, `"win32 bell: caption prefix"` (pure `bellTitle(alloc, title, ringing) []u8`).
- [ ] **Step 2: Run** `LOCK ZIG build test -j2 -Dtest-filter="win32 taskbar"` and `"win32 bell"` → FAIL.
- [ ] **Step 3: Implement**; scenario `bell-progress` (order 410, Git Bash config, SKIP without Git Bash: `printf '\a'` from an unfocused tab → that tab `bell = true`, caption starts with the bell; select it → cleared; `printf '\e]9;4;1;40\a'` → state `progress {state:"set", value:40}`; `\e]9;4;0\a` → `progress null`).
- [ ] **Step 4: Verify** unit PASS; `E2E -Only bell-progress` → PASS.
- [ ] **Step 5: Commit** `git commit -m "feat(win32): bell features and taskbar progress"`

### Task 27: TaskDialog confirmations

**Files:** Modify `src/apprt/win32/dialogs.zig` (`confirmCloseKind` → `TaskDialogIndirect`; `confirm` used by clipboard prompts → TaskDialog too); Create `test/windows/e2e/close-confirm.ps1`.

**Interfaces:**
- Consumes: Task 1 (`comctl32`), callers from Tasks 6/13/21 (unchanged signatures).
- Produces: `confirmCloseKind(owner, kind)`: title "Ghostty", main instruction per kind ("Close this terminal?", "Close this tab?", "Close this window?", "Close all windows?", "Quit Ghostty?"), content "A process is still running. Closing will end it.", custom buttons `&Close` (id 100) and `Cancel` (IDCANCEL, default), `TDF_POSITION_RELATIVE_TO_WINDOW`; returns true only for 100. `confirm(owner, title, body)` keeps its signature (Yes/No custom buttons `&Allow`/`&Cancel`, default Cancel). Falls back to the M1 `MessageBoxW` when `TaskDialogIndirect` fails. Every call site already checks that its window survived the dialog loop; the file header documents the posted-message rule (M1 Task 18 minor).
- [ ] **Step 1: Failing test** `"win32 dialogs: task dialog config is valid"` (pure `buildConfig(owner, kind, buttons) TASKDIALOGCONFIG`: `cbSize == @sizeOf(TASKDIALOGCONFIG)`, `nDefaultButton == IDCANCEL`, two buttons, flags contain `TDF_POSITION_RELATIVE_TO_WINDOW`).
- [ ] **Step 2: Run** `LOCK ZIG build test -j2 -Dtest-filter="win32 dialogs"` → FAIL.
- [ ] **Step 3: Implement**; scenario `close-confirm` (order 420: `text:ping -t 127.0.0.1\r`; `PostMessage(WM_CLOSE)` → a dialog owned by the pid appears; Esc → window stays; again → Alt+C → window closes, no orphan `PING.EXE`; shell exit behind the dialog: `text:timeout /t 4 >nul & exit\r`, post `WM_CLOSE` at once → dialog; wait 6 s (the shell exits and its tab closes behind the dialog), then Esc → no crash, process gone ≤ 5 s; `close_tab` with two tabs and a running ping → a dialog appears and Esc keeps both tabs).
- [ ] **Step 4: Verify** unit PASS; `E2E -Only close-confirm,paste-confirm` → PASS.
- [ ] **Step 5: Commit** `git commit -m "feat(win32): TaskDialog close and clipboard confirmations"`

### Task 28: Notification-area icon and last-window lifecycle

**Files:**
- Create: `src/apprt/win32/tray.zig`, `test/windows/e2e/tray.ps1`, `test/windows/e2e/quit-after-last.ps1`
- Modify: `src/apprt/win32/App.zig` (`tray: tray.State`, created after the first window, destroyed in `terminate`; `windowDestroyed` → `lastWindowAction`; `startQuitTimer` doc fixed — M1 Task 14 minor; `test { _ = tray; }`), `src/config/Config.zig` (core touch point: `quit-after-last-window-closed` default `false` on Windows, Linux unchanged; doc sentence for Windows), `src/apprt/win32/actions/app_actions.zig` (`config_change` → `tray.sync`), `src/apprt/win32/ipc/ops.zig` (state gains `"tray":{"visible":bool}`; a state with no window answers `"windows":[]`)

**Interfaces:**
- Consumes: Task 1 (tray and menu bindings), Task 20 (pipe server, forwarding), Task 21 (`new_window`, `present_terminal`, quit flow), core `quit_timer` start/stop.
- Produces:
  ```zig
  // tray.zig
  pub const State = struct { hwnd: ?HWND = null, visible: bool = false, taskbar_created: u32 = 0, icon: ?HICON = null };
  pub fn init(app: *App) !void;   // hidden top-level tool window, class GhosttyTray (never shown; receives "TaskbarCreated"), icon from the exe resources, tip "Ghostty"
  pub fn sync(app: *App) void;    // visible ⇔ !config.@"quit-after-last-window-closed": NIM_ADD + NIM_SETVERSION(NOTIFYICON_VERSION_4) / NIM_DELETE
  pub fn deinit(app: *App) void;  // NIM_DELETE, DestroyIcon, DestroyWindow
  pub const menu_new_window: u32 = 1;
  pub const menu_quit: u32 = 2;
  pub fn clickAction(windows: usize) enum { present_last, new_window };  // pure; left click = NIN_SELECT / NIN_KEYSELECT
  // WM_GHOSTTY_TRAY (LOWORD(lParam) = event): NIN_SELECT|NIN_KEYSELECT → clickAction; WM_CONTEXTMENU → SetForegroundWindow(tray hwnd),
  //   TrackPopupMenuEx(TPM_RETURNCMD|TPM_RIGHTBUTTON) with "New Window", separator, "Quit"; WM_COMMAND with the menu ids does the same (e2e posts it);
  //   "TaskbarCreated" → NIM_ADD again. Quit: no window → PostQuitMessage; else the Task 21 quit flow (confirms when needed)
  // App.zig
  pub fn lastWindowAction(quit_after: bool, delay_ms: ?u32) enum { quit_now, quit_timer, stay };  // pure
  //   windowDestroyed with no window left: quit_now → PostQuitMessage; quit_timer → the M1 timer (core's quit_timer start/stop still honoured);
  //   stay → nothing (tray icon + pipe keep the process reachable)
  ```
- [ ] **Step 1: Failing tests** `"win32 app: last window policy"` (`(true, null)` → quit_now; `(true, 1000)` → quit_timer; `(false, null)` and `(false, 1000)` → stay), `"win32 tray: click action"` (0 windows → new_window; 2 → present_last).
- [ ] **Step 2: Run** `LOCK ZIG build test -j2 -Dtest-filter="win32 app"` and `"win32 tray"` → FAIL.
- [ ] **Step 3: Implement**; scenarios (`milestone=M2`): `tray` (order 430, `Start-E2eGhostty -KeepDefaultQuit`: state `tray.visible = true`; close the only window → process alive after 3 s and state `windows = []`; `PostMessage(<GhosttyTray window of the pid>, WM_GHOSTTY_TRAY, 0, NIN_SELECT)` → a window appears ≤ 2 s; close it; `PostMessage(WM_COMMAND, menu_new_window)` → a window; a second launch of the same class forwards → 2 windows; `PostMessage(WM_COMMAND, menu_quit)` with idle shells → process exits ≤ 3 s), `quit-after-last` (order 440: `quit-after-last-window-closed = true` → `tray.visible = false` and closing the last window ends the process ≤ 3 s; with `quit-after-last-window-closed-delay = 2s` the process is alive at 1 s and gone by 4 s; a `new-window` IPC inside the delay keeps it running).
- [ ] **Step 4: Verify** unit PASS; `LOCK ZIG build test -j2 -Dapp-runtime=none -Dtest-filter="config"` PASS; `E2E -Only tray,quit-after-last,single-instance,shell-exit` → PASS.
- [ ] **Step 5: Commit** `git commit -m "feat(win32): notification-area icon; keep running after the last window by default on Windows"`

### Task 29: Tab-close process semantics (Windows Terminal behaviour)

**Files:**
- Modify: `src/Command.zig` (Windows: `killTree` → `killChild`: terminate the direct child only; drop the job walk and `shouldKill`; keep the job object and `jobProcessIds` for process listing (M4 pane queries); keep `fileSubsystem` only if still used), `src/termio/Exec.zig` (`killCommand` calls `killChild`, then closes the pseudo console right away so `ClosePseudoConsole` sends `CTRL_CLOSE_EVENT` to the console clients attached to that surface; the M1 drain-to-EOF bound is unchanged)
- Modify: `test/windows/e2e/close-tree.ps1`, `test/windows/e2e/_common.ps1` (`Assert-NoSurvivors -Except [int[]]`; `Start-SurvivorConsole($G)` types `cmd //c start "gt-survivor-<hex>" cmd /k` into Git Bash and returns the new `cmd.exe` pid, found by its command line; `Stop-Survivor` kills it and its `conhost.exe`, always called from `finally`)
- Create: `test/windows/e2e/tab-close-tree.ps1`

**Interfaces:**
- Consumes: M1 `Command` job and ConPTY close path (`src/pty.zig`), Task 11 oracle, Task 13 tabs.
- Produces: `pub fn killChild(self: *Command) !void` (Windows) and the behaviour of SPEC §18.14: closing a surface (split, tab or window) ends its shell and every console client attached to its pseudo console; programs with their own console (`start cmd`, `start python x.py`), detached processes and GUI programs keep running.
- [ ] **Step 1: Failing tests** (`-Dapp-runtime=none`)
  ```zig
  test "windows command: killChild ends only the direct child" { // cmd /c "start /min cmd /k & ping -n 30 127.0.0.1" without a pseudo console: after killChild the child is gone, the started cmd.exe (own console) is alive; the test terminates it }
  test "windows exec: closing the pseudo console ends attached console clients" { // pty + cmd /k ping -n 60 127.0.0.1; ping pid from jobProcessIds; killChild + close the pseudo console → ping.exe gone within 6 s }
  ```
- [ ] **Step 2: Run** `LOCK ZIG build test -j2 -Dapp-runtime=none -Dtest-filter="windows command"` and `"windows exec"` → FAIL.
- [ ] **Step 3: Implement**; scenarios: `close-tree` (stays `milestone=M1`, rewritten: ping in Git Bash plus `Start-SurvivorConsole`; close the window → `bash.exe`, `ping.exe` and the surface's `OpenConsole.exe`/`conhost.exe` gone ≤ 6 s; the survivor `cmd.exe` alive; `Assert-NoSurvivors -Except <survivor, its conhost>`; survivor stopped in `finally`), `tab-close-tree` (order 450, M2, scenario config `confirm-close-surface = false`: two tabs; ping and a survivor started in tab 1; `close_tab:this` on tab 1 → its shell and ping gone ≤ 6 s, tab 0's shell alive (echo oracle), survivor alive, then stopped).
- [ ] **Step 4: Verify** unit PASS; `E2E -Only close-tree,tab-close-tree,close-while-streaming,shell-exit` → PASS.
- [ ] **Step 5: Commit** `git commit -m "fix(windows): closing a tab ends its shell and pseudo-console clients only (Windows Terminal semantics)"`

### Task 30: Re-parent-safe present target (swap chain recreated after a move)

**Files:** Modify `src/renderer/D3D11.zig` (`PresentTarget.generation`; the render thread recreates its swap chain when the generation changed), `src/apprt/win32/Surface.zig` (`present_generation` field, `bumpPresentTarget`).

**Interfaces:**
- Consumes: M1 `SwapChain.init/deinit`, `PresentTarget`, core `Surface.refreshCallback`.
- Produces:
  ```zig
  // D3D11.zig
  pub const PresentTarget = struct { hwnd: *anyopaque, size: *const std.atomic.Value(u64), id: u32,
      generation: *const std.atomic.Value(u32) };  // bumped by the apprt after the HWND changed parents
  // swap chain getter (render thread): generation != swap_chain_generation → deinit the swap chain (all back-buffer refs
  // released first) and create a new one for the same hwnd before the frame uses it; MakeWindowAssociation again
  // Surface.zig
  present_generation: std.atomic.Value(u32) = .init(0),
  pub fn bumpPresentTarget(self: *Surface) void;  // UI thread: fetchAdd(1, .release), then core_surface.refreshCallback() so a frame follows
  ```
  Re-parenting never touches DXGI on the UI thread (SPEC §5); the render thread does the recreation (SPEC §18.16).
- [ ] **Step 1: Failing tests** (WARP, hidden test HWNDs)
  ```zig
  test "d3d11 swapchain: generation bump recreates the swap chain after SetParent" { // child of parent A presents; SetParent(child, B); bump; next frame: new swap chain object, present OK, back-buffer readback == target }
  test "d3d11 swapchain: no recreation without a bump" { // 5 frames, same swap chain object }
  ```
- [ ] **Step 2: Run** `LOCK ZIG build test -j2 -Dapp-runtime=none -Dtest-filter="d3d11 swapchain"` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Verify** PASS; `LOCK ZIG build -j2`; `E2E -Only windows-multi,render` → PASS (`move_tab_to_new_window` still renders).
- [ ] **Step 5: Commit** `git commit -m "feat(d3d11): recreate the swap chain on the render thread after the surface window is re-parented"`

### Task 31: Tab drag state machine and drag ghost

**Files:** Modify (replace stubs) `src/apprt/win32/tab_drag.zig`, `src/apprt/win32/drag_ghost.zig`.

**Interfaces:**
- Consumes: `TabStrip.Metrics` (`drag_threshold`), `Chrome.paintTabChip` (Task 18), Task 1 layered-window bindings.
- Produces:
  ```zig
  // tab_drag.zig (pure; all coordinates in screen pixels)
  pub const Point = struct { x: i32, y: i32 };
  pub const Hit = union(enum) { none, strip: struct { window: u32, index: usize } };  // index = insertion slot under the cursor
  pub const Event = union(enum) { move: struct { pt: Point, hit: Hit }, release, cancel };  // cancel = Esc or capture lost
  pub const Outcome = union(enum) { click, reorder: struct { from: usize, to: usize }, move_to: struct { window: u32, index: usize },
      tear_off: Point /* new window origin */, move_window: Point /* single-tab source */, cancelled: struct { restore_index: usize } };
  pub const Feedback = struct { live_reorder: ?struct { from: usize, to: usize } = null, ghost: ?Point = null,
      marker: ?struct { window: u32, index: usize } = null, done: ?Outcome = null };
  pub const Machine = struct {
      pub fn begin(source_window: u32, tab: usize, tab_count: usize, press: Point, grab: Point /* cursor offset inside the tab */,
          strip_origin: Point /* source strip top-left */, threshold: i32, detach_margin: i32) Machine;
      pub fn feed(self: *Machine, ev: Event) Feedback;
  };
  pub fn detachMargin(dpi: u32) i32;   // geom.scale(24, dpi)
  ```
  States `pressed → in_strip → detached`. `pressed` stays until the cursor moves beyond `threshold`; then over the own strip → `in_strip` (live reorder feedback, as Task 10's drag rules), elsewhere → `detached`. `in_strip` → `detached` when the hit is not the own strip and the cursor is more than `detach_margin` outside the source strip bounds; `detached` over the own strip → back to `in_strip`. `detached`: `ghost = pt - grab`; over another window's strip → `marker`. Release: `pressed` → `click`; `in_strip` → `reorder` (the final from/to, possibly equal); `detached` over another strip → `move_to`; `detached` over nothing → `tear_off(pt - grab - strip_origin_offset)` or `move_window(...)` when `tab_count == 1`. `cancel` in any drag state → `cancelled` with the index the tab had at `begin`.
  ```zig
  // drag_ghost.zig
  pub fn show(app: *App, title: []const u8, size: geom.Rect, at: tab_drag.Point) void; // one per process: WS_POPUP, WS_EX_LAYERED|WS_EX_TRANSPARENT|WS_EX_TOOLWINDOW|WS_EX_NOACTIVATE|WS_EX_TOPMOST
  pub fn moveTo(at: tab_drag.Point) void;   // SetWindowPos without activation
  pub fn hide() void;
  // content: Chrome.paintTabChip into a premultiplied 32bpp DIB, UpdateLayeredWindow(ULW_ALPHA, constant alpha 0xD8);
  // WS_EX_TRANSPARENT keeps it out of WindowFromPoint; WM_DPICHANGED (moving across monitors) repaints at the new dpi
  ```
- [ ] **Step 1: Failing tests**
  ```zig
  test "win32 tab drag: press and release without moving is a click" {}
  test "win32 tab drag: below threshold stays pressed" {}
  test "win32 tab drag: reorder inside the own strip" { // live_reorder {0,1}, release → reorder {0,1} }
  test "win32 tab drag: leaving the strip by the margin detaches and shows the ghost" { // y = strip bottom + margin + 1, hit none → ghost = pt - grab }
  test "win32 tab drag: back over the own strip re-attaches" {}
  test "win32 tab drag: drop on another window's strip" { // marker {7, 1}; release → move_to {7, 1} }
  test "win32 tab drag: drop outside tears off, single tab moves the window" {}
  test "win32 tab drag: Esc restores the original index" { // after live reorder 0→2, cancel → cancelled{restore_index 0} }
  ```
- [ ] **Step 2: Run** `LOCK ZIG build test -j2 -Dtest-filter="win32 tab drag"` → FAIL.
- [ ] **Step 3: Implement** (the ghost has no unit test beyond compiling; Task 32's scenario shows it).
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `git commit -m "feat(win32): tab drag state machine and layered drag ghost"`

### Task 32: Tab tear-off and re-dock across windows

**Files:**
- Modify: `src/apprt/win32/strip_input.zig` (drag through `tab_drag.Machine` with capture on the source window; cross-window hit testing; ghost; Esc), `src/apprt/win32/Window.zig` (`insertTab`, `createForTearOff`), `src/apprt/win32/Tab.zig` (`setWindow` also rescales surfaces when the dpi differs and calls `bumpPresentTarget` on each surface)
- Create: `test/windows/e2e/tab-drag.ps1`

**Interfaces:**
- Consumes: Tasks 19 (strip input), 21 (`detachTab`, `move_tab_to_new_window` path), 30 (`bumpPresentTarget`), 31 (machine, ghost), Task 18 (drop marker from `strip_input.State.drop_index`).
- Produces:
  ```zig
  // strip_input.zig
  pub fn hitAt(app: *App, pt: tab_drag.Point) tab_drag.Hit;
  //   WindowFromPoint → GetAncestor(GA_ROOT) → must be one of app.windows (class GhosttyWindow of this process; other processes are never targets)
  //   → ScreenToClient → that window's strip.hitTest → insertion index = slot whose centre is right of x (count when past the last tab)
  // drag start (threshold passed): SetCapture(source hwnd); SetFocus(source hwnd) so Esc reaches it (WM_SETFOCUS redirect to the surface is
  //   suppressed while dragging); WM_KEYDOWN VK_ESCAPE → cancel; WM_CAPTURECHANGED → cancel; WM_LBUTTONUP → release
  // feedback: live_reorder → window.moveTab; marker → target window strip_input.drop_index + Chrome.invalidate (cleared on leave);
  //   ghost → drag_ghost.show/moveTo/hide
  // outcomes: move_to → source.detachTab, target.insertTab(tab, index), tab.setWindow(target), select it, SetForegroundWindow(target);
  //   tear_off → createForTearOff(app, origin, source size) + detachTab/insertTab/setWindow + show;
  //   move_window → SetWindowPos(source) to the origin; cancelled → moveTab back to restore_index;
  //   afterwards: source with no tab → requestClose(true) (last-window rule of Task 28 applies only if no window remains); focus the moved tab's surface
  // Window.zig
  pub fn insertTab(self: *Window, tab: *Tab, index: usize) void;           // clamp index, select, layout, refreshTitle
  pub fn createForTearOff(app: *App, origin: tab_drag.Point, size: struct { w: i32, h: i32 }) !*Window; // first_tab = false, placed at origin (dpi of the monitor there)
  // Tab.zig
  pub fn setWindow(self: *Tab, window: *Window) void;  // SetParent(container); every surface: window = window; dpi differs → content scale + contentScaleCallback; bumpPresentTarget
  ```
  The core surface, its pty and its child process never restart: only HWND parents change.
- [ ] **Step 1: Failing test** `"win32 strip input: insertion index from x"` (pure `insertionIndex(tabs: []const geom.Rect, x: i32) usize`: left of tab 0 centre → 0, between centres → 1, past the last → count).
- [ ] **Step 2: Run** `LOCK ZIG build test -j2 -Dtest-filter="win32 strip input"` → FAIL.
- [ ] **Step 3: Implement**; scenario `tab-drag` (order 460, cmd config, interactive only: window A with tabs T0, T1; record the `cmd.exe` pids of both shells (process tree) and T1's surface `hwnd`; `Send-MouseDrag` from T1's centre to 250 px below A's bottom edge in 25 steps, holding 300 ms before release → 2 windows, each with one tab, T1's surface `hwnd` unchanged, both `cmd.exe` pids alive and unchanged, echo oracle in T1 works, a `GhosttyDragGhost` window was visible mid-drag and is hidden after; drag T1 from the new window onto A's strip right of T0 → 1 window with tabs [T0, T1], the new window gone, pids unchanged; drag T0 out and press Esc before releasing → still 1 window, order unchanged).
- [ ] **Step 4: Verify** unit PASS; `E2E -Only tab-drag,tab-strip-mouse,windows-multi` → PASS.
- [ ] **Step 5: Commit** `git commit -m "feat(win32): drag tabs out into new windows and onto other windows"`

### Task 33: M2 end-to-end run

**Files:** none planned; bug notes only (the lead files 34.n).

- [ ] **Step 1:** `LOCK ZIG build -j2`; `E2E -Milestone all -EvidenceDir %TEMP%\m2-evidence` (Debug). Then `LOCK ZIG build -j2 -Doptimize=ReleaseFast --prefix zig-out-rf`; `$env:GHOSTTY_E2E_EXE` = the RF exe; `E2E -Milestone all` again.
- [ ] **Step 2:** For every FAIL write a bug note (scenario, build, symptom, log excerpt, evidence path). `LOCK ZIG build test -j2 -Dtest-filter="win32 "` and `--build-file pkg/win32/build.zig` → record counts.
- [ ] **Step 3: Commit** only if scenario scripts needed fixes of their own: `git commit -m "test(windows): M2 e2e stabilisation"`.

### Task 34.n: Integration fix (template, one bug per task)

**Files:** exactly the files the bug note names (lead assigns; ≤ 3 parallel only with disjoint files).

- [ ] **Step 1:** Reproduce with the failing scenario; pure-logic bugs get a failing unit test first.
- [ ] **Step 2:** Fix; unit filter + scenario → PASS (SKIP noted when not interactive).
- [ ] **Step 3: Commit** `git commit -m "fix(win32): <bug summary>"`

### Task 35: RAM rows, screenshots, M2 acceptance

**Files:**
- Modify: `test/windows/measure-ram.ps1` (scenarios `tabs`, `splits`, `windows`, `close-10`, driven by `Invoke-GhosttyAction`, no keyboard input), `docs/windows/ram-baseline.csv`, `test/windows/README.md` (M2 runner, IPC module, scenario list, tray and tab-close behaviour), `docs/windows/SPEC.md` §17 (M2 marked done with the commit, any scope moved during execution)

**Interfaces:**
- Produces rows (ReleaseFast, hardware adapter): `tabs` = (1 window + 10 tabs − one-surface) / 10 per tab; `splits` = 10 splits in one tab, per split; `windows` = 5 windows, per extra window; `close-10` = open 10 tabs, close them, wait 30 s, private bytes vs before opening.
- [ ] **Step 1:** `LOCK ZIG build -j2 -Doptimize=ReleaseFast --prefix zig-out-rf`; run the four scenarios + `one-surface`.
- [ ] **Step 2: Gate** (SPEC §14): per tab/split ≤ +10 MB, per window ≤ +15 MB, close-10 within +10 % of the pre-open value. Over → DONE_WITH_CONCERNS with numbers; no tuning here.
- [ ] **Step 3: Screenshots:** one window with 3 tabs and 4 splits, dark and light, at 96/144/192 dpi (from `dpi-sim` evidence) + a maximized and a fullscreen capture → evidence dir; list paths in the report.
- [ ] **Step 4: ARM64:** `LOCK ZIG build -Dtarget=aarch64-windows-gnu -j2` → record (MSVC ARM64 in M6 CI).
- [ ] **Step 5: Exit checklist** (below) recorded in the report; commit `git commit -m "test(windows): M2 RAM rows, screenshots and acceptance record"`.

---

## M2 exit checklist

1. `LOCK ZIG build -j2` and ReleaseFast build succeed; `pkg/win32` tests pass; `-Dtest-filter="win32 "` passes 3× in a row; `-Dtest-filter="d3d11 "` (`-Dapp-runtime=none`) and `config` pass.
2. `win32 actions: every Action.Key is classified` green: 43 implemented, 25 deferred with milestone, 2 unsupported (counts as in Task 3; the test pins them).
3. `E2E -Milestone all` green on Debug and on ReleaseFast (M1 18 + M2 scenarios); SKIPs only for a non-interactive desktop and re-run by the owner.
4. Single instance: second launch exits 0 ≤ 2 s and the new window shows ≤ 1.5 s (ReleaseFast); `+new-window` works; e2e instances never touched the owner's Ghostty (class isolation).
5. RAM rows `tabs`, `splits`, `windows`, `close-10` within SPEC §14 targets.
6. Screenshot set (Task 35 Step 3) inspected by the lead.
7. Owner manual checklist (record PASS/FAIL per line): tray icon present after closing the last window, left click opens a window, menu New Window / Quit work, icon returns after restarting Explorer; `start cmd` from a tab survives closing that tab; dragging a tab to a window on a monitor with another scale renders it at that scale; snap layouts flyout on hovering maximize; Aero snap by dragging the caption to an edge; moving a window between monitors of different scale; Mica visible behind the strip with "Transparency effects" on and solid with it off; switching Windows light/dark in Settings repaints the strip and conditional themes; Alt+Tab/taskbar titles follow the active tab; taskbar progress during a `winget`-style OSC 9;4 run.
8. Upstream rebase of `windows` onto upstream main (lead), M2 changelog for the owner.

## M1 carry-over assignment

| M1 ledger item | Assigned |
|---|---|
| T14 last-window close always quits; `quit-after-last-window-closed` + delay unreachable; `startQuitTimer` doc | Task 28 |
| T14 local `RegGetValueW`; T24 local `SystemParametersInfoW`/`GetClassNameW`; T26 local `EnumClipboardFormats`; T27 local kernel32 externs in `SwapChain.zig` | Task 1 |
| T14 `terminate()` spin on failing `DestroyWindow`, `Window.create` errdefer pop not keyed by pointer | Task 6 |
| T14 wakeup re-arm untested | Task 3 |
| T21 WM_CLOSE `wparam == 1` marker spoofable; `Surface.close` confirm bypasses `confirming_close`; dead child `SIZE_MINIMIZED` branch | Task 6 |
| T21 DPI scale applied after `SetWindowPos`; T29.2 `contentScaleCallback` before the coalesced size | Task 23 |
| T18 modal dialog re-enters the window procedure | Task 27 (+ posted-message rule, Global Constraints) |
| T24 duplicated surface class name; `refreshCursor` skips a captured surface | Task 16 |
| T22 dump readback + file I/O under the shared context lock | Task 4 |
| T28 all-SKIP run exits 0 | Task 4 |
| T30 CSV commit stamp, CRLF, README double blank line, `AdapterDesc` layout assert | Task 4 |
| T5 SharedDeps links Win32 libs for lib-vt consumers | Task 1 |
| T19 owner question (console processes killed on tab close) | answered by the owner (Windows Terminal semantics) → Task 29 |
| T13 `systemExists` OOB, T19 pid-reuse race in `killTree` ("fix in final wave") | M1 final review (not M2) |
| T23 keyboard, T26 clipboard, T12 font, T11/T20 shader, T16 logging, T8/T9 renderer minors | stay deferred (M3 input/clipboard/font/shader polish, M5 logging) |

## Self-review notes

- Spec coverage (SPEC §17 M2 as amended): custom frame + Mica + snap (12, 17, 18), tabs incl. reorder/rename (10, 13, 19), splits (9, 14, 16), multi-window (21), placement toggles (22), DPI (23), theme/colour scheme/config reload (15), scrollbar (25), bell + taskbar progress (26), resize overlay (24), TaskDialog confirmations (27), tray + last-window lifecycle (28), tab-close process semantics (29), tab tear-off/re-dock with re-parent-safe swap chains (30, 31, 32), IPC + single instance + `performIpc` (5, 8, 11, 20), action coverage (3), RAM/screenshots (35). Deferred by design: unfocused-split dimming and `bell-features=border` (M3 DComp overlays), readonly badge (M3), everything in Task 3's deferred list.
- Every wave re-checked: ≤ 3 tasks, disjoint `Files:` including the hot files table; stubs created in W1 carry every cross-task signature so later waves never edit another task's file.
- Type names used across tasks: `TabStrip.Layout/Metrics/Part/Mode/Drag`, `SplitLayout.Layout(Tree)`, `geom.Rect`, `theme.Palette/Color`, `frame.State/Decorations`, `placement.State`, `scrollbar.State`, `taskbar.State`, `resize_overlay.State`, `Overrides`, `protocol.Request/Response/Code`, `Server.Pending`, `client.Error`, `Window/Tab/Surface.CreateOptions`, `dialogs.CloseKind` — defined once (Task 2, 5, 6, 8, 9, 10) and only consumed elsewhere.
