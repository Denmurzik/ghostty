#!/bin/bash
# vts: requires=L1 extra-config=windows-conpty=bundled
# underline-colors: underline colour (SGR 58, semicolon and 256 forms) with every underline style. The inbox ConPTY
# drops or mangles SGR 58; the bundled one (`windows-conpty = bundled`, installed by every build) forwards it
# unchanged (conpty-probe/RESULT.md). GUI check PENDING: SKIPs until its reference is generated with
# `-Only underline-colors -Update`.
printf '\e[2J\e[H\e[?25l'
printf 'underline-colors\n\n'
printf '\e[4:1;58;2;255;0;0msingle red\e[0m  \e[4:2;58;2;0;255;0mdouble green\e[0m  \e[4:3;58;2;255;128;0mcurly orange\e[0m\n'
printf '\e[4:4;58;2;0;160;255mdotted blue\e[0m  \e[4:5;58;2;255;0;255mdashed magenta\e[0m  \e[4:3;58;5;196mcurly 256 red\e[0m\n\n'
printf '\e[4:3;58;2;0;255;0;31mcurly green line, red fg\e[0m  \e[4;58;2;255;255;0mplain 4 with yellow line\e[0m\n'
printf '\e[4:3;58;2;255;0;0mw\e[0m\e[4:3;58;2;255;0;0mi\e[0m\e[4:3;58;2;255;0;0mg\e[0m\e[4:3;58;2;255;0;0mg\e[0m\e[4:3;58;2;255;0;0ml\e[0m\e[4:3;58;2;255;0;0my\e[0m (one cell per run)\n'
echo done > "$VTS_DONE"
exec sleep 600
