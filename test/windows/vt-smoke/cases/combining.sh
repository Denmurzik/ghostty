#!/bin/bash
# vts: requires=none extra-config=
# combining: combining marks, stacked marks, variation selectors and the cell widths they keep.
printf '\e[2J\e[H\e[?25l'
printf 'combining\n\n'
printf 'precomposed: é ñ ü å\n'
printf 'combining:   e\xcc\x81 n\xcc\x83 u\xcc\x88 a\xcc\x8a\n'
printf 'stacked:     a\xcc\x80\xcc\x81\xcc\x82\xcc\x83 o\xcc\xa3\xcc\x82 x\xcc\x8c\xcc\xa7\n'
printf 'cyrillic:    и\xcc\x86 е\xcc\x88\n'
printf 'width check: |e\xcc\x81|e\xcc\x81e\xcc\x81|n\xcc\x83|\n'
printf 'columns:     |1|2|3|4|5|\n'
printf 'vs15/vs16:   ☺\xef\xb8\x8e ☺\xef\xb8\x8f ❤\xef\xb8\x8e |\n'
printf 'zwj/zwnj:    a\xe2\x80\x8db a\xe2\x80\x8cb |\n'
printf 'devanagari:  क\xe0\xa5\x8d\xe0\xa4\xb7 |\n'
echo done > "$VTS_DONE"
exec sleep 600
