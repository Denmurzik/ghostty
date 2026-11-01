#!/bin/bash
# vts: requires=L1 extra-config=windows-conpty=bundled
# kitty-anim: a looping Kitty animation, 1x1 pixel frames stretched over 8x4 cells at row 0, col 0: frame 1 magenta (#ff00ff),
# frame 2 green (#00ff00), 100 ms each (a=f adds frame 2, a=a r=1 z=100 gives the root frame its gap, a=a s=3 v=1 runs it forever).
# Used by e2e/hidden-render.ps1 and measure-ram.ps1 (hidden-anim), and for a manual look. The frame changes with time, so there is
# no reference PNG: the vt-smoke run SKIPs it (requires=L1 without a reference).
# KITTY_ANIM_ONCE=<file>: only the first shell that finds the file missing plays; later ones (new tabs) just sleep.
if [ -n "${KITTY_ANIM_ONCE:-}" ]; then
    [ -e "$KITTY_ANIM_ONCE" ] && exec sleep 600
    : > "$KITTY_ANIM_ONCE"
fi
printf '\e[2J\e[H\e[?25l'
printf '\e_Ga=T,i=1,f=24,s=1,v=1,c=8,r=4,q=2;/wD/\e\'
printf '\e_Ga=f,i=1,f=24,s=1,v=1,z=100,q=2;AP8A\e\'
printf '\e_Ga=a,i=1,r=1,z=100,q=2\e\'
printf '\e_Ga=a,i=1,s=3,v=1,q=2\e\'
printf '\n\n\n\n\nanimation above (8x4 cells, magenta/green)\n'
[ -n "${VTS_DONE:-}" ] && echo done > "$VTS_DONE"
exec sleep 600
