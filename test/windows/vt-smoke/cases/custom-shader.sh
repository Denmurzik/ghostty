#!/bin/bash
# vts: requires=T7 extra-config=custom-shader=@FIXTURES@/../shaders/invert.glsl
# custom-shader: the invert shader (shaders/invert.glsl) is applied to the whole terminal surface.
printf '\e[2J\e[H\e[?25l'
printf 'custom shader: invert\n'
printf '\e[31mred\e[0m \e[32mgreen\e[0m \e[34mblue\e[0m\n'
printf '\e[1;37;44m white on blue \e[0m\n'
echo done > "$VTS_DONE"
exec sleep 600
