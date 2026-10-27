#!/bin/bash
# vts: requires=none extra-config=
# alt-screen: ?1049 switches to the alternate screen and back; the main screen and cursor survive.
printf '\e[2J\e[H\e[?25l'
printf 'main screen line 1\n'
printf 'main screen line 2 (must survive the alternate screen)\n'
printf '\e[31mmain screen line 3 in red\e[0m\n'
printf 'cursor will be saved after this: '
printf '\e[?1049h\e[2J\e[H'
printf 'ALTERNATE SCREEN (must not be visible at the end)\n'
for r in 3 4 5 6 7 8; do printf '\e[%d;10Halt row %d ++++++++++++++' $r $r; done
printf '\e[?1049l'
printf 'back on main: cursor restored here\n'
printf 'second round: '
printf '\e[?1049h\e[2J\e[H\e[1;32mALT 2\e[0m'
printf '\e[?1049l'
printf 'main again, no alt text above\n'
echo done > "$VTS_DONE"
exec sleep 600
