#!/bin/bash
# ConPTY probe case. printf only (plus pauses), then park the shell so the
# window stays up. Tmux-wrapped (DCS passthrough) notifications and a plain
# control. Core allows one desktop notification per second, hence the pauses.
printf '\033Ptmux;\033\033]9;m4-dcs-bel\a\033\'
sleep 1.3
printf '\033Ptmux;\033\033]777;notify;m4;dcs-st\033\033\\033\'
sleep 1.3
# Same as above with the inner ST doubled the way tmux really requires.
printf '\033Ptmux;\033\033]777;notify;m4;dcs-st2\033\033\033\\033\'
sleep 1.3
printf '\033]9;m4-plain\a'
printf 'PROBE dcs-tmux sent\n'
exec sleep 600
