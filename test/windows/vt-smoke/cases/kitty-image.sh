#!/bin/bash
# vts: requires=L1 extra-config=
# kitty-image: Kitty graphics, file transmission of the 16x16 fixture. The inbox ConPTY drops APC (lead decision L1),
# so this case SKIPs until a reference exists (provisional, owner-approved gap in docs/windows/feature-checklist.md).
printf '\e[2J\e[H\e[?25l'
printf 'kitty-image\n\n'
img=$(printf '%s' "@FIXTURES@/kitty-16.png" | base64 | tr -d '\n')
printf '\e_Ga=T,f=100,t=f,c=8,r=4;%s\e\\' "$img"
printf '\n\n\n\n\nimage above (8x4 cells)\n'
echo done > "$VTS_DONE"
exec sleep 600
