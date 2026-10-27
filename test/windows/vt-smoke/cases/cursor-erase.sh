#!/bin/bash
# vts: requires=none extra-config=
# cursor-erase: CUP/CUU/CUD/CUF/CUB/CHA, ED, EL, ECH, ICH, DCH, IL, DL, save/restore cursor.
printf '\e[2J\e[H\e[?25l'
for r in 1 2 3 4 5 6 7 8 9 10 11 12; do printf '\e[%d;1H%02d ############################################' $r $r; done
printf '\e[1;1HCUP home: top-left'
printf '\e[3;10H\e[0KEL 0: erase to end of line'
printf '\e[4;20H\e[1KEL 1: erase to start (this text stays)'
printf '\e[5;1H\e[2KEL 2: whole line erased, then this text'
printf '\e[6;10H\e[5XECH 5'
printf '\e[7;10H\e[4@ICH 4'
printf '\e[8;10H\e[4PDCH 4'
printf '\e[10;1H\e[LIL: line inserted above row 10'
printf '\e[13;1H\e[M'
printf '\e[15;5HA\e[2CB\e[3DC\e[2AD\e[3BE\e[40GF'
printf '\e7\e[18;30HSaved cursor, moved here\e8 restored'
printf '\e[20;1H\e[J'
printf '\e[19;1HED 0 below this line'
printf '\e[22;1H'
printf 'cursor-erase end'
echo done > "$VTS_DONE"
exec sleep 600
