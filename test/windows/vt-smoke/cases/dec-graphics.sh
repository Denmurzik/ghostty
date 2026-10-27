#!/bin/bash
# vts: requires=none extra-config=
# dec-graphics: DEC special graphics charset (ESC ( 0), G1 via SO/SI, back to ASCII (ESC ( B).
printf '\e[2J\e[H\e[?25l'
printf 'dec-graphics\n\n'
printf '\e(0lqqqqqqqqqqqqqqqqqk\e(B\n'
printf '\e(0x\e(B DEC special     \e(0x\e(B\n'
printf '\e(0tqqqqqqqqqqqqqqqqqu\e(B\n'
printf '\e(0x\e(B lqk mqj tuvwn   \e(0x\e(B\n'
printf '\e(0mqqqqqqqqqqqqqqqqqj\e(B\n\n'
printf 'all of 0x5f-0x7e: \e(0'
for i in $(seq 95 126); do printf "\x$(printf %x $i)"; done
printf '\e(B\n\n'
printf 'G1 via SO/SI: \e)0\x0elqqk\x0f back to ascii: lqqk\n'
printf 'ascii again after reset: \e(B lqqk\n'
echo done > "$VTS_DONE"
exec sleep 600
