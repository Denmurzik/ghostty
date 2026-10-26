#!/bin/bash
# ConPTY probe case. printf only, then park the shell so the window stays up.
printf '\033[2J\033[H'
printf '\033]777;notify;probe-title;probe-osc777-body\007'
printf 'PROBE osc777 sent\n'
exec sleep 600
