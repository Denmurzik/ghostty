#!/bin/bash
# ConPTY probe case. printf only, then park the shell so the window stays up.
printf '\033[2J\033[H'
printf '\033]22;crosshair\033\'
printf 'PROBE osc22 sent\n'
exec sleep 600
