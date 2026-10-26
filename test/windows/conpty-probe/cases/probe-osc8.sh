#!/bin/bash
# ConPTY probe case. printf only, then park the shell so the window stays up.
printf '\033[2J\033[H'
printf '\033]8;;https://example.com/probe\033\LINKLINKLINKLINKLINKLINKLINKLINKLINKLINK'
printf '\033]8;;\033\'
printf '\nPROBE osc8 sent\n'
exec sleep 600
