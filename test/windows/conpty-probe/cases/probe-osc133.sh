#!/bin/bash
# ConPTY probe case. printf only, then park the shell so the window stays up.
# A full prompt/command cycle: A prompt start, B prompt end, C output start, D finished (exit 0).
printf '\033[2J\033[H'
printf '\033]133;A\007PROMPT> \033]133;B\007'
printf '\033]133;C\007'
printf 'command output\n'
printf '\033]133;D;0\007'
printf 'PROBE osc133 sent\n'
exec sleep 600
