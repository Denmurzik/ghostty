# Recon: apprt contract and GTK/macOS structure (for `src/apprt/win32`)

Repo state: upstream main, `minimum_zig_version = "0.17.0"` (build.zig.zon:6), version 1.3.2-dev. All paths are relative to the repo root. LOC counts come from `wc -l`.

## 0. TL;DR

- There is NO interface/trait file for an apprt. The contract is duck-typed at comptime. `core` calls `apprt.runtime.App` and `apprt.runtime.Surface` and fails to compile if a member is missing. The authoritative spec is "everything `src/Surface.zig`, `src/App.zig`, `src/main_ghostty.zig`, `src/renderer/*` and `src/global.zig` call on those types", listed in section 1.
- A Win32 apprt must add a `.win32` arm to about 14 `switch (build_config.app_runtime)` sites (section 1.1).
- Rendering has changed in this upstream. The renderer no longer draws into a toolkit-owned GL area. It draws into an offscreen `Target`, exports an `ExportedFrame` (`OpenGL.zig:277,301`), pushes it into a single-slot "latest wins" queue, and posts `Surface.Message.redraw`. The apprt then does `performAction(.render)` and pulls the frame with `renderer.takeFrame()` (`generic.zig:1060-1072`, `opengl/Frame.zig:56-84`, `gtk/class/render_surface.zig:157`). The D3D11 backend can follow this model or present to a DXGI swap chain on the render thread. Both are legal because the apprt is the only consumer.
- `SplitTree(V)` is shared core code (`src/datastruct/split_tree.zig`, 2529 LOC including 18 tests). The GTK apprt uses it and the macOS app does not (Swift reimplements it in `macos/Sources/Features/Splits/SplitTree.swift`, 1413 LOC). Win32 should use it.
- GTK apprt is 24,692 LOC of Zig plus 1,458 LOC of Blueprint UI, CSS and XML. Roughly 40-45% of it is Linux-only plumbing that Win32 does not need (section 7).
- Recommendation: a native Zig apprt, not a host app over the embedded C API (section 4).

## 1. The apprt contract

### 1.1 Selection and build wiring

- `src/apprt.zig:43-50`: `pub const runtime = switch (build_config.artifact) { .exe => switch (app_runtime) {.none, .gtk}, .lib => embedded, .wasm_module => browser }`. `apprt.App = runtime.App`, `apprt.Surface = runtime.Surface` (lines 52-53).
- `src/apprt/runtime.zig:5-24`: `enum Runtime { none, gtk }`. `default()` returns `.gtk` for linux/freebsd and `.none` for every other OS, including Windows. A `.win32` member and a Windows default are needed here.
- `src/build/Config.zig:26,202-206`: field `app_runtime`, option `-Dapp-runtime`. `src/build_config.zig:41` exposes `build_config.app_runtime`.
- `build.zig:211,279,332` treats `app_runtime != .none` as "produce and install an exe". `build.zig:~218-236` treats `.none` as "produce the libghostty glue lib" (`ghostty-internal.dll` and `ghostty-internal-static.lib` already exist for Windows, `build.zig:231-233`). `build.zig:297` has `assert(config.app_runtime == .none)` (run step). `build.zig:332` is the valgrind step.
- `src/build/GhosttyExe.zig:44-48` already has a Windows branch: `exe.subsystem = .windows` and `dist/windows/ghostty.rc` (also `ghostty.manifest`, `ghostty.ico`). Consequence: a GUI-subsystem exe has no stderr console. `src/global.zig:398` defaults `Logging.stderr = app_runtime != .none`, so a file or OutputDebugString log sink is needed.
- `src/build/SharedDeps.zig:666-672`: EGL linked only for gtk. `SharedDeps.zig:691-694`: `switch (app_runtime) { .none, .gtk => addGtk }`. A `.win32` arm is needed (link user32, dwmapi, d3d11, dxgi, imm32/msctf, shell32, ole32, and so on).
- `switch (build_config.app_runtime)` sites that need a `.win32` arm. Most are `getGObjectType = ... .none => void` and could become `else => void`:
  - `src/apprt.zig:44`
  - `src/apprt/structs.zig:47,53,216`
  - `src/apprt/action.zig:733`
  - `src/apprt/surface.zig:174`
  - `src/config/Config.zig:4892` (apprt-specific defaults), `:9346`, `:10068`
  - `src/datastruct/split_tree.zig:1327`
  - `src/font/face.zig:61`
  - `src/input/Binding.zig:995`
  - `src/terminal/mouse.zig:84`
  - `src/build/SharedDeps.zig:691`
  - Equality checks that may need review: `src/config/Config.zig:8948` (translated command palette is gtk-only), `src/cli/version.zig:49`, `src/global.zig:398`.
- Renderer side: `src/renderer/backend.zig` has `enum { opengl, metal }`, with the default `.metal` on Darwin and `.opengl` elsewhere. `src/renderer.zig:39-42` maps it to `Metal` or `OpenGL`. `GraphicsAPI.Device` is app-scoped (`renderer.zig:45`). A `d3d11` member and a Windows default are needed. The existing OpenGL backend is EGL-based (`opengl/Device.zig`, default platform `EGL_PLATFORM_SURFACELESS_MESA`) and has no Windows story.

### 1.2 Process entry (exe path)

`src/main_ghostty.zig:42-114`:
1. `global.init`. If a CLI `+action` was given, run it and exit. Otherwise:
2. `const app: *App = try App.create(alloc)` (core App).
3. `var app_runtime: apprt.App = undefined; try app_runtime.init(app, .{});`. The `.{}` is the "opts" struct. GTK declares `opts: struct {}` (`gtk/App.zig:30-43`).
4. Optional `if (@hasDecl(apprt.App, "startQuitTimer")) app_runtime.startQuitTimer();` (line 111).
5. `try app_runtime.run();` blocks until quit. `defer app_runtime.terminate()`.
- `src/main_ghostty.zig:77-95` prints a usage banner when `app_runtime == .none`. `global.zig:219` calls `apprt.runtime.resourcesDir(alloc)` (module-level decl, required). `cli/new_window.zig:240`, `cli/new_tab.zig:253` and `cli/toggle_quick_terminal.zig:46` call the static `apprt.App.performIpc(alloc, target, action, value) !bool`. Win32 can return `false`.
- The apprt, not core, loads the config. GTK does `CoreConfig.load(alloc)` (`gtk/class/application.zig:276`) and again on hard reload (`:2808`). The `Config` is passed to `core_app.updateConfig`.

### 1.3 `apprt.App` members core relies on

| Member | Called from | Notes |
|---|---|---|
| `init(*App, *CoreApp, opts)`, `run()`, `terminate()` | main_ghostty.zig:105-114 | `run()` must pump messages and call `core_app.tick(rt_app)` each iteration. GTK: `application.zig:566-575`, a manual `MainContext.iteration` loop with `tick` after every iteration. |
| `wakeup()` | `App.zig:595-599` (`App.Mailbox.push`) | Callable from ANY thread. Must make `tick` run soon on the UI thread. GTK: `glib.MainContext.wakeup` (`application.zig:1317`). Win32: `PostMessage`/`PostThreadMessage` of a private WM, or `MsgWaitForMultipleObjectsEx` plus `SetEvent`. |
| `performAction(target: apprt.Target, comptime action: Action.Key, value: Action.Value(action)) !bool` | ~100 call sites in `Surface.zig`/`App.zig` | Returns true if handled. false means "not performed". For key-binding actions this makes `performBindingAction` return false and the keypress falls through to the pty (`Surface.zig:5450-5660`). Unimplemented actions should log and return false (GTK: `application.zig:808-824`). |
| `static performIpc(alloc, ipc.Target, comptime ipc.Action.Key, value) !bool` | cli/*.zig | `none.zig` and `embedded.zig:367-378` return false. GTK uses D-Bus (`gtk/ipc/*`, 356 LOC). |
| `startQuitTimer()` (optional) | main_ghostty.zig:111 | Because the app starts with 0 surfaces. |
| `config: Config` field (optional) | `App.zig:367` (`core_app.keyEvent` reads `rt_app.config.keybind.set`) | Needed ONLY if Win32 calls `core_app.keyEvent` for global/app-scoped keybinds (e.g. `RegisterHotKey`). GTK does not. Embedded does (`embedded.zig:149`, kept in sync in `performPreAction` on `config_change`, `embedded.zig:344-355`). |
| `keyboardLayout()` (optional) | `Surface.zig:3415` | macOS-only (`Surface.zig:3403`). Ignore. |
| `redrawInspector(surface)` | gtk/embedded only | No core caller found. Optional. |
| `pre_exec`, `post_fork` (module decls, optional) | `Command.zig:145,154`, `termio/Exec.zig:1056` | Linux cgroup stuff. Skip. |
| `CAPI` (module decl, optional) | `main_c.zig:42` | Embedded only. |

### 1.4 `apprt.Surface` members core relies on

All are in `gtk/Surface.zig` (109 LOC, thin wrapper over the GObject) and `embedded.zig:447-1258`.

| Member | Used by core for |
|---|---|
| `core() *CoreSurface`, `rtApp() *App` | `App.zig:211,228,245` (`addSurface`/`deleteSurface` call `rt_surface.rtApp().performAction(.app,.quit_timer,...)`) |
| `close(process_active: bool)` | `Surface.zig:884` (`needsConfirmQuit()` is passed). The apprt shows its own confirm UI and then tears down the tab/split. |
| `getTitle() ?[:0]const u8` | `Surface.zig:1045` |
| `getContentScale() !ContentScale` | `Surface.zig:511,1924,1969,2111,2216,2654`. Value is DPI/96 as x,y f32. |
| `getSize() !SurfaceSize` | `Surface.zig:540`. Pixel size of the render area, excluding chrome. |
| `getCursorPos() !CursorPos` | `Surface.zig:1257,2873,3732...`. Pixels, relative to the surface, origin top-left. |
| `supportsClipboard(Clipboard) bool` | `Surface.zig:4187`. `standard`, `selection`, `primary`. Win32: standard only (selection could be emulated). |
| `clipboardRequest(Clipboard, ClipboardRequest) !ClipboardReadResult` | `Surface.zig:6261`. Async. Result is `started`, `unavailable` or `unsupported`. After `started` the apprt MUST later call `core.completeClipboardRequest(req, CompleteClipboard{contents, available, confirmed, remember})` or `core.denyClipboardRequest(req)` (`Surface.zig:5980-6167`). Request types: paste, osc_52_read/write, kitty_read/write, list (`structs.zig:75-148`). `completeClipboardRequest` may return UnsafePaste/UnauthorizedPaste, and the apprt then runs a confirmation dialog and re-calls with `confirmed=true`. |
| `setClipboard(Clipboard, []ClipboardContent{mime,data}, confirm: bool) !void` | `Surface.zig:2316,2433,5220,5956,6051,6128`. `confirm` means show the OSC 52 write prompt. |
| `defaultTermioEnv() !std.process.Environ.Map` | `Surface.zig:668`. Start from `global.environMap()` and strip apprt env vars. |
| `renderDeviceOptions() !renderer.Device.Options` | `Surface.zig:566`. Called once, by the first surface only. Creates the app-scoped `renderer.Device` (`App.device`). OpenGL options = `{display: ?*egl.Display}`. D3D11 will want adapter/LUID plus HWND-derived info. |
| `deinit()` | Called by GTK glue. Optional for core. |
| `cgroup()`, `redrawInspector()` | GTK-only. Skip. |

Stable-address rule: `core_surface.init(alloc, &config, core_app, rt_app, rt_surface)` (`Surface.zig:477-483`) stores `*rt_surface`, so the apprt surface must live at a stable address (heap or HWND userdata).

Renderer seam (`src/renderer/Options.zig`): the renderer receives `rt_surface: *apprt.Surface` and `device`. `renderer.Thread.threadMain_` calls `renderer.threadEnter(surface)` on the render thread (`Thread.zig:222`, `generic.zig:904`, `OpenGL.zig:201`). OpenGL ignores the surface. Metal reads `rt_surface.platform`/`content_scale` (`Metal.zig:79-82`). A D3D11 renderer can read an HWND or DXGI swap chain off the apprt surface here. Other renderer-to-apprt hooks are `displayRealized`/`displayUnrealized` (`generic.zig:979-1013`, `Surface.zig:2584-2598`, "unrealized" = no GPU resources until the window exists), `Surface.draw()` for a synchronous main-thread draw (`Surface.zig:925`, "renderers must support drawFrame from the main thread so they can update during resize"), and `reportPresentationHealth(.unhealthy)` (`Surface.zig:961`, `render_surface.zig:168`, a fallback request from GPU to CPU-readback presentation).

### 1.5 Calls the apprt must make INTO core (`*CoreSurface`, in `src/Surface.zig`)

| Function (line) | Trigger and notes |
|---|---|
| `init`/`deinit` (477/829) | Create/destroy. `Surface.init` itself does `performAction` for `cell_size`, `size_limit`, `set_title`, `initial_size` (728-820, 1916-1990). So the apprt window must exist and accept those before init returns. It spawns the renderer and IO threads (754/762). |
| `displayRealized()`/`displayUnrealized()` (2584/2590) | Window shown or destroyed, so the renderer can build or drop GPU state. |
| `sizeCallback(SurfaceSize)` (2600) | WM_SIZE. Pixel size. Ignores unchanged sizes. |
| `contentScaleCallback(ContentScale)` (3765) | WM_DPICHANGED. |
| `keyCallback(input.KeyEvent) !InputEffect` (2792) | `{action press/release/repeat, key (physical), mods, consumed_mods, composing, utf8, unshifted_codepoint}` (`input/key.zig:16-48`). Returns `.ignored/.consumed/.closed`. `keyEventIsBinding` (2748) tests without side effects. |
| `textCallback([]u8)` (3426) | Raw text insertion, no key protocol. |
| `preeditCallback(?[]u8)` (2669) | IME composition string. Null clears. Core does not reset preedit by itself. |
| `imePoint()`/`imePointScaled()` (2215/2222) | Core to apprt query: cursor rect for positioning the IME candidate window. |
| `focusCallback(bool)` (3466), `occlusionCallback(bool)` (3437) | WM_SETFOCUS/KILLFOCUS, minimize/visibility. Occlusion pauses rendering. |
| `mouseButtonCallback(state, button, mods) !bool` (3918) | Returns consumed. |
| `cursorPosCallback(CursorPos px, ?Mods)` (4678) | Mouse move in surface pixels. |
| `scrollCallback(xoff, yoff, ScrollMods)` (3584) | `ScrollMods.precision` (`input/mouse.zig:89`) for hi-res wheels. |
| `mousePressureCallback` (4614) | Force-touch. macOS only. |
| `mouseReportingActive()`, `mouseCaptured()`, `hasSelection()`, `selectionString()` (3807/3909/2160/2167) | Decide context menu or selection logic in the apprt. |
| `colorSchemeCallback(light/dark)` (4871) and `core_app.colorSchemeEvent(rt_app, scheme)` (`App.zig:416`) | Theme change. This triggers `reload_config{soft=true}` back to the apprt. |
| `performBindingAction(input.Binding.Action) !bool` (4941) | Menu or UI to action (e.g. `.scroll_to_row`, `.search`, `.navigate_search`, `.end_search`, `.prompt_surface_title`). |
| `completeClipboardRequest`/`denyClipboardRequest` (6017/6167) | See the clipboard table above. |
| `updateConfig(*const Config)` (1804) | Per-surface config. |
| `needsConfirmQuit()` (995) | Before closing. |
| `activateInspector()`/`deactivateInspector()` (934/972), `.inspector` field | Inspector UI lifetime. |
| `setFontSize` (2536), `pwd(alloc)` (2180), `getProcessInfo` (6678), `dumpText` (2030) | Zoom UI, working-dir inheritance, tab titles, "foreground pid". |

Calls into `*CoreApp` (`src/App.zig`): `create/destroy/init/deinit` (80/153/119/136), `tick(rt_app)` (164, drains the app mailbox, 64-slot BlockingQueue), `updateConfig(rt_app, *Config)` (172, which sends `config_change` back), `addSurface`/`deleteSurface` (202/222), `focusEvent(bool)` (337), `keyEvent(rt_app, KeyEvent)` (352, app/global bindings only), `colorSchemeEvent` (416), `performAction/performAllAction` (444/494), `needsConfirmQuit` (264), `focusedSurface` (256), `findSurfaceByID` (543), `newWindow` (319), `closeSurface` (308).

### 1.6 Input value types the apprt must produce

- `input.Mods` (shift/ctrl/alt/super plus lock bits plus sided bits), `input.Key` physical enum. Mapping table: `src/input/keycodes.zig` already has a Windows column (`native_idx = 3 // win`, line 13, raw table at 176+). Core `keycodes.entries` provides `native -> Key`, so scancode to Key is available. Verify it is the set-1 scancode with the extended bit. `embedded.zig:122-125` shows the lookup idiom.
- `unshifted_codepoint` and `consumed_mods`: GTK computes them from keyvals (`gtk/key.zig`, 655 LOC, and `class/surface.zig:1395-1450`). Win32 equivalent: `ToUnicodeEx` with and without shift/ctrl state, dead-key tracking via IME/WM_DEADCHAR.

## 2. Actions (`src/apprt/action.zig`, 1089 LOC)

Mechanics: `Action` is a tagged union (`action.zig:63-511`). `Key` is a `c_int` enum (368-438) that is ABI-synced with `include/ghostty.h` (adding an action means editing both). `Target` is `union{app, surface:*CoreSurface}` (16). Access the apprt surface via `target.surface.rt_surface`. Dispatch reference: `gtk/class/application.zig:689-830`. Implementations: `Action` struct at `application.zig:2094-3250`.

Legend: M = macOS-only, G = GTK-only, X = cross-platform. Tier 1 = needed for a usable terminal, 2 = expected features, 3 = optional or can return false.

| Action (payload) | GTK does | Win32 equivalent | Tier / scope |
|---|---|---|---|
| quit | `app.quit()` (617) | `PostQuitMessage` after confirm | 1 X |
| new_window | new `Window` (2554) | new top-level HWND + first tab | 1 X |
| new_tab | `Action.newTab` (2524) into the window of target (app target means a new window) | add tab to window | 1 X |
| close_tab (`CloseTabMode` this/other/right) | adw TabView close pages | remove tab(s) | 1 X |
| new_split (`SplitDirection` right/down/left/up) | `split_tree.newSplit` (2502) | `SplitTree.split` plus a new child HWND/region | 1 X |
| close_all_windows | unimplemented | close every window | 3 M |
| toggle_maximize | `gtk.Window.maximize` | `ShowWindow(SW_MAXIMIZE/RESTORE)` | 2 X |
| toggle_fullscreen (`native`, `macos_non_native*`) | `fullscreen()` | borderless on monitor rect (save/restore placement) | 2 X (non-native variants M) |
| toggle_tab_overview | `adw.TabOverview` | skip or return false | 3 G |
| toggle_window_decorations | `setDecorated` | toggle WS_CAPTION or custom frame | 3 G |
| toggle_quick_terminal | layer-shell window (`application.zig:3055`, `window.zig:1320`, `winproto`) | topmost popup HWND, slide animation, `RegisterHotKey` | 2 X (exists on mac, G) |
| toggle_command_palette | `command_palette.zig` (785) | own popup list. Items come from core `input/command.zig` and `command-palette-entry` | 2 X |
| toggle_visibility | unimplemented | show/hide all windows | 3 M |
| toggle_background_opacity | unimplemented | `SetLayeredWindowAttributes`/composition alpha | 3 M |
| move_tab (`amount: isize`, wraps) | `adw` reorder | reorder | 2 X |
| goto_tab (`GotoTab` previous/next/last/index) | select page | select tab | 1 X |
| goto_split (`GotoSplit` previous/next/up/left/down/right) | `Tree.goto` (core, uses `spatial`) | `SplitTree.goto` | 1 X |
| goto_window (previous/next) | cycle toplevels | cycle HWNDs | 2 X |
| resize_split (`{amount:u16, direction}`) | `Tree.resize` | same | 2 X |
| equalize_splits | `Tree.equalize` | same | 2 X |
| toggle_split_zoom | `Tree.zoom` | same | 2 X |
| present_terminal | raise window, select tab, focus (`application.zig:2712`) | `SetForegroundWindow` plus select tab (beware focus-stealing rules) | 2 X |
| size_limit (`min_w,min_h,max_w,max_h` px) | `window.sizeLimit` (3015) | handle `WM_GETMINMAXINFO` | 1 X |
| reset_window_size | unimplemented | restore the last `initial_size` | 3 X |
| initial_size (`{w,h}` px) | `window.setDefaultSize` (2406) | `SetWindowPos` before first show | 1 X |
| cell_size (`{w,h}` px) | store for resize increments | resize snapping in `WM_SIZING` (optional) | 2 X |
| scrollbar (`terminal.Scrollbar` total/offset/len) | `surface_scrolled_window` (2905) | custom overlay scrollbar or `SetScrollInfo`. On drag, call `performBindingAction(.scroll_to_row)` | 1 X |
| render | `surface.redraw()` (2826) | invalidate and present latest frame (or no-op if the render thread presents directly) | 1 X |
| inspector (`toggle/show/hide`) | `inspector_widget`/`inspector_window` | window with imgui (section 3) | 3 X |
| show_gtk_inspector | `gtk.Window.setInteractiveDebugging` | n/a (return false) | G |
| render_inspector | unimplemented | redraw the inspector window | 3 X (M uses it) |
| export_terminal_io (`contents` slice) | save-file dialog (2126) | `GetSaveFileName` | 3 X |
| desktop_notification (`title`, `body`) | `gio.Notification` (2234) plus per-surface `desktop_notifications.zig` (358) | toast (WinRT, needs AUMID) or `Shell_NotifyIcon` balloon | 2 X |
| set_title / set_tab_title / set_window_title (`title`) | tab/window titles | `SetWindowText` plus tab label | 1 X |
| prompt_title (`surface/tab/window`) | `title_dialog.zig` (236) | small modal edit box | 3 X |
| pwd (`pwd`) | store on surface (for inheritance) | store | 2 X |
| mouse_shape (`terminal.MouseShape`, 34 members) | `gdk.Cursor` by name | `SetCursor(LoadCursor(IDC_*))` map | 1 X |
| mouse_visibility (visible/hidden) | hide cursor | `ShowCursor` / blank cursor on that HWND | 2 X |
| mouse_over_link (`url`; empty means leave) | tooltip/status popover | status label bottom-left or tooltip | 2 X |
| renderer_health (`healthy/unhealthy`) | unimplemented in app (handled via surface child exited overlay) | show warning bar | 3 X |
| open_config (`os_open`/`new_window`) | opens file via portal (2619) | `ShellExecuteW` "open" on config path | 2 X |
| quit_timer (`start/stop`) | `glib.timeoutAdd` (2702, `quit-after-last-window-closed-delay`) | `SetTimer`/timer queue then `PostQuitMessage` | 1 X |
| float_window (`on/off/toggle`) | unimplemented | `SetWindowPos(HWND_TOPMOST)` | 3 M (trivial on Win32) |
| secure_input (`on/off/toggle`) | unimplemented | none | 3 M |
| key_sequence (`trigger` or `end`) | `key_state_overlay.zig` (342) | text overlay/status | 2 X |
| key_table (`activate(name)/deactivate/deactivate_all`) | same overlay | same | 2 X |
| color_change (`{kind,r,g,b}`) | unimplemented | (optionally retint chrome) | 3 X |
| reload_config (`{soft}`) | `application.zig:2785` (load, `updateConfig`) | same: `Config.load`, `core_app.updateConfig` | 1 X |
| config_change (`*const Config`, valid only during the call) | applies CSS/props (2218) | copy needed fields: padding, colors, tab bar, titlebar, opacity, blur | 1 X |
| close_window | close the target's window | `WM_CLOSE` | 1 X |
| ring_bell | audio and visual per `bell-features` (2898) | `MessageBeep`/PlaySound, `FlashWindowEx`, title bell icon | 2 X |
| selection_changed | no-op ("no a11y consumer") | UI Automation (later) | 3 X |
| undo / redo | unimplemented | none | 3 M |
| check_for_updates | unimplemented | none | 3 M |
| open_url (`kind` unknown/text/html/osc8, `url` bytes) | portal OpenURI (`portal/OpenURI.zig`, 599) or fallback (2081) | `ShellExecuteW`. SECURITY: `unknown` and `osc8` are untrusted and must be validated, no executable or UNC launching without a check (`action.zig:939-979`). `os/open.zig:36` already maps windows to `rundll32 url.dll,FileProtocolHandler` | 1 X |
| show_child_exited (`{exit_code, runtime_ms}`) | `surface_child_exited.zig` (195) bar | in-surface message bar with Close | 1 X |
| progress_report (`terminal.osc.Command.ProgressReport`) | progress bar in the surface | taskbar progress via `ITaskbarList3::SetProgressValue` plus optional in-surface bar | 2 X |
| show_on_screen_keyboard | `activateOsk` | invoke touch keyboard (`TabTip.exe`/`ITipInvocation`) | 3 G |
| command_finished (`{exit_code ?u8, duration}`) | notify per `notify-on-command-finish*` (3202) | toast/flash | 3 X |
| start_search (`needle`) / end_search | `search_overlay.zig` (495) | find-bar overlay. It drives core with `performBindingAction(.search / .navigate_search / .end_search)` | 2 X |
| search_total (`?usize`) / search_selected (`?usize`) | updates overlay counters | same | 2 X |
| readonly (`on/off`) | badge | badge | 3 X |
| copy_title_to_clipboard | `setClipboard` | same | 3 X |
| move_tab_to_new_window | detach page | detach tab into new HWND | 3 X |
| resize_window (`{w,h}`, 0 means keep) | `window.resizeWindow` (2874) | `SetWindowPos` (ignore if split or fullscreen) | 3 X |

Note: `Action.Key` currently has 70 members. A Win32 apprt needs about 30 for a credible v1 (tier 1 plus the cheap tier 2).

## 3. How GTK structures things (Win32 reuse map)

Object tree: `Application` (`class/application.zig`, 3320 LOC; owns `Config`, runs the loop) to `Window` (`window.zig`, 2380; AdwApplicationWindow with `adw.TabView`/`TabBar`/`TabOverview`) to `Tab` (`tab.zig`, 588) to `SplitTree` widget (`split_tree.zig`, 1567; renders `datastruct.SplitTree(Surface)` via nested `GtkPaned`) to `Surface` (`surface.zig`, 4535) containing `RenderSurface` (461) and overlays.

| Area | GTK implementation (LOC) | Reusable core vs GTK-specific | Win32 notes |
|---|---|---|---|
| Windows and tabs | `window.zig` 2380, `tab.zig` 588, `ui/1.4/window.blp` 344 | All GTK/libadwaita. Core only sends tab and window actions and `window-*`/`tabs-*` config. | Custom top-level (or DWM-extended frame) plus own tab strip. Largest UI item. Needs `WM_DPICHANGED`, `WM_GETMINMAXINFO`, `DwmExtendFrameIntoClientArea`, `DWMWA_USE_IMMERSIVE_DARK_MODE`, caption colour (`window-titlebar-*`), Win11 Mica/acrylic via `DWMWA_SYSTEMBACKDROP_TYPE` for `background-blur`/`background-opacity`. |
| Splits | `split_tree.zig` 1567 + 2 blp | Data structure is shared core: `src/datastruct/split_tree.zig` (generic over a View with `ref/unref/eql`). It is immutable and persistent: `init, clone, split, remove, resize, equalize, zoom, goto, spatial, locate, iterator, deepest`. GTK only maps it to widgets. GObject registration at line 1327 is gtk-only. | Use it unchanged. `Surface.Tree = SplitTree(GtkSurface)` (`class/surface.zig:67`). Win32: define `View = Win32Surface` with refcount and lay out child regions from `ratio` and `layout` (`split_tree.zig:101-110`). Divider drag calls `Tree.resize`/`resizeInPlace`. Zoom is `tree.zoomed` handle. |
| Surface widget | `surface.zig` 4535, `render_surface.zig` 461, `surface_scrolled_window.zig` 245, `ui/1.0/surface.blp` 439, `scale.zig` 186 | The input to core translation is toolkit-specific. Core owns the semantics. | Child HWND per surface (or one top-level plus hit-testing) with its own wndproc. `scale.zig` snaps texture origin to device pixels: relevant for fractional DPI. |
| Keyboard and IME | `gtk/key.zig` 655, `GtkIMMulticontext` in `surface.zig:669,1249-1330` | Translation GTK to `input.KeyEvent` is GTK-only. | `WM_KEYDOWN/UP`, `WM_SYSKEY*`, `WM_CHAR`/`WM_UNICHAR`, `ImmGetCompositionString` or TSF for preedit, `WM_IME_STARTCOMPOSITION/COMPOSITION`, candidate window placement from `imePoint()`. |
| Mouse / scroll | `surface.zig:2940-3220` | GTK-specific events to `mouseButtonCallback/cursorPosCallback/scrollCallback` | `WM_*BUTTON*`, `WM_MOUSEMOVE`, `WM_MOUSEWHEEL/HWHEEL` (hi-res deltas set `precision`), capture with `SetCapture`. |
| Quick terminal | `application.zig:3055`, `window.zig:1320`, `winproto/{wayland,x11}.zig` (layer-shell) | Config `quick-terminal-*` (position, size, screen, animation, autohide) is core. | Dedicated topmost popup HWND on the chosen monitor, slide animation, autohide on `WM_ACTIVATE`. Global hotkey needs `RegisterHotKey` + `core_app.keyEvent` (hence the `config` field in 1.3). |
| Global shortcuts | `class/global_shortcuts.zig` 700 (xdg portal) | Core flags a keybind `global` (`App.zig:381`) | `RegisterHotKey` + low-level hook. |
| Command palette | `command_palette.zig` 785 + blp 111 | Entries and actions are core: `src/input/command.zig`, config `command-palette-entry`, executed via `performBindingAction` | Own popup (filterable list, fuzzy match). |
| Inspector (imgui) | `imgui_widget.zig` 557 (GL-backed imgui), `inspector_widget.zig` 245, `inspector_window.zig` 217 | The inspector UI contents are core: `src/inspector/` (~5,000 LOC, `Inspector.zig` + `widgets/*`) on `dcimgui` (`pkg/dcimgui`). Only the platform and renderer backend is per-apprt. | `pkg/dcimgui/build.zig` only builds `opengl3`, `metal`, `osx` backends. Win32 needs `imgui_impl_win32` + `imgui_impl_dx11`, or defer the inspector. Embedded macOS uses Metal (`embedded.zig:1262-1510`). |
| Config reload | `application.zig:2785-2826` + `class/config.zig` 175 + `config_errors_dialog.zig` 160 | Parsing, diffing, conditional state (theme) are core | Load, `core_app.updateConfig`, handle `config_change` payload. File watching is not in core: it is a manual `reload_config` keybind. |
| Notifications | `desktop_notifications.zig` 358 + `application.zig:2234` | Rate limiting in core `App.zig:61-64`. Payload truncation in `apprt/surface.zig:20-58`. | Toast/balloon. |
| Resize overlay | `resize_overlay.zig` 338 | Config `resize-overlay*` | Small topmost popup or in-surface text drawn by apprt. |
| URL hover | `mouse_over_link` action, `surface.zig` | Link detection in core | Status text/tooltip. |
| Search | `search_overlay.zig` 495 + blp 99 | Search engine is core (`terminal.search.Thread`, `Surface.zig:211`) | Find bar. |
| Key sequences/tables | `key_state_overlay.zig` 342 | State machine is core | Indicator widget. |
| Dialogs | `clipboard_confirmation_dialog.zig` 336, `close_confirmation_dialog.zig` 203, `title_dialog.zig` 236 | Trigger conditions are core | `TaskDialog`/custom. |
| Color scheme | `gsettings.zig` 101 + portal | `App.colorSchemeEvent` core | Registry `AppsUseLightTheme` + `WM_SETTINGCHANGE "ImmersiveColorSet"`. |
| Single instance / IPC | `gtk/ipc/*`, `DBus.zig` | `apprt/ipc.zig` (252 LOC: `Target`, `Action{new_window, new_tab, toggle_quick_terminal}`) | Named pipe/mutex. v1 can return false. |

GTK-only plumbing (skip entirely): `winproto/` (x11 + wayland + BlurRegion + vicinae XML, 1887 LOC), `portal.zig`/`portal/OpenURI.zig` (706), `cgroup.zig`, `pre_exec.zig`, `post_fork.zig`, `flatpak.zig`, `gtk_version.zig`, `adw_version.zig`, `class.zig` + `ext/*` + `weak_ref.zig` GObject helpers (820), `build/gresource.zig`+`blueprint.zig` (397), CSS (227), `ui/*.blp` (1,458 total).

## 4. macOS and `embedded` as an alternative base

How macOS works:
- The Swift app is a normal AppKit/SwiftUI app (162 files, about 23.5k LOC under `macos/Sources`; `Ghostty.App.swift` 2516, `TerminalController.swift` 1823, `BaseTerminalController.swift` 1741) linking libghostty (artifact `.lib` selects `apprt.embedded`, `apprt.zig:48`). The runtime config struct is `ghostty_runtime_config_s` (`include/ghostty.h:~1090-1102`; Zig side `embedded.zig:36-100`): callbacks `wakeup_cb`, `action_cb`, `read_clipboard_cb`, `confirm_read_clipboard_cb`, `write_clipboard_cb`, `close_surface_cb`.
- Lifecycle: `ghostty_app_new(&runtime_cfg, config)` (`Ghostty.App.swift:83`), `wakeup_cb` becomes `DispatchQueue.main.async { ghostty_app_tick }` (lines 61, 121, 546). Per surface `ghostty_surface_new` with `ghostty_surface_config_s{platform_tag, nsview, scale, font_size, working_directory, command, env_vars...}` (`embedded.zig:462-502`). Host forwards `ghostty_surface_key/text/preedit/mouse_button/mouse_pos/mouse_scroll/set_size/set_content_scale/set_focus/set_occlusion/binding_action/complete_clipboard_request` (CAPI at `embedded.zig:1512-2578`, ~1,070 LOC; `ghostty.h` 1,287 lines).
- Rendering: the core owns presentation. Metal attaches an `IOSurfaceLayer` to the `NSView` (`Metal.zig:79-82`, `renderer/metal/IOSurfaceLayer.zig`). The host never sees frames.
- All UI (windows, tabs, splits, palette, search, quick terminal, update UI, settings) is Swift. Splits are a Swift reimplementation (`SplitTree.swift` 1413 LOC), not `split_tree.zig`.
- Actions arrive as `ghostty_action_s` through one C callback (`embedded.zig:303-323`, `performAction` forwards `target.cval()`/`action.cval()`). Platform handled set: `Ghostty.App.swift` handles about 60 of 70.

Is it viable for Win32 (host written in Zig calling the C API)?

Pros of embedded:
- Zero changes to the ~14 core switch sites, so there is no merge friction with upstream.
- A stable-ish ABI boundary, `GHOSTTY_API` functions with plain C types. Windows lib build plumbing already exists: `GhosttyLib.zig:47,118-140` (MSVC CRT workarounds), `build.zig:223-236` installs `ghostty-internal.dll/.lib`.
- Matches the `wakeup` then `tick` model of a Win32 message loop naturally.
- Cleaner minimal contract to study: embedded is the smallest complete apprt (about 1,500 LOC excluding CAPI).

Cons of embedded:
1. `Platform` union only has `macos`/`ios` (`embedded.zig:382-437`, `ghostty.h:70-73,491-500`). Adding `win32{hwnd}` needs core and ABI changes anyway.
2. No frame presentation path other than Metal. The CAPI has no `take_frame`/swap-chain hook, and `renderer.takeFrame()` is only consumed by GTK. A D3D11 renderer would need core changes either way (new Platform and HWND plumbing in `Options.rt_surface`).
3. The inspector is Metal-only (`embedded.zig:1315-1378`), `keyboardLayout` is macOS-only, and `performIpc` returns false. Embedded has no non-Apple renderer story at all.
4. The host still has to build every UI feature from section 3 (windows, tabs, splits, palette, search...). Only the glue changes: no typed Zig access to `SplitTree`, `Config`, `input.Binding`. Everything crosses `ghostty.h`, whose structs must be kept in sync by hand (`action.zig:64-78` "Sync with" comments plus `lib.checkGhosttyHEnum` tests).
5. Lifetime and threading hazards cross a C boundary: `ghostty_config_t` ownership, clipboard `state` pointers, string lifetimes valid "only for the duration of the action callback" (`action.zig:284-296`).
6. A Zig host over C would consume `@cImport(ghostty.h)` and lose the comptime contract check, which is the main safety net when core changes upstream.
7. Two build artifacts instead of one exe, with DLL plus CRT linking friction on MSVC (already a documented pain at `GhosttyLib.zig:118-140`).

Verdict: build a native Zig `src/apprt/win32` (as GTK does). Use `embedded.zig` as the reference for the minimal contract and `gtk/` for feature scope. The cost of the `.win32` arms is small (about 14 one-line edits; many can become `else => void`). The embedded route does not avoid core changes: it only moves the renderer and presentation work behind a C ABI. If a lib is wanted later, `.lib` embedded remains available independently.

## 5. Threading model

Threads per process / surface:
- UI/app thread (the apprt's main thread): runs the OS loop, calls `core_app.tick` (drains `App.mailbox`, a `BlockingQueue(Message, 64)`, `App.zig:~560-600`), receives all input callbacks, and receives all `performAction`s. Every `rt_app.performAction` in core originates from `handleMessage`/`tick` or from an input callback on this thread. Renderer, IO and search threads only talk to it through `Surface.Mailbox.push`, which wraps into `App.Message.surface_message` and calls `rt_app.wakeup()` (`apprt/surface.zig` Mailbox, `App.zig:595-599`). Therefore `wakeup()` is the one apprt method that must be thread-safe.
- Renderer thread per surface (`Surface.zig:754`, `renderer/Thread.zig`): libxev loop with `xev.Async` for wakeup/stop/draw_now and `xev.Timer` for cursor blink and animations. Receives messages via `renderer.Thread.Mailbox` (`BlockingQueue(Message,64)`). It does all GPU work: `threadEnter` (binds the GL context) then draws on each wakeup. For OpenGL the EGL context is created on the main thread in `OpenGL.init` and re-bound on the render thread (`OpenGL.zig:201-215`). Devices are app-scoped (`App.device`) and made lazily on the first surface (`Surface.zig:566-570`). A D3D11 immediate context is single-thread: each surface's renderer thread needs its own deferred/immediate context (or a mutex) over the shared `ID3D11Device`. The `Metal.zig` approach is one command queue per surface.
- IO (termio) thread per surface (`Surface.zig:762`, `termio/Thread.zig`): xev loop, owns the terminal state mutation under `renderer_state.mutex` (shared with the renderer). Plus a dedicated pty read thread: `termio/Exec.zig:140-154` (`ReadThread.threadMainWindows` on Windows; cancel via `CancelIoEx`, `Exec.zig:219-229`). ConPTY is implemented (`pty.zig:344-489`, `Exec` defaults to `cmd.exe`, `Exec.zig:767,846`).
- Search thread (`terminal.search.Thread`, `Surface.zig:211`) and background font/warmup threads (`App.zig:89-101`, optional `Discover.warmup`/`Device.warmup`).
- Frame handoff: the render thread finishes a frame, then `pushFrame` (single slot, old frame released), then `surface_mailbox.push(.redraw)`, then the UI thread runs `Surface.redraw` which emits `performAction(.render)`, and the apprt calls `core.renderer.takeFrame()` (main thread only) (`generic.zig:1060-1072`). For D3D11: either follow this (export a shared NT handle texture and compose in the UI thread) or present directly on the render thread. In the latter case the `render` action is a no-op and `ExportedFrame` can stay `void` (`generic.zig:96`: `if @hasDecl(GraphicsAPI,"ExportedFrame")`). `Surface.draw()` (main thread, `drawFrame(sync=true)`) must also work, for resize.
- Vsync: only macOS has a display link (`renderer/DisplayLink.zig`; `hasVsync` returns false elsewhere, `generic.zig:1186`). On Linux and Windows the renderer thread simply draws on wakeup. A Win32 swap chain with a frame-latency waitable object would sit in the render thread.
- Platform specifics in this machinery: xev backend is chosen at runtime (`global.zig:30,161`, `xev.Dynamic`; epoll/io_uring on Linux, kqueue on macOS, IOCP on Windows; the Windows backend is untested here: `Async`/`Timer` on IOCP are what renderer and termio threads need). Darwin-only: thread names via `pthread_setname_np`, QoS (`Thread.zig:204-253`), autorelease pools. Linux-only: cgroup, `pre_exec`/`post_fork`. GTK-only: the `MainContext` loop. posix-only: termios polling timer (`Exec.zig:181-184,242,329`) is skipped on Windows.

UI-thread requirements for Win32: every HWND call, all `core.*Callback`s, `completeClipboardRequest`, `core_app.tick`, `takeFrame`, and the OLE clipboard (STA) must stay on the thread that owns the windows. Clipboard reads may complete asynchronously (OLE delayed render) as long as `completeClipboardRequest` is called from the UI thread exactly once.

## 6. The `none` apprt

- `src/apprt/none.zig` (19 LOC): `App = struct { performIpc → false }`, `Surface = struct {}`, `resourcesDir = internal_os.resourcesDir`. It is the default for every non-Linux/FreeBSD target (`runtime.zig:14-24`).
- What builds with `-Dapp-runtime=none` (the Windows/macOS default): the libghostty glue lib `GhosttyLib` (artifact `.lib`, so `apprt.runtime == embedded`, not `none`; `build.zig:218-236`), `libghostty-vt` shared and static (`build.zig:~120-170`, independent of apprt), test exe, bench, helpgen, docs, webdata, and the CLI-only exe, which is compiled but not installed (`build.zig:211`). The `+action` CLI path (`main_ghostty.zig:60-76`) works and prints usage for a bare run. `global.zig:398` makes stderr logging default off.
- Therefore `none` is a link-time placeholder, not a runtime. A bare `zig build` on Windows today yields DLL/libs plus helpers, never `ghostty.exe`.

## 7. Size estimate and what Win32 must replicate

GTK apprt totals (`src/apprt/gtk`): 24,692 LOC Zig (57 files) + 1,458 LOC of `.blp` + 227 CSS + 305 Wayland XML. By area (Zig):

| Area | LOC | Win32 replicate? |
|---|---|---|
| App lifecycle, config, global shortcuts | 4,411 | Yes, about 1,000 (loop, tick, config load/reload, action switch, quit timer, theme, hotkeys) |
| Window and tab | 2,968 | Yes, about 1,800 (custom frame, tab strip, DPI) |
| Splits | 1,567 | Yes, about 600 (layout/divider/drag over core `SplitTree`) |
| Surface (+render surface, scrollbar, scale) | 5,536 | Yes, about 2,000 (wndproc, input translation, clipboard, cursor, scrollbar, present) |
| Key translation | 655 | Yes, about 600 (VK/scancode to Key, mods, dead keys, IME) |
| Command palette | 785 | Yes, about 500 (or later) |
| Inspector | 1,019 | Optional, about 400 + imgui backends |
| Overlays (search, key state, resize, child exited, debug) | 1,418 | Yes, about 700 |
| Dialogs | 935 | Yes, about 400 |
| Notifications | 358 | Yes, about 150 |
| winproto (x11/wayland) | 1,887 | No. Replaced by about 300 of DWM/monitor/hotkey code |
| portal/D-Bus IPC/gsettings | 1,163 | No. Replaced by about 250 (OpenURI to ShellExecute, registry theme, optional named-pipe IPC) |
| GObject infra, build glue, Linux misc | 1,990 | No |

Estimated Win32 apprt: about 9-11k LOC Zig with imports of hand-written Win32 externs. This is roughly 40-45% of the GTK size because there is no declarative UI layer (GTK's `.blp` plus 3,000+ LOC of GObject boilerplate), no toolkit widgets for tabs/dialogs/palette, and no Linux plumbing. Minimum viable v1 (single window, tabs, splits, clipboard, IME, scrollbar, config reload, ~30 actions) is about 5-6k LOC.

Gotchas for the architect:
- `std.os.windows` is being gutted upstream (see header comment, `src/os/windows.zig:5-9`). Win32 externs must be declared locally, in a new `src/apprt/win32/win32.zig`, or the repo's `translate_c` of `windows.h`. No Win32 binding package is in `build.zig.zon`.
- Zig 0.17 APIs are in play (`std.Io`, `std.lang.Type`, `@backingInt`). Use the existing patterns in `src/os/windows.zig` and `src/lib/tinyio/windows.zig`.
- Existing Windows groundwork in core: `os/xdg.zig:25-74` (LOCALAPPDATA), `os/open.zig:36`, `os/resourcesdir.zig:63`, `pty.zig` ConPTY, `termio/Exec.zig` windows paths, and the keycode Windows column.
- Clipboard `Clipboard` enum backing is `c_int` for gtk and `u2` otherwise (`structs.zig:47`). Win32 gets `u2`, so no change except the switch arm.
- Shader pipeline is GLSL to SPIR-V (glslang + spirv_cross in `pkg/`), and `renderer/shadertoy.zig:45` supports `Target = {glsl, msl}`. D3D11 will need a custom-shader target such as HLSL via SPIR-V Cross, or custom shaders disabled initially.
- Renderer backend interface that D3D11 must provide (derived from `OpenGL.zig`): `Device` (+`Options`, `init`, optional `warmup`), `init(alloc, device, opts)`, `deinit`, `threadEnter(surface)/threadExit`, `surfaceSize`, optional `setViewport`, `drawFrameStart/End`, `initShaders`, `initTarget`, `beginFrame` returning `Frame` (with `renderPass`, `complete(sync)`), `Target`, `RenderPass`, `Pipeline`, `Buffer`, `Sampler`, `Texture`, `shaders`, `*Options` helpers (`bufferOptions`, `textureOptions`, `samplerOptions`, `imageTextureOptions`, `initAtlasTexture`), `custom_shader_target`, `custom_shader_y_is_down`, `swap_chain_count`, optional `ExportedFrame`/`present`, optional `displayRealized`/`loopEnter`.
