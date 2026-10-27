# vt-smoke

Screenshot checks of the terminal emulation on the Windows port. Each case in
`cases/<name>.sh` prints its escape sequences with `printf` in a fresh
`ghostty.exe`; the frame dump (`GHOSTTY_D3D11_DUMP`, the surface without window
chrome) is compared with `ref/<name>@<dpi>.png`.

```
powershell -NoProfile -File test/windows/vt-smoke.ps1 [-Only a,b] [-Update] [-Driver warp|hardware] [-EvidenceDir d]
```

Exit code: 0 all compared cases PASS (SKIPs allowed), 1 any FAIL, 2 the run
was skipped (locked desktop, busy desktop lock, no Git Bash). The run takes the
desktop lock (`%TEMP%\gui-e2e.lock`, `test/windows/README.md`).

## A case

```
#!/bin/bash
# vts: requires=<task|none> extra-config=<k=v;k=v>
printf '...'              # < 8 KiB, printf only: msys `cat` loses bytes
echo done > "$VTS_DONE"   # tells the harness the output is out
exec sleep 600
```

- `requires` names the task or decision that makes the case meaningful: `T5`
  font fallback, `T7` custom shaders, `T15` transparency, `L1` ConPTY
  passthrough (APC/Kitty graphics and SGR 58 do not survive the inbox ConPTY).
  A case with a requirement SKIPs until its reference PNG exists; generate it
  after the prerequisite landed with `-Only <case> -Update`.
- `extra-config` lines are appended to the case's config; `@FIXTURES@` (also in
  the script) is the `cases/` directory (`bg.png`, `kitty-16.png`).
- The harness writes the config (class `ghostty-vts-<hex>`, `font-size = 12`,
  `window-width = 100`, `window-height = 30`, `cursor-style-blink = false`, the
  embedded font, `command = direct:<Git Bash> --noprofile --norc <case>`, UTF-8
  locale), waits for `$VTS_DONE` and then for two equal dumps 300 ms apart.
  Cases hide the cursor (`CSI ? 25 l`) so the frame does not depend on focus.

## References

`ref/<case>@<dpi>.png` (dpi: 96 at 100 %, 168 at 175 %) are the dumps of the surface as it is rendered: 1685x1125 at 168 dpi, 1004x634 at 96 dpi,
WARP driver. A case without a reference for the current DPI SKIPs ("no reference for N dpi"); generate it with `-Only <case> -Update`.
They are the machine's own: another display scale gives a different size, which would be a FAIL ("size mismatch"), hence the DPI key; regenerate with `-Update`
there. `Compare-Image` accepts a per-channel difference of 24 on 99.5 % of the
pixels. A failing case keeps `vts-<case>.png` and `vts-<case>.diff.png` (red =
pixels over the tolerance) in `-EvidenceDir`.

`-Update` rewrites references; without `-Only` only `requires=none` cases are
written. Inspect every changed PNG before it is committed: a reference is only
as right as the screenshot looked.

`selftest.ps1` checks `Compare-Image` (identical, one changed pixel, size
mismatch) without starting Ghostty.
