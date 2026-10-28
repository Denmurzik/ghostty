# Bundled ConPTY

`conpty.dll` and `OpenConsole.exe` from the NuGet package
`Microsoft.Windows.Console.ConPTY` 1.25.260930003
(https://www.nuget.org/packages/Microsoft.Windows.Console.ConPTY,
source https://github.com/microsoft/terminal), MIT license (see `LICENSE`).
All four files are Authenticode-signed by Microsoft Corporation.

The Windows build installs the pair for the target architecture next to
`ghostty.exe` (`src/build/GhosttyConpty.zig`; `-Dconpty-dir` overrides this
directory). Ghostty prefers it to the inbox ConPTY (`windows-conpty`),
because it forwards Kitty graphics and SGR 58. See
`test/windows/conpty-probe/RESULT.md`.

The binaries are committed because Zig's package manager cannot fetch a
`.nupkg` (`zig fetch` stops with `unknown file type`), and every build must
ship them without a separate download step.

| File | Package path | SHA-256 |
|---|---|---|
| `x64/conpty.dll` | `runtimes/win-x64/native/conpty.dll` | `feeef341d891643c62d30b6b07800bc70f0bc148f44cb8c3bee84aa557ae805a` |
| `x64/OpenConsole.exe` | `build/native/runtimes/x64/OpenConsole.exe` | `3d66b23d0a71bb8eed2b77edc8b9df9bf54ce6c8fb74c863a30e760997f80586` |
| `arm64/conpty.dll` | `runtimes/win-arm64/native/conpty.dll` | `151a02355227710c20c9f8f1eaf68ac4668aa09cdc921adc7ec661804d8eb1bf` |
| `arm64/OpenConsole.exe` | `build/native/runtimes/arm64/OpenConsole.exe` | `4313825a3ba634d113cc6ed3bc8ce735e3c19d360cecd985794787479469f91f` |

To update: unpack the new package, copy the four files to the same places,
update the version and the hashes here, and rerun
`test/windows/conpty-probe/headless.ps1 -DllDir vendor/conpty/x64`.
