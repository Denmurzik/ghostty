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
                                 M4:  tmux/{Server.zig (pipe, routing), env.zig (TMUX/TMUX_PANE/PATH), Registry.zig (real host,
                                      remain-on-exit), commands.zig (semantics over a duck-typed Host), FakeHost.zig (headless
                                      host for the replay test), layout.zig (main-vertical, tiled, ratios), spawn.zig (R-M4-5),
                                      pane_io.zig + keys.zig (send-keys gate, capture-pane), labels.zig (pane border labels)}
                                      ipc/protocol.zig carries the tmux wire fields (module `ipc_protocol` for tmux.exe)
src/tmux_shim/                   tmux.exe: main.zig (entry), run.zig (testable logic), pipe.zig (client transport), win.zig
                                 (own kernel32 externs); cli.zig (tmux argv parser), format.zig (#{var} expansion),
                                 sh_command.zig (POSIX one-liner parser, R2): the last three are std only and also compiled
                                 into the main test exe
src/build/GhosttyTmuxShim.zig    builds/installs tmux.exe next to ghostty.exe, step test-tmux-shim (M4)
src/os/windows_shell.zig         default shell resolver (Git Bash → pwsh → cmd)
src/os/windows_console.zig       console attach for CLI actions
test/windows/                    PowerShell harness: launch.ps1 capture-window.ps1 send-input.ps1 measure-ram.ps1 measure-tmux.ps1
                                 claude-team.ps1 (real Claude Code runs, lib/ClaudeRun.psm1) (+README)
dist/windows/                    ghostty.rc/.manifest/.ico (exist), installer/ghostty.iss (M6), portable layout (M6)
```

Rules: Windows code goes in the paths above; core edits are `comptime builtin.target.os.tag == .windows`-gated or are
platform-neutral improvements (e.g. `SplitTree.replace`). Every core touch point is listed in the plan that makes it.

## 3. Build integration

- New enum members: `apprt.Runtime.win32` (default on Windows), `renderer.Backend.d3d11` (default on Windows). OpenGL is
  not supported on Windows (no EGL); `-Drenderer=opengl` with a Windows target is a build error with a clear message.
- ABI: MSVC for x64 (R3; `src/build/Config.zig:105-116` already forces it): `x86_64-windows-msvc`. The ARM64 release artifacts use `aarch64-windows-gnu` (R-M6-11; amends R3, owner sign-off pending); `-Arm64Abi msvc` once the Visual Studio ARM64 component is installed.
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
- Release recipe flags (R-M6-3): `-Doptimize=ReleaseFast -Demit-themes=true -Demit-terminfo=true -Dstrip=false` (PDBs, shipped only in `-symbols.zip`) `-Dtic=<Git's tic.exe> -Dversion-string=<zon>-win.<N> -Dconpty-dir=<arch dir>`, an explicit `-Dtarget`, `-j4`, and `ZIG_GLOBAL_CACHE_DIR` set to a neutral folder so the user name stays out of the files.
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
- **Exception (M3, R-M3-4):** the inspector's own swap chain. The imgui inspector window is a separate top-level
  `GhosttyInspector` window per surface; it draws on the UI thread from a 30 Hz timer (only while open, visible and not
  iconic) with the shared device under `Device.lockContext` and owns a UI-thread swap chain (created, resized, presented
  and released there, `ClearState` after its draw). It is the only place where the UI thread calls DXGI; it never touches
  a surface's chain. A composition (DComp) swap chain of a terminal surface is created on the render thread and handed to
  the UI thread as an AddRef'd pointer in a posted message (`composition.zig`), the UI thread only attaches it to the
  window's DComp target (§18.21, §18.32).
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

### 6.6 M3 renderer work (done) and what remains
M3 shipped (amended by the rulings of §18, R-M3-1..12):
- **Composition swap chain** only when transparency is configured (`background-opacity < 1` or `background-blur` not
  `false`): a premultiplied-alpha `CreateSwapChainForComposition` chain per surface, attached to one DComp target on
  the window (R-M3-2, §18.21, §18.32); otherwise the surface stays in `hwnd` mode. Overlays are **not** DComp visuals (this
  amends the earlier "visuals for overlays" plan): text overlays are owned `WS_POPUP` windows (§7.5, R-M3-1), and the
  unfocused-split dimming and the bell border are drawn by the D3D11 backend on the frame target before present
  (`Decor.zig` / `decor.hlsl`, driven by a per-surface atomic word, skipped at word 0).
- `background-opacity`/`background-blur`: Acrylic (`DWMSBT_TRANSIENTWINDOW`) for the whole window over a transparent
  client (R-M3-3, §18.22).
- Custom shaders: GLSL (shadertoy) to SPIR-V to HLSL (SPIRV-Cross), `ps_5_0`; the post passes read/write UNORM views so a
  shader sees the same raw framebuffer values as on OpenGL/Metal (Task 7.1). A failing post shader disables all custom
  shaders (as Metal/OpenGL do).
- Device-loss recovery (R-M3-10) and the renderer-health bar; background and Kitty image textures are dropped and
  re-uploaded on a device generation change (platform-neutral hook in `generic.zig`/`image.zig`).
- imgui inspector (`imgui_impl_win32` + `imgui_impl_dx11` in `pkg/dcimgui`, R-M3-4); background image verified on D3D11
  (`vt-smoke/bg-image`).
- Kitty graphics could not be verified end to end in M3: the inbox ConPTY drops APC sequences (§18.33; the bundled ConPTY
  of M5 forwards them).

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
  `render` returns `true` and does nothing (D2). `apprt/win32/actions.zig` (M2) holds the coverage test: every key is
  implemented, deferred to a named milestone, or in an explicit `unsupported` list.
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
- **Overlays (M3, R-M3-1, amends the "DComp overlay visuals" plan of §17):** every overlay is an owned `WS_POPUP`
  (`overlay.zig` host; they follow move/resize/maximize/DPI/minimize/tab switch and tab tear-off): search bar, command
  palette, resize overlay, link label, key-state label, read-only badge, copy toast, health bar, drop highlight is not drawn
  (macOS has none). They paint with the shared Direct2D painter API of `Chrome.zig` and the macOS look (§18.20, DECISIONS
  style rule). Child windows above a flip-model child swap chain hit the airspace problem, DComp visuals are not used.
  Only the search bar and the palette take focus; a popup that needs the owner to look active keeps it so.
- **Window chrome after the owner's macOS redesign (M3 Task 29, DECISIONS 2026-10-27):** a title row (focused surface
  title and a shell-icon proxy for its pwd, centred; Windows caption buttons on the right) and a tab row below it, shown
  with two or more tabs (`window-show-tab-bar`), equal-width tabs with the `goto_tab` shortcut and a hover close button,
  macOS animations, inactive-window dimming. The translucent window is frosted (Acrylic) and stays frosted while
  inactive (`WM_NCACTIVATE(FALSE)` is swallowed except with `window-decoration = server`, §18.22).

### 7.6 Dialogs
M1: `MessageBoxW` (OK/Cancel) for close confirmation, unsafe paste and OSC 52 — no struct-packing risk. M2: `TaskDialogIndirect`
(comctl32 v6 via the manifest dependency) with custom button labels and config-errors dialog. **Since M3 (DECISIONS 2026-10-28)** every
Ghostty dialog is our own modal window in the Windows 11 look (WinUI `ContentDialog`: rounded, Mica, dark/light, Direct2D
text, per-monitor DPI; `src/apprt/win32/dialog/`, same `dialogs.zig` API); `MessageBoxW` remains only as the fallback when
that window cannot be built. Owned by the top-level window; modal. The link and paste confirmations have no accelerator on
"Allow" (the question appears asynchronously; a user who keeps typing must not accept it).

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
M4: DCS `tmux;` passthrough is already unwrapped by the core stream (tests only; the ConPTY gap is documented, R-M4-10, §12.4); `SplitTree.replace`. M5 (as built):
- OSC 7 path translation (`/c/x`, `/C:/x` → `C:\x`) in `stream_handler.zig` (pulled into M3), case-insensitive hostname compare,
  `.exe`-stripping shell detection.
- Shell integration (R-M5-6): pwsh (7 and 5.1) and cmd get OSC 133 A/B/C/D marks independent of the `title` feature; Git Bash keeps
  the upstream bash marks. `setupBash` rewrites `GHOSTTY_RESOURCES_DIR`, `GHOSTTY_BIN_DIR` and `TERMINFO` to the mixed `C:/a/b`
  form (TERMINFO as `/c/...`, §10) and the bash `path` feature is skipped under MSYS (R-M5-8).
- Terminfo (R-M5-7): the build compiles `ghostty.terminfo` with `tic -x` on Windows targets (`-Dtic=<path>`, else `tic` on PATH,
  else Git for Windows' `%ProgramFiles%\Git\usr\bin\tic.exe`) into `share/terminfo/78/{xterm-ghostty,ghostty}`; no `tic` → source
  only and one build warning. The Windows `term` default is `xterm-ghostty` again; Exec sets it only when the compiled entry exists.
- `+edit-config` on Windows (R-M5-8b), `+install-explorer-integration` / `+uninstall-explorer-integration` (R-M5-5,
  `src/os/windows_explorer.zig`), `--profile=<id>` as a launch/IPC argument (R-M5-2, `Overrides.zig`), `windows_shell.profiles` (R-M5-1).
- Windows-only config keys and defaults in `Config.zig`: `windows-jump-list`, `windows-tmux-external`, `auto-update` default `check`,
  `undo-timeout` 5 s with the default binds `ctrl+shift+z` = `undo` / `ctrl+shift+y` = `redo` (R-M5-12a), `right-click-action` default
  `copy-or-paste`. `main_ghostty.zig` turns Zig's segfault handler off on Windows (§11).
- Close confirmation (task #53, `Surface.closeNeedsConfirm`): bash, zsh and pwsh keep `Terminal.cursorIsAtPrompt` (OSC 133). For a
  surface whose shell integration is cmd, which never emits `133;C`, `Exec.shellBusy` asks instead: a Toolhelp snapshot looks for
  a child of the shell (conhost/OpenConsole and processes older than the shell excluded; GUI-subsystem images via
  `src/os/windows_pe.zig` and children with their own console host are ignored; a `--headless` pseudoconsole host such as
  node-pty counts as busy; an unreadable child counts as busy). The zsh integration is loaded under MSYS: `.zshenv` sources a
  drive path directly and the `path` feature is skipped.
- `windows-conpty = auto|bundled|inbox` (default `auto`, read when a surface starts): `termio/Exec.zig` and `src/pty.zig` create
  the pseudoconsole through the bundled `conpty.dll` (§18.33), or the inbox one for an MSYS2/Cygwin `args[0]` under `auto`; a failed create falls back to the inbox table once and disables
  the bundled one for the process.
- Apprt-only features (no core change): jump list (`jumplist.zig`), profile menu, update check (`update/`), `secure_input.zig`
  (R-M5-11), undo (`undo.zig` and the park/restore code in `Window.zig`/`Tab.zig`, R-M5-12), `osk.zig` (R-M5-13), popup menu theme
  (`menu_theme.zig`), the right-click context menu (`context_menu.zig`).

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
M7 (R-M7-3, R-M7-5): symbols and emoji follow macOS and Windows Terminal. In `SharedGridSet` the embedded `emoji` and `emoji_text`
faces (Noto) are added on Windows only when DirectWrite is unusable (`Windows.dw == null`). `Windows.discoverFallback` orders its fixed
list by the requested presentation (text: Segoe UI Symbol before Segoe UI Emoji; emoji: Segoe UI Emoji first); `MapCharacters` stays in
front. Measured (`e2e/font-symbols`): `✓ ⚠ ❯ →` come from JetBrains Mono / the Nerd symbols font, `⏺` and colour emoji from Segoe UI
Emoji (COLR v0 layers render as colour through the FreeType path), no Noto. New Unicode emoji that Segoe UI Emoji lacks show as
missing glyphs; `font-codepoint-map` is the override. `font-thicken` works on Windows: outline glyphs only,
`FT_Outline_EmboldenXY` with `x = y = 16 + strength * 48 / 255` (26.6 units; 1/4 px at 0, 1 px at 255) after the synthetic-bold
step; advance and cell metrics are unchanged, colour and bitmap glyphs untouched. The text-weight comparison (`e2e/text-weight`:
A `linear-corrected`, B `native`, C = A + `font-thicken`, D = B + `font-thicken`) ended with the owner choosing A: no default change.

## 10. Child environment
- Base: `global.environMap()` (Ghostty's own env) minus nothing Windows-specific in M1.
- `TERM` (M5, R-M5-7): Windows default `xterm-ghostty` (upstream's), set only when the compiled entry exists next to the exe
  (`share\terminfo\78\xterm-ghostty`), else `xterm-256color` with one warning. A command whose argv0 basename is `wsl`/`wsl.exe`
  (any directory) or whose argv0 is System32 `bash.exe` always gets `xterm-256color`. `TERMINFO` points at the compiled directory
  in the `/c/...` form for every shell (MSYS ncurses splits `C:/...` at the colon). Known gaps: Cygwin needs `/cygdrive/c/...`; ssh to a
  host without the entry forwards a `TERM` the remote may not know (Windows OpenSSH from pwsh in particular).
  `COLORTERM=truecolor`, `TERM_PROGRAM=ghostty`, `TERM_PROGRAM_VERSION`, `GHOSTTY_RESOURCES_DIR`, `GHOSTTY_BIN_DIR`
  unchanged from core.
- PATH: core appends the exe dir. Windows (M4, with `windows-tmux-shim = true`; the default is `false` since M7, R-M7-1; R-M4-11): the exe dir is **moved
  to the front** of PATH (shim dir = exe dir, DECISIONS; a login shell such as Git Bash may reorder PATH in its profile: check
  `command -v tmux`) and every surface gets `TMUX=\\.\pipe\ghostty-tmux-<pid>-<16 hex nonce>,<pid>,0` and `TMUX_PANE=%<n>` (§12).
  Order: Ghostty's environment, the tmux client's environment (split-window/respawn-pane send theirs; `=C:`-style and
  non-UTF-8 entries are dropped, `TMUX`, `TMUX_PANE`, `GHOSTTY_SURFACE_ID`, `GHOSTTY_LOG` are never taken from it), then `TMUX`,
  `TMUX_PANE`, PATH, then the command's own `env K=V`. The nonce is 64 random bits per process, so a stale `TMUX` never
  meets a later Ghostty with the same pid. With `windows-tmux-shim = false` neither is set or removed (an inherited `TMUX`
  stays) and PATH is not changed; the key is app-wide and read when a surface starts.
- Git Bash: `CHERE_INVOKING=1` (§8.3). MSYS-facing path vars (`GHOSTTY_RESOURCES_DIR`, `GHOSTTY_BIN_DIR`) use the mixed `C:/a/b` form
  when bash integration applies; `TERMINFO` uses `/c/a/b` (R-M5-8). Under MSYS the exe dir is already first on PATH (M4), so the bash
  `path` feature is skipped.
- M7 (R-M7-1): with `windows-tmux-shim = true` panes also get `CLAUDE_CODE_TMUX_TRUECOLOR=1` unless the inherited environment already
  has it (the shim's "outer terminal" is Ghostty, which is truecolor). With the key off nothing of the shim touches the environment.
- WSL directory (M7, R-M7-10): in a surface whose command is WSL (argv0 basename `wsl`/`wsl.exe`, or System32 `bash.exe`), an OSC 7
  path that `pwd_path.translate` rejects but that is an absolute POSIX path (no control characters, <= 4096 bytes) and whose host is
  empty, `localhost` or the computer name is stored as the pwd as is; any other host stays rejected (a distro with a custom
  `wsl.conf` hostname is a documented limit; `/c/x` is mapped to `C:\x`). A new WSL surface that inherits a POSIX
  `working-directory` gets `wsl.exe --cd <path>` as argv[1] (an existing `--cd <x>` or lone `~` is replaced) and starts in the default
  process directory; a non-WSL surface drops the POSIX path with one log line. Palette, proxy icon and `window-subtitle` ignore
  a non-drive pwd.
- zsh from Git Bash (M5, task #53): while the bash startup files run, a DEBUG trap (`set -T` temporarily) arms the handoff right
  before an `[exec] [path/]zsh[.exe]` command only: the user's `ZDOTDIR` at that moment goes to `GHOSTTY_ZSH_ZDOTDIR` (restored by our
  `.zshenv` before the user's files) and `ZDOTDIR` points at the zsh integration. After a returning zsh and at the end `ZDOTDIR` is the
  user's again. The trap is removed only if it is still exactly ours (`$_` and `functrace` are kept; a chained user trap survives).
  Nothing else started by `.bashrc` sees our `ZDOTDIR`.
- Conpty (M5): the pty is created through the bundled `conpty.dll` + `OpenConsole.exe` from the exe directory by default; `OpenConsole.exe`
  appears as a child of Ghostty and the shell as its child.
- Profiles (M5, R-M5-1): `windows_shell.profiles(alloc, env, probe, default_argv)` returns, in order, `default` (the config `command` or
  §8.3), `git-bash` (`bash --login -i`), `pwsh` (`pwsh -NoLogo`), `powershell` (System32 Windows PowerShell, `-NoLogo`), `cmd` and one
  `wsl:<distro>` per distro (`wsl.exe -d <distro> --cd ~`). Distros are read from `HKCU\Software\Microsoft\Windows\CurrentVersion\Lxss\{GUID}\DistributionName`
  (read-only; the `DefaultDistribution` first, `docker-desktop*` skipped, names matching `[A-Za-z0-9._-]{1,64}` only) — `wsl.exe -l -q`
  is not used, so listing starts no distro. The list is cached on the App and rebuilt whenever a profile menu opens. No config key for
  custom profiles.

## 11. Logging and console (D10)
- `GHOSTTY_LOG` packed-struct flags gain `file` (default true on Windows) and `debugger` (default true on Windows Debug).
  `stderr` default stays `app_runtime != .none` but the Windows stderr sink only writes if the std handle is valid.
- File sink: `%LOCALAPPDATA%\ghostty\logs\ghostty.log`; at startup, if > 5 MiB rename to `ghostty.1.log` (one rotation).
  Lines `<ISO8601> <level>(<scope>): <msg>\n`, mutex-guarded, flushed per line. Debug level only in Debug builds.
- CLI actions (`+version`, `+list-fonts`, `+show-config`, …, `--help`): before running, if `GetStdHandle(STD_OUTPUT_HANDLE)`
  is invalid, `AttachConsole(ATTACH_PARENT_PROCESS)` then reopen `CONOUT$`/`CONIN$` and `SetStdHandle`; if there is no
  parent console (Explorer launch), output goes to the log file only. Implemented in `src/os/windows_console.zig`, called from
  `main_ghostty.zig` only on Windows.
- ConPTY choice (M5): one warning line when the bundled `conpty.dll`/`OpenConsole.exe` pair is missing, fails to load or
  `OpenConsole.exe` cannot start (then the inbox console is used for the process); `GHOSTTY_WIN32_CONPTY_FLAGS` applies to the inbox
  table only.
- Panics (M1): a root `panic` override writes the message + stack trace to the file sink and `OutputDebugStringW` before
  aborting (a GUI exe has no valid stderr).
- Known limitation: a GUI-subsystem `ghostty.exe +version` started from interactive `cmd` returns the prompt before the
  output appears; use `ghostty.exe +version | more`, `start /wait`, or a pipe (Git Bash).
- Crash (M5, R-M5-10; `src/os/windows_crash.zig`): Zig's own handler is off on Windows (`std_options.enable_segfault_handler = builtin.os.tag != .windows`
  in `main_ghostty.zig`; its vectored handler would print and abort before any unhandled-exception filter runs).
  `SetUnhandledExceptionFilter` is installed first thing in `main` on both the GUI and CLI paths. At install a dump thread
  (64 KiB stack) loads `dbghelp.dll` at runtime (so `ghostty.exe` has no `dbghelp.dll` import) and resolves `MiniDumpWriteDump`,
  then waits on an event; the path prefix `%LOCALAPPDATA%\ghostty\crash\ghostty-<pid>-` is precomputed. The filter takes a one-shot
  gate (`InterlockedCompareExchange`; a second crashing thread waits on the done event), hands over the exception pointers, waits
  at most 10 s and returns `EXCEPTION_EXECUTE_HANDLER` (no WER dialog). The thread writes `<prefix><GetTickCount64>.dmp` with
  `MiniDumpNormal | MiniDumpWithThreadInfo | MiniDumpWithUnloadedModules | MiniDumpFilterMemory`: no heap and no indirect memory, so
  the pty reader's buffer and other terminal text do not reach the dump. As built, the thread then scrubs the written file
  (`scrubStacks`: every 8-byte word of every thread stack that is non-zero and not shaped like a user-mode pointer is zeroed;
  an unparsable dump is left as written). One log line (code, address, path) is written by the dump thread through
  `windows_log.logFmt` (file and debugger sinks only, no stderr lock; the filter itself has little stack after a stack overflow).
  At `appStarted` the filter is re-checked and re-installed (logged once) if another module replaced it. The panic path
  (`src/main.zig`) requests a dump with no exception record before aborting. The 10 newest dumps are kept (pruned on the dump thread
  at start); `+crash-report` lists the `.dmp` files; nothing is ever uploaded. Known limit: a crash under the process heap lock times
  out with no dump.

## 12. Built-in tmux shim (M4)

**Default off since M7 (R-M7-1, owner 2026-10-29).** `windows-tmux-shim` defaults to `false`: `env.apply` leaves `TMUX`, `TMUX_PANE` and
`PATH` as inherited. The tmux pipe server still starts (a reload with the key on uses it for new surfaces; cost about 0), `tmux.exe`
stays in the zip and the installer, and `package-portable` checks it with the key on. Claude Code agent teams need
`windows-tmux-shim = true`; the tmux e2e scenarios enable it. With the key on, panes get `CLAUDE_CODE_TMUX_TRUECOLOR=1` (§10). The shim
answers `allow-passthrough off`, so Kitty images stay off in Claude Code with the shim on; DCS `tmux;` passthrough is not unwrapped
(R-M7-11).

### 12.1 Processes and transport
- `tmux.exe` (console subsystem, no SharedDeps, no libc; imports only kernel32 and ntdll; measured: -V p50 21 ms (the process-creation floor), peak
  private 0.6 MB). Steps: parse global flags (`-S <path>`, `-L <name>`, `-V`); `-V` → print `tmux 3.5a\n`, exit 0 (no IPC);
  resolve the pipe: `-S` value, else the first field of `TMUX`, else `no server running on default` (exit 1). Only
  `\\.\pipe\ghostty-tmux-<pid>-<16 hex>` is accepted (anything else: `not a Ghostty tmux socket`; a file or UNC path never gets the
  request); `-L` without `-S` and `TMUX` unset use the external pipe of §12.4 (M5, opt-in; this replaces M4's `-L without -S is not a server` answer, and with the key off no such pipe exists, so the answer is `no server running`). `load-buffer … -` reads stdin (≤ 512 KiB, valid UTF-8, else
  `ghostty: request too large` / `invalid UTF-8 on stdin`). Connect: `CreateFileW` with `SECURITY_SQOS_PRESENT |
  SECURITY_IDENTIFICATION`; `ERROR_PIPE_BUSY` → `WaitNamedPipeW` with a 50…1000 ms backoff until the deadline (10 s client
  timeout, request deadline 250 ms earlier); `ERROR_FILE_NOT_FOUND` → `no server running on <pipe>`; the handle must be a pipe and
  `GetNamedPipeServerProcessId` must equal the pid in the name. Output is printed verbatim (LF only, no BOM; `WriteConsoleW` on a console,
  raw UTF-8 otherwise); exit 0 for code 0, else 1. `tmux.exe __idle` (the `cat` placeholder) waits on its own process handle and
  ignores Ctrl+C. `GHOSTTY_TMUX_TRACE=<file>` appends one JSON line per call (`{t,argv,cwd,pane,code,ms,stdout_len,stdin_len}`,
  `FILE_APPEND_DATA`, one `WriteFile`); `GHOSTTY_TMUX_STATS=1` prints `tmux-stats peak_private_kb=… wall_ms=… build=…` to stderr.
- Server (R-M4-1): a second instance of the M2 `ipc/Server.zig` on `\\.\pipe\ghostty-tmux-<pid>-<nonce>`, claimed by every
  non-forwarding Ghostty process after the forward check and before the first window, with the same hardening as the M2
  pipe (`FILE_FLAG_FIRST_PIPE_INSTANCE`, `PIPE_REJECT_REMOTE_CLIENTS`, DACL `D:P(A;;GA;;;<current user SID>)`, plus the
  High-integrity label when elevated, peer user/elevation check). Per-pipe fields: `post_tag` 1 (`WM_GHOSTTY_IPC` wparam, routed
  before the main-server guard so a standalone process answers), `max_request` 4 MiB, `io_timeout_ms` 500, `close_wait_ms` 200
  (a silent client frees the queue in 600 ms). It answers only `op: "tmux"`; the per-user M2 pipe never does. One IPC
  thread, requests posted to the UI thread, executed there, replies written by the IPC thread; clients are queued in arrival
  order (Claude's parallel `kill-pane` at exit). The server also refuses stdin > 512 KiB (a hostile client does not run `tmux.exe`).
- Wire format (`src/apprt/win32/ipc/protocol.zig`, §18.5): frame = `u32` little-endian byte length + UTF-8 JSON, max 16 MiB.
  Request `{"v":1,"op":"tmux","args":[…],"cwd":"C:\\…","env":["K=V",…],"stdin":"…"|null,"pane":"%N","deadline_ms":…}` (`args` = the
  command line after the global flags, `env` = the client environment, `pane` = the caller's `TMUX_PANE`). Response
  `{"v":1,"code":0,"stdout":"…","stderr":"…","data":null}`. Unknown `v` → code 3, stderr `protocol version mismatch`; an expired
  `deadline_ms` is not acted on.

### 12.2 Registry and semantics
- Pane ids `%N` (R-M4-2): `Surface.pane_id` from a monotonic counter in `Registry.State` (never derived from the surface id),
  taken at creation by every surface, so `TMUX_PANE` is valid in every shell, including non-tmux-created ones. A respawn keeps
  its pane's number and takes none; numbers of closed panes are not reused. Window ids `@N` = Ghostty **tab** (`Tab.id`, kept
  by tear-off; tmux window ≙ tab). Session = the Ghostty process (`session_name` = `0`). Targets: `%N`, `@N`, `@N.%M`;
  `session:window.pane` forms fail with `can't find pane/window`.
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
  - Placeholder `cat`: a command string exactly `cat` starts `tmux.exe __idle` (waits on its own process handle, reads no input, until
    killed); never a shell.
### 12.3 Pane command execution (R1, R2)
- Env (R1): Ghostty `defaultTermioEnv` overlaid with the request's client `env`, then `TMUX`, `TMUX_PANE`, PATH with exe
  dir first, then the command's own `env K=V` assignments.
- Command (R2): if Git Bash is resolvable (§8.3 list, plus `CLAUDE_CODE_GIT_BASH_PATH` from the client env first) →
  argv `{<git>\bin\bash.exe, "-c", <string>}` with cwd = `-c`, else the `cd` target of the string, else the client cwd (R-M4-5); else `sh_command.parse(string)` for the grammar
  `[cd W &&] [env (NAME=W)*] W+` with POSIX single/double-quote rules and `'"'"'` escapes, no expansions → direct argv,
  cwd from `cd`, env overrides; parse failure → exit 1, stderr `ghostty: unsupported pane command`.
### 12.4 Other
- DCS passthrough `ESC P tmux; … ESC \` (R-M4-10): core's parser already dispatches the inner sequence as a normal OSC (stream
  tests `stream: tmux …`, no unwrap code). The inbox ConPTY does not forward the DCS itself (Task 2): an OSC 9 wrapped with a BEL
  terminator arrives as a bare OSC 9, an OSC 777 with an ST terminator is **dropped**. Documented gap: ST-terminated
  inner sequences (Claude notifications that use them) are lost while `TMUX` is set; no `dcs-tmux` e2e.
- XTVERSION is not spoofed (images stay disabled under TMUX; accepted).
- External mode (M5, R-M5-14; opt-in `windows-tmux-external = false` by default, which relaxes M2 revision 2: a same-user process may
  then ask Ghostty to run a command). When `true`, the primary instance claims a third pipe
  `\\.\pipe\ghostty-tmux-<user SID>-<session>-<class>[-admin]` with the M2 per-user pipe's security; it serves only `op: "tmux"` with a
  non-null `namespace`. `tmux.exe` connects there with `-L <name>` (even when `TMUX` is set, as tmux does) or with `TMUX` unset;
  namespace = `<name>`, or `default` without `-L`. No Ghostty running → `no server running on <path>`, exit 1 (Ghostty is never
  auto-launched). Each namespace maps to one Ghostty window created by `new-session -d` and shown with `SW_SHOWNOACTIVATE`; its tabs
  are the tmux windows, named by `-n` (the first tab of such a window starts the tmux plan directly, with no throwaway shell).
  Commands added in external mode: `has-session`, `new-session`, `new-window`, `kill-session`, `kill-server` (closes the namespace's
  windows without confirmation; not undoable), `list-windows -F '#{window_name}'` and the `session:window-name` target form (recon §5).
  A duplicate-named tab stays owned; dead namespaces are swept when a new session is created (cap of 8 namespaces). Inside mode is unchanged.
  `tmux.exe` is on PATH only inside Ghostty sessions; outside, the user adds the Ghostty directory to PATH (documented gap).
- Pane border labels (§12.2, Task 13): a click-through overlay pill in the pane's top-right or bottom-right corner while the
  window option `pane-border-status` is `top`/`bottom`, showing the expanded `pane-border-format` (`#[…]` runs stripped, the first
  `fg=` of the template or of `pane-border-style` colours it, the text is sanitised); hidden when the pane is narrower than the
  label + 2 cells.
### 12.5 Contract tests
`src/tmux_shim/*` unit tests (argv parser, format expansion, sh_command grammar incl. the [tmux §6] Windows example) and an
apprt-level replay test that runs the exact spawn sequence of [tmux §4 notes] against a headless registry and asserts
stdout bytes, exit codes and resulting tree shape.
### 12.6 Single instance / `performIpc`
M2 adds a per-user pipe (name in §18.5) served by the same IPC thread for `+new-window`/`+new-tab`/
`+toggle-quick-terminal`. Single-instance is ON by default (§18.6): a launch without arguments (or with only
`--working-directory`) forwards `new_window` to the running instance and exits; any other argument starts a separate
process; `windows-single-instance = false` opts out (GTK `gtk-single-instance` pattern).

## 13. Packaging (M6, as built)
- Artifacts (R-M6-3): per arch (`x64`, `arm64`) `ghostty-<ver>-windows-<arch>.zip`, `...-setup.exe`, `...-symbols.zip`
  (`ghostty.pdb`, `tmux.pdb`), plus one `SHA256SUMS.txt`: 6 artifacts + sums. `<ver>` is the `-Dversion-string`.
- Portable zip: one top folder `ghostty-<ver>-windows-<arch>/` with `ghostty.exe`, `tmux.exe`, `conpty.dll`, `OpenConsole.exe`,
  `share\` (allowlist: `ghostty`, `terminfo`, `bash-completion`, `fish`, `zsh`, `vim`, `nvim`, `bat`, `man`; the compiled
  `share\terminfo\78\xterm-ghostty` is required), `LICENSE`, `THIRD_PARTY_NOTICES.txt`, `README-windows.txt`; no PDBs.
  Resources found via existing `resourcesdir.zig`.
- Inno Setup (`dist/windows/installer/ghostty.iss`, built by `installer/build.ps1`), R-M6-4: per-user only
  (`PrivilegesRequired=lowest`, `{autopf}\Ghostty` = `%LOCALAPPDATA%\Programs\Ghostty`; per-machine is a v1.0 gap), fixed
  `AppId={{37134A5A-16BD-4127-9CC0-134E0CF32BA5}`, `MinVersion=10.0.17763`, English, no licence page. Start Menu shortcut with AUMID
  `com.mitchellh.ghostty.windows-unofficial`, optional desktop shortcut (`desktopicon`, unticked), optional task `explorer` (M7: renamed `explorermenu` and ticked, §13.1)
  (unticked in M6): after install `{app}\ghostty.exe +install-explorer-integration` runs hidden; a failure warns and does not fail Setup.
  Explorer "Open Ghostty here" (R-M5-5) keys: HKCU `Software\Classes\{Directory,Directory\Background,Drive}\shell\GhosttyOpenHere`
  with `(default)` = `Open Ghostty here`, `Icon` = `"<exe>",0` and `command\(default)` = `"<exe>" "--working-directory=%V\."`
  (the `\.` keeps a drive root's backslash away from the closing quote; `Overrides.parse` normalises it with `GetFullPathNameW`).
  Windows 11 shows the entry under "Show more options" only (the top-level menu needs package identity). No PATH change.
  `[InstallDelete]` drops `{app}\share\ghostty\themes` and `...\shell-integration` before copying (never `{app}\*`).
- Running Ghostty (guards, `[Code]`): tray window class `GhosttyTray` (one `#define`, checked against `tray.zig`).
  `PrepareToInstall` asks Retry/Cancel while it exists; a silent install fails there (exit code 7, nothing changed).
  `InitializeUninstall` does the same before `[UninstallRun]` (silent: exit 1). `CloseApplications=no` (the Restart Manager step
  comes after `PrepareToInstall` and would never be reached).
- Uninstall: `[UninstallRun]` always runs `{app}\ghostty.exe +uninstall-explorer-integration --all --only-this-exe`
  (hidden, `RunOnceId: ExplorerRevert`). `--only-this-exe` (R-M6-5) removes a verb key only when its `command\(default)` names this
  exe (full paths after `GetFullPathNameW`/`GetLongPathNameW`, `CompareStringOrdinal` ignoring case), so a portable copy's verbs
  stay; `--all` also removes the AUMID key and toast icon. No `[UninstallDelete]`; the config is never touched.
- The `/DGhosttyTest` variant (`...-setup-test.exe`, own AppId, `%TEMP%\GhosttyTestInstall`, no uninstall entry, no shortcuts, no
  Explorer step) is for `installer-test` only; the running-Ghostty guards are compiled into it (they write nothing).
- Toasts (ruling): Ghostty itself registers the AUMID under `HKCU\Software\Classes\AppUserModelId\<AUMID>`
  (`DisplayName`, `IconUri`) on first notification and calls `SetCurrentProcessExplicitAppUserModelID`, so the portable
  zip gets toasts too; the uninstaller removes the key. The Debug build uses `...windows-unofficial-debug`;
  `src/os/windows_explorer.zig` defines the AUMID once and `package.ps1` checks the `.iss` against it.
- Version (R-M5-9a, R-M6-1/2): `build.zig.zon` keeps upstream's version; releases build with
  `-Dversion-string=<zon>-win.<N>` (for example `1.3.2-dev-win.3`) and are tagged **`win-<zon>-<N>`** (annotated, by the
  owner, pinned to the built SHA), `N` a fork-wide counter from 1 that never resets or repeats. A `win-` git tag is ignored by the
  `Config.zig` tag check (falls through to the dev version); the `-win.` rule applies to the raw `-Dversion-string` (must end in
  `-win.<N>`, `N` canonical and <= 65535, no `+build`). The update check compares only `N`. Both exes carry a VERSIONINFO
  resource (`dist/windows/versioninfo.rc`; `FILEVERSION` = `major,minor,patch,N`, `VS_FF_PRERELEASE`, product name
  "Ghostty — Unofficial Windows port", no company name).
- Local release script (R-M6-6/7, owner decision: no CI in M6): `dist/windows/release.ps1 -N <N> -ConptyPackage <nupkg>`
  validates (clean tree, HEAD on `origin/windows`, `N` above every local `win-*` tag, RAM gate), runs the unit-test groups,
  builds x64 (`x86_64-windows-msvc`) and ARM64 (R-M6-11), calls `package.ps1`, verifies, writes `release-notes.md` and **prints**
  the `git tag`, `git push`, `gh release create --prerelease --draft --verify-tag` and `gh release edit --draft=false` lines
  into `publish.txt`; it executes none of them. `-Rehearsal -N 0` marks them "do not run". Runbook: `docs/windows/RELEASING.md`.
- Signing hook (R-M6-8): artifacts are unsigned. `-SignCommand '<command with {file}>'` signs `ghostty.exe`, `tmux.exe` (in the
  stage, before zipping) and, through ISCC `/DSign`, `setup.exe` and the uninstaller; never `conpty.dll`/`OpenConsole.exe`.
  `package.ps1 -FromZip` repackages an existing zip for later signing.
- Bundled ConPTY (R-M6-12): `conpty.dll` + `OpenConsole.exe` from NuGet `Microsoft.Windows.Console.ConPTY` 1.25.260930003 (MIT),
  per arch, next to `ghostty.exe` (`-Dconpty-dir`); version, SHA-256 and the Microsoft Authenticode signature are checked in the
  preflight and again when packaging; `windows-conpty = auto` (default) uses the inbox console for MSYS2/Cygwin programs (R-M5-17), `inbox` forces it everywhere.
- Third-party notices (R-M6-10): `THIRD_PARTY_NOTICES.txt` at the zip root and in the install dir; `third-party-check.ps1` fails
  packaging when a dependency, a toolchain runtime of the arch or `microsoft/terminal` has no section.
- Unsigned (R-M6-9): SmartScreen shows "Unknown publisher" (More info, Run anyway); Smart App Control blocks the build with no
  override ("not supported with Smart App Control on").
- No GitHub Actions workflow in M6 (the owner's minutes are exhausted; upstream workflows stay untouched and are switched
  off in the fork's settings). A `workflow_dispatch`-only `windows-ci.yml` with ARM64 unit tests is a backlog line.

### 13.1 M7 amendments (win.2, R-M7-2, R-M7-13, R-M7-14)
- Zip additions: `ghostty-explorer.dll` and `ghostty-explorer.msix` next to `ghostty.exe` (per arch); `package.ps1` builds the `.msix` with
  `makeappx pack /nv` (Windows SDK, never signed), verifies the staged file on every path (all entries scanned for the privacy
  check, imports and machine type of the DLL read with a PowerShell PE reader, the DLL signed when `-SignCommand` is given).
- Explorer command (`src/explorer_command/`, std-only Zig like `tmux.exe`): exports `DllGetClassObject` and `DllCanUnloadNow`; one
  `IExplorerCommand` class with a fixed CLSID (`ids.zig`), `ThreadingModel = STA`; `GetState` enabled for exactly one file-system item
  (null item array: the folder is resolved from the site, `IObjectWithSite`); `Invoke` starts `"<dll dir>\ghostty.exe"
  "--working-directory=<path>\."` with the path as cwd and no inherited handles, outside the package's job (breakaway, so the
  launched `ghostty.exe` has no package identity).
- Sparse package: `Identity Name="Ghostty.ExplorerMenu"`, publisher `CN=Ghostty Windows port (unofficial)` plus the unsigned-namespace OID
  `2.25.311729368913984317654407730594956997722=1`, `uap10:AllowExternalContent`, `TargetDeviceFamily` 10.0.22000.0, `runFullTrust`,
  `windows.fileExplorerContextMenus` for **`Directory` and `Directory\Background` only** (the schema rejects `Drive`; drives keep the
  classic verb), `windows.comServer` surrogate for the DLL. `ghostty.exe` has no `<msix>` manifest element: AUMID, toasts, jump list and
  taskbar grouping are as in v1.0.
- Installer: task `explorer` is renamed `explorermenu` and ticked by default (Inno remembers tasks by name, so an upgrade from v1.0
  shows it ticked once). It installs the classic verbs and, on Windows build >= 22000, `Add-AppxPackage -Path <app>\ghostty-explorer.msix
  -ExternalLocation <app> -AllowUnsigned -ForceUpdateFromAnyVersion` through hidden `powershell.exe` (errors stop the script; Unicode
  apostrophes in paths are quoted). A failure is logged and shown as a suppressible note; Setup succeeds and the classic verb stays.
  Unticking `explorermenu` on an upgrade removes the package (user intent; the classic verb is untouched as in R-M6-4).
- Upgrade over a loaded DLL: `PrepareToInstall` removes the package, then deletes `ghostty-explorer.dll`, else renames it to
  `ghostty-explorer.dll.old-<tick>`, else loops on Retry/Cancel (silent: Setup stops); `ssPostInstall` deletes `*.old-*` best effort.
  Uninstall: `[UninstallRun]` removes the package first (`ExplorerMenuRevert`) and then runs `ExplorerRevert`; a held DLL is renamed
  aside (a leftover can keep `{app}` until the next install).
- `/DGhosttyTest` installs both files and contains no package code. The portable README gives the two PowerShell lines;
  `+install-explorer-integration` does not register packages. Residual risk: the package path was tested only on the owner's machine.
- Release (R-M7-14): `release.ps1 -N 2`, tag `win-1.3.2-dev-2`, no upstream merge; the lead adds the win.2 highlights and the
  residual-risk line to `release-notes.md` and re-runs `Test-Privacy` before the owner runs `publish.txt`.

## 14. RAM budget
Measured by `test/windows/measure-ram.ps1`: launches `ghostty.exe` with `XDG_CONFIG_HOME` pointing at a temp config
(defaults + `command = direct:cmd.exe /k`), waits until the window is visible + 10 s idle, samples
`Get-Process -Id <pid>` → `PrivateMemorySize64` (**Private Bytes**, the budgeted number) and `WorkingSet64` (reported),
ghostty.exe only (conhost/OpenConsole and shells are reported separately, not budgeted). Steps for extra tabs/splits/windows
are driven by the test-only IPC `action` op (§18.8; M2+), never by keyboard input: `tabs` = 10 x `new_tab`, `splits` = 10 x `new_split` in one tab,
`windows` = 4 x `new_window`, `close-10` = 10 tabs opened and closed again, 30 s idle (rows `close-10-before` / `close-10`), `zero-windows` = the
process resident with no window; the per-surface / per-window cost is (row - `one-surface`) / 10, 10, 4. Output: one CSV row per scenario appended to `docs/windows/ram-baseline.csv`
(date, commit, optimize, adapter, scenario, private_mb, ws_mb). Budgeted numbers are measured on `-Doptimize=ReleaseFast`
builds (Debug numbers may be recorded with `optimize=Debug` but are never gated). The scrollback scenario uses
`cmd /c "for /L %i in (1,1,200000) do @echo %i"` (there is no `seq` in cmd).

| Scenario (100% DPI, default font/config, idle) | v1.0 target (Private Bytes) | M1 gate |
|---|---|---|
| 1 window, 1 surface | ≤ 80 MB | ≤ 110 MB (+ baseline recorded) |
| each extra surface (tab or split) | ≤ +10 MB | M2: +5.7 MB per tab, +6.0 per split (ReleaseFast, Arc iGPU): met |
| each extra window (1 surface) | ≤ +15 MB | M2: +17.7 MB (2 runs: 140.2 / 140.1 vs 69.1 MB): **over, owner decision** |
| surface after `seq 1 200000` (scrollback full at default `scrollback-limit` 10 MB) | ≤ surface cost + 15 MB | recorded |
| close 10 extra surfaces, wait 30 s | back within +10% of the pre-open value | M2: +18.0 % and +14.1 % (81.2 / 78.5 vs 68.8 MB): **over, owner decision** (a 16-pane cycle leaves about +80 MB, pre-existing) |
| 0 windows, resident in the notification area (§18.15) | recorded | M2: 63.1 MB private (recorded, not gated) |
| tmux.exe per invocation | ≤ 5 MB, ≤ 100 ms wall | M4 |
| M3 (2026-10-28, ReleaseFast, Arc iGPU, 96 dpi, default window 1388x751): 1 window 1 surface | M2 row + 1 MB | 64.5 / 64.5 MB (M2: 69.1): met |
| M3 DirectWrite discovery (`font-family = Consolas`, CJK printed) | `font-consolas-m1` row + 2 MB | 66.5 MB (m1 69.7 at 175 %; same-day one-surface 64.5, +2.0): met |
| M3 custom shader (1 shader, invert) | +2 x target bytes + 4 MB | +13.6 MB at 1388x751 (gate +12.3), +21.5 MB maximised 1872x1050 (gate +19.7): **over by 1.3 / 1.8 MB, owner decision** |
| M3 composition mode (`background-opacity = 0.9`) | first surface +3 MB, each extra +0.5 MB | first +0.4 MB, extra -0.15 MB per surface: met |
| M3 overlays (search + command palette, each opened once; link label not driven) | +1 MB total | cold +2.1 MB (search +1.1, palette +1.0); warm +0.4 MB (Task 26.5): met warm; the first paint of a cold window costs about +2 MB (shared Direct2D/DirectWrite state, irreducible; owner note) |
| M3 inspector open on 1 surface | +25 MB open; within +2 MB 30 s after close | +3.5 MB open (met); 30 s after close +3.6 MB before Task 26.5, about +1.9 MB mean after it (imgui in its own heap; 2 of 5 samples over +2): **borderline, the rest is GPU driver cache** |
| M3 quick terminal | 0 before the first toggle, then one surface's cost | 64.3 before (0); +10.1 MB after the first toggle (one tab/split costs +5.7/+6.0, an extra window +17.7): **over a surface's cost, owner decision** |
| M3 first toast (WinRT DLLs) | +4 MB | deferred: owner-approval-gated (HKCU AUMID key) |
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
| R15 | MSVC toolchain/ARM64 libs on CI | Outcome (M6): no CI; releases are built locally (R-M6-6). ARM64 uses `aarch64-windows-gnu`, which needs no VS ARM64 component (R-M6-11); `-Arm64Abi msvc` once installed. |
| R16 | Unsigned binaries + named pipes trigger SmartScreen/AV | Accepted (DECISIONS); no code injection/hooks used. Outcome (M6): README, release notes and CHANGELOG say it; Smart App Control blocks the unsigned build with no override ("not supported with Smart App Control on"); signing hook in place, no certificate (R-M6-8, R-M6-9). |
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

**M2 (done, accepted with concerns: `docs/windows/m2/acceptance.md`; commit `test(windows): M2 RAM rows, screenshots and acceptance record`) — tabs, splits, multi-window, Mica, titlebar, DPI, keybind actions.** Custom frame (caption removed, DWM-extended,
Mica under the titlebar/tab strip, own caption buttons, `HTMAXBUTTON` snap layouts, `window-decoration` client/server/none),
Direct2D/DirectWrite tab strip (select, close, middle-click, new, drag reorder, overflow scroll, inline rename = `prompt_title`),
tabs and splits over core `SplitTree` (one container HWND per tab, one child HWND per surface; divider drag, zoom, equalize,
goto, resize), multiple windows (cascade, goto/present, move tab to new window, tab tear-off by drag into a new window and
re-dock onto another window's strip with live ghost/insertion feedback, Esc cancel; processes keep running, §18.16), maximize/fullscreen/float/decorations toggles,
per-monitor DPI incl. hidden tabs, theme (`window-theme`, titlebar colours, system colour scheme → conditional config), config
reload (soft/hard) and `open_config`, native scrollbar, bell (title/attention/system/audio), taskbar progress, resize overlay
(owned popup), Windows 11 style close confirmations, named-pipe IPC + single-instance (`windows-single-instance`) + `performIpc` +
test-only IPC ops, notification-area icon with Ghostty staying alive after the last window (Windows default
`quit-after-last-window-closed = false`, §18.7/§18.15), Windows Terminal tab-close process semantics (§18.14), file drag-and-drop from Explorer as shell-quoted paths (§18.17),
input and output latency measured and fixed incl. TUI wheel scrolling and ConPTY (§18.18), new surfaces survive a GPU device loss while the process stays
resident (§18.19; full recovery M3). Every `Action.Key` is classified implemented / deferred (milestone) /
unsupported by `apprt/win32/actions.zig`. Exit: action-coverage test green; M1+M2 e2e green on Debug and ReleaseFast;
screenshots at 100/150/200% (simulated through the test DPI op; real multi-monitor checked by the owner); per-tab/split/window
and close-10 RAM rows within §14 targets; the ReleaseFast latency gates of §18.18 met. Plan: `docs/windows/plans/M2-tabs-splits-windows.md`.
Scope moved during execution (ledger): Task 40 (ConPTY variant) is N/A, the measured ConPTY stage is not the floor (§18.18); the drop highlight is
removed (macOS has none); the native always-visible scrollbar stays an interim, an overlay scroller like macOS is M3 work; a macOS-like tab bar
look polish is an M3 task; full recovery after a GPU device loss is M3 (§18.19); the Git Bash cwd inheritance waits for M5 OSC 7 translation; tab
context menu and tab tooltips are M3; the +80 MB after a 16-pane open/close cycle is accepted as pre-existing and flagged for M3 RAM work.

**M3 (done, accepted with concerns: `docs/windows/m3/acceptance.md`; acceptance commit `docs(windows): M3 acceptance — RAM, latency, screenshots, feature checklist`; final review `docs/windows/m3/final-review.md`; closing commit: 7a47ed93c) — feature parity.**
Quick terminal (`RegisterHotKey`, slide, owned tool window), global keybinds, command palette, search bar,
notifications (WinRT toasts, AUMID self-registered under HKCU, R-M3-5), URL hover/open with untrusted-URL validation
(R-M3-8), inspector (imgui win32 + dx11), config-errors dialog, export-terminal-io save dialog, custom shaders (GLSL to
HLSL via SPIRV-Cross), background image, transparency + blur (composition swap chains, Acrylic), DirectWrite discovery
and fallback, device-loss recovery with the renderer-health bar, key-sequence/table indicator, read-only badge,
unfocused-split dimming and `bell-features = border` (decor pass), `toggle_visibility`, `toggle_background_opacity`,
tab context menu and tooltip, text drops, overlay scrollbar, the owner's macOS-style chrome redesign (title row, tab
row, proxy icon), OSC 7 path translation (pulled forward from M5), vt-smoke screenshots and the feature checklist
(`docs/windows/feature-checklist.md`). Exit: the checklist is closed except the recorded gaps (Kitty graphics and SGR 58
underline colour: the inbox ConPTY drops them, §18.33; ligatures, Kitty keyboard end to end, IME: owner checks); RAM and
latency rows in `docs/windows/ram-baseline.csv` / `latency-baseline.csv`; the numbers over budget and the Git
Bash input-loss workaround (Task 26.4) are listed in the acceptance record and the changelog for the owner. Plan: `docs/windows/plans/M3-feature-parity.md`.

**M4 (done, accepted with pending: `E2E -Milestone all` (next quiet-desktop batch), owner manual checks (`load-buffer -w` with a text clipboard); record `docs/windows/m4/acceptance.md`, final review `docs/windows/m4/final-review.md`, CHANGELOG "M4"; acceptance commit `docs(windows): M4 acceptance — tmux shim RAM, latency, Claude Code agent-team runs`; closing commit 5b8243768) — tmux shim + IPC + Claude Code e2e.**
`tmux.exe` (console exe, imports kernel32/ntdll/advapi32 only — advapi32 since M5 Task 17), a second IPC server on `\\.\pipe\ghostty-tmux-<pid>-<nonce>` (§12.1, R-M4-1), the
registry/host over Ghostty tabs and surfaces with the §12.2 command set (`split-window`, `respawn-pane`, `kill-pane`,
`select-layout`, `resize-pane`, `select-pane`, `set-option`, `show-options`, `display-message`, `list-panes/windows`,
`show-environment`, `load-buffer`, plus `send-keys` with a post-resize gate and `capture-pane`), `SplitTree.replace`,
`TMUX`/`TMUX_PANE` and the exe dir first on PATH in every surface, the opt-out key `windows-tmux-shim` (R-M4-11), `remain-on-exit`,
pane border labels, DCS `tmux;` verified in core (the ConPTY gap is documented, §12.4). Exit (plan "M4 exit checklist"):
- Replay: `tmux-replay` is green on Debug and ReleaseFast (live and static fixture), with the leader typing 7 of 7 lines
  across the layout changes; `tmux-cli`, `tmux-env`, `tmux-send-keys`, `tmux-labels` green on both builds.
- Real Claude Code 2.1.312 (sonnet, the owner's login, `test/windows/claude-team.ps1`): the agent-team run passed twice in
  a row in a ReleaseFast Ghostty (3 panes, leader 621 of 2073 px = 30.0 %, panes titled alpha/beta, both teammates' messages
  in the inbox, only the leader after `/exit`, no stray processes, the trace has exactly the shapes of the recorded
  fixture). The G1 run (Debug) and these two found no product bug.
- Budgets (ReleaseFast, `m4-*` rows): `tmux.exe` peak private 0.6 MB (`load-buffer` at the 512 KiB cap 3.9 MB, `__idle`
  0.5 MB); one surface 72.0 MB against 72.1 MB for the M3 acceptance build measured the same day (+0.0); the team layout
  (leader + 2 respawned teammates) 84.1 MB, 30 s after killing them 78.2 MB (+5.9 % of the pre-team value). `tmux.exe`
  process wall p95: `display-message` 32.2 ms (p50 25.3; **gate 30 ms missed by 2.2 ms**, the process-creation floor on
  this machine is about 21 ms: `-V` p50), `split-window -- cat` 35.5 ms and `respawn-pane -k` 114.6 ms (gates 300 ms).
  Key-echo latency (Ghostty-owned p95, `input-latency`, same-day interleaved, 6 runs each): 2.14 ms median against
  1.63 ms for the M3 acceptance build (+0.5 ms), single runs 1.3-11.6 ms with 7-13 % background CPU: within the noise; no
  code of M4 runs on the key to pty write path.
- Gaps and owner checks: the clipboard path of `load-buffer -w` is covered by unit tests and needs a run with a text
  clipboard (owner-run); DCS `tmux;` with an ST-terminated inner sequence is dropped by the inbox ConPTY (§12.4);
  external mode, `new-session`/`attach` and the other known gaps are listed in the CHANGELOG. Plan: `docs/windows/plans/M4-tmux-shim.md`.

**M5 — Windows extras (accepted 1e4912c37 with known limits R-M5-15…18 and the owner manual checks pending, see `docs/windows/m5/acceptance.md`; plan `docs/windows/plans/M5-windows-extras.md`, rulings §18.36).** Jump lists (new window/tab, profiles as tasks), shell-profiles menu (Git Bash, pwsh, Windows PowerShell, cmd, WSL distros
from the Lxss registry; right-click `+`, palette, tray), Explorer "Open Ghostty here" (`+install-explorer-integration` + installer), pwsh integration
(OSC 133/7/title), Git Bash integration fixes, OSC 7 translation, compiled terminfo + `TERM=xterm-ghostty`, `+edit-config`,
update check (`auto-update = check|off`, GitHub Releases via WinHTTP, toast), crash minidumps, external tmux mode,
Windows analogs of macOS-only actions (`secure_input`, `undo`/`redo`), on-screen keyboard.
Exit: each feature has a test or scripted screenshot; update check tested against a fake release JSON.

**M6 — packaging and release (done 2026-10-29: v1.0 pre-release `win-1.3.2-dev-1` from `f904ba62c`; record `docs/windows/m6/acceptance.md`; plan `docs/windows/plans/M6-release.md`).** Zip + Inno Setup
(x64 + ARM64), version resource, third-party notices, bundled ConPTY, a local release script that prints the publish commands
(no CI: R-M6-6), pre-release published by the owner, v1.0 gate of DECISIONS (feature checklist closed, RAM rows, Claude Code run,
owner smoke). Exit: owner sign-off.

**M7 — win.2 (`1.3.2-dev-win.2`, plan `docs/windows/plans/M7-win2.md`, rulings R-M7-1…14 in §18; "done" is recorded in Task 18, `docs/windows/m7/acceptance.md`).** tmux shim off by default,
Kitty in pwsh/cmd (render and `a=q` reply measured), symbols/emoji from Segoe UI Symbol/Emoji, `font-thicken`, tab rename popup, Windows paths in links,
`CF_HDROP` paste, system double-click time, pwsh/cmd `cursor`/`ssh-env`/`ssh-terminfo`, WSL start directory, Windows 11 top-level "Open Ghostty here"
(sparse package), installer task `explorermenu`. MSYS stays on the inbox console (limit, `docs/windows/m7/msys-key-loss.md`).

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
   `\\.\pipe\ghostty-<user SID>-<session id>-<class>[-admin]` (class = config `class` sanitized, default
   `com.mitchellh.ghostty`, Debug builds `com.mitchellh.ghostty-debug`; `-admin` when the process is elevated), so other
   sessions, builds, integrity levels and test instances never meet. An elevated server's security descriptor carries the
   high mandatory label; both ends check that the peer has the same user SID and elevation (M2 plan revision 2). Every
   request carries `deadline_ms` (`GetTickCount64`); the server does nothing for an expired request. M2 servers accept
   requests of at most 64 KiB. Cost if wrong: rename of a pipe constant.
6. Single instance (amends §12.6): config `windows-single-instance = detect|true|false`, default `detect` = forward only when
   the command line is empty or holds nothing but `--working-directory=` (owner decision 2026-10-26: a launch with arguments
   starts a separate process; revision 2 dropped `--title=`/`--command=`/`--shell-integration=`, so no request can make
   another process run a command). The second process's cwd is not forwarded (Start-menu cwd is meaningless); Explorer
   passes `--working-directory`, absolutized before forwarding. The pipe is claimed in `App.init` before any window; the
   claimer is the primary. A process that does not own the pipe never shows a tray icon and quits after its last window. Cost if wrong: one default flip.
7. Owner decision (DECISIONS, 2026-10-26): `quit-after-last-window-closed` defaults to `false` on Windows — closing the last
   window leaves Ghostty running in the notification area (§18.15), reachable from the tray icon and by the next launch
   (single instance). `true` restores quit-on-last-window, honouring `quit-after-last-window-closed-delay` and core's
   `quit_timer` start/stop.
8. Test-only IPC ops `state`, `action`, `dpi`, `color-scheme` answer only when Ghostty was started with
   `GHOSTTY_WIN32_TEST_IPC=1`; e2e uses them instead of system-wide DPI/theme changes (owner-machine safety). Cost if
   wrong: none for users.
9. Chrome painter backend (decided by M2 Task 12 spike, 2026-10-26): software `ID2D1DCRenderTarget` on a buffered-paint
   DC over Mica (`dc`). RAM +2.91 MB over a window without D2D (budget 3 MB for the D2D painter, borderline; overall RAM
   is gated at G1). Condition: the top-level is created WITHOUT `WS_SYSMENU` — with it DWM paints its own min/max/close
   over the extended frame ("ghost" buttons). Task 17 therefore shows the system menu itself (Alt+Space and right-click
   on the caption: `GetSystemMenu` + `TrackPopupMenuEx` → `WM_SYSCOMMAND`), swallows a lone-Alt `SC_KEYMENU` (it froze
   the UI thread in the spike) and must verify: Alt+Space menu, taskbar/thumbnail context menu, Alt+F4, caption
   double-click maximize, Win+Up/Down, drag-to-top snap, snap-flyout layout selection, Alt+key reaching the terminal,
   inactive-window caption. If any of these cannot be restored without `WS_SYSMENU`, Task 17 falls back to the R9 opaque
   painter (no Mica) with `WS_SYSMENU`. Maximized: `WM_NCCALCSIZE` adds the frame inset back to the client top.
   Re-parenting: `SetParent` keeps a presenting FLIP_DISCARD swap chain working (same size; and after the source window
   is destroyed and the target resized) → Task 30 keeps only the defensive generation bump. Not proven: cross-DPI /
   cross-monitor moves, another UI thread. Spike evidence: `test/windows/chrome-spike/`.
10. One container child HWND per tab holds that tab's surfaces; hidden tabs are hidden containers (surfaces occluded);
    split gaps are 4 px at 96 dpi painted with `split-divider-color` (theme default otherwise).
11. Scrollbar = native `WS_VSCROLL` on the surface, always visible with `scrollbar = system` (`SIF_DISABLENOSCROLL`, no grid
    reflow when scrollback first appears), dark via the `DarkMode_Explorer` theme; none with `scrollbar = never`.
12. Frame dumps are named `surface-<apprt surface id>.bmp` (first surface = 1); headless renderers keep the index.
13. `bell-features = audio` plays WAV files through `PlaySoundW`; `bell-audio-volume` is ignored on Windows in M2.
14. Owner decision (DECISIONS, 2026-10-26; amends §8.4 and the M1 Task 19 ruling): closing a surface (split, tab or window)
    terminates only its direct child and then closes its pseudo console, so the console clients attached to it receive
    `CTRL_CLOSE_EVENT` and end (Windows Terminal semantics). Programs with their own console (`start cmd`), detached
    processes and GUI programs survive. The job object stays only for listing a surface's processes (M4 pane queries); it
    is never used to kill.
15. Owner decision (DECISIONS, 2026-10-26): a notification-area icon (`Shell_NotifyIconW`, hidden `GhosttyTray` tool window,
    re-added on `TaskbarCreated`) is shown while `quit-after-last-window-closed = false`. Left click presents the last
    active window or opens a new one; the menu has New Window and Quit (Quit confirms like the `quit` action when
    processes are running).
16. Owner requirement (2026-10-26): tab tear-off and re-dock. A tab moves between windows by `SetParent` of its container
    HWND; the core surfaces, ptys and child processes stay untouched. After every re-parent the apprt bumps the surface's
    `PresentTarget.generation` and the render thread recreates the swap chain for the same HWND before its next frame
    (the UI thread never calls DXGI). Drop targets are this process's `GhosttyWindow`s found by `WindowFromPoint` +
    `GA_ROOT` (the layered drag ghost is `WS_EX_TRANSPARENT`); other Ghostty processes are never targets. A drop outside
    every strip creates a new window under the cursor (a single-tab source window just moves); an emptied source window
    closes; a dpi change between windows rescales the moved surfaces.
17. Owner requirement (2026-10-26, M2 Task 38): files dropped from Explorer onto a surface are inserted as their paths,
    space-separated, quoted for the surface's shell (from the launched command: Git Bash/MSYS shells → msys paths
    `/c/Users/…` in POSIX single quotes (owner decision 2026-10-26), wsl → `/mnt/c/…`, pwsh/powershell → PowerShell
    single quotes, cmd and unknown shells → double quotes when needed), delivered like macOS Ghostty's
    drop: a paste through `textCallback` (bracketed when the program enabled it), never followed by Enter. One OLE
    `IDropTarget` per top-level window (OLE is initialised for it); the target surface is highlighted during the drag.
    Text drops are M3. An elevated Ghostty gets no drops from a non-elevated Explorer (UIPI), as in Windows Terminal.
18. Owner requirement (2026-10-26, M2 Tasks 36, 37, 40; the owner sees lag in ReleaseFast too, worst when scrolling
    TUIs): latency is measured first (Task 36 is the first M2 task) by a std-only tracer (`src/os/windows_latency.zig`,
    active only with `GHOSTTY_LATENCY_TRACE=<csv>`) with stages input (`WM_KEYDOWN`/`WM_MOUSEWHEEL`) → pty write →
    pty output → parse → render start → frame-slot wait → present. Gates on ReleaseFast (owner decision 2026-10-26: whole
    path ≤ 16 ms p95, Ghostty-owned stages ≤ 6 ms; Debug may stay slower and is recorded, not gated): key echo, TUI key
    navigation and wheel scrolling (`less`, `vim`) ≤ 16 ms; a 30-notch wheel burst settles ≤ 50 ms after the last notch;
    output → present ≤ 8 ms idle; plus the owner's hands-on comparison with Windows Terminal. Changed only with a stage
    table and the lead's written sign-off. Wheel input is coalesced per message-loop turn. When ConPTY itself is the floor, Task 40 switches to the
    best measured variant — inbox `PSEUDOCONSOLE_PASSTHROUGH_MODE` where supported, or `conpty.dll` + `OpenConsole.exe`
    from Microsoft's pinned NuGet package shipped next to `ghostty.exe` (as Windows Terminal does), with fallback to the
    inbox conhost; the lead records the chosen variant here.
19. M2 Task 39: the shared D3D11 device has a generation; after `DEVICE_REMOVED/RESET` new surfaces get a fresh device and
    the lost one is freed with its last renderer; a resident process with a lost device and no window quits. Existing
    surfaces stay blank until closed; full recovery and the renderer-health bar remain M3.

Rulings for M3 (architect-m3, 2026-10-27; lead/owner may overturn; recorded here by Task 27):

20. R-M3-1, overlays = owned popups, pixel effects = decor pass (amends §17 "DComp overlay visuals" and §6.6). Text overlays
    are owned `WS_POPUP`s (proven by M2's resize overlay; child windows above a flip-model child swap chain hit the airspace
    problem). Unfocused-split dimming and the bell border are drawn by the D3D11 backend on the frame target before
    present, driven by a per-surface atomic word, skipped at word 0. The bell border clears on key-down and on focus-in
    like macOS (a flag check on the existing hooks, no new call on the key path). Task 11 owns the shared Direct2D painter API
    in `Chrome.zig` that the overlays (search, palette, labels) use to match the macOS look. Cost if wrong: a later switch
    to DComp visuals for the two effects, local to `Decor.zig`/`decor.zig`.
21. R-M3-2, composition mode only for transparency. A surface's swap chain is `hwnd` mode unless `background-opacity < 1`
    or `background-blur` is not `false`; a config reload switches modes through the M2 present-target generation (chain
    recreated on the render thread, the old chain kept until the new one presented). Whether a window can be translucent is
    decided at creation: a window shown opaque (or that showed an `hwnd` chain) stays opaque after a reload to a translucent
    config (restart needed, like macOS) and `toggle_background_opacity` on it is a no-op returning false; a window born
    translucent goes solid at `background-opacity = 1` and back without a restart. `toggle_background_opacity` never
    switches modes: it makes the backdrop layer opaque. Task 14 hands the chain to the UI thread in a posted message
    (DComp objects are touched on the UI thread only) and retires the `hwnd` chain after the first composition present;
    a minimised window is throttled through core visibility. Cost if wrong: transparency costs RAM/latency for everyone
    (if always-on) or one mode switch per toggle.
22. R-M3-3, backdrop with transparency (as built, Task 8 spike + Tasks 15a/15b). The window is translucent through
    `DwmEnableBlurBehindWindow` with an empty region and a child class `hbrBackground = BLACK_BRUSH` (never
    `DwmExtendFrameIntoClientArea(-1)` + `DWMSBT_NONE`, which stays opaque black); with `background-blur` (default true when
    `background-opacity < 1`) the whole window uses Acrylic (`DWMSBT_TRANSIENTWINDOW`). The owner requires the blur to stay
    when the window is inactive, so `WM_NCACTIVATE(FALSE)` is swallowed for those windows (without it Acrylic goes
    solid), except with `window-decoration = server` (the native caption must show inactive); accepted side effects: the
    owner of a MessageBox and a second Acrylic window are drawn active too. Chrome paints with the same alpha and draws its own
    caption buttons (the blur variant has no DWM ones). The renderer premultiplies in sRGB space like DWM blends, only the
    background layers (not text or cursor). Radius values are ignored (DWM has no radius). High contrast and "Transparency
    effects" off turn the effect off (an owner check; the off-state is not machine-tested). Capture-based tests use the screen
    rect (PrintWindow does not see the backdrop). Cost if wrong: one backdrop constant.
23. R-M3-4, inspector uses the shared device under `Device.lockContext`, rendered on the UI thread from a 30 Hz timer while
    its window is open, visible and not iconic, plus a hook in the wakeup handler guarded by an open-inspector count (core
    does not wake the app on pty output or keys); `render_inspector` only sets a dirty flag. It is a separate top-level
    `GhosttyInspector` window per surface, created on the first `inspector` action. `imgui_impl_dx11.cpp` is compiled
    with `-DD3DCompile=ghostty_imgui_D3DCompile` (forwards to the System32-loaded pointer of `pkg/win32/d3dcompiler.zig`);
    `imgui_impl_win32.cpp` with `-DIMGUI_IMPL_WIN32_DISABLE_GAMEPAD`; `ghostty.exe` imports neither `d3dcompiler_47.dll`
    nor `xinput*`. This UI-thread swap chain is the one exception to §6.4. Known: a GPU busy for more than 50 ms can make
    one inspector `Present` wait under the context lock. Cost if wrong: an own device for the inspector.
24. R-M3-5, toasts via WinRT, no COM activator. AUMID `com.mitchellh.ghostty.windows-unofficial` (Debug builds `...-debug`),
    self-registered under `HKCU\Software\Classes\AppUserModelId\<AUMID>` (`DisplayName` "Ghostty - Unofficial Windows
    port", `IconUri` = `%LOCALAPPDATA%\ghostty\toast-icon.png` written from `images/icons/icon_128.png`) on the first
    notification; `SetCurrentProcessExplicitAppUserModelID` at start, which ungroups taskbar pins made with M1/M2 builds
    (changelog). A click runs the `Activated` delegate (pool thread, only posts) and presents that surface while Ghostty
    runs (it always runs: tray); a toast clicked in the Action Center after Ghostty exited does nothing (no `ToastActivator`
    CLSID). Title and body are XML-escaped with control characters stripped. If WinRT fails: `FlashWindowEx` plus one
    warning. The key and the icon file persist after uninstall (documented). Cost if wrong: a COM activator server (M5).
25. R-M3-6, quick terminal = a `Window` of kind `.quick`: `WS_POPUP`, `WS_EX_TOOLWINDOW`, topmost while shown, decorations
    none, strip `tabs_only` only with 2 or more tabs, size/position/screen from `quick-terminal-*`, slide by `SetWindowPos`
    frames on a timer with a `SetWindowRgn` clip (monitor and DPI fixed for the animation), not user-resizable in v1,
    hidden on toggle (not destroyed), destroyed when its last surface closes. It is excluded from `goto_window`, the tray's
    last-active window and, while hidden, from the `quit-after-last-window-closed` count; a shown quick terminal counts
    as a window (killing a visible terminal's shell is the worse failure; macOS may quit there). Auto-hide ignores the
    own panel's deactivation. `quick-terminal-keyboard-interactivity` and `-space-behavior` are ignored on Windows.
    `+toggle-quick-terminal` now parses its options (`--class=`), which also fixes GTK (an upstreamable change). Cost if
    wrong: a process that stays alive while only the quick terminal is visible.
26. R-M3-7, global keybinds (`global:`) = `RegisterHotKey` on the message-only window, `MOD_NOREPEAT`; activation runs the
    bound action through `core_app.performAllAction`; a chord owned by another app logs one warning; re-registered on
    config change, not on keyboard-layout change (documented gap); no low-level hook.
27. R-M3-8, `open_url` policy (extends M2 Task 34.4). `text`/`html` (from Ghostty) open directly; `unknown`/`osc8` (terminal
    output) are validated: `http`, `https`, `mailto`, `ftp` open; `file:` URLs are percent-decoded once, bare paths
    resolved against the surface's pwd (`/c/x` to `C:\x`, `~`, relative), then `GetFullPathNameW`; refused: ADS (`:`
    after the drive), `\\?\` / `\\.\` prefixes, UNC, DOS device names, and drives that are not fixed or removable. Existing
    local files open, except that (after stripping trailing dots and spaces, and checking the 8.3 short name) an
    executable/script/container type or any type for which `AssocIsDangerous` is true is revealed in Explorer instead of run;
    a missing path is refused; any other scheme asks first (the Windows 11 style dialog); more than 2048 bytes or any C0/C1 control is
    refused. Validation and execution run on one lazy STA worker (queue up to 8, `SEE_MASK_NOASYNC | SEE_MASK_FLAG_NO_UI`) so a dead
    network drive never blocks the UI thread; `link.open` returns true for every verdict. Cost if wrong: a confirmation or
    reveal where a direct open was expected.
28. R-M3-9, DirectWrite for discovery only (Task 5): rasterisation stays FreeType + HarfBuzz; `src/font/directwrite.zig` does
    family and fallback discovery (`MapCharacters`, plus a walk over installed faces for codepoints it does not map), the M1
    index stays as the fallback when no DWrite factory can be created; emoji presentation is not routed to DirectWrite
    (Segoe UI Emoji is COLRv1, FreeType cannot colour it: the embedded Noto Color Emoji stays). A codepoint missing from every
    font costs one walk (1-74 ms Debug, cold DWrite), then `SharedGrid` caches the miss. `+list-fonts` printed NUL-interleaved
    UTF-16 names on Windows (M1 bug): fixed in core `freetype Face.name` (upstream candidate).
29. R-M3-10, device-loss recovery. A renderer that sees `DEVICE_REMOVED/RESET` marks its generation lost and reports
    `unhealthy`; the apprt shows the health bar and, 250 ms after the first report, calls `displayUnrealized()` +
    `displayRealized()` for every surface on a lost generation; the backend re-acquires the device on the next frame; image
    textures (Kitty images, background image) are dropped and re-uploaded on a generation change; custom shaders are disabled
    after a loss (logged once). Three failed recoveries within 60 s switch acquisition to WARP. M2 Task 39's "resident
    process quits when the device is lost" is removed. The e2e `device-recover` uses an SGR 48;2 cell block as its
    marker, not a Kitty image (§18.33). Residual: a surface that is hidden and unhealthy mid-recovery may show the default
    health text; `markUnhealthy` pushes `.forever` under `draw_mutex` (deadlocks only on a full mailbox).
30. R-M3-11, `docs/windows/feature-checklist.md` (one line per cross-platform feature: milestone, evidence, status) is the M3
    exit artefact and feeds the v1.0 gate.
31. R-M3-12, text drops go through core's paste path (`completeClipboardRequest` with a `.paste` request), so bracketed
    paste and the unsafe-paste confirmation apply as for Ctrl+V (M2 §18.17 text drops).
32. Task 8 spike verdict (`test/windows/composition-spike/RESULT.md`): (a) a DComp child target with a worker-thread
    composition swap chain works; (b) a transparent client works only via `DwmEnableBlurBehindWindow` (empty region) with
    the child erasing with a black brush, `DwmExtendFrameIntoClientArea(-1)` + `DWMSBT_NONE` stays opaque black; (c) Acrylic
    works with "Transparency effects" on; (d) works; (e) the target survives `SetParent`, a second target on the same HWND fails
    `0x88980800` (release the old one first); (f) PrintWindow misses the backdrop, use screen capture; (g) pacing is unchanged
    (about 8.1 ms); (h) the DComp device costs 0.07-0.20 MB (one null-device DComp device per process); (i) a minimised
    composition chain keeps presenting (90-120 fps, never occluded), so the renderer throttles itself on `IsIconic`; (j) hwnd and
    composition switch cleanly; (k) `ALLOW_TEARING` is accepted (creation and present flags in lockstep); (l) the DComp
    device survives D3D device recreation. DPI was simulated; one GPU and one monitor.
33. L1, ConPTY ruling (M3 Task 28 probe, `test/windows/conpty-probe/RESULT.md`). The inbox conhost with default flags
    delivers OSC 9, 777, 133, 8 and 22 to the terminal; it drops Kitty graphics APC sequences and mangles SGR 58 (underline
    colour); `PSEUDOCONSOLE_PASSTHROUGH_MODE` (flag 8) arrives identical for the probed sequences and does not rescue the APC.
    No default-flag change (Task 28.1 is not scheduled). Kitty graphics and SGR 58 underline colour are therefore
    **owner-approved provisional gaps** (the vt-smoke cases `kitty-image` and `underline-colors` SKIP and carry no reference)
    until a newer `conpty.dll` + OpenConsole is bundled (an owner question: needs a download approval, selectable with
    `GHOSTTY_WIN32_CONPTY_DLL`). Not gating: with flag 8 a Debug run showed key-echo whole-path p95 18.8 ms against 50 ms with flag 0.
    **Update (M5, owner-approved download):** a headless probe (`conpty-probe/headless.ps1`, `RESULT.md` "Bundled ConPTY")
    ran `Microsoft.Windows.Console.ConPTY` 1.25.260930003 (`conpty.dll` + `OpenConsole.exe`, MIT, signed by Microsoft).
    It forwards Kitty APC, SGR 58 and OSC 133/7/8/52/9 byte-identical and in place, unlike the inbox console, which
    rewrites OSC 8 and moves OSC 7/52/9. Resize works, and its key-echo p95 is below 1 ms (inbox: 0.6 to 15 ms).
    - **Decision:** `windows-conpty = auto` is the default: bundled, except inbox for MSYS2/Cygwin programs (Git
      Bash). On the bundled console their runtime loses the first key read after a resize: reading the console size
      makes OpenConsole query the cursor (`CSI 6 n`) through the terminal, and the key read around it is dropped
      (e2e `resize-input`: 4-12 of 36 lines on bundled, 0 on inbox; the resize prime does not help). `bundled` and
      `inbox` force. Every win32 build installs the pair for x64/arm64 from
      `vendor/conpty` (committed: `zig fetch` cannot unpack a `.nupkg`; `-Dconpty-dir` overrides) next to
      `ghostty.exe`, with `THIRD_PARTY_NOTICES.txt`.
    - **Loading:** `LoadLibraryExW("conpty.dll", APPLICATION_DIR | SYSTEM32)` once both files are found in the exe
      directory. Missing files or a failed load mean one log line and the inbox console; `windows-conpty = inbox` forces
      it. A pty keeps the ConPTY it was created with.
    - **Flags:** 0. Flag 8 means `GLYPH_WIDTH_GRAPHEMES` in this package, which has no passthrough flag; it changed
      nothing measured.
    - **Terminal duties:** the bundled console forwards the application's `CSI 6 n` to the terminal and resyncs its
      cursor from the reply, so Ghostty's grapheme widths win. At start it sends DA1 and `CSI 1 t`.
    - **Gaps:** the Kitty graphics and SGR 58 gaps become pending GUI checks (vt-smoke `kitty-image`,
      `underline-colors` references).
34. Execution rulings of M3 (lead, recorded for the owner):
    - Task 7: a failing custom post shader drops all custom shaders (as Metal/OpenGL do); `generic.zig` `has_custom_shaders`
      requires `post_pipelines.len > 0` (also fixes a latent Metal/OpenGL bug: candidate upstream PR). Task 7.1: shader passes
      use UNORM views (gamma space), animation draws are paced on the frame slot.
    - Task 15a: composition hosting (Surface/Tab) and the persistent blur backdrop; 15b: chrome painted with the same alpha
      (sRGB premultiply of background layers only). Task 9: `theme.windowActive` helper and a pending-activation flag with 1 s
      expiry for owned popups.
    - Task 29 (chrome redesign): the title area and tab row follow Ghostty for macOS (DECISIONS 2026-10-27). Task 29.1: OSC 7
      is translated to a local drive path in core `reportPwd` on Windows only; UNC paths are not supported (untrusted OSC 7
      could make the next tab or a link open contact an SMB share, an NTLM hash leak); any program may set a local-drive cwd for
      the next tab (upstream parity); Git Bash integration emits OSC 7 from the builtin `pwd -W`, recomputed only when `PWD` changes.
    - Owner decision (readline `bell-style visible` in Git for Windows' `/etc/inputrc` flashed the window on backspace at an
      empty prompt): bash integration on MSYS sets `bell-style audible` unless the user's inputrc sets a bell style.
    - Task 25.1: the scrollbar is an overlay scroller like macOS (AppKit numbers approximate); an empty-track click is swallowed
      (avoids a stray selection under a closing popup); no track-click autorepeat.
    - Test harness (privacy): every screen capture goes through `Get-ScreenShot` / `Save-WindowShot`, which check the exact
      z-order and a `WindowFromPoint` grid and skip (E2E-SKIP, nothing saved) when a window that is not ours is in the
      capture area; images are cropped to the Ghostty window (a margin only over the scenario's own backdrop).
    - Task 26: `vt-smoke` references are keyed by display scale (`ref/<case>@<dpi>.png`, a missing DPI is a SKIP);
      `background-focus` retries an exit line lost by Git Bash. Result: the Git Bash input loss is worked around, see Tasks 26.4 and 26.4.1 below.
    - Task 26.4: after a pseudo console resize, MSYS2 (Git Bash) sometimes takes in the window-size event only together
      with the next input record and loses that record (the shell misses the SIGWINCH until then; a delay does not help:
      0 lost at 0-20 ms, 3-5 of 12 at 50-1500 ms). Workaround in `termio/resize_prime.zig`: the first pty write after a
      grid change (and any write within 50 ms of it) starts with a win32-input-mode Shift key-up (`CSI 16;42;0;0;0;1 _`);
      it is the record lost, and every reader ignores a lone key-up (Cygwin drops key-ups, cooked readers never see
      them). Armed only after the pseudo console asked for win32-input-mode (`CSI ? 9001 h` in its first output, found
      across read splits), so an older conhost never gets the sequence; the write path costs one branch otherwise.
      Evidence: `e2e/resize-input` (Git Bash 36 checks over window, split and tab-strip resizes; cmd.exe and pwsh lines
      unchanged), 9 of 20 lost without it; under heavy CPU load the 50 ms window now starts at conhost's first output after the resize (cap 2 s; 36/36 with 12 burner threads; before, 2 of 36 lost once
      when conhost handled the resize late). Root cause not proven (a minimal kernel32 ConPTY host never reproduced it);
      follow-up: report to msys2-runtime (pointer: `strip_inrec` in the Cygwin console code).
    - Task 26.4.1: the resize-prime window now starts at conhost's first output after the resize (cap 2 s), so a resize that
      conhost handles late no longer loses the record (36/36 with 12 CPU-burner threads; 2 of 36 before).
    - Task 26.5: the inspector gives imgui its own heap (`ImGui_SetAllocatorFunctions`, destroyed with the last context);
      30 s after close it holds about +1.9 MB over the pre-open value (was +3.6; 2 of 5 samples over +2, borderline).
      Overlays: no code change, the cost is first use of shared Direct2D/DirectWrite/uxtheme state (+0.4 MB warm, about
      +2 MB for a cold first paint); owner-visible note in `docs/windows/m3/acceptance.md`.
    - Windows 11 dialogs (`fe9a5d5b2` and fixes): see 7.6 and DECISIONS 2026-10-28.
    - M3 final review (`docs/windows/m3/final-review.md`): title updates use a fixed 75 ms window; link confirmations go
      through the message window; proxy icon and reveal refuse links that leave the local disk; deferred to M5:
      `export_terminal_io` write off the UI thread, translucent capture guard, DPAPI for the e2e clipboard backup.
35. Rulings of M4 (plan-m4 revision 2, lead 2026-10-28; owner may overturn). Ledger rulings: (a) the opt-out key
    `windows-tmux-shim` (R-M4-11); (b) a DCS `tmux;` channel that ConPTY does not provide is a documented gap, not code
    (R-M4-10); (c) real Claude Code runs are allowed (owner's shared login, option B: CLI flags only, `CLAUDE_*` removed,
    sonnet, 10 minute box, stop at the first auth error, only the run's own files removed).
    - R-M4-1, one server implementation, two pipes: the tmux pipe is a second `ipc.Server` instance with `post_tag` 1,
      `max_request` 4 MiB, `io_timeout_ms` 500 and `close_wait_ms` 200; routing on wparam before the main-server guard; every
      non-forwarding process claims its own pipe (`ghostty-tmux-<pid>-<nonce>`, 64-bit nonce); a failed claim leaves `TMUX`
      unset. The client opens only that name shape, with `SECURITY_IDENTIFICATION`, and checks the server pid (§12.1).
    - R-M4-2, ids without a registry table: `Surface.pane_id` from a monotonic counter (a respawn keeps its number); `@N` =
      `Tab.id`; lookups scan the windows and re-resolve by id after every mutation.
    - R-M4-3, headless semantics: `tmux/commands.zig` runs against a duck-typed `Host`; the replay of the recorded Claude
      sequence runs against `FakeHost` (same `layout.zig`), the real host against the same sequence in `tmux-replay`.
    - R-M4-4, flag policy: every command parses tmux 3.5a's full getopt template; a flag with no visible effect is
      accepted and ignored, an unimplemented semantic fails with `<cmd>: -X is not supported by Ghostty`, an unknown flag
      with `command <cmd>: unknown flag -X`; names, aliases and unique prefixes resolve against the full command table.
    - R-M4-5, pane spawn: `cat` is `tmux.exe __idle`; an empty command is the configured one; with Git Bash
      (`CLAUDE_CODE_GIT_BASH_PATH` of the client, else the search) the string runs as `bash -c`; else the one-liner parser
      (`[cd W &&] [env (NAME=W)*] W+`); cwd = `-c`, else the `cd` target (parser path), else the client cwd; a missing
      directory fails with `can't find directory`; every shim pane gets `wait-after-command`. `MSYS_NO_PATHCONV` is not set (it would leak into the teammates' Bash tool), so native Windows targets see MSYS path conversion: an intended difference from tmux. Known gap: a config reload drops
      it.
    - R-M4-6, `send-keys` gate: the answer is immediate; bytes are queued and flushed by a message-window timer once the
      pane is 300 ms old and its tab's layout has been quiet for 150 ms (Git Bash first-byte loss; kept after the Task
      26.4 prime, which only covers resize).
    - R-M4-7, `capture-pane`: the visible screen only (`-p` prints, else the buffer); ranges (`-S`, `-E`) are ignored with a note on stderr, `-a -b -C -e -M -P -T` are
      refused.
    - R-M4-8, titles and styles: `select-pane -T` pins the user title (re-applied after a respawn); options are stored
      verbatim (value ≤ 8192 bytes, ≤ 256 per map); only `remain-on-exit` and the `pane-border-*` options act; labels follow
      `optionsChanged`.
    - R-M4-9, trace and stats: `GHOSTTY_TMUX_TRACE` (one JSON line per call, append-only, stdin never traced) and
      `GHOSTTY_TMUX_STATS=1` (`peak_private_kb`, `wall_ms`, `build`).
    - R-M4-10, DCS `tmux;`: core already dispatches the unwrapped inner sequence (stream tests); the inbox ConPTY drops
      an ST-terminated inner OSC 777 and forwards a BEL-terminated OSC 9 as a bare OSC 9 (Task 2): documented gap (§12.4).
    - R-M4-11, the key `windows-tmux-shim = true|false` (default true in M4-M6, **false since M7**, R-M7-1; Windows only, app-wide, read when a surface starts):
      false sets/removes neither `TMUX` nor `TMUX_PANE` and does not change PATH.
    - Acceptance (M4 Task 15): the budgets and the real runs are in §17; the RAM rows are tagged `m4-*` in
      `docs/windows/ram-baseline.csv`, the latency rows `m4-tmux`/`m4-a`/`m4-base` in `latency-baseline.csv`.
36. Rulings of M5 (plan-m5, lead 2026-10-28; owner may overturn; plan `docs/windows/plans/M5-windows-extras.md`). Owner answers on the
    ledger: `auto-update` defaults to `check`; external tmux mode is opt-in; the profile menu opens on right-click of `+` (plus palette
    and tray); `+edit-config` opens a new Ghostty with the editor, else Notepad; AUMID self-registration stays, `--all` reverts it; WSL distros
    come from the Lxss registry and terminfo is compiled by Git for Windows' `tic.exe`.
    - R-M5-1, profiles are detected, not configured: `windows_shell.profiles` returns `default`, `git-bash`, `pwsh`, `powershell`, `cmd`,
      `wsl:<distro>` (§10). Distros from `HKCU\...\Lxss` read-only (default first, `docker-desktop*` skipped, names `[A-Za-z0-9._-]{1,64}`).
      Ids are stable ASCII; the list is cached on the App and rebuilt when a profile menu opens. No config key for custom profiles.
    - R-M5-2, `--profile=<id>`: a launch/IPC argument parsed by `Overrides`, forwardable (it names a profile, never a command, so M2
      revision 2 holds). The receiving process resolves the id; unknown gives IPC code 1 `unknown profile: <id>` (standalone: one warning and
      `Default`). With `-e`/`--command=`, `-e` wins and a warning is logged. `--working-directory=` values ending in `\.` are normalised.
    - R-M5-3, where profiles are offered: right-click on `+` (New Tab items, separator, "New Window" submenu; `SetForegroundWindow` before
      `TrackPopupMenuEx`, `WM_NULL` after; left click unchanged), palette items `New Tab: <profile>` / `New Window: <profile>`
      (`Run.profile`, reachable with one tab), tray "New Window" submenu, jump list. Menus are native, themed like `tab_menu.zig`.
    - R-M5-4, jump list (`ICustomDestinationList`, AUMID of §13): tasks only (no custom category): New Window, New Tab
      (`+new-tab --working-directory=home`), a separator, one task per profile except `Default` (`--profile=<id>`); working directory
      `%USERPROFILE%`, icon = the profile's exe. The UI thread builds the items and hands them to an STA worker that never reads App state;
      built 2 s after start, on profile-list change and config reload, primary instance only, `windows-jump-list = true` (default); off
      calls `DeleteList` once. `stop` waits at most 2 s for the worker, else leaks it with a log line. `+new-tab` with no instance starts the
      own exe (`jumplist.newTabFallback`, from `performIpc`'s `.no_server` arm, `.new_tab` only).
    - R-M5-5, Explorer keys: see §13. CLI: `+uninstall-explorer-integration` deletes exactly the three keys (foreign keys reported and kept),
      `--all` also deletes the AUMID key and the toast icon file, `--dry-run` prints every key and value and opens no key. The jump list is
      cleared by Ghostty itself on its next start with `windows-jump-list = false`. M6: the installer writes the same keys, and its
      shortcut carries the AUMID (§13).
    - R-M5-6, prompt marks (independent of the `title` feature): pwsh `prompt` returns `133;A` + text + `133;B`; `133;C` after
      `AcceptLine` by wrapping `PSConsoleHostReadLine` (a foreign wrapper is chained); `133;D;<code>` at the start of `prompt`, never before
      the first prompt or after an empty Enter, with the exit code from `$?`/`$LASTEXITCODE`; without PSReadLine only A/B. cmd: `PROMPT` =
      `$e]133;D$e\$e]133;A$e\` + (title/OSC 7 part when `title` is on) + the user's prompt + `$e]133;B$e\`, idempotent at both ends; the D has
      no exit code, so there is no `command_finished` for cmd (documented gap), but `jump_to_prompt` and output boundaries work. Git Bash keeps
      the upstream marks. As built: the PowerShell 5.1 and 7.x overloads are chosen by reflection.
    - R-M5-7, terminfo and `TERM`: see §8.5 and §10. Cost if wrong: one default.
    - R-M5-8, MSYS: see §10 (mixed-form env paths, `/c/...` TERMINFO, bash `path` feature skipped under MSYS).
    - R-M5-8b, `+edit-config`: `VISUAL`, else `EDITOR`, tokenised with the Windows rules (`windows_cmdline.zig`), exe resolved on
      PATH/PATHEXT. A PE subsystem of `IMAGE_SUBSYSTEM_WINDOWS_GUI` is spawned directly with the path; otherwise a separate Ghostty runs
      `--class=<config class> -e <tokens> <config path>`, detached (a GUI-subsystem `ghostty.exe` cannot share the caller's console with a
      terminal editor, §11). No editor: `%SystemRoot%\System32\notepad.exe <path>`, detached (upstream errors here). The CLI exits 0 after
      spawning. `.cmd`/`.bat` editors run detached without a window.
    - R-M5-9, update check (`src/apprt/win32/update/`): `auto-update` unset means `check` on Windows, `download` means `check` with one
      warning, `off` means never automatic; no automatic check in Debug, in test mode or in a build without `-win.<N>`. Endpoint (constant)
      `https://api.github.com/repos/Denmurzik/ghostty/releases?per_page=20`, `Accept: application/vnd.github+json`,
      `User-Agent: Ghostty/<version> (Windows)`, no other header, cookie or identifier. WinHTTP with automatic proxy, TLS only (plain `http`
      only for the loopback test override `GHOSTTY_WIN32_UPDATE_URL`, test mode only), body cap 1 MiB, 10 s per phase and a 10 s wall-clock
      deadline enforced by closing the request handle from the UI thread's timer; `stop` closes it and joins (at most 2 s); `winhttp.dll` is
      loaded at runtime and waited on (at most 2 s, `WINHTTP_OPTION_UNLOAD_NOTIFY_EVENT`) before `FreeLibrary`. First check 60 s after start,
      then every 24 h, skipped when `%LOCALAPPDATA%\ghostty\update.json` (`{"last_check":<unix s>,"notified":<N>}`) says under 24 h. A redirect
      is not followed. `check_for_updates` always answers with a Windows 11 dialog (up to date / available with "Open release page" / local
      build / could not check). `ghostty.exe` imports neither `winhttp.dll` nor `dbghelp.dll` (checked by Task 20 Step 3).
    - R-M5-9a, version and tag scheme: see §13. A newer non-draft release (pre-releases included) whose `tag_name` is a valid
      `win-<zon>-<N>` gives one toast per `N` (`Ghostty <zon>-win.<N> is available`, "Open the release page"); the click opens `html_url`
      only if it starts with `https://github.com/Denmurzik/ghostty/releases/tag/win-`. Cost if wrong: re-tag before M6.
    - R-M5-10, crash dumps: see §11 (Zig's segfault handler off on Windows, unhandled-exception filter, dump thread, `MiniDumpFilterMemory`,
      10 kept, local only; as built, a stack scrub after the write).
    - R-M5-11, `secure_input` analog: Windows has no API that hides keystrokes from other same-user processes, so it means (1)
      `SetWindowDisplayAffinity(WDA_EXCLUDEFROMCAPTURE)` on every top-level window of the UI thread (windows, palette/search/labels/badges
      popups, dialogs, inspector windows, the tab drag ghost; a sweep on every toggle and `secure_input.apply(hwnd)` at each creation site);
      (2) text copied while on carries `ExcludeClipboardContentFromMonitorProcessing`, `CanIncludeInClipboardHistory = 0` and
      `CanUploadToCloudClipboard = 0`; (3) the lock badge when `macos-secure-input-indication = true` (25 DIP `lock.shield` glyph, Segoe Fluent
      Icons `0xE72E`, 10 DIP from the top-right of each surface; a click opens a Windows 11 explainer dialog). App-wide like macOS
      (`on`/`off`/`toggle`). No automatic secure input at password prompts (ConPTY has no termios): documented gap.
    - R-M5-12, undo/redo (macOS `BaseTerminalController`/`TerminalController` semantics, apprt only): entries are registered only in
      `Window.zig`'s request handlers (`handleCloseTab`, `handleClose`, `handleCloseSurface` except for `child_exited`) after any
      confirmation answered yes; `close_all_windows` and the tab-menu `others`/`right` closes push one grouped entry; `removeSurface`/`removeTab`
      stay the non-undoable primitive used by tmux, IPC and expiry. A closed tab, window or split is **parked** (HWNDs hidden,
      `focusCallback(false)`, surfaces and child processes alive) and really closes after `undo-timeout` with the §18.14 semantics; a parked
      surface whose child exits closes for real. Parked items are invisible to tmux, the tray, `goto_window`, the IPC lookups
      (`Surface.parked()`) and the last-window rule, but still get config, theme, colour-scheme and device-loss sweeps through
      `App.forEachWindow(include_parked = true)`; `quit` closes parked items before its confirmation. With
      `quit-after-last-window-closed = true`, closing the last window quits and is not undoable. A tmux `kill-*` close is final. Task 15a:
      tabs and windows; Task 15b: splits via tree snapshots (restored only if the tab's tree is node for node the tree the close
      produced, else the entry is dropped with a log line), undo of create (new tab, window, split) and `redo`; every entry flips between two
      states, undo and redo are the same flip, and a flip gives a fresh expiry.
    - R-M5-12a, undo default and keys: Windows `undo-timeout = 5s` like macOS, Windows-only default binds `ctrl+shift+z` = `undo` and
      `ctrl+shift+y` = `redo` (`performable`); `ctrl+shift+t` is `new_tab`, `ctrl+z` belongs to the shell. Cost: for 5 s after a close the
      tab's programs keep running (a dev server keeps its port), a departure from the Windows Terminal close semantics. Alternative:
      `undo-timeout = 0` on Windows with no keys. The CHANGELOG states the choice.
    - R-M5-13, `show_on_screen_keyboard`: if `IFrameworkInputPane::Location` reports an empty rect, `ITipInvocation::Toggle(GetDesktopWindow())`;
      never hide it. If `CoCreateInstance(CLSID_UIHostNoLaunch)` fails with `REGDB_E_CLASSNOTREG` (TabTip not running), `ShellExecuteW`
      `%CommonProgramFiles%\microsoft shared\ink\TabTip.exe` and retry once. Test mode only records.
    - New tab fill (#57): in composition mode (translucent window) a swap chain is handed to the compositor only after its first
      successful present, and until a chain shows, the pane erases itself with the applied light/dark theme background
      premultiplied at the window alpha; after the first attach `setContent` waits for the commit before erasing to alpha 0.
      Opaque windows keep the `WM_ERASEBKGND` fill from 468bace72.
    - 19.n batch 2 (parity audit): About dialog (palette, tray, tab menu; GitHub button opens the fork's issues, Docs ghostty.org),
      `window-step-resize`, `initial-window`, `window-subtitle`, `bell-audio-volume`, `auto-update-channel`; see `parity-audit.md`.
    - R-M5-14, external tmux mode is opt-in (`windows-tmux-external = false`): see §12.4. It relaxes M2 revision 2.
    - Other M5 rulings: right-click default `right-click-action = copy-or-paste` on Windows (Windows Terminal/conhost convention), with a
      native context menu for `context-menu`; drag-and-drop pastes Windows paths (`C:\x`, quoted) in Git Bash/Cygwin and `/mnt/c` for WSL;
      popup menus follow the app theme (undocumented uxtheme ordinals 135/136 loaded from System32 only, build 18362 or later, high contrast
      uses the system theme, silent fallback); no network at all in test mode unless the loopback override is set.
    - R-M5-15, `tui-latency` is a known limit for v1.0 (lead ruling, 2026-10-29): Ghostty-owned p95 14-16 ms against the 6 ms gate, bound by one 60 Hz frame; M3 already measured 9.7 ms on `b2-vim` at 120 Hz. Not a blocker. Cost if wrong: TUI scrolling feels about a frame slower than the target.
    - R-M5-16, `split-many` teardown gates are 100 ms on ReleaseFast and 150 ms on Debug; 112 ms was measured once on ReleaseFast. Cost if wrong: Debug teardown regressions up to 150 ms go unflagged.
    - R-M5-17, `windows-conpty = auto` is the default: inbox console for MSYS2/Cygwin programs (the bundled one loses the first key after a pty resize there), bundled otherwise; Kitty graphics and SGR 58 therefore do not work in Git Bash. A time-boxed input hold-back was ruled out by timing evidence. Cost if wrong: Git Bash users miss graphics, or MSYS2 loses keys if `bundled` is forced.
    - R-M5-18, the 50 MB Debug `stream-integrity` run (never finished since M1) and the per-feature RAM rows (no `measure-ram.ps1` recipes) are documented limits, not blockers; ReleaseFast passes the stream in 42 s.
    - M6 rulings (plan-m6 and lead, 2026-10-28; the owner may overturn; full text in `docs/windows/plans/M6-release.md`):
      - R-M6-1, versions: a `win-` git tag is treated like `tip` by the `Config.zig` tag check; the release version comes only from
        `-Dversion-string=<zon>-win.<N>`; the raw text must end in `-win.<N>` (`N` canonical, <= 65535, no `+build`) or the build fails
        naming the value. Cost if wrong: one `switch` arm and one text check.
      - R-M6-2, version resource: one `versioninfo.rc` for `ghostty.exe` and `tmux.exe` (numeric literals, no `winver.h`); no `CompanyName`;
        `tmux.exe` still imports only kernel32/ntdll/advapi32 (the M5 SID check needs advapi32; the allowlist was amended in M6).
      - R-M6-3, artifacts: six artifacts + `SHA256SUMS.txt`; zip with one top folder; `-Dstrip=false` for PDBs in `-symbols.zip` only. Cost
        if wrong: the default strip and no symbols.
      - R-M6-4, installer: per-user only, running-Ghostty guards in `PrepareToInstall`/`InitializeUninstall` (Retry/Cancel; silent setup
        exit 7), `CloseApplications=no`, `/DGhosttyTest` variant for the e2e. Cost if wrong: the owner closes Ghostty by hand before an upgrade.
      - R-M6-5, `+uninstall-explorer-integration --only-this-exe`: a verb counts as ours only if it names this exe.
      - R-M6-6, local release path, no CI (owner: Actions minutes exhausted); upstream workflows untouched; ARM64 unit tests are an
        owner check and never block; `workflow_dispatch`-only `windows-ci.yml` is a backlog line.
      - R-M6-7, release: tag `win-<zon>-<N>`, `N` from 1 and never reused; `release.ps1` prints, the owner runs; draft first, then published.
      - R-M6-8, signing hook without a certificate; `-SignCommand` never touches the Microsoft ConPTY files.
      - R-M6-9, v1.0 gaps: per-machine install, MSIX/top-level menu, winget/scoop, signing (Smart App Control blocks the unsigned build, no
        override), ARM64 automated tests, jump-list removal on uninstall.
      - R-M6-10, third-party notices with full licence texts, checked at packaging.
      - R-M6-11, ARM64 release ABI `aarch64-windows-gnu` (amends R3; owner sign-off pending). Cost if wrong: add the VS ARM64 component
        (admin, once) and pass `-Arm64Abi msvc`.
      - R-M6-12, bundled ConPTY ships (owner approval 2026-10-28), package 1.25.260930003, signature and hashes checked.

Rulings for M7 (plan-m7 and lead, 2026-10-29; the owner may overturn; full text in `docs/windows/plans/M7-win2.md`, as built here):
- R-M7-1, tmux shim off by default; `CLAUDE_CODE_TMUX_TRUECOLOR=1` with the key on; the pipe server still starts (§10, §12).
- R-M7-2, installer task `explorer` renamed `explorermenu`, ticked by default; unticking on an upgrade removes the top-level package
  (deviates from the plan wording, which kept everything; the classic verb is untouched) (§13.1).
- R-M7-3, symbols and emoji from Segoe UI Symbol/Emoji, embedded Noto only without DirectWrite; colour check passed (COLR v0), so no Noto fallback (§9).
- R-M7-4, tab rename in an owned borderless popup. **As built: focus loss cancels** (the existing tested behaviour), not commits as the plan text said.
  A translucent window keeps the popup opaque; its scenario phase checks only no-white and visible text.
- R-M7-5, `font-thicken` on Windows; the comparison ended with the owner's pick of variant A: no default change (§9).
- R-M7-6, Windows paths in links (`X:\…`, `X:/…`, `.\…`, `..\…`, `dir\file.ext`), never UNC or `\?\`, `:line[:col]` kept.
- R-M7-7, `CF_HDROP` paste when no text is on the clipboard; text wins.
- R-M7-8, `click-repeat-interval = 0` follows `GetDoubleClickTime()`.
- R-M7-9, pwsh `cursor`/`ssh-env`/`ssh-terminfo` (a synchronous `ssh` function), cmd `cursor` (stays during commands) and `ssh-*` (`ssh.cmd` on the pane `PATH`).
- R-M7-10, WSL start directory with an OSC 7 host check; custom `wsl.conf` hostname and `/c/x` mapping are documented limits (§10).
- R-M7-11, Kitty: no DCS `tmux;` unwrap; the `a=q` reply needs no code (the headless probe: plain reply arrives on the bundled console, so
  Task 12 was only the end-to-end case); `t=s` and MSYS paths stay out.
- R-M7-12, MSYS stays on the inbox console under `auto` (documented limit): the bundled console lost whole lines in 7-16 of 36 checks per run, with
  VT or win32-input-mode keys, against 0 of 48 on inbox; Windows Terminal does not show it. Kitty in Git Bash is opt-in with
  `windows-conpty = bundled`. `docs/windows/m7/msys-key-loss.md` has the measurements and the unsent bug-report text.
- R-M7-13, the Windows 11 top-level menu: `ghostty-explorer.dll` + unsigned sparse package; **folders and folder backgrounds only, drives keep the
  classic verb** (schema limit); tested only on the owner's machine (§13.1).
- R-M7-14, release `release.ps1 -N 2`, no upstream merge; the lead adds highlights and the residual-risk line to `release-notes.md`.
