#!/bin/bash
# vts: requires=T15 extra-config=background=#102030;background-opacity=0.8
# opacity: background-opacity = 0.8 (composition swap chain, alpha 204 in the dump): default-background cells are translucent, cells with an explicit background (SGR 44, SGR 7) stay opaque, text stays opaque.
printf '\e[2J\e[H\e[?25l'
printf 'opacity 0.8\n\n'
printf 'text over the translucent background\n'
printf '\e[44m highlighted cells \e[0m \e[7m inverse \e[0m \e[31mred\e[0m \e[32mgreen\e[0m \e[33myellow\e[0m\n'
for r in 1 2 3 4 5 6; do printf 'row %d: the quick brown fox jumps over the lazy dog\n' $r; done
echo done > "$VTS_DONE"
exec sleep 600
