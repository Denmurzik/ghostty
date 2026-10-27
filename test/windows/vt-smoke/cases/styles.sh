#!/bin/bash
# vts: requires=none extra-config=
# styles: bold, dim, italic, inverse, invisible, strikethrough, overline and combinations.
printf '\e[2J\e[H\e[?25l'
printf 'styles\n\n'
printf 'normal \e[1mbold\e[0m \e[2mdim\e[0m \e[3mitalic\e[0m \e[1;3mbold-italic\e[0m\n'
printf '\e[7minverse\e[0m \e[8minvisible\e[0m(<- hidden) \e[9mstrikethrough\e[0m \e[53moverline\e[0m\n'
printf '\e[4munderline\e[0m \e[1;4mbold underline\e[0m \e[3;9mitalic strike\e[0m \e[7;1mbold inverse\e[0m\n\n'
printf '\e[31;1mbold red\e[0m \e[32;2mdim green\e[0m \e[34;3mitalic blue\e[0m \e[33;7minverse yellow\e[0m\n'
printf '\e[41;37mwhite on red\e[0m \e[7;41;37minverse of that\e[0m \e[1;9;53mbold strike overline\e[0m\n\n'
printf 'reset in the middle: \e[1;3;4;9mall\e[22m no-bold\e[23m no-italic\e[24m no-underline\e[29m no-strike\e[0m done\n'
echo done > "$VTS_DONE"
exec sleep 600
