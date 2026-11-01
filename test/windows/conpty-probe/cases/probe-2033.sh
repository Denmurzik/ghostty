#!/bin/bash
# Headless ConPTY probe case (headless.ps1 -Visibility): mode 2033, the 998 DSR
# and the 2033 DECRQM between markers; GOT: is the first reply up to its `n`,
# GOT2: the next one up to `n`, GOT3: the DECRQM reply up to its `y`.
printf '<<vis'
printf '\e[?2033h'
printf '\e[?998n'
printf '\e[?2033$p'
printf 'vis>>\n'
read -rs -t 3 -d n r; printf 'GOT:%s\n' "$(printf %s "$r" | od -An -tx1)"
read -rs -t 2 -d n r; printf 'GOT2:%s\n' "$(printf %s "$r" | od -An -tx1)"
read -rs -t 2 -d y r; printf 'GOT3:%s\n' "$(printf %s "$r" | od -An -tx1)"
