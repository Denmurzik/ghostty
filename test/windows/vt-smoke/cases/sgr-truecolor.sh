#!/bin/bash
# vts: requires=none extra-config=
# sgr-truecolor: 24-bit colour ramps (SGR 38;2 / 48;2) and the colon form.
printf '\e[2J\e[H\e[?25l'
printf 'sgr-truecolor\n'
for row in red green blue gray; do
  for i in $(seq 0 3 255); do
    case $row in
      red) c="$i;0;0" ;;
      green) c="0;$i;0" ;;
      blue) c="0;0;$i" ;;
      gray) c="$i;$i;$i" ;;
    esac
    printf '\e[48;2;%sm \e[0m' "$c"
  done
  printf '\n'
done
printf '\nhue sweep\n'
for i in $(seq 0 3 255); do printf '\e[48;2;%d;%d;%dm \e[0m' $((255 - i)) $i $(((i * 2) % 256)); done; printf '\n'
for i in $(seq 0 3 255); do printf '\e[48;2;%d;%d;%dm \e[0m' $i $(((i * 3) % 256)) $((255 - i)); done; printf '\n\n'
printf '\e[38;2;255;128;0mfg orange\e[0m \e[38;2;0;200;255mfg cyan\e[0m \e[38;2;255;255;255;48;2;128;0;128m white on purple\e[0m\n'
printf '\e[38:2::255:105:180mcolon form fg pink\e[0m \e[48:2::0:100:0m colon form bg green \e[0m\n'
echo done > "$VTS_DONE"
exec sleep 600
