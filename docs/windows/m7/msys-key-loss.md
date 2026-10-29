# MSYS first-key loss on the bundled ConPTY

Status: documented limit. `windows-conpty = auto` keeps MSYS2/Cygwin programs
(Git Bash) on the inbox console. Nothing here has been filed upstream.

## Environment

- Windows 11, 10.0.26300.
- Git for Windows `git version 2.55.0.windows.3`; MSYS runtime
  (`uname -r`) `3.6.9-b4195d69.x86_64`.
- Bundled `conpty.dll` / `OpenConsole.exe` 1.25.260930003 (`vendor/conpty`).

## Symptom

In Git Bash on the bundled console, input typed right after a resize (window
resize, split open/close, tab switch, tab strip appearing/disappearing) is
sometimes lost. Whole lines are lost: the command never runs.

## Measurements

G1 `resize-input` (`test/windows/e2e/resize-input.ps1`): after each trigger a
line is typed at 50 ms and 300 ms; a check fails when the file the line should
create does not exist ("the line did not run").

| Console | lost / checks |
|---|---|
| bundled, run 1 | 16/36 |
| bundled, run 2 | 14/36 |
| bundled, run 3 | 9/36 |
| inbox (default) | 0/48 |

Task 13 A/B (`.superpowers/sdd/M7-win2/task-13-report.md`): a test mode makes
Ghostty send win32-input-mode key records instead of VT keys.

| Variant | lost / checks |
|---|---|
| bundled, win32-input-mode | 10/36, 7/36, 10/36 |
| bundled, VT keys (control) | 10/36 |

Key encoding is not the cause. Ghostty's `resize_prime` (a Shift key-up before
the first write after a resize) was active in every run.

Windows Terminal (same OpenConsole family), checked by hand: Git Bash, resize
or split, then `echo abc` typed immediately, 20 tries, no loss.

Kitty on bundled: images render and the `a=q` reply reaches programs
(`kitty-render` 5/5 PASS, conpty-probe RESULT.md). On inbox the APC is dropped.
That is what a user gives up under `auto`.

## Hypotheses against the numbers

From `docs/windows/issues-after-v1.md` section 2a.3.

1. Key encoding (VT vs win32-input-mode) - ruled out: same loss with both.
2. Missing resize priming - ruled out: `resize_prime` active, loss unchanged.
3. `cons_master_thread` race in msys2-runtime while OpenConsole waits for a
   reply to `CSI 6 n` after a resize - consistent (inbox never sends it, loss
   is 0), not proven. No MSYS-side trace exists.
4. Ghostty's resize pattern differs from Windows Terminal's (open lead): e.g.
   the number of `ResizePseudoConsole` calls per drag, their timing relative
   to input. WT works with the same console and runtime, so something on our
   side matters. Not measured yet; the first thing to try if this is revisited
   (count and coalesce `ResizePseudoConsole` calls, then rerun G1).

## Decision

No switch. MSYS programs stay on the inbox console under `auto`. Users who
want Kitty graphics in Git Bash set `windows-conpty = bundled` and accept
occasionally lost input right after a resize/split/tab switch. This is stated
in the `windows-conpty` option docs.

## Bug report text (msys2-runtime / Cygwin, NOT filed)

Title: Console input lost after pseudo console resize with OpenConsole
1.25.260930003 (conpty.dll) hosting an MSYS2 program

Environment:
- Windows 11 10.0.26300
- Git for Windows 2.55.0.windows.3, bash from it, MSYS runtime 3.6.9
- Pseudo console: `conpty.dll` + `OpenConsole.exe` 1.25.260930003 (the Windows
  Terminal family), created with `CreatePseudoConsole`; the host is a
  terminal emulator that writes keys to the input pipe.

Repro:
1. Host creates a pseudo console and runs `bash.exe` (Git Bash) in it.
2. Host calls `ResizePseudoConsole` (window resize, split, tab switch).
3. Within 50-300 ms host writes `echo abc\r` (or `touch f\r`) to the input
   pipe.

Expected: the line runs, as with the inbox conhost (0 lost in 48 checks) and
in Windows Terminal (0 lost in 20 manual tries).

Actual: with the bundled OpenConsole the whole line is dropped in about 25-45%
of checks (7-16 of 36). Not dependent on the key encoding: identical loss
when the host sends win32-input-mode key records instead of VT bytes.

Observation: after a resize OpenConsole queries the cursor with `CSI 6 n` and
waits for the reply. Suspected race in msys2-runtime's `cons_master_thread`
(console input handling) between that reply/the resize event and the following
input records, so queued records are discarded. Unconfirmed; we have no
runtime-side trace.

Open question for the reporters: why does Windows Terminal not trigger it
with the same console and runtime (possibly different `ResizePseudoConsole`
cadence).
