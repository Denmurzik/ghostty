#!/bin/bash
# ConPTY probe case. printf only, then park the shell so the window stays up.
printf '\033[2J\033[H'
printf '\033]9;probe-osc9-body\007'
printf 'PROBE osc9 sent\n'
exec sleep 600
