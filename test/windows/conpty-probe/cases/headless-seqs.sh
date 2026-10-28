#!/bin/bash
# Headless ConPTY probe case (headless.ps1). printf only. Every sequence sits
# between text markers `<<name` and `name>>` so the host can cut the raw
# ConPTY output into one slice per sequence.
printf '\033[2J\033[H'
printf '<<apc'
printf '\033_Gi=32,s=1,v=1,a=q,t=d,f=24;AAAA\033\\'
printf '\033_Ga=T,i=31,f=24,s=2,v=1,c=4,r=2;/wD//wD/\033\\'
printf 'apc>>\r\n'
printf '<<sgr58'
printf '\033[4:3;58:2::255:0:0mU1\033[0m'
printf '\033[4;58;5;196mU2\033[0m'
printf '\033[4:1;58;2;0;255;0mU3\033[0m'
printf 'sgr58>>\r\n'
printf '<<osc133'
printf '\033]133;A\007P> \033]133;B\007'
printf '\033]133;C\007out\033]133;D;0\007'
printf 'osc133>>\r\n'
printf '<<osc7'
printf '\033]7;file://probehost/c/probe/dir\033\\'
printf 'osc7>>\r\n'
printf '<<osc8'
printf '\033]8;;https://example.com/probe\033\\LINK\033]8;;\033\\'
printf 'osc8>>\r\n'
printf '<<osc52'
printf '\033]52;c;cHJvYmU=\007'
printf 'osc52>>\r\n'
printf '<<osc9'
printf '\033]9;probe-note\007'
printf 'osc9>>\r\n'
# Width of a ZWJ emoji as the pseudo console sees it: the cursor report after
# it says who answered (the host answers a forwarded query with 24;77) and
# which column the console thinks the cursor is on.
printf '<<dsr\r\n'
printf '\360\237\221\251\342\200\215\360\237\222\273'
printf '\033[6n'
IFS= read -r -s -d R -t 3 rep
printf '\r\nDSR=%q\r\n' "$rep"
printf 'dsr>>\r\n'
printf 'READY-RESIZE\r\n'
# The host resizes the pseudo console to 100x30, then sends a line.
IFS= read -r -t 20 line
printf '<<size[%s]' "$line"
stty size
printf 'size>>\r\n'
printf 'PROBE-DONE\r\n'
sleep 1
