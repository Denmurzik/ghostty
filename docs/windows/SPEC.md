# Ghostty for Windows — architecture spec

Status: draft 1 (2026-10-25), author `architect`. Authority order: `docs/windows/DECISIONS.md` (binding) > this spec > plans.
Inputs: `docs/windows/recon/{apprt,renderer,platform,build,tmux}.md` (cited as `[apprt §n]`, `[renderer §n]`, …). This spec does
not repeat recon facts; it records the design decisions taken on top of them. Every "Decision" below is binding for plans
unless the owner overturns it. Owner/lead rulings on former open questions are recorded in §18.

## 0. Summary of the key decisions

| # | Decision | Why |
|---|---|---|
| D1 | Native Zig apprt `src/apprt/win32` (R5), one **top-level HWND per window**, one **child HWND per terminal surface**. | Win32 focus, IME context, mouse capture, cursor, WM_DPICHANGED and later UI Automation all work per HWND; split layout = `SetWindowPos` of children; Chromium-proven with DComp. |
| D2 | D3D11 backend **presents on the render thread** into a DXGI flip-model swap chain owned by the renderer. **No `ExportedFrame`**; the `render` action is a no-op. | No cross-thread frame hand-off, no copies on the UI thread, modal resize loops do not stall rendering [renderer §5.3, apprt §5]. |
| D3 | **One app-scoped `ID3D11Device`** (shared by all surfaces) + a process-wide **context lock** held from `drawFrameStart` to `drawFrameEnd`. Frame pacing via a **frame-latency waitable object** waited in `beginFrame` (only reached when a frame is really drawn), only after a previous `Present`, timeout 0 on the sync/UI-thread path. `swap_chain_count = 1`. | RAM: one driver/UMD instance instead of one per surface; frames are tiny so lock hold time is ≪ 1 ms. Option A of [renderer §7.2] (device per surface) stays available as a fallback switch (§6.3). |
| D4 | Swap chain mode `hwnd` (CreateSwapChainForHwnd, FLIP_DISCARD, `B8G8R8A8_UNORM`) in M1–M2; mode `composition` (DirectComposition, premultiplied alpha) added in M3 for transparency/overlays. Both live behind `src/renderer/d3d11/SwapChain.zig`. | Fastest path to pixels for M1 without closing the door on opacity; the switch is local to one file plus window styles. |
| D5 | Builtin shaders are hand-written HLSL ported from `shaders.metal` (R4); compiled at runtime with `d3dcompiler_47.dll` once per process into a global bytecode cache (warmed on `Device.warmup`). | R4. |
| D6 | Win32/COM bindings are **hand-written Zig** in a new path package `pkg/win32` (module `win32`). No translate-c of `windows.h`, no zigwin32. Core code under `src/os/` keeps using `src/os/windows.zig` and never imports `win32`. | Small surface (~15 COM interfaces, ~150 functions); no dependency on Zig-std churn; core stays upstreamable. |
| D7 | Chrome (tab strip, title area, overlays from M2 on) is drawn with **Direct2D 1.1 + DirectWrite**; text inputs (search, palette, rename) use native `EDIT` controls. Mica via `DWMWA_SYSTEMBACKDROP_TYPE`. | Pure Win32/DWM, no WinUI (DECISIONS). |
| D8 | tmux shim = console exe `tmux.exe` (thin argv forwarder) + **named-pipe server inside Ghostty**; all tmux semantics run on the Ghostty UI thread against a pane/window registry. | Startup < 100 ms [tmux §9]; one place to fix semantics. |
| D9 | Config: `%USERPROFILE%\.config\ghostty\config.ghostty` only (DECISIONS). Cache/state/logs/crash stay under `%LOCALAPPDATA%\ghostty\` (they are not config). | DECISIONS + [platform §3.5]. |
| D10 | Logging for the GUI exe: file sink `%LOCALAPPDATA%\ghostty\logs\ghostty.log` + `OutputDebugStringW` sink; CLI `+actions` get a console via inherited handles or `AttachConsole(ATTACH_PARENT_PROCESS)`. | [platform §7.1] (a)+(c). |

## 1. Scope

Goals, product identity, archs, minimum OS, release form: see DECISIONS. Non-goals for v1.0: tmux server persistence,
detach/attach, code signing, MSIX packaging, Windows 10 guarantees, exclusive fullscreen, HDR/P3 output.

## 2. Module layout

```
pkg/win32/                       NEW path package, module "win32" (hand-written bindings, no C code)
  build.zig, build.zig.zon, main.zig
  foundation.zig                 HRESULT/GUID/LUID/RECT/POINT/HWND/HINSTANCE/HMONITOR/WPARAM/LPARAM/LRESULT, hresult→error mapping
  com.zig                        IUnknown, vtable conventions, ComPtr-free helpers (release, queryInterface)
  dxgi.zig                       IDXGIFactory2/IDXGIAdapter1/IDXGIDevice/IDXGISwapChain1/2, formats, DXGI_ERROR_*
  d3d11.zig                      ID3D11Device/DeviceContext/Buffer/Texture2D/views/states/shaders/InputLayout, D3D11CreateDevice
  d3dcompiler.zig                runtime-loaded D3DCompile (LoadLibraryW "d3dcompiler_47.dll"), ID3DBlob, ID3DInclude
  user32.zig gdi32.zig dwmapi.zig imm32.zig shell32.zig ole32.zig kernel32.zig(GUI-only extras) uxtheme.zig
  dcomp.zig d2d1.zig dwrite.zig  (M2/M3)
src/renderer/D3D11.zig           GraphicsAPI struct (contract of [renderer §1.3])
src/renderer/d3d11/              Device.zig Target.zig SwapChain.zig Frame.zig RenderPass.zig Pipeline.zig
                                 buffer.zig Texture.zig Sampler.zig shaders.zig hlsl.zig(compile+cache)
src/renderer/shaders/hlsl/       common.hlsli full_screen.hlsl bg_color.hlsl cell_bg.hlsl cell_text.hlsl image.hlsl bg_image.hlsl
src/apprt/win32.zig              runtime root: App, Surface, resourcesDir
src/apprt/win32/                 App.zig Window.zig Surface.zig key.zig keyboard.zig mouse.zig ime.zig clipboard.zig
                                 dialogs.zig dpi.zig
                                 M2+: Tab.zig TabStrip.zig SplitLayout.zig Chrome.zig (D2D) theme.zig scrollbar.zig
                                 M3+: QuickTerminal.zig CommandPalette.zig SearchBar.zig notify.zig inspector/
                                 M4:  tmux/{Server.zig,Registry.zig,commands.zig,layout.zig}
src/tmux_shim/                   main.zig (tmux.exe), protocol.zig (wire format, shared), cli.zig (tmux argv parser,
                                 shared), format.zig (#{var} expansion), sh_command.zig (POSIX one-liner parser, R2)
src/build/GhosttyTmuxShim.zig    builds/installs tmux.exe (M4)
src/os/windows_shell.zig         default shell resolver (Git Bash → pwsh → cmd)
src/os/windows_console.zig       console attach for CLI actions
test/windows/                    PowerShell harness: launch.ps1 capture-window.ps1 send-input.ps1 measure-ram.ps1 (+README)
dist/windows/                    ghostty.rc/.manifest/.ico (exist), installer/ghostty.iss (M6), portable layout (M6)
```

Rules: Windows code goes in the paths above; core edits are `comptime builtin.target.os.tag == .windows`-gated or are
platform-neutral improvements (e.g. `SplitTree.replace`). Every core touch point is listed in the plan that makes it.

## 3. Build integration

- New enum members: `apprt.Runtime.win32` (default on Windows), `renderer.Backend.d3d11` (default on Windows). OpenGL is
  not supported on Windows (no EGL); `-Drenderer=opengl` with a Windows target is a build error with a clear message.
- ABI: MSVC (R3; `src/build/Config.zig:105-116` already forces it). Targets `x86_64-windows-msvc`, `aarch64-windows-msvc`.
- `SharedDeps` Windows arm: import module `win32`; link system libs `user32 gdi32 dwmapi imm32 shell32 ole32 uxtheme
  d3d11 dxgi` (+ `dcomp d2d1 dwrite windowscodecs` from M2/M3, `advapi32` for registry). `d3dcompiler_47` is loaded at
  runtime, never linked.
- `posix_c` translate-c includes are OS-conditional (no `pwd.h`/`unistd.h` on Windows) [build §4 #1-2]. glad is compiled
  only when `renderer == .opengl`. The `tail` system command in `GhosttyResources` is skipped for non-Linux templates.
- Exe: `subsystem = .windows` with `exe.entry = .{ .symbol_name = "mainCRTStartup" }` (Zig's `start.zig` exports C `main`
  under `link_libc`; lld would otherwise pick `WinMainCRTStartup` and fail on a missing `WinMain`; proven by a hello-GUI
  exe in M1 Task 1). Resources from `dist/windows/ghostty.rc` (exists). Manifest gains (M1 Task 1)
  `<activeCodePage>UTF-8</activeCodePage>` and `<longPathAware>true</longPathAware>` (PerMonitorV2 already present). The
  test exe has no manifest, so no code path may rely on the ANSI code page being UTF-8 (fonts are opened via UTF-16, §9).
- `tmux.exe` (M4): separate exe, console subsystem, root `src/tmux_shim/main.zig`, **no SharedDeps** (only std + `src/tmux_shim`),
  installed next to `ghostty.exe`.
- Release recipe flags: `-Doptimize=ReleaseFast -Demit-themes=true -Demit-terminfo=true`.
- Local builds always `-j4` through the test-lock (DECISIONS).

## 4. Bindings package `pkg/win32` (D6)

- Plain Zig `extern "user32" fn … callconv(.winapi)` declarations, same style as `src/os/windows.zig:140-160`.
- COM interface pattern (one per interface):
  ```zig
  pub const ID3D11Device = extern struct {
      vtable: *const VTable,
      pub const VTable = extern struct { // ALL slots in header order, inherited first
          base: IUnknown.VTable,
          CreateBuffer: *const fn (*ID3D11Device, *const BUFFER_DESC, ?*const SUBRESOURCE_DATA, *?*ID3D11Buffer) callconv(.winapi) HRESULT,
          CreateTexture1D: *const anyopaque, // unused slots keep their name, typed *const anyopaque
          ...
      };
      pub inline fn createBuffer(self: *ID3D11Device, …) !*ID3D11Buffer { … }
  };
  ```
  Every interface gets a test asserting `@sizeOf(VTable) / @sizeOf(usize)` equals the slot count from the Windows SDK
  10.0.26100 header (inheritance included). IIDs are `GUID` constants copied from the headers.
- HRESULT handling: `foundation.check(hr) Error!void` maps `DXGI_ERROR_DEVICE_REMOVED/RESET/HUNG` → `error.DeviceLost`,
  `E_OUTOFMEMORY` → `error.OutOfMemory`, `DXGI_ERROR_WAS_STILL_DRAWING` → `error.WouldBlock`, `E_INVALIDARG` →
  `error.InvalidArgument`, others → `error.ComFailure` and logs the hex value.
- Strings: `std.unicode.utf8ToUtf16LeAllocZ` at call sites; no `A` (ANSI) APIs except where no `W` exists.
- Only the minimum needed per milestone; additions are append-only per file.

## 5. Threading model

| Thread | Owner | Does |
|---|---|---|
| UI (main) thread | apprt | `GetMessageW` loop; all HWNDs, DComp tree (M3), clipboard (OLE STA, `OleInitialize`), IME, dialogs; `core_app.tick`; every core `*Callback`; tmux command execution (M4). |
| Render thread ×surface | core `renderer.Thread` | All D3D11 work for its surface incl. `Present`, `ResizeBuffers`, swap-chain creation (in `threadEnter`). |
| IO thread ×surface + pty read thread | core termio | unchanged; read thread becomes event-driven (§8.4). |
| Shader warmup thread | `Device.warmup` (detached, App.zig:100) | compiles builtin HLSL into the process cache. |
| IPC thread (M2/M4) | apprt | named-pipe accept/read/write; forwards each request to the UI thread and waits for its reply. |

- `App.wakeup()` (any thread): `if (!pending.swap(true)) PostMessageW(msg_hwnd, WM_GHOSTTY_WAKEUP, 0, 0)`. The
  message-only window's WndProc clears `pending` and runs `core_app.tick(rt_app)`. Posted messages are dispatched inside
  modal size/move loops, so ticks continue while the user drags.
- Cross-thread to UI: always `PostMessageW` to the message-only window with a heap payload; never `SendMessage` from a
  render/IO thread (deadlock with modal loops).
- D3D11: the device is free-threaded; the immediate context is used only under `Device.context_lock` (§6.3). DXGI
  swap chains are created and presented on the render thread; the HWND is owned by the UI thread (allowed for flip
  model, no exclusive fullscreen; `MakeWindowAssociation(DXGI_MWA_NO_ALT_ENTER | NO_WINDOW_CHANGES)`).

## 6. Renderer: D3D11 backend

### 6.1 Contract
`src/renderer/D3D11.zig` implements every decl of [renderer §1.3] (types, `swap_chain_count = 1` — generic's per-frame `FrameState`s (each a full-size `Target` plus
atlas copies, `generic.zig:395-447`) buy nothing on D3D11 because `WRITE_DISCARD` renames buffers and
`SetMaximumFrameLatency(1)` caps queueing; 3 would cost ~5×33 MB at 4K under WARP/iGPU —
`custom_shader_y_is_down = true`, `custom_shader_target` (`.glsl` placeholder until M3 adds `.hlsl`; custom shaders are
logged and skipped before M3), `ImageTextureFormat`, `init/deinit`, `threadEnter/threadExit`, `surfaceSize`,
`setViewport`, `drawFrameStart/End`, `initShaders`, `initTarget`, `initAtlasTexture`, all `*Options`, `beginFrame`).
It does **not** declare `ExportedFrame`.

Apprt seam (comptime-optional, so tests with `app_runtime = none` render headless):
```zig
// src/renderer/D3D11.zig
pub const PresentTarget = struct {
    hwnd: *anyopaque,                         // HWND of the surface child window
    size: *const std.atomic.Value(u64),       // physical client size, (w << 32) | h, written by UI thread on WM_SIZE
};
// src/apprt/win32/Surface.zig
pub fn d3d11PresentTarget(self: *Surface) ?renderer.D3D11.PresentTarget
```
`D3D11.threadEnter(surface)` calls it when `@hasDecl(apprt.Surface, "d3d11PresentTarget")`; null → headless (renders
into `Target` only; used by tests).

### 6.2 Resources and formats
Mapping per [renderer §4, §7.2]. Fixed choices:
- `Target`: `B8G8R8A8_TYPELESS` texture, RTV `B8G8R8A8_UNORM_SRGB` when `blending.isLinear()` else `_UNORM`, SRV for
  post passes. Backbuffer `B8G8R8A8_UNORM`; present = `CopyResource(backbuffer, target)` (same format group) then
  `Present`. No blit shader.
- Atlases: grayscale `R8_UNORM`, color `B8G8R8A8_UNORM_SRGB`; read with `Texture2D.Load` (no sampler).
- Images: `R8G8B8A8_UNORM_SRGB`, linear-clamp sampler. `.gray`/`.bgra` image formats are unreachable → `@panic` with message.
- Buffers by role: `fgBufferOptions`/`imageBufferOptions`/`bgImageBufferOptions` → vertex (instance) buffer;
  `bgBufferOptions` → structured buffer + SRV (stride 4, slot `t4` in VS+PS); `uniformBufferOptions` → constant buffer
  (slot `b1`, size rounded to 16). All `D3D11_USAGE_DYNAMIC` + `Map(WRITE_DISCARD)`; growth ×2 recreates the SRV.
- Register map (single source: `common.hlsli`, mirrored by `src/renderer/d3d11/slots.zig`, from which `RenderPass` binds
  per stage): uniforms `b1` (VS+PS); `buffers[0]` → IA vertex slot 0; `buffers[i≥1]` → SRV `t(3+i)` in VS **and** PS
  (so `bg_cells` = `t4`); `textures[i]` → SRV `t(i)` in PS only (`cell_text`: `t0` grayscale atlas, `t1` colour atlas;
  image/bg_image/custom: `t0`); `samplers[i]` → `s(i)` in PS. Textures are limited to `t0..t2` per step, so buffer SRVs
  never alias texture SRVs.
- Blend: premultiplied `ONE / INV_SRC_ALPHA` when `blending_enabled`; no depth, no MSAA, no scissor.

### 6.3 Device, context lock, pacing, device loss
- `Device` (app-scoped, `init(alloc, Options) !*Device`): `CreateDXGIFactory2`, adapter enumeration
  (`EnumAdapterByGpuPreference(HIGH_PERFORMANCE)` is not used: default adapter 0; `Options.driver = .warp` or env
  `GHOSTTY_D3D11_DRIVER=warp` forces WARP for CI/VMs), `D3D11CreateDevice` with FL 11_0 minimum, `BGRA_SUPPORT`,
  `DEBUG` when `Options.debug_layer` (env `GHOSTTY_D3D11_DEBUG=1`, Debug builds only). Not `SINGLETHREADED`.
- `context_lock: std.Io.Mutex` (same Io-mutex style as `generic.draw_mutex`). `drawFrameStart` = lock; `drawFrameEnd` =
  unlock. Every other use of the immediate context (resource destruction is free-threaded and needs no lock) must take the
  lock (debug builds assert the owner thread).
- Pacing wait lives in `beginFrame`, NOT `drawFrameStart`: generic calls `drawFrameStart` on every `drawFrame`
  (`generic.zig:1756`) before the 0-size check and the no-redraw early return, while holding `draw_mutex`; waiting there
  would burn latency tokens on draws that never present and block the UI thread in `WM_SIZE`. `beginFrame` waits on the
  waitable object only if `presented_since_wait` is set, with timeout 100 ms on the render thread and 0 on the sync
  (UI-thread) path. The wait then happens under `draw_mutex` + context lock; it is bounded by one refresh interval.
- Pacing: swap chain flag `FRAME_LATENCY_WAITABLE_OBJECT`, `SetMaximumFrameLatency(1)`; `Present(sync_interval, 0)` with
  `sync_interval = 1` when config `window-vsync = true` else `0` (+`ALLOW_TEARING` only with interval 0 and only if
  supported). `ResizeBuffers` repeats the creation flags (`FRAME_LATENCY_WAITABLE_OBJECT | ALLOW_TEARING`) after releasing
  every cached back-buffer reference. Generic still draws
  on every wakeup (no display link); the waitable wait caps it at the display rate.
- Fallback switch (only if measured lock contention > 2 ms/frame with ≥ 8 surfaces): `Options.per_surface_device = true`
  gives each `D3D11` instance its own device+context and no global lock. Not built in M1.
- Device loss (`error.DeviceLost` from Present/Map/Create*): M1 = mark `renderer_health = .unhealthy` via
  `frameCompleted(.unhealthy)`, log once, keep the window alive. M3 = full recovery: `Device.generation` bump, every
  surface rebuilds through `displayUnrealized()` + `displayRealized()` [renderer §1.4].

### 6.4 Resize, DPI, sync draws
- UI thread on `WM_SIZE` of a surface child: store the packed size in `PresentTarget.size` and nothing else - no
  `core.draw()` (no sync draw) and no direct `core.sizeCallback`. Size changes are coalesced by `ResizeCoalescer`
  (`apprt/win32/Surface.zig`): the first size of a burst arms a 16 ms `SetTimer` on the surface HWND; `WM_TIMER` and the
  top-level `WM_EXITSIZEMOVE` hand only the newest size to `core.sizeCallback` and stop the timer. Zero sizes
  (minimized, collapsed parent) cancel the pending size, and a size core already has never arms the timer. The renderer
  thread picks the new size up from `PresentTarget.size` and presents on its own, so the UI thread never waits for
  `draw_mutex` or a swap chain call during a live resize (this replaced the original sync-draw design, which hung
  `resize-while-streaming`).
- `surfaceSize()` reads `PresentTarget.size` (Metal-like pull) clamped to `max_texture_size`; headless returns the
  `setViewport` value.
- Swap chain resize happens inside `Frame.complete` before the copy: if backbuffer size ≠ target size →
  `ResizeBuffers(0, w, h, UNKNOWN, flags)` (backbuffer reference released first).
- DXGI threading: `MakeWindowAssociation(hwnd, DXGI_MWA_NO_WINDOW_CHANGES | DXGI_MWA_NO_ALT_ENTER)` before the first
  `Present`; `SetFullscreenState` is never called. `ResizeBuffers` and all presents happen on the render thread; the
  UI thread never calls into DXGI. M1 e2e has a live-resize-while-streaming hang watchdog (acceptance timing on a
  ReleaseFast build, see `test/windows/README.md`).
- Teardown order: `Surface.destroy` = `core_surface.deinit()` (joins render + IO threads, releases the swap chain) →
  `DestroyWindow(child)` → free; `Window.destroy` destroys its surfaces before its own HWND. The surface WndProc ignores
  core callbacks until `initialized` is set (`WM_SIZE` arrives inside `CreateWindowExW`, before `core_surface.init`).
- DPI: process is PerMonitorV2 (manifest). Surface content scale = `GetDpiForWindow(hwnd) / 96.0` for x and y.
  `WM_DPICHANGED` on the top-level: `SetWindowPos` to the suggested rect, then each surface child calls
  `core.contentScaleCallback` and the normal size path. Fractional scale (125%, 175%) is handled by core font sizing.

### 6.5 Shaders
- Port `shaders.metal` 1:1 into `src/renderer/shaders/hlsl/*.hlsl` sharing `common.hlsli`; CPU structs (`Uniforms`,
  `CellText`, `CellBg`, `Image`, `BgImage`) are copied from `opengl/shaders.zig` into `d3d11/shaders.zig` with a comptime
  `@offsetOf` test per field against the HLSL cbuffer packing.
- `d3d11/hlsl.zig`: `compile(entry, profile) ![]const u8` over embedded sources with an `ID3DInclude` resolving
  `common.hlsli`; flags `OPTIMIZATION_LEVEL3` (release) or `DEBUG | SKIP_OPTIMIZATION` (debug). A process-global cache
  `{entry → bytecode}` guarded by a mutex; `Device.warmup()` (static, no args — App.zig:100 calls it so) fills it.
- Custom shaders (M3): enable SPIRV-Cross HLSL backend (`pkg/spirv-cross/build.zig`: `spirv_hlsl.cpp`,
  `-DSPIRV_CROSS_C_API_HLSL=1`), `shadertoy.Target.hlsl`, `hlslFromSpv` with SM 5.0, bindings `b1`/`t0`/`s0`, compiled with
  `ps_5_0` against the builtin `full_screen` VS [renderer §3].

### 6.6 Later renderer work
M3: composition swap chain + DComp (per-surface target on the child HWND, premultiplied alpha, visuals for overlays),
`background-opacity`/`background-blur` (Mica/Acrylic on the top-level + transparent surfaces), device-loss recovery,
imgui inspector (`imgui_impl_win32` + `imgui_impl_dx11` in `pkg/dcimgui`), bg image + Kitty images verified on D3D11.

## 7. Apprt `src/apprt/win32`

### 7.1 Object model
`App` (one per process) → `Window` (top-level HWND, class `GhosttyWindow`) → `Tab` (M2; M1 has exactly one implicit tab)
→ `SplitTree(Surface)` (core `src/datastruct/split_tree.zig`, M2) → `Surface` (child HWND, class `GhosttySurface`,
heap-allocated, stable address, owns `CoreSurface`). `GWLP_USERDATA` of each HWND points at its Zig object.
A hidden message-only window (`HWND_MESSAGE`, class `GhosttyApp`) receives wakeups, IPC posts, timers (`quit_timer`).

### 7.2 Core contract mapping
Implements every member of [apprt §1.3, §1.4]. Notes on non-obvious ones:
- `App.init(core_app, opts)`: `OleInitialize`, `SetProcessDpiAwarenessContext` is NOT called (manifest does it), register
  classes, create message-only window, load config (`Config.load`), `core_app.updateConfig`, create the first window.
- `App.run()`: `while (GetMessageW(&msg, null, 0, 0) > 0) { TranslateMessage; DispatchMessageW }`. Quit = `PostQuitMessage(0)`.
- `performAction`: an exhaustive `switch` over `Action.Key`; unimplemented actions `log.debug` and return `false`.
  `render` returns `true` and does nothing (D2). `apprt/win32/actions_test.zig` (M2) asserts every key is either
  implemented or in an explicit `unsupported` list.
- `performIpc`: `false` until M2 (§12.6).
- `Surface.defaultTermioEnv()`: `global.environMap()` copy, then (M4) `TMUX`, `TMUX_PANE`, PATH prepend (§10).
- `Surface.close(process_active)`: if `process_active` and config `confirm-close-surface` ≠ false → confirmation dialog
  (§7.6); then destroy child, remove from tree; last surface of last window → `PostQuitMessage` unless
  `quit-after-last-window-closed = false`.
- `getCursorPos` = `GetCursorPos` + `ScreenToClient`; `getSize` = client rect of the surface child.
- `renderDeviceOptions()` = `.{ .driver = env override or .hardware, .debug_layer = env }`.

### 7.3 Input translation
Keyboard (`key.zig` pure functions + `keyboard.zig` WndProc glue):
- Messages: `WM_KEYDOWN/UP`, `WM_SYSKEYDOWN/UP` (Alt), `WM_CHAR`, `WM_SYSCHAR`, `WM_DEADCHAR`, `WM_SYSDEADCHAR`,
  `WM_UNICHAR` (ignored except `UNICODE_NOCHAR` probe). The loop calls `TranslateMessage` for every message (required for
  IME and dead keys). On `WM_KEYDOWN` the handler **drains the already-posted `WM_CHAR`/`WM_DEADCHAR` messages for the same
  HWND with `PeekMessageW(PM_REMOVE)`** and attaches their UTF-16 (surrogates joined) as `KeyEvent.utf8` (the winit
  technique). `WM_CHAR` arriving without a preceding key-down (IME commit, `SendInput` unicode, Alt+numpad) → `textCallback`.
- Physical key: `scancode = (lParam >> 16) & 0xFF`, `| 0xE000` if bit 24; look up `input.keycodes.entries` by
  `.native`. Special cases: ignore fake-shift scancodes `0xE02A`/`0xE036`; disambiguate Pause (`VK_PAUSE`) vs NumLock
  (`VK_NUMLOCK`) by VK [platform §5]; `VK_PROCESSKEY` (IME owns the key) → no key event.
- Action: press / repeat (lParam bit 30) / release.
- Mods: from `GetKeyState` per VK (`VK_LSHIFT…VK_RWIN`), sides set, `caps_lock`/`num_lock` from toggle bit.
- AltGr: the layout has AltGr if `VkKeyScanExW` of any char in the layout reports shift-state bits Ctrl+Alt (computed per
  HKL on `WM_INPUTLANGCHANGE`, cached). A `VK_LCONTROL` key-down whose `GetMessageTime()` equals the following `VK_RMENU`
  key-down is the synthetic AltGr Ctrl → swallowed. When RAlt is down on an AltGr layout and the event produced text,
  `consumed_mods = {ctrl, alt}` and both are removed from `mods`.
- Ctrl/Alt text: C0 control characters (< 0x20, 0x7F) produced by WM_CHAR are dropped from `utf8`; core encodes them from
  `key` + `mods`. `unshifted_codepoint` = `ToUnicodeEx(vk, scancode, empty_state, …, flags = 0x4)` (no kbd-state change)
  on the current HKL.
- Dead keys: `WM_DEADCHAR` → `KeyEvent{ composing = true, utf8 = dead char }` and `preeditCallback(dead char)`; the
  next composed `WM_CHAR` clears preedit and is sent as text with the key event.
- IME (IMM32, `ime.zig`): `WM_IME_STARTCOMPOSITION` (position via `ImmSetCompositionWindow`/`ImmSetCandidateWindow`
  at `core.imePoint()`), `WM_IME_COMPOSITION` (`GCS_COMPSTR` → `preeditCallback`, `GCS_RESULTSTR` → `textCallback` +
  clear preedit), `WM_IME_ENDCOMPOSITION` → `preeditCallback(null)`. We draw the preedit ourselves (core does), so
  `WM_IME_SETCONTEXT` clears `ISC_SHOWUICOMPOSITIONWINDOW`. TSF is out of scope until a user-visible IMM32 gap is found.
- win32-input-mode (CSI ?9001h): not implemented in v1 (core ignores the mode; conhost falls back to VT input).
Mouse (`mouse.zig`): client px → `cursorPosCallback`; buttons L/R/M/X1/X2 with `SetCapture`/`ReleaseCapture`;
`WM_MOUSEWHEEL`/`WM_MOUSEHWHEEL`: offset = delta / 120.0, `precision = delta % 120 != 0`; `TrackMouseEvent(TME_LEAVE)`
→ leave handling as GTK does; `WM_SETCURSOR` in client area applies the current `mouse_shape` (`IDC_*` map; hidden for
`mouse_visibility = hidden`).

### 7.4 Clipboard (`clipboard.zig`)
- `supportsClipboard`: `.standard` only. `setClipboard`: `OpenClipboard(surface_hwnd)` (retry 5× 10 ms on failure),
  `EmptyClipboard`, `CF_UNICODETEXT` from `text/plain` content (CRLF not added; bytes as given). `confirm = true` → confirmation
  dialog "Allow this program to write to the clipboard?" (OSC 52) first.
- `clipboardRequest`: returns `.started`, posts `WM_GHOSTTY_CLIPBOARD_READ` to itself; the handler reads `CF_UNICODETEXT`
  and calls `core.completeClipboardRequest(req, .{contents, available = true, confirmed = false})` exactly once (never
  re-entrantly inside `clipboardRequest`). `error.UnsafePaste`/`UnauthorizedPaste` → confirmation dialog with a 512-char preview,
  "Paste"/"Cancel"; Paste re-calls with `confirmed = true`, Cancel → `denyClipboardRequest`.
- `copy-on-select = clipboard|true` works through core; `selection`/`primary` clipboard requests return `.unsupported`.

### 7.5 Chrome, Mica, titlebar (M2) and overlays (M2/M3)
- Custom frame: `DwmExtendFrameIntoClientArea` (top inset = tab-strip height), `WM_NCCALCSIZE` removes the caption,
  `WM_NCHITTEST` returns `HTCAPTION` on empty strip area and `HTMAXBUTTON` on our maximize button (snap layouts flyout),
  `DWMWA_USE_IMMERSIVE_DARK_MODE` from `window-theme`/system theme, `DWMWA_SYSTEMBACKDROP_TYPE = DWMSBT_MAINWINDOW` (Mica)
  under the titlebar/tab strip only (ruling §18: terminal surfaces stay opaque unless `background-opacity` < 1, M3);
  caption buttons drawn by us (Segoe Fluent Icons glyphs).
- Tab strip + overlays rendered by Direct2D/DirectWrite into the top-level window (`Chrome.zig`); first M2 task is a spike
  proving Mica + child-HWND swap chains + D2D chrome coexist (risk R9).
- M1 has no custom chrome: standard captioned window with immersive dark mode attribute only.

### 7.6 Dialogs
M1: `MessageBoxW` (OK/Cancel) for close confirmation, unsafe paste and OSC 52 — no struct-packing risk. M2: `TaskDialogIndirect`
(comctl32 v6 via the manifest dependency, already declared) with custom button labels and config-errors dialog; note
`TASKDIALOGCONFIG` is declared under `pshpack1.h` (1-byte packing) in `commctrl.h`. Owned by the top-level window; modal.

## 8. Core changes (platform-gated)

### 8.1 Compile/link fixes (M1 first)
[build §4] #1-8 and [platform §8] blockers 1-2, 4: posix_c includes, `Exec.zig:2003/2007` arity, HANDLE-typed quit pipe
(`CloseHandle`/`WriteFile`), `main_ghostty.zig:78` `std.io.getStdOut` (gone), memset quirk vs `libvcruntime` (drop the
strong override on `windows-msvc` artifacts), glad only for OpenGL, Dmabuf/EGL not analysed because OpenGL is not selected.

### 8.2 Config path (D9)
- `src/os/homedir.zig` `homeWindows`: `USERPROFILE` → `HOMEDRIVE`+`HOMEPATH` → null; `expandHome` expands `~/` and `~\`.
- `src/os/xdg.zig`: `config()` = `XDG_CONFIG_HOME` (non-empty) else `<home>\.config`; `cache()`/`state()` keep `LOCALAPPDATA`.
  Implemented as a per-kind `windows_env: ?[]const u8` (null for config).
- Legacy `config` filename not read on Windows: `Config.zig` `loadDefaultFiles`, `file_load.zig` `preferredXdgPath`,
  `config/edit.zig` `configPathCandidates`. First-run template creation at the new path is existing behaviour.
- Path is built per component (`"ghostty", "config.ghostty"`) so the result is `C:\Users\x\.config\ghostty\config.ghostty`.

### 8.3 Default shell (Config.zig `.windows` arm → `internal_os.windows_shell.resolve`)
Only when `command == null`. Returns `.direct` argv (spaces survive) and a kind:
1. **Git Bash**: first existing of `%ProgramFiles%\Git\bin\bash.exe`, `%ProgramW6432%\Git\bin\bash.exe`,
   `%ProgramFiles(x86)%\Git\bin\bash.exe`, `%LOCALAPPDATA%\Programs\Git\bin\bash.exe`, registry
   `HKLM|HKCU\SOFTWARE\GitForWindows\InstallPath` + `\bin\bash.exe`, `git.exe` on PATH → `<git>\..\..\bin\bash.exe`.
   Never a bare `bash` from PATH (`System32\bash.exe` is WSL). argv `{bash.exe, "--login", "-i"}`; adds `CHERE_INVOKING=1`
   to config `env` unless the user set it.
2. **pwsh**: `pwsh.exe` via PATH+PATHEXT, `%ProgramFiles%\PowerShell\7\pwsh.exe`, `%LOCALAPPDATA%\Microsoft\WindowsApps\pwsh.exe`;
   argv `{pwsh.exe, "-NoLogo"}`.
3. **cmd**: `%COMSPEC%` else `%SystemRoot%\System32\cmd.exe`; argv `{cmd.exe}`.
Logs `default shell kind=… path=…` at info. Existence = `GetFileAttributesW` ≠ INVALID and not a directory. The resolver
takes an injectable probe (`exists: *const fn (path: []const u8) bool`, `env` map, registry reader) for tests.
Spawn failure of a resolved shell is reported by core's abnormal-exit message; no automatic retry in v1.

### 8.4 termio/Exec on Windows
- Read thread: out pipe becomes an overlapped named pipe (like `in_pipe`); loop = `ReadFile` overlapped +
  `WaitForMultipleObjects({read_event, quit_event})`; `threadExit` sets `quit_event` (no CancelIoEx race). Buffer 64 KiB.
- Child tree lifetime: a Job object with `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` per surface; process created
  atomically in the job via `PROC_THREAD_ATTRIBUTE_JOB_LIST` in the existing attribute list (nested with libxev's own
  pid-filtered job). Closing the surface closes the job. On the pseudo-console path `bInheritHandles = FALSE`.
- ConPTY handles: the pty-side ends (`in_pipe_pty`, `out_pipe_pty`) are closed right after `CreateProcessW` succeeds
  (as in the Microsoft sample); otherwise the read loop never sees EOF after `ClosePseudoConsole`.
- After child exit: `ClosePseudoConsole` on a helper thread, drain the out pipe to EOF (≤ 500 ms) before reporting exit.
- `.shell` command strings are tokenized with Windows rules (double quotes, backslash-quote) instead of whitespace split.
- ConPTY flags stay `0` in M1; passthrough/INHERIT_CURSOR evaluated in M5.

### 8.5 Later core changes
M4: DCS `tmux;` passthrough unwrap in `src/terminal/dcs.zig` [tmux §10]; `SplitTree.replace`. M5: OSC 7 path translation
(`/c/x`, `/C:/x` → `C:\x`) in `stream_handler.zig`, case-insensitive hostname compare, `.exe`-stripping shell detection,
pwsh integration, forward-slash env paths for MSYS shells, compiled terminfo emitted by the build (then `TERM`
default back to `xterm-ghostty`), `+edit-config` on Windows.

## 9. Fonts
Fonts M1: `freetype_windows` discovery gets a one-time index (family, style name, weight, italic, ttc index per file,
built lazily on first query, ~300 files) and style ranking for bold/italic/bold-italic; codepoint fallback tries a fixed
list first (Segoe UI Emoji, Segoe UI Symbol, Cascadia Mono, Consolas, Yu Gothic, Malgun Gothic, Microsoft YaHei, SimSun)
then the index. Font files are opened through UTF-16 paths (W APIs + read-only file mapping → FreeType memory face), never
`FT_New_Face(path)` with a narrow path, so per-user fonts under non-ASCII profiles load without a UTF-8 code page.
Emoji: Win11 Segoe UI Emoji is COLRv1; FreeType's `FT_LOAD_COLOR` path covers COLRv0 only, so M1 verifies colour
rendering and, if it fails, ships monochrome system emoji as a known gap (embedded Noto Color Emoji stays available) until
M3. M3: DirectWrite discovery + `IDWriteFontFallback::MapCharacters` [platform §4.2]; rasterization stays
FreeType + HarfBuzz.

## 10. Child environment
- Base: `global.environMap()` (Ghostty's own env) minus nothing Windows-specific in M1.
- `TERM`: Windows default `xterm-256color` (config default changed on Windows only) until the compiled terminfo ships
  (M5); `COLORTERM=truecolor`, `TERM_PROGRAM=ghostty`, `TERM_PROGRAM_VERSION`, `GHOSTTY_RESOURCES_DIR`, `GHOSTTY_BIN_DIR`
  unchanged from core.
- PATH: core appends the exe dir today. Windows (M4): **prepend** the exe dir (shim dir = exe dir, DECISIONS) and set
  `TMUX=\\.\pipe\ghostty-tmux-<pid>,<pid>,0`, `TMUX_PANE=%<n>` per surface (§12). Before M4 PATH behaviour is unchanged.
- Git Bash: `CHERE_INVOKING=1` (§8.3). MSYS-facing path vars use forward slashes from M5.

## 11. Logging and console (D10)
- `GHOSTTY_LOG` packed-struct flags gain `file` (default true on Windows) and `debugger` (default true on Windows Debug).
  `stderr` default stays `app_runtime != .none` but the Windows stderr sink only writes if the std handle is valid.
- File sink: `%LOCALAPPDATA%\ghostty\logs\ghostty.log`; at startup, if > 5 MiB rename to `ghostty.1.log` (one rotation).
  Lines `<ISO8601> <level>(<scope>): <msg>\n`, mutex-guarded, flushed per line. Debug level only in Debug builds.
- CLI actions (`+version`, `+list-fonts`, `+show-config`, …, `--help`): before running, if `GetStdHandle(STD_OUTPUT_HANDLE)`
  is invalid, `AttachConsole(ATTACH_PARENT_PROCESS)` then reopen `CONOUT$`/`CONIN$` and `SetStdHandle`; if there is no
  parent console (Explorer launch), output goes to the log file only. Implemented in `src/os/windows_console.zig`, called from
  `main_ghostty.zig` only on Windows.
- Panics (M1): a root `panic` override writes the message + stack trace to the file sink and `OutputDebugStringW` before
  aborting (a GUI exe has no valid stderr).
- Known limitation: a GUI-subsystem `ghostty.exe +version` started from interactive `cmd` returns the prompt before the
  output appears; use `ghostty.exe +version | more`, `start /wait`, or a pipe (Git Bash).
- Crash (M5): `SetUnhandledExceptionFilter` + `MiniDumpWriteDump` into `%LOCALAPPDATA%\ghostty\crash\`.

## 12. Built-in tmux shim (M4)

### 12.1 Processes and transport
- `tmux.exe` (console subsystem, no SharedDeps, target startup < 50 ms, private bytes < 5 MB). Steps: parse global flags
  (`-S <path>`, `-L <name>`, `-V`); `-V` → print `tmux 3.5a\n`, exit 0 (no IPC); `load-buffer … -` → read all stdin; resolve
  the pipe: `-S` value, else first field of `TMUX`, else (external mode) the per-user pipe `\\.\pipe\ghostty-<user SID>`
  (M5); connect with `WaitNamedPipeW` ≤ 1000 ms; send one request; print `stdout`/`stderr` verbatim (LF only, no BOM);
  exit with `code`. Connection failure → stderr `no server running on <path>\n`, exit 1.
- Server (`src/apprt/win32/tmux/Server.zig`): pipe `\\.\pipe\ghostty-tmux-<ghostty pid>`, `PIPE_TYPE_BYTE`,
  `PIPE_REJECT_REMOTE_CLIENTS`, `PIPE_UNLIMITED_INSTANCES`, DACL `D:P(A;;GA;;;<current user SID>)`. One IPC thread
  with overlapped accept; each request is posted to the UI thread (`WM_GHOSTTY_IPC`), executed there, and the reply is
  written back by the IPC thread. Concurrent clients are queued in arrival order (Claude's parallel `kill-pane` at exit).
- Wire format (`src/tmux_shim/protocol.zig`): frame = `u32` little-endian byte length + UTF-8 JSON, max 16 MiB.
  Request `{"v":1,"argv":[…],"cwd":"C:\\…","env":["K=V",…],"stdin":"…"|null}` (env = full client environment, for R1).
  Response `{"code":0,"stdout":"…","stderr":"…"}`. Unknown `v` → code 1, stderr `protocol version mismatch`.

### 12.2 Registry and semantics
- Pane ids `%N` monotonic per Ghostty process (never reused), assigned to every surface at creation (so `TMUX_PANE` is
  valid in every shell, including non-tmux-created ones). Window ids `@N` = Ghostty **tab** (tmux window ≙ tab).
  Session = the Ghostty process (`session_name` = `0`).
- Command table = [tmux §4] rows 1-15 + [tmux §9] startup calls, implemented exactly as specified there (argv shapes,
  stdout format, exit codes, error texts `can't find pane: %N`, `no space for new pane`, `create pane failed: pane too small`).
  Ghostty mapping:
  - `split-window -t %P [-h|-v] [-l N%] [-d] [-P -F fmt] -- cmd`: `SplitTree.split` of `%P` (`-h` → right, `-v` → down),
    ratio from `-l` (size of the NEW pane), focus unchanged with `-d`; refuse when the new pane would be below the core
    min size (`no space for new pane`, exit 1).
  - `respawn-pane -k -t %N -- "<sh string>"`: build a new surface (command/env/cwd from §12.3) and swap it into the same
    leaf with the new core `SplitTree.replace` (geometry unchanged); `%N` re-points to the new surface; the old one is
    closed without confirmation.
  - `kill-pane -t %N`: close the surface without confirmation; last pane of a tab closes the tab.
  - `select-layout -t @W main-vertical` + `resize-pane -t %L -x 30%`: rebuild the tab tree as leader column (left, 30%)
    + teammates stacked vertically (equal) on the right; `tiled` → equal grid. Other layouts: accepted no-op, exit 0.
  - `select-pane -T title` → surface title override (no focus change); `set-option -p|-w …` → stored per pane/window; `window-style
    fg=<colour>` and `pane-border-*` stored and, from M4 polish, rendered as a coloured title label on the split.
  - `remain-on-exit failed`: pane surfaces created by the shim get `wait-after-command = true`; on `show_child_exited` the
    apprt closes the pane if `exit_code == 0` and the option is `failed`, else shows the exited bar.
  - `display-message -p [-t] fmt` / `list-panes -F` / `list-windows -F`: `#{var}` expansion (`format.zig`) for
    `pane_id window_id window_name session_name pane_title pane_top pane_left client_termtype allow-passthrough
    focus-events status status-position window_bigger client_control_mode` with the safe answers of [tmux §9].
  - `show-environment -g` → empty, exit 0. `load-buffer [-w] -` → store buffer; `-w` also sets the Windows clipboard.
  - Placeholder `cat`: a command string exactly `cat` starts `tmux.exe __idle` (blocks reading console input until
    killed); never a shell.
### 12.3 Pane command execution (R1, R2)
- Env (R1): Ghostty `defaultTermioEnv` overlaid with the request's client `env`, then `TMUX`, `TMUX_PANE`, PATH with exe
  dir first, then the command's own `env K=V` assignments.
- Command (R2): if Git Bash is resolvable (§8.3 list, plus `CLAUDE_CODE_GIT_BASH_PATH` from the client env first) →
  argv `{<git>\bin\bash.exe, "-c", <string>}` with cwd = client cwd; else `sh_command.parse(string)` for the grammar
  `[cd W &&] [env (NAME=W)*] W+` with POSIX single/double-quote rules and `'"'"'` escapes, no expansions → direct argv,
  cwd from `cd`, env overrides; parse failure → exit 1, stderr `ghostty: unsupported pane command`.
### 12.4 Other
- DCS passthrough `ESC P tmux; … ESC \` is unwrapped by core and re-fed to the parser (notifications/titles from Claude).
- XTVERSION is not spoofed (images stay disabled under TMUX; accepted).
- External mode (`TMUX` unset, `-L`) and the `claude-swarm` session namespace: M5.
### 12.5 Contract tests
`src/tmux_shim/*` unit tests (argv parser, format expansion, sh_command grammar incl. the [tmux §6] Windows example) and an
apprt-level replay test that runs the exact spawn sequence of [tmux §4 notes] against a headless registry and asserts
stdout bytes, exit codes and resulting tree shape.
### 12.6 Single instance / `performIpc`
M2 adds a per-user pipe `\\.\pipe\ghostty-<user SID>` served by the same IPC thread for `+new-window`/`+new-tab`/
`+toggle-quick-terminal`. Single-instance is ON by default (ruling, §18): a second launch forwards `new_window` (with its
`--working-directory`) to the running instance and exits; an opt-out config follows the GTK `gtk-single-instance` pattern.

## 13. Packaging (M6)
- Portable zip `ghostty-<ver>-windows-<arch>.zip`: `ghostty.exe`, `tmux.exe`, `share\ghostty\…` (themes, shell-integration,
  terminfo source), `share\terminfo\…`, `LICENSE`, `README-windows.txt`. Resources found via existing `resourcesdir.zig`.
- Inno Setup (`dist/windows/installer/ghostty.iss`): per-user install default (`{localappdata}\Programs\Ghostty`), Start
  Menu shortcut with AUMID `com.mitchellh.ghostty.windows-unofficial`, optional desktop shortcut,
  Explorer "Open Ghostty here" (HKCU `Directory\shell` + `Directory\Background\shell`, `ghostty.exe --working-directory="%V"`),
  uninstaller removes both. No PATH change.
- Toasts (ruling): Ghostty itself registers the AUMID under `HKCU\Software\Classes\AppUserModelId\<AUMID>`
  (`DisplayName`, `IconUri`) on first notification and calls `SetCurrentProcessExplicitAppUserModelID`, so the portable
  zip gets toasts too; the uninstaller removes the key.
- Version resource fields from `build_config.version` (generated `.rc` include), product name "Ghostty — Unofficial Windows port".
- CI (GitHub Actions): `windows-latest` x64 build + tests; ARM64 cross-build on x64 and tests on `windows-11-arm`;
  release workflow on tag `v*` uploads zip + installer for both arches as a GitHub pre-release.

## 14. RAM budget
Measured by `test/windows/measure-ram.ps1`: launches `ghostty.exe` with `XDG_CONFIG_HOME` pointing at a temp config
(defaults + `command = direct:cmd.exe /k`), waits until the window is visible + 10 s idle, samples
`Get-Process -Id <pid>` → `PrivateMemorySize64` (**Private Bytes**, the budgeted number) and `WorkingSet64` (reported),
ghostty.exe only (conhost/OpenConsole and shells are reported separately, not budgeted). Steps for extra tabs/splits/windows
are driven by keybind `SendInput` (M2+). Output: one CSV row per scenario appended to `docs/windows/ram-baseline.csv`
(date, commit, optimize, adapter, scenario, private_mb, ws_mb). Budgeted numbers are measured on `-Doptimize=ReleaseFast`
builds (Debug numbers may be recorded with `optimize=Debug` but are never gated). The scrollback scenario uses
`cmd /c "for /L %i in (1,1,200000) do @echo %i"` (there is no `seq` in cmd).

| Scenario (100% DPI, default font/config, idle) | v1.0 target (Private Bytes) | M1 gate |
|---|---|---|
| 1 window, 1 surface | ≤ 80 MB | ≤ 110 MB (+ baseline recorded) |
| each extra surface (tab or split) | ≤ +10 MB | measured from M2 |
| each extra window (1 surface) | ≤ +15 MB | measured from M2 |
| surface after `seq 1 200000` (scrollback full at default `scrollback-limit` 10 MB) | ≤ surface cost + 15 MB | recorded |
| close 10 extra surfaces, wait 30 s | back within +10% of the pre-open value | from M2 |
| tmux.exe per invocation | ≤ 5 MB, ≤ 100 ms wall | M4 |
Levers if over budget: shared D3D device (D3), lazy font-face loading, atlas initial size, `scrollback-limit` (user),
`EmptyWorkingSet` is NOT used (it only hides private bytes).

## 15. Testing strategy
1. **Upstream unit tests on Windows**: `zig build test -Dtest-filter=<f>` locally (focused; full suite only via test-lock;
   Debug test exe is slow on Windows [build §3.2]); full `zig build test` + `test-lib-vt` in CI (timeout 90 min).
2. **Windows-specific unit tests** in the normal test exe (names start with `win32 `, `d3d11 `, `windows `, `tmux shim `
   so `-Dtest-filter` selects them): bindings vtable sizes, key translation with real layouts loaded by
   `LoadKeyboardLayoutW` (`00000409` US, `00000407` DE, `00000419` RU, `00000411` JP), shell resolver with fake probes,
   config path with spaces/non-ASCII homes, sh_command grammar, IPC framing, tmux format/argv/replay.
3. **Renderer tests (headless)**: WARP device (`GHOSTTY_D3D11_DRIVER=warp` not needed — tests construct WARP explicitly),
   render to an offscreen `Target`, copy to a staging texture, assert pixels (clear colour, a cell background, a glyph
   from a synthetic atlas, image pipeline quad). Swap chain test uses a hidden test HWND.
4. **App-level (process) tests** — `test/windows/*.ps1`, run manually or in CI:
   - `launch.ps1 -Config <file> [-Driver warp]` → starts ghostty with an isolated `XDG_CONFIG_HOME`, returns pid + HWND.
   - `capture-window.ps1 -Hwnd <h> -Out <png>` → `PrintWindow(PW_RENDERFULLCONTENT)` (works for DXGI content) to PNG;
     `-Probe x,y` prints the BGRA at a pixel for automatic asserts (e.g. background colour from config).
   - `send-input.ps1 -Hwnd <h> -Text <s> | -Keys <chord>` → `SendInput` (unicode and VK paths).
   - Safety on the owner's machine (shared module `test/windows/lib/Harness.psm1`): pre-check for an interactive,
     unlocked session with a usable foreground window, else every GUI scenario reports `SKIP` (recorded, never `FAIL`);
     foreground via `AllowSetForegroundWindow` + Alt-tap; layouts switched by posting `WM_INPUTLANGCHANGEREQUEST` to the
     Ghostty HWND; the original keyboard layout is restored and only layouts that were not loaded before
     (`GetKeyboardLayoutList` diff) are unloaded — also in unit tests that call `LoadKeyboardLayoutW`.
   - Primary pixel oracle: `GHOSTTY_D3D11_DUMP=<dir>` makes the renderer write the presented target to
     `<dir>\surface-<n>.bmp` (at most 4 per second); `PrintWindow` capture is secondary (black on locked/RDP-minimised desktops).
   - End-to-end checks use the shell itself as oracle: type `echo <token> > %TEMP%\gt-<id>.txt`, then assert the file.
   - Visual checks: after every UI/renderer task the implementer attaches a screenshot path in the report and inspects it.
5. **RAM**: `measure-ram.ps1` per milestone (§14).
6. **Claude Code tmux e2e (M4)**: (a) automated replay of the tmux spawn sequence through the real `tmux.exe` + running
   Ghostty; (b) scripted real run: Ghostty → Git Bash → `claude --agent-teams --teammate-mode tmux` with a prompt that
   creates a 2-teammate team; pass = 3 panes in main-vertical layout, titles set, teammates exchange messages, shutdown
   closes panes, leader exit leaves no orphan panes/processes. (b) is the v1.0 acceptance (DECISIONS) and also run by the owner.
7. **vttest-style**: `test/windows/vt-smoke.ps1` (M3) prints esctest/vttest-like sequences through Git Bash and compares
   screenshots against reference PNGs with a tolerance.

## 16. Risks and mitigations
| # | Risk | Mitigation |
|---|---|---|
| R1 | COM vtable slot mistakes crash at runtime | Spike first (M1 Task 2): WARP device + clear + readback + D3DCompile; slot-count tests per interface against SDK headers; methods used only through typed wrappers. |
| R2 | libxev IOCP backend (Async/Timer/Process/Stream) untested in Ghostty | M1 core-compile task runs termio/xev tests; M1 Exec task has a spawn/exit/close test; bugs fixed in a vendored libxev patch (path override) and offered upstream. |
| R3 | Exec.zig Windows path bugs / read-thread hang on close | §8.4 event-based read loop; tests: close while `cmd /c type bigfile` streams; `cmd /c exit 3` exit code. |
| R4 | Debug test exe very slow on Windows | Focused filters locally; ReleaseSafe investigation note in M1; CI timeout 90 min. |
| R5 | Upstream rebases conflict | Windows code in own dirs; core patches small and gated; rebase onto upstream main at the end of every milestone; plans list every core touch point. |
| R6 | Shared device lock contention / device loss affects all surfaces | Lock only around frame encode; waitable wait outside the lock; per-surface-device switch kept possible (§6.3); recovery in M3. |
| R7 | Keyboard edge cases (AltGr, dead keys, IME, RU shortcuts) | Pure translation functions with real-layout tests; manual checklist DE/PL/RU/JP in M1 acceptance. |
| R8 | GUI subsystem hides CLI output and logs | §11 console attach + file log; `+version` test from cmd/pwsh/Git Bash. |
| R9 | Mica + child-HWND swap chains + D2D chrome do not compose as expected | First task of M2 is a spike; fallback = chrome in a separate child HWND strip with opaque Mica-tinted colour. |
| R10 | Transparency needs DComp (retrofit) | Swap chain behind `SwapChain.zig` modes (D4); M3 adds `composition` mode only. |
| R11 | Claude Code tmux contract drift | Re-run the extraction recipe of [tmux] header at each milestone; replay tests pinned to recorded argv. |
| R12 | Git Bash `bash -c` (R2) mangles Windows env/paths for teammates | Pass Windows paths only inside quoted args; e2e test covers it; built-in parser path also tested; owner may flip R2 order. |
| R13 | Font discovery cost (O(files) per query) and wrong styles | M1 index + ranking; M3 DirectWrite. |
| R14 | RAM budget missed due to GPU driver UMD | Measure in M1 on hardware + WARP; shared device; report per-adapter numbers; owner decides if target moves. |
| R15 | MSVC toolchain/ARM64 libs on CI | R3 MSVC; GitHub images ship VS Build Tools with ARM64; fallback `-gnu` noted. |
| R16 | Unsigned binaries + named pipes trigger SmartScreen/AV | Accepted (DECISIONS); README documents it; no code injection/hooks used. |
| R17 | Low-RAM dev machine | Builds `-j4` via test-lock only; tasks verify with focused filters. |

## 17. Milestones
Each milestone ends with: upstream rebase, RAM measurement row, screenshot set in the report, owner-visible changelog.

**M1 — core builds + single-window terminal.** Core compiles and focused tests pass on Windows; `ghostty.exe` opens one
window (standard caption, dark mode attr), D3D11 renders text (embedded JetBrains Mono), ConPTY + default shell (Git Bash
`--login -i` with CHERE_INVOKING → pwsh → cmd), keyboard incl. AltGr/dead keys, IMM32 IME basics, mouse select/scroll,
clipboard copy/paste with confirmations, config at the single path (first-run template), basic per-monitor DPI, logging.
Exit criteria: (1) `zig build -j4` produces `zig-out\bin\ghostty.exe`; (2) Windows unit tests (`win32 `, `d3d11 `,
`windows ` filters) pass; selected upstream filters pass (`terminal`, `config`, `input`, `font`); (3) launch → Git Bash prompt
in `%USERPROFILE%` in ≤ 1.5 s, screenshot shows correct text/colours; (4) `echo` oracle e2e passes for US text, DE AltGr `@`,
RU text, Ctrl+C interrupt; (5) `vim`/`less` in Git Bash usable (`TERM=xterm-256color`); (6) closing the window terminates the
shell tree (no orphan `bash.exe`/`conhost.exe`); (7) RAM ≤ 110 MB private (1 window, `ReleaseFast`), baseline row
recorded; (8) no hang on close while output streams or during live resize; (9) `exit` in the last shell closes the window
and ends the process ≤ 3 s; (10) `aarch64-windows-msvc` compiles (recorded, not gating). GUI scenarios that cannot run on
a locked/non-interactive desktop are recorded as SKIP and re-run interactively before sign-off.

**M2 — tabs, splits, multi-window, Mica, titlebar, DPI, keybind actions.** Custom frame (caption removed, DWM-extended,
Mica under the titlebar/tab strip, own caption buttons, `HTMAXBUTTON` snap layouts, `window-decoration` client/server/none),
Direct2D/DirectWrite tab strip (select, close, middle-click, new, drag reorder, overflow scroll, inline rename = `prompt_title`),
tabs and splits over core `SplitTree` (one container HWND per tab, one child HWND per surface; divider drag, zoom, equalize,
goto, resize), multiple windows (cascade, goto/present, move tab to new window), maximize/fullscreen/float/decorations toggles,
per-monitor DPI incl. hidden tabs, theme (`window-theme`, titlebar colours, system colour scheme → conditional config), config
reload (soft/hard) and `open_config`, native scrollbar, bell (title/attention/system/audio), taskbar progress, resize overlay
(owned popup), TaskDialog close confirmations, named-pipe IPC + single-instance (`windows-single-instance`) + `performIpc` +
test-only IPC ops, `quit-after-last-window-closed`. Every `Action.Key` is classified implemented / deferred (milestone) /
unsupported by `apprt/win32/actions.zig`. Exit: action-coverage test green; M1+M2 e2e green on Debug and ReleaseFast;
screenshots at 100/150/200% (simulated through the test DPI op; real multi-monitor checked by the owner); per-tab/split/window
and close-10 RAM rows within §14 targets. Plan: `docs/windows/plans/M2-tabs-splits-windows.md`.

**M3 — feature parity.** Quick terminal (`RegisterHotKey`, slide), command palette, search bar, notifications (toast with
AUMID self-registered under HKCU, §13), URL hover/open (`ShellExecuteW`, untrusted URL validation),
inspector (imgui win32+dx11), config-errors dialog, custom shaders (HLSL via SPIRV-Cross), Kitty graphics
and background image verified, transparency + blur (DComp composition swap chains), DirectWrite discovery/fallback,
device-loss recovery + renderer-health bar, key-sequence/table indicator, export-terminal-io save dialog, vt-smoke
screenshots; from M2: unfocused-split dimming and `bell-features = border` (DComp overlay visuals), readonly badge, tab
tear-off by drag, `toggle_visibility` (with global hotkeys), `toggle_background_opacity`. Exit: feature checklist (one line per cross-platform feature) all green with a test or screenshot each.

**M4 — tmux shim + IPC + Claude Code e2e.** `tmux.exe`, IPC server, registry, all §12 semantics, DCS tmux unwrap,
`SplitTree.replace`, PATH prepend + TMUX/TMUX_PANE in every surface. Exit: replay test green; real Claude Code agent-team
run (§15.6b) green twice in a row; tmux.exe ≤ 5 MB / ≤ 100 ms.

**M5 — Windows extras.** Jump lists (new window/tab, profiles), shell-profiles dropdown (Git Bash, pwsh, cmd, WSL distros
from `wsl.exe -l -q`), Explorer "Open Ghostty here" (`+install-explorer-integration` + installer), pwsh integration
(OSC 133/7/title), Git Bash integration fixes, OSC 7 translation, compiled terminfo + `TERM=xterm-ghostty`, `+edit-config`,
update check (`auto-update = check|off`, GitHub Releases via WinHTTP, toast), crash minidumps, external tmux mode,
Windows analogs of macOS-only actions (`secure_input`, `undo`/`redo`), on-screen keyboard.
Exit: each feature has a test or scripted screenshot; update check tested against a fake release JSON.

**M6 — packaging, CI, release.** Zip + Inno Setup (x64 + ARM64), version resource, GitHub Actions (build + tests on x64
and `windows-11-arm`, release on tag), pre-release published, v1.0 gate of DECISIONS (feature checklist closed, RAM rows,
Claude Code run, owner smoke). Exit: owner sign-off.

## 18. Rulings on former open questions (lead, 2026-10-25; owner may overturn)
1. Single-instance: ON by default — a second launch opens a new window in the running instance (§12.6).
2. Mica: titlebar/tab strip only; terminal surfaces stay opaque by default (§7.5).
3. Toasts: AUMID self-registered under HKCU; works for the installer and the portable zip (§13).
4. Cache/state/logs/crash dumps: `%LOCALAPPDATA%\ghostty\` (D9); only config lives under `%USERPROFILE%\.config`.

Rulings for M2 (architect-m2, 2026-10-26; lead/owner may overturn):

5. IPC wire format (amends §2, §12.1, §12.6): `src/apprt/win32/ipc/protocol.zig` (std only; `tmux.exe` imports it as a
   module in M4). Frame = `u32` LE length + UTF-8 JSON, max 16 MiB. Request `{"v":1,"op":"…",…}`, response
   `{"v":1,"code":N,"stdout":"…","stderr":"…","data":…}` (codes 0 ok, 1 failed, 2 bad request/unknown op, 3 version).
   M2 ops `new-window`, `new-tab`, `toggle-quick-terminal`; M4 adds op `tmux` carrying the §12.1 fields. Per-user pipe
   `\\.\pipe\ghostty-<user SID>-<session id>-<class>` (class = config `class` sanitized, default `com.mitchellh.ghostty`,
   Debug builds `com.mitchellh.ghostty-debug`), so other sessions, builds and test instances never meet. Cost if wrong:
   rename of a pipe constant.
6. Single instance (amends §12.6): config `windows-single-instance = detect|true|false`, default `detect` = forward unless
   the command line has anything besides `--working-directory=`, `--title=`, `--command=`, `--shell-integration=`, or uses
   `-e`. The second process's cwd is not forwarded (Start-menu cwd is meaningless); Explorer passes `--working-directory`.
   The first instance always serves the pipe when it can claim the name. Cost if wrong: one default flip.
7. `quit-after-last-window-closed` defaults to `true` on Windows (as on Linux); `false` keeps a windowless process only
   while it serves the pipe (reachable by the next launch), otherwise it quits with a log line. Cost if wrong: default flip.
8. Test-only IPC ops `state`, `action`, `dpi`, `color-scheme` answer only when Ghostty was started with
   `GHOSTTY_WIN32_TEST_IPC=1`; e2e uses them instead of system-wide DPI/theme changes (owner-machine safety). Cost if
   wrong: none for users.
9. Chrome painter backend is decided by M2 Task 12 (spike): software `ID2D1DCRenderTarget` on a buffered-paint DC
   (expected), `ID2D1HwndRenderTarget`, or the R9 opaque fallback without Mica. The lead records the result here.
10. One container child HWND per tab holds that tab's surfaces; hidden tabs are hidden containers (surfaces occluded);
    split gaps are 4 px at 96 dpi painted with `split-divider-color` (theme default otherwise).
11. Scrollbar = native `WS_VSCROLL` on the surface, always visible with `scrollbar = system` (`SIF_DISABLENOSCROLL`, no grid
    reflow when scrollback first appears), dark via the `DarkMode_Explorer` theme; none with `scrollbar = never`.
12. Frame dumps are named `surface-<apprt surface id>.bmp` (first surface = 1); headless renderers keep the index.
13. `bell-features = audio` plays WAV files through `PlaySoundW`; `bell-audio-volume` is ignored on Windows in M2.
