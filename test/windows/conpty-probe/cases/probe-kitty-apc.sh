#!/bin/bash
# ConPTY probe case. printf only, then park the shell so the window stays up.
# Kitty graphics: transmit+display an 8x8 RGB image of solid #ff00ff over 16x4 cells; i=31 so the
# terminal answers (APC reply read by the shell, harmless).
printf '\033[2J\033[H'
# Second witness: a query (a=q) is always answered, so the terminal logs a graphics response.
printf '\033_Gi=32,s=1,v=1,a=q,t=d,f=24;AAAA\033\'
printf '\033_Ga=T,i=31,f=24,s=8,v=8,c=16,r=4;/wD//wD//wD//wD//wD//wD//wD//wD//wD//wD//wD//wD//wD//wD//wD//wD//wD//wD//wD//wD//wD//wD//wD//wD//wD//wD//wD//wD//wD//wD//wD//wD//wD//wD//wD//wD//wD//wD//wD//wD//wD//wD//wD//wD//wD//wD//wD//wD//wD//wD//wD//wD//wD//wD//wD//wD//wD//wD//wD//wD//wD//wD//wD//wD/\033\'
printf '\nPROBE kitty sent\n'
exec sleep 600
