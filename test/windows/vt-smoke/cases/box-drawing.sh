#!/bin/bash
# vts: requires=none extra-config=
# box-drawing: Unicode box drawing (U+2500-257F), block elements (U+2580-259F) and braille.
printf '\e[2J\e[H\e[?25l'
printf 'box-drawing\n\n'
printf '┌──────┬──────┐ ╔══════╦══════╗ ╭──────┬──────╮\n'
printf '│ one  │ two  │ ║ one  ║ two  ║ │ one  │ two  │\n'
printf '├──────┼──────┤ ╠══════╬══════╣ ├──────┼──────┤\n'
printf '│ three│ four │ ║ three║ four ║ │ three│ four │\n'
printf '└──────┴──────┘ ╚══════╩══════╝ ╰──────┴──────╯\n\n'
printf '┏━━━┳━━━┓ ┍━┯━┑ ┎─┰─┒ ╒═╤═╕ ╓─╥─╖ ┌╌╌┬┄┄┐ ╱╲╳\n'
printf '┃ a ┃ b ┃ ┝━┿━┥ ┠─╂─┨ ╞═╪═╡ ╟─╫─╢ ┆  ┊┈┈┊ ╲╱╳\n'
printf '┗━━━┻━━━┛ ┕━┷━┙ ┖─┸─┚ ╘═╧═╛ ╙─╨─╜ └╌╌┴┄┄┘ ╴╵╶╷\n\n'
printf 'blocks: ▀▁▂▃▄▅▆▇█▉▊▋▌▍▎▏▐░▒▓▔▕▖▗▘▙▚▛▜▝▞▟\n'
printf 'shades: \e[32m░░▒▒▓▓██\e[0m \e[44;33m▀▀▄▄▌▌▐▐\e[0m\n'
printf 'braille: ⠁⠃⠇⡇⣇⣧⣷⣿ ⢀⣀⣤⣶⣿\n'
echo done > "$VTS_DONE"
exec sleep 600
