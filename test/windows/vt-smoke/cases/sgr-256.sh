#!/bin/bash
# vts: requires=none extra-config=
# sgr-256: the 256-colour palette (SGR 38;5 / 48;5): system, 6x6x6 cube, grayscale.
printf '\e[2J\e[H\e[?25l'
printf 'sgr-256 system colours 0-15\n'
for i in $(seq 0 15); do printf '\e[48;5;%dm  \e[0m' $i; done; printf '\n\n'
printf 'cube 16-231\n'
for r in 0 1 2 3 4 5; do
  for g in 0 1 2 3 4 5; do
    for b in 0 1 2 3 4 5; do printf '\e[48;5;%dm \e[0m' $((16 + r * 36 + g * 6 + b)); done
    printf ' '
  done
  printf '\n'
done
printf '\ngrayscale 232-255\n'
for i in $(seq 232 255); do printf '\e[48;5;%dm  \e[0m' $i; done; printf '\n\n'
printf 'foreground\n'
for i in 16 52 88 124 160 196 202 208 214 220 226 190 154 118 82 46 47 48 49 50 51 45 39 33 27 21 57 93 129 165 201; do printf '\e[38;5;%dm#\e[0m' $i; done; printf '\n'
echo done > "$VTS_DONE"
exec sleep 600
