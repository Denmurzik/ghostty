#!/bin/bash
# vts: requires=M7-2 extra-config=
# symbols: symbols and emoji from the system faces (Segoe UI Symbol, Segoe UI Emoji), with a reference row of M.
printf '\e[2J\e[H\e[?25l'
printf 'symbols\n\n'
printf '\xe2\x8f\xba \xe2\x9c\x94 \xe2\x9a\xa0 \xe2\x9c\xbb \xe2\x9d\xaf \xe2\x86\x92\n'
printf '\xf0\x9f\x98\x80 \xf0\x9f\x91\x8d\n'
printf 'MMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMM\n'
echo done > "$VTS_DONE"
exec sleep 600
