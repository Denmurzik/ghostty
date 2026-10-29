#!/bin/bash
# Headless ConPTY probe case (headless.ps1 -KittyQ): send a Kitty graphics
# query, then read what arrives on the input until the reply's final `\`
# (or 2 s), and print its hex as `GOT:<hex>`.
printf '\033_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\033\'
got=
IFS= read -rs -t 2 -d '\' got
printf '\nGOT:%s\n' "$(printf '%s' "$got" | od -An -v -tx1 | tr -d ' \n')"
