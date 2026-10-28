# Ghostty {{VERSION}} (unofficial Windows port)

{{V1_LINE}}

An unofficial Windows build of the Ghostty terminal. It is not made or supported by the Ghostty project.

## Unsigned

Unsigned. Windows SmartScreen shows "Unknown publisher" (More info, then Run anyway). Not supported with Smart App Control on: Smart App Control blocks the setup and the exe outright, with no "Run anyway".

## Install

- `ghostty-{{VERSION}}-windows-x64-setup.exe` (or `-arm64-`) installs for the current user. No administrator rights are needed.
- Portable: unzip `ghostty-{{VERSION}}-windows-x64.zip` (or `-arm64`) anywhere and run `ghostty.exe`. Keep the folder together: it needs `share\`, `conpty.dll` and `OpenConsole.exe` next to it.
- `-symbols.zip` holds `ghostty.pdb` and `tmux.pdb` for crash dumps. You do not need it to run Ghostty.
- Verify a download against `SHA256SUMS.txt` below.

Tag: `{{TAG}}`

## Unit tests

{{TESTS}}

{{ARM64_LINE}}

## Bundled ConPTY

{{CONPTY}}

## SHA-256

```
{{SHA256SUMS}}
```
