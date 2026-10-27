#!/bin/bash
# vts: requires=T5 extra-config=
# wide-cjk: double-width cells (CJK, Hangul, fullwidth Latin) next to narrow ones; the glyphs need font fallback (T5).
printf '\e[2J\e[H\e[?25l'
printf 'wide-cjk\n\n'
printf '|ab|漢字|かな|한글|ＡＢＣ|\n'
printf '|12|漢字|カナ|한글|１２３|\n'
printf '|..|....|....|....|......|\n\n'
printf '日本語のテキスト mixed with ascii text\n'
printf '中文字符测试 and 한국어 텍스트\n\n'
printf '\e[10;98H漢字 (wraps at the right edge)\n'
printf '\e[13;1H\e[7m漢字 inverse \e[0m \e[44m蓝底\e[0m \e[4m下划线\e[0m\n'
echo done > "$VTS_DONE"
exec sleep 600
