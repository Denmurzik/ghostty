@echo off
rem Ghostty shell integration for cmd.exe: ssh through `ghostty +ssh`
rem (features ssh-env and ssh-terminfo from GHOSTTY_SHELL_FEATURES).
rem Its directory is first on PATH only when one of them is on.
setlocal
rem Not again: ghostty +ssh finds `ssh` on PATH, and this directory is first.
set "GHOSTTY_SSH_SELF=%~dp0"
set "GHOSTTY_SSH_SELF=%GHOSTTY_SSH_SELF:~0,-1%"
call set "PATH=%%PATH:%GHOSTTY_SSH_SELF%;=%%"
set "GHOSTTY_SSH_FLAGS="
if not defined GHOSTTY_BIN_DIR goto :plain
if not exist "%GHOSTTY_BIN_DIR%\ghostty.exe" goto :plain
echo %GHOSTTY_SHELL_FEATURES%| findstr /c:"ssh-env" >nul || set "GHOSTTY_SSH_FLAGS=--forward-env=false"
echo %GHOSTTY_SHELL_FEATURES%| findstr /c:"ssh-terminfo" >nul || set "GHOSTTY_SSH_FLAGS=%GHOSTTY_SSH_FLAGS% --terminfo=false"
start "" /b /wait "%GHOSTTY_BIN_DIR%\ghostty.exe" +ssh %GHOSTTY_SSH_FLAGS% -- %*
exit /b %errorlevel%

:plain
rem No ghostty.exe: the real ssh.exe (not this script).
ssh.exe %*
exit /b %errorlevel%
