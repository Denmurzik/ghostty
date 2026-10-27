#!/bin/bash
# ConPTY probe case. printf only, then park the shell so the window stays up.
printf '\033[8;30;100t'
printf 'PROBE csi8 sent\n'
exec sleep 600
