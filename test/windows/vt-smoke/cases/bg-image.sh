#!/bin/bash
# vts: requires=none extra-config=background-image=@FIXTURES@/bg.png
# bg-image: text over a background image (fixture bg.png).
printf '\e[2J\e[H\e[?25l'
printf 'bg-image\n\n'
printf 'text over the background image\n'
printf '\e[44m highlighted cells \e[0m \e[7m inverse \e[0m \e[31mred\e[0m \e[32mgreen\e[0m \e[33myellow\e[0m\n'
for r in 1 2 3 4 5 6 7 8; do printf 'row %d: the quick brown fox jumps over the lazy dog\n' $r; done
echo done > "$VTS_DONE"
exec sleep 600
