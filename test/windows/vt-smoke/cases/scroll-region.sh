#!/bin/bash
# vts: requires=none extra-config=
# scroll-region: DECSTBM margins with LF, SD (CSI T), IND and RI; text outside the region stays.
printf '\e[2J\e[H\e[?25l'
printf '\e[1;1Hscroll-region: header (outside, row 1)'
printf '\e[30;1Hfooter (outside, row 30)'
printf '\e[5;20r'
printf '\e[5;1H'
for i in $(seq 1 30); do printf 'line %02d inside region 5-20\n' $i; done
printf '\e[2T'
printf '\e[20;1H\eD'
printf '\e[5;1H\eM'
printf '\e[5;1Hrows 5-6: blank after SD 2, IND, RI (net two lines down)'
printf '\e[20;40Hrow 20: bottom margin'
printf '\e[r'
printf '\e[25;1Hmargins reset: row 25 text'
printf '\e[3;8r\e[8;50HDECSTBM 3-8: row 8, bottom margin'
printf '\e[8;50H\n\e[8;50Hscrolled by LF at the bottom margin'
printf '\e[r'
echo done > "$VTS_DONE"
exec sleep 600
