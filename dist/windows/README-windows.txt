Ghostty for Windows (unofficial port)
====================================

This is an unofficial Windows port of the Ghostty terminal. It is not made
or supported by the Ghostty project.

  https://github.com/Denmurzik/ghostty

THIS BUILD IS UNSIGNED
----------------------
There is no code-signing certificate yet.

  * Smart App Control (SAC) blocks unsigned programs. This build is not
    supported with SAC turned on.
  * SmartScreen may warn on the first start: click "More info", then
    "Run anyway".

Portable use
------------
Unzip the folder anywhere and run ghostty.exe from it. ghostty.exe needs
these next to it, so keep the folder together:

  share\            themes, shell integration, terminfo
  conpty.dll        the bundled console host (Microsoft, MIT license)
  OpenConsole.exe   the process conpty.dll starts for each terminal

Without conpty.dll and OpenConsole.exe, set "windows-conpty = inbox" in the
config to use the console of Windows itself. Kitty graphics and underline
colors (SGR 58) need the bundled pair.

Files
-----
  Config:  %USERPROFILE%\.config\ghostty\config.ghostty
  Data:    %LOCALAPPDATA%\ghostty   (logs, crash dumps, update state)

Explorer integration (optional)
-------------------------------
  ghostty.exe +install-explorer-integration

adds "Open Ghostty here" to Explorer for the current user. Undo it with

  ghostty.exe +uninstall-explorer-integration --all --only-this-exe

If you used it from a portable copy, run the undo command BEFORE you delete
the folder.

tmux.exe
--------
tmux.exe is a small tmux compatible shim for programs that expect a tmux
command, for example Claude Code agent teams. For the external tmux mode,
put this folder on your PATH.

Updates
-------
To turn off update checks, set

  auto-update = off

in the config. Download new versions from the releases page of the fork.

Changes
-------
The change log is docs\windows\CHANGELOG.md in the fork:

  https://github.com/Denmurzik/ghostty/blob/windows/docs/windows/CHANGELOG.md
