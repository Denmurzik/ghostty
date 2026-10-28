# M4 acceptance record

Commit under test: `019c5031b` (`windows`), ReleaseFast build for the budget rows and the real Claude runs, Debug build
for the Debug e2e pass. Real Claude Code 2.1.312 (`sonnet`, the owner's shared login), 2026-10-28. Source: the Task 15
report (`.superpowers/sdd/M4-tmux-shim/task-15-report.md`), the CHANGELOG "M4" section, SPEC §17 M4 and the M4 final
review (`docs/windows/m4/final-review.md`).

Status: **done, accepted with pending**:

- `E2E -Milestone all` has not run yet. It goes into the next quiet-desktop batch.
- The owner's manual checks (exit checklist 8) are open, among them `load-buffer -w` with a text clipboard.

One budget row misses its goal: `display-message` p95 32.2 ms against 30 ms. The ledger accepts it (the process-creation
floor is about 21 ms).

## Exit checklist (plan `docs/windows/plans/M4-tmux-shim.md`, "M4 exit checklist")

| # | Item | Result | Evidence |
|---|---|---|---|
| 1 | Builds and unit tests | PASS | ReleaseFast, `-Demit-lib-vt`, Linux recipe and aarch64-windows-gnu build. `test-tmux-shim` 33/33; `tmux shim ` 106/107 (1 skip); `win32 tmux ` 159/160 (1 skip) and exit 0 twice more; `SplitTree` 104/105; `stream: tmux` 73/73; `win32 ipc` 104/105. The final review reran the filters at `019c5031b`: all PASS. |
| 2 | e2e | PASS for M4, **pending for `all`** | `E2E -Milestone M4` is 5 of 5 on Debug and on ReleaseFast: `tmux-cli`, `tmux-env`, `tmux-replay`, `tmux-send-keys`, `tmux-labels`. Earlier failures were load or concurrent installs into `zig-out`. `E2E -Milestone all` was not run (time, shared machine). |
| 3 | Leader typing | PASS | `tmux-replay` leader typing 7 of 7 lines across the layout changes. |
| 4 | Real run | PASS | The agent-team run passed twice in a row in a ReleaseFast Ghostty: 3 panes, leader 621 of 2073 px = 30.0 %, panes titled alpha/beta, inbox messages from both teammates, only the leader after `/exit`, no stray processes, trace shapes equal to the fixture. The recon is updated. |
| 5 | Budgets | PASS with one concern | `tmux.exe` peak private 0.6 MB (`load-buffer` at the 512 KiB cap 3.9 MB, `__idle` 0.5 MB). One surface 72.0 MB against 72.1 MB for the M3 build measured the same day (+0.0). Team layout 84.1 MB; 30 s after killing it 78.2 MB (+5.9 %). `tmux.exe` wall p95: `display-message` **32.2 ms (goal 30; concern)**, `split-window` 35.5 ms, `respawn-pane -k` 114.6 ms (gates 300 ms). Key echo median of 6 interleaved runs 2.14 ms against 1.63 ms (+0.5 ms, within noise). |
| 6 | Feature checklist | PASS | M4 rows have evidence; the owner check of the `load-buffer -w` row is pending. |
| 7 | SPEC | PASS | §2, §10, §12.1/12.2/12.4, §17 and §18 item 35 are amended. The wording points of the final review (its M5) were fixed in the fix round. |
| 8 | Owner manual checks | **PENDING** | See below. |
| 9 | Changelog | PASS | CHANGELOG "M4": the `windows-tmux-shim` key and the known gaps. |

## Pending for the owner (exit checklist 8)

Each line is PASS / FAIL once the owner has run it.

- [ ] In the daily Ghostty, with `teammateMode: "tmux"` in the owner's own settings, a real team of 2 or 3 teammates
  opens splits, titles and labels, and closes cleanly.
- [ ] Typing in the leader while teammates spawn loses no keys.
- [ ] With `windows-tmux-shim = false`, a user MSYS2 tmux works as before.
- [ ] Without Claude: `tmux split-window -h` and `tmux kill-pane` from Git Bash behave like Ghostty splits.
- [ ] `load-buffer -w -` with a text clipboard sets the Windows clipboard (`tmux-replay` skips these steps while the
  clipboard holds non-text). With `clipboard-write = deny` the buffer is kept and the clipboard is left alone.

## Final review

`docs/windows/m4/final-review.md`: READY_WITH_FIXES. The fix round (output and queue caps, privacy of the fixtures, this
record, the five minors) is in the branch `sdd/task-m4-final-fix`. Left to the owner: the pushed history still holds the
unsanitised fixture of commit `946b48316` (user name, private plugin names, a session id); a rewrite is destructive and
is not done without them.

## Known gaps

As in the CHANGELOG "M4": external mode, `new-session`/`attach`, `select-layout` beyond main-vertical/tiled,
`capture-pane` of the visible screen only, the DCS `tmux;` gap in ConPTY, images disabled under `TMUX`, the
`wait-after-command` reload gap, the `__idle` pane after a client timeout, the `send-keys` gate.
