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
colors (SGR 58) need the bundled pair. Git Bash uses the console of Windows
by default, so it shows no images; "windows-conpty = bundled" changes that
but can lose typed input lines there (see the change log).

Files
-----
  Config:  %USERPROFILE%\.config\ghostty\config.ghostty
  Data:    %LOCALAPPDATA%\ghostty   (logs, crash dumps, update state)

Explorer integration (optional)
-------------------------------
  ghostty.exe +install-explorer-integration

adds "Open Ghostty here" (the classic menu, "Show more options" on
Windows 11) for the current user. Undo it with

  ghostty.exe +uninstall-explorer-integration --all --only-this-exe

If you used it from a portable copy, run the undo command BEFORE you delete
the folder.

Windows 11 top-level menu
-------------------------
Not included. Windows refuses to install an unsigned package for it
(error 0x80073D2B); it needs a code-signing certificate. The entry stays in
"Show more options" (Shift+F10).

tmux.exe
--------
tmux.exe is a small tmux compatible shim for programs that expect a tmux
command. It is OFF by default: panes get no TMUX variable and this folder
is not put in front of PATH. For Claude Code agent teams (teammateMode
"tmux") add to the config

  windows-tmux-shim = true

and open a new window. For the external tmux mode, put this folder on your
PATH.

Updates
-------
To turn off update checks, set

  auto-update = off

in the config. Download new versions from the releases page of the fork.

Changes
-------
The change log is docs\windows\CHANGELOG.md in the fork:

  https://github.com/Denmurzik/ghostty/blob/windows/docs/windows/CHANGELOG.md
