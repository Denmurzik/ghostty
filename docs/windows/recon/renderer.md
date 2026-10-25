# Renderer recon: designing a D3D11 GraphicsAPI backend

Scope: read-only digest of `src/renderer/**`, shader pipeline, build wiring, apprt contract.
All paths relative to repo root `C:\D\den4ik\Ghostty`. Line numbers are from the checked-out tree (upstream main + `windows` branch; no renderer files appear modified for Windows yet).
Note: this tree is NEWER than the classic GL-in-GLArea design: OpenGL is now an EGL-surfaceless offscreen renderer and the apprt composites "exported frames" (Section 5). Do not rely on older knowledge of `OpenGL.zig`.

## 0. TL;DR

- A backend is one Zig struct (`OpenGL.zig` 449 LOC, `Metal.zig` 387 LOC) plus 8-9 sibling files; `GenericRenderer(GraphicsAPI)` (`src/renderer/generic.zig`, 3693 LOC) does all terminal logic and only calls a small, well-defined surface (Section 1).
- Exactly 5 builtin pipelines + N user post-process pipelines. No compute, no geometry, no mipmaps, no MSAA. Everything fits D3D11 FL 11_0 comfortably (Section 4).
- Per-API shader sources exist twice (GLSL 776 LOC, MSL 853 LOC). Metal's conventions (Y-down, pixel-center FragCoord, `custom_shader_y_is_down = true`) are the closest match to D3D11, so port from `shaders.metal`, not GLSL.
- Custom (shadertoy) shaders go GLSL -> glslang (Vulkan client, fragment only) -> SPIR-V -> SPIRV-Cross. The SPIRV-Cross build compiles ONLY GLSL+MSL backends; HLSL needs `spirv_hlsl.cpp` + `-DSPIRV_CROSS_C_API_HLSL=1` (2-line change in `pkg/spirv-cross/build.zig`, Section 3).
- Estimated D3D11 backend size: ~2.0-2.6k LOC Zig + ~0.9k LOC HLSL + a COM binding package (no win32/d3d bindings exist in the repo; Section 6/7).

## 1. Backend selection and the GraphicsAPI contract

### 1.1 Selection
- Enum: `src/renderer/backend.zig:5-17` `Backend { opengl, metal }`, `default()` returns metal on Darwin else opengl. A `.d3d11` arm must be added here (and `default()` for `.windows`).
- Build option: `src/build/Config.zig:27` field `renderer`, `:208-212` `-Drenderer=<opengl|metal>`, exported to code via `:697` `addOptions(RendererBackend, "renderer", ...)`; `src/build_config.zig:43` `pub const renderer`.
- Comptime switch: `src/renderer.zig:39-42` (`GraphicsAPI = switch (build_config.renderer)`), `:36` `Renderer = GenericRenderer(GraphicsAPI)`, `:45` `Device = GraphicsAPI.Device`.
- Other switch sites that must learn `.d3d11`: `src/apprt/gtk/class/surface.zig:1778-1798` (`renderDeviceOptions`, gtk only), `src/apprt/embedded.zig:1278` (imgui shutdown), `src/build/SharedDeps.zig:578` (links OpenGL framework when `.opengl` on Darwin), `src/crash/sentry.zig:182` (tag only). `SharedDeps.zig:~590` passes `backend-opengl3 = !isDarwin` to dcimgui (inspector); on Windows the inspector would need an `imgui_impl_dx11`/win32 backend (not wired in `pkg/dcimgui/build.zig:9-11`). Out of scope for MVP, flag it.

### 1.2 Hierarchy (documented at `generic.zig:60-89`)
GraphicsAPI -> Target / Frame -> RenderPass -> Step -> Pipeline; plus Buffer, Texture, Sampler, Device, shaders.

### 1.3 Required decls on the API struct (what `generic.zig` actually touches)
Type-level decls (`generic.zig:96-108`, 310):
- `Device` (app-scoped; `src/renderer.zig:45`, `src/Surface.zig:565-570` calls `Device.init(alloc, rt_surface.renderDeviceOptions())` once and caches in `app.device`; `App.zig:100` calls optional `Device.warmup` on a detached thread; `App.zig:150` `dev.deinit(alloc)`). Needs `Device.Options` (returned by apprt `renderDeviceOptions`).
- `GraphicsAPI` (self alias), `Target`, `Frame`, `RenderPass`, `Pipeline`, `Buffer(T)` (generic fn), `Sampler`, `Texture`, `shaders` (module).
- `swap_chain_count: comptime_int` (3 in both; sizes the frame ring, `generic.zig:310`).
- `custom_shader_target: shadertoy.Target` (`.glsl`/`.msl`; `generic.zig:885`) -> add `.hlsl`.
- `custom_shader_y_is_down: bool` (`generic.zig:100,2490,2500`; also read by gtk apprt to flip exported frames, `render_surface.zig:193`).
- Optional: `ExportedFrame` (`generic.zig:96`, void if absent).

Instance methods on the API value (`self.api.*`):
- `init(alloc, device: *const Device, opts: renderer.Options) !API` (`generic.zig:716`), `deinit()` (`:871`). Options (`src/renderer/Options.zig`): device, derived config, font_grid, size, surface_mailbox, `rt_surface: *apprt.Surface`, `thread`.
- `initShaders(alloc, custom_shaders: []const [:0]const u8) !shaders.Shaders` (`:893`); called lazily, again on blending/custom-shader change (`reinitialize_shaders`, `:2237,2244`). Custom shader strings are already converted to the API's target language.
- `initTarget(w, h) !Target` (`:446,480`), `initAtlasTexture(*const font.Atlas) !Texture` (`:424,430,3687`).
- `bufferOptions` family: `fgBufferOptions`, `bgBufferOptions`, `uniformBufferOptions`, `imageBufferOptions`, `bgImageBufferOptions` (+ `instanceBufferOptions`) (`generic.zig:405-420,509; image.zig`). In GL/Metal all alias one fn; in D3D11 these MUST differ (bind flags: vertex vs SRV vs constant buffer).
- `textureOptions()` (custom shader ping-pong textures), `samplerOptions()`, `imageTextureOptions(format: ImageTextureFormat, srgb: bool)` (only ever called with `(.rgba, true)`, `image.zig:797`; the `.gray`/`.bgra` variants are dead). `ImageTextureFormat = {gray, rgba, bgra}` must exist.
- `beginFrame(renderer: *Renderer, target: *Target) !Frame` (`:1908`).
- `surfaceSize() !{width,height}` (`:1760`) polled every draw: if 0 -> skip draw; difference from `self.size.screen` triggers target recreation.
- `drawFrameStart()` / `drawFrameEnd()` (`:1756-1757`), mandatory (Metal: autorelease pool).
- Optional via `@hasDecl`: `threadEnter(surface: *apprt.Surface) !void` (`:907`), `threadExit()` (`:941`), `loopEnter()` (`:949`) / `loopExit()` (`:962`), `displayRealized()` (`:982`), `setViewport(w,h)` (`:2262`, called from `setScreenSize`), `present(...)` (not called by generic; called by Frame impls).

Per-type contracts:
- `Target`: fields `width`, `height` (read at `:1912` region: `frame.target.width != self.size.screen.width`), `init(Options)`, `deinit()`. GL: sRGB RT texture + blit-to-RGBA8 export texture (`opengl/Target.zig`). Metal: IOSurface-backed MTLTexture (`metal/Target.zig`).
- `Frame` (`opengl/Frame.zig`, `metal/Frame.zig`): `begin(opts, renderer, target)`, `renderPass(attachments) RenderPass`, `complete(sync: bool)`. `complete` is responsible for: submit, present (API-specific), then call `renderer.frameCompleted(health)` (`generic.zig:2046`) which posts the frame-ring semaphore. GL does `gl.finish()` then `frameCompleted` synchronously (`opengl/Frame.zig:60-90`); Metal does it in a command-buffer completion handler.
- `RenderPass`: `begin(Options{attachments})`, `step(Step)`, `complete()`. `Attachment{ target: union{texture: Texture, target: Target}, clear_color: ?[4]float }`. `Step{ pipeline, uniforms: ?Buffer, buffers: []?Buffer, textures: []?Texture, samplers: []?Sampler, draw{ type, vertex_count, instance_count } }`. Primitive types used: `.triangle` (fullscreen 3-vertex), `.triangle_strip` (4-vertex quads).
  Slot conventions (the real binding contract the shaders rely on):
  - uniforms -> constant buffer slot **1** (b1) (GL `bindBase(.uniform,1)` `opengl/RenderPass.zig:~95`; MSL `[[buffer(1)]]`).
  - `buffers[0]` -> the vertex/instance buffer (stride from `Pipeline.stride`); `buffers[i>=1]` -> storage/structured buffer at slot **i** for GL (SSBO binding i) and at index i+1 for Metal (index 1 is uniforms). For D3D11 use SRV slot `t(i)` in both VS and PS.
  - `textures[i]` -> texture slot i; `samplers[i]` -> sampler slot i (fragment stage). Only the custom-shader pass supplies samplers; builtin pipelines use fixed samplers inside the shader (Metal `constexpr sampler`) or per-texture state (GL).
  - Blending: pipeline-level flag `blending_enabled`; always premultiplied `ONE, ONE_MINUS_SRC_ALPHA` (`opengl/RenderPass.zig:125-126`; `metal/Pipeline.zig:125-128`). Clear color applied on first step only (GL: `step_number==0`).
- `Pipeline`: `init(comptime VertexAttributes: ?type, Options{vertex_fn, fragment_fn, step_fn: constant|per_vertex|per_instance, blending_enabled})`, `deinit()`, field `stride`. Vertex layout is derived by comptime reflection over the Zig extern struct (`opengl/Pipeline.zig:autoAttribute`; field order == attribute location). `step_fn.constant` is declared but not used by any pipeline.
- `Buffer(T)`: `init(opts, len)`, `initFill(opts, []const T)`, `deinit()`, `sync([]const T)` (grow x2 on overflow, else partial overwrite), `syncFromArrayLists([]ArrayList(T)) !usize` (returns item count), field `buffer` (the raw handle passed as Step uniforms/buffers). `opengl/buffer.zig`, `metal/buffer.zig`. Note `initFill` is used per Kitty placement per frame (`image.zig:~145`): create+destroy a 1-element buffer for every image draw. In D3D11 prefer Dynamic `Map(WRITE_DISCARD)`; consider caching later.
- `Texture`: `init(opts, w, h, ?data)`, `deinit()`, `replaceRegion(x,y,w,h,data)`, fields `width`,`height` (atlas growth check `generic.zig:3682`). Error set `Texture.Error` used in `initAtlasTexture` signature.
- `Sampler`: `init(opts)`, `deinit()`, field holds native sampler.
- `shaders` module: `Shaders{ pipelines: <struct with fields bg_color, cell_bg, cell_text, image, bg_image>, post_pipelines: []const Pipeline, defunct }`, `Shaders.init(...)`, `deinit(alloc)`, `Shaders.uninit`; and the CPU-side vertex/uniform struct types: `Uniforms`, `CellText`, `CellBg` (=[4]u8), `Image`, `BgImage` (`opengl/shaders.zig:~116-290`; `metal/shaders.zig` has identical definitions). These exact extern layouts are the CPU/GPU ABI and must be mirrored in HLSL.
- Presentation (API-specific, not called by generic):
  - Metal: `present(target, sync)` sets the IOSurface on a CALayer from the completion handler (`Metal.zig:237`, `metal/Frame.zig:~55-75`).
  - GL: `present(target, presentation_health) !ExportedFrame` (`OpenGL.zig:277`); `ExportedFrame = union{dmabuf, memory}` (`:301`); Frame pushes it with `renderer.pushFrame` (single-slot latest-wins queue `generic.zig:1021-1062`) and posts `.redraw` to the apprt (`opengl/Frame.zig:~85`). Apprt calls `renderer.takeFrame()` (`generic.zig:1070`) on the main thread.
  - Health feedback: apprt -> `Surface.reportPresentationHealth` (`Surface.zig:961`) -> render thread mailbox `.presentation_health` (`Thread.zig:~400`) -> `renderer.setPresentationHealth` (`generic.zig:1203`); backend reads `renderer.presentationHealth()` to pick GPU-share vs CPU fallback.
- Display link / vsync: only macOS has one (`generic.zig:28-32`, `renderer/DisplayLink.zig`). `DisplayLink == void` elsewhere -> `hasVsync()` false (`generic.zig:1186`) -> `Thread.drawFrame` draws on every wakeup/timer (`Thread.zig:462-472`). Config `window-vsync` is only consumed by the display-link path (`generic.zig:1281`). A Windows backend gets NO pacing from generic; pacing must come from DXGI (Present interval / waitable swap chain) or the generic must gain a Windows "display link" (DwmFlush / waitable object thread) analogous to `DisplayLink.zig`. See Section 7.

### 1.4 Threading model (`Thread.zig`, `generic.zig`)
- One renderer thread per surface (`Thread.zig:221-234`): `loopEnter` (if declared) -> `threadEnter(surface)` -> libxev loop -> `threadExit` (deferred).
- `draw_mutex` (`generic.zig:112`) guards all draw state; `drawFrame(sync)` (`:1716`) takes it and calls `drawFrameLocked` (`:1740`). `sync == true` only from the Metal display-callback (main thread).
- GL creates the EGL context on the main thread in `init` and re-binds on the render thread in `threadEnter` (`OpenGL.zig:52-90,201`). A D3D11 backend has an easier job: the device is free-threaded; only the immediate context needs single-thread discipline.
- Frame ring: `SwapChain` (`generic.zig:305-360`) holds `swap_chain_count` `FrameState`s (own uniforms, cells buffers, atlas textures, target, optional custom shader textures). `nextFrame` blocks on a semaphore; `frameCompleted` posts it. If `Frame.complete` calls `frameCompleted` synchronously (GL does) the ring degenerates safely.
- Lifecycle hooks: `displayRealized()` (`:979`) sets `display_realized=true`, forces shader/target rebuild; `displayUnrealized()` (`:1005`) -> `releaseGpuResources()` (`:1244`) frees swap chain + shaders. `threadExit` also releases GPU objects *before* the API tears down (comment at `:1244`, `:914`). A D3D11 backend must tolerate being asked to rebuild everything (device lost, window re-created).

## 2. Shaders

### 2.1 Locations and embedding
- GLSL: `src/renderer/shaders/glsl/` (10 files, 776 LOC): `common.glsl` (156, `#version 430 core`, std140 `Globals` UBO at binding 1, unpack/linearize/contrast helpers), `full_screen.v.glsl` (24, `#version 330`, VertexID-based big triangle), `bg_color.f.glsl`, `cell_bg.f.glsl`, `cell_text.{v,f}.glsl`, `image.{v,f}.glsl`, `bg_image.{v,f}.glsl`.
- MSL: single file `src/renderer/shaders/shaders.metal` (853 LOC): entry points `full_screen_vertex`, `bg_color_fragment`, `bg_image_vertex/fragment`, `cell_bg_fragment`, `cell_text_vertex/fragment`, `image_vertex/fragment`.
- Shadertoy wrapper: `src/renderer/shaders/shadertoy_prefix.glsl` (52) + `test_shadertoy_{crt,focus,invalid}.glsl` (tests).
- GLSL is embedded at **comptime**: `opengl/shaders.zig:loadShaderCode` (`@embedFile` + a hand-rolled recursive `#include "..."` expander `processIncludes`, ~line 340-376; handles `#include` only at line starts). GLSL is compiled by the GL driver at runtime in `Pipeline.init` (`gl.Program.createVF`).
- MSL: compiled at BUILD time into `Ghostty.metallib` via `src/build/MetallibStep.zig` (xcrun; created at `SharedDeps.zig:138-143`, embedded as anonymous import `ghostty_metallib` at `SharedDeps.zig:503-506`); loaded in `metal/shaders.zig` with `newLibraryWithData`.
- D3D11 equivalent would sit between them: HLSL files `@embedFile`d (same `#include` trick available, or use D3DCompile's include handler) and compiled once per process (Section 7).

### 2.2 Pipelines (`opengl/shaders.zig:13-48`, `metal/shaders.zig:15-45`)
| name | vertex | fragment | step_fn | blending | draw |
|---|---|---|---|---|---|
| `bg_color` | full_screen | bg_color | per_vertex (no attrs) | off | tri x3 (`generic.zig:~1940`) |
| `cell_bg` | full_screen | cell_bg | per_vertex (no attrs) | on | tri x3 |
| `cell_text` | cell_text (attrs `CellText`) | cell_text | per_instance | on | tri_strip x4, instances = glyph count |
| `image` | image (attrs `Image`) | image | per_instance | on | tri_strip x4 per Kitty placement/overlay |
| `bg_image` | bg_image (attrs `BgImage`) | bg_image | per_instance | on | tri x3 (one instance) |
+ `post_pipelines[]`: user custom shaders, vertex = `full_screen`, fragment = converted shadertoy code, blending ON (default `PipelineDescription`; `opengl/shaders.zig:initPostPipeline`), tri x3.
Frame order (`generic.zig:1925-2040`): [bg_image OR bg_color] -> kitty below_bg -> cell_bg -> kitty below_text -> cell_text -> kitty above_text -> debug overlay (image pipeline) -> (optional) post passes ping-ponging `front_texture`/`back_texture`, last pass writes the frame `Target`.

### 2.3 Uniforms and buffer layouts
Global uniform struct `shaders.Uniforms` (extern, `opengl/shaders.zig:~116-175`, identical in Metal): `projection_matrix mat4` (CPU computes ortho2d with Y-DOWN pixel space, `generic.zig:2288`), `screen_size vec2`, `cell_size vec2`, `grid_size 2xu16` (packed into one uint), `grid_padding vec4`, `padding_extend` bitmask u32, `min_contrast f32`, `cursor_pos 2xu16`, `cursor_color 4xu8`, `bg_color 4xu8`, `bools` bitfield u32 (cursor_wide=1, use_display_p3=2, use_linear_blending=4, use_linear_correction=8). Offsets follow std140 which equals D3D cbuffer packing for this member order (float4 members land on 16-byte boundaries; no vec3 straddling). Add a comptime `@offsetOf` test when porting.
Vertex/instance attributes (comptime-reflected from Zig structs, location = field index):
- `CellText` (32 B stride): glyph_pos uvec2, glyph_size uvec2, bearings ivec2 (i16x2), grid_pos uvec2 (u16x2), color uvec4 (u8x4), atlas u8, bools u8 (packed). D3D11 formats: `R32G32_UINT`, `R32G32_UINT`, `R16G16_SINT`, `R16G16_UINT`, `R8G8B8A8_UINT`, `R8_UINT`, `R8_UINT`, all `PER_INSTANCE_DATA` step 1, all integer inputs (use `uint`/`int2` HLSL types).
- `Image` (f32x2, f32x2, f32x4, f32x2).
- `BgImage` (f32 opacity, u8 info bitfield: position 4b, fit 2b, repeat 1b).
- Storage buffer `bg_cells`: `uint[]` of packed RGBA8 per cell (binding 1): read in `cell_bg.f` (indexed `y*cols+x` from FragCoord) and `cell_text.v` (per instance). => D3D11 `StructuredBuffer<uint>` or `ByteAddressBuffer` SRV `t1`, visible to VS and PS. Created by `bgBufferOptions()` -> BIND_SHADER_RESOURCE + MISC_BUFFER_STRUCTURED (stride 4).
- Textures: cell_text uses `sampler2DRect`/`texture2d` with **pixel coordinates, nearest, clamp** for two atlases (grayscale R8, color BGRA8 sRGB); image/bg_image use normalized `sampler2D` linear clamp. D3D11: atlases -> `Texture2D.Load(int3(px,0))` (no sampler); images -> `SamplerState` linear/clamp (bg_image `repeat` is done with `mod` in the shader, not in the sampler).
- sRGB/linear logic lives in shader code (`linearize/unlinearize`, `use_linear_blending`, `use_linear_correction`); when linear blending is on, shaders output linear values and the RT format is `*_SRGB` so hardware encodes after blending.

### 2.4 Coordinate conventions (important for HLSL port)
- GL: framebuffer origin bottom-left, so GLSL needs `layout(origin_upper_left) in vec4 gl_FragCoord` (`cell_bg.f.glsl`, `bg_image.f.glsl`) and the apprt flips exported frames (`custom_shader_y_is_down = false`).
- Metal: top-left origin, `custom_shader_y_is_down = true`.
- D3D11 is top-left as well: `SV_Position` is already upper-left, NDC +Y up, texture row 0 is top. The same CPU projection matrix works unchanged. => Set `custom_shader_y_is_down = true`, no flip.

## 3. Custom shader (shadertoy) pipeline

Single file: `src/renderer/shadertoy.zig` (494 LOC).
Flow (`loadFromFile`, lines ~80-160):
1. Read user file (<=4 MB).
2. `glslFromShader` (`:~147`): prepend `@embedFile("shaders/shadertoy_prefix.glsl")` (`#version 430 core`; `layout(binding=1, std140) uniform Globals {iResolution, iTime, ..., iPalette[256], iBackgroundColor, ...}`; `layout(binding=0) uniform sampler2D iChannel0`; `main()` calls user `mainImage`). Uniform CPU mirror: `shadertoy.Uniforms` extern struct (`:14-47`, includes `palette: [256][4]f32`).
3. `spirvFromGlsl` (`:~163-215`): glslang C API via `pkg/glslang`; `GLSLANG_CLIENT_VULKAN`, `TARGET_VULKAN_1_2`, `SPV_1_5`, `default_version=100`, **stage fixed to FRAGMENT**, messages SPV|VULKAN rules.
4. Backend selection (`:~125-131`): `.glsl` -> `glslFromSpv` (GLSL 430, `:~264`) or `.msl` -> `mslFromSpv` (`:~244`, enables `MSL_ENABLE_DECORATION_BINDING` so the UBO stays at buffer index 1). Generic `spvCross()` helper (`:~278-345`) does parse -> create compiler -> options -> compile and returns an owned `[:0]u8`.
5. `generic.zig:882-890` passes `GraphicsAPI.custom_shader_target`; failures are logged and custom shaders silently dropped (`:884`-`:889`, and `initPostPipelines` swallows errors).

Build deps:
- `pkg/glslang/build.zig` (builds glslang static lib, MSVC-aware; `lib.root_module.addIncludePath(override)`; translate-c of `glslang_c_interface.h`), `pkg/glslang/{shader,program,init,main}.zig`.
- `pkg/spirv-cross/build.zig:45-90`: flags `-DSPIRV_CROSS_C_API_GLSL=1 -DSPIRV_CROSS_C_API_MSL=1` (lines ~44-46) and source list `spirv_cross.cpp, spirv_parser.cpp, spirv_cross_parsed_ir.cpp, spirv_cfg.cpp, spirv_cross_c.cpp, spirv_glsl.cpp, spirv_msl.cpp` (lines ~65-75). `pkg/spirv-cross/main.zig` just exposes the translate-c module `spirv_cross_c`. Upstream is fetched lazily by hash (`pkg/spirv-cross/build.zig.zon`, SPIRV-Cross tarball, version tag 13.1.1 of the wrapper). Both are wired in `SharedDeps.zig:357-395` (system-integration alternates exist) and declared in the root `build.zig.zon:86-87`.
- Both build scripts already handle `abi == .msvc` (no `linkLibCpp`), so the Windows/MSVC target is supported by the repo today (`src/build/Config.zig:105-118` defaults Windows to MSVC ABI).

**HLSL backend status: NOT compiled in.** `SPVC_BACKEND_HLSL` exists in the C header, but without `-DSPIRV_CROSS_C_API_HLSL=1` and `spirv_hlsl.cpp` the C API returns an error for that backend. Enabling = add the define and the `.cpp` to the lists in `pkg/spirv-cross/build.zig` (the SPIRV-Cross tarball contains `spirv_hlsl.cpp`; I could not open the Zig package cache to confirm the file list because `zig-pkg/` only holds aro/translate_c/uucode in this checkout, so verify when the first build fetches it). Then in `shadertoy.zig` add `Target.hlsl`, `hlslFromSpv` using `SPVC_BACKEND_HLSL` with `SPVC_COMPILER_OPTION_HLSL_SHADER_MODEL = 50` (D3DCompile `ps_5_0`), probably `HLSL_USE_ENTRY_POINT_NAME` off, and (if default emitted names clash) `spvc_compiler_hlsl_add_resource_binding` to force: UBO -> `b1`, `iChannel0` texture -> `t0`, its sampler -> `s0`. SPIRV-Cross HLSL splits a combined `sampler2D` into `Texture2D` + `SamplerState` pair named `_<name>_sampler`, bindings follow the SPIR-V `binding` decoration for both, which gives the right t0/s0/b1 defaults here.
Output must be fed to `D3DCompile` at runtime (user files are only known at runtime; no way around d3dcompiler for this path).

Open issues to test on day 1 (cheap, test files already exist: `test_shadertoy_crt.glsl` etc.):
- The prefix redeclares `layout(location = 0) in vec4 gl_FragCoord;` (prefix line ~50); verify SPIRV-Cross HLSL maps it to `SV_Position` (MSL path does something that works; HLSL may emit a plain `TEXCOORD0` input, in which case the built-in full-screen VS must output a matching float4 at the same semantic, or patch the prefix with `#ifdef`).
- Fragment-only SPIR-V: HLSL entry `main(SPIRV_Cross_Input) : SV_Target0`. The matching VS (`full_screen`) is hand-written and must expose that interface.
- The Vulkan-client glslang path rejects `gl_VertexID` and `sampler2DRect`, so the BUILTIN GLSL shaders cannot simply be run through the same function (see 7.3).

## 4. Textures, atlas, images, D3D11 mapping

### 4.1 Font atlas (`generic.zig:3677-3691`, `OpenGL.zig:410-433`, `Metal.zig:347-376`)
- Two atlases per frame state (grayscale `R8`, color `BGRA8` stored sRGB: GL `srgba`, Metal `bgra8unorm_srgb`). Square, power-of-2 growth (`atlas.size`).
- Upload path: when `atlas.modified` counter changes (`generic.zig:~1892-1905`), under shared `font_grid.lock`: if `atlas.size > texture.width` recreate via `api.initAtlasTexture`, then `texture.replaceRegion(0,0,size,size,data)` (whole atlas each time, each of 3 ring frames separately). D3D11: `R8_UNORM` and `B8G8R8A8_UNORM_SRGB`, DEFAULT usage, `UpdateSubresource` (full) — or DYNAMIC + `Map(WRITE_DISCARD)` for very large atlases. FL11_0 max 2D size 16384, ample.
- Atlas sampling is pixel-addressed nearest; with `Load()` no sampler state needed. Color atlas: shader assumes premultiplied *linear* values after sampling; using the `_SRGB` SRV format reproduces GL's `srgba` behaviour (hardware decode).

### 4.2 Kitty graphics and debug overlay (`src/renderer/image.zig`)
- CPU state machine: placements sorted by z (`kittyUpdate`, `:274`), Pending -> `upload` (`:778`) creates a `Texture` via `imageTextureOptions(.rgba, true)` (always sRGB RGBA8; data converted to RGBA8 by wuffs in `prepForUpload`), then `ready`; unload/replace states free textures.
- Draw (`:116-190`): one `Step` per placement with a fresh 1-element vertex buffer, textures `{img}`; `triangle_strip x4`. Overlay uses the same `image` pipeline (CPU z2d-rendered texture, `Overlay.zig`).
- D3D11: `R8G8B8A8_UNORM_SRGB`, IMMUTABLE or DEFAULT with initial data, linear clamp sampler. Image sampling of sRGB texture returns linear; the image fragment shader then conditionally re-encodes (`image.f.glsl`). Same code path -> same behaviour.

### 4.3 Background image (`generic.zig:2158 uploadBackgroundImage`, `prepBackgroundImage ~2060`, `updateBgImageBuffer :2312`)
- Decoded by wuffs (png/jpeg) on the CPU, same `Image.upload` texture path; per-frame `BgImage` instance buffer carries opacity + packed position/fit/repeat; the fragment shader does all layout math. Nothing special for D3D11.

### 4.4 Custom shader textures
- `CustomShaderState` (`generic.zig:490-600`): `front_texture`/`back_texture` created by `api.textureOptions()` (needs shader-read AND render-target usage; Metal uses BGRA8(sRGB if linear)). A `Sampler` from `samplerOptions()` (linear, clamp). Resized with the screen. D3D11: `B8G8R8A8_UNORM[_SRGB]` with `BIND_RENDER_TARGET | BIND_SHADER_RESOURCE`, need RTV + SRV per texture, `Texture` struct must hold both.

### 4.5 Feature assumptions vs D3D11 FL 11_0
Maps cleanly:
- Instancing with per-instance vertex data, `SV_VertexID`, triangle strip/list, no index buffer, no geometry/tessellation/compute.
- Structured/raw buffer SRVs in VS and PS (SM 5.0).
- sRGB render targets with hardware sRGB-correct blending (`B8G8R8A8_UNORM_SRGB` RTV).
- Premultiplied alpha blend state (ONE, INV_SRC_ALPHA), single-RT, no depth/stencil, no scissor/MSAA.
- `R8_UNORM`, `RGBA8/BGRA8 UNORM(_SRGB)` all mandatory at 11_0. Max texture 16384.
- Integer vertex attributes (all attributes are integer except Image/BgImage floats): `*_UINT/SINT` input layout formats; HLSL must declare `uint`/`int` inputs.
Needs workaround or care:
- Flip-model swap chains (`DXGI_SWAP_EFFECT_FLIP_*`, needed for low latency and `ALLOW_TEARING`) forbid `_SRGB` buffer formats: create the swap chain as `B8G8R8A8_UNORM` and render to an offscreen `B8G8R8A8_TYPELESS` (or separate `_SRGB`) texture, then `CopyResource`/draw-blit into the backbuffer. This matches the existing Target-then-present structure (render to `Target`, then present step), so it is cheap.
- No `R8_UNORM_SRGB` exists (Metal has `r8unorm_srgb` in `ImageTextureFormat.gray`); it is dead code in Ghostty (only `.rgba` used), safe to stub.
- `bgBufferOptions`/`fgBufferOptions` etc. must set different D3D11 bind flags; the generic code already routes through distinct names so no generic change needed.
- Buffer growth (`Buffer.sync` reallocation with 2x) must recreate the SRV too if it is a structured buffer.
- Dynamic buffers: `Map(WRITE_DISCARD)` for full resync; `WRITE_NO_OVERWRITE` is not needed. Partial `setSubData` semantics (leave tail untouched) is only used when data fits, so replacing contents wholesale is equivalent as long as the shader indexes only valid ranges (cells tail beyond `fg_count` is never read).
- Immediate context is single-threaded and shared per device: see Section 7.2.
- GPU completion tracking: D3D11 has no completion handler. `Frame.complete` can call `renderer.frameCompleted(health)` right after `Present`/`Flush` (as GL does); the runtime serializes resource hazards. Use `ID3D11Query(EVENT)` or `ID3D11Fence` only if true CPU/GPU overlap accounting becomes necessary. Device removed (`DXGI_ERROR_DEVICE_REMOVED/RESET`) from `Present` maps to `Health.unhealthy`.
- Pixel format for P3 (`window-colorspace = display-p3`): `use_display_p3` is just a bool in the uniforms; macOS sets the IOSurface colorspace. On Windows an equivalent would be `DXGI_COLOR_SPACE_*` on the swap chain (`IDXGISwapChain3::SetColorSpace1`); defer.

## 5. Apprt interaction

### 5.1 How OpenGL gets its surface (new design)
- App-scoped `Device` = EGL display + config (`opengl/Device.zig`), `EGL_PLATFORM_SURFACELESS_MESA` unless the apprt passes its own display (GTK passes the GDK Wayland/X11 EGL display via `renderDeviceOptions`, `src/apprt/gtk/class/surface.zig:1777-1800`).
- Per-surface `OpenGL.init` creates its own EGL context (`OpenGL.zig:52-90`); no window/surface binding at all. The Target is a texture-backed FBO (`opengl/Target.zig`).
- Present: dmabuf export (EGLImage) when healthy, else CPU readback into `ExportedFrame.Memory` (RGBA8 premultiplied). Pushed to the `latest_frame` slot and apprt is signalled with surface message `.redraw` (`opengl/Frame.zig`, `generic.zig:1021-1062`).
- GTK side (`src/apprt/gtk/class/render_surface.zig`): `snapshot()` (`:~145-210`) calls `core.renderer.takeFrame()` on the main thread, builds a `GdkTexture` (`rebuildTexture :307`, `rebuildMemoryTexture :390`), flips if `!custom_shader_y_is_down`, draws it in the GTK scene graph. Size flows the other way: `sizeAllocate -> emitDeviceResize -> signal resize` (`:~130,217-228`) -> core `Surface.sizeCallback` -> `Surface.resize` (`src/Surface.zig:2618-2650`) -> render thread mailbox `{resize = size}` (`:2641`) -> `Thread.zig:404` -> `renderer.setScreenSize` (`generic.zig:2249`) -> `api.setViewport`. `OpenGL.surfaceSize` then just reads back the GL viewport (`OpenGL.zig:217-228`), i.e. the size is renderer-owned state set by `setViewport`; the Target is lazily recreated inside `drawFrameLocked` when `frame.target.{width,height}` mismatch (`generic.zig:~1855-1870`).

### 5.2 How Metal gets its surface (the other model)
- `Metal.init` reads `opts.rt_surface.content_scale` and `opts.rt_surface.platform.macos.nsview` (`Metal.zig:70-98`; `apprt/embedded.zig:382-425` `Platform` union, `:452` `content_scale`), creates an `IOSurfaceLayer`, installs it as the NSView layer (layer-hosting). Sets `contentsScale`.
- `surfaceSize` = layer bounds x contentsScale clamped to `max_texture_size` (`Metal.zig:200-216`) - i.e. the API *pulls* size from the native view every draw.
- `present(target, sync)` hands the IOSurface to the layer from the GPU completion handler; `loopEnter` registers `displayCallback` so AppKit-driven display passes call `renderer.drawFrame(true)` synchronously on the main thread (resize live-drag).
- Embedded apprt resize entry: `ghostty_surface_set_size` (`embedded.zig:1996`) -> core `sizeCallback`; content scale: `ghostty_surface_set_content_scale` (`:2037`) -> `contentScaleCallback`.

### 5.3 What a Win32 apprt must provide
Either model works; recommended (Metal-like, "direct") needs:
1. `renderDeviceOptions()` on the apprt surface returning `D3D11.Device.Options` (e.g. adapter preference LUID / debug-layer flag); called once, first surface (`Surface.zig:565-568`).
2. In `rt_surface` (what `Options.rt_surface` points to): the `HWND` (and maybe `HINSTANCE`), current content scale (DPI/96), and a way to read client size in physical pixels without touching the message loop (`GetClientRect` is thread-safe enough; or atomics updated by `WM_SIZE`). Add a `Platform` variant like `windows: struct { hwnd }` mirroring `embedded.zig:382`.
3. Size notification: apprt calls core `Surface.sizeCallback(.{width,height})` on `WM_SIZE`/`WM_DPICHANGED` (same as GTK/embedded) so grid/pty are resized. The renderer discovers the new size through `setScreenSize` (CPU state) and `surfaceSize()`.
4. Redraw requests: core already posts `.redraw` to the apprt only for exported frames; for direct presentation nothing is needed (the render thread presents itself). `WM_PAINT` while resizing can be answered by simply validating the rect, or the apprt can request a synchronous draw (`renderer.drawFrame(true)` from the main thread behaves like Metal's `displayCallback`).
5. Optional: `displayRealized`/`displayUnrealized` equivalents when the HWND is re-created (tab tear-off, reparent) - generic already supports these (`generic.zig:979,1005`), currently called only by GTK (`class/surface.zig:3426,3446`).

### 5.4 Resize/present synchronization
- State touched on both threads is guarded by `draw_mutex`; `setScreenSize` and `drawFrameLocked` both take it, so a resize cannot interleave with a draw.
- Swap chain `ResizeBuffers` requires zero outstanding references to the backbuffer and must happen on the thread that owns the immediate context. Do it inside the API on the render thread: in `surfaceSize()`/`initTarget` or at the start of `Frame.begin` compare client size to swap chain size and resize, then continue. Generic's own per-frame `Target`s are separate offscreen textures, so only the final backbuffer needs resizing.
- During modal resize loops on Windows the main thread is blocked in `DefWindowProc`; the render thread keeps running independently, which is what we want. Present stretching (`DXGI_SCALING_STRETCH`) hides one-frame size mismatches; use `DXGI_SCALING_NONE` + `DXGI_ALPHA_MODE_PREMULTIPLIED` only with a composition (DirectComposition) swap chain.
- Transparency/blur (`background-opacity`, `background-blur`): HWND swap chains cannot have per-pixel alpha without `DXGI_SCALING_STRETCH` + DirectComposition (`CreateSwapChainForComposition` + `IDCompositionVisual`). Plan for DComp from the start if opacity is in scope (premultiplied alpha is already what the shaders output).

## 6. Size of existing backends (LOC, `wc -l`)
OpenGL: `OpenGL.zig` 449 + `opengl/` {buffer 126, Device 105, Frame 90, Pipeline 164, RenderPass 144, Sampler 45, shaders 376, Target 242, Texture 104} = 1396 -> **1845 LOC**. Plus `Dmabuf.zig` (shared export type) and `pkg/opengl/` thin GL/EGL binding (1658 LOC, not counted; for D3D11 the analogue is the COM binding package).
Metal: `Metal.zig` 387 + `metal/` {api 447 (hand-declared MTL enums/structs), buffer 185, Device 156, Frame 131, IOSurfaceLayer 187, Pipeline 204, RenderPass 229, Sampler 64, shaders 455, Target 108, Texture 202} = 2368 -> **2755 LOC**; plus `DisplayLink.zig` (macOS pacing).
Shaders: GLSL 776 LOC (10 files) / MSL 853 LOC (1 file). Shared `generic.zig` 3693 LOC, `shadertoy.zig` 494, `image.zig` ~850.
Estimate for D3D11: API struct ~450, Device (factory/adapter/caps/shader bytecode cache) ~200, Target+swapchain+present ~350, Pipeline (input layout reflection, blend/rasterizer states, shader create) ~250, RenderPass ~250, Buffer ~200, Texture ~150, Sampler ~60, Frame ~120, shaders.zig (types copied from GL + D3DCompile glue) ~400 => **~2.4k LOC Zig**; HLSL ~700-900 LOC (port of MSL, which is ~850); COM binding package (hand-rolled vtables for ~10 interfaces, ~700-1000 LOC, or translate-c of `d3d11.h/dxgi1_2.h/d3dcompiler.h` with `CINTERFACE`/`COBJMACROS`).

## 7. Recommendation

### 7.1 Files / types (mirror the Metal layout; Metal is the better template than GL)
```
src/renderer/D3D11.zig            API struct (init/deinit, surfaceSize, initTarget, present, *Options, beginFrame, ...)
src/renderer/d3d11/Device.zig     app-scoped: IDXGIFactory2, IDXGIAdapter1, feature level (>= 11_0), max_texture_size,
                                  compiled shader bytecode cache (blobs), optional warmup() hook (App.zig:100 supports it)
src/renderer/d3d11/Target.zig     offscreen RT texture (TYPELESS BGRA8) + RTV(_SRGB or UNORM per blending) + SRV; width/height
src/renderer/d3d11/Frame.zig      begin/renderPass/complete(sync): Flush, present, frameCompleted(health)
src/renderer/d3d11/RenderPass.zig Step -> IASetPrimitiveTopology/IASetVertexBuffers/VS+PSSetShaderResources/VS+PSSetConstantBuffers(1)/OMSetBlendState/DrawInstanced
src/renderer/d3d11/Pipeline.zig   VS+PS+ID3D11InputLayout (comptime reflect VertexAttributes like opengl/Pipeline.zig autoAttribute), blend state
src/renderer/d3d11/Buffer.zig     Buffer(T): role (vertex | structured SRV | constant), DYNAMIC + Map(WRITE_DISCARD)
src/renderer/d3d11/Texture.zig    ID3D11Texture2D + SRV (+RTV when render target); replaceRegion via UpdateSubresource(box)
src/renderer/d3d11/Sampler.zig    ID3D11SamplerState
src/renderer/d3d11/shaders.zig    Shaders collection (copy of opengl/shaders.zig structs: Uniforms, CellText, CellBg, Image, BgImage) + HLSL embedding/compile
src/renderer/shaders/hlsl/*.hlsl  common.hlsli, full_screen.vs, bg_color.ps, cell_bg.ps, cell_text.{vs,ps}, image.{vs,ps}, bg_image.{vs,ps}
pkg/d3d11/ (or pkg/win32-com/)    minimal COM/ABI bindings: d3d11, dxgi1_x, d3dcompiler (runtime LoadLibrary), optional DComp
```
Plus edits: `backend.zig` (`.d3d11`, default on Windows), `renderer.zig` switch, `shadertoy.zig` (`Target.hlsl`, `hlslFromSpv`), `pkg/spirv-cross/build.zig` (HLSL), `SharedDeps` (link `d3d11`, `dxgi`; Windows SDK libs already discoverable, see `GhosttyLib.zig:112-140`), root `build.zig.zon` if a new pkg is added, the Win32 apprt (`Platform.windows`).

### 7.2 Type mapping
| Ghostty concept | OpenGL | Metal | D3D11 |
|---|---|---|---|
| Device | EGL display+config | MTLDevice | `IDXGIFactory2`+adapter+LUID; per-surface `ID3D11Device` created from it |
| per-surface state | EGL context | MTLCommandQueue + CALayer | `ID3D11Device` + immediate ctx + `IDXGISwapChain1` (HWND or DComp) |
| Target | FBO+sRGB tex (+export tex) | IOSurface MTLTexture | `ID3D11Texture2D` (RT+SRV), RTV format = `B8G8R8A8_UNORM_SRGB` if `blending.isLinear()` else `_UNORM` (as Metal.zig:220-235) |
| Frame.complete | `glFinish`, export, push | commit + completion handler -> present | `ClearState/Flush`, `CopyResource` Target->backbuffer, `Present(interval,flags)`, `frameCompleted` |
| Pipeline | program+VAO | MTLRenderPipelineState | VS+PS+InputLayout+BlendState (static per pipeline) |
| Buffer | GL buffer | MTLBuffer | `ID3D11Buffer` (+SRV for structured) |
| Texture | GL texture | MTLTexture | `ID3D11Texture2D`+SRV(+RTV) |
| Sampler | GL sampler | MTLSamplerState | `ID3D11SamplerState` |
| vsync | n/a (apprt) | CVDisplayLink | `Present(1)` on render thread, or waitable swap chain / `DwmFlush` thread feeding `Thread.draw_now` |

Concurrency decision (needs the architect): D3D11 has ONE immediate context per device and Ghostty runs one render thread per surface.
- Option A (recommended): one `ID3D11Device` per surface, created from the shared adapter. Mirrors the GL "context per surface" pattern (`opengl/Device.zig` comment), no locking, a device-removed event only affects that surface. Cost: more GPU memory per surface, per-device shader object creation (cheap if bytecode is cached in `Device`).
- Option B: single shared device + `ID3D11Multithread::SetMultithreadProtected(TRUE)`. Less memory, but a vsync-blocking `Present` on one thread can stall others on the device lock.
Use `custom_shader_y_is_down = true`, `swap_chain_count = 3`.

### 7.3 Shader strategy
- Builtin pipelines: **hand-written HLSL, ported from `shaders.metal`** (same conventions, same uniform struct, same bool flags). Reasons: (1) the builtin GLSL cannot go through the existing glslang path unchanged - that path targets Vulkan GLSL, fragment stage only (`shadertoy.zig` `GLSLANG_CLIENT_VULKAN`, `stage FRAGMENT`), while the builtin sources use `gl_VertexID` (invalid for Vulkan; must be `gl_VertexIndex`), `sampler2DRect`, `origin_upper_left` redeclaration, std430 SSBOs, interface blocks, `#include`; (2) SPIRV-Cross-generated HLSL for `cell_text` is verbose and loses control over integer input semantics/packing; (3) total volume is small (~850 lines MSL). A hybrid is possible later (generate then hand-edit) but not needed.
- Custom shaders: SPIRV-Cross HLSL (enable backend as in Section 3), fragment only, paired with the hand-written `full_screen` VS; keep `Target.hlsl` string output and compile with `D3DCompile(ps_5_0)` at pipeline-init time. Reuse `shadertoy.Uniforms` unchanged as cbuffer b1 (size ~4.7 KB < 64 KB; `[256][4]f32` palette = 256 float4 registers, ok).
- Builtin compile timing: **runtime `D3DCompile` from `d3dcompiler_47.dll`** (in-box on Windows 10/11; load via `LoadLibraryW` + `GetProcAddress` to avoid an import library), executed ONCE per process in `Device.init` (or in a `Device.warmup` thread, hook exists at `App.zig:100`), cached as `ID3DBlob`s on the `Device` and reused for every surface's `CreateVertexShader/CreatePixelShader`. Compile with `D3DCOMPILE_OPTIMIZATION_LEVEL3` in release, `DEBUG|SKIP_OPTIMIZATION` in debug. Embedding HLSL via `@embedFile` keeps parity with GLSL (and `#include` can be handled by a D3DCompile include callback or the existing comptime `processIncludes` trick).
- Build-time fxc precompilation is a good phase-2 optimization (cuts startup ~50-150 ms and removes the runtime d3dcompiler need for builtins) but adds a Windows-only build step: `fxc.exe` ships in the Windows SDK (`std.zig.WindowsSdk.find` is already used in `GhosttyLib.zig:~122`), cross-compiling from Linux/macOS cannot run it, and fxc is legacy (no SM6). Provide a fallback path so both modes work; do not make the first milestone depend on it. Never `dxc`: D3D11 needs DXBC, not DXIL.

### 7.4 Bring-up order (suggested)
1. `pkg/d3d11` bindings + `D3D11.Device` + headless clear-to-color Target readback (CPU `Memory`-style) to validate the stack without an apprt.
2. HLSL for `bg_color`, `cell_bg`, `cell_text` + atlas textures; render and compare against OpenGL output with a readback test (OpenGL already has `readPixelsAlloc`; add a D3D11 twin to diff frames).
3. `image`, `bg_image`, overlay.
4. Win32 apprt integration: swap chain on HWND, resize, DPI, `presentation_health`.
5. Custom shaders (HLSL backend in spirv-cross) and post-process ping-pong.
6. DComp/opacity/blur, vsync pacing, tearing, P3/HDR (optional), imgui inspector.

### 7.5 Risks
1. **COM bindings**: nothing in the repo (no zigwin32 in `build.zig.zon`; `src/os/windows.zig` is a 378-line hand-rolled stub for kernel32-level APIs). Options: translate-c of Windows SDK headers via the existing `pkg/translate-c` infra (heavy `windows.h` transitive closure, unions/anonymous types, risk of translate-c failures on current Zig master) vs. hand-written vtable structs (error-prone slot order, but small surface) vs. importing zigwin32 (version coupling with a Zig that already uses `std.lang.Type`/`std.Io` new APIs). Needs an early spike.
2. **Immediate-context threading** (7.2) and `Present` blocking behaviour with per-surface render threads; DXGI also serializes swap chain creation/presentation on some drivers.
3. **Flip-model + sRGB + alpha**: wrong format choices cause washed-out or double-gamma output; test both `native` and `linear`/`linear-corrected` blending (`Config.zig:9878-9886`), since `use_linear_blending` flips both the RTV format and shader math, and `target_config_modified` forces target recreation on change (`generic.zig:2230-2240`).
4. **Transparency/blur** needs DirectComposition, which changes the swap chain creation path and apprt window styles; cheap if designed in early, a rewrite if retrofitted.
5. **No built-in frame pacing** on non-Mac: `hasVsync()` is false, so the render thread draws on every wakeup (cursor blink, output). Without `Present` blocking this can spin GPU; decide: blocking `Present(1)` on render thread (simple, but blocks the draw mutex for up to a frame and stalls `setScreenSize` callers waiting on `draw_mutex`) vs. waitable swap chain + generic hook analogous to `DisplayLink`. Note that generic holds `draw_mutex` across `Frame.complete` (and thus Present) so a blocking Present delays config/resize/font changes; prefer `Present` after releasing the lock or use `DXGI_PRESENT_DO_NOT_WAIT`/waitable object.
6. **SPIRV-Cross HLSL output quirks** for shadertoy prefix (`gl_FragCoord` redeclaration, array-of-vec3 `iPalette[256]` and `iChannelResolution[4]` in cbuffer: HLSL pads each element to 16 bytes, same as std140, so should match `shadertoy.Uniforms`, but verify with a layout test like the existing "custom shader selection uniform layout matches compiled GLSL" test at `shadertoy.zig:~395`).
7. **Device lost / TDR / adapter switch**: map `DXGI_ERROR_DEVICE_REMOVED` to `Health.unhealthy` and rebuild via the existing `displayUnrealized`+`displayRealized` path; per-surface device (Option A) simplifies this.
8. **Inspector (imgui)**: dcimgui is currently built with `backend-opengl3` on every non-Darwin target (`SharedDeps.zig:~595`); a Windows build needs `imgui_impl_dx11` + `imgui_impl_win32` wired into `pkg/dcimgui` and the apprt, independent of the terminal renderer.
9. **Hardcoded assumptions to review**: `OpenGL.zig:30` Y-up flag (not applicable), GL-only Windows 32-bit workaround comment at `OpenGL.zig:98`, `renderer/Overlay.zig`/`image.zig` import `Renderer.API` at comptime, so any missing decl in `D3D11.zig` surfaces as scattered compile errors; implement all decls in Section 1.3 up front (stubbing `present`, `setViewport`, `loopEnter`).
10. Could not run any build (no `zig` on PATH in this recon environment), so every claim about build behaviour (HLSL availability, MSVC handling) comes from reading `build.zig` files only.
