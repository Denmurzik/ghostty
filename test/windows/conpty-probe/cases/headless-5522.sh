#!/bin/bash
# Headless ConPTY probe case (headless.ps1 -Kitty5522): OSC 5522 and DECSET/DECRQM
# ?5522 between markers, then the reply the host writes to the input.
# Output: <<k5522 ... k5522>> (the escape sequences), then DECRQM:<hex> (the
# DECRQM reply), then MSG<n>:<hex> per OSC reply read up to its final `\`
# (`read -d '\'` drops the `\`), then GOT:<hex of all of them> .
b64() { printf '%s' "$1" | base64 | tr -d '\n'; }
ST='\033\'
mt=$(b64 'text/plain')
mh=$(b64 'text/html')
dt=$(b64 'probe-text')
dh=$(b64 '<b>probe-html</b>')
rq=$(b64 'text/plain .')
printf '<<k5522'
printf '\033[?5522h'
printf '\033[?5522$p'
printf '\033]5522;type=write'"$ST"
printf '\033]5522;type=wdata:mime=%s;%s' "$mt" "$dt"; printf "$ST"
printf '\033]5522;type=wdata:mime=%s;%s' "$mh" "$dh"; printf "$ST"
printf '\033]5522;type=wdata'"$ST"
printf '\033]5522;type=read;%s' "$rq"; printf "$ST"
printf 'k5522>>\n'

hex() { od -An -v -tx1 | tr -d ' \n'; }
d=
IFS= read -rs -t 3 -d y d
printf 'DECRQM:%s\n' "$(printf '%s' "$d" | hex)"
all=
n=0
while [ $n -lt 8 ]; do
    m=
    if ! IFS= read -rs -t 3 -d '\' m; then
        [ -z "$m" ] && break
    fi
    n=$((n + 1))
    all="$all$m"
    printf 'MSG%d:%s\n' "$n" "$(printf '%s' "$m" | hex)"
    case "$m" in *status=DONE*) break ;; esac
done
printf 'GOT:%s\n' "$(printf '%s' "$all" | hex)"
