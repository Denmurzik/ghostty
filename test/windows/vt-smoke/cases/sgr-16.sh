#!/bin/bash
# vts: requires=none extra-config=
# sgr-16: the 16 ANSI foreground and background colours (SGR 30-37, 40-47, 90-97, 100-107).
printf '\e[2J\e[H\e[?25l'
printf 'sgr-16 foreground normal / bright\n'
for i in 0 1 2 3 4 5 6 7; do printf '\e[%dm Fg%d \e[0m' $((30 + i)) $i; done; printf '\n'
for i in 0 1 2 3 4 5 6 7; do printf '\e[%dm Fg%d \e[0m' $((90 + i)) $((i + 8)); done; printf '\n\n'
printf 'background normal / bright\n'
for i in 0 1 2 3 4 5 6 7; do printf '\e[%dm Bg%d \e[0m' $((40 + i)) $i; done; printf '\n'
for i in 0 1 2 3 4 5 6 7; do printf '\e[%dm Bg%d \e[0m' $((100 + i)) $((i + 8)); done; printf '\n\n'
printf 'fg on bg\n'
for i in 0 1 2 3 4 5 6 7; do printf '\e[%d;%dm XY \e[0m' $((30 + i)) $((47 - i)); done; printf '\n'
for i in 0 1 2 3 4 5 6 7; do printf '\e[1;%d;%dm XY \e[0m' $((30 + i)) $((47 - i)); done; printf '\n'
echo done > "$VTS_DONE"
exec sleep 600
