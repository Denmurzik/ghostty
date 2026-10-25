# M1 — Core builds + single-window terminal: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `zig build -j4` on Windows produces `ghostty.exe` that opens one window running Git Bash (→ pwsh → cmd) over ConPTY, rendered by a Direct3D 11 backend, with keyboard (AltGr, dead keys), IMM32 IME, mouse, clipboard, the single config path, and file logging.

**Architecture:** Make the existing core compile on Windows with platform-gated fixes, add a hand-written Win32/COM binding package `pkg/win32`, a native Zig apprt `src/apprt/win32` (top-level HWND + one child HWND per surface, UI thread message loop) and a `GraphicsAPI` backend `src/renderer/D3D11.zig` that presents from the render thread into a flip-model swap chain on the surface HWND (one shared device, context lock).

**Tech Stack:** Zig 0.17.0, MSVC ABI, Win32 (user32/imm32/dwmapi), Direct3D 11 + DXGI 1.2+, runtime `d3dcompiler_47.dll`, HLSL SM 5.0, FreeType + HarfBuzz (existing), ConPTY (existing), libxev IOCP (existing), PowerShell harness scripts.

**Spec:** docs/windows/SPEC.md

## Global Constraints

Copied from `docs/windows/DECISIONS.md` (binding) and SPEC.md. Every task implicitly includes these.

- Zig 0.17.0 at `C:\tools\zig-x86_64-windows-0.17.0\zig.exe` (always the full path). Shell: Git Bash.
- Target ABI = MSVC (R3). Archs: x86_64 + aarch64 (ARM64 only cross-built; cannot be tested locally). Minimum OS: Windows 11 22H2.
- App runtime: NEW native Zig apprt `src/apprt/win32` — pure Win32 + DWM. No WinUI, no GTK, no .NET (R5).
- Renderer: NEW Direct3D 11 GraphicsAPI backend `src/renderer/D3D11.zig` + `src/renderer/d3d11/`.
- Builtin renderer shaders are hand-written HLSL ported from `shaders.metal` (D3D11 is Y-down like Metal); runtime `D3DCompile` via `d3dcompiler_47.dll` (R4).
- Code is laid out so it could be upstreamed: Windows code isolated in its own dirs/arms; core changes minimal and platform-gated.
- Config: exactly ONE path on Windows: `%USERPROFILE%\.config\ghostty\config.ghostty` (if `XDG_CONFIG_HOME` is set it replaces the `%USERPROFILE%\.config` base). No legacy `config` filename fallback on Windows, no AppData, no `~/.ghostty`.
- Default shell order: Git Bash → pwsh (PowerShell 7) → cmd. Git Bash runs with `--login -i` and `CHERE_INVOKING=1`.
- Binary `ghostty.exe`, name "Ghostty — Unofficial Windows port", original Ghostty icon.
- Machine: 15.5 GB RAM, ~4–5 GB free. Builds/test suites strictly one at a time through the test-lock; zig builds with `-j4`. Bash timeout 600000 for every build/test command.
- Commits: no `Co-Authored-By` or similar trailers.
- Visual verification: screenshots of the Ghostty window after UI/renderer changes (from Task 24 on; earlier tasks have no pixels).
- No `std.os.windows` beyond basic types; core (`src/os`, `src/termio`, `src/config`, `src/font`) uses `src/os/windows.zig` and never imports the `win32` module; apprt and renderer use `pkg/win32`.

Command abbreviations used below (expand literally; shell state does not persist):
- `LOCK` = `bash "%USERPROFILE%/.claude/mods/teamlead/skills/teamlead/scripts/test-lock" --`
- `ZIG` = `"C:/tools/zig-x86_64-windows-0.17.0/zig.exe"`
- Run everything from `C:/D/den4ik/Ghostty` (or the task's worktree root).
- Windows-specific test names start with `win32 `, `d3d11 `, `windows ` so `-Dtest-filter` selects them.

## Review Focus

1. User profile / install paths with spaces and non-ASCII characters (e.g. `C:\Users\Анна Ли`) must work for the config path, the resolved shell argv and quoted `command` strings → tests in Task 7 (xdg/homedir), Task 8 (resolver argv), Task 15 (tokenizer).
2. Closing a surface while the child is streaming output, or while grandchildren run, must not hang and must leave no orphan processes → tests in Task 9 (quit during streaming) and Task 15 (job kills grandchildren).
3. Non-US keyboard layouts: AltGr characters (DE `AltGr+Q` = `@`), dead keys (DE `^` then `e` = `ê`), RU layout typing Cyrillic while `ctrl+shift+c` still matches the physical-C binding → tests in Task 20.
4. Clipboard temporarily held by another process, and pastes containing newlines/control bytes (unsafe paste) → retry + confirmation tests in Task 23.
5. Minimize (0×0 client), tiny sizes and DPI changes must not crash or draw into a zero-sized target; content scale follows `GetDpiForWindow` → tests in Task 18 (size/scale/occlusion) and Task 24 (ResizeBuffers 1×1 ↔ full, 0-size skip).

## Waves (parallelism)

Tasks in the same wave touch disjoint files except where noted ("shared file, distinct hunks" — merge sequentially, no semantic overlap).

| Wave | Tasks (parallel) | Depends on |
|---|---|---|
| W1 | 1 build gating · 3 pkg/win32 COM + D3D spike | — |
| W2 | 2 known core source fixes · 4 D3D11 contract stub · 6 pkg/win32 Win32 bindings + wiring | 1 (2, 4); 3 (6) |
| W3 | 5 core compile peel (exclusive on core files) | 2, 4, 6 |
| W4 | 7 config path · 8 shell resolver + TERM · 9 pty read loop · 10 logging/console · 11 apprt skeleton · 12 D3D11 device/resources · 13 HLSL text shaders · 14 font discovery | 5 (all); 3 (12, 13) — Config.zig shared by 7/8/11 (distinct hunks) |
| W5 | 15 job object + tokenizer · 16 HLSL image shaders · 17 Pipeline/RenderPass/Target · 18 apprt Surface hosting | 9 (15); 13 (16); 12+13 (17); 11 (18) |
| W6 | 19 shaders.zig/Frame/D3D11 headless · 20 keyboard · 21 mouse · 22 IME · 23 clipboard + dialogs | 16+17 (19); 18 (20–23) |
| W7 | 24 swap chain + present | 18, 19 |
| W8 | 25 integration + e2e harness | all above |
| W9 | 26 RAM baseline + M1 acceptance | 25 |

---

### Task 1: Build-graph gating for the Windows core

**Files:**
- Modify: `src/build/SharedDeps.zig:214-229` (posix_c include list), `src/build/SharedDeps.zig:656-663` (glad block)
- Modify: `src/build/GhosttyResources.zig:280-360` (template processing that runs `tail`)
- Modify: `src/main.zig:24-40`, `src/main_c.zig:46-52` (memset quirk import)

**Interfaces:**
- Consumes: nothing.
- Produces: on `os.tag == .windows`, module `posix_c` translates only `errno.h`, `signal.h`, `sys/types.h`; glad sources are compiled only when `config.renderer == .opengl`; no `tail` system command is created for a Windows target; `quirks_memset` is not referenced when `target.os.tag == .windows and target.abi == .msvc`.

- [ ] **Step 1: Reproduce the baseline failure**
  Run: `LOCK ZIG build -Dapp-runtime=none -j4 2>&1 | tail -40`
  Expected: FAIL, `posix_c.h:2:10: fatal error: 'pwd.h' not found`.
- [ ] **Step 2: Make the posix_c include list OS-conditional** (`pwd.h`, `unistd.h` only for non-Windows; keep the module name so `@import("posix_c")` still resolves on Windows).
- [ ] **Step 3: Gate glad** — wrap the `vendor/glad/src/gl.c` include/source in `if (self.config.renderer == .opengl)`; the EGL sub-block stays inside it.
- [ ] **Step 4: Remove `tail` from Windows builds** — skip the Linux-only templates (desktop, D-Bus, systemd, metainfo) when `target.os.tag` is not linux/freebsd.
- [ ] **Step 5: Gate the memset quirk** — in `src/main.zig` and `src/main_c.zig`, import `quirks_memset.zig` only when not (`windows` and `msvc`); add a comment pointing at the `libvcruntime` duplicate-symbol error ([build §4 #6]).
- [ ] **Step 6: Verify**
  Run: `LOCK ZIG build -Dapp-runtime=none -j4 2>&1 | grep -E "pwd.h|unistd.h|'tail'|duplicate symbol: memset" ; echo rc=$?`
  Expected: no matching lines (`rc=1`); remaining errors are Zig analysis errors in `Exec.zig`/`Dmabuf.zig` (fixed by Tasks 2 and 4).
  Run also: `LOCK ZIG build -Demit-lib-vt -j4` → PASS (lib-vt unaffected).
- [ ] **Step 7: Commit**
  ```bash
  git add src/build/SharedDeps.zig src/build/GhosttyResources.zig src/main.zig src/main_c.zig
  git commit -m "build(windows): gate posix headers, glad, tail and memset quirk for windows-msvc"
  ```

### Task 2: Known core source fixes (Exec, main_ghostty)

**Files:**
- Modify: `src/termio/Exec.zig:125-128, 196-230, 537-552, 1778-1829, 1993-2010`
- Modify: `src/main_ghostty.zig:77-95`
- Modify: `src/os/windows.zig` (add `WriteFile` extern if absent)

**Interfaces:**
- Consumes: Task 1 (translate-c passes).
- Produces: Exec's Windows quit pipe is closed with `CloseHandle` and signalled with `WriteFile`; `execCommand` Windows branch appends correctly; `main_ghostty.zig` `.none` branch uses the 0.17 stdout API used elsewhere in the repo (grep for `std.Io.File.stdout()` usage and copy that idiom).

- [ ] **Step 1: Fix `Exec.zig:2003,2007`** to `try args.append(alloc, try alloc.dupeSentinel(u8, argv0, 0));` (and the `tok` line).
- [ ] **Step 2: Replace `posix.system.close/write` on `read_thread_pipe`/`quit`** in the Windows paths (`threadEnter` errdefers, `threadExit`, `ThreadData.deinit`, `threadMainWindows`) with `windows.exp.kernel32.CloseHandle` / `WriteFile`, under `if (comptime builtin.target.os.tag == .windows)`; POSIX code unchanged.
- [ ] **Step 3: Fix `main_ghostty.zig:78`** (`std.io.getStdOut` no longer exists).
- [ ] **Step 4: Verify**
  Run: `LOCK ZIG build -Dapp-runtime=none -j4 2>&1 | grep -E "Exec.zig|main_ghostty.zig" ; echo rc=$?`
  Expected: `rc=1` (no errors in these files). Other errors may remain (Task 4/5).
- [ ] **Step 5: Commit**
  ```bash
  git add src/termio/Exec.zig src/main_ghostty.zig src/os/windows.zig
  git commit -m "fix(windows): exec argv append arity, handle-typed quit pipe, stdout API"
  ```

### Task 3: `pkg/win32` package — COM core, DXGI, D3D11, d3dcompiler spike

**Files:**
- Create: `pkg/win32/build.zig`, `pkg/win32/build.zig.zon`, `pkg/win32/main.zig`
- Create: `pkg/win32/foundation.zig`, `pkg/win32/com.zig`, `pkg/win32/dxgi.zig`, `pkg/win32/d3d11.zig`, `pkg/win32/d3dcompiler.zig`
- Test: `pkg/win32/test_spike.zig` (referenced from `main.zig` test block)

**Interfaces:**
- Consumes: nothing (standalone package; not yet wired into Ghostty — Task 6 wires it).
- Produces (module `win32`, `main.zig` re-exports `foundation`, `com`, `dxgi`, `d3d11`, `d3dcompiler`; Task 6 adds more):
  - `foundation`: `HRESULT = i32`, `BOOL = i32`, `GUID`, `LUID`, `RECT`, `POINT`, `HWND = *opaque {}`, `HINSTANCE`, `HMODULE`, `WPARAM`, `LPARAM`, `LRESULT`, `Error = error{ DeviceLost, OutOfMemory, WouldBlock, InvalidArgument, ComFailure }`, `fn check(hr: HRESULT) Error!void` (mapping in SPEC §4, logs hex for `ComFailure`), `fn succeeded(hr: HRESULT) bool`.
  - `com`: `IUnknown` (`VTable{ QueryInterface, AddRef, Release }`), `fn release(obj: anytype) void` (calls `obj.vtable.base…Release` through the IUnknown prefix), `fn queryInterface(obj: anytype, comptime T: type) Error!*T` (uses `T.iid`).
  - Every interface: `extern struct { vtable: *const VTable }`, `pub const iid: GUID`, `VTable` lists ALL slots in SDK header order, inherited first (via a `base` field of the parent VTable); slots not typed yet are `*const anyopaque` but keep the header name. Consumers later replace a placeholder with its typed signature (append-only otherwise).
  - `d3d11`: full slot lists for `ID3D11Device` (40 own), `ID3D11DeviceChild` (4), `ID3D11DeviceContext` (108 own), `ID3D11Resource`, `ID3D11Buffer`, `ID3D11Texture2D`, `ID3D11View`, `ID3D11RenderTargetView`, `ID3D11ShaderResourceView`, `ID3D11SamplerState`, `ID3D11BlendState`, `ID3D11RasterizerState`, `ID3D11InputLayout`, `ID3D11VertexShader`, `ID3D11PixelShader`; typed now: `D3D11CreateDevice`, `CreateTexture2D`, `CreateRenderTargetView`, `ClearRenderTargetView`, `CopyResource`, `Map`, `Unmap`, `GetImmediateContext`. Helper `fn createDevice(driver: DriverType, flags: CreateDeviceFlags) Error!CreatedDevice` with `CreatedDevice = struct { device: *ID3D11Device, context: *ID3D11DeviceContext, level: FeatureLevel }`; `DriverType = enum(i32){ hardware = 1, warp = 5 }`; min level `11_0`.
  - `dxgi`: slot lists for `IDXGIObject`, `IDXGIFactory`, `IDXGIFactory1`, `IDXGIFactory2`, `IDXGIAdapter`, `IDXGIAdapter1`, `IDXGIDevice`, `IDXGIDeviceSubObject`, `IDXGISwapChain`, `IDXGISwapChain1`, `IDXGISwapChain2`; `Format` enum (at least `B8G8R8A8_UNORM`, `_UNORM_SRGB`, `_TYPELESS`, `R8_UNORM`, `R8G8B8A8_UNORM_SRGB`, `R32_UINT`, `UNKNOWN`); `fn createFactory(debug: bool) Error!*IDXGIFactory2` (`CreateDXGIFactory2`).
  - `d3dcompiler`: `ID3DBlob` (IUnknown + `GetBufferPointer`, `GetBufferSize`), `ID3DInclude` (NOT IUnknown: vtable `{ Open, Close }`), `Compiler = struct { fn load() error{CompilerUnavailable}!Compiler; fn compile(self: Compiler, alloc: std.mem.Allocator, opts: CompileOptions) CompileError![]u8 }`, `CompileOptions = struct { source: []const u8, source_name: [:0]const u8, entry: [:0]const u8, target: [:0]const u8, flags: u32 = 0, include: ?*ID3DInclude = null }`, `CompileError = error{ CompileFailed, OutOfMemory }` (error text logged via `std.log.scoped(.d3dcompiler)`). Loads `d3dcompiler_47.dll` with `LoadLibraryExW(..., LOAD_LIBRARY_SEARCH_SYSTEM32)` and `GetProcAddress("D3DCompile")`.

- [ ] **Step 1: Write the failing tests** in `pkg/win32/test_spike.zig`:
  ```zig
  test "win32 com: vtable slot counts" {
      const n = struct { fn slots(comptime V: type) usize { return @sizeOf(V) / @sizeOf(usize); } }.slots;
      try std.testing.expectEqual(@as(usize, 43), n(d3d11.ID3D11Device.VTable));
      try std.testing.expectEqual(@as(usize, 115), n(d3d11.ID3D11DeviceContext.VTable));
      try std.testing.expectEqual(@as(usize, 25), n(dxgi.IDXGIFactory2.VTable));
      try std.testing.expectEqual(@as(usize, 29), n(dxgi.IDXGISwapChain1.VTable));
  }
  test "win32 spike: WARP clear and readback" {
      // createDevice(.warp, .{ .bgra_support = true }); 4x4 B8G8R8A8_UNORM RT; clear to {1,0,0,1};
      // CopyResource into a STAGING CPU_READ texture; Map(READ)
      try std.testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, pixel0); // BGRA of opaque red
  }
  test "win32 spike: D3DCompile trivial pixel shader" {
      // compile "float4 main() : SV_Target { return 1; }" with target ps_5_0
      try std.testing.expect(bytecode.len > 0);
  }
  test "win32 spike: D3DCompile reports errors" {
      try std.testing.expectError(error.CompileFailed, compiler.compile(alloc, .{ .source = "nonsense", … }));
  }
  ```
  The expected slot counts (43/115/25/29) are derived from `C:\Program Files (x86)\Windows Kits\10\Include\10.0.26100.0\um\d3d11.h` and `shared\dxgi1_2.h`; recount from the header if a test disagrees and fix the vtable, not the number, unless the header proves the number wrong.
- [ ] **Step 2: Run to see them fail** — `LOCK ZIG build test -j4 --build-file pkg/win32/build.zig` → compile errors (types missing).
- [ ] **Step 3: Implement** the files above. `build.zig`: `b.addModule("win32", .{ .root_source_file = b.path("main.zig") })`, a `test` step over `main.zig` linking system libs `d3d11`, `dxgi`. `build.zig.zon`: `.name = .win32`, `.paths = .{""}`, no deps; get the `fingerprint` value from the error Zig prints on first build.
- [ ] **Step 4: Run tests** — same command → PASS (4 tests).
- [ ] **Step 5: Commit**
  ```bash
  git add pkg/win32
  git commit -m "feat(win32): hand-written COM/DXGI/D3D11/d3dcompiler bindings with WARP spike tests"
  ```

### Task 4: Renderer backend enum + D3D11 contract stub

**Files:**
- Modify: `src/renderer/backend.zig` (add `d3d11`, Windows default)
- Modify: `src/renderer.zig:16-42` (export `D3D11`, switch arm)
- Modify: `src/build/Config.zig:208-212` (reject `-Drenderer=opengl|metal` for Windows targets with a clear error)
- Modify: `src/apprt/gtk/class/surface.zig:1778` (add `.d3d11 => unreachable` arm; GTK never selects it)
- Create: `src/renderer/D3D11.zig`, `src/renderer/d3d11/{Device,Target,Frame,RenderPass,Pipeline,buffer,Texture,Sampler,shaders}.zig` (compile-only stubs)

**Interfaces:**
- Consumes: Task 1.
- Produces (later tasks replace the stub bodies, never the names):
  - `renderer.D3D11` with every decl of SPEC §6.1 / [renderer §1.3]: `Device`, `GraphicsAPI`, `Target`, `Frame`, `RenderPass`, `Pipeline`, `Buffer(T)`, `Sampler`, `Texture`, `shaders`, `swap_chain_count = 3`, `custom_shader_target: shadertoy.Target = .glsl`, `custom_shader_y_is_down = true`, `ImageTextureFormat = enum { gray, rgba, bgra }`, methods `init(alloc, device: *const Device, opts: rendererpkg.Options) !D3D11`, `deinit`, `threadEnter(surface: *apprt.Surface) !void`, `threadExit`, `surfaceSize() !struct{ width: u32, height: u32 }`, `setViewport(w: u32, h: u32) void`, `drawFrameStart`, `drawFrameEnd`, `initShaders`, `initTarget(w: usize, h: usize) !Target`, `initAtlasTexture(*const font.Atlas) Texture.Error!Texture`, `fgBufferOptions`, `bgBufferOptions`, `uniformBufferOptions`, `imageBufferOptions`, `bgImageBufferOptions`, `textureOptions`, `samplerOptions`, `imageTextureOptions(format, srgb)`, `beginFrame(renderer, target) !Frame` — signatures mirror `src/renderer/OpenGL.zig`.
  - `pub const PresentTarget = struct { hwnd: *anyopaque, size: *const std.atomic.Value(u64) };` and `pub fn packSize(w: u32, h: u32) u64` / `pub fn unpackSize(v: u64) struct { width: u32, height: u32 }` (w in the high 32 bits).
  - `d3d11/Device.zig`: `pub const Options = struct { driver: Driver = .hardware, debug_layer: bool = false }`, `pub const Driver = enum { hardware, warp }`, `pub fn init(alloc: Allocator, options: Options) !*Device`, `pub fn deinit(self: *Device, alloc: Allocator) void`.
  - Stub behaviour: `init` succeeds; `surfaceSize` returns `{0, 0}` (generic then never draws — lets Task 18 run a real core surface without rendering); everything else returns `error.Unimplemented` or is a no-op. CPU struct types in `d3d11/shaders.zig` are copied verbatim from `opengl/shaders.zig` (`Uniforms`, `CellText`, `CellBg`, `Image`, `BgImage`) so `generic.zig` type-checks.

- [ ] **Step 1: Write the failing test** in `src/renderer/D3D11.zig`:
  ```zig
  test "d3d11 stub: size packing roundtrip" {
      const s = unpackSize(packSize(3840, 2160));
      try std.testing.expectEqual(@as(u32, 3840), s.width);
      try std.testing.expectEqual(@as(u32, 2160), s.height);
  }
  ```
- [ ] **Step 2: Implement** enum, switch arms, stubs. `Backend.default` returns `.d3d11` when `target.os.tag == .windows`.
- [ ] **Step 3: Verify the backend is selected and the stub type-checks**
  Run: `LOCK ZIG build -Dapp-runtime=none -j4 2>&1 | grep -E "renderer/(D3D11|d3d11/)|Dmabuf|egl" ; echo rc=$?`
  Expected: `rc=1` (no errors from the stub, OpenGL/Dmabuf/EGL no longer analysed). The test itself runs in Task 5 once the test exe links.
  Run: `LOCK ZIG build -Demit-lib-vt -j4` → PASS.
- [ ] **Step 4: Commit**
  ```bash
  git add src/renderer/backend.zig src/renderer.zig src/build/Config.zig src/apprt/gtk/class/surface.zig src/renderer/D3D11.zig src/renderer/d3d11
  git commit -m "feat(renderer): d3d11 backend enum, windows default and contract stub"
  ```

### Task 5: Core compiles and links on Windows (peel the rest)

**Files:** not knowable up front; expected touch points (all Windows-gated): `src/termio/*.zig`, `src/os/*.zig`, `src/cli/*.zig`, `src/terminal/kitty/*.zig`, `src/crash/*.zig`, `src/inspector/*.zig`, `src/build/SharedDeps.zig` (not the Windows lib-link block owned by Task 6), `pkg/dcimgui/build.zig` (disable `backend-opengl3` on Windows if it fails). This task runs ALONE in its wave; nothing else edits core files meanwhile.

**Interfaces:**
- Consumes: Tasks 1, 2, 4, 6.
- Produces: `ZIG build test -Dtest-filter=<x> -Dapp-runtime=none` compiles, links and runs `ghostty-test` on Windows; `ZIG build -Dapp-runtime=none` installs `ghostty-internal.dll`.

- [ ] **Step 1: Loop** — run `LOCK ZIG build test -j4 -Dapp-runtime=none -Dtest-filter="d3d11 stub" 2>&1 | tail -60`; fix the first error class by platform gating (`if (comptime builtin.target.os.tag == .windows)` / `switch` arm), never by deleting POSIX behaviour; repeat. Record every fix (file:line, one line why) in the commit message body.
- [ ] **Step 2: Size guard** — if the diff passes ~400 changed lines before the test exe links, commit what you have (each commit must still pass `-Demit-lib-vt`), and report the remaining error list as NEEDS_CONTEXT with the log path.
- [ ] **Step 3: Verify**
  Run: `LOCK ZIG build test -j4 -Dapp-runtime=none -Dtest-filter="d3d11 stub"` → PASS (1 test).
  Run: `LOCK ZIG build test -j4 -Dapp-runtime=none -Dtest-filter="config"` → PASS or a list of Windows-failing tests (report them; do not fix behaviour here).
  Run: `LOCK ZIG build test -j4 -Dapp-runtime=none -Dtest-filter="Exec"` and `-Dtest-filter="xev"` → record results (libxev IOCP smoke, SPEC R2).
- [ ] **Step 4: Commit** (one or more)
  ```bash
  git commit -am "fix(windows): make ghostty core and test exe compile and link on windows-msvc"
  ```

### Task 6: `pkg/win32` Win32 bindings + wiring into Ghostty

**Files:**
- Create: `pkg/win32/user32.zig`, `pkg/win32/kernel32.zig`, `pkg/win32/imm32.zig`, `pkg/win32/dwmapi.zig`, `pkg/win32/gdi32.zig`, `pkg/win32/ole32.zig`
- Modify: `pkg/win32/main.zig` (re-exports), `pkg/win32/build.zig` (link libs for tests), `pkg/win32/test_spike.zig` → add `test_user32.zig`
- Modify: `build.zig.zon` (add `.win32 = .{ .path = "./pkg/win32", .lazy = true }`)
- Modify: `src/build/SharedDeps.zig` Windows section (~:970): when `target.os.tag == .windows`, `addImport("win32", dep.module("win32"))` and `linkSystemLibrary` for `user32 gdi32 dwmapi imm32 ole32 d3d11 dxgi`.

**Interfaces:**
- Consumes: Task 3.
- Produces (exact names; all `callconv(.winapi)`; W-variants only):
  - `user32`: `RegisterClassExW, UnregisterClassW, CreateWindowExW, DestroyWindow, DefWindowProcW, GetMessageW, PeekMessageW, TranslateMessage, DispatchMessageW, PostMessageW, PostQuitMessage, ShowWindow, UpdateWindow, SetWindowPos, MoveWindow, GetClientRect, GetWindowRect, AdjustWindowRectExForDpi, GetDpiForWindow, SetWindowLongPtrW, GetWindowLongPtrW, SetWindowTextW, LoadCursorW, LoadIconW, SetCursor, ShowCursor, SetCapture, ReleaseCapture, TrackMouseEvent, GetCursorPos, ScreenToClient, ClientToScreen, GetKeyState, GetKeyboardState, ToUnicodeEx, VkKeyScanExW, MapVirtualKeyExW, GetKeyboardLayout, LoadKeyboardLayoutW, UnloadKeyboardLayout, ActivateKeyboardLayout, GetMessageTime, SetTimer, KillTimer, OpenClipboard, CloseClipboard, EmptyClipboard, GetClipboardData, SetClipboardData, IsClipboardFormatAvailable, SetFocus, GetFocus, SetForegroundWindow, MessageBeep, MessageBoxW, GetDoubleClickTime, SendInput, InvalidateRect, ValidateRect, BeginPaint, EndPaint, GetSystemMetricsForDpi`; types `HKL, WNDCLASSEXW, MSG, CREATESTRUCTW, MINMAXINFO, TRACKMOUSEEVENT, INPUT, KEYBDINPUT, MOUSEINPUT, PAINTSTRUCT, WNDPROC`; constants for every `WM_*`, `WS_*`, `WS_EX_*`, `SW_*`, `SWP_*`, `VK_*`, `IDC_*`, `GWLP_USERDATA`, `HWND_MESSAGE`, `CF_UNICODETEXT`, `MB_*`, `PM_REMOVE`, `TME_LEAVE`, `KF_*`, `WHEEL_DELTA` used by Tasks 11, 18, 20–25.
  - `kernel32` (GUI side only): `GetModuleHandleW, GlobalAlloc, GlobalLock, GlobalUnlock, GlobalFree, GlobalSize, OutputDebugStringW, LoadLibraryExW, GetProcAddress, FreeLibrary, GetLastError, Sleep`.
  - `imm32`: `ImmGetContext, ImmReleaseContext, ImmGetCompositionStringW, ImmSetCompositionWindow, ImmSetCandidateWindow, ImmNotifyIME`; `COMPOSITIONFORM, CANDIDATEFORM`, `GCS_COMPSTR, GCS_RESULTSTR, GCS_CURSORPOS, CFS_POINT, CFS_CANDIDATEPOS, CFS_EXCLUDE, ISC_SHOWUICOMPOSITIONWINDOW, NI_COMPOSITIONSTR, CPS_CANCEL`.
  - `dwmapi`: `DwmSetWindowAttribute`, `DWMWA_USE_IMMERSIVE_DARK_MODE = 20`.
  - `gdi32`: `GetStockObject` (only for the class background brush), `ole32`: `OleInitialize, OleUninitialize`.

- [ ] **Step 1: Failing test** `test "win32 user32: message-only window roundtrip"` — register class `GhosttyWin32Test`, `CreateWindowExW(.., HWND_MESSAGE, ..)`, `PostMessageW(hwnd, WM_APP + 7, 42, 0)`, `PeekMessageW(PM_REMOVE)` returns it with `wParam == 42`; destroy + unregister.
- [ ] **Step 2: Run** `LOCK ZIG build test -j4 --build-file pkg/win32/build.zig` → FAIL (missing decls).
- [ ] **Step 3: Implement** bindings + wiring.
- [ ] **Step 4: Verify** — package tests PASS (5 tests); `LOCK ZIG build -Demit-lib-vt -j4` PASS; `LOCK ZIG build -Dapp-runtime=none -j4 2>&1 | grep -E "win32" ; echo rc=$?` → `rc=1`.
- [ ] **Step 5: Commit**
  ```bash
  git add pkg/win32 build.zig.zon src/build/SharedDeps.zig
  git commit -m "feat(win32): user32/imm32/dwmapi bindings and wire win32 module into windows builds"
  ```

### Task 7: Config path = `%USERPROFILE%\.config\ghostty\config.ghostty`

**Files:**
- Modify: `src/os/homedir.zig` (`homeWindows`, `expandHome` Windows arm)
- Modify: `src/os/xdg.zig:20-104` (`InternalOptions.windows_env: ?[]const u8`; `config()` passes `null`)
- Modify: `src/config/file_load.zig:12-58` (subdir per component; Windows: no legacy)
- Modify: `src/config/Config.zig:4245-4262` (`loadDefaultFiles`: no legacy on Windows) — shared file with Tasks 8/11, distinct hunk
- Modify: `src/config/edit.zig:123-140` (`configPathCandidates`: no legacy on Windows)
- Test: in the same files (`test "windows …"` blocks, guarded `if (builtin.target.os.tag != .windows) return error.SkipZigTest;`)

**Interfaces:**
- Consumes: Task 5.
- Produces: `homedir.home` on Windows returns `USERPROFILE` → `HOMEDRIVE ++ HOMEPATH` → `null`; `homedir.expandHome` expands `~/x` and `~\x`; `xdg.config` on Windows = `XDG_CONFIG_HOME` (non-empty) else `<home>\.config`; `xdg.cache/state` unchanged (LOCALAPPDATA); `file_load.defaultXdgPath` = `<config base>\ghostty\config.ghostty`.

- [ ] **Step 1: Failing tests**
  ```zig
  test "windows xdg: config base is USERPROFILE\\.config, LOCALAPPDATA ignored" {
      // env: USERPROFILE=C:\Users\Анна Ли, LOCALAPPDATA=C:\Users\Анна Ли\AppData\Local
      try testing.expectEqualStrings("C:\\Users\\Анна Ли\\.config\\ghostty", try xdg.config(io, alloc, &env, .{ .subdir = "ghostty" }));
  }
  test "windows xdg: XDG_CONFIG_HOME replaces the base" { // XDG_CONFIG_HOME=D:\cfg → "D:\\cfg\\ghostty" }
  test "windows xdg: cache still uses LOCALAPPDATA" { // → "C:\\…\\AppData\\Local\\ghostty" }
  test "windows homedir: USERPROFILE wins over HOMEDRIVE+HOMEPATH" {}
  test "windows homedir: expandHome expands ~/ and ~\\" { // "~/a" and "~\\a" → "C:\\Users\\x\\a" }
  test "windows config: legacy config file is ignored" {
      // temp dir as XDG_CONFIG_HOME containing only ghostty\config → preferred path ends with "\\ghostty\\config.ghostty"
  }
  ```
  To make the last test independent of the process env, add `pub fn preferredXdgPathEnv(io: std.Io, alloc: Allocator, environ_map: *const std.process.Environ.Map) ![]const u8` and make `preferredXdgPath` call it with `global.environMap()`.
- [ ] **Step 2: Run** `LOCK ZIG build test -j4 -Dapp-runtime=none -Dtest-filter="windows xdg"` (and `"windows homedir"`, `"windows config"`) → FAIL.
- [ ] **Step 3: Implement.** Path joins use components (`"ghostty"`, `"config.ghostty"`), not `"ghostty/config.ghostty"`.
- [ ] **Step 4: Run** the three filters → PASS; also `-Dtest-filter="config"` shows no new failures vs Task 5's record.
- [ ] **Step 5: Commit** `git commit -m "feat(windows): single config path under %USERPROFILE%\\.config, no legacy fallback"`

### Task 8: Default shell resolver + Windows TERM default

**Files:**
- Create: `src/os/windows_shell.zig`
- Modify: `src/os/main.zig` (export `windows_shell`)
- Modify: `src/os/windows.zig` (add `GetFileAttributesW`, `RegGetValueW` (advapi32), `HKEY_LOCAL_MACHINE`, `HKEY_CURRENT_USER`, `RRF_RT_REG_SZ`)
- Modify: `src/config/Config.zig:3935` (`term` default: `"xterm-256color"` on Windows) and `:4843-4858` (`.windows` arm) — shared file, distinct hunks
- Modify: `src/build/SharedDeps.zig` Windows lib list: add `advapi32`

**Interfaces:**
- Consumes: Task 5.
- Produces:
  ```zig
  pub const Kind = enum { git_bash, pwsh, cmd };
  pub const Resolved = struct { kind: Kind, argv: []const [:0]const u8 }; // allocated with the given allocator
  pub const Probe = struct {
      ctx: ?*anyopaque = null,
      exists: *const fn (ctx: ?*anyopaque, path: []const u8) bool,
      regGitInstallPath: *const fn (ctx: ?*anyopaque, alloc: Allocator) ?[]const u8,
  };
  pub fn resolve(alloc: Allocator, env: *const std.process.Environ.Map, probe: Probe) !Resolved;
  pub fn systemProbe() Probe; // GetFileAttributesW + RegGetValueW
  ```
  Candidate order and argv exactly as SPEC §8.3. `Config.finalize` Windows arm: when `command == null`, `resolve(alloc, &env, systemProbe())` → `self.command = .{ .direct = argv }`; if kind is `git_bash` and `self.env` has no `CHERE_INVOKING`, put `CHERE_INVOKING=1`; log `default shell kind={s} path={s}`.

- [ ] **Step 1: Failing tests** (fake probe with a set of existing paths)
  ```zig
  test "windows shell: Git Bash preferred, argv has --login -i" {
      // exists: "C:\\Program Files\\Git\\bin\\bash.exe", "C:\\Program Files\\PowerShell\\7\\pwsh.exe"
      // env ProgramFiles=C:\Program Files
      try testing.expectEqual(Kind.git_bash, r.kind);
      try testing.expectEqualStrings("C:\\Program Files\\Git\\bin\\bash.exe", r.argv[0]);
      try testing.expectEqualStrings("--login", r.argv[1]);
      try testing.expectEqualStrings("-i", r.argv[2]);
  }
  test "windows shell: System32 bash.exe (WSL) is never chosen" { // only C:\Windows\System32\bash.exe exists, PATH has System32 → kind != .git_bash }
  test "windows shell: registry InstallPath used" { // regGitInstallPath returns "D:\\Tools\\Git" and D:\Tools\Git\bin\bash.exe exists }
  test "windows shell: git.exe on PATH locates bash" { // PATH contains "E:\\g\\cmd", E:\g\cmd\git.exe and E:\g\bin\bash.exe exist }
  test "windows shell: pwsh when no Git Bash" { // argv == {"…\\pwsh.exe", "-NoLogo"} }
  test "windows shell: cmd from COMSPEC as last resort" { // COMSPEC=C:\Windows\system32\cmd.exe → argv == {COMSPEC} }
  test "windows shell: non-ASCII ProgramFiles path survives" { // "C:\\Программы\\Git\\bin\\bash.exe" }
  ```
- [ ] **Step 2: Run** `LOCK ZIG build test -j4 -Dapp-runtime=none -Dtest-filter="windows shell"` → FAIL.
- [ ] **Step 3: Implement** resolver, Config wiring, TERM default (Windows only; other OS unchanged).
- [ ] **Step 4: Run** → PASS (7 tests); `-Dtest-filter="config"` no new failures.
- [ ] **Step 5: Commit** `git commit -m "feat(windows): default shell Git Bash -> pwsh -> cmd and TERM=xterm-256color default"`

### Task 9: Event-driven pty read loop and drain on exit

**Files:**
- Modify: `src/pty.zig:326-491` (`WindowsPty`: out pipe as overlapped named pipe `\\.\pipe\LOCAL\ghostty-pty-out-<pid>-<n>`, `closeConsoleAsync`)
- Modify: `src/termio/Exec.zig:120-230, 274-330, 537-552, 1778-1829` (event quit, 64 KiB buffer, exit drain)
- Modify: `src/os/windows.zig` (`CreateEventW`, `SetEvent`, `WaitForMultipleObjects`, `WaitForSingleObject`, `GetOverlappedResult`, `ERROR_IO_PENDING`, `ERROR_BROKEN_PIPE`, `WAIT_OBJECT_0`)

**Interfaces:**
- Consumes: Task 5 (and Task 2's handle fixes, which this replaces).
- Produces:
  ```zig
  // src/termio/Exec.zig (Windows only)
  pub fn readLoopWindows(handle: windows.HANDLE, quit_event: windows.HANDLE, ctx: anytype, comptime onData: fn (@TypeOf(ctx), []const u8) void) void;
  // src/pty.zig WindowsPty
  pub fn closeConsoleAsync(self: *Pty) void; // idempotent (atomic flag); deinit skips ClosePseudoConsole if already done
  ```
  `ReadThread.threadMainWindows` becomes a thin call of `readLoopWindows` with `io.processOutput`. `threadExit` = `SetEvent(quit_event)` + join. On child exit (Windows arm of `processExit`) → `pty.closeConsoleAsync()`, then wait ≤ 500 ms on a `drained_event` set by the read loop at EOF, then continue the existing exit path. Buffer: 64 KiB.

- [ ] **Step 1: Failing tests** (in `Exec.zig`, Windows-only)
  ```zig
  test "windows exec: read loop returns promptly when quit is signalled while blocked" {
      // anonymous overlapped named-pipe pair; start readLoopWindows on a thread; SetEvent(quit) after 50 ms
      // join must complete within 1000 ms (measure with std.time.Timer)
  }
  test "windows exec: read loop delivers all bytes before EOF" {
      // write 1 MiB in 4 KiB chunks then close the write end; collected bytes == 1 MiB, last byte matches
  }
  test "windows exec: output written right before child exit is not lost" {
      // WindowsPty.open + Command spawning `cmd.exe /c echo ghostty-drain-token`; on process exit call closeConsoleAsync;
      // collected output contains "ghostty-drain-token" within 2 s
  }
  ```
- [ ] **Step 2: Run** `LOCK ZIG build test -j4 -Dapp-runtime=none -Dtest-filter="windows exec"` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS (3 tests). Also `-Dtest-filter="pty"` and `-Dtest-filter="Command"` no new failures.
- [ ] **Step 5: Commit** `git commit -m "fix(windows): event-driven ConPTY read loop, 64KiB reads, drain output on child exit"`

### Task 10: Logging sinks and console attach for CLI actions

**Files:**
- Modify: `src/global.zig:395-402` (`Logging`: add `file: bool = windows`, `debugger: bool = windows and Debug`)
- Modify: `src/main_ghostty.zig:24-60, 118-200` (call console attach before running a CLI action on Windows; add file + debugger sinks to `logFn`)
- Create: `src/os/windows_console.zig` (imported directly from `main_ghostty.zig`, not via `os/main.zig`)
- Create: `src/os/windows_log.zig` (file sink)
- Modify: `src/os/windows.zig` (`AttachConsole`, `ATTACH_PARENT_PROCESS`, `SetStdHandle`, `GetStdHandle`, `CreateFileW` if absent, `OutputDebugStringW`, `MoveFileExW`)

**Interfaces:**
- Consumes: Task 5.
- Produces:
  ```zig
  // windows_console.zig
  pub fn ensureConsoleForCli() void; // std handle valid → nothing; else AttachConsole(ATTACH_PARENT_PROCESS) + reopen CONOUT$/CONIN$ + SetStdHandle
  // windows_log.zig
  pub fn init(alloc: Allocator, environ_map: *const std.process.Environ.Map) void; // opens %LOCALAPPDATA%\ghostty\logs\ghostty.log, rotates > 5 MiB to ghostty.1.log
  pub fn write(line: []const u8) void; // mutex-guarded, appends "\n"-terminated line
  pub fn formatLine(buf: []u8, ts_ms: i64, level: std.log.Level, scope: []const u8, msg: []const u8) []const u8; // "<ISO8601 UTC> <level>(<scope>): <msg>"
  ```
- [ ] **Step 1: Failing tests** (`windows_log.zig`)
  ```zig
  test "windows log: line format" { // ts 0 → starts with "1970-01-01T00:00:00.000Z info(config): hello" }
  test "windows log: rotation over 5 MiB" { // temp LOCALAPPDATA with 6 MiB ghostty.log → after init: ghostty.1.log exists, ghostty.log size 0 }
  ```
- [ ] **Step 2: Run** `LOCK ZIG build test -j4 -Dapp-runtime=none -Dtest-filter="windows log"` → FAIL.
- [ ] **Step 3: Implement**; the stderr sink must skip silently when `GetStdHandle(STD_ERROR_HANDLE)` is null/invalid.
- [ ] **Step 4: Run** → PASS. Manual check once Task 11 is merged (same wave; otherwise the lead runs it after the wave): `./zig-out/bin/ghostty.exe +version` from Git Bash and from `cmd /c` prints the version (record output in the report).
- [ ] **Step 5: Commit** `git commit -m "feat(windows): file and debugger log sinks, console attach for CLI actions"`

### Task 11: Win32 apprt skeleton (runtime enum, App loop, empty window)

**Files:**
- Modify: `src/apprt/runtime.zig` (`win32` member; default on Windows), `src/apprt.zig:43-50` (`.win32 => win32`)
- Modify (one-line `.win32` arms, or `else => void` for `getGObjectType`): `src/apprt/action.zig:733`, `src/apprt/structs.zig:47,53,216`, `src/apprt/surface.zig:174`, `src/config/Config.zig:4892,9346,10068` (shared file, distinct hunks), `src/datastruct/split_tree.zig:1327`, `src/font/face.zig:61`, `src/input/Binding.zig:995`, `src/build/SharedDeps.zig:691` (`.win32 => {}`)
- Modify: `build.zig` (exe emitted for `.win32`; `run` step works for win32 — `build.zig:297` assert)
- Create: `src/apprt/win32.zig`, `src/apprt/win32/App.zig`, `src/apprt/win32/Window.zig`, `src/apprt/win32/Surface.zig` (stub: `pub const Surface = struct {}` members filled by Task 18), `src/apprt/win32/util.zig` (UTF-8↔UTF-16 helpers, `hwndUserData(T, hwnd)`)
- Test: `src/apprt/win32/util.zig`, `src/apprt/win32/App.zig`

**Interfaces:**
- Consumes: Tasks 5, 6.
- Produces:
  ```zig
  // src/apprt/win32.zig
  pub const App = @import("win32/App.zig");
  pub const Surface = @import("win32/Surface.zig");
  pub const resourcesDir = internal_os.resourcesDir;
  // App.zig
  pub const WM_GHOSTTY_WAKEUP = WM_APP + 1; pub const WM_GHOSTTY_CLIPBOARD_READ = WM_APP + 2; pub const WM_GHOSTTY_QUIT_TIMER = WM_APP + 3;
  core_app: *CoreApp, config: Config, msg_hwnd: HWND, hinstance: HINSTANCE, windows: std.ArrayList(*Window),
  wakeup_pending: std.atomic.Value(bool),
  pub fn init(self: *App, core_app: *CoreApp, opts: struct {}) !void;
  pub fn run(self: *App) !void;
  pub fn terminate(self: *App) void;
  pub fn wakeup(self: *App) void;              // thread-safe, coalesced PostMessageW
  pub fn performAction(self: *App, target: apprt.Target, comptime action: apprt.Action.Key, value: apprt.Action.Value(action)) !bool;
  pub fn performIpc(alloc, target, comptime action, value) !bool; // false
  pub fn startQuitTimer(self: *App) void;
  // Window.zig
  pub fn create(app: *App) !*Window;            // class "GhosttyWindow", WS_OVERLAPPEDWINDOW, DWMWA_USE_IMMERSIVE_DARK_MODE per system theme
  pub fn destroy(self: *Window) void;
  hwnd: HWND, app: *App, surface: ?*Surface,   // M1: at most one surface
  // util.zig
  pub fn utf16z(alloc: Allocator, s: []const u8) ![:0]u16;
  pub fn utf8(alloc: Allocator, s: []const u16) ![]u8;
  pub fn fromUserData(comptime T: type, hwnd: HWND) ?*T;
  ```
  `performAction` handles `quit`, `close_window`, `quit_timer` (start/stop via `SetTimer` on `msg_hwnd`), `set_title` (top-level `SetWindowTextW`), `render` (return true), `initial_size`/`size_limit`/`cell_size` (stored; applied by Task 18); every other key → `log.debug("unimplemented action={s}")`, return false. Closing the last window posts `WM_QUIT`.

- [ ] **Step 1: Failing tests**
  ```zig
  test "win32 util: utf16 roundtrip with non-BMP" { // "a😀Ж" → utf16z → utf8 equals input }
  test "win32 app: wakeup coalesces" { // call wakeup() 1000x from 4 threads on a test App with a message-only hwnd; count WM_GHOSTTY_WAKEUP in queue ≤ 4 and ≥ 1 }
  ```
- [ ] **Step 2: Run** `LOCK ZIG build test -j4 -Dtest-filter="win32 "` → FAIL (now with default `app_runtime = win32`).
- [ ] **Step 3: Implement.** `App.init`: `OleInitialize(null)`, register `GhosttyApp`/`GhosttyWindow` classes, message-only window, `CoreConfig.load`, `core_app.updateConfig`, `Window.create`, `ShowWindow`.
- [ ] **Step 4: Verify** — tests PASS; `LOCK ZIG build -j4` installs `zig-out/bin/ghostty.exe`; launch it (`./zig-out/bin/ghostty.exe &` then after 3 s `powershell -NoProfile -Command "(Get-Process ghostty).MainWindowTitle"` prints a title), close it with `powershell -Command "(Get-Process ghostty).CloseMainWindow()"` → process exits within 3 s (`Get-Process ghostty` errors).
- [ ] **Step 5: Commit** `git commit -m "feat(win32): apprt runtime skeleton with message loop, wakeup and top-level window"`

### Task 12: D3D11 Device, Buffer, Texture, Sampler

**Files:**
- Modify (replace stubs): `src/renderer/d3d11/Device.zig`, `src/renderer/d3d11/buffer.zig`, `src/renderer/d3d11/Texture.zig`, `src/renderer/d3d11/Sampler.zig`
- Modify: `pkg/win32/d3d11.zig` (type the placeholder slots used: `CreateBuffer`, `CreateShaderResourceView`, `CreateSamplerState`, `UpdateSubresource`, plus desc structs `BUFFER_DESC`, `TEXTURE2D_DESC`, `SUBRESOURCE_DATA`, `SHADER_RESOURCE_VIEW_DESC`, `SAMPLER_DESC`, `BOX`, `MAPPED_SUBRESOURCE`)

**Interfaces:**
- Consumes: Tasks 3, 4, 5, 6.
- Produces:
  ```zig
  // Device.zig
  device: *d3d11.ID3D11Device, context: *d3d11.ID3D11DeviceContext, factory: *dxgi.IDXGIFactory2,
  level: d3d11.FeatureLevel, max_texture_size: u32 (16384 for FL11),
  pub fn init(alloc: Allocator, options: Options) !*Device;   // env GHOSTTY_D3D11_DRIVER=warp|hardware and GHOSTTY_D3D11_DEBUG=1 override options
  pub fn deinit(self: *Device, alloc: Allocator) void;
  pub fn lockContext(self: *Device) void;  pub fn unlockContext(self: *Device) void;   // std.Io.Mutex, debug-asserts owner thread
  // buffer.zig
  pub const Role = enum { vertex, structured, constant };
  pub const Options = struct { device: *Device, role: Role };
  pub fn Buffer(comptime T: type) type // fields: buffer: *d3d11.ID3D11Buffer, srv: ?*d3d11.ID3D11ShaderResourceView, len: usize, opts: Options
  //   init(opts, len) !Self, initFill(opts, []const T) !Self, deinit(), sync([]const T) !void, syncFromArrayLists([]const std.ArrayList(T)) !usize
  //   DYNAMIC + CPU_WRITE; Map(WRITE_DISCARD) under the caller-held context lock; grows ×2 (recreates SRV for .structured)
  // Texture.zig
  pub const Options = struct { device: *Device, format: dxgi.Format, srv_format: dxgi.Format, render_target: bool = false, rtv_format: dxgi.Format = .UNKNOWN };
  // fields: texture, srv, rtv: ?, width: usize, height: usize; init(opts, w, h, ?[]const u8) Error!Texture; deinit(); replaceRegion(x, y, w, h, data) Error!void (UpdateSubresource with BOX); Error = error{ DeviceLost, OutOfMemory, InvalidArgument, ComFailure }
  // Sampler.zig
  pub const Options = struct { device: *Device, filter: enum { linear, nearest } = .linear }; // clamp addressing; fields: sampler; init/deinit
  ```
- [ ] **Step 1: Failing tests** (WARP, `Options{ .driver = .warp }`)
  ```zig
  test "d3d11 device: WARP device has feature level >= 11_0" {}
  test "d3d11 buffer: sync grows and preserves contents" {
      // Buffer(u32) .structured len 4; sync 10 items → len >= 10, srv non-null; copy to staging, read back == input
  }
  test "d3d11 buffer: constant role rounds size to 16" { // Buffer(extern struct{a:f32,b:f32,c:f32}) byteWidth % 16 == 0 }
  test "d3d11 texture: replaceRegion writes the box" { // R8_UNORM 8x8, replaceRegion(2,2,2,2,{1,2,3,4}); readback rows 2..3 cols 2..3 == data, (0,0) == 0 }
  ```
- [ ] **Step 2: Run** `LOCK ZIG build test -j4 -Dtest-filter="d3d11 "` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS (5 tests incl. the stub test).
- [ ] **Step 5: Commit** `git commit -m "feat(d3d11): device with context lock, dynamic buffers, textures and samplers"`

### Task 13: HLSL text-path shaders + compile cache

**Files:**
- Create: `src/renderer/shaders/hlsl/common.hlsli`, `full_screen.hlsl`, `bg_color.hlsl`, `cell_bg.hlsl`, `cell_text.hlsl`
- Create: `src/renderer/d3d11/hlsl.zig`

**Interfaces:**
- Consumes: Tasks 3, 4, 5.
- Produces:
  ```zig
  pub const Stage = enum { vertex, pixel };
  pub const Entry = enum { full_screen_vs, bg_color_ps, cell_bg_ps, cell_text_vs, cell_text_ps }; // Task 16 appends image_vs, image_ps, bg_image_vs, bg_image_ps
  pub fn bytecode(entry: Entry) ![]const u8;     // compiled once per process (mutex + per-entry slot), vs_5_0/ps_5_0
  pub fn warmup() void;                          // compiles every Entry, logs failures; Device.warmup calls it
  ```
  HLSL is a 1:1 port of the matching functions in `src/renderer/shaders/shaders.metal` (same uniform struct order, same bool bits, Y-down). Registers fixed in `common.hlsli`: `cbuffer Globals : register(b1)`, `StructuredBuffer<uint> bg_cells : register(t1)` (VS+PS), atlases `Texture2D<float> atlas_grayscale : register(t0)`, `Texture2D<float4> atlas_color : register(t1)` in the `cell_text` PS (keep Metal's texture indices), images `t0` + `SamplerState s0`. Includes are resolved by an `ID3DInclude` that serves the `@embedFile`d `common.hlsli`.
- [ ] **Step 1: Failing tests**
  ```zig
  test "d3d11 hlsl: every text-path entry compiles" { inline for (std.meta.tags(Entry)) |e| try testing.expect((try bytecode(e)).len > 0); }
  test "d3d11 hlsl: bytecode is cached" { try testing.expectEqual((try bytecode(.cell_text_vs)).ptr, (try bytecode(.cell_text_vs)).ptr); }
  ```
- [ ] **Step 2: Run** `LOCK ZIG build test -j4 -Dtest-filter="d3d11 hlsl"` → FAIL.
- [ ] **Step 3: Implement.** Debug builds compile with `DEBUG | SKIP_OPTIMIZATION`, release with `OPTIMIZATION_LEVEL3`.
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `git commit -m "feat(d3d11): HLSL port of bg_color/cell_bg/cell_text shaders with runtime compile cache"`

### Task 14: Windows font discovery index and style ranking

**Files:**
- Modify: `src/font/discovery.zig:965-1210` (`Windows` backend)

**Interfaces:**
- Consumes: Task 5.
- Produces: `Windows.discover` honours `desc.bold`, `desc.italic`, `desc.style`, `desc.monospace`; results ranked (exact style match > weight distance > italic match); a process-wide index (`family`, `style`, `weight` from OS/2 `usWeightClass`, `italic` from `fsSelection`/`macStyle`, path, face index) built once on first query under a mutex; `discoverFallback` tries the fixed list (SPEC §9) before a full codepoint scan; `.otc` files included.
- [ ] **Step 1: Failing tests** (real `C:\Windows\Fonts`; skip if the Consolas files are absent)
  ```zig
  test "windows font: Consolas bold resolves to consolab.ttf" {}
  test "windows font: Consolas bold italic resolves to consolaz.ttf" {}
  test "windows font: index is built once" { // two discover() calls → index_build_count == 1 }
  test "windows font: emoji fallback prefers Segoe UI Emoji" { // codepoint U+1F600 → path basename "seguiemj.ttf" (case-insensitive) }
  ```
- [ ] **Step 2: Run** `LOCK ZIG build test -j4 -Dtest-filter="windows font"` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS; `-Dtest-filter="font"` no new failures vs Task 5's record.
- [ ] **Step 5: Commit** `git commit -m "feat(windows): indexed font discovery with style ranking and native fallback list"`

### Task 15: Job object for the child tree + Windows command tokenizer

**Files:**
- Modify: `src/Command.zig:305-440` (`CREATE_SUSPENDED`, assign to a job with `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`, `ResumeThread`; `job` handle on `Command`)
- Modify: `src/termio/Exec.zig:1150-1180` (Windows kill = `TerminateJobObject`), `:1993-2010` (`.shell` tokenization)
- Modify: `src/os/windows.zig` (`CreateJobObjectW`, `SetInformationJobObject`, `AssignProcessToJobObject`, `TerminateJobObject`, `QueryInformationJobObject`, `ResumeThread`, `JOBOBJECT_EXTENDED_LIMIT_INFORMATION`, `JOBOBJECT_BASIC_PROCESS_ID_LIST`, `CREATE_SUSPENDED`)

**Interfaces:**
- Consumes: Task 9.
- Produces: `pub fn tokenizeWindows(alloc: Allocator, s: []const u8) ![][:0]const u8` in `Exec.zig` (MS C runtime rules: whitespace splits, `"…"` groups, `\"` literal quote, `2n` backslashes before `"` → `n`); `Command.job: ?windows.HANDLE` closed in `Command` cleanup; closing it kills the whole tree.
- [ ] **Step 1: Failing tests**
  ```zig
  test "windows tokenize: quoted path with spaces" {
      // "\"C:\\Program Files\\Git\\bin\\bash.exe\" --login -i" → { "C:\\Program Files\\Git\\bin\\bash.exe", "--login", "-i" }
  }
  test "windows tokenize: escaped quote and non-ASCII" { // "say \"\\\"hi\\\"\" Ж" → { "say", "\"hi\"", "Ж" } }
  test "windows command: closing the job kills grandchildren" {
      // spawn `cmd.exe /c ping -n 60 127.0.0.1 >nul` via Command (no pty); wait 500 ms; QueryInformationJobObject lists ≥ 2 pids;
      // open each pid (SYNCHRONIZE); close the job handle; every process handle is signalled within 2000 ms
  }
  ```
- [ ] **Step 2: Run** `LOCK ZIG build test -j4 -Dtest-filter="windows tokenize"` and `-Dtest-filter="windows command"` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS; `-Dtest-filter="windows exec"` still PASS.
- [ ] **Step 5: Commit** `git commit -m "feat(windows): kill-on-close job object for child trees and MS-rules command tokenizer"`

### Task 16: HLSL image shaders

**Files:**
- Create: `src/renderer/shaders/hlsl/image.hlsl`, `src/renderer/shaders/hlsl/bg_image.hlsl`
- Modify: `src/renderer/d3d11/hlsl.zig` (append `image_vs`, `image_ps`, `bg_image_vs`, `bg_image_ps` entries)

**Interfaces:** Consumes Task 13's `Entry`/`bytecode`. Produces the four new `Entry` tags.
- [ ] **Step 1:** The existing test "d3d11 hlsl: every text-path entry compiles" now iterates all tags (rename to "d3d11 hlsl: every entry compiles") → FAIL until the files exist.
- [ ] **Step 2: Implement** as 1:1 ports of the Metal `image_*` and `bg_image_*` functions (bg repeat via `fmod` in shader, linear-clamp sampler `s0`, texture `t0`).
- [ ] **Step 3: Run** `LOCK ZIG build test -j4 -Dtest-filter="d3d11 hlsl"` → PASS.
- [ ] **Step 4: Commit** `git commit -m "feat(d3d11): HLSL port of image and bg_image shaders"`

### Task 17: Pipeline, RenderPass, Target

**Files:**
- Modify (replace stubs): `src/renderer/d3d11/Pipeline.zig`, `src/renderer/d3d11/RenderPass.zig`, `src/renderer/d3d11/Target.zig`
- Modify: `pkg/win32/d3d11.zig` (type: `CreateInputLayout`, `CreateVertexShader`, `CreatePixelShader`, `CreateBlendState`, `CreateRasterizerState`, `IASetInputLayout`, `IASetVertexBuffers`, `IASetPrimitiveTopology`, `VSSetShader`, `PSSetShader`, `VSSetConstantBuffers`, `PSSetConstantBuffers`, `VSSetShaderResources`, `PSSetShaderResources`, `PSSetSamplers`, `OMSetRenderTargets`, `OMSetBlendState`, `RSSetViewports`, `RSSetState`, `DrawInstanced`, `Draw`; descs `INPUT_ELEMENT_DESC`, `BLEND_DESC`, `RASTERIZER_DESC`, `VIEWPORT`)

**Interfaces:**
- Consumes: Tasks 12, 13.
- Produces:
  ```zig
  // Pipeline.zig
  pub const Options = struct { device: *Device, vertex: hlsl.Entry, pixel: hlsl.Entry, step_fn: enum { constant, per_vertex, per_instance } = .per_vertex, blending_enabled: bool = true };
  pub fn init(comptime VertexAttributes: ?type, opts: Options) !Pipeline; // input layout reflected at comptime from the extern struct (field order = semantic index, TEXCOORD<i>); integer fields → *_UINT/_SINT formats per SPEC §6.2
  pub fn deinit(self: *const Pipeline) void; stride: usize
  // Target.zig
  pub const Options = struct { device: *Device, width: usize, height: usize, srgb: bool };
  // fields: texture (B8G8R8A8_TYPELESS), rtv (UNORM_SRGB if srgb else UNORM), srv, width, height; init(Options) !Target; deinit()
  pub fn readPixelsAlloc(self: *const Target, alloc: Allocator) ![]u8; // BGRA8 rows via staging copy; for tests and debugging
  // RenderPass.zig — same shape as opengl/RenderPass.zig: Options{ attachments: []const Attachment }, begin(opts), step(Step), complete()
  ```
- [ ] **Step 1: Failing tests** (WARP)
  ```zig
  test "d3d11 pipeline: input layout reflects CellText" { // 7 elements; formats R32G32_UINT,R32G32_UINT,R16G16_SINT,R16G16_UINT,R8G8B8A8_UINT,R8_UINT,R8_UINT; stride 32 }
  test "d3d11 renderpass: clear colour reaches the target" { // Target 16x16 unorm; pass with clear {0,0.5,1,1}, no steps → pixel (0,0) BGRA == {255,128,0,255} ±1 }
  test "d3d11 renderpass: bg_color pipeline fills the target" {
      // Uniforms.bg_color = {10,20,30,255}; step(bg_color, tri x3) → every sampled pixel == BGRA {30,20,10,255}
  }
  ```
- [ ] **Step 2: Run** `LOCK ZIG build test -j4 -Dtest-filter="d3d11 "` → FAIL.
- [ ] **Step 3: Implement.** Clear colour applies on the first step only (as GL). Primitive types `.triangle` → `TRIANGLELIST`, `.triangle_strip` → `TRIANGLESTRIP`.
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `git commit -m "feat(d3d11): pipelines with reflected input layouts, render passes and offscreen targets"`

### Task 18: Apprt Surface hosting a core surface

**Files:**
- Modify: `src/apprt/win32/Surface.zig` (full core contract), `src/apprt/win32/Window.zig` (host one Surface child, WM_SIZE/WM_DPICHANGED/WM_GETMINMAXINFO/WM_CLOSE), `src/apprt/win32/App.zig` (actions `initial_size`, `size_limit`, `cell_size`, `mouse_shape` stored, `show_child_exited` → false)
- Create: `src/apprt/win32/dpi.zig`, `src/apprt/win32/keyboard.zig`, `src/apprt/win32/mouse.zig`, `src/apprt/win32/ime.zig`, `src/apprt/win32/clipboard.zig`, `src/apprt/win32/dialogs.zig` (dispatch stubs returning `null`; filled by Tasks 20–23)
- Create: `test/windows/launch.ps1`, `test/windows/README.md`, `test/windows/configs/cmd.ghostty`

**Interfaces:**
- Consumes: Tasks 4 (`PresentTarget`, `packSize`), 11.
- Produces:
  ```zig
  // Surface.zig — heap allocated, stable address; GWLP_USERDATA → *Surface
  hwnd: HWND, window: *Window, core_surface: CoreSurface, size: std.atomic.Value(u64), content_scale: apprt.ContentScale, title: ?[:0]const u8,
  pub fn create(window: *Window) !*Surface;          // CreateWindowExW("GhosttySurface", WS_CHILD|WS_VISIBLE|WS_CLIPSIBLINGS, …), then core_surface.init(...)
  pub fn destroy(self: *Surface) void;
  pub fn core(self: *Surface) *CoreSurface;  pub fn rtApp(self: *const Surface) *App;
  pub fn close(self: *Surface, process_active: bool) void;  // MessageBoxW confirm when needed (Task 23 swaps to dialogs.zig)
  pub fn getTitle(self: *Surface) ?[:0]const u8;  pub fn getContentScale(self: *const Surface) !apprt.ContentScale;
  pub fn getSize(self: *const Surface) !apprt.SurfaceSize;  pub fn getCursorPos(self: *const Surface) !apprt.CursorPos;
  pub fn supportsClipboard(self: *const Surface, clipboard_type: apprt.Clipboard) bool;      // forwards to clipboard.zig
  pub fn clipboardRequest(self: *Surface, clipboard_type: apprt.Clipboard, state: apprt.ClipboardRequest) !apprt.ClipboardReadResult; // forwards
  pub fn setClipboard(self: *Surface, clipboard_type: apprt.Clipboard, contents: []const apprt.ClipboardContent, confirm: bool) !void; // forwards
  pub fn defaultTermioEnv(self: *Surface) !std.process.Environ.Map;   // global.environMap() copy
  pub fn renderDeviceOptions(self: *Surface) !renderer.Device.Options;
  pub fn d3d11PresentTarget(self: *Surface) ?renderer.D3D11.PresentTarget; // { hwnd, &self.size }
  pub fn sizeMessage(wparam: WPARAM, lparam: LPARAM) struct { packed_size: u64, visible: bool }; // pure; WndProc uses it
  // per-concern dispatch from the surface WndProc, each returns ?LRESULT (null = DefWindowProc)
  keyboard.handle(self: *Surface, msg: u32, wparam: WPARAM, lparam: LPARAM) ?LRESULT  // same signature for mouse.handle, ime.handle, clipboard.handle
  // dpi.zig
  pub fn contentScale(dpi: u32) apprt.ContentScale;   // dpi / 96.0 for x and y
  ```
  WndProc order: `WM_SIZE` (pack size → `core.sizeCallback` → `core.draw()`; `SIZE_MINIMIZED` → `occlusionCallback(false)`, restore → `true`), `WM_SETFOCUS`/`WM_KILLFOCUS` → `focusCallback`, `WM_DPICHANGED` (on Window) → `SetWindowPos(suggested)` + `contentScaleCallback`, `WM_ERASEBKGND` → 1, `WM_PAINT` → `ValidateRect`, then ime → keyboard → mouse → clipboard dispatch.
- [ ] **Step 1: Failing tests**
  ```zig
  test "win32 dpi: content scale" { // 96 → 1.0, 144 → 1.5, 120 → 1.25 }
  test "win32 surface: WM_SIZE decoding" {
      // sizeMessage(SIZE_MINIMIZED, 0) → .{ .packed_size = 0, .visible = false }
      // sizeMessage(SIZE_RESTORED, MAKELPARAM(800, 600)) → .{ .packed_size = packSize(800, 600), .visible = true }
      // sizeMessage(SIZE_MAXIMIZED, MAKELPARAM(1, 1)) → .{ .packed_size = packSize(1, 1), .visible = true }
  }
  ```
- [ ] **Step 2: Run** `LOCK ZIG build test -j4 -Dtest-filter="win32 "` → FAIL.
- [ ] **Step 3: Implement**; `test/windows/launch.ps1 -Config <path> [-Driver warp]` creates a temp `XDG_CONFIG_HOME\ghostty\config.ghostty` from `-Config`, starts `zig-out\bin\ghostty.exe`, waits for `MainWindowHandle ≠ 0` (≤ 10 s) and prints `pid=<n> hwnd=<0x…>`.
- [ ] **Step 4: Verify** — tests PASS. `LOCK ZIG build -j4`; `powershell -NoProfile -File test/windows/launch.ps1 -Config test/windows/configs/cmd.ghostty` (create that config: `command = direct:cmd.exe`) then `powershell -NoProfile -Command "Get-CimInstance Win32_Process -Filter 'ParentProcessId=<pid>' | Select Name"` lists `cmd.exe` (renderer is still the stub: the window is blank, which is expected). Default config (no `command`) lists `bash.exe` when Git for Windows is installed.
- [ ] **Step 5: Commit** `git commit -m "feat(win32): host a core surface in a child HWND with size, DPI, focus and occlusion"`

### Task 19: D3D11 API, shaders.zig and Frame (headless)

**Files:**
- Modify (replace stubs): `src/renderer/D3D11.zig`, `src/renderer/d3d11/shaders.zig`, `src/renderer/d3d11/Frame.zig`

**Interfaces:**
- Consumes: Tasks 12, 16, 17.
- Produces: every contract decl real (SPEC §6.1). `shaders.Shaders.init(alloc, device, custom_shaders)` builds `bg_color`, `cell_bg`, `cell_text`, `image`, `bg_image`; non-empty `custom_shaders` → `log.warn("custom shaders are not supported by the D3D11 renderer yet")` and `post_pipelines = &.{}`. `drawFrameStart/End` = `device.lockContext/unlockContext` (Task 24 inserts the waitable wait before the lock). `surfaceSize`: headless → `setViewport` value. `Frame.complete(sync)`: `context.Flush()` (Task 24 adds present), then `renderer.frameCompleted(health)`; `error.DeviceLost` → `.unhealthy`. `Device.warmup()` (static) calls `hlsl.warmup()`. `@offsetOf` tests for `Uniforms` against the HLSL cbuffer offsets (hard-coded table from `common.hlsli`).
- [ ] **Step 1: Failing tests** (WARP, headless)
  ```zig
  test "d3d11 shaders: Uniforms offsets match the HLSL cbuffer" {
      // common.hlsli declares every Globals member with an explicit packoffset; shaders.zig mirrors that table as
      // `hlsl_uniform_offsets` (name → byte offset); for each field: @offsetOf(Uniforms, name) == table value
  }
  test "d3d11 frame: cell_bg draws a per-cell colour" {
      // 2x1 grid, cell 8x16 px, bg_cells = {0xFF0000FF (red), 0xFF00FF00 (green)} packed RGBA; frame with bg_color + cell_bg
      // target pixel (4,8) == red, (12,8) == green (BGRA order in readback)
  }
  test "d3d11 frame: cell_text samples the grayscale atlas" {
      // 8x8 atlas filled 255 in a 4x4 glyph at (0,0); one CellText instance at grid (0,0), color white, glyph_size 4x4
      // pixel inside the glyph is white (≥ 250), pixel outside equals the background
  }
  ```
- [ ] **Step 2: Run** `LOCK ZIG build test -j4 -Dtest-filter="d3d11 "` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `git commit -m "feat(d3d11): complete headless GraphicsAPI with shader set and frames"`

### Task 20: Keyboard translation

**Files:**
- Create: `src/apprt/win32/key.zig` (pure functions)
- Modify: `src/apprt/win32/keyboard.zig` (WndProc glue)
- Create: `test/windows/send-input.ps1`

**Interfaces:**
- Consumes: Task 18 (`keyboard.handle` signature, `Surface`).
- Produces:
  ```zig
  // key.zig
  pub const KeyState = [256]u8;                                   // GetKeyboardState layout
  pub fn physicalKey(lparam: LPARAM, vk: u16) input.Key;           // scancode | 0xE000 if extended; Pause/NumLock by VK; 0xE02A/0xE036 → .unidentified
  pub fn isFakeShift(lparam: LPARAM) bool;
  pub fn mods(state: *const KeyState) input.Mods;                  // sides + caps/num lock
  pub fn layoutHasAltGr(hkl: HKL) bool;                            // VkKeyScanExW scan over printable BMP chars, cached by caller
  pub fn unshiftedCodepoint(hkl: HKL, vk: u16, scancode: u16) u21; // ToUnicodeEx(empty state, flags 0x4); 0 if none
  pub fn applyAltGr(m: input.Mods, has_altgr_layout: bool, ralt_down: bool, produced_text: bool) struct { mods: input.Mods, consumed: input.Mods };
  pub fn stripControl(text: []const u8, buf: []u8) []const u8;     // drops C0 and DEL
  // keyboard.zig: drains WM_CHAR/WM_DEADCHAR with PeekMessageW(PM_REMOVE) after a key-down; swallows the synthetic AltGr LCtrl (same GetMessageTime as the following RAlt)
  ```
  `send-input.ps1 -Hwnd <h> (-Text <unicode string> | -Keys <chord list like "ctrl+c","altgr+q","enter">) [-Layout <KLID>]` uses `SendInput` (KEYEVENTF_UNICODE for -Text, VK+scancode for -Keys) after `SetForegroundWindow`.
- [ ] **Step 1: Failing tests** (layouts loaded with `LoadKeyboardLayoutW(KLF_NOTELLSHELL)`; skip a test if its layout cannot be loaded)
  ```zig
  test "win32 key: physical key from extended scancode" { // lparam scancode 0x48 + ext bit → .arrow_up; 0x48 no ext → .numpad_8 }
  test "win32 key: Pause vs NumLock" { // VK_PAUSE → .pause; VK_NUMLOCK → .num_lock }
  test "win32 key: US has no AltGr, DE has AltGr" { // layoutHasAltGr(00000409) == false, (00000407) == true }
  test "win32 key: AltGr consumes ctrl+alt only when text produced" {
      // applyAltGr({ctrl, alt}, true, true, true) → mods == {}, consumed == {ctrl, alt}
      // applyAltGr({ctrl, alt}, true, true, false) → mods == {ctrl, alt}
  }
  test "win32 key: unshifted codepoint on RU layout is Cyrillic, physical key stays .key_c" {
      // hkl 00000419, VK 'C' scancode 0x2E → unshiftedCodepoint == 'с' (U+0441); physicalKey(0x2E<<16, 'C') == .key_c
  }
  test "win32 key: stripControl removes C0" { // "\x01a\x7fb" → "ab" }
  ```
- [ ] **Step 2: Run** `LOCK ZIG build test -j4 -Dtest-filter="win32 key"` → FAIL.
- [ ] **Step 3: Implement.** Dead keys: `WM_DEADCHAR` → `KeyEvent{ composing = true, utf8 = dead char }` + `preeditCallback(dead char)`; the composed char clears preedit.
- [ ] **Step 4: Verify** — tests PASS; e2e oracle with `cmd.exe` config: `send-input.ps1 -Text "echo kb-ok-Жж> %TEMP%\gt-kb.txt"` + `-Keys enter` → file content `kb-ok-Жж` (UTF-8 or OEM — compare after `chcp 65001` in the config `command = direct:cmd.exe /k chcp 65001`).
- [ ] **Step 5: Commit** `git commit -m "feat(win32): keyboard translation with AltGr, dead keys and physical keys"`

### Task 21: Mouse, wheel and cursor shapes

**Files:**
- Modify: `src/apprt/win32/mouse.zig`, `src/apprt/win32/App.zig` (actions `mouse_shape`, `mouse_visibility` → surface state, return true)

**Interfaces:**
- Consumes: Task 18.
- Produces: `pub fn wheelOffset(delta: i16) struct { offset: f64, precision: bool }` (delta / 120.0, precision = delta % 120 ≠ 0); `pub fn cursorFor(shape: terminal.MouseShape) [*:0]const u16` (IDC_* map: text → IDC_IBEAM, pointer → IDC_HAND, default → IDC_ARROW, ew/ns/nesw/nwse resize, crosshair, wait/progress, not_allowed, grab/grabbing → IDC_HAND, others → IDC_ARROW); handler for `WM_MOUSEMOVE`, `WM_[LRM]BUTTON{DOWN,UP,DBLCLK}`, `WM_XBUTTON*`, `WM_MOUSEWHEEL`, `WM_MOUSEHWHEEL`, `WM_MOUSELEAVE`, `WM_SETCURSOR` (client area only), with `SetCapture` on first button down and `ReleaseCapture` when all are up.
- [ ] **Step 1: Failing tests**
  ```zig
  test "win32 mouse: wheel offsets" { // 120 → 1.0 not precise; -240 → -2.0; 30 → 0.25 precise }
  test "win32 mouse: cursor map" { // .text → IDC_IBEAM; .pointer → IDC_HAND; .default → IDC_ARROW }
  ```
- [ ] **Step 2: Run** `LOCK ZIG build test -j4 -Dtest-filter="win32 mouse"` → FAIL.
- [ ] **Step 3: Implement.** Wheel `WM_MOUSEWHEEL` arrives at the focused window: convert screen coords with `ScreenToClient` and route to the surface under the cursor.
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `git commit -m "feat(win32): mouse buttons, capture, wheel and cursor shapes"`

### Task 22: IME (IMM32)

**Files:**
- Modify: `src/apprt/win32/ime.zig`

**Interfaces:**
- Consumes: Task 18; core `Surface.imePoint()`, `preeditCallback`, `textCallback`.
- Produces: `pub fn handle(self: *Surface, msg, wparam, lparam) ?LRESULT` for `WM_IME_SETCONTEXT` (clear `ISC_SHOWUICOMPOSITIONWINDOW`), `WM_IME_STARTCOMPOSITION` (position), `WM_IME_COMPOSITION` (`GCS_COMPSTR` → preedit, `GCS_RESULTSTR` → text + clear preedit), `WM_IME_ENDCOMPOSITION` (preedit null); `pub fn candidatePos(ime_point: apprt.IMEPos, scale: f32) POINT` (physical px, below the cursor cell).
- [ ] **Step 1: Failing test** `test "win32 ime: candidate position below the cursor" { // IMEPos{x=10,y=20,width=8,height=16}, scale 1.5 → POINT{15, 54} }`
- [ ] **Step 2: Run** `LOCK ZIG build test -j4 -Dtest-filter="win32 ime"` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS. Manual check (record in report, Japanese MS-IME if installed): type `nihon` + Space + Enter in cmd → `日本` appears (visible from Task 24 on; before that verify via the echo oracle).
- [ ] **Step 5: Commit** `git commit -m "feat(win32): IMM32 composition and candidate window placement"`

### Task 23: Clipboard and confirmation dialogs

**Files:**
- Modify: `src/apprt/win32/clipboard.zig`, `src/apprt/win32/dialogs.zig`, `src/apprt/win32/Surface.zig` (`close` confirmation through `dialogs.zig`)

**Interfaces:**
- Consumes: Task 18.
- Produces:
  ```zig
  // clipboard.zig
  pub fn supports(t: apprt.Clipboard) bool;                                   // .standard only
  pub fn write(hwnd: HWND, text_utf8: []const u8) !void;                      // OpenClipboard retry 5× 10 ms, CF_UNICODETEXT
  pub fn read(alloc: Allocator, hwnd: HWND) !?[:0]u8;                         // null when no text
  pub fn request(self: *Surface, t: apprt.Clipboard, req: apprt.ClipboardRequest) !apprt.ClipboardReadResult; // .started + PostMessageW(WM_GHOSTTY_CLIPBOARD_READ)
  // dialogs.zig (MessageBoxW in M1; TaskDialog in M2)
  pub fn confirm(owner: HWND, title: []const u8, body: []const u8, ok_label: []const u8) bool;
  pub fn previewText(alloc: Allocator, text: []const u8, max_chars: usize) ![]u8; // first 512 chars, control chars shown as U+2400 symbols
  ```
  Unsafe/unauthorized paste → `confirm(…, "Paste")` → `completeClipboardRequest(confirmed = true)` or `denyClipboardRequest`. OSC 52 write with `confirm = true` → `confirm` first.
- [ ] **Step 1: Failing tests**
  ```zig
  test "win32 clipboard: write then read roundtrip with non-ASCII" { // "copy Ж😀\nline2" }
  test "win32 clipboard: write succeeds while another thread holds the clipboard briefly" {
      // thread A: OpenClipboard, sleep 30 ms, CloseClipboard; main: write → no error, read == written
  }
  test "win32 dialogs: preview escapes control characters and truncates" { // "a\x1b[31mb" → "a␛[31mb"; 600 chars → 512 + "…" }
  ```
- [ ] **Step 2: Run** `LOCK ZIG build test -j4 -Dtest-filter="win32 clipboard"` and `"win32 dialogs"` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `git commit -m "feat(win32): clipboard read/write with retries and paste/OSC52 confirmations"`

### Task 24: Swap chain, present, pacing, resize

**Files:**
- Create: `src/renderer/d3d11/SwapChain.zig`
- Modify: `src/renderer/D3D11.zig` (`threadEnter` creates the swap chain from `d3d11PresentTarget`, `surfaceSize` pulls `PresentTarget.size`, `drawFrameStart` waits on the waitable object ≤ 100 ms before locking), `src/renderer/d3d11/Frame.zig` (`complete`: resize-if-needed, `CopyResource`, `Present`), `src/renderer/d3d11/Device.zig` (tearing support query)
- Modify: `pkg/win32/dxgi.zig` (type `CreateSwapChainForHwnd`, `MakeWindowAssociation`, `CheckFeatureSupport` (IDXGIFactory5 via QI), `GetBuffer`, `ResizeBuffers`, `Present`, `SetMaximumFrameLatency`, `GetFrameLatencyWaitableObject`; `SWAP_CHAIN_DESC1`)
- Create: `test/windows/capture-window.ps1`, `test/windows/configs/colors.ghostty`

**Interfaces:**
- Consumes: Tasks 18, 19.
- Produces:
  ```zig
  pub const Mode = enum { hwnd }; // .composition added in M3
  pub fn init(device: *Device, hwnd: *anyopaque, width: u32, height: u32, mode: Mode) !SwapChain; // FLIP_DISCARD, 2 buffers, B8G8R8A8_UNORM, FRAME_LATENCY_WAITABLE_OBJECT (+ALLOW_TEARING if supported), MaxFrameLatency 1, MWA_NO_ALT_ENTER|MWA_NO_WINDOW_CHANGES
  pub fn deinit(self: *SwapChain) void;
  pub fn waitable(self: *const SwapChain) ?windows.HANDLE;
  pub fn presentTarget(self: *SwapChain, ctx: *d3d11.ID3D11DeviceContext, target: *const Target, vsync: bool) !void; // ResizeBuffers when size differs, CopyResource, Present(vsync?1:0, tearing&&!vsync ? ALLOW_TEARING : 0)
  ```
  `capture-window.ps1 -Hwnd <h> -Out <png> [-Probe "x,y"]` uses `PrintWindow(hwnd, hdc, PW_RENDERFULLCONTENT = 2)` into a `System.Drawing.Bitmap`, saves PNG, prints `probe x,y = #RRGGBB` per probe.
- [ ] **Step 1: Failing tests** (hidden test HWND, WARP)
  ```zig
  test "d3d11 swapchain: present a cleared target and read the backbuffer" {
      // hidden 64x32 window; Target cleared to {1,0,0,1}; presentTarget; GetBuffer(0) copy to staging → BGRA {0,0,255,255}
  }
  test "d3d11 swapchain: resize 1x1 and back" { // presentTarget with 1x1 target then 64x32 target → no error; backbuffer desc matches last size }
  test "d3d11: surfaceSize 0x0 skips drawing" { // PresentTarget.size = packSize(0,0) → surfaceSize == {0,0} }
  ```
- [ ] **Step 2: Run** `LOCK ZIG build test -j4 -Dtest-filter="d3d11 "` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Verify** — tests PASS. `LOCK ZIG build -j4`; `launch.ps1 -Config test/windows/configs/colors.ghostty` (`background = #102030`, `foreground = #e0e0e0`, `command = direct:cmd.exe /k echo GHOSTTY-M1`) → `capture-window.ps1 -Hwnd <h> -Out $TEMP/m1-first.png -Probe "5,5"` prints `#102030`; open the PNG and confirm the text `GHOSTTY-M1` is legible. Repeat with `-Driver warp`.
- [ ] **Step 5: Commit** `git commit -m "feat(d3d11): flip-model swap chain on the surface HWND with waitable pacing and resize"`

### Task 25: Integration fixes and end-to-end harness

**Files:**
- Modify: as needed in `src/apprt/win32/*`, `src/renderer/D3D11.zig`, `src/renderer/d3d11/*` (integration bugs only; no new features)
- Modify: `dist/windows/ghostty.manifest` (add `activeCodePage` UTF-8, `longPathAware`)
- Create: `test/windows/e2e-m1.ps1`, `test/windows/configs/{gitbash-de,unsafe-paste}.ghostty`

**Interfaces:**
- Consumes: everything above.
- Produces: `e2e-m1.ps1` runs these scenarios, each printing `PASS|FAIL <name>` and exiting non-zero on any FAIL:
  1. `startup`: default config → window ≤ 1.5 s after launch, child `bash.exe` (or `pwsh.exe`/`cmd.exe` when Git Bash is absent) exists, cwd `%USERPROFILE%` (oracle: `pwd -W > %TEMP%\gt-cwd.txt`).
  2. `config-path`: `XDG_CONFIG_HOME` unset, `%USERPROFILE%\.config\ghostty\config.ghostty` absent → after first launch it exists (template). (Uses a temporary `USERPROFILE` override for the process.)
  3. `typing-us`, `typing-de-altgr` (`-Layout 00000407`, `altgr+q` → `@`), `typing-de-deadkey` (`-Layout 00000407`, scancode 0x29 `^` then `e` → `ê`), `typing-ru` (`-Text "привет"`), `ctrl-c` (`ping -t 127.0.0.1` interrupted; oracle: next command runs).
  4. `paste-confirm`: clipboard `echo a\necho b` + `ctrl+shift+v` → confirmation dialog appears (find window by class `#32770`), press Enter → both commands run.
  5. `render`: probe background colour pixel = config `background`; screenshot saved.
  6. `resize`: `SetWindowPos` to 400×300 then 1200×800 → screenshots; no error lines in `ghostty.log`.
  7. `close-tree`: start `ping -n 60 127.0.0.1` in the shell, close the window → no `ping.exe`/`bash.exe` child of the old pid after 3 s.
  8. `close-while-streaming`: `cmd /c "for /L %i in (1,1,200000) do @echo %i"` then close → process exits ≤ 3 s.
- [ ] **Step 1:** Write `e2e-m1.ps1` + configs; run it → expect FAILs that reveal integration bugs.
- [ ] **Step 2:** Fix integration bugs (each fix with a unit test where the bug is in pure logic).
- [ ] **Step 3: Verify** — `LOCK ZIG build -j4` then `powershell -NoProfile -File test/windows/e2e-m1.ps1` → all PASS; attach the screenshot paths in the report.
- [ ] **Step 4: Commit** `git commit -m "test(windows): M1 end-to-end harness and integration fixes"`

### Task 26: RAM baseline and M1 acceptance

**Files:**
- Create: `test/windows/measure-ram.ps1`, `docs/windows/ram-baseline.csv`
- Modify: `test/windows/README.md` (how to run all harness scripts)
- Modify: `src/renderer/d3d11/Device.zig`, `src/apprt/win32/Surface.zig` (three `debug` log lines with `PrivateUsage`), `pkg/win32/kernel32.zig` (`K32GetProcessMemoryInfo`, `PROCESS_MEMORY_COUNTERS_EX`)

**Interfaces:**
- Consumes: Task 25.
- Produces: `measure-ram.ps1 [-Driver hardware|warp] [-Scenario one-surface|scrollback]` → appends `date,commit,adapter,scenario,private_mb,ws_mb` to `docs/windows/ram-baseline.csv` (method SPEC §14: ghostty.exe only, 10 s idle after the window is visible; `scrollback` runs `seq 1 200000` first; adapter name from the `d3d11 adapter=` log line).
- [ ] **Step 1:** Implement the script; run `-Scenario one-surface` (hardware and warp) and `-Scenario scrollback` (hardware).
- [ ] **Step 2: Verify the M1 gate** — `one-surface` hardware `private_mb ≤ 110`. If above, report DONE_WITH_CONCERNS with the numbers and a breakdown from log lines that print `PrivateUsage` (via `GetProcessMemoryInfo`) after `Device.init`, after the first surface init and after the first frame (add these three debug log lines in this task); do not tune in this task.
- [ ] **Step 3: Run the M1 exit checklist** (SPEC §17 M1 criteria 1–8): build, `-Dtest-filter` runs for `win32 `, `d3d11 `, `windows `, plus `terminal`, `config`, `input`, `font` (record pass/fail counts), e2e-m1.ps1, RAM row. Record results in the report.
- [ ] **Step 4: Commit**
  ```bash
  git add test/windows docs/windows/ram-baseline.csv src/renderer/d3d11/Device.zig src/apprt/win32/Surface.zig pkg/win32/kernel32.zig
  git commit -m "test(windows): RAM measurement script and M1 baseline"
  ```

---

## Self-review notes

- Spec coverage (M1 scope of SPEC §17): core compile (1, 2, 4, 5), bindings (3, 6), apprt (11, 18, 20–23), D3D11 (12, 13, 16, 17, 19, 24), ConPTY robustness (9, 15), config path (7), default shell + TERM (8), fonts (14), logging/console (10), DPI basics (18, 24), RAM (26), e2e (25). Out of M1 by design: tabs/splits/multi-window/Mica (M2), custom shaders/transparency/inspector/URL (M3), tmux (M4), OSC 7/pwsh integration (M5).
- Shared files across parallel tasks: `src/config/Config.zig` (Tasks 7, 8, 11 — distinct hunks), `src/os/windows.zig` (Tasks 2, 8, 9, 10, 15 — append-only externs; 9→15 sequential), `pkg/win32/d3d11.zig`/`dxgi.zig` (Tasks 12, 17, 24 — different waves), `src/build/SharedDeps.zig` (1, 6, 8, 11 — different regions/waves).
