# Issues after v1.0 (win-1.3.2-dev-1)

Date: 2026-10-29. Research only: nothing here was built or tested; every
claim names its evidence and whether it was verified in code or inferred.
Source: the owner's reports after installing v1.0, plus a code audit.

## 1. Claude Code colours are dimmer than in Windows Terminal

Owner: in Git Bash + Claude Code, Windows Terminal shows `#D77757`, Ghostty
shows `#D78787`.

**Cause (verified).** `#D78787` is xterm-256 index 174, and 174 is exactly
what chalk's `rgbToAnsi256` gives for `#D77757` (round(215/255·5)=4,
round(119/255·5)=2, round(87/255·5)=2 → 16+144+12+2). So Claude Code sends
256-colour SGR, not truecolor. The installed Claude Code binary contains:

```js
function ae(){if(i.CLAUDE_CODE_TMUX_TRUECOLOR)return!1;
  if(i.TMUX&&u.level>2)return u.level=2,!0;return!1}
```

Claude Code clamps colours to 256 whenever `TMUX` is set, unless
`CLAUDE_CODE_TMUX_TRUECOLOR` is set. Ghostty's tmux shim exports `TMUX` and
`TMUX_PANE` into every pane (`src/apprt/win32/tmux/env.zig:30-41`,
`windows-tmux-shim = true` by default, `src/config/Config.zig:3879`).
Windows Terminal sets no `TMUX`, so Claude Code stays at truecolor there.

**Fix.** When the shim exports `TMUX`, also export
`CLAUDE_CODE_TMUX_TRUECOLOR=1` (the "outer terminal" of our tmux is Ghostty
itself, which is truecolor) unless the user's environment already sets it.
One line in `tmux/env.zig` `apply` + a unit test. Effort S.

**Workaround now:** `env = CLAUDE_CODE_TMUX_TRUECOLOR=1` in the Ghostty config
(the `env` key, `Config.zig:1318`; not checked on Windows yet), or
`export CLAUDE_CODE_TMUX_TRUECOLOR=1` in `~/.bashrc`.

The same `TMUX` export also stops Claude Code from drawing images (see § 2).

## 1b. Git Bash prompt colours look dull

Two independent causes, neither specific to the port:

- **Palette (verified).** Git Bash's prompt uses the 16 ANSI colours (green
  user@host, magenta `MINGW64`, yellow path). Ghostty's built-in palette is
  the soft "Tomorrow Night"-like one (`src/terminal/color.zig:497-504`:
  green `#B5BD68`, yellow `#F0C674`, magenta `#B294BB`), the same as on macOS.
  Windows Terminal's default scheme Campbell is saturated (green `#13A10E`,
  yellow `#C19C00`, purple `#881798`). So Ghostty on Windows matches Ghostty
  on macOS here, by design. None of the 819 bundled themes is Campbell.
  Option: ship a `Campbell` theme file (or document a palette block) so
  users can match Windows Terminal; do not change the default (upstream
  parity).
- **Text rasterization (inferred).** Ghostty renders glyphs with FreeType
  greyscale AA and `alpha-blending = linear-corrected` on non-macOS
  (`Config.zig:415-419`); Windows Terminal uses DirectWrite ClearType with
  contrast enhancement, which makes coloured text look heavier and more
  saturated. Thin strokes of the same RGB read paler. To compare: try
  `alpha-blending = native` and `font-thicken = true`. A real fix would be
  a DirectWrite rasterizer or stem darkening; that is effort L, and macOS
  parity is already met.

## 2. Kitty images still do not show

See the agent report merged below (§ 2a). In short (verified for Claude
Code): with `TMUX` set, Claude Code sends a version query, expects the
answer "tmux X.Y", and otherwise logs "TMUX is set, but the terminal did not
answer as tmux; … unset TMUX". It then asks
`tmux display-message -p "#{client_termtype}\t#{allow-passthrough}\t…"`
(8 fields) and wraps Kitty APCs in tmux DCS passthrough (`ESC Ptmux;`).
Separately, `windows-conpty = auto` puts Git Bash on the inbox ConPTY,
which (per the M5 record) does not pass Kitty graphics.

**Owner decision (2026-10-29): turn the tmux shim off.** The owner does not
need tmux. `windows-tmux-shim` defaults to `false` (`Config.zig:3879`). No
`TMUX`/`TMUX_PANE` and no PATH prepend in panes, and the installer and
portable zip may keep `tmux.exe` but nothing exports it. This removes
obstacles 2 and 3 below and the 256-colour clamp of § 1, so the
`CLAUDE_CODE_TMUX_TRUECOLOR` fix becomes unnecessary. Cost: Claude Code
agent teams no longer open as Ghostty splits. Docs, release notes and the
tmux e2e scenarios (claude-team, tmux-cli, tmux-replay) must enable the
key explicitly. Remaining work for images: the inbox ConPTY under Git Bash
(obstacle 1), the `a=q` reply through ConPTY input (4), and a GUI render
check (5).

### 2a. Kitty graphics report (agent, code reading only)


Ветка `windows`, HEAD 151a59f62. Тег `win-1.3.2-dev-1` указывает на f904ba62c, родителя 151a59f62; разница только в документации.
Исследование без сборки и без запусков: читал код, ledger и git-историю. Upstream-исходники microsoft/terminal, msys2-runtime,
viuer и описание протокола kitty смотрел в сети. Логику Claude Code проверял по строкам в установленном `~/.local/bin/claude.exe`.

Метки уверенности:
- **[код]** — проверено в коде этого репозитория;
- **[артефакт]** — записано в RESULT.md, ledger или отчётах (измерения прошлых задач, сам я их не повторял);
- **[бинарь CC]** — проверено по строкам в бинаре Claude Code;
- **[upstream-src]** — по исходникам upstream (ветка main), конкретную сборку 1.25 не проверял;
- **[вывод]** — умозаключение без прямой проверки.

#### Коротко

Картинок нет из-за пяти независимых препятствий. Каждое из них ломает Kitty graphics само по себе:

1. **Git Bash работает на inbox conhost**, а тот выбрасывает APC (`windows-conpty = auto`). Это ожидаемо и задокументировано.
2. **`TMUX`/`TMUX_PANE` выставляются в КАЖДОЙ панели**, включая pwsh и cmd (`windows-tmux-shim = true` по умолчанию). С ними
   инструменты оборачивают графику в `ESC P tmux; … ESC \`, а Ghostty такой DCS не разворачивает и выбрасывает. Claude Code
   при `TMUX` вообще уходит в tmux-ветку, где картинки выключены: Ghostty не отвечает на XTVERSION строкой «tmux …», а shim
   отвечает `allow-passthrough off`.
3. **Ответ на `a=q` почти наверняка не доходит до программы и через bundled OpenConsole.** Его input-парсер игнорирует APC
   ([upstream-src]). Поэтому инструменты, которые определяют поддержку запросом (Claude Code без TMUX, viu/viuer, kitten),
   считают, что поддержки нет.
4. **Отрисовку Kitty-картинки в GUI на D3D11 никто ни разу не проверял.** Кейс vt-smoke `kitty-image` всегда SKIP. Код
   пайплайна при этом полный, не заглушка.
5. **`t=s` (shared memory) на Windows не поддерживается** — так же, как в upstream. POSIX-пути от MSYS-клиентов в `t=f`/`t=t`
   не транслируются.

Сам MSYS2-runtime вывод APC **не фильтрует**: в headless-пробе на bundled ConPTY printf из Git Bash дошёл байт-в-байт.

---

#### 1. Путь APC от программы до парсера Ghostty

##### Общая часть [код]

- Консоль выбирается по `args[0]` панели в момент открытия pty: `src/termio/Exec.zig:1035-1036` →
  `Pty.openFor` (`src/pty.zig:429-433`) → `windows.conptyFor(program)` (`src/pty.zig:528-538`).
- Режим `auto` даёт inbox для MSYS2/Cygwin: `src/os/windows.zig:759-770` (`conptyWantsBundled`), классификатор
  `isMsysProgram` в `src/os/windows.zig:730-742` (bash, sh, zsh, fish… вне System32, всё под `usr\bin`, cygwin). При этом
  пишется строка лога `windows-conpty = auto: inbox ConPTY for the MSYS2/Cygwin program …` (`src/os/windows.zig:777-780`).
  Режим из конфига ставится в `src/apprt/win32/hooks.zig:115`.
- **Следствие [код]:** консоль выбирается один раз на всю панель. Нативная программа, запущенная из Git Bash (`claude.exe`,
  `chafa.exe`), получает ту же inbox-консоль.
- Программа делает `WriteFile`/`WriteConsole` в свою консоль. Консоль (conhost.exe или OpenConsole.exe) пишет VT в
  `out_pipe_pty` (`src/pty.zig:500-506`, `:529-536`).
- Ghostty читает именованный pipe overlapped-чтением в `threadMainWindows` (`src/termio/Exec.zig:1929-1964`, `ReadFile` на
  `:2054`). Дальше `Termio.processOutput` (`src/termio/Termio.zig:711`) → парсер → события `apc_start`/`apc_put`/`apc_end`
  (`src/termio/stream_handler.zig:392-395`) → `apcEnd` (`:523-541`) → `terminal.kittyGraphics(...)`.
- Ответ терминала уходит через `messageWriter(writeReq)` (`stream_handler.zig:537-538`) → `queueWrite`
  (`Exec.zig:451`) → входной pipe консоли.

##### (a) Inbox ConPTY (kernel32 → conhost.exe)

- **APC пропадает внутри conhost** [артефакт]. GUI-проба M3 Task 28 при флагах 0 и 8: в кадре нет пикселя `#ff00ff`, в логе
  нет `kitty graphics response`, курсор не сдвинулся (`test/windows/conpty-probe/RESULT.md:16-18`, `:40-55`). Headless-проба
  M5: «dropped x2» при inbox 0 и inbox 8 (`RESULT.md:142-144`).
- Флаг 8 (`PSEUDOCONSOLE_PASSTHROUGH_MODE`) у inbox ничего не меняет (`RESULT.md:52-55`, `:76-81`).
- SGR 58 inbox превращает в мигание (`RESULT.md:145`).

##### (b) Bundled ConPTY (conpty.dll + OpenConsole.exe 1.25.260930003)

- **Вывод APC доходит без изменений** [артефакт]: «arrived x2, byte-identical» (`RESULT.md:142-145`).
- Режима «passthrough» в 1.25 **нет**. Флаг 8 там означает `PSEUDOCONSOLE_GLYPH_WIDTH_GRAPHEMES` (`RESULT.md:137-140`;
  `src/os/windows.zig:645-647`). Bundled-консоль всегда создаётся с флагами 0 (`src/os/windows.zig:794-797`).
- В «новом» ConPTY (переписан в линейке WT 1.22) вывод приложения, включённого в VT-режим, проходит насквозь всегда
  [вывод из upstream-документации и измерения выше]. В upstream `conpty-static.h` остались только флаги `INHERIT_CURSOR`,
  `GLYPH_WIDTH_*` и `AMBIGUOUS_IS_WIDE` [upstream-src].
- **Как это проверяли** [артефакт]. Только headless, без Ghostty:
  - `test/windows/conpty-probe/headless.ps1` сам играет роль терминала: создаёт pseudo console из bundled `conpty.dll`,
    запускает в Git Bash `cases/headless-seqs.sh` (`headless.ps1:305`) и ищет в сыром выходе два `ESC _ G`
    (`headless.ps1:330-332`).
  - Хост отвечает только на DA1 и CPR (`headless.ps1:185`, `RESULT.md:134-136`). **На `a=q` хост не отвечал**, так что путь
    ответа обратно через OpenConsole не проверен.
  - В самом Ghostty картинку на bundled-консоли **ни разу не рисовали**: `vt-smoke/kitty-image` всегда SKIP «no reference for
    96 dpi» (`.superpowers/sdd/M6-release/e2e-rc-1.log:378`; `docs/windows/m6/acceptance.md:28`). Пункт GUI-проверки в M5 не
    отмечен (`docs/windows/m5/acceptance.md:61`). В `conpty-report.md:58-59` прямо написано «GUI checks PENDING».
  - Значит, фраза в CHANGELOG «Kitty graphics and SGR 58 work there» (`docs/windows/CHANGELOG.md:396-400`) — **непроверенное
    утверждение**.

##### Где теряется

| Направление | inbox | bundled |
|---|---|---|
| APC от программы к Ghostty | теряется в conhost [артефакт] | доходит [артефакт, headless] |
| ответ Ghostty (`ESC _ G i=…;OK ESC \`) к программе | не проверялось; скорее всего теряется [вывод] | **скорее всего теряется в input-парсере OpenConsole** [upstream-src, см. п. 2] |

---

#### 2. MSYS2-runtime как фильтр; инструменты; определение поддержки

##### MSYS2 вывод не фильтрует [артефакт]

Headless-проба запускала **Git Bash** (`"bash.exe" --noprofile --norc case.sh`, `headless.ps1:305`). На bundled-консоли APC
дошёл байт-в-байт (`RESULT.md:144`). Значит, слой консоли msys-2.0.dll в VT-режиме пропускает APC. Ломает дело только
inbox conhost.

##### Обратный путь (ответы) [upstream-src, вывод]

Разбор входа в OpenConsole (`src/terminal/parser/stateMachine.cpp`, main):

- `ESC _` всегда переводит парсер в `SosPmApcString` (`_EnterSosPmApcString`). Обработчик этого состояния
  `_EventSosPmApcString` только вызывает `_ActionIgnore()`, кэш при входе сбрасывается. Условий для input-движка нет. Итог:
  **тело APC-ответа выбрасывается**, а финальный `ESC \` скорее всего превращается в нажатие Alt+`\`.
- В `InputStateMachineEngine` DCS-ответы (XTVERSION) буферизуются и сбрасываются клиенту на ST (`_expectingStringTerminator`).
  OSC-ответы проходят через `FlushToTerminal`. CPR и DA1 OpenConsole забирает себе.
- Итог: XTVERSION и OSC до программы доходят, APC — нет.
- Какой коммит лёг в пакет 1.25.260930003, я не проверял. Чтобы подтвердить, нужен прогон (план, шаг P3).

##### Что выставлено в окружении [код]

- `TERM=xterm-ghostty`. Для WSL и при отсутствии terminfo-записи — `xterm-256color` (`src/termio/Exec.zig:941-962`,
  `windowsTerm` `:3048-3071`).
- `TERM_PROGRAM=ghostty` и `TERM_PROGRAM_VERSION` (`Exec.zig:838-839`).
- **В каждой панели `TMUX` и `TMUX_PANE`** (`src/apprt/win32/tmux/env.zig:28-44`, вызов в
  `src/apprt/win32/Surface.zig:560-576`; документация `src/config/Config.zig:3860-3879`).
- XTVERSION возвращает `ghostty <version>` (`src/termio/stream_handler.zig:987-997`).

##### Инструменты

| Инструмент | Есть под Windows | Как определяет kitty | Итог в порте сегодня |
|---|---|---|---|
| сырой `printf`/`[Console]::Write` с `t=d` | — | без определения | на bundled должен рисовать; это лучший смоук-тест [вывод] |
| **chafa** ≥1.14.3 | нативные сборки есть | эвристики по env (Ghostty → kitty), с 1.16 есть ещё `--probe`; при `TMUX` оборачивает в tmux passthrough (есть `--passthrough`) | на bundled рисует только с `-f kitty --passthrough none`, потому что `TMUX` выставлен [вывод по changelog chafa] |
| **viu** (viuer) | да (Rust) | только запрос `a=q` + DA1 из stdin; локальный режим через `t=t` | ответ съедается, viu откатывается на блоки [upstream-src viuer + вывод] |
| **kitten icat** | нативного kitten для Windows нет (kitty работает только на Unix) [вывод]; из WSL — возможно | запрос `a=q` + DA1 | из WSL то же, что у viu: ответа нет [вывод] |
| **timg** | нативной сборки нет, только WSL | env + запросы; при `TMUX` оборачивает | — [вывод] |
| **wezterm imgcat** | да | iTerm2 OSC 1337 | **никогда**: Ghostty (и upstream) не реализует `OSC 1337 File` (`src/terminal/osc/parsers/iterm2.zig:169`, `:193` «unimplemented») [код] |
| **Claude Code** | да | см. ниже | сейчас картинок нет в любой панели [бинарь CC] |

##### Claude Code [бинарь CC]

**Без `TMUX`.** `kittyGraphics = (пришёл ответ на graphics-запрос) && h5n(xtversionName ?? terminal)`, где `h5n` принимает
`kitty(≥0.28)` и `ghostty`/`ghostty …`. Нужен **ответ на `a=q`**, а он, скорее всего, съедается OpenConsole. Обходной путь —
`CLAUDE_CODE_FORCE_TERMINAL_IMAGES=1`: тогда функция `pe()` возвращает `settled: true`.

**С `TMUX`.** Включается ветка `SVs()`:

- версия терминала должна начинаться с `"tmux "`, иначе сообщение «TMUX is set, but the terminal did not answer as tmux»;
- нужен `TMUX_PANE`;
- выполняется `tmux display-message -p -t $TMUX_PANE` с 8 полями (`client_termtype`, `allow-passthrough`, `focus-events`,
  `pane_top`, `pane_left`, `status`, `status-position`, `window_bigger`);
- `allow-passthrough` должен быть `on`/`all`, `focus-events` — `1`, а `h5n(client_termtype)` — истина;
- вывод оборачивается в `ESC Ptmux;` с удвоенным ESC (функция `iD()`, при `TMUX` `yun()` возвращает `"tmux"`).

Claude Code использует `a=T,U=1` (Unicode placeholders), а запросы шлёт с `t=d` и `t=f`.

**Что отвечает наш shim** (`src/apprt/win32/tmux/commands.zig:304-321`):
`xterm-ghostty\toff\t0\t<top>\t<left>\ton\tbottom\t0`. Это 8 полей, числа валидны, но:

- `allow-passthrough off` → картинок нет;
- `focus-events 0` → картинок нет;
- `client_termtype = xterm-ghostty` не проходит `h5n`: у настоящего tmux тут лежит XTVERSION внешнего терминала, то есть
  `ghostty 1.x`.

Значения по умолчанию для `show-options` — в `commands.zig:199-212` (`focus-events off`, `allow-passthrough off`). Но первое
препятствие ещё раньше: XTVERSION.

**Разворачивает ли Ghostty `ESC P tmux;`?** Нет [код]. В `src/terminal/dcs.zig:51-75` обрабатывается только
`DCS 1000 p` (tmux control mode). `ESC P tmux;` разбирается как DCS с final `t` и уходит в «unknown DCS hook»
(`dcs.zig:37`), payload выбрасывается. Inbox conhost сам ломает такие DCS (`RESULT.md:86-112`). Как bundled ведёт себя с DCS
от приложения, не проверялось.

Связанный пункт лида: при `TMUX` Claude Code ограничивает цвета 256 (если не задан `CLAUDE_CODE_TMUX_TRUECOLOR`). Корень
тот же: `TMUX` экспортируется в каждую панель.

---

#### 3. «Первая клавиша после resize теряется» на bundled под MSYS

##### Что записано [артефакт]

- `.superpowers/sdd/M5-windows-extras/e2e-all-report.md:22-61`. Кейс `resize-input bash` на bundled: потеряно 7, 10, 12 и 4
  строки из 36; на inbox — 0 из 36. Теряется всегда первый символ строки.
- По инструментированному логу строка теряется **ровно тогда, когда `CSI 6 n` от OpenConsole приходит через 0,6–2 мс после
  строки** (12 из 12). OpenConsole блокирует консольный вызов до ответа; Ghostty отвечает примерно за 0,1 мс.
- Рабочая гипотеза из отчёта: первый прочитанный после resize ключ заставляет MSYS2 опросить консоль (`con.fillin` →
  `GetConsoleScreenBufferInfo`). На bundled это превращается в round trip через терминал, и запись теряется «внутри
  msys2-runtime».
- `readrec.exe` (нативный `ReadConsoleInputW`) получает все клавиши. Но он не делает параллельных консольных вызовов, поэтому
  комбинацию «ожидание CPR + клавиша» он не проверяет.
- Headless-репро (bash `--posix --login -i`) дал 0 потерь из 40: «trigger needs something of the full Ghostty session».
- Resize-prime (Shift key-up, `src/termio/resize_prime.zig:1-21`) не помогает: 12/36 с ним, 10/36 без.
- Hold-back исключён: `CSI 6 n` приходит **после** клавиши (`e2e-all-report.md:110-113`).
- Решение R-M5-17 — `auto` (ledger `progress.md:123`, `:129`; `docs/windows/SPEC.md:1017-1030`, `:1200`;
  `docs/windows/m5/acceptance.md:44`).

##### Корневая причина не доказана

Гипотезы [вывод, частично upstream-src]:

- **H1, наиболее согласованная.** В msys2-runtime (`fhandler/console.cc`) поток `cons_master_thread` под `input_mutex`
  вычитывает записи через `ReadConsoleInputW`, обрабатывает `WINDOW_BUFFER_SIZE_EVENT`, при этом вызывает
  `con.fillin(...)`, а затем пишет оставшиеся записи обратно (`WriteConsoleInputW`) и сверяет их через `inrec_eq()`.
  - Если записи не совпали, срабатывает fixup-путь «Giving up», который может потерять или переставить запись.
  - На bundled `fillin` блокируется на CPR round trip. Окно гонки расширяется, а OpenConsole может нормализовать записи
    иначе, чем conhost: в марте 2026 уже чинили расхождение `wRepeatCount` 0→1, коммит f3914f1e «Cygwin: console: Fix master
    thread», git-for-windows#5632.
  - С этой гипотезой согласуется и исходная inbox-потеря «записи после window-size event», которую поглощает prime
    (`resize_prime.zig:3-11`).
  - Для справки: Git for Windows на машине — 2.55.0, MSYS runtime 3.6.9 (`uname -r`), фикс 2026 года там, вероятно, уже есть.
- **H2.** SIGWINCH прерывает `read()` у readline/bash (EINTR), и уже вычитанный символ теряется.
- Похожее семейство ошибок upstream уже знает: git-for-windows#5632 — перемешивание и потеря клавиш в Windows Terminal (то есть
  на новом ConPTY), но не в conhost.

##### Варианты, чтобы MSYS-программы шли через bundled

От дешёвых к дорогим:

1. **Дешёвая диагностика, S, без риска.**
   - Проверить Git Bash в Windows Terminal 1.23+: там тот же новый OpenConsole. Resize, потом сразу набрать строку.
   - Если в WT потерь нет, главное отличие — WT шлёт **все** клавиши в win32-input-mode (OpenConsole сам просит
     `CSI ? 9001 h`, `RESULT.md:166-169`). Тогда стоит попробовать вариант 2.
   - Параллельно снять cygwin `strace` с bash на bundled во время `resize-input` и найти, где пропадает запись.
2. **Ghostty шлёт клавиши в win32-input-mode, когда консоль его запросила (паритет с WT). M, риск средний.**
   - Инфраструктура уже есть: `resize_prime.zig` распознаёт запрос 9001h и шлёт такие последовательности.
   - A/B на `resize-input`. Эффект на H1 не гарантирован.
3. **Сообщить в msys2-runtime / Cygwin** (Takashi Yano быстро отвечает) с минимальным репро. S по работе, но срок не наш.
   Когда починят, переключить `auto` на bundled и для MSYS.
4. **Opt-in без исправления, S, риск только для тех, кто включил.** Уже есть `windows-conpty = bundled`. Можно добавить
   отдельный ключ только для MSYS или профиль Git Bash (bundled), чтобы желающие получили картинки ценой редкой потери
   клавиши.
5. **Обойти ConPTY для MSYS через мост на cygwin-pty (как mintty). L, риск высокий.** Не рекомендую: нативные дети внутри
   MSYS-pty снова попадают в inbox-консоль через MSYS «pcon», и для `claude.exe` или `chafa.exe` из Git Bash это ничего не
   решает.

---

#### 4. pwsh/cmd на bundled: работает ли сквозь весь путь; D3D11

##### Пайплайн отрисовки реализован, это не заглушка [код]

- Общий рендерер рисует Kitty-слои `kitty_below_bg`, `kitty_below_text` и `kitty_above_text`
  (`src/renderer/generic.zig:2153-2203`). Загрузка текстур — `images.upload` (`:2067-2068`).
- D3D11:
  - пайплайны `image` и `bg_image`: `src/renderer/d3d11/shaders.zig:77-93`;
  - HLSL `src/renderer/shaders/hlsl/image.hlsl` — полноценный порт VS и PS (выборка, linear blending, premultiply);
    регистрация в `src/renderer/d3d11/hlsl.zig:27-28`, `:47`, `:64`;
  - форматы текстур — `src/renderer/D3D11.zig:700-720` с тестом `:1452`;
  - загрузка — `src/renderer/image.zig:796-815`;
  - тест «d3d11 device: images re-uploaded after recovery» — `image.zig:1446`.
- PNG декодируется через wuffs (`src/terminal/sys.zig:18-21`).
- Ядро kitty совпадает с upstream: `git diff upstream/main...windows -- src/terminal/kitty` пуст. Windows-проверки путей —
  upstream-коммит 0b5446364.
- Лимиты: `.allWithTempDir(global.tmpDirPath())` (`src/termio/Termio.zig:296`, `:513`); temp-каталог берётся из
  `GetTempPathW` (`src/os/file.zig:67-84`).
- Мелочь [код/вывод]: шаг image не передаёт sampler (`image.zig:200-207`), а шейдер берёт `linear_clamp : register(s0)`.
  - `RenderPass` связывает только переданные samplers (`src/renderer/d3d11/RenderPass.zig:164-166`).
  - Если s0 никто не занимал, D3D11 подставит дефолтный sampler (linear, clamp), это корректно. Но если custom-shader пасс
    оставил в s0 свой sampler, кадр картинки возьмёт его.
  - Не блокер. Стоит явно передавать sampler — дёшево.
- Тот же путь текстур подтверждён в GUI косвенно: vt-smoke `bg-image` проходит на 100 % (`m6/acceptance.md:28`).

##### Работает ли сквозь весь путь сегодня: не доказано, а для реальных инструментов скорее нет

- **Сырой APC с `t=d` в pwsh-панели (bundled):** ожидаю, что рисуется. Вывод проходит (п. 1b), ядро и рендер на месте.
  GUI-подтверждения нет.
- **Реальные инструменты в pwsh:** мешает `TMUX` (п. 2): chafa без `--passthrough none` и Claude Code. Viu и Claude Code без
  `TMUX` ломаются ещё и на ответе `a=q`.

Смоук-тест для владельца (2 пикселя `#ff00ff`, растянутые на 8×2 ячейки; данные взяты из `headless-seqs.sh:8`):

```powershell
### pwsh-панель (по умолчанию bundled):
$e=[char]27; [Console]::Write("${e}_Ga=T,f=24,s=2,v=1,c=8,r=2;/wD//wD/${e}\")
```

```bash
### Git Bash — только после windows-conpty = bundled в конфиге и в новой панели:
printf '\e_Ga=T,f=24,s=2,v=1,c=8,r=2;/wD//wD/\e\\'
```

Если в pwsh магента не появилась, значит, проблема в рендере или ядре на Windows, а не в ConPTY. Тогда первым делом лог
`kitty graphics response` при запросе `a=q` и кадр-дамп.

---

#### 5. Прочие блокеры

- **`a=q` и ответы вообще.** Ответ кодирует `StreamHandler.apcEnd` (`stream_handler.zig:523-541`). Дальше см. п. 2: OpenConsole
  его, скорее всего, съедает. Ответы с `q=1`/`q=2` подавлены, и для отображения ответ не нужен.
- **Unicode placeholders (`U=1`).** Реализованы в ядре и рендере upstream (тесты `image.zig:1135`, `:1203`, `:1261`), на Windows
  отдельных препятствий нет [код]. Claude Code ими пользуется [бинарь CC].
- **`t=f` (файл)** [код]:
  - работает для Windows-путей, `\` и `/`;
  - сырой путь проверяется до открытия (`src/terminal/kitty/windows.zig:42-62`: UNC, `\\.\`, `\\?\`, `\??\`, CON/COM…);
  - канонический путь проверяется после открытия (`:67-70`, только `X:\…`);
  - вызовы в `graphics_image.zig:355-364`, `:479-485`.
- **`t=t` (временный файл)** [код]. Файл должен лежать в `/tmp`, `/dev/shm`, в каталоге из `GetTempPathW` или в его
  realpath, а имя должно содержать `tty-graphics-protocol` (`graphics_image.zig:408-423`, `:502-532`). Нативные клиенты с
  `%TEMP%` проходят.
- **MSYS-клиенты** шлют POSIX-пути (`/tmp/...`, `/c/...`). Ghostty откроет их относительно корня текущего диска, файл не
  найдётся — **трансляции нет** [код + вывод]. Ни нативный chafa, ни Claude Code это не затрагивает.
- **`t=s` (shared memory)** [код]. На Windows всегда `error.UnsupportedMedium` (`graphics_image.zig:204-208`, комментарий
  «windows is currently unsupported»). Так же в upstream, то есть это не регресс порта. Спецификация kitty для Windows говорит
  про «Named shared memory object» (`OpenFileMappingW`/`MapViewOfFile`, без unlink). Реализовать можно, но паритету с upstream
  это не нужно.
- **Ограничение размера.** `image-storage-limit` по умолчанию 320 MB (`Config.zig:2538`), отличий для Windows нет.
- **iTerm2 OSC 1337 File** не реализован (`iterm2.zig:169`, `:193`), так что `wezterm imgcat` и iTerm-режим Claude Code не
  работают. Это тоже как в upstream.
- **Неточность в документации.** CHANGELOG (`:249-256`, `:396-400`) и parity-audit (`:29`) говорят «работает» или «done»,
  хотя GUI-проверки нет, а `TMUX` ломает реальные инструменты.

---

#### Ранжированный план

Сортировка: сначала то, что даёт ценность быстрее и при меньшем риске.

| № | Что | Объём / риск | Что снимает |
|---|---|---|---|
| P0 | Владелец прогоняет смоук-тест из п. 4 в pwsh, потом в Git Bash с `windows-conpty = bundled`. Генерация референса `vt-smoke -Only kitty-image -Update` (GUI-прогон) | S / нет | проверяет п. 4: рисует ли D3D11 вообще |
| P1 | Обходные пути для владельца сейчас: pwsh-панель; для Claude Code — `TMUX` и `TMUX_PANE` пустые для процесса (или `windows-tmux-shim = false`) плюс `CLAUDE_CODE_FORCE_TERMINAL_IMAGES=1`; chafa — `-f kitty --passthrough none`; Git Bash — `windows-conpty = bundled` с риском потерять клавишу | S / нет | даёт картинки до фиксов [вывод] |
| P2 | **Проблема TMUX.** (a) Ghostty разворачивает `ESC P tmux; … ESC \`: ESC ESC → ESC, внутренние байты снова подаются в парсер; только для панелей, где shim выставил `TMUX`. (b) Shim отвечает `allow-passthrough on`, `focus-events 1`/`on`, `client_termtype = ghostty <version>` (`commands.zig:203-204`, `:308-311`). (c) Решение владельца для Claude Code: либо в shim-панелях отвечать на XTVERSION `tmux 3.5a`, как настоящий tmux, либо не экспортировать `TMUX` в обычные панели (тогда agent teams перейдут в in-process) | M / низкий–средний; (c) — продуктовое решение | chafa, yazi, timg и Claude Code во всех панелях; заодно 256 цветов в Claude Code (пункт лида) |
| P3 | Подтвердить, что ответ `a=q` съедается: расширить `headless.ps1`, чтобы хост отвечал APC, а кейс читал ответ через `read -t`. Если съедается — Ghostty кодирует APC-ответы как записи клавиш win32-input-mode, когда консоль запросила 9001h (как в `resize_prime.zig`), тогда OpenConsole не разбирает их как APC | S, потом M / средний | автодетект в Claude Code без FORCE, viu, kitten |
| P4 | Git Bash на bundled: проверка в WT, cygwin `strace`, A/B с полным win32-input-mode, отчёт в msys2-runtime. При 0/36 — `auto` → bundled для MSYS | M–L / средний | п. 1a: картинки и SGR 58 в Git Bash «как в upstream» |
| P5 | Opt-in ключ или профиль «bundled только для Git Bash», пока P4 не готов | S / низкий | желающим — картинки в Git Bash сейчас |
| P6 | Явно передавать sampler в image-step (`image.zig:200-207`); исправить CHANGELOG и parity-audit | S / нет | гигиена |
| P7 | Named shared memory для `t=s`; трансляция MSYS-путей для `t=f`/`t=t` | M / низкий | выше паритета, мало ценности |
| P8 | Мост на cygwin-pty для MSYS | L / высокий | не рекомендую |

##### Источники (сеть)

- microsoft/terminal `src/terminal/parser/stateMachine.cpp` и `InputStateMachineEngine.cpp` (main, raw.githubusercontent.com)
- microsoft/terminal `src/inc/conpty-static.h` (main)
- microsoft/terminal issue #17643 (известные проблемы после перехода ConPTY на passthrough; DCS-ответы, PR #17845)
- msys2/msys2-runtime `winsup/cygwin/fhandler/console.cc` (тег msys2-3.6.9)
- cygwin-cvs: «Cygwin: console: Fix master thread» (f3914f1e, март 2026); «Disable cons_master_thread in win32-input-mode»
  (август 2024, 3.5.5)
- git-for-windows/git#5632
- atanunq/viuer `src/printer/kitty.rs`
- sw.kovidgoyal.net/kitty/graphics-protocol (медиум `s` на Windows, определение поддержки)
- changelog chafa (1.14.3 Ghostty→kitty, 1.16 `--probe`, детект Ghostty внутри tmux)


## 3. Tab rename: white box, typed text invisible

Owner screenshot: double-click on the tab → a white rectangle over the tab
row, letters do not appear while typing (Enter still renames).

**Code (verified).** `src/apprt/win32/title_edit.zig:120-163` creates a
plain GDI `EDIT` child of the top-level window (`WS_CHILD | WS_VISIBLE |
WS_BORDER`). Nothing handles `WM_CTLCOLOREDIT` for it: the top-level
window proc does not, while the search bar and the command palette, whose
EDITs live in their own popup windows, do (`SearchBar.zig:501`,
`CommandPalette.zig:1055`). The e2e scenario `test/windows/e2e/tab-rename.ps1`
checks only that the control exists and the title changes. It takes no
pixels, which is how this passed.

**Cause (inferred, strong).** The top-level client area is composed by
DWM with per-pixel alpha. Mica/extended frame covers the title row
(`frame.zig:381-398`, `cyTopHeight = title_h`). A translucent window
(`background-opacity < 1`) gets `DwmEnableBlurBehindWindow` over the whole
client area (`composition.zig:12-16, 452`). The chrome is painted with
buffered paint and explicit alpha precisely because GDI writes alpha 0
(`Chrome.zig:794-803`: "GDI leaves its alpha at 0, so over Mica the fill
would not show"). A stock EDIT paints with GDI: its white background
(alpha 0, premultiplied → additive) comes out as a white box, and its black
ClearType text and caret (alpha 0) vanish. Check: does the same happen with
`background-opacity = 1` and the tab bar not in the title row?

**Fix options.**
- **(a) Host the EDIT in an owned borderless popup** over the tab, as the
  search bar does (`overlay.zig` `.panel`, `WS_POPUP`), and theme it in
  `WM_CTLCOLOREDIT` from `theme.palette`. Proven pattern in this codebase.
  Effort S–M.
- **(b) Draw the editor in the strip with Direct2D** (custom caret/selection,
  IME via `ImmSetCompositionWindow`). This is closest to macOS
  `macos/Sources/Helpers/TabTitleEditor.swift`, which edits in place with the
  tab's own font and centring. Effort M–L.

Recommended: (a) now, styled after `TabTitleEditor.swift` (no white field,
tab font, centred text). Also add a pixel check to `tab-rename.ps1`: the
editor area is not white, and typed text changes pixels.

## 4. Symbols (non-letters) look different from Windows Terminal

**Why (verified).** A character is drawn by whichever of these comes first:

1. **Sprites drawn by Ghostty itself, the same code on every platform**
   (`src/font/sprite/draw/`): box drawing, blocks, braille, Powerline,
   legacy computing, branch symbols and part of geometric shapes. These look
   exactly like Ghostty on macOS. Windows Terminal draws its own built-in
   versions, with different line weights.
2. **Embedded JetBrains Mono + Symbols Nerd Font** (`src/font/embedded.zig`),
   the same as macOS. Windows Terminal's default is Cascadia Mono, which
   itself carries many symbols (❯, arrows, technical symbols), so
   Windows Terminal rarely falls back.
3. **Embedded Noto Color Emoji + Noto Emoji (monochrome)**, which are added
   on every non-Darwin target (`src/font/SharedGridSet.zig:373-400`). On
   macOS they are skipped, and Apple Color Emoji plus CoreText's system
   fallback (Apple Symbols, Menlo, …) are used instead. So on Windows, text
   symbols that Claude Code uses (⏺ U+23FA, ✔, ⚠, ✻, …) come from
   **Noto Emoji**: rounder, heavier shapes, different from both Windows
   Terminal (Segoe UI Symbol/Emoji) and Ghostty macOS (Apple fonts). Emoji
   come from Noto Color Emoji, not Segoe UI Emoji.
4. **System fallback**: DirectWrite `MapCharacters`, then the fixed list
   `Segoe UI Emoji, Segoe UI Symbol, Cascadia Mono, Consolas, …`
   (`src/font/discovery.zig:979-990`). It is reached only for what steps
   1–3 lack.

**So:** sprite and letter shapes match macOS. Symbols and emoji match
Ghostty for Linux, not macOS or Windows Terminal.

**Options.**
- Skip the embedded Noto pair on Windows, as macOS skips it, so symbols and
  emoji come from Segoe UI Symbol / Segoe UI Emoji, the Windows "system
  look" that is the analogue of macOS's choice. Keep Noto as a last resort
  after system discovery. Effort S–M, plus vt-smoke reference updates.
**Owner decision (2026-10-29): do it like macOS and Windows Terminal.**
On Windows, skip the embedded Noto pair at the point macOS does
(`SharedGridSet.zig` emoji-fallback block), so text symbols resolve through
system discovery to Segoe UI Symbol, and emoji to Segoe UI Emoji (colour).
That matches macOS's "system fonts" approach and Windows Terminal's look.
Keep Noto only as a last resort when DirectWrite discovery is unusable
(`Windows.dw == null`). Update the vt-smoke references and the font unit
tests that assume Noto. Sprites and JetBrains Mono stay as they are
(macOS parity).

- Users can already override per range today:
  `font-codepoint-map = U+2300-U+23FF,U+2700-U+27BF=Segoe UI Symbol`.

## 5. Explorer "Open Ghostty here" missing after install

The installer task `explorer` is `Flags: unchecked`
(`dist/windows/installer/ghostty.iss:83`), so a default install registers
nothing. On Windows 11 the verb appears only under "Show more options"
(classic menu). Options:
- make the task checked by default (S);
- a top-level Windows 11 menu entry needs an `IExplorerCommand` shell
  extension plus a sparse package with identity. Unsigned, that works only
  in developer mode (L).

## 6. Audit: what else is not ported or broken

Merged from the audit report below (§ 6a).

### 6a. Audit report (agent, code reading only)


Версия аудита: `windows` @ `151a59f62` (релиз `win-1.3.2-dev-1`). Дата: 2026-10-29.
Метод: только чтение файлов и git-истории. Ничего не собиралось, не запускалось, GUI не открывался, реестр и конфиг пользователя не трогались.
Опорные документы (обновлены, не переписаны): `docs/windows/parity-audit.md`, `feature-checklist.md`, `SPEC.md`, `DECISIONS.md`, `CHANGELOG.md`, `m5/acceptance.md`, `m6/acceptance.md`, `issues-after-v1.md` (он уже лежит в репо, это те же жалобы владельца плюс анализ; я не дублирую его выводы, а сверяю с кодом), ledgers M5/M6, final-review A/B/C.

#### Легенда

- status: `missing` (нет вообще), `stub` (заглушка/no-op), `partial` (работает не везде или не полностью), `bug` (делает не то).
- impact: high / med / low. Относительно владельца-пользователя Windows Terminal, который переходит на Ghostty.
- effort: S не больше 1 дня, M 2-5 дней, L больше недели (или зависит от внешних вещей).
- Метки в колонке пункта: `[известно]` есть в списке владельца или в доках; `[обновлено]` известно, но причина или объём уточнены кодом; `[новое]` в доках нет или нет оценки; `[не проверено]` по коду не удалось подтвердить, нужен запуск.
- Evidence: пути от корня репо. `*` в номере строки значит «около».

#### Сводка

- apprt actions: 67 из 70 реализованы, как и сказано в parity-audit. Не реализованы три: `selection_changed` (нужен UI Automation), `toggle_tab_overview`, `show_gtk_inspector` (GTK-only). Ничего скрытого: switch в `src/apprt/win32/actions.zig:33-60` исчерпывающий, TODO/FIXME в `src/apprt/win32` нет вовсе. Заглушек уровня «returns false» среди реализованных тоже нет, кроме штатных отказов (нет окна, нет таба).
- Главные пробелы лежат не в actions, а в трёх слоях: (1) окружение вокруг ConPTY (Git Bash, TMUX, WSL, win32-input-mode), (2) буфер обмена и ссылки (только `CF_UNICODETEXT`, только POSIX-пути), (3) доступность и системная интеграция (UIA, caret, `window-save-state`, подпись).
- Три бага видны владельцу каждый день и чинятся дёшево: Claude Code цвета (одна переменная в `tmux/env.zig`), редактор переименования таба (GDI `EDIT` на стекле), символы и emoji из Noto (решение владельца уже принято).
- Нашёл новое, чего нет в gap-листах: нет `win32-input-mode`; вставка файлов из Проводника (`CF_HDROP`) не работает; ссылки на `C:\path\file:12` не распознаются; WSL не наследует cwd; pwsh/cmd-интеграция знает только фичу `title` (поэтому ssh из pwsh ломает TERM); CLI-действия из pwsh/cmd (GUI-subsystem); копирование HTML/rich не поддержано; перетаскивание сплитов как на macOS.

#### 1. Баги и дефекты, которые владелец видит сейчас

| # | Пункт | Status | Evidence | Impact | Effort |
|---|---|---|---|---|---|
| 1.1 | Claude Code рисует цвета бледнее (`#D78787` вместо `#D77757` = индекс 174 из 256-цветной палитры). Причина по коду: shim экспортирует `TMUX` в каждый pane, а Claude Code при `TMUX` режет цвет до 256, если не задан `CLAUDE_CODE_TMUX_TRUECOLOR`. Лечится одной переменной в `tmux/env.zig` `apply` + unit-тест. Что Claude Code так себя ведёт, взято из `issues-after-v1.md` §1, бинарник Claude Code я не читал. `[обновлено]` | bug | `src/apprt/win32/tmux/env.zig:30-34` (put `TMUX`), `src/config/Config.zig:3879` (`windows-tmux-shim = true`), `COLORTERM=truecolor` ставится во всех ветках: `src/termio/Exec.zig:730,733,750` | high | S |
| 1.2 | Редактор переименования таба: белый прямоугольник, набираемый текст не виден (Enter всё равно переименовывает). Причина: стоковый GDI `EDIT` как прямой child верхнего окна, а верхняя полоса окна это DWM-стекло (`DwmExtendFrameIntoClientArea`, при прозрачности ещё blur-behind на всё клиентское). GDI пишет alpha 0, поэтому фон «светится» белым, а чёрный текст и каретка пропадают. `WM_CTLCOLOREDIT` и тема не заданы. Поиск и палитра живут в собственных popup-окнах и обрабатывают `WM_CTLCOLOREDIT`. Вывод про alpha 0 это вывод по коду плюс измерение из DECISIONS (диалоги), в GUI не проверял. `[обновлено]` | bug | `src/apprt/win32/title_edit.zig:120-131` (создание EDIT без темы), `src/apprt/win32/frame.zig:381-391` (стекло), `src/apprt/win32/Chrome.zig:794-798` (комментарий «GDI leaves alpha at 0»), `src/apprt/win32/SearchBar.zig:501`, `src/apprt/win32/CommandPalette.zig:1055`; e2e `test/windows/e2e/tab-rename.ps1` не снимает пиксели | high | S-M (вариант: popup-панель через `overlay.zig`, как поиск; вариант L: рисовать редактор в стрипе через Direct2D) |
| 1.3 | Символы и emoji берутся из встроенных Noto Color Emoji и Noto Emoji (код добавляет их на любой не-Darwin цели), поэтому ⏺ ✔ ⚠ ✻ из Claude Code выглядят иначе, чем в Windows Terminal (Segoe UI Symbol/Emoji) и в macOS. Решение владельца 2026-10-29 уже записано: пропускать Noto на Windows, оставить только как last resort при `Windows.dw == null`; обновить vt-smoke refs и font-тесты. Пока не сделано. `[обновлено]` | partial | `src/font/SharedGridSet.zig:375-398` (блок «Emoji fallback»), `src/font/discovery.zig:979-990` (список системных fallback), `docs/windows/issues-after-v1.md` §4 | high | S-M |
| 1.4 | Kitty-картинки не видны в Claude Code. Две независимые причины. (a) Под `TMUX` shim отвечает `allow-passthrough off`, `XTVERSION` не подменяется, DCS `tmux;` с ST-терминатором ConPTY режет. (b) Git Bash (shell по умолчанию) идёт на inbox-ConPTY при `windows-conpty = auto`, а inbox режет Kitty APC. `[обновлено]` | partial | (a) `src/apprt/win32/tmux/commands.zig:204,308-310`, `docs/windows/CHANGELOG.md:188-190`; (b) `src/config/Config.zig:3921-3933`, `docs/windows/m5/acceptance.md:44` | high | (a) M, (b) L |
| 1.5 | Git Bash: SGR 58 (цвет подчёркивания, нужен nvim/LSP) и Kitty graphics недоступны, потому что bundled ConPTY теряет первую клавишу после resize в MSYS2 (запрос `CSI 6 n`). Исправление на стороне msys2-runtime, отчёт в follow-up не заведён. Hold-back ввода исключён замерами. `[известно]` | partial | `docs/windows/feature-checklist.md:154-158`, `.superpowers/sdd/M5-windows-extras/progress.md:123,129`, `src/os/windows.zig:632-711` (выбор консоли по пути программы) | high | L (зависит от upstream msys2) |
| 1.6 | Палитра ANSI по умолчанию «Tomorrow Night» (как на macOS), а не Campbell из Windows Terminal; поэтому приглашение Git Bash бледнее. Темы Campbell в репо нет (темы приходят из внешнего пакета, 819 шт., наличие Campbell среди них не проверил). Это паритет с macOS, не дефект кода. `[обновлено]` | partial | `src/terminal/color.zig:497-504` | low | S (положить тему Campbell и упомянуть в README) |

#### 2. Ввод, буфер обмена, ссылки

| # | Пункт | Status | Evidence | Impact | Effort |
|---|---|---|---|---|---|
| 2.1 | `win32-input-mode` (`CSI ?9001h`) не реализован: ядро игнорирует режим, ConPTY запрашивает его, но Ghostty продолжает слать VT. Режим используется только для обходного Shift-key-up после resize. Следствие (вывод, не замер): нативные консольные программы (PSReadLine, cmd) не видят Shift+Enter, Ctrl+Enter, Ctrl+Backspace и подобные аккорды так, как в Windows Terminal. В списках gaps этого нет. `[новое]` | partial | `docs/windows/SPEC.md:308`, `src/termio/resize_prime.zig:8-38`, фикстуры `src/terminal/Terminal.zig:16295-16358` | med | M |
| 2.2 | Kitty keyboard protocol через ConPTY проверен только юнитами ядра; сквозной проверки на Windows нет (inbox-консоль, скорее всего, не пропускает negotiation). `[известно]` | partial | `docs/windows/feature-checklist.md:30` (status manual) | med | S (проверка) / L (если не пропускает) |
| 2.3 | Вставка файлов, скопированных в Проводнике (`CF_HDROP`): ничего не происходит. На macOS Cmd+V вставляет экранированный путь. Windows читает только `CF_UNICODETEXT`. Картинки из буфера тоже не обрабатываются. `[новое]` | missing | `src/apprt/win32/clipboard.zig:133-136,559-560`; macOS: `macos/Sources/Helpers/Extensions/NSPasteboard+Extension.swift:40-55` | med | S-M (путь через ту же квотировку, что у drag-and-drop) |
| 2.4 | Копирование в rich/HTML: ядро по умолчанию отдаёт `copy_to_clipboard = mixed` (plain + HTML), Windows берёт только первый text-mime; `html`, `vt`, `mixed` деградируют до plain. Цвета не попадают в Word/Outlook/Slack. `[новое]` | partial | `src/apprt/win32/clipboard.zig:155-158`, `src/input/Binding.zig:1126-1137` | low | M (формат `HTML Format` с заголовком CF_HTML) |
| 2.5 | Selection/primary clipboard и протокол OSC 5522 (kitty clipboard) возвращают `.unsupported`; `paste_from_selection` и `middle-click-action = primary-paste` (дефолт) ничего не делают; `copy-on-select` в режиме selection отваливается к стандартному буферу. `[известно в SPEC]` | partial | `src/apprt/win32/clipboard.zig:100-103,123-127`, `docs/windows/SPEC.md:322` | low | S-M (внутренний буфер выделения; mime-списки для 5522) |
| 2.6 | Ссылки на файлы Windows: регулярка по умолчанию не знает `\` и `C:\...`; путь вида `C:\proj\a.ts:12` и `.\src\x.zig` не кликается, `C:/x` ловится частично. Git Bash печатает POSIX-пути, а pwsh, MSVC и Claude Code на Windows печатают backslash. `[новое]` | missing | `src/config/url.zig:34-66` (классы символов без `\`), нет Windows-ветки | med | S-M (Windows-ветка регулярки + e2e) |
| 2.7 | `click-repeat-interval = 0` на Windows даёт 500 мс вместо `GetDoubleClickTime()`; настройка системы игнорируется. `[новое]` | partial | `src/os/mouse.zig:8-24` (только macOS), `src/config/Config.zig:5083-5086` | low | S |
| 2.8 | Глобальные хоткеи не перерегистрируются при смене раскладки (только при reload конфига). `[известно]` | partial | `docs/windows/CHANGELOG.md:133`, `src/apprt/win32/keyboard.zig:67-71` (кэш AltGr сбрасывается, `hotkeys` нет) | low | S |
| 2.9 | IME через IMM32, без TSF: нет reconversion (`IMR_*`), окно кандидатов берёт IME. Проверок только ручные. `[известно]` | partial | `src/apprt/win32/ime.zig:1-60`, `docs/windows/SPEC.md:307`, `docs/windows/feature-checklist.md:78` (manual) | med для CJK | L |
| 2.10 | Курсоры `alias`, `copy`, `zoom_in`, `zoom_out`, `context_menu` отображаются стрелкой (в системе нет аналогов). `[новое]` | partial | `src/apprt/win32/mouse.zig:236` | low | S |
| 2.11 | Сенсор и перо: `WM_POINTER`/`WM_GESTURE` не обрабатываются, остаётся эмуляция мыши системой. `[не проверено]` | missing | grep по `src/apprt/win32`: ничего | low | S-M |
| 2.12 | Завершение сеанса (logoff/shutdown): `WM_QUERYENDSESSION` всегда «да», `ShutdownBlockReasonCreate` нет; шеллы и фоновые процессы убиваются без предупреждения (на macOS подтверждение выхода работает). `[новое]` | partial | `src/apprt/win32/tray.zig:226-233` | low | S-M |

#### 3. Окна, табы, сплиты, UI (паритет с macOS)

| # | Пункт | Status | Evidence | Impact | Effort |
|---|---|---|---|---|---|
| 3.1 | `window-save-state`: восстановления окон, табов, сплитов при запуске нет; опция игнорируется. `[известно]` | missing | `src/config/Config.zig:2316`; `src/apprt/win32` ключ не читает; macOS: `macos/Sources/Features/Terminal/TerminalRestorable.swift` | med | M |
| 3.2 | Перетаскивание сплит-панели для перестановки (drag на зоны top/bottom/left/right другого сплита, grab handle). На Windows перетаскиваются только табы. `[новое]` | missing | macOS: `Features/Splits/TerminalSplitTreeView.swift:108`, `Ghostty/Surface View/SurfaceDragSource.swift`, `SurfaceGrabHandle.swift`; в `src/apprt/win32` аналога нет (только `tab_drag.zig`) | low-med | M-L |
| 3.3 | Цвета табов (палитра в контекстном меню таба на macOS) и «Show All Tabs» (`toggle_tab_overview`) отсутствуют; меню таба содержит 6 пунктов. `[известно как осознанное]` | missing | `src/apprt/win32/tab_menu.zig:1-5`, `src/apprt/win32/actions.zig:58`; macOS: `Terminal/TerminalTabColor.swift` | low | M |
| 3.4 | Quick terminal: пользователь не может менять размер (окно `WS_POPUP`); поведение при нескольких виртуальных рабочих столах не задано (аналога `quick-terminal-space-behavior` нет, `IVirtualDesktopManager` не используется; что делает показ с другого стола, не проверено). `[известно / не проверено]` | partial | `src/apprt/win32/frame.zig:75`, `docs/windows/CHANGELOG.md:134`; grep `VirtualDesktop` в `QuickTerminal.zig`: нет; macOS: `QuickTerminal/QuickTerminalSpaceBehavior.swift` | low-med | M (resize) / S-M (desktop) |
| 3.5 | Подсветка панели при `present_terminal`/переходах (`HighlightOverlay` на macOS) отсутствует: окно просто выходит вперёд. `[новое]` | missing | macOS: `Ghostty/Surface View/SurfaceView.swift:922-975`; в `src/apprt/win32` нет | low | S-M |
| 3.6 | Анимации (разворот табов, slide quick terminal, bell border) не учитывают системное «Animation effects off» (`SPI_GETCLIENTAREAANIMATION`). `[новое]` | missing | grep по `src`: пусто; `src/apprt/win32/tab_anim.zig` | low | S |
| 3.7 | `window-subtitle` не пере-применяется при reload конфига до следующей смены заголовка. `[известно]` | bug | `docs/windows/CHANGELOG.md:338` | low | S |
| 3.8 | Undo: не предлагается для закрытий от tmux, IPC и выхода дочернего процесса; создание через меню профилей, tray и jump list не отменяемо; `close_all_windows` не отменяется, если существует quick terminal (требует только `.normal` окна). `[известно + A-M6]` | partial | `docs/windows/CHANGELOG.md:186,319,343`; `src/apprt/win32/actions/undo_actions.zig:170` | low | S-M |
| 3.9 | Припаркованные (закрытые, ждущие undo) поверхности всё ещё звонят и мигают в панели задач: `bell.ring` не проверяет `parked`. `[A-M3, открыт]` | bug | `src/apprt/win32/bell.zig:23-50` (нет `parked`) | low | S |
| 3.10 | `step_resize` при перетаскивании между мониторами с разным DPI щёлкает по старому размеру ячейки на 1-2 шага. `[A-M9, открыт]` | bug | `.superpowers/sdd/M5-windows-extras/final-review-A.md:99-102` | low | S |
| 3.11 | `macos-icon*`, `macos-window-shadow`, `macos-titlebar-style`, `macos-window-buttons`, `macos-hidden`, `macos-dock-drop-behavior`: аналогов нет или решено «не делать». Для `macos-dock-drop-behavior` естественный аналог (папка на иконку на панели задач или на `ghostty.exe`) не проверен. `[известно / не проверено]` | missing | `docs/windows/parity-audit.md` строка «macos-icon*»; `src/config/Config.zig:3526` | low | - / S |
| 3.12 | Меню-бара нет (palette и tray его заменяют): пункты macOS «Reload Configuration», «Change Title...», Help-ссылки доступны только через palette или привязки. Осознанно, как у GTK. `[известно]` | missing | `docs/windows/parity-audit.md` (Settings UI: won't do) | low | - |

#### 4. Шрифты и рендер

| # | Пункт | Status | Evidence | Impact | Effort |
|---|---|---|---|---|---|
| 4.1 | Текст тоньше и бледнее, чем в Windows Terminal: растеризация только FreeType (grayscale AA), DirectWrite используется лишь для поиска файла шрифта; `font-thicken` на Windows не работает; `alpha-blending` по умолчанию `linear-corrected`. Реального ClearType/DirectWrite-контраста нет. Вывод из `issues-after-v1.md` §1b, визуально не сравнивал. `[обновлено]` | partial | `src/config/Config.zig:348-350,415-419`, `src/font/directwrite.zig:1-6`, `src/font/WindowsFontFile.zig` | med | L (DirectWrite-растеризатор или stem darkening) |
| 4.2 | Цветные emoji COLRv1 (Segoe UI Emoji на Win11) не рисуются FreeType-путём; используется Noto (см. 1.3). `[известно]` | partial | `docs/windows/CHANGELOG.md:132`, `docs/windows/SPEC.md:429` | low-med | M (после 1.3 станет заметнее) |
| 4.3 | `window-colorspace = display-p3` не работает (D3D11-шейдеры не конвертируют); HDR, wide gamut и exclusive fullscreen вынесены в non-goals v1. `[известно]` | partial | `src/config/Config.zig:2228`, `src/renderer/d3d11/Frame.zig:447-449`, `src/renderer/d3d11/RenderPass.zig:291-293`, `docs/windows/SPEC.md:26`, `docs/windows/m1/ledger.md:162` | low | M-L |
| 4.4 | `background-blur` это включено/выключено (DWM Acrylic), радиус игнорируется; Acrylic нужен включённый «Transparency effects». `[известно]` | partial | `docs/windows/parity-audit.md`, `docs/windows/CHANGELOG.md:135` | low | - |
| 4.5 | Выбор GPU-адаптера отсутствует (создаётся устройство на адаптере по умолчанию, WARP как запасной); приоритет задаётся только Windows Graphics Settings. `[новое]` | missing | `src/renderer/d3d11/Device.zig:30-44` | low | S |
| 4.6 | Облачные и удалённые шрифты (нелокальный loader) пропускаются при discovery. `[известно в коде]` | partial | `src/font/directwrite.zig:4-5` | low | S |
| 4.7 | Хвосты латентности привязаны к кадру 60 Гц: `tui-latency` owned p95 14-16 мс против гейта 6; `input-latency` 6-11 мс; `split-many` teardown на границе 100 мс; `tmux-cli` spawn p95 57 мс. p50 около 1 мс. `[известно]` | partial | `docs/windows/m5/acceptance.md:42-45`, `docs/windows/m6/acceptance.md:36`, `src/renderer/d3d11/SwapChain.zig:126-127` (max frame latency 1, waitable object) | med | M-L (present без ожидания кадра, режим tearing) |
| 4.8 | RAM: quick terminal (+10 МБ) и custom shader вне бюджета (решение владельца); per-feature RAM-строки M5 (профили, update, undo, external tmux, crash handler) не замерены (нет рецептов). `[известно]` | partial | `docs/windows/m3/acceptance.md:84,98`, `docs/windows/m5/acceptance.md:45` | low | S-M |

#### 5. Оболочки, ConPTY, tmux-shim, WSL

| # | Пункт | Status | Evidence | Impact | Effort |
|---|---|---|---|---|---|
| 5.1 | pwsh и cmd интеграция знает только фичу `title`; нет `cursor` (полоса в приглашении), `path`, `ssh-env`, `ssh-terminfo`, `sudo`. Upstream-скрипты bash/zsh/fish имеют все. `[новое]` | partial | `src/shell-integration/pwsh/ghostty.ps1:14` (единственная проверка `GHOSTTY_SHELL_FEATURES`), `src/termio/shell_integration.zig:304` (полный список фич) | med | M |
| 5.2 | `TERM=xterm-ghostty` по ssh на хост без записи ломает полноэкранные программы (особенно Windows OpenSSH из pwsh). Лечится реализацией `ssh-env`/`ssh-terminfo` в `ghostty.ps1` (п. 5.1); пока: `TERM=xterm-256color` вручную. `[известно]` | bug | `docs/windows/CHANGELOG.md:315-316`, `docs/windows/feature-checklist.md:110` | med | M (вместе с 5.1) |
| 5.3 | WSL: путь из OSC 7 Linux-вида (`/home/u`) не переводится в дисковый путь и отбрасывается (`OSC 7 path is not a local drive path, ignored`), поэтому новый таб/сплит из WSL-таба не наследует каталог, proxy-иконка и `window-subtitle` не работают; в Windows Terminal это решено `wsl.exe --cd`. UNC отвергнут намеренно (утечка NTLM по SMB); `\\wsl.localhost` исключением не сделан. Не проверено запуском. `[новое]` | partial | `src/termio/stream_handler.zig:1609-1621`, `docs/windows/SPEC.md:1040-1043` | med для WSL | M |
| 5.4 | cmd: OSC 133 `D` без кода выхода, поэтому `command_finished` для cmd нет; `jump_to_prompt` работает. `[известно]` | partial | `docs/windows/CHANGELOG.md:314` | low-med | M |
| 5.5 | Автоматического secure input при вводе пароля нет (ConPTY без termios). `[известно, по дизайну]` | missing | `docs/windows/CHANGELOG.md:307`, `src/termio/Exec.zig:373-378` | low | - (эвристики) |
| 5.6 | tmux-shim: `select-layout` кроме `main-vertical`/`tiled` ничего не делает; `capture-pane` только видимый экран; `-L/new-session/attach` только в external-режиме; после reload `wait-after-command` теряется; сплит, ответ на который пришёл после таймаута клиента, оставляет `__idle` pane; external-режим требует Ghostty в PATH. Server persistence и detach/attach это non-goal. `[известно]` | partial | `docs/windows/CHANGELOG.md:184-194,317-318` | low | M |
| 5.7 | Bundled ConPTY отключается на весь процесс после любой ошибки создания; установка через winget-portable (symlink) использует inbox-консоль; Cygwin требует `/cygdrive/...` для `TERMINFO`. `[известно]` | partial | `docs/windows/CHANGELOG.md:329-332,316` | low | S |
| 5.8 | `+edit-config`: GUI-редактор определяется только по PE-subsystem; консольный редактор со своим окном запускается внутри Ghostty. `[известно]` | partial | `src/cli/edit_config.zig:237-249`, `docs/windows/CHANGELOG.md:322-323` | low | S |
| 5.9 | Падение под heap lock не оставляет дамп (таймаут 10 с молча, B-M10). `[известно]` | partial | `docs/windows/CHANGELOG.md:321`, `.superpowers/sdd/M5-windows-extras/final-review-B.md:123-125` | low | S |

#### 6. CLI, IPC, автоматизация

| # | Пункт | Status | Evidence | Impact | Effort |
|---|---|---|---|---|---|
| 6.1 | CLI-действия (`+show-config`, `+validate-config`, `+list-themes`, `+version`) из pwsh и cmd: `ghostty.exe` GUI-subsystem, консоль присоединяется через `AttachConsole(PARENT)`, но cmd и pwsh не ждут GUI-процесс: приглашение возвращается раньше вывода; интерактивный `+list-themes` борется с шеллом за stdin. Работает с pipe, `start /wait`, в Git Bash. Это записано только в SPEC. Лечится консольным companion-exe (`ghostty-cli.exe` или `.com`). `[новое в gap-листах]` | partial | `src/os/windows_console.zig:1-12`, `docs/windows/SPEC.md:481-482` | med | M |
| 6.2 | Скриптинг: на macOS AppleScript и App Intents (input text, key/mouse events, list terminals, perform action, focus, close, command palette); на Windows IPC даёт только `new-window`, `new-tab`, `toggle-quick-terminal`, остальные операции только в тестовом режиме. `[известно]` | partial | `src/apprt/win32/ipc/ops.zig:5-8,98-112`; macOS: `macos/Sources/Features/AppleScript/`, `Features/App Intents/` | low-med | M-L |
| 6.3 | `+ssh-cache`: блокировка файла отключена на Windows, права не выставляются; параллельные ssh-сессии могут испортить кэш. `[новое]` | partial | `src/cli/ssh-cache/DiskCache.zig:100,158,202,263` | low | S |
| 6.4 | libghostty C API на Windows не поддержан (`global.zig` TODO) и `setlocale` fallback на Windows это заглушка. Код приложения не затрагивает. `[известно upstream]` | stub | `src/global.zig:70`, `src/os/locale.zig:45` | low | - |

#### 7. Установка, обновления, релиз

| # | Пункт | Status | Evidence | Impact | Effort |
|---|---|---|---|---|---|
| 7.1 | Сборки без подписи: SmartScreen «Unknown publisher», Smart App Control блокирует setup и exe без «Run anyway». Хук `-SignCommand` в `release.ps1` готов, сертификата нет. `[известно]` | missing | `docs/windows/CHANGELOG.md:416-418`, `dist/windows/release-notes.md:9` | high (охват) | L (сертификат и процесс) |
| 7.2 | «Open Ghostty here» отсутствует после установки по умолчанию: задача installer `explorer` с `Flags: unchecked`; в Win11 только в классическом меню «Show more options». Верхнее меню требует `IExplorerCommand` и sparse-пакет с identity. `[известно]` | partial | `dist/windows/installer/ghostty.iss:83`, `docs/windows/CHANGELOG.md:305-306` | med | S (галочка по умолчанию) / L (верхнее меню) |
| 7.3 | Только per-user установка; нет per-machine, MSIX, winget, scoop. `[известно]` | missing | `docs/windows/CHANGELOG.md:419-420`, `docs/windows/feature-checklist.md:131,137` | med | M-L |
| 7.4 | Обновления: только проверка и toast, автоустановки нет (`auto-update = download` логирует предупреждение); клик по toast из Action Center после выхода Ghostty ничего не делает; пользователи, у которых работает только standalone-процесс, уведомлений не получают; `auto-update-channel = stable` фактически равно «все win- релизы». `[известно]` | partial | `src/apprt/win32/update/Updater.zig:464`, `docs/windows/CHANGELOG.md:131,395`, `docs/windows/m5/acceptance.md:37` | low-med | M |
| 7.5 | ARM64: собирается `aarch64-windows-gnu` (не msvc), юнит-тесты на устройстве не гоняются, workflow CI для ARM64 не создан (в `.github/workflows` только upstream-файлы). `[известно]` | partial | `docs/windows/CHANGELOG.md:410-412,421,425-428`, `.github/workflows/` | med | M |
| 7.6 | Шаблон release-notes не содержит раздела «Known gaps» (M6 acceptance ссылается на него); в notes только «Unsigned». `[новое]` | partial | `dist/windows/release-notes.md` (34 строки), `docs/windows/m6/acceptance.md:44` | low | S |
| 7.7 | Синхронизация с upstream: `windows` на 548 коммитов впереди `upstream/main`, ядро (вне `win32` и `d3d11`, `tmux_shim`) тронуто в 95 файлах (+15.9 тыс. строк); решено не ребейзить до v1.0. Локальный `upstream/main` = `68640f304` (2026-10-26), свежее не fetch-ил (сеть не использовал). `[известно, не проверено]` | partial | `git log upstream/main..windows`, `.superpowers/sdd/M6-release/progress.md:58`, `.superpowers/sdd/M5-windows-extras/final-review-B.md:106-110` (M7: список core-касаний в SPEC) | med | M-L (каждый merge) |
| 7.8 | Установка/удаление: Retry-кнопка защиты «Ghostty запущен» проверена только руками; удаление не чистит jump list (его убирает Проводник вместе с ярлыком); guard опирается на окно трея (`windows-single-instance = false` его обходит). `[известно]` | partial | `docs/windows/CHANGELOG.md:422-423`, `.superpowers/sdd/M5-windows-extras/final-review-C.md:100-102` (M9) | low | S |

#### 8. Доступность и локализация

| # | Пункт | Status | Evidence | Impact | Effort |
|---|---|---|---|---|---|
| 8.1 | Экранный диктор и UI Automation: провайдера нет вообще (`WM_GETOBJECT`/`IRawElementProvider` в `src/apprt/win32` нет), `selection_changed` отложен. Окна диалогов используют настоящие `BUTTON`, их Narrator читает; терминальное содержимое не читается. На macOS в `SurfaceView_AppKit.swift` 18 мест accessibility. `[известно]` | missing | `src/apprt/win32/actions.zig:54-57`, grep по `src/apprt/win32`: нет | high (для a11y-пользователей) | L |
| 8.2 | Системная каретка и события (`CreateCaret`, `NotifyWinEvent`) отсутствуют: Magnifier и Narrator не следят за курсором терминала. `[новое]` | missing | grep по `src/apprt/win32`: нет | med | S-M |
| 8.3 | Локализация: `i18n.init` на Windows сразу возвращается; интерфейс (диалоги, меню, toast) только английский. На GTK есть `po/` с переводами. `[новое]` | missing | `src/os/i18n.zig:32-33`, каталог `po/` | low | L |
| 8.4 | High contrast: учтён (нет прозрачности, системные цвета). Reduce motion: нет (п. 3.6). `[проверено]` | partial | `src/apprt/win32/composition.zig:172,387,417` | low | S |

#### 9. Конфигурация: ключи и их документация

| # | Пункт | Status | Evidence | Impact | Effort |
|---|---|---|---|---|---|
| 9.1 | Доки в `Config.zig` говорят «macOS only» или «GTK only» про ключи, которые Windows реализует: `window-vsync`, `window-position-x/y`, `window-theme`, `window-show-tab-bar`, `window-titlebar-background/foreground`. Пользователь Windows думает, что они не работают. Наоборот `window-colorspace` написано «macOS» и верно. `[новое]` | partial | `src/config/Config.zig:2098,2215,2280,2351,2355,2362`, ключи читает `src/apprt/win32/*` (`window-vsync` через `src/renderer/D3D11.zig:157-207`) | low | S |
| 9.2 | `bell-audio-path` только WAV (масштаб громкости только PCM 8/16 бит; другие форматы не играют или на полной громкости). `[известно]` | partial | `src/config/Config.zig:3365-3367`, `docs/windows/parity-audit.md` | low | M |
| 9.3 | `drag-handle` игнорируется (заголовок всегда тянется). `font-thicken(-strength)` без эффекта (см. 4.1). `macos-auto-secure-input` без аналога (5.5). `[известно]` | partial | `docs/windows/parity-audit.md` | low | - |
| 9.4 | `TERMINFO`: два правила переписывают его по-разному (bash-ветка мёртвая, `Exec.zig` перезаписывает). Косметика, но путаница в доках (B-M4). `[A/B minors]` | partial | `.superpowers/sdd/M5-windows-extras/final-review-B.md:88-93` | low | S |

#### 10. Технический долг: parked минимумы из ledgers, проверенные по коду

Закрытые в fix-wave (A-I1, A-M1, A-M2, B-I1, B-M1, B-M2, B-M3, B-M9, C-C1, C-I1, C-I2, C-M1, C-M2) не перечисляю. Открытыми остались (не все перепроверял; отмечено):

| # | Пункт | Status | Evidence | Impact | Effort |
|---|---|---|---|---|---|
| 10.1 | A-M4: при OOM `undo.drain` оставляет запись в двух местах, возможен double free. Форма кода всё ещё прежняя. | bug | `src/apprt/win32/undo.zig:71-82` | low | S |
| 10.2 | A-M5: `bell.playScaled` может освободить буфер, который winmm ещё проигрывает (не перепроверил). | bug | `src/apprt/win32/bell.zig:96-130`, `.superpowers/sdd/M5-windows-extras/final-review-A.md:80-83` | low | S |
| 10.3 | A-M7: `scrollbar.configChanged` обходит только `app.windows`, припаркованные табы пропускает (не перепроверил). | bug | `src/apprt/win32/scrollbar.zig:196` | low | S |
| 10.4 | A-M8: `WaitForCommitCompletion` на UI-потоке без таймаута (зависнет при застрявшем DWM, TDR, RDP). Условие `waitBeforeErase` ограничивает только видимость. | partial | `src/apprt/win32/composition.zig:226-232` | low-med | S |
| 10.5 | A-M10 / B-M5: `Exec.shellBusy` на UI-потоке делает снимок процессов и читает PE с диска для каждого cmd-таба; гонка на `subprocess.integration`. | partial | `src/termio/Exec.zig:2395*` | low | S |
| 10.6 | B-M6: `Sleep(300)` на UI-потоке после запуска TabTip. | partial | `src/apprt/win32/osk.zig:88` | low | S |
| 10.7 | B-M8: гонка в отмене проверки обновлений (утечка handle, winhttp.dll остаётся загруженным), не перепроверил. | bug | `.superpowers/sdd/M5-windows-extras/final-review-B.md:112-116` | low | S |
| 10.8 | C-M6/M7/M8: `Test-ConfigTranslucent` не видит `config-file`/тему с прозрачностью; справка `+install-explorer-integration` не упоминает `--force`; SPEC §13 всё ещё описывает release через GitHub Actions. | partial | `.superpowers/sdd/M5-windows-extras/final-review-C.md:65-110` | low | S |

#### 11. Тесты и процесс

| # | Пункт | Status | Evidence | Impact | Effort |
|---|---|---|---|---|---|
| 11.1 | Ручные проверки владельца M5 (exit checklist 8, 10 пунктов) всё ещё PENDING: Explorer, jump list и WSL-профиль, update toast, secure input и OBS, undo, touch keyboard, `TERM=xterm-ghostty` в Git Bash, external tmux, GUI-референсы bundled-консоли. Ручные проверки M6 тоже открыты. `[известно]` | partial | `docs/windows/m5/acceptance.md:52-61`, `docs/windows/m6/acceptance.md:44` | med | S (для владельца) |
| 11.2 | vt-smoke: нет референсов 96 dpi для `kitty-image`, `underline-colors`, `wide-cjk` (SKIP), то есть Kitty/SGR 58/CJK не имеют визуальной регрессии. `[известно]` | partial | `docs/windows/m6/acceptance.md:28` | med | S |
| 11.3 | e2e `scrollbar` флакует (5/5, затем 2/3), «hardening post-v1»; возможен настоящий дефект состояния полосы. `[известно]` | partial | `docs/windows/m6/acceptance.md:25`, `.superpowers/sdd/M6-release/progress.md:66` | low-med | S-M |
| 11.4 | `stream-integrity` на 50 МБ не заканчивается на Debug (с M1), `split-many` teardown на границе гейта. `[известно]` | partial | `docs/windows/m5/acceptance.md:45` | low | S |
| 11.5 | Визуальные дефекты проходят сквозь e2e (`tab-rename.ps1` не снимает пиксели; `About`-иконка и центрирование проверены не были); CI нет, e2e требует разблокированный рабочий стол. Рекомендация: пиксельные проверки в сценариях UI-контролов. `[новое]` | partial | `test/windows/e2e/tab-rename.ps1`, `docs/windows/feature-checklist.md:125` | med | M |
| 11.6 | `claude-team.ps1` на RC не запускался (tmux-shim проверен на реальном Claude Code в M4). `[известно]` | partial | `docs/windows/m6/acceptance.md:40` | low-med | S |

#### 12. Не удалось проверить (нужен запуск или сеть)

- Цвета Claude Code: поведение клампа при `TMUX` взято из `issues-after-v1.md` §1; бинарник не читал, запуска не было.
- Реальные эффекты 1.2 (GDI alpha на стекле), 2.1 (аккорды клавиш без win32-input-mode), 3.4 (показ quick terminal с другого виртуального стола), 5.3 (наследование каталога в WSL): выводы по коду и SPEC, без GUI.
- Наличие темы Campbell среди 819 встроенных тем (пакет вне репо).
- Свежесть upstream: `git fetch` не делал; объём расхождения считал по локальному `upstream/main` (`68640f304`).
- CLI-действия `+list-fonts`, `+show-face`, `+boo`, `+ssh-cache` на Windows (есть упоминания в CHANGELOG и упаковочном e2e, отдельных сценариев нет).
- Windows 10 (best-effort по DECISIONS) и ARM64-железо.
- Реальный toast из Action Center, TDR и поведение под RDP/блокировкой сессии (в доках отмечены как manual).
- Ligatures: путь только ядра (HarfBuzz), скриншотов нет.
- Touch/pen (2.11), `macos-dock-drop-behavior`-аналог (3.11).

#### 13. Проверено, пробела нет

- apprt actions: 67/70, коды обработчиков в `src/apprt/win32/actions/*.zig` без заглушек.
- Мышь: колесо с precision, горизонтальное колесо, X1/X2, захват, `focus-follows-mouse`: `src/apprt/win32/mouse.zig`.
- Клавиатура: AltGr, dead keys, NumLock/CapsLock, раскладка RU: `src/apprt/win32/key.zig`, `keyboard.zig`.
- `window-vsync`, tearing, device loss, high contrast, DPI, remote session: найдены в коде и тестах.
- Keybind-действия `Binding.zig`: на Windows молчат только `toggle_tab_overview`, `show_gtk_inspector`, `paste_from_selection` (нет selection clipboard).

#### 14. Предлагаемый порядок на следующую версию

1. S-пакет за один заход (почти всё high/med): 1.1 (одна переменная), 1.2 (popup-редактор), 1.3 (убрать Noto на Windows), 7.2 (галочка Explorer), 2.7, 2.8, 9.1, 7.6, 1.6.
2. M-пакет «буфер и ссылки»: 2.3 `CF_HDROP`, 2.6 ссылки с `\`, 2.4 HTML, 2.5 selection.
3. M-пакет «оболочки»: 5.1/5.2 (`ssh-env`, `ssh-terminfo`, `cursor` для pwsh), 5.3 WSL cwd, 6.1 console companion, 2.1 `win32-input-mode`.
4. Продуктовый: 3.1 `window-save-state`, 1.4(a) DCS passthrough в shim.
5. Большие: 7.1 подпись, 8.1 UIA, 4.1 DirectWrite-растеризатор, 1.5 багрепорт msys2-runtime, 7.7 upstream merge, 7.5 ARM64 CI.

## 7. Owner decisions for win.2 (2026-10-29)

| Item | Decision |
|---|---|
| Tab rename | EDIT in an owned borderless popup over the tab, themed via `WM_CTLCOLOREDIT`, font and centring after macOS `TabTitleEditor.swift` (§ 3a) |
| tmux shim | `windows-tmux-shim = false` by default; `tmux.exe` stays in the package; tmux e2e enable the key |
| Git Bash palette | No change (upstream default palette, same as macOS) |
| Explorer task | Installer task `explorer` checked by default |
| Kitty in Git Bash | Investigate the first-key loss with the bundled ConPTY under MSYS first (compare with Windows Terminal); switch MSYS to bundled only once the key is not lost. Until then images are for pwsh/cmd |
| Thin/pale text | Compare `alpha-blending = native` and `font-thicken = true` first; make the better one the Windows default; DirectWrite rasterizer later |
| Symbols/emoji | Skip embedded Noto on Windows like macOS: Segoe UI Symbol / Segoe UI Emoji (§ 4) |
| win.2 scope | Small fixes (above + `C:\path:12` links, Explorer file drop `CF_HDROP`, `click-repeat-interval`) + Kitty (tmux off, `a=q` reply path, GUI render check) + shells (pwsh/cmd `ssh-env`/`ssh-terminfo`/`cursor`, WSL cwd) |
| Win11 top-level "Open Ghostty here" | In win.2. `IExplorerCommand` COM DLL + unsigned sparse package (publisher with the unsigned-namespace OID `2.25.311729368913984317654407730594956997722=1`, `windows.fileExplorerContextMenus`), registered/removed by the installer (`Add-AppxPackage -ExternalLocation`), classic verb kept for Windows 10. DLL replacement on upgrade goes through the existing Retry loop. Tested only on the owner's machine (no clean/foreign machine available): residual risk noted in the release notes. Effort M (~2–3 days) |
