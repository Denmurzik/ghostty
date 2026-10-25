# M1 — Core builds + single-window terminal: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `zig build -j4` on Windows produces `ghostty.exe` that opens one window running Git Bash (→ pwsh → cmd) over ConPTY, rendered by a Direct3D 11 backend, with keyboard (AltGr, dead keys), IMM32 IME, mouse, clipboard, the single config path, and file logging.

**Architecture:** Make the existing core compile on Windows with platform-gated fixes, add a hand-written Win32/COM binding package `pkg/win32`, a native Zig apprt `src/apprt/win32` (top-level HWND + one child HWND per surface, UI-thread message loop) and a `GraphicsAPI` backend `src/renderer/D3D11.zig` that presents from the render thread into a flip-model swap chain on the surface HWND (one shared device, context lock, `swap_chain_count = 1`, pacing wait in `beginFrame`).

**Tech Stack:** Zig 0.17.0, MSVC ABI, Win32 (user32/imm32/dwmapi), Direct3D 11 + DXGI 1.2+, runtime `d3dcompiler_47.dll`, HLSL SM 5.0, FreeType + HarfBuzz (existing), ConPTY (existing), libxev IOCP (existing), PowerShell harness scripts.

**Spec:** docs/windows/SPEC.md

Revision 2 (2026-10-25): revised after `docs/windows/plans/M1-preflight-review.md`; dispositions at the end. Tasks were renumbered.

## Global Constraints

Copied from `docs/windows/DECISIONS.md` (binding), SPEC.md and lead instructions. Every task implicitly includes these.

- Zig 0.17.0 at `C:\tools\zig-x86_64-windows-0.17.0\zig.exe` (always the full path). Shell: Git Bash.
- Target ABI = MSVC (R3). Archs: x86_64 + aarch64 (ARM64 only cross-built; cannot be tested locally). Minimum OS: Windows 11 22H2.
- App runtime: NEW native Zig apprt `src/apprt/win32` — pure Win32 + DWM. No WinUI, no GTK, no .NET (R5).
- Renderer: NEW Direct3D 11 GraphicsAPI backend `src/renderer/D3D11.zig` + `src/renderer/d3d11/`.
- Builtin renderer shaders are hand-written HLSL ported from `shaders.metal` (D3D11 is Y-down like Metal); runtime `D3DCompile` via `d3dcompiler_47.dll` (R4).
- Code is laid out so it could be upstreamed: Windows code isolated in its own dirs/arms; core changes minimal and platform-gated.
- Config: exactly ONE path on Windows: `%USERPROFILE%\.config\ghostty\config.ghostty` (if `XDG_CONFIG_HOME` is set it replaces the `%USERPROFILE%\.config` base). No legacy `config` filename fallback on Windows, no AppData, no `~/.ghostty`. Cache/state/logs live in `%LOCALAPPDATA%\ghostty\` (ruling, SPEC §18).
- Default shell order: Git Bash → pwsh (PowerShell 7) → cmd. Git Bash runs with `--login -i` and `CHERE_INVOKING=1`.
- Binary `ghostty.exe`, name "Ghostty — Unofficial Windows port", original Ghostty icon.
- Machine: 15.5 GB RAM, ~4–5 GB free. Builds/test suites strictly one at a time through the test-lock; zig builds with `-j4`. Bash timeout 600000 for every build/test command.
- **Worktree bootstrap:** every task worktree gets a directory junction to the shared package store before its first build: `cmd //c mklink /J "<worktree>\zig-pkg" "C:\D\den4ik\Ghostty\zig-pkg"` (verified: deps live in `C:\D\den4ik\Ghostty\zig-pkg`, ~259 MB, git-ignored; the global cache `%LOCALAPPDATA%\zig` is shared automatically). A worktree's first (cold) build runs with `run_in_background` and a hard deadline `timeout 1500 …` through the test-lock, not as a 600 s foreground call.
- Commits: no `Co-Authored-By` or similar trailers.
- Visual verification: from Task 22 on, pixel evidence comes from `GHOSTTY_D3D11_DUMP` frame dumps (primary) and `PrintWindow` screenshots (secondary).
- **GUI/e2e safety on the owner's machine:** every script that sends input, switches layouts or captures windows imports `test/windows/lib/Harness.psm1` (Task 21) and: (a) reports `SKIP` (never `FAIL`) when the session is locked, non-interactive, or has no usable foreground window, and records the SKIP in its output; (b) restores the original keyboard layout and unloads only layouts it added (`GetKeyboardLayoutList` diff); (c) never leaves Ghostty processes running (kills its own pids on exit). Unit tests that call `LoadKeyboardLayoutW` follow rule (b) too.
- Zig 0.17 std: `std.time.Timer` and `std.Thread.sleep` do not exist; use the Io idioms already in the touched file (`global.io()`, `std.Io.Timestamp.now(io, .awake)` deltas, `io.sleep(...)`).
- No `std.os.windows` beyond basic types; core (`src/os`, `src/termio`, `src/config`, `src/font`, `src/Command.zig`, `src/pty.zig`) uses `src/os/windows.zig` and never imports the `win32` module; apprt and renderer use `pkg/win32`. Nullable Win32 returns (`CreateWindowExW`, `GetClipboardData`, `GetFocus`, `LoadCursorW`, …) are declared `?HWND`/`?HANDLE`.

Command abbreviations used below (expand literally; shell state does not persist):
- `LOCK` = `bash "%USERPROFILE%/.claude/mods/teamlead/skills/teamlead/scripts/test-lock" --`
- `ZIG` = `"C:/tools/zig-x86_64-windows-0.17.0/zig.exe"`
- Run everything from the task's worktree root.
- Test name prefixes: `win32 ` (apprt + bindings), `d3d11 ` (renderer), `windows ` (core). **Renderer and core test commands always pass `-Dapp-runtime=none`**; only `win32 ` apprt filters use the default runtime (win32 after Task 10).

## Review Focus

1. User profile / install paths with spaces and non-ASCII characters (e.g. `C:\Users\Анна Ли`) must work for the config path, the resolved shell argv, quoted `command` strings and per-user fonts → tests in Task 7 (xdg/homedir), Task 13 (resolver argv), Task 19 (tokenizer), Task 12 (font in a non-ASCII dir).
2. Closing a surface while the child streams output, while grandchildren run, or by `exit` in the shell must not hang and must leave no orphan processes → Task 9 (quit while blocked, EOF after `closeConsoleAsync` ≤ 1 s), Task 19 (job kills grandchildren), Task 28 (`close-while-streaming`, `shell-exit`, `close-tree`).
3. Non-US keyboard input: AltGr characters (DE `AltGr+Q` = `@`), dead keys (DE `^` then `e` = `ê`), RU layout typing Cyrillic while `ctrl+shift+c` still matches the physical-C binding, `VK_PACKET` unicode input and surrogate pairs → Task 23 tests + Task 28 scenarios.
4. Clipboard held by another process, pastes with newlines/control bytes, surface closed while a paste request is pending → Task 26 tests.
5. Minimize (0×0 client), tiny sizes, DPI changes and live resize while streaming must not crash, hang or draw into a zero-sized target → Task 18 (`sizeMessage`), Task 27 (1×1 ↔ full resize, 0-size skip, pacing), Task 28 (`resize-while-streaming` watchdog).

## Waves (parallelism)

At most 3 tasks per wave; file sets inside a wave are strictly disjoint (including `src/os/windows.zig`, `pkg/win32/*.zig`, `src/apprt/win32/*.zig`, `src/config/Config.zig`, `src/build/SharedDeps.zig`, `src/termio/Exec.zig`).

| Wave | Tasks | Depends on |
|---|---|---|
| W1 | 1 build gating + GUI-entry proof + manifest · 2 pkg/win32 COM + D3D spike | — |
| W2 | 3 known core source fixes · 4 D3D11 contract stub · 5 pkg/win32 Win32 bindings + wiring | 1 (3, 4); 2 (5) |
| W3 | 6 core compile peel (alone) | 3, 4, 5 |
| W4 | 7 config path · 8 D3D11 device/resources · 9 pty read loop + drain | 6 |
| W5 | 10 apprt runtime + build wiring · 11 HLSL text shaders + slots · 12 font discovery | 6 (all); 2 (11) |
| W6 | 13 shell resolver + TERM · 14 apprt App/Window/wakeup/actions · 15 HLSL image shaders | 7 (13); 10 (14); 11 (15) |
| W7 | 16 logging/console/panic · 17 Pipeline/RenderPass/Target · 18 apprt Surface core contract | 13 (16, os/windows.zig order); 8+11 (17); 4+14 (18) |
| W8 | 19 job object + tokenizer · 20 d3d11 shaders.zig · 21 Window hosts Surface + harness | 9+16 (19); 15+17 (20); 18 (21) |
| W9 | 22 D3D11 API + Frame + dump · 23 keyboard · 24 mouse | 20 (22); 21 (23, 24) |
| W10 | 25 IME · 26 clipboard + dialogs · 27 swap chain + present + pacing | 21 (25, 26); 21+22 (27) |
| W11 | 28 e2e scenarios (alone) | all above |
| W12 | 29.n integration fixes (≤ 3 at a time, disjoint) | 28 |
| W13 | 30 RAM baseline + M1 acceptance (alone) | 29.* |

File ownership by wave for the hot files: `src/os/windows.zig` 3→9→12→13→16→19; `src/termio/Exec.zig` 3→9→19; `src/config/Config.zig` 7→10→13; `src/build/SharedDeps.zig` 1→5→(6)→10; `pkg/win32/d3d11.zig` 2→8→17; `pkg/win32/dxgi.zig` 2→27; `src/apprt/win32/App.zig` 10→14→21→30; `src/apprt/win32/Surface.zig` 10→18; `src/renderer/D3D11.zig` 4→22→27; `src/renderer/d3d11/Frame.zig` 4→22→27; `src/renderer/d3d11/Device.zig` 4→8→27→30.

---

### Task 1: Build-graph gating, GUI-entry proof, UTF-8 manifest

**Files:**
- Modify: `src/build/SharedDeps.zig:214-229` (posix_c include list), `src/build/SharedDeps.zig:656-663` (glad block)
- Modify: `src/build/GhosttyResources.zig:280-360` (template processing that runs `tail`)
- Modify: `src/main.zig:24-40`, `src/main_c.zig:46-52` (memset quirk import)
- Modify: `dist/windows/ghostty.manifest` (add `<activeCodePage>UTF-8</activeCodePage>` and `<longPathAware>true</longPathAware>`)
- Create: `test/windows/gui-entry/build.zig`, `test/windows/gui-entry/main.zig`

**Interfaces:**
- Produces: on Windows, module `posix_c` translates only `errno.h`, `signal.h`, `sys/types.h` (module name kept); glad compiled only when `config.renderer == .opengl`; no `tail` command for Windows targets; `quirks_memset` not referenced on `windows`+`msvc`; a proven recipe for a GUI-subsystem exe with `link_libc` + Zig `main`: `exe.subsystem = .windows; exe.entry = .{ .symbol_name = "mainCRTStartup" };` (Task 10 copies it into `GhosttyExe.zig`).

- [ ] **Step 1: Reproduce the baseline** — `LOCK ZIG build -Dapp-runtime=none -j4 2>&1 | tail -40` → FAIL `'pwd.h' not found`.
- [ ] **Step 2: GUI-entry proof** — `test/windows/gui-entry/main.zig`: `pub fn main() u8 { return 7; }`; `build.zig`: exe `gui-entry`, `link_libc = true`, `subsystem = .windows`, target native-msvc. First build WITHOUT `entry` and record the linker error (expected: unresolved `WinMain`); then add `exe.entry = .{ .symbol_name = "mainCRTStartup" }`.
  Run: `LOCK ZIG build -j4 --build-file test/windows/gui-entry/build.zig && ./test/windows/gui-entry/zig-out/bin/gui-entry.exe; echo rc=$?` → `rc=7`.
- [ ] **Step 3: posix_c, glad, tail, memset gating** as listed in Files (POSIX behaviour unchanged on other OSes).
- [ ] **Step 4: Manifest** — add the two elements inside the existing `asmv3:windowsSettings` (use the `http://schemas.microsoft.com/SMI/2019/WindowsSettings` namespace for `activeCodePage` and `.../2016/WindowsSettings` for `longPathAware`).
- [ ] **Step 5: Verify**
  `LOCK ZIG build -Dapp-runtime=none -j4 2>&1 | grep -E "pwd.h|unistd.h|'tail'|duplicate symbol: memset" ; echo rc=$?` → `rc=1` (remaining errors are in `Exec.zig`/`Dmabuf.zig`, Tasks 3/4).
  `LOCK ZIG build -Demit-lib-vt -j4` → PASS.
- [ ] **Step 6: Commit**
  ```bash
  git add src/build/SharedDeps.zig src/build/GhosttyResources.zig src/main.zig src/main_c.zig dist/windows/ghostty.manifest test/windows/gui-entry
  git commit -m "build(windows): gate posix headers, glad, tail and memset quirk; prove GUI entry point; UTF-8 manifest"
  ```

### Task 2: `pkg/win32` package — COM core, DXGI, D3D11, d3dcompiler spike

**Files:**
- Create: `pkg/win32/build.zig`, `pkg/win32/build.zig.zon`, `pkg/win32/main.zig`, `pkg/win32/foundation.zig`, `pkg/win32/com.zig`, `pkg/win32/dxgi.zig`, `pkg/win32/d3d11.zig`, `pkg/win32/d3dcompiler.zig`, `pkg/win32/test_spike.zig`

**Interfaces:**
- Produces (module `win32`; `main.zig` re-exports `foundation`, `com`, `dxgi`, `d3d11`, `d3dcompiler`):
  - `foundation`: `HRESULT = i32`, `BOOL = i32`, `GUID`, `LUID`, `RECT`, `POINT`, `HWND = *opaque {}`, `HANDLE`, `HINSTANCE`, `HMODULE`, `WPARAM`, `LPARAM`, `LRESULT`, `Error = error{ DeviceLost, OutOfMemory, WouldBlock, InvalidArgument, ComFailure }`, `fn check(hr: HRESULT) Error!void` (SPEC §4 mapping; logs hex for `ComFailure`), `fn succeeded(hr: HRESULT) bool`.
  - `com`: `IUnknown`, `fn release(obj: anytype) void`, `fn queryInterface(obj: anytype, comptime T: type) Error!*T` (uses `T.iid`).
  - Interface pattern (SPEC §4): `extern struct { vtable: *const VTable }`, `pub const iid: GUID`, `VTable` lists ALL slots in SDK header order with the parent VTable as a `base` field; untyped slots are `*const anyopaque` with the header name; consumers later replace a placeholder with its typed signature.
  - `d3d11`: full slot lists for `ID3D11Device` (40 own), `ID3D11DeviceChild` (4), `ID3D11DeviceContext` (108 own), `ID3D11Resource`, `ID3D11Buffer`, `ID3D11Texture2D`, `ID3D11View`, `ID3D11RenderTargetView`, `ID3D11ShaderResourceView`, `ID3D11SamplerState`, `ID3D11BlendState`, `ID3D11RasterizerState`, `ID3D11InputLayout`, `ID3D11VertexShader`, `ID3D11PixelShader`; typed now: `D3D11CreateDevice`, `CreateTexture2D`, `CreateRenderTargetView`, `ClearRenderTargetView`, `CopyResource`, `Map`, `Unmap`, `GetImmediateContext`; `fn createDevice(driver: DriverType, flags: CreateDeviceFlags) Error!CreatedDevice`, `CreatedDevice = struct { device: *ID3D11Device, context: *ID3D11DeviceContext, level: FeatureLevel }`, `DriverType = enum(i32) { hardware = 1, warp = 5 }`, min level `11_0`.
  - `dxgi`: slot lists for `IDXGIObject`, `IDXGIFactory`, `IDXGIFactory1`, `IDXGIFactory2`, `IDXGIAdapter`, `IDXGIAdapter1`, `IDXGIDevice`, `IDXGIDeviceSubObject`, `IDXGISwapChain`, `IDXGISwapChain1`, `IDXGISwapChain2`; `Format` enum (`B8G8R8A8_UNORM`, `_UNORM_SRGB`, `_TYPELESS`, `R8_UNORM`, `R8G8B8A8_UNORM_SRGB`, `R32_UINT`, `UNKNOWN`, …); `fn createFactory(debug: bool) Error!*IDXGIFactory2`.
  - `d3dcompiler`: `ID3DBlob`, `ID3DInclude` (NOT IUnknown: `{ Open, Close }`), `Compiler = struct { fn load() error{CompilerUnavailable}!Compiler; fn compile(self: Compiler, alloc: std.mem.Allocator, opts: CompileOptions) CompileError![]u8 }`, `CompileOptions = struct { source: []const u8, source_name: [:0]const u8, entry: [:0]const u8, target: [:0]const u8, flags: u32 = 0, include: ?*ID3DInclude = null }`, `CompileError = error{ CompileFailed, OutOfMemory }` (compiler text logged via `std.log.scoped(.d3dcompiler)`); loads `d3dcompiler_47.dll` with `LoadLibraryExW(…, LOAD_LIBRARY_SEARCH_SYSTEM32)`.

- [ ] **Step 1: Failing tests** in `test_spike.zig`:
  ```zig
  test "win32 com: vtable slot counts" { // @sizeOf(VTable)/@sizeOf(usize)
      // ID3D11Device 43, ID3D11DeviceContext 115, IDXGIFactory2 25, IDXGISwapChain1 29 (verified against SDK 10.0.26100 headers)
  }
  test "win32 spike: WARP clear and readback" { // 4x4 B8G8R8A8_UNORM RT cleared to {1,0,0,1}; staging readback pixel0 == {0,0,255,255} }
  test "win32 spike: D3DCompile trivial pixel shader" { // "float4 main() : SV_Target { return 1; }" ps_5_0 → len > 0 }
  test "win32 spike: D3DCompile reports errors" { // "nonsense" → error.CompileFailed }
  ```
- [ ] **Step 2: Run** `LOCK ZIG build test -j4 --build-file pkg/win32/build.zig` → FAIL (types missing).
- [ ] **Step 3: Implement.** `build.zig`: `b.addModule("win32", …)` + `test` step linking `d3d11`, `dxgi`. `build.zig.zon`: `.name = .win32`, `.paths = .{""}`; take the `fingerprint` from Zig's first-build error.
- [ ] **Step 4: Run** → PASS (4 tests).
- [ ] **Step 5: Commit** `git add pkg/win32 && git commit -m "feat(win32): hand-written COM/DXGI/D3D11/d3dcompiler bindings with WARP spike tests"`

### Task 3: Known core source fixes (minimal)

**Files:**
- Modify: `src/termio/Exec.zig:125-128, 196-230, 537-552, 1778-1829, 1993-2010`
- Modify: `src/main_ghostty.zig:77-95`
- Modify: `src/os/windows.zig` (add `WriteFile` if absent; add empty labelled sections at EOF for later tasks: `// --- events (Task 9)`, `// --- font files (Task 12)`, `// --- registry (Task 13)`, `// --- console (Task 16)`, `// --- jobs (Task 19)`)

**Interfaces:**
- Consumes: Task 1.
- Produces: `Exec.zig` compiles on Windows (argv append arity fixed; quit-pipe `close`/`write` replaced by `CloseHandle`/`WriteFile` — compile-level only, Task 9 replaces the mechanism, no tests here); `main_ghostty.zig` `.none` branch uses the 0.17 stdout idiom used elsewhere in the repo.
- [ ] **Step 1:** `Exec.zig:2003,2007` → `try args.append(alloc, try alloc.dupeSentinel(u8, argv0, 0));` (and `tok`).
- [ ] **Step 2:** Windows-gated `CloseHandle`/`WriteFile` replacements for the quit pipe; POSIX code untouched.
- [ ] **Step 3:** Fix `main_ghostty.zig:78` (`std.io.getStdOut` is gone).
- [ ] **Step 4: Verify** `LOCK ZIG build -Dapp-runtime=none -j4 2>&1 | grep -E "Exec.zig|main_ghostty.zig" ; echo rc=$?` → `rc=1`.
- [ ] **Step 5: Commit** `git commit -am "fix(windows): exec argv append arity, handle-typed quit pipe, stdout API"`

### Task 4: Renderer backend enum + D3D11 contract stub

**Files:**
- Modify: `src/renderer/backend.zig`, `src/renderer.zig:16-42`, `src/build/Config.zig:208-212` (reject `-Drenderer=opengl|metal` for Windows targets), `src/apprt/gtk/class/surface.zig:1778` (`.d3d11 => unreachable`)
- Create: `src/renderer/D3D11.zig`, `src/renderer/d3d11/{Device,Target,Frame,RenderPass,Pipeline,buffer,Texture,Sampler,shaders}.zig` (stubs)

**Interfaces:**
- Consumes: Task 1.
- Produces (later tasks replace bodies, never names):
  - `renderer.D3D11` with every decl of SPEC §6.1 (signatures mirror `src/renderer/OpenGL.zig`), `swap_chain_count = 1`, `custom_shader_target: shadertoy.Target = .glsl`, `custom_shader_y_is_down = true`, `ImageTextureFormat = enum { gray, rgba, bgra }`; no `ExportedFrame`.
  - `pub const PresentTarget = struct { hwnd: *anyopaque, size: *const std.atomic.Value(u64) };` `pub fn packSize(w: u32, h: u32) u64` (w in the high 32 bits), `pub fn unpackSize(v: u64) struct { width: u32, height: u32 }`.
  - `d3d11/Device.zig`: `Options = struct { driver: Driver = .hardware, debug_layer: bool = false }`, `Driver = enum { hardware, warp }`, `init(alloc, Options) !*Device`, `deinit(*Device, alloc)`.
  - Stub behaviour: `init` succeeds; `surfaceSize` returns `{0, 0}` (generic never draws, shaders are lazy — `generic.zig:829,1820`); other functions return `error.Unimplemented` or no-op. CPU structs in `d3d11/shaders.zig` copied from `opengl/shaders.zig`.
- [ ] **Step 1: Failing test** `test "d3d11 stub: size packing roundtrip" { // packSize(3840, 2160) → unpack == {3840, 2160} }`
- [ ] **Step 2: Implement**; `Backend.default` → `.d3d11` on Windows.
- [ ] **Step 3: Verify** `LOCK ZIG build -Dapp-runtime=none -j4 2>&1 | grep -E "renderer/(D3D11|d3d11/)|Dmabuf|egl" ; echo rc=$?` → `rc=1`; `LOCK ZIG build -Demit-lib-vt -j4` → PASS. (The test runs in Task 6.)
- [ ] **Step 4: Commit** `git commit -m "feat(renderer): d3d11 backend enum, windows default and contract stub"`

### Task 5: `pkg/win32` Win32 bindings (full M1 set) + wiring

**Files:**
- Create: `pkg/win32/user32.zig`, `pkg/win32/kernel32.zig`, `pkg/win32/imm32.zig`, `pkg/win32/dwmapi.zig`, `pkg/win32/gdi32.zig`, `pkg/win32/ole32.zig`, `pkg/win32/test_user32.zig`
- Modify: `pkg/win32/main.zig`, `pkg/win32/build.zig`
- Modify: `build.zig.zon` (`.win32 = .{ .path = "./pkg/win32", .lazy = true }`)
- Modify: `src/build/SharedDeps.zig` Windows section (~:970): `addImport("win32", …)`; `linkSystemLibrary` `user32 gdi32 dwmapi imm32 ole32 advapi32 d3d11 dxgi`

**Interfaces:**
- Consumes: Task 2.
- Produces — the complete M1 apprt set, so W9/W10 tasks never edit `pkg/win32` (all `callconv(.winapi)`, W-variants, nullable returns as optionals):
  - `user32` functions: `RegisterClassExW UnregisterClassW CreateWindowExW DestroyWindow DefWindowProcW GetMessageW PeekMessageW TranslateMessage DispatchMessageW PostMessageW SendMessageW PostQuitMessage ShowWindow UpdateWindow SetWindowPos MoveWindow GetClientRect GetWindowRect AdjustWindowRectExForDpi GetDpiForWindow SetWindowLongPtrW GetWindowLongPtrW SetWindowTextW LoadCursorW LoadIconW SetCursor ShowCursor SetCapture ReleaseCapture TrackMouseEvent GetCursorPos ScreenToClient ClientToScreen WindowFromPoint GetKeyState GetKeyboardState ToUnicodeEx VkKeyScanExW MapVirtualKeyExW GetKeyboardLayout GetKeyboardLayoutList LoadKeyboardLayoutW UnloadKeyboardLayout ActivateKeyboardLayout GetMessageTime SetTimer KillTimer OpenClipboard CloseClipboard EmptyClipboard GetClipboardData SetClipboardData IsClipboardFormatAvailable SetFocus GetFocus SetForegroundWindow GetForegroundWindow AllowSetForegroundWindow MessageBeep MessageBoxW GetDoubleClickTime SendInput InvalidateRect ValidateRect BeginPaint EndPaint GetSystemMetricsForDpi IsWindow`.
  - `user32` types: `HKL WNDCLASSEXW MSG CREATESTRUCTW MINMAXINFO TRACKMOUSEEVENT INPUT KEYBDINPUT MOUSEINPUT PAINTSTRUCT WNDPROC`; constants: all `WM_*` used by SPEC §7 incl. `WM_CHAR WM_SYSCHAR WM_DEADCHAR WM_SYSDEADCHAR WM_UNICHAR WM_SYSKEYDOWN WM_SYSKEYUP WM_INPUTLANGCHANGE WM_INPUTLANGCHANGEREQUEST WM_IME_SETCONTEXT WM_IME_STARTCOMPOSITION WM_IME_COMPOSITION WM_IME_ENDCOMPOSITION WM_MOUSELEAVE WM_MOUSEHWHEEL WM_XBUTTONDOWN WM_DPICHANGED WM_GETMINMAXINFO WM_SETCURSOR`; `VK_*` incl. `VK_PACKET (0xE7) VK_PROCESSKEY (0xE5) VK_LCONTROL VK_RCONTROL VK_LMENU VK_RMENU VK_LSHIFT VK_RSHIFT VK_LWIN VK_RWIN VK_CAPITAL VK_NUMLOCK VK_PAUSE VK_F4 VK_SPACE VK_F10`; `KLF_ACTIVATE KLF_NOTELLSHELL KLF_SUBSTITUTE_OK KEYEVENTF_KEYUP KEYEVENTF_UNICODE KEYEVENTF_SCANCODE KEYEVENTF_EXTENDEDKEY INPUT_KEYBOARD`, `WS_* WS_EX_* SW_* SWP_* IDC_* GWLP_USERDATA CF_UNICODETEXT MB_* PM_REMOVE PM_NOREMOVE TME_LEAVE KF_* WHEEL_DELTA SIZE_* UNICODE_NOCHAR`; `HWND_MESSAGE = @ptrFromInt(@as(usize, @bitCast(@as(isize, -3))))`.
  - `kernel32` (GUI side): `GetModuleHandleW GlobalAlloc GlobalLock GlobalUnlock GlobalFree GlobalSize OutputDebugStringW LoadLibraryExW GetProcAddress FreeLibrary GetLastError K32GetProcessMemoryInfo` + `PROCESS_MEMORY_COUNTERS_EX`.
  - `imm32`: `ImmGetContext ImmReleaseContext ImmGetCompositionStringW ImmSetCompositionWindow ImmSetCandidateWindow ImmNotifyIME`; `COMPOSITIONFORM CANDIDATEFORM GCS_COMPSTR GCS_RESULTSTR GCS_CURSORPOS CFS_POINT CFS_CANDIDATEPOS CFS_EXCLUDE ISC_SHOWUICOMPOSITIONWINDOW NI_COMPOSITIONSTR CPS_CANCEL`.
  - `dwmapi`: `DwmSetWindowAttribute`, `DWMWA_USE_IMMERSIVE_DARK_MODE = 20`. `gdi32`: `GetStockObject`. `ole32`: `OleInitialize OleUninitialize`.
- [ ] **Step 1: Failing test** `test "win32 user32: message-only window roundtrip"` — register `GhosttyWin32Test`, `CreateWindowExW(.., HWND_MESSAGE, ..)`, `PostMessageW(hwnd, WM_APP + 7, 42, 0)`, `PeekMessageW(PM_REMOVE)` → `wParam == 42`; destroy + unregister.
- [ ] **Step 2: Run** `LOCK ZIG build test -j4 --build-file pkg/win32/build.zig` → FAIL.
- [ ] **Step 3: Implement** bindings + wiring.
- [ ] **Step 4: Verify** package tests PASS (5); `LOCK ZIG build -Demit-lib-vt -j4` PASS; `LOCK ZIG build -Dapp-runtime=none -j4 2>&1 | grep -E "win32" ; echo rc=$?` → `rc=1`.
- [ ] **Step 5: Commit** `git add pkg/win32 build.zig.zon src/build/SharedDeps.zig && git commit -m "feat(win32): user32/imm32/dwmapi bindings and wire win32 module into windows builds"`

### Task 6: Core compiles and links on Windows (peel the rest)

**Files:** not knowable up front; expected (all Windows-gated): `src/termio/*.zig` (not `Exec.zig` regions owned by Task 9 beyond compile fixes), `src/os/*.zig`, `src/cli/*.zig`, `src/terminal/kitty/*.zig`, `src/crash/*.zig`, `src/inspector/*.zig`, `src/build/SharedDeps.zig` (outside the Windows section), `pkg/dcimgui/build.zig` (disable `backend-opengl3` on Windows if it fails). Runs ALONE in W3.

**Interfaces:**
- Consumes: Tasks 3, 4, 5.
- Produces: `ZIG build test -Dapp-runtime=none -Dtest-filter=<x>` compiles, links and runs `ghostty-test`; `ZIG build -Dapp-runtime=none` installs `ghostty-internal.dll`.
- [ ] **Step 1: Loop** — `LOCK ZIG build test -j4 -Dapp-runtime=none -Dtest-filter="d3d11 stub" 2>&1 | tail -60`; fix the first error class by platform gating (never delete POSIX behaviour); repeat. Record each fix (file:line, one-line why) in the commit body.
- [ ] **Step 2: Size guard** — past ~400 changed lines without a linking test exe: commit (each commit passes `-Demit-lib-vt`) and report NEEDS_CONTEXT with the remaining error list and log path; the lead files 6b.
- [ ] **Step 3: Verify** `-Dtest-filter="d3d11 stub"` PASS; record pass/fail counts for `-Dtest-filter="config"`, `"Exec"`, `"xev"` (libxev IOCP smoke) — do not fix behaviour here.
- [ ] **Step 4: Commit** `git commit -am "fix(windows): make ghostty core and test exe compile and link on windows-msvc"`

### Task 7: Config path = `%USERPROFILE%\.config\ghostty\config.ghostty`

**Files:**
- Modify: `src/os/homedir.zig`, `src/os/xdg.zig:20-104`, `src/config/file_load.zig:12-58`, `src/config/Config.zig:4245-4262`, `src/config/edit.zig:123-140`

**Interfaces:**
- Consumes: Task 6.
- Produces: `homedir.home` Windows = `USERPROFILE` → `HOMEDRIVE ++ HOMEPATH` → null; `expandHome` expands `~/x` and `~\x`; `InternalOptions.windows_env: ?[]const u8` (null for config); `xdg.config` Windows = `XDG_CONFIG_HOME` (non-empty) else `<home>\.config`; cache/state unchanged; `file_load.defaultXdgPath` joins components (`"ghostty"`, `"config.ghostty"`); `pub fn preferredXdgPathEnv(io: std.Io, alloc: Allocator, environ_map: *const std.process.Environ.Map) ![]const u8` (`preferredXdgPath` delegates); no legacy `config` on Windows in `loadDefaultFiles`, `preferredXdgPath*`, `configPathCandidates`.
- [ ] **Step 1: Failing tests** (Windows-only, `error.SkipZigTest` elsewhere)
  ```zig
  test "windows xdg: config base is USERPROFILE\\.config, LOCALAPPDATA ignored" { // USERPROFILE=C:\Users\Анна Ли → "C:\\Users\\Анна Ли\\.config\\ghostty" }
  test "windows xdg: XDG_CONFIG_HOME replaces the base" { // D:\cfg → "D:\\cfg\\ghostty" }
  test "windows xdg: cache still uses LOCALAPPDATA" {}
  test "windows homedir: USERPROFILE wins over HOMEDRIVE+HOMEPATH" {}
  test "windows homedir: expandHome expands ~/ and ~\\" {}
  test "windows config: legacy config file is ignored" { // temp XDG_CONFIG_HOME with only ghostty\config → path ends "\\ghostty\\config.ghostty" }
  ```
- [ ] **Step 2: Run** `LOCK ZIG build test -j4 -Dapp-runtime=none -Dtest-filter="windows xdg"` (also `"windows homedir"`, `"windows config"`) → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS; `-Dtest-filter="config"` no new failures vs Task 6's record.
- [ ] **Step 5: Commit** `git commit -m "feat(windows): single config path under %USERPROFILE%\\.config, no legacy fallback"`

### Task 8: D3D11 Device, Buffer, Texture, Sampler

**Files:**
- Modify (replace stubs): `src/renderer/d3d11/Device.zig`, `src/renderer/d3d11/buffer.zig`, `src/renderer/d3d11/Texture.zig`, `src/renderer/d3d11/Sampler.zig`
- Modify: `pkg/win32/d3d11.zig` (type `CreateBuffer`, `CreateShaderResourceView`, `CreateSamplerState`, `UpdateSubresource`; `BUFFER_DESC TEXTURE2D_DESC SUBRESOURCE_DATA SHADER_RESOURCE_VIEW_DESC SAMPLER_DESC BOX MAPPED_SUBRESOURCE`)

**Interfaces:**
- Consumes: Tasks 2, 4, 6.
- Produces:
  ```zig
  // Device.zig
  device: *d3d11.ID3D11Device, context: *d3d11.ID3D11DeviceContext, factory: *dxgi.IDXGIFactory2, level, max_texture_size: u32,
  pub fn init(alloc: Allocator, options: Options) !*Device;   // env GHOSTTY_D3D11_DRIVER=warp|hardware, GHOSTTY_D3D11_DEBUG=1 override
  pub fn deinit(self: *Device, alloc: Allocator) void;
  pub fn lockContext(self: *Device) void;  pub fn unlockContext(self: *Device) void; // std.Io.Mutex; debug asserts owner thread
  // buffer.zig
  pub const Role = enum { vertex, structured, constant };
  pub const Options = struct { device: *Device, role: Role };
  pub fn Buffer(comptime T: type) type // buffer, srv: ?, len, opts; init, initFill, deinit, sync, syncFromArrayLists; DYNAMIC + Map(WRITE_DISCARD); ×2 growth recreates SRV
  // Texture.zig
  pub const Options = struct { device: *Device, format: dxgi.Format, srv_format: dxgi.Format, render_target: bool = false, rtv_format: dxgi.Format = .UNKNOWN };
  // texture, srv, rtv: ?, width, height; init(opts, w, h, ?[]const u8) Error!Texture; deinit(); replaceRegion(x, y, w, h, data) Error!void
  // Sampler.zig
  pub const Options = struct { device: *Device, filter: enum { linear, nearest } = .linear }; // clamp addressing
  ```
- [ ] **Step 1: Failing tests** (WARP): `"d3d11 device: WARP device has feature level >= 11_0"`, `"d3d11 buffer: sync grows and preserves contents"` (structured u32, 4 → 10 items, srv non-null, readback == input), `"d3d11 buffer: constant role rounds size to 16"`, `"d3d11 texture: replaceRegion writes the box"` (R8 8×8, box (2,2,2,2) = {1,2,3,4}, (0,0) == 0).
- [ ] **Step 2: Run** `LOCK ZIG build test -j4 -Dapp-runtime=none -Dtest-filter="d3d11 "` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `git commit -m "feat(d3d11): device with context lock, dynamic buffers, textures and samplers"`

### Task 9: Event-driven pty read loop and drain on exit

**Files:**
- Modify: `src/pty.zig:326-491` (`WindowsPty`: out pipe as overlapped named pipe `\\.\pipe\LOCAL\ghostty-pty-out-<pid>-<n>`; `closeChildSide`; `closeConsoleAsync`)
- Modify: `src/termio/Exec.zig:120-230, 274-330, 537-552, 1778-1829`
- Modify: `src/os/windows.zig` (section `events`: `CreateEventW SetEvent WaitForMultipleObjects WaitForSingleObject GetOverlappedResult ERROR_IO_PENDING ERROR_BROKEN_PIPE WAIT_OBJECT_0 WAIT_TIMEOUT`)

**Interfaces:**
- Consumes: Task 6.
- Produces:
  ```zig
  // Exec.zig (Windows only)
  pub fn readLoopWindows(handle: windows.HANDLE, quit_event: windows.HANDLE, ctx: anytype, comptime onData: fn (@TypeOf(ctx), []const u8) void) ReadLoopEnd; // 64 KiB buffer
  pub const ReadLoopEnd = enum { eof, quit, err };
  // pty.zig WindowsPty
  pub fn closeChildSide(self: *Pty) void;   // closes in_pipe_pty + out_pipe_pty; Exec calls it right after the child is spawned
  pub fn closeConsoleAsync(self: *Pty) void; // idempotent (atomic flag); deinit skips ClosePseudoConsole if done
  ```
  `threadMainWindows` = thin wrapper calling `io.processOutput`; sets `drained_event` on `.eof`. `threadExit` = `SetEvent(quit_event)` + join. Windows child-exit path: `closeConsoleAsync()`, wait ≤ 500 ms on `drained_event`, continue.
- [ ] **Step 1: Failing tests**
  ```zig
  test "windows exec: read loop returns promptly when quit is signalled while blocked" { // SetEvent after 50 ms → .quit, join < 1000 ms (Io timestamps) }
  test "windows exec: read loop delivers all bytes before EOF" { // 1 MiB in 4 KiB chunks, close writer → .eof, 1 MiB collected }
  test "windows exec: output before child exit is drained and EOF follows" {
      // WindowsPty.open + spawn `cmd.exe /c echo ghostty-drain-token`; closeChildSide after spawn; on exit closeConsoleAsync
      // → output contains the token AND readLoopWindows returns .eof within 1000 ms of closeConsoleAsync
  }
  ```
- [ ] **Step 2: Run** `LOCK ZIG build test -j4 -Dapp-runtime=none -Dtest-filter="windows exec"` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS; `-Dtest-filter="pty"`, `"Command"` no new failures.
- [ ] **Step 5: Commit** `git commit -m "fix(windows): event-driven ConPTY read loop, close pty-side handles, drain on child exit"`

### Task 10: Apprt runtime enum, build wiring, minimal App loop

**Files:**
- Modify: `src/apprt/runtime.zig`, `src/apprt.zig:43-50`
- Modify (`.win32` arms or `else => void`): `src/apprt/action.zig:733`, `src/apprt/structs.zig:47,53,216`, `src/apprt/surface.zig:174`, `src/config/Config.zig:4892,9346,10068`, `src/datastruct/split_tree.zig:1327`, `src/font/face.zig:61`, `src/input/Binding.zig:995`, `src/build/SharedDeps.zig:691`
- Modify: `build.zig` (exe for `.win32`; run step `build.zig:297` assert), `src/build/GhosttyExe.zig:44-48` (`exe.entry = .{ .symbol_name = "mainCRTStartup" }` on Windows, from Task 1)
- Create: `src/apprt/win32.zig`, `src/apprt/win32/App.zig` (minimal), `src/apprt/win32/Surface.zig` (stub `struct {}` + required decls returning errors)

**Interfaces:**
- Consumes: Tasks 5, 6.
- Produces:
  ```zig
  // win32.zig
  pub const App = @import("win32/App.zig"); pub const Surface = @import("win32/Surface.zig"); pub const resourcesDir = internal_os.resourcesDir;
  // App.zig (minimal; Task 14 extends)
  core_app: *CoreApp, config: Config, hinstance: HINSTANCE,
  pub fn init(self: *App, core_app: *CoreApp, opts: struct {}) !void;  // OleInitialize, Config.load, core_app.updateConfig
  pub fn run(self: *App) !void;   // while (GetMessageW(&msg, null, 0, 0) > 0) { TranslateMessage(&msg); DispatchMessageW(&msg); } — TranslateMessage is REQUIRED (Task 23 drains WM_CHAR)
  pub fn terminate(self: *App) void;
  pub fn wakeup(self: *App) void;  // no-op until Task 14
  pub fn performAction(...) !bool; // returns false (log.debug) until Task 14
  pub fn performIpc(alloc, target, comptime action, value) !bool; // false
  ```
- [ ] **Step 1: Failing test** `test "win32 app: runtime is win32 on windows" { try testing.expect(build_config.app_runtime == .win32); }` in `App.zig`.
- [ ] **Step 2: Run** `LOCK ZIG build test -j4 -Dtest-filter="win32 app"` → FAIL.
- [ ] **Step 3: Implement.** With no window yet, `run` posts `WM_QUIT` to itself when `GHOSTTY_WIN32_EXIT_IMMEDIATELY=1` (test hook for Step 4), else loops.
- [ ] **Step 4: Verify** test PASS; first worktree build per the bootstrap rule; `LOCK ZIG build -j4` installs `zig-out/bin/ghostty.exe`; `GHOSTTY_WIN32_EXIT_IMMEDIATELY=1 ./zig-out/bin/ghostty.exe; echo rc=$?` → `rc=0`; `LOCK ZIG build -Demit-lib-vt -j4` PASS.
- [ ] **Step 5: Commit** `git commit -m "feat(win32): apprt runtime enum, GUI entry point and minimal message loop"`

### Task 11: HLSL text-path shaders, register map, compile cache

**Files:**
- Create: `src/renderer/shaders/hlsl/common.hlsli`, `full_screen.hlsl`, `bg_color.hlsl`, `cell_bg.hlsl`, `cell_text.hlsl`, `src/renderer/d3d11/hlsl.zig`, `src/renderer/d3d11/slots.zig`

**Interfaces:**
- Consumes: Tasks 2, 4, 6.
- Produces:
  ```zig
  // hlsl.zig
  pub const Entry = enum { full_screen_vs, bg_color_ps, cell_bg_ps, cell_text_vs, cell_text_ps }; // Task 15 appends image_*, bg_image_*
  pub fn bytecode(entry: Entry) ![]const u8; // compiled once per process (mutex + slot per entry); vs_5_0/ps_5_0
  pub fn warmup() void;
  pub fn source(entry: Entry) []const u8;    // for the slots test
  // slots.zig (mirror of common.hlsli; SPEC §6.2)
  pub const uniforms_cb: u32 = 1;            // b1, VS+PS
  pub const buffer_srv_base: u32 = 3;        // buffers[i>=1] → t(3+i), VS+PS (bg_cells = t4)
  pub const max_textures: u32 = 3;           // textures[i] → t(i), PS only
  pub fn bufferSrv(i: usize) u32;            // asserts i >= 1
  ```
  HLSL = 1:1 port of the matching `shaders.metal` functions; `common.hlsli` declares every `Globals` member with an explicit `packoffset` and every register explicitly (`register(b1)`, `register(t0|t1|t4)`, `register(s0)`).
- [ ] **Step 1: Failing tests**
  ```zig
  test "d3d11 hlsl: every entry compiles" { inline for (std.meta.tags(Entry)) |e| try testing.expect((try bytecode(e)).len > 0); }
  test "d3d11 hlsl: bytecode is cached" { // same ptr on second call }
  test "d3d11 slots: bg_cells register matches slots.zig and does not alias textures" {
      // common.hlsli text contains "register(t4)" for bg_cells; bufferSrv(1) == 4; 4 >= max_textures
  }
  ```
- [ ] **Step 2: Run** `LOCK ZIG build test -j4 -Dapp-runtime=none -Dtest-filter="d3d11 hlsl"` and `"d3d11 slots"` → FAIL.
- [ ] **Step 3: Implement** (Debug: `DEBUG | SKIP_OPTIMIZATION`; release: `OPTIMIZATION_LEVEL3`; `ID3DInclude` serving the embedded `common.hlsli`).
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `git commit -m "feat(d3d11): HLSL text-path shaders, fixed register map and runtime compile cache"`

### Task 12: Windows font discovery — index, ranking, UTF-16 file access, colour emoji check

**Files:**
- Modify: `src/font/discovery.zig:965-1210` (`Windows`), `src/font/DeferredFace.zig:235-250` (`.win` load path), `src/font/face/freetype.zig:66-100` (face may own a mapped view)
- Create: `src/font/WindowsFontFile.zig`
- Modify: `src/os/windows.zig` (section `font files`: `CreateFileW CreateFileMappingW MapViewOfFile UnmapViewOfFile GetFileSizeEx FILE_MAP_READ PAGE_READONLY`)

**Interfaces:**
- Consumes: Task 6.
- Produces:
  ```zig
  // WindowsFontFile.zig — read-only mapping opened via a UTF-16 path (no ANSI fopen; no private-bytes copy)
  pub fn open(path_utf8: []const u8) !WindowsFontFile; pub fn bytes(self: *const WindowsFontFile) []const u8; pub fn close(self: *WindowsFontFile) void;
  ```
  `Windows.discover` honours `bold`, `italic`, `style`, `monospace` with ranking (exact style > weight distance > italic match); one process-wide index (family, style, OS/2 weight, italic, path, face index; `.ttf .ttc .otf .otc`) built once under a mutex; `discoverFallback` tries the SPEC §9 list first. All FreeType faces for `.win` load through `WindowsFontFile` + memory face; the face owns the mapping.
- [ ] **Step 1: Failing tests** (skip if the named system font is absent)
  ```zig
  test "windows font: Consolas bold resolves to consolab.ttf" {}
  test "windows font: Consolas bold italic resolves to consolaz.ttf" {}
  test "windows font: index is built once" {}
  test "windows font: emoji fallback prefers Segoe UI Emoji" { // U+1F600 → "seguiemj.ttf" }
  test "windows font: font in a non-ASCII directory loads" { // copy consola.ttf to %TEMP%\Шрифты Тест\ → open+load face succeeds }
  test "windows font: U+1F600 from Segoe UI Emoji renders as a colour glyph" {
      // render into an Atlas → isColorGlyph == true and atlas format BGRA; if FreeType cannot (COLRv1),
      // the test is marked SkipZigTest with a log line "known M1 gap: monochrome system emoji" and the gap is recorded in the report
  }
  ```
- [ ] **Step 2: Run** `LOCK ZIG build test -j4 -Dapp-runtime=none -Dtest-filter="windows font"` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS (colour test PASS or SKIP-with-gap); `-Dtest-filter="font"` no new failures vs Task 6.
- [ ] **Step 5: Commit** `git commit -m "feat(windows): indexed font discovery with style ranking, UTF-16 font file mapping"`

### Task 13: Default shell resolver + Windows TERM default

**Files:**
- Create: `src/os/windows_shell.zig`
- Modify: `src/os/main.zig` (export), `src/os/windows.zig` (section `registry`: `GetFileAttributesW RegGetValueW HKEY_LOCAL_MACHINE HKEY_CURRENT_USER RRF_RT_REG_SZ`), `src/config/Config.zig:3935, 4843-4858`

**Interfaces:**
- Consumes: Task 7 (Config.zig order), Task 6.
- Produces:
  ```zig
  pub const Kind = enum { git_bash, pwsh, cmd };
  pub const Resolved = struct { kind: Kind, argv: []const [:0]const u8 };
  pub const Probe = struct {
      ctx: ?*anyopaque = null,
      exists: *const fn (ctx: ?*anyopaque, path: []const u8) bool,
      regGitInstallPath: *const fn (ctx: ?*anyopaque, alloc: Allocator) ?[]const u8,
  };
  pub fn resolve(alloc: Allocator, env: *const std.process.Environ.Map, probe: Probe) !Resolved;
  pub fn systemProbe() Probe;
  ```
  Order/argv per SPEC §8.3. `Config.finalize` Windows arm: `command == null` → `.direct = argv`; `git_bash` + no user `CHERE_INVOKING` → put `CHERE_INVOKING=1` in `env`; log `default shell kind=… path=…`. `term` default `"xterm-256color"` on Windows only.
- [ ] **Step 1: Failing tests** — `"windows shell: Git Bash preferred, argv has --login -i"`, `"windows shell: System32 bash.exe (WSL) is never chosen"`, `"windows shell: registry InstallPath used"`, `"windows shell: git.exe on PATH locates bash"`, `"windows shell: pwsh when no Git Bash"` (argv `{…\pwsh.exe, "-NoLogo"}`), `"windows shell: cmd from COMSPEC as last resort"`, `"windows shell: non-ASCII ProgramFiles path survives"` (`C:\Программы\Git\bin\bash.exe`), `"windows config: TERM defaults to xterm-256color"`.
- [ ] **Step 2: Run** `LOCK ZIG build test -j4 -Dapp-runtime=none -Dtest-filter="windows shell"` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS; `-Dtest-filter="config"` no new failures.
- [ ] **Step 5: Commit** `git commit -m "feat(windows): default shell Git Bash -> pwsh -> cmd and TERM=xterm-256color default"`

### Task 14: Apprt App wakeup, message-only window, top-level Window, actions

**Files:**
- Modify: `src/apprt/win32/App.zig`
- Create: `src/apprt/win32/Window.zig`, `src/apprt/win32/util.zig`

**Interfaces:**
- Consumes: Task 10.
- Produces:
  ```zig
  // App.zig
  pub const WM_GHOSTTY_WAKEUP = WM_APP + 1; pub const WM_GHOSTTY_QUIT_TIMER = WM_APP + 3; // WM_APP + 2 reserved for the surface clipboard message (Task 26)
  msg_hwnd: HWND, windows: std.ArrayList(*Window), wakeup_pending: std.atomic.Value(bool),
  pub fn wakeup(self: *App) void;             // thread-safe, coalesced PostMessageW(msg_hwnd, WM_GHOSTTY_WAKEUP)
  pub fn startQuitTimer(self: *App) void;
  // performAction: quit, close_window, quit_timer (SetTimer on msg_hwnd), set_title, render (true, no-op); others log.debug + false
  // Window.zig
  hwnd: HWND, app: *App, surface: ?*Surface,  // M1: at most one surface; hosting is added in Task 21
  pub fn create(app: *App) !*Window;          // class "GhosttyWindow", WS_OVERLAPPEDWINDOW, DWMWA_USE_IMMERSIVE_DARK_MODE per system theme
  pub fn destroy(self: *Window) void;         // destroys its surface first (Task 21), then its HWND
  // util.zig
  pub fn utf16z(alloc: Allocator, s: []const u8) ![:0]u16; pub fn utf8(alloc: Allocator, s: []const u16) ![]u8;
  pub fn fromUserData(comptime T: type, hwnd: HWND) ?*T;
  ```
  Closing the last window posts `WM_QUIT`. `App.init` creates the message-only window and the first `Window`.
- [ ] **Step 1: Failing tests** `"win32 util: utf16 roundtrip with non-BMP"` (`"a😀Ж"`), `"win32 app: wakeup coalesces"` (1000 calls from 4 threads → 1 ≤ queued WM_GHOSTTY_WAKEUP ≤ 4).
- [ ] **Step 2: Run** `LOCK ZIG build test -j4 -Dtest-filter="win32 "` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Verify** tests PASS; `LOCK ZIG build -j4`; launch `./zig-out/bin/ghostty.exe &`, after 3 s `powershell -NoProfile -Command "(Get-Process ghostty).MainWindowTitle"` prints a title; `(Get-Process ghostty).CloseMainWindow()` → process gone ≤ 3 s.
- [ ] **Step 5: Commit** `git commit -m "feat(win32): app wakeup, message-only window, top-level window and basic actions"`

### Task 15: HLSL image shaders

**Files:** Create `src/renderer/shaders/hlsl/image.hlsl`, `bg_image.hlsl`; Modify `src/renderer/d3d11/hlsl.zig` (append `image_vs image_ps bg_image_vs bg_image_ps`).

**Interfaces:** Consumes Task 11 (`Entry`, `bytecode`, slots: texture `t0`, sampler `s0`). Produces the four tags.
- [ ] **Step 1:** "d3d11 hlsl: every entry compiles" now covers the new tags → FAIL until the files exist.
- [ ] **Step 2: Implement** 1:1 ports of Metal `image_*`/`bg_image_*` (repeat via `fmod`, linear-clamp `s0`).
- [ ] **Step 3: Run** `LOCK ZIG build test -j4 -Dapp-runtime=none -Dtest-filter="d3d11 hlsl"` → PASS.
- [ ] **Step 4: Commit** `git commit -m "feat(d3d11): HLSL port of image and bg_image shaders"`

### Task 16: Logging sinks, console attach, panic hook

**Files:**
- Modify: `src/global.zig:395-402`, `src/main_ghostty.zig:24-60, 118-200`, `src/main.zig` (root `pub const panic` on Windows)
- Create: `src/os/windows_console.zig`, `src/os/windows_log.zig` (imported directly by `main_ghostty.zig`/`main.zig`)
- Modify: `src/os/windows.zig` (section `console`: `AttachConsole ATTACH_PARENT_PROCESS SetStdHandle GetStdHandle CreateFileW(if absent) OutputDebugStringW MoveFileExW`)

**Interfaces:**
- Consumes: Tasks 6, 13 (`os/windows.zig` order).
- Produces:
  ```zig
  // windows_console.zig
  pub fn ensureConsoleForCli() void;
  // windows_log.zig
  pub fn init(alloc: Allocator, environ_map: *const std.process.Environ.Map) void; // %LOCALAPPDATA%\ghostty\logs\ghostty.log, rotate > 5 MiB → ghostty.1.log
  pub fn write(line: []const u8) void;
  pub fn formatLine(buf: []u8, ts_ms: i64, level: std.log.Level, scope: []const u8, msg: []const u8) []const u8;
  pub fn writePanic(msg: []const u8, trace: ?*std.builtin.StackTrace, ret_addr: ?usize) void; // file sink + OutputDebugStringW
  ```
  `Logging` gains `file: bool = windows`, `debugger: bool = windows and Debug`; the stderr sink skips when the handle is invalid. Root panic override on Windows: `windows_log.writePanic(...)` then the default panic.
- [ ] **Step 1: Failing tests** `"windows log: line format"` (ts 0 → `"1970-01-01T00:00:00.000Z info(config): hello"`), `"windows log: rotation over 5 MiB"`, `"windows log: panic text reaches the file sink"` (call `writePanic("boom", null, null)` against a temp LOCALAPPDATA → file contains `panic: boom`).
- [ ] **Step 2: Run** `LOCK ZIG build test -j4 -Dapp-runtime=none -Dtest-filter="windows log"` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Verify** PASS; manual (GUI-subsystem limitation, SPEC §11): `./zig-out/bin/ghostty.exe +version | cat` from Git Bash and `cmd //c "zig-out\\bin\\ghostty.exe +version | more"` print the version.
- [ ] **Step 5: Commit** `git commit -m "feat(windows): file/debugger log sinks, console attach for CLI actions, panic to log"`

### Task 17: Pipeline, RenderPass, Target

**Files:**
- Modify (replace stubs): `src/renderer/d3d11/Pipeline.zig`, `src/renderer/d3d11/RenderPass.zig`, `src/renderer/d3d11/Target.zig`
- Modify: `pkg/win32/d3d11.zig` (type `CreateInputLayout CreateVertexShader CreatePixelShader CreateBlendState CreateRasterizerState IASetInputLayout IASetVertexBuffers IASetPrimitiveTopology VSSetShader PSSetShader VSSetConstantBuffers PSSetConstantBuffers VSSetShaderResources PSSetShaderResources PSSetSamplers OMSetRenderTargets OMSetBlendState RSSetViewports RSSetState DrawInstanced Draw`; `INPUT_ELEMENT_DESC BLEND_DESC RASTERIZER_DESC VIEWPORT`)

**Interfaces:**
- Consumes: Tasks 8, 11.
- Produces:
  ```zig
  // Pipeline.zig
  pub const Options = struct { device: *Device, vertex: hlsl.Entry, pixel: hlsl.Entry, step_fn: enum { constant, per_vertex, per_instance } = .per_vertex, blending_enabled: bool = true };
  pub fn init(comptime VertexAttributes: ?type, opts: Options) !Pipeline; // comptime-reflected input layout, TEXCOORD<i>, integer → *_UINT/_SINT
  // Target.zig
  pub const Options = struct { device: *Device, width: usize, height: usize, srgb: bool };
  pub fn readPixelsAlloc(self: *const Target, alloc: Allocator) ![]u8; // BGRA8 via staging (tests, dump hook)
  // RenderPass.zig — shape of opengl/RenderPass.zig; binds uniforms to b1 (VS+PS), buffers[0] to IA slot 0,
  // buffers[i>=1] to t(slots.bufferSrv(i)) in VS AND PS, textures[i] to t(i) PS, samplers[i] to s(i) PS
  ```
- [ ] **Step 1: Failing tests** (WARP): `"d3d11 pipeline: input layout reflects CellText"` (7 elements: R32G32_UINT, R32G32_UINT, R16G16_SINT, R16G16_UINT, R8G8B8A8_UINT, R8_UINT, R8_UINT; stride 32), `"d3d11 renderpass: clear colour reaches the target"` ({0,0.5,1,1} → BGRA {255,128,0,255} ±1), `"d3d11 renderpass: bg_color pipeline fills the target"` (bg {10,20,30,255} → BGRA {30,20,10,255}).
- [ ] **Step 2: Run** `LOCK ZIG build test -j4 -Dapp-runtime=none -Dtest-filter="d3d11 "` → FAIL.
- [ ] **Step 3: Implement** (clear on the first step only; `.triangle` → TRIANGLELIST, `.triangle_strip` → TRIANGLESTRIP).
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `git commit -m "feat(d3d11): pipelines with reflected input layouts, per-stage slot binding, offscreen targets"`

### Task 18: Apprt Surface — core contract

**Files:**
- Modify (replace stub): `src/apprt/win32/Surface.zig`
- Create: `src/apprt/win32/dpi.zig`, and dispatch stubs with their state types: `src/apprt/win32/keyboard.zig`, `mouse.zig`, `ime.zig`, `clipboard.zig`, `dialogs.zig`

**Interfaces:**
- Consumes: Tasks 4 (`PresentTarget`, `packSize`), 14 (`Window`, `App`, `util`).
- Produces (W9/W10 tasks fill the stub files and never edit `Surface.zig`):
  ```zig
  // Surface.zig — heap allocated, stable address, GWLP_USERDATA → *Surface
  hwnd: HWND, window: *Window, core_surface: CoreSurface, initialized: bool, id: u32,
  size: std.atomic.Value(u64), content_scale: apprt.ContentScale, title: ?[:0]const u8,
  keyboard_state: keyboard.State, mouse_state: mouse.State, ime_state: ime.State, clipboard_state: clipboard.State,
  pub fn create(window: *Window) !*Surface;  // CreateWindowExW("GhosttySurface", WS_CHILD|WS_VISIBLE|WS_CLIPSIBLINGS) then core_surface.init, then initialized = true
  pub fn destroy(self: *Surface) void;       // clipboard.cancelPending(self) → core_surface.deinit() (joins threads) → DestroyWindow(hwnd) → free
  pub fn core(self: *Surface) *CoreSurface;  pub fn rtApp(self: *const Surface) *App;
  pub fn close(self: *Surface, process_active: bool) void; // dialogs.confirmClose(self.window.hwnd) when needed, then window-level close
  pub fn getTitle, getContentScale, getSize, getCursorPos, defaultTermioEnv, renderDeviceOptions  // per SPEC §7.2
  pub fn supportsClipboard(...) bool; pub fn clipboardRequest(...) !apprt.ClipboardReadResult; pub fn setClipboard(...) !void; // forward to clipboard.zig
  pub fn d3d11PresentTarget(self: *Surface) ?renderer.D3D11.PresentTarget; // { hwnd, &self.size }
  pub fn sizeMessage(wparam: WPARAM, lparam: LPARAM) struct { packed_size: u64, visible: bool };
  // stub files, each: pub const State = struct {}; pub fn handle(self: *Surface, msg: u32, wparam: WPARAM, lparam: LPARAM) ?LRESULT { return null; }
  // clipboard.zig additionally: supports/request/write/cancelPending stubs; dialogs.zig: confirmClose(owner) bool (MessageBoxW stub), confirm(...)
  // dpi.zig
  pub fn contentScale(dpi: u32) apprt.ContentScale;
  ```
  WndProc: core callbacks are ignored until `initialized`; order `WM_SIZE` (sizeMessage → store → `sizeCallback` → `core.draw()`; minimize → `occlusionCallback(false)`, restore → `true`), `WM_SETFOCUS/KILLFOCUS` → `focusCallback`, `WM_ERASEBKGND` → 1, `WM_PAINT` → `ValidateRect`, then `ime.handle` → `keyboard.handle` → `mouse.handle` → `clipboard.handle`, else `DefWindowProcW`.
- [ ] **Step 1: Failing tests** `"win32 dpi: content scale"` (96 → 1.0, 120 → 1.25, 144 → 1.5), `"win32 surface: WM_SIZE decoding"` (`SIZE_MINIMIZED` → `{0, false}`; `SIZE_RESTORED` 800×600 → `{packSize(800,600), true}`; `SIZE_MAXIMIZED` 1×1 → `{packSize(1,1), true}`).
- [ ] **Step 2: Run** `LOCK ZIG build test -j4 -Dtest-filter="win32 "` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS; `LOCK ZIG build -j4` compiles.
- [ ] **Step 5: Commit** `git commit -m "feat(win32): surface child window implementing the core apprt surface contract"`

### Task 19: Job object for the child tree + Windows command tokenizer

**Files:**
- Modify: `src/Command.zig:305-440` (`PROC_THREAD_ATTRIBUTE_JOB_LIST` in the existing attribute list; `job` handle; `bInheritHandles = FALSE` on the pseudo-console path)
- Modify: `src/termio/Exec.zig:1150-1180` (Windows kill = `TerminateJobObject`), `:1993-2010` (`.shell` tokenization)
- Modify: `src/os/windows.zig` (section `jobs`: `CreateJobObjectW SetInformationJobObject TerminateJobObject QueryInformationJobObject JOBOBJECT_EXTENDED_LIMIT_INFORMATION JOBOBJECT_BASIC_PROCESS_ID_LIST PROC_THREAD_ATTRIBUTE_JOB_LIST`)

**Interfaces:**
- Consumes: Tasks 9, 16 (file order).
- Produces: `pub fn tokenizeWindows(alloc: Allocator, s: []const u8) ![][:0]const u8` in `Exec.zig` (MS C runtime rules); `Command.job: ?windows.HANDLE` (`KILL_ON_JOB_CLOSE`), closed on cleanup.
- [ ] **Step 1: Failing tests** `"windows tokenize: quoted path with spaces"` (`"\"C:\\Program Files\\Git\\bin\\bash.exe\" --login -i"` → 3 args), `"windows tokenize: escaped quote and non-ASCII"` (`say "\"hi\"" Ж` → `say`, `"hi"`, `Ж`), `"windows command: closing the job kills grandchildren"` (`cmd.exe /c ping -n 60 127.0.0.1 >nul`; after 500 ms ≥ 2 pids in the job; close job → all signalled ≤ 2000 ms, Io timestamps).
- [ ] **Step 2: Run** `LOCK ZIG build test -j4 -Dapp-runtime=none -Dtest-filter="windows tokenize"` and `"windows command"` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS; `"windows exec"` still PASS.
- [ ] **Step 5: Commit** `git commit -m "feat(windows): kill-on-close job via JOB_LIST attribute and MS-rules command tokenizer"`

### Task 20: d3d11 `shaders.zig` — pipeline set and uniform layout

**Files:** Modify (replace stub) `src/renderer/d3d11/shaders.zig`.

**Interfaces:**
- Consumes: Tasks 15, 17.
- Produces: `Shaders.init(alloc, device: *Device, custom_shaders: []const [:0]const u8) !Shaders` building `bg_color`, `cell_bg`, `cell_text`, `image`, `bg_image`; non-empty `custom_shaders` → `log.warn` once, `post_pipelines = &.{}`; `deinit`; CPU structs (`Uniforms`, `CellText`, `CellBg`, `Image`, `BgImage`) as before; `pub const hlsl_uniform_offsets` table (field name → byte offset) mirroring `common.hlsli` packoffsets.
- [ ] **Step 1: Failing tests** `"d3d11 shaders: Uniforms offsets match the HLSL cbuffer"` (for every field `@offsetOf(Uniforms, name) == hlsl_uniform_offsets[name]`), `"d3d11 shaders: all builtin pipelines initialise on WARP"`.
- [ ] **Step 2: Run** `LOCK ZIG build test -j4 -Dapp-runtime=none -Dtest-filter="d3d11 shaders"` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `git commit -m "feat(d3d11): builtin pipeline set and uniform layout checks"`

### Task 21: Window hosts the Surface; harness foundation

**Files:**
- Modify: `src/apprt/win32/Window.zig` (host one Surface child; `WM_SIZE` → `SetWindowPos(child)`, `WM_DPICHANGED` → suggested rect + `contentScaleCallback`, `WM_GETMINMAXINFO` from `size_limit`, `WM_CLOSE` → `needsConfirmQuit` + `dialogs.confirmClose`, destroy order per SPEC §6.4)
- Modify: `src/apprt/win32/App.zig` (actions `initial_size`, `size_limit`, `cell_size` stored/applied; `mouse_shape`, `mouse_visibility` → `surface.mouse_state`; `show_child_exited` → false; `close_window`)
- Create: `test/windows/lib/Harness.psm1`, `test/windows/launch.ps1`, `test/windows/README.md`, `test/windows/configs/cmd.ghostty` (`command = direct:cmd.exe /k chcp 65001`)

**Interfaces:**
- Consumes: Task 18.
- Produces:
  - `Harness.psm1`: `Test-InteractiveSession` (unlocked, interactive, `GetForegroundWindow` non-null) → `$true|$false`; `Invoke-GuiScenario -Name -ScriptBlock` (prints `SKIP <name>: <reason>` when not interactive, `PASS|FAIL <name>` otherwise, and appends to `$env:TEMP\ghostty-e2e\results.txt`); `Set-ForegroundSafe -Hwnd` (`AllowSetForegroundWindow(ASFW_ANY)` + Alt-tap + `SetForegroundWindow`); `Save-KeyboardLayouts` / `Restore-KeyboardLayouts` (`GetKeyboardLayoutList` diff, unload only added layouts, re-activate the original); `Switch-GhosttyLayout -Hwnd -Klid` (`LoadKeyboardLayoutW` + `PostMessageW(WM_INPUTLANGCHANGEREQUEST)`); `Stop-OwnGhostty` (kills pids started by the script).
  - `launch.ps1 -Config <path> [-Driver warp] [-DumpDir <dir>]` → temp `XDG_CONFIG_HOME\ghostty\config.ghostty`, sets `GHOSTTY_D3D11_DRIVER`/`GHOSTTY_D3D11_DUMP`, starts `zig-out\bin\ghostty.exe`, waits for `MainWindowHandle` ≤ 10 s, prints `pid=<n> hwnd=<0x…>`.
- [ ] **Step 1: Failing test** `"win32 window: child rect fills the client area"` (pure `childRect(client: RECT) RECT` helper; M1 has no padding/strip → identity).
- [ ] **Step 2: Run** `LOCK ZIG build test -j4 -Dtest-filter="win32 window"` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Verify** PASS; `LOCK ZIG build -j4`; `powershell -NoProfile -File test/windows/launch.ps1 -Config test/windows/configs/cmd.ghostty` → `Get-CimInstance Win32_Process -Filter 'ParentProcessId=<pid>'` lists `cmd.exe` (window blank: renderer still headless); default config lists `bash.exe` when Git for Windows is installed; closing the window leaves no child of that pid after 3 s.
- [ ] **Step 5: Commit** `git commit -m "feat(win32): window hosts a core surface; safe e2e harness foundation"`

### Task 22: D3D11 API and Frame (headless) + frame-dump hook

**Files:** Modify (replace stubs) `src/renderer/D3D11.zig`, `src/renderer/d3d11/Frame.zig`.

**Interfaces:**
- Consumes: Tasks 8, 17, 20.
- Produces: every contract decl real (SPEC §6.1); `swap_chain_count = 1`; `drawFrameStart/End` = `device.lockContext/unlockContext`; `beginFrame(renderer, target)` calls `self.waitForFrameSlot(sync)` (no-op until Task 27 sets a swap chain); `surfaceSize` headless → `setViewport` value; `Frame.complete(sync)` = `context.Flush()` (Task 27 adds present) → dump hook → `renderer.frameCompleted(health)` (`error.DeviceLost` → `.unhealthy`, logged once); `Device.warmup()` (static) → `hlsl.warmup()`.
  Dump hook: when env `GHOSTTY_D3D11_DUMP=<dir>` is set, `Frame.complete` writes `Target.readPixelsAlloc` as a 32-bit BMP to `<dir>\surface-<n>.bmp` at most every 250 ms (`n` = per-process renderer index).
- [ ] **Step 1: Failing tests** (WARP, headless)
  ```zig
  test "d3d11 frame: cell_bg draws a per-cell colour" { // 2x1 grid, cell 8x16; bg_cells {red, green} → (4,8) red, (12,8) green }
  test "d3d11 frame: cell_text samples the grayscale atlas" { // 4x4 glyph in an 8x8 atlas → inside ≥ 250 white, outside == bg }
  test "d3d11 frame: colour atlas glyph next to a non-default bg cell" {
      // BGRA atlas glyph (pure blue) at cell 0, cell 1 bg = green → cell 0 pixels blue, cell 1 green (no t-register aliasing)
  }
  test "d3d11 frame: dump hook writes a BMP" { // env dir in %TEMP%; one frame → surface-0.bmp exists, size == 54 + w*h*4 }
  ```
- [ ] **Step 2: Run** `LOCK ZIG build test -j4 -Dapp-runtime=none -Dtest-filter="d3d11 frame"` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `git commit -m "feat(d3d11): complete headless GraphicsAPI, frames and frame-dump hook"`

### Task 23: Keyboard translation

**Files:** Create `src/apprt/win32/key.zig`, `test/windows/send-input.ps1`; Modify `src/apprt/win32/keyboard.zig`.

**Interfaces:**
- Consumes: Tasks 18 (`keyboard.State`, `handle` signature), 21 (harness).
- Produces:
  ```zig
  // key.zig (pure)
  pub const KeyState = [256]u8;
  pub fn physicalKey(lparam: LPARAM, vk: u16) input.Key;           // scancode | 0xE000 if extended; Pause/NumLock by VK; 0xE02A/0xE036 → .unidentified
  pub fn mods(state: *const KeyState) input.Mods;
  pub fn layoutHasAltGr(hkl: HKL) bool;
  pub fn unshiftedCodepoint(hkl: HKL, vk: u16, scancode: u16) u21;   // ToUnicodeEx(empty state, flags 0x4)
  pub fn applyAltGr(m: input.Mods, has_altgr_layout: bool, ralt_down: bool, produced_text: bool) struct { mods: input.Mods, consumed: input.Mods };
  pub fn stripControl(text: []const u8, buf: []u8) []const u8;
  pub const Utf16Joiner = struct { pending_high: ?u16 = null; pub fn feed(self: *Utf16Joiner, unit: u16, out: *[4]u8) ?[]const u8 }; // joins surrogate pairs across WM_CHARs
  pub fn passToSystem(vk: u16, sys: bool, alt_down: bool) bool;     // true only for Alt+F4 and Alt+Space
  // keyboard.State: altgr_cache: ?struct { hkl: HKL, has_altgr: bool }, joiner: Utf16Joiner, last_lctrl_time: ?i32, dead_pending: bool
  ```
  Handler (SPEC §7.3): `WM_KEYDOWN/UP`, `WM_SYSKEYDOWN/UP` (only `passToSystem` cases reach `DefWindowProcW`; F10/Alt+x go to core), drains posted `WM_CHAR/WM_SYSCHAR/WM_DEADCHAR/WM_SYSDEADCHAR` via `PeekMessageW(PM_REMOVE)`; `VK_PROCESSKEY` → ignored (IME owns it); `VK_PACKET` key-downs → no key event, their `WM_CHAR` text → `textCallback` (through the joiner); `WM_CHAR` without a preceding key-down → `textCallback`; `WM_INPUTLANGCHANGE` → `altgr_cache = null`; synthetic AltGr LCtrl swallowed; dead keys → `composing` + preedit.
  `send-input.ps1 -Hwnd <h> (-Text <s> | -Keys <list> | -Scancodes <list>)` via Harness (`Set-ForegroundSafe`); `-Keys` uses VK+scancode (real typing path), `-Text` uses `KEYEVENTF_UNICODE` (`VK_PACKET` path).
- [ ] **Step 1: Failing tests** (layouts via `LoadKeyboardLayoutW(KLF_NOTELLSHELL)`; a test-local helper unloads only layouts it added; skip if a layout cannot load)
  ```zig
  test "win32 key: physical key from extended scancode" { // 0x48+ext → .arrow_up; 0x48 → .numpad_8 }
  test "win32 key: Pause vs NumLock" {}
  test "win32 key: US has no AltGr, DE has AltGr" {}
  test "win32 key: AltGr consumes ctrl+alt only when text produced" {}
  test "win32 key: unshifted codepoint on RU layout is Cyrillic, physical key stays .key_c" { // U+0441 }
  test "win32 key: stripControl removes C0" {}
  test "win32 key: surrogate pair joined across two WM_CHAR units" { // 0xD83D then 0xDE00 → "😀"; lone high then BMP → U+FFFD + char }
  test "win32 key: only Alt+F4 and Alt+Space pass to the system" { // F10 sys → false; Alt+X → false }
  test "win32 key: layouts loaded by tests are unloaded afterwards" { // GetKeyboardLayoutList before == after }
  ```
- [ ] **Step 2: Run** `LOCK ZIG build test -j4 -Dtest-filter="win32 key"` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Verify** PASS; with Harness (SKIP if not interactive): cmd config, `send-input.ps1 -Keys` typing `echo kb-ok> %TEMP%\gt-kb.txt` + enter → file `kb-ok`; `-Text "echo Жж😀> %TEMP%\gt-kb2.txt"` + enter → file contains `Жж😀` (UTF-8 via `chcp 65001`).
- [ ] **Step 5: Commit** `git commit -m "feat(win32): keyboard translation incl. AltGr, dead keys, VK_PACKET and surrogates"`

### Task 24: Mouse, wheel and cursor shapes

**Files:** Modify `src/apprt/win32/mouse.zig`.

**Interfaces:**
- Consumes: Task 18 (`mouse.State` holds `shape`, `visible`, `captured_buttons`, `tracking_leave`), Task 21 (actions write the state).
- Produces: `pub fn wheelOffset(delta: i16) struct { offset: f64, precision: bool }`; `pub fn cursorFor(shape: terminal.MouseShape) [*:0]const u16` (text → IDC_IBEAM, pointer/grab/grabbing → IDC_HAND, default/other → IDC_ARROW, resize shapes → IDC_SIZE*, crosshair, wait/progress, not_allowed → IDC_NO); handler for move, L/R/M/X buttons (`SetCapture` on first down, `ReleaseCapture` when none), wheel/hwheel (routed to the surface under the cursor via `WindowFromPoint`), `WM_MOUSELEAVE`, `WM_SETCURSOR` (client area; hidden when `visible == false`).
- [ ] **Step 1: Failing tests** `"win32 mouse: wheel offsets"` (120 → 1.0 not precise; -240 → -2.0; 30 → 0.25 precise), `"win32 mouse: cursor map"`.
- [ ] **Step 2: Run** `LOCK ZIG build test -j4 -Dtest-filter="win32 mouse"` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `git commit -m "feat(win32): mouse buttons, capture, wheel and cursor shapes"`

### Task 25: IME (IMM32)

**Files:** Modify `src/apprt/win32/ime.zig`.

**Interfaces:**
- Consumes: Task 18 (`ime.State`: `composing: bool`); core `Surface.imePoint()` (already the BOTTOM of the cursor cell, unscaled-divided — `src/Surface.zig:2246-2254`), `preeditCallback`, `textCallback`.
- Produces: handler for `WM_IME_SETCONTEXT` (clear `ISC_SHOWUICOMPOSITIONWINDOW`), `WM_IME_STARTCOMPOSITION` (positions), `WM_IME_COMPOSITION` (`GCS_COMPSTR` → preedit, `GCS_RESULTSTR` → text + clear preedit), `WM_IME_ENDCOMPOSITION` (preedit null); `pub fn candidatePos(p: apprt.IMEPos, scale: f32) POINT` (= `{x*scale, y*scale}`, no extra height); `pub fn excludeRect(p: apprt.IMEPos, scale: f32) RECT` (`[y - height, y]` scaled, for `CFS_EXCLUDE`); `ime.State.composing` is what Task 23 consults with `VK_PROCESSKEY`.
- [ ] **Step 1: Failing tests** `"win32 ime: candidate position is the cursor bottom"` (IMEPos{10,20,8,16}, 1.5 → POINT{15, 30}), `"win32 ime: exclude rect covers the cursor cell"` (→ RECT{15, 6, 27, 30}).
- [ ] **Step 2: Run** `LOCK ZIG build test -j4 -Dtest-filter="win32 ime"` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS. Manual (if MS-IME Japanese is installed; else record SKIP): `nihon` + Space + Enter in cmd → `日本` (echo oracle).
- [ ] **Step 5: Commit** `git commit -m "feat(win32): IMM32 composition and candidate window placement"`

### Task 26: Clipboard and confirmation dialogs

**Files:** Modify `src/apprt/win32/clipboard.zig`, `src/apprt/win32/dialogs.zig`.

**Interfaces:**
- Consumes: Task 18 (`clipboard.State` = FIFO of pending `apprt.ClipboardRequest`s; `cancelPending` called by `Surface.destroy`).
- Produces:
  ```zig
  pub const WM_GHOSTTY_CLIPBOARD_READ = WM_APP + 2; // posted to the SURFACE hwnd (no pointer payload); a destroyed hwnd drops it
  pub fn supports(t: apprt.Clipboard) bool;                          // .standard only
  pub fn write(hwnd: HWND, text_utf8: []const u8) !void;             // OpenClipboard retry 5× 10 ms (io.sleep), CF_UNICODETEXT
  pub fn read(alloc: Allocator, hwnd: HWND) !?[:0]u8;
  pub fn request(self: *Surface, t: apprt.Clipboard, req: apprt.ClipboardRequest) !apprt.ClipboardReadResult; // enqueue + PostMessageW(self.hwnd, …) → .started
  pub fn cancelPending(self: *Surface) void;                         // denyClipboardRequest for each queued request
  // dialogs.zig (MessageBoxW in M1)
  pub fn confirm(owner: HWND, title: []const u8, body: []const u8) bool;
  pub fn confirmClose(owner: HWND) bool;
  pub fn previewText(alloc: Allocator, text: []const u8, max_chars: usize) ![]u8; // control chars → U+2400 block, 512 chars + "…"
  ```
  Unsafe/unauthorized paste → `confirm` → `completeClipboardRequest(confirmed = true)` or `denyClipboardRequest`; OSC 52 write with `confirm = true` → `confirm` first.
- [ ] **Step 1: Failing tests** `"win32 clipboard: write then read roundtrip with non-ASCII"` (`"copy Ж😀\nline2"`), `"win32 clipboard: write succeeds while another thread holds the clipboard briefly"` (holder sleeps 30 ms via Io), `"win32 clipboard: pending request is denied when the surface closes"` (fake queue + recording deny callback), `"win32 dialogs: preview escapes control characters and truncates"`.
- [ ] **Step 2: Run** `LOCK ZIG build test -j4 -Dtest-filter="win32 clipboard"` and `"win32 dialogs"` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `git commit -m "feat(win32): clipboard with retries, safe async reads and paste/OSC52 confirmations"`

### Task 27: Swap chain, present, pacing, resize

**Files:**
- Create: `src/renderer/d3d11/SwapChain.zig`, `test/windows/capture-window.ps1`, `test/windows/configs/colors.ghostty`
- Modify: `src/renderer/D3D11.zig` (`threadEnter` creates the swap chain from `d3d11PresentTarget`; `surfaceSize` pulls `PresentTarget.size`; `waitForFrameSlot`), `src/renderer/d3d11/Frame.zig` (`complete`: copy + present), `src/renderer/d3d11/Device.zig` (tearing support query)
- Modify: `pkg/win32/dxgi.zig` (type `CreateSwapChainForHwnd MakeWindowAssociation CheckFeatureSupport(IDXGIFactory5 via QI) GetBuffer ResizeBuffers Present SetMaximumFrameLatency GetFrameLatencyWaitableObject`; `SWAP_CHAIN_DESC1`)

**Interfaces:**
- Consumes: Tasks 21, 22.
- Produces:
  ```zig
  pub const Mode = enum { hwnd }; // .composition in M3
  pub fn init(device: *Device, hwnd: *anyopaque, width: u32, height: u32, mode: Mode) !SwapChain;
  //   FLIP_DISCARD, 2 buffers, B8G8R8A8_UNORM, flags FRAME_LATENCY_WAITABLE_OBJECT (+ALLOW_TEARING if supported),
  //   SetMaximumFrameLatency(1), MakeWindowAssociation(NO_WINDOW_CHANGES|NO_ALT_ENTER) BEFORE the first Present
  pub fn deinit(self: *SwapChain) void;
  pub fn waitForSlot(self: *SwapChain, timeout_ms: u32) void;  // waits only if presented_since_wait; clears it
  pub fn copyToBackbuffer(self: *SwapChain, ctx: *d3d11.ID3D11DeviceContext, target: *const Target) !void; // ResizeBuffers (same flags, refs released) when size differs, then CopyResource
  pub fn present(self: *SwapChain, vsync: bool) !void;          // Present(vsync?1:0, (!vsync and tearing) ? ALLOW_TEARING : 0); sets presented_since_wait; OCCLUDED is success
  ```
  `D3D11.waitForFrameSlot(sync)` → `swap_chain.waitForSlot(if (sync) 0 else 100)`.
  `capture-window.ps1 -Hwnd <h> -Out <png> [-Probe "x,y"]` (Harness; SKIP when not interactive) uses `PrintWindow(PW_RENDERFULLCONTENT)`.
- [ ] **Step 1: Failing tests** (hidden test HWND, WARP)
  ```zig
  test "d3d11 swapchain: copyToBackbuffer puts the target into the back buffer" { // read back buffer 0 BETWEEN copy and present → BGRA {0,0,255,255} }
  test "d3d11 swapchain: present returns ok or occluded" {}
  test "d3d11 swapchain: resize 1x1 and back keeps creation flags" { // no INVALID_CALL; desc matches last size }
  test "d3d11 pacing: no-op draws do not consume the latency slot" {
      // 10 drawFrame calls that early-return (no redraw) then one real frame: total < 20 ms
  }
  test "d3d11: surfaceSize 0x0 skips drawing" {}
  ```
- [ ] **Step 2: Run** `LOCK ZIG build test -j4 -Dapp-runtime=none -Dtest-filter="d3d11 "` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Verify** PASS; `LOCK ZIG build -j4`; `launch.ps1 -Config test/windows/configs/colors.ghostty -DumpDir $TEMP/gt-dump` (`background = #102030`, `foreground = #e0e0e0`, `command = direct:cmd.exe /k echo GHOSTTY-M1`) → `surface-0.bmp` pixel (5,5) = `#102030`; open the BMP and confirm `GHOSTTY-M1` is legible; `capture-window.ps1` probe agrees (or SKIP).
- [ ] **Step 5: Commit** `git commit -m "feat(d3d11): flip-model swap chain with waitable pacing in beginFrame and safe resize"`

### Task 28: End-to-end scenarios

**Files:** Create `test/windows/e2e/*.ps1` (one script per scenario), `test/windows/e2e-m1.ps1` (runner), `test/windows/configs/{gitbash-de,unsafe-paste,stream}.ghostty`.

**Interfaces:**
- Consumes: everything above; Harness (`Invoke-GuiScenario`, layout save/restore, `Stop-OwnGhostty`).
- Produces: each scenario prints `PASS|FAIL|SKIP <name>`; the runner exits non-zero only on FAIL; results also in `$env:TEMP\ghostty-e2e\results.txt`. Pixel checks use `GHOSTTY_D3D11_DUMP`.
  1. `startup` — window ≤ 1.5 s; child `bash.exe` (or pwsh/cmd); cwd `%USERPROFILE%` (`pwd -W > %TEMP%\gt-cwd.txt`).
  2. `config-path` — temp `USERPROFILE` without config → template created at `<USERPROFILE>\.config\ghostty\config.ghostty`.
  3. `typing-us`, `typing-de-altgr` (`Switch-GhosttyLayout 00000407`, `altgr+q` → `@`), `typing-de-deadkey` (scancode 0x29 then `e` → `ê`), `typing-ru` (real `-Keys` on 00000419 → `привет`), `typing-unicode` (`-Text` VK_PACKET path, `😀`), `ctrl-c` (`ping -t 127.0.0.1` interrupted).
  4. `paste-confirm` — clipboard `echo a\necho b` + `ctrl+shift+v` → dialog (`#32770`) → Enter → both run.
  5. `render` — dump pixel = config background.
  6. `resize` — `SetWindowPos` 400×300 then 1200×800 → dumps; no `error` lines in `ghostty.log`.
  7. `resize-while-streaming` — `SetWindowPos` ×200 while `cmd /c "for /L %i in (1,1,2000000) do @echo %i"` streams; watchdog: window responds to `SendMessageTimeout(WM_NULL, 2000 ms)` throughout and the run ends ≤ 10 s after the loop. A hang triggers the SPEC §6.4 fallback (filed as a 29.n task).
  8. `close-tree` — `ping -n 60 127.0.0.1`, close window → no `ping.exe`/`bash.exe`/`conhost.exe`/`OpenConsole.exe` child of the old pid after 3 s.
  9. `close-while-streaming` — close during the stream → process exits ≤ 3 s.
  10. `shell-exit` — `exit` → process gone ≤ 3 s, no orphan `conhost.exe`/`OpenConsole.exe`.
  11. `vim-less` (Git Bash config) — `less /etc/profile` then `q`; `vim -c ':wq! %TEMP%/gt-vim.txt'` after typing `i`, `vim-ok`, `Esc` → file contains `vim-ok`.
- [ ] **Step 1:** Write scripts; run `powershell -NoProfile -File test/windows/e2e-m1.ps1` after `LOCK ZIG build -j4`; for every FAIL write a short bug note (scenario, symptom, log excerpt) into the report — the lead files one 29.n task per bug.
- [ ] **Step 2: Commit** `git commit -m "test(windows): M1 end-to-end scenarios with safe GUI harness"`

### Task 29.n: Integration fix (template, one bug per task)

**Files:** exactly the files the bug note names (lead assigns; ≤ 3 parallel only with disjoint files).

- [ ] **Step 1:** Reproduce with the failing scenario script; if the bug is in pure logic, write a failing unit test first.
- [ ] **Step 2:** Fix; run the unit test filter and the scenario script → PASS (or SKIP when not interactive, noted).
- [ ] **Step 3: Commit** `git commit -m "fix(windows): <bug summary>"`

### Task 30: RAM baseline, ARM64 compile check, M1 acceptance

**Files:**
- Create: `test/windows/measure-ram.ps1`, `docs/windows/ram-baseline.csv`
- Modify: `test/windows/README.md`, `src/renderer/d3d11/Device.zig` and `src/apprt/win32/App.zig` (three `debug` log lines with `PrivateUsage` from `K32GetProcessMemoryInfo`: after `Device.init`, after the first surface init, after the first frame)

**Interfaces:**
- Consumes: Tasks 28, 29.*.
- Produces: `measure-ram.ps1 [-Driver hardware|warp] [-Scenario one-surface|scrollback] [-Optimize ReleaseFast|Debug]` → appends `date,commit,optimize,adapter,scenario,private_mb,ws_mb` (SPEC §14; ghostty.exe only, 10 s idle; `scrollback` runs `cmd /c "for /L %i in (1,1,200000) do @echo %i"` first; adapter from the `d3d11 adapter=` log line).
- [ ] **Step 1:** `LOCK ZIG build -j4 -Doptimize=ReleaseFast`; run `one-surface` (hardware, warp) and `scrollback` (hardware).
- [ ] **Step 2: Gate** — `one-surface` hardware ReleaseFast `private_mb ≤ 110`; above → DONE_WITH_CONCERNS with the three `PrivateUsage` log values; no tuning here.
- [ ] **Step 3: ARM64** — `LOCK ZIG build -Dtarget=aarch64-windows-msvc -j4` → record PASS/FAIL (not gating; failures become M2 tasks).
- [ ] **Step 4: M1 checklist** (SPEC §17 M1 criteria 1–10): build; filters `win32 `, `d3d11 `, `windows `, plus `terminal`, `config`, `input`, `font` (pass/fail counts); `e2e-m1.ps1` (PASS/SKIP list; SKIPs re-run interactively by the owner); RAM row; record everything in the report.
- [ ] **Step 5: Commit** `git commit -m "test(windows): RAM measurement script, M1 baseline and acceptance record"`

---

## Self-review notes

- Spec coverage (SPEC §17 M1): core compile (1, 3, 4, 6), bindings (2, 5), apprt (10, 14, 18, 21, 23–26), D3D11 (8, 11, 15, 17, 20, 22, 27), ConPTY robustness (9, 19), config path (7), default shell + TERM (13), fonts (12), logging/console/panic (16), DPI basics (18, 21), RAM + ARM64 (30), e2e (28). Out of M1 by design: tabs/splits/multi-window/Mica (M2), custom shaders/transparency/inspector/URL (M3), tmux (M4), OSC 7/pwsh integration (M5).
- Wave table re-checked for ≤ 3 tasks and disjoint files; hot-file ownership listed under the table.

## Pre-flight dispositions

Findings from `docs/windows/plans/M1-preflight-review.md`:

1. applied — pacing wait moved to `beginFrame` with `presented_since_wait` and timeout 0 on sync draws (Tasks 22, 27; SPEC §6.3); test "no-op draws do not consume the latency slot".
2. applied — `mainCRTStartup` entry proven by a hello-GUI exe in Task 1, applied to `GhosttyExe.zig` in Task 10 (SPEC §3).
3. applied — `closeChildSide` right after spawn; EOF-within-1 s assertion (Task 9); `bInheritHandles = FALSE` on the pty path (Task 19; SPEC §8.4).
4. applied — fixed register map (`bg_cells` = `t4`), `slots.zig` mirror, per-stage binding, aliasing test (Tasks 11, 17, 22; SPEC §6.2).
5. applied — candidate position is `imePoint` scaled, no extra height; `CFS_EXCLUDE` rect test (Task 25).
6. applied — `copyToBackbuffer` + `present` split; readback between them; second test accepts OK/OCCLUDED (Task 27).
7. applied — `MakeWindowAssociation` before first Present, no `SetFullscreenState`, live-resize-while-streaming watchdog scenario, documented fallback (Tasks 27, 28; SPEC §6.4).
8. applied — teardown order and `initialized` guard (Tasks 14, 18, 21; SPEC §6.4).
9. applied — `swap_chain_count = 1` (Task 4; SPEC §6.1).
10. applied — ReleaseFast measurement, `optimize` column, cmd-based scrollback (Task 30; SPEC §14).
11. applied — manifest moved to Task 1; fonts opened via UTF-16 file mapping + memory face, non-ASCII dir test (Task 12; SPEC §3, §9).
12. applied — `VK_PACKET`, surrogate joining, `WM_SYS*` handling with Alt+F4/Alt+Space passthrough, `VK_PROCESSKEY`, `WM_INPUTLANGCHANGE` cache reset (Task 23); `TranslateMessage` required in the loop (Task 10).
13. applied — Harness with interactive-session pre-check → SKIP, `AllowSetForegroundWindow` + Alt-tap, `WM_INPUTLANGCHANGEREQUEST`, layout-list diff restore, `GHOSTTY_D3D11_DUMP` as primary pixel oracle (Tasks 21, 22, 23, 27, 28; SPEC §15).
14. applied — worktree bootstrap Global Constraint (`zig-pkg` junction, background first build); waves capped at 3 per the lead.
15. applied — split: old 11 → 10 + 14; old 18 → 18 + 21; old 19 → 20 + 22; old 25 → 28 + 29.n; old 24 kept as 27 with the dump hook moved to 22 and PS capture secondary.
16. applied — Task 18 pre-declares `keyboard_state`/`mouse_state`/`ime_state`/`clipboard_state` with types in their own files; Task 5 front-loads the full W9/W10 constant set.
17. applied — panic hook writing to the file sink + `OutputDebugStringW` (Task 16; SPEC §11).
18. applied — colour-emoji rendering test with documented SKIP-as-known-gap fallback (Task 12; SPEC §9).
19. applied — `vim-less` and `shell-exit` scenarios (Task 28); SPEC §17 criterion (9) added.
20. applied — `advapi32` folded into Task 5; labelled sections in `os/windows.zig` (Task 3); `os/windows.zig` now has one owner per wave.
21. applied — `-Dapp-runtime=none` on every renderer/core test command (Global Constraints + each task).
22. applied — Io-based timing/sleep rule in Global Constraints; tests reference Io timestamps.
23. applied — `ResizeBuffers` repeats creation flags after releasing refs; tearing only with interval 0 (Task 27; SPEC §6.3).
24. applied — `PROC_THREAD_ATTRIBUTE_JOB_LIST` instead of suspended+assign (Task 19; SPEC §8.4).
25. applied — clipboard read message posted to the surface HWND without a pointer payload; pending requests denied in `Surface.destroy` (Tasks 18, 26).
26. applied — nullable return types and the `HWND_MESSAGE` constant spelled out (Task 5, Global Constraints).
27. applied — `+version` check via pipes / `| more`; limitation documented (Task 16; SPEC §11).
28. applied — ARM64 compile-only check recorded in Task 30 (SPEC §17 criterion 10).
29. applied — Task 3 limited to compile-level fixes without tests; WARP re-runs only in Task 30.
