# Composition spike (R10, M3 Task 8) — result

Machine: Windows 11 10.0.26300, 2880x1920 primary monitor, 120 Hz (8.33 ms frame), hardware D3D11.
"Transparency effects" setting during all runs: ON (`EnableTransparency=1`, read only, not changed).
OFF is the owner's manual check.

Spike: `main.zig` (exe), driven by `run.ps1` under the desktop lock. A full-monitor striped (red/green, 6 px)
backdrop window sits behind the test window, so transparency is measurable by pixel and every screenshot
contains only the spike's own windows. Swap-chain test pattern: left third opaque blue `#1020C0`, middle third
alpha 0, right third premultiplied white at alpha 128. Raw log lines: `evidence/results.txt`; shots: `evidence/*.png`.

## Verdict

| | Question | Verdict |
|---|---|---|
| a | child HWND + `CreateTargetForHwnd(child, TRUE)`, premultiplied composition chain created on a worker, `SetContent`+`Commit` on UI thread; present + `ResizeBuffers` on the worker | PASS |
| b | transparent client | `ext` (`DwmExtendFrameIntoClientArea(-1)` + `DWMSBT_NONE`) FAILS (opaque black). `DwmEnableBlurBehindWindow` empty region PASSES, provided the child erases itself with the black class brush |
| c | Acrylic (`DWMSBT_TRANSIENTWINDOW`) behind the transparent chain | PASS with Transparency effects ON |
| d | D2D DC-painted strip over the glass | PASS in blur and Acrylic; FAIL only in `ext`+NONE (black strip) |
| e | `SetParent` of the child | target SURVIVES, no re-creation needed |
| f | `PrintWindow` vs screen capture | PrintWindow includes the swap-chain content but not the backdrop |
| g | waitable pacing | same as hwnd mode |
| h | private bytes | DComp device +0.07..0.20 MB; target+visual below measurable |
| i | maximize, 1.5x rect, minimize/restore | PASS (blur and Acrylic) |
| j | hwnd chain -> composition -> hwnd on one child | PASS, no `WINDOW_ALREADY_COMPOSED`, no flash |
| k | `ALLOW_TEARING` on a composition chain | accepted |
| l | DComp device with null rendering device survives D3D device recreation | PASS |

## Details

**(a)** `CreateTargetForHwnd` hr=0x0 in every run. 300-frame windows, 0 present errors, 325-341 frames per run. Each of 3
window resizes caused exactly one `ResizeBuffers` on the worker, +70..+100 frames, 0 errors. While minimized the chain keeps
returning S_OK (frames +89..+122 per second, never `STATUS_OCCLUDED`): the renderer must throttle itself when minimized.
Second `CreateTargetForHwnd` on a child that already has a target: `0x88980800` (`WINDOW_ALREADY_COMPOSED`); release the old
target first.

**(b)** Recipe that works: `DwmEnableBlurBehindWindow(hwnd, {DWM_BB_ENABLE|DWM_BB_BLURREGION, fEnable=1, hRgnBlur=CreateRectRgn(0,0,-1,-1)})`
(alone, or together with `ext`), `DWMSBT_NONE`, and the child window class with `hbrBackground = BLACK_BRUSH` so the default
`WM_ERASEBKGND` clears the child area to alpha 0. Result: alpha-0 third shows the backdrop stripes (100% of sampled pixels),
alpha-128 third is white at 50% over the stripes (`#98E098`/`#E09898`), strip shows stripes behind the tab
(`evidence/transparent-blur-none-cb-idle.png`, `-maximized.png`).
- `ext` + `DWMSBT_NONE` (+- black child): the whole glass is opaque black (`#000000`), alpha-0 pixels show black
  (`transparent-ext-none-cb-idle.png`). Not usable for `background-opacity < 1`.
- Without the black erase (`WM_ERASEBKGND` returns 1, as in the first runs) the area under the child stays opaque white
  (`#FFFFFF`, the initial DWM surface) until the surface is re-allocated by a maximize or a `SetParent`
  (`evidence/transparent-blur-none-idle.png`). Task 15 must erase the child black.
- `WS_EX_NOREDIRECTIONBITMAP` on the child makes no difference (children have no own redirection surface).
- With the blur variant DWM draws no caption buttons; with `ext` it draws min/max/close (`transparent-ext-none-idle.png`).

**(c)** `blur`, `ext` and `both` + Acrylic all show the Acrylic material through alpha 0: middle third `#66661E`
(blurred red/green average, stripe sharpness 0.0 against 47.5 unblurred), half-alpha third `#B3B38F`, strip `#66661E`
(`transparent-blur-acrylic-cb-idle.png`, `transparent-ext-acrylic-cb-idle.png`, maximized shot too). Acrylic works with `ext`
(unlike plain NONE). Same after resize, maximize, 1.5x, restore.

**(d)** Tab fill exactly `#102030`, 628 bright text pixels in the tab, strip background shows backdrop/Acrylic, in idle and maximized.

**(e)** After `SetParent(child, B)` with no re-creation the composited content appears in B (pattern thirds intact, 183 frames
in 1.5 s, 0 errors) and keeps working after window A is destroyed and B resized
(`reparent-2-after-SetParent-in-B.png`, `reparent-4-A-destroyed-B-resized.png`). Task 15 need not recreate the target in
`tabReparented`; keep the probe result above in mind if it ever does.

**(f)** `PrintWindow(PW_RENDERFULLCONTENT)` captures the DComp content (blue left third `#1020C0`), but composes transparent
pixels over black (middle `#000000`, right `#808080`), i.e. it does not see the window behind. With Acrylic it matches the
screen capture (`#66661E`). Use screen-rect capture for transparency checks.

**(g)** 300 frames each, both chains alone in the same window, quiet machine (`results.txt`, `pacing`, last two runs; order
hwnd, comp, comp, hwnd): wait ms mean 8.10-8.12, p50 8.12-8.14, p95 8.18-8.19, max 8.21-8.34 for both modes; frame interval
8.33 ms. Difference below 0.03 ms. (Under load by other sessions the same runs gave mean 10.3-11.0, p95 23-25 for both modes.)

**(h)** Private bytes: baseline 5.70 MB; D3D11 device + factory +26.35 MB; DComp device (null rendering device) +0.07 / +0.20 MB;
1 target+visual +0.00; 16 targets+visuals on 8x8 children +0.00 MB (below page granularity, < 4 KB each). Swap chains: first
creation +4.85 MB (lazy driver state), later rounds +0.00..+0.02 for composition and hwnd alike (buffers are not private bytes).

**(i)** Blur and Acrylic: resize to 860x560, 700x450, 1000x640 (buffers resized on the worker, pattern correct each time);
maximized client 2733x1920; window rect x1.5; minimize 1 s then restore: pattern and transparency intact, presenting
(+47..+66 frames per 500 ms after restore).

**(j)** Three rounds of hwnd chain -> release -> `CreateTargetForHwnd` + composition chain -> release (the last round also
releases the DComp device) -> hwnd chain again, same child: every `CreateSwapChainForHwnd`/`CreateTargetForHwnd` hr=0x0, no
`WINDOW_ALREADY_COMPOSED`. A pixel sampler at the child centre (one sample per refresh, 8.33 ms, 636-693 samples, 3 runs): 0
off-colour samples across all switches (gaps of 50-114 ms between release and the next chain's first frame, so the last
frame stays on screen); control hole of 63 ms (child hidden) detected in every run (6-7 of 7-8 samples off), so the sampler
can see it. One run was sampled only every 27 ms (machine load); the other three are the evidence.

**(k)** `CheckFeatureSupport(PRESENT_ALLOW_TEARING)`=true. Composition chain created with `ALLOW_TEARING` and
`Present(0, DXGI_PRESENT_ALLOW_TEARING)`: accepted, 2784 presents in ~0.9 s, 0 errors, pattern visible. `Present(0,
ALLOW_TEARING)` on a chain created without the flag: `DXGI_ERROR_INVALID_CALL` (0x887A0001). A composition chain is always
composed by DWM, so the flag only removes the vsync block; Task 14 can keep or drop it, harmless either way.

**(l)** `DCompositionCreateDevice2(null, ...)` created before any D3D device; D3D device 1 and its chain released
(`CheckDeviceState` stays true); device 2 chain attached to the same visual with `SetContent`+`Commit`, then device 3 swapped
in while device 2 was destroyed: centre pixels `#102030` / `#20C030` / `#102030` as expected, 0 errors.

## For SPEC section 18 rulings

- Transparent client: blur-behind with empty region + black-erased child (not `ext`+NONE).
- Acrylic: `DWMSBT_TRANSIENTWINDOW` over the same transparent chain; works with `ext` too.
- Re-parenting: target survives `SetParent`; release a target before creating another for the same HWND.
- Mode switching on one child needs no special handling; keep the old swap chain until the new one has presented.
- Throttle the renderer when minimized; capture checks with the screen rect, not `PrintWindow`.
- `IDCompositionVisual` overloads (`SetOffsetX/Y`, `SetTransform`, `SetClip`) stay untyped: vtable order of the MSVC overloads not verified.

## Not run / caveats

- "Transparency effects" OFF: owner's manual check.
- DPI 144 is simulated by scaling the window rect (the process DPI does not change), as the dpi-sim scenario does.
- Single monitor/GPU; 120 Hz.
