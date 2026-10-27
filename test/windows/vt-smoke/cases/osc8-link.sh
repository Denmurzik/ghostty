#!/bin/bash
# vts: requires=none extra-config=
# osc8-link: OSC 8 hyperlinks (ST and BEL terminators, id parameter, empty URI closes). The static frame shows the
# link text as plain text with no stray escape bytes; the hover underline is not part of the frame.
printf '\e[2J\e[H\e[?25l'
printf 'osc8-link\n\n'
printf 'a \e]8;;https://example.com/one\e\\link one\e]8;;\e\\ in a line\n'
printf 'a \e]8;id=x;https://example.com/two\a link two (BEL)\e]8;;\a in a line\n'
printf '\e]8;;file:///C:/Windows\e\\\e[1;34mstyled link\e[0m\e]8;;\e\\ after\n'
printf 'adjacent: \e]8;;https://a.example\e\\AAA\e]8;;https://b.example\e\\BBB\e]8;;\e\\ end\n'
printf 'plain url (not OSC 8): https://example.com/plain\n'
echo done > "$VTS_DONE"
exec sleep 600
