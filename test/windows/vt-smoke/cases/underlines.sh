#!/bin/bash
# vts: requires=none extra-config=
# underlines: SGR 4 styles (single, double, curly, dotted, dashed); coloured lines (SGR 58) are in underline-colors.
printf '\e[2J\e[H\e[?25l'
printf 'underlines\n\n'
printf '\e[4msingle\e[0m  \e[21mdouble (21)\e[0m  \e[4:2mdouble (4:2)\e[0m  \e[4:3mcurly\e[0m  \e[4:4mdotted\e[0m  \e[4:5mdashed\e[0m\n\n'
printf '\e[4:3;31mcurly with red fg\e[0m  \e[4;9munderline + strike\e[0m\n'
echo done > "$VTS_DONE"
exec sleep 600
