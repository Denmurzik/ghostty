# Следующая версия (после M8, `1.4.1-dev-win.3`): что осталось

Дата: 2026-11-01. Что не вошло в `1.4.1-dev-win.3` (до этого: 2026-10-29, `1.3.2-dev-win.2`), по приоритету. Номера
пунктов сохранены; закрытые в M8 пункты (10, 25, 28 и часть 11) помечены, новые пункты 29-34 в конце списка «Низкий».
Источники:
`issues-after-v1.md` (§ 6a аудит, статусы после win.2), `m7/msys-key-loss.md`,
ledger M7 (`.superpowers/sdd/M7-win2/progress.md`), финальное ревью M7.

## Высокий приоритет

1. **Пункт «Open Ghostty here» в основном меню Windows 11.**
   - Windows отказывает неподписанному sparse-пакету с исполняемой активацией: ошибка 0x80073D2B, событие AppXDeploymentServer 796.
   - Нужен настоящий сертификат подписи кода (Authenticode/Azure Trusted Signing). С ним подписываем `ghostty-explorer.msix` и издателя.
   - Код готов: `src/explorer_command/` (DLL прошла ревью), `dist/windows/sparse/`, ветка регистрации в установщике сейчас выключена.
   - Проверить, что `ghostty.exe`, запущенный из меню, не получает identity пакета: `ENABLE_PROCESS_TREE` действует только на детей.
2. **Подпись сборок** (audit 7.1): SmartScreen «Unknown publisher», Smart App Control. Тот же сертификат, что и в п. 1.
3. **Kitty-картинки и SGR 58 в Git Bash.** Эксперимент 2026-10-30 (ветка `exp/conpty-msys`, отчёт `.superpowers/sdd/M7-win2/exp-conpty-report.md`): теряется только ПЕРВАЯ клавиша после ресайза (не вся строка; `msys-key-loss.md` исправить), и только когда bash не обработал SIGWINCH сразу; встроенная консоль после каждого ресайза шлёт `CSI 6 n` (её GetConsoleScreenBufferInfo ждёт CPR, GH#18725), его вызывает проверка размера Cygwin. ShowHide/Reparent, duplex-канал, коалесинг ресайзов, Shift-wake не помогли. Дальше: трассировка на стороне MSYS; перепроверить WT скриптом, а не руками.
   - На встроенном ConPTY MSYS теряет целые строки после ресайза, сплита и смены вкладки (7–16 из 36). С win32-input-mode то же самое.
   - В Windows Terminal потерь нет. Главная открытая зацепка: как Ghostty вызывает `ResizePseudoConsole` (сколько раз за одно перетаскивание, в какие моменты) по сравнению с WT. Измерить и повторить поведение WT.
   - Текст баг-репорта для msys2-runtime лежит в `m7/msys-key-loss.md`, он не отправлен.
4. **Экранный диктор / UI Automation** (8.1, 8.2): провайдера UIA нет, системной каретки нет.
5. **`window-save-state`** (3.1): восстановление окон, вкладок и сплитов.

## Средний

6. Растеризатор DirectWrite (4.1): текст как в Windows Terminal. `font-thicken` пока остаётся ручной настройкой.
7. Цветные emoji COLRv1 через FreeType (4.2). VS15 на emoji по умолчанию (😀︎) рисуется как U+FFFD, потому что Noto Emoji больше не загружается: нужен текстовый запасной шрифт последней очереди.
8. Полноценный `win32-input-mode` (2.1). Kitty keyboard protocol: сквозная проверка через ConPTY (2.2).
9. Kitty: `t=s` (shared memory), POSIX-пути от MSYS-клиентов в `t=f`, DCS `tmux;` passthrough (R-M7-11).
10. ~~Буфер обмена: rich/HTML копирование (2.4), selection clipboard и OSC 5522 (2.5).~~ **Сделано в M8** (Tasks 3, 4, 7, 9, 10, 13). Остался предел: чтение 5522 из Git Bash при `windows-conpty = auto` (пункт 32).
11. ~~Перетаскивание сплитов (3.2)~~ **сделано в M8** (Tasks 2, 5, 8, 11, 14); остаются цвета вкладок и «Show All Tabs» (3.3), изменение размера quick terminal (3.4), подсветка панели (3.5).
12. Системный «Animation effects off» в анимациях (3.6, 8.4).
13. CLI-действия из pwsh/cmd: приглашение возвращается раньше вывода (6.1).
14. cmd: OSC 133 `D` без кода выхода (5.4); курсор cmd остаётся во время выполнения команды.
15. ssh.cmd в PATH наследуется дочерними процессами cmd (`cmd /c ssh` из утилит тоже идёт через `ghostty +ssh`).
16. Установщик: per-machine, winget/scoop (7.3); автоустановка обновлений (7.4).
17. ARM64: юнит-тесты на устройстве, msvc-сборка (7.5).
18. Rebase на свежий upstream (7.7).

## Низкий

19. IME через TSF, reconversion (2.9). Сенсор и перо (2.11). Logoff/shutdown block reason (2.12).
20. Глобальные хоткеи при смене раскладки (2.8). Курсоры alias/copy/zoom (2.10).
21. `window-colorspace = display-p3`, HDR (4.3). Радиус `background-blur` (4.4). Выбор GPU (4.5). Облачные шрифты (4.6).
22. tmux-shim: другие `select-layout`, `capture-pane` с историей (5.6). `+ssh-cache` блокировка файла (6.3).
23. Локализация интерфейса (8.3). Устаревшие пометки «macOS only/GTK only» в документации Config.zig (9.1). `bell-audio-path` не только WAV (9.2). Два правила `TERMINFO` (9.4).
24. WSL: кастомный hostname в `wsl.conf` не наследует папку; `/c/x` превращается в `C:\x`.
25. ~~Claude Code на Windows рисует ASCII-заглушки `( )` вместо `◯`~~ **Сделано в M8** (Task 18): дочерние процессы получают `TERMINUS_SUBLIME=1`, когда итоговый `TERM` равен `xterm-ghostty` и переменная не задана. Выключить: `unset TERMINUS_SUBLIME` в rc оболочки при `TERM=xterm-ghostty` или `TERM`, которого нет в списке пакета (пакет проверяет только непустоту: `TERMINUS_SUBLIME=0` и `TERM=xterm-256color` НЕ выключают; пустое `env = TERMINUS_SUBLIME=` удаляет ключ, и Ghostty добавит его снова). Предлагаемый текст для upstream: ниже, отправлять нельзя (R-M8-4).
26. Тесты: нестабильный сценарий scrollbar; латентность на 60 Гц (ограничена кадром); split-many teardown на границе 100 мс; шум запуска процессов в tmux-cli.
27. Ручные проверки владельца: Retry установщика при запущенном Ghostty; ARM64 на устройстве.
28. Лаг ввода, копящийся во вкладке (Git Bash, zsh): **вероятно исправлен в M8** (Task 1: счётчик презентов D3D11, сброс отставания, пересинхронизация в простое; сдвиг времени шейдера `iTime`). Сообщать как «исправление отгружено, доказательство в пакете m8» (Task 24 B4, сценарий `long-tab-lag`); если лаг остался, снять лог с `GHOSTTY_D3D11_PACING_LOG=1` (строки `d3d11 pacer resync` и `slot_timeout=`). Прежняя гипотеза (MSYS + встроенный OpenConsole, п. 3) остаётся запасной.

Новое после M8:

29. **Отмена перемещения сплита** (R-M8-30). Сейчас перемещение не отменяется, а само перемещение сбрасывает записи отмены затронутых вкладок.
30. **Окна, полностью закрытые другими окнами,** не считаются скрытыми (R-M8-22): нет проверки перекрытия, рендер идёт. Нужен тест перекрытия (например, `Present` с `DXGI_STATUS_OCCLUDED` или проверка через DWM).
31. **EcoQoS / `PROCESS_POWER_THROTTLING`** для скрытых окон (R-M8-24): энергия при длительном простое.
32. **Ответы OSC 5522 и DECRQM `?5522`/`?2033` в Git Bash** (R-M8-16): встроенная консоль (inbox) не доставляет ответы на чтение 5522 надёжно и сама отвечает «неизвестно» на DECRQM. Варианты: `windows-conpty = bundled` для Git Bash (см. пункт 3) или обход на стороне ConPTY-обёртки.
33. **Блокировка экрана без окна-получателя.** Подписка WTS (`WTSRegisterSessionNotification`) висит на окне сообщений (message-only). Если проверка Win+L в пакете M8 не пришлёт `screen state locked=true`, нужен запасной вариант: обычное скрытое окно.
34. **Kitty-анимация на D3D11 не проверена** (R-M8-40) и **отладочный слой D3D11 в e2e не захватывается** (ERROR-строки не попадают в `ghostty.log`). Если Task 24 покажет, что кадры анимации не идут, это отдельная задача рендерера.

### Предлагаемые тексты для upstream (только текст, не отправлять: R-M8-4)

- **`is-unicode-supported`** (npm): в ветке `process.platform === 'win32'` добавить признак Ghostty, например
  `|| env.TERM_PROGRAM === 'ghostty'` (Ghostty задаёт `TERM_PROGRAM=ghostty` во всех оболочках; сейчас проверяются только `WT_SESSION`, `TERMINUS_SUBLIME`,
  `ConEmuTask`, `TERM_PROGRAM=Terminus-Sublime`, `TERM_PROGRAM=vscode`, `TERM=xterm-256color`, `TERM=alacritty`, `TERMINAL_EMULATOR=JetBrains-JediTerm`).
  Тогда `TERMINUS_SUBLIME=1` в Ghostty станет не нужен.
- **git-for-windows** (`git-prompt.sh`, `etc/profile.d/git-prompt.sh`): в заголовок окна подставлять путь без управляющих символов,
  `\[\033]0;$TITLEPREFIX:${PWD//[[:cntrl:]]/}\007\]` вместо `\[\033]0;$TITLEPREFIX:$PWD\007\]`: имя каталога с ESC или BEL иначе
  может послать терминалу произвольные OSC (например, 52, запись в буфер обмена). Ghostty обходит это в `ghostty.bash` (Task 6).

## Upstream Ghostty 1.4.0 (вышла 2026-10-27)

Источник: https://ghostty.org/docs/install/release-notes/1-4-0 (7 месяцев, 2889 коммитов).

**Что это значит для порта.** Ветка `windows` уже стоит на upstream `68640f304` (26.10). До тега `v1.4.0` от него всего 6 коммитов: смена версии, польский перевод, тесты NSPasteboard для macOS, VOUCHED. Значит, почти всё ядро 1.4 уже в win.2, включая исправления безопасности. Rebase на `v1.4.0` тривиальный: конфликт только в `build.zig.zon` (версия). После него следующий релиз будет `1.4.0-win.1`. С 26.10 в `upstream/main` пришло 77 коммитов, их тоже взять при rebase.

### Исправления безопасности (в ядре, уже в нашей базе)
- Защита вставки не считала CR концом строки: вставка могла выполнить команду без подтверждения (GHSA-4hwh-wx3w-3fqg).
- Kitty graphics: падения, зависания, огромные выделения памяти, а в отдельных случаях чтение и удаление файлов вне temp (GHSA-mhff-mv4q-fp63).
- tmux control mode: падения (GHSA-hcr9-7hcr-mjm8, GHSA-hp9c-qp4q-cpw3).
- Очистка экрана в scrollback при маленьком `scrollback-limit` портила память (GHSA-w9q4-5jvv-mcv4).
- zsh-интеграция: подобранное имя каталога могло отправить произвольные escape-последовательности, например OSC 52 (GHSA-2r63-vmw6-3m3c). У нас zsh под Git Bash: проверить, что наша копия скрипта совпадает с исправленной.
- Только macOS: OSC 8 и `link` открывали небезопасные локальные файлы и схемы, drag-and-drop обходил защиту вставки, имена файлов с управляющими символами. **Сверить с нашей политикой** `src/apprt/win32/shell_open.zig` и путём drop на Windows.

### Новое в ядре: на Windows работает или заработает само
- Kitty graphics: анимация, относительные размещения (`P=`, `Q=`, `H=`, `V=`), transient-изображения, полное соответствие спецификации, разбор в 16 раз быстрее. Проверить анимацию на D3D11 и паузу, когда вкладка скрыта.
- Сжатие scrollback в простое (`scrollback-compression`, физическая память −70–90 %). Upstream уже поддерживает Windows (`DiscardVirtualMemory`, `src/terminal/mem.zig`). Лимит по умолчанию 10 → 50 МБ. `scrollback-limit` переименован в `scrollback-limit-bytes`, новый `scrollback-limit-lines`.
- Производительность: ASCII-парсинг ×5,7, ресайз с большим scrollback ×6, рендерер в 2,7–11 раз меньше держит lock, большие OSC ×30. Пересчитать наши `latency-baseline.csv` и `ram-baseline.csv`.
- VT: mode 2033 (отчёт о видимости), `CSI 8;rows;cols t` (`vt-window-resize-allowed`), DECSTR, DECBKM, DECRQCRA/XTCHECKSUM, `CSI 19 t`, DECXCPR, overline в terminfo, OSC 133 `click_events=2`, Unicode 18, десятки исправлений совместимости с xterm. Ctrl+L на prompt переносит вывод в scrollback.
- Клавиатура: `modifyOtherKeys` 2 как в xterm, F13–F25, UTF-8 для alt+не-ASCII.
- `+ssh` (у нас уже есть) и `ssh-env`/`ssh-terminfo` через `+ssh`. У `+ssh-cache` позиционные аргументы и `--prune`. `ssh-env` больше не перекрывает `SetEnv`. Сверить с нашими pwsh/cmd обёртками.
- `+explain-config`, пейджер для `+show-config` (`GHOSTTY_PAGER`). `GHOSTTY_SURFACE_ID` выставляется в окружении процессов, у нас уже есть.
- bash-интеграция: реальный код выхода на Bash 4.4+, исправления `PROMPT_COMMAND` и ble.sh. zsh: исправлен `{` в prompt.
- Конфиг: `copy-on-select` теперь `none|primary|clipboard|both` (на Windows по умолчанию `none`), `link-osc8`, `clipboard-write-limit-bytes`, `window-padding-balance = equal`, `~` в `theme`, `command-palette-entry = clear`. Исправлен разбор конфига на границе буфера.
- Темы: +356 (iTerm2-Color-Schemes), 10 изменили цвета.

### Новое, где нужна работа в win32 apprt (upstream сделал для macOS/GTK)
- **Kitty clipboard protocol OSC 5522** (картинки, HTML, события вставки, `clipboard-read`/`clipboard-write`, превью при чтении). **Сделано в M8** (чтение из Git Bash при `auto`: предел, п. 32).
- **Перетаскивание сплитов** (`drag-handle = auto|always|never`): по сплитам, вкладкам и окнам, процессы переезжают вместе со сплитом. **Сделано в M8** (отмена перемещения: п. 29).
- **`middle-click-action`**: **сделано в M8** (Task 13: `primary-paste` вставляет внутренний буфер выделения).
- **Скрытые вкладки освобождают GPU-ресурсы** и не рендерятся: **сделано в M8** (Tasks 12, 15, 17; порог оставить ли сжатие до 1×1 измеряется в Task 24 B2).
- **Отчёт о видимости (mode 2033)**: **сделано в M8** (окна, quick terminal, блокировка, экран выключен, другой виртуальный стол; закрытые другими окнами не отслеживаются: п. 30).
- **Палитра команд**: подсветка совпадений, поиск по инициалам и описаниям, ранжирование (macOS). Перевод палитры на новые языки; у нас i18n на Windows выключен (audit 8.3).
- **Полоса «процесс завершился»** внизу терминала, красная для быстрого или неудачного выхода (`abnormal-command-exit-runtime`, macOS): аналог `show_child_exited` по стилю macOS.
- **«Review Windows…»** при выходе, если в нескольких окнах идут процессы (macOS).
- **Поиск запоминает последний запрос** (macOS).
- Новые actions `move_tab_to_new_window` и `set_window_title` у нас уже реализованы. `prompt_window_title` (GTK) сверить с нашим `prompt_title`.
- `+new-tab` и `+toggle-quick-terminal` (GTK, через запущенный экземпляр): аналог для Windows через наш IPC.

### Изменения поведения, которые надо учесть
- Сочетания по умолчанию: GTK `ctrl+shift+page_up/down` теперь `move_tab`, а `jump_to_prompt` на `ctrl+shift+arrow_up/down`. **Проверено в M8: уже GTK 1.4, менять нечего** (R-M8-6).
- terminfo `Se` возвращает курсор к настроенному `cursor-style`.
- Лимиты: OSC ≤ 8 МиБ, kitty-payload ≤ 65 МиБ, ≤ 64 комбинирующих символа на ячейку.
- В разделе «Windows» release notes: «No Windows GUI roadmap; libghostty supports Windows and is tested in CI». Upstream собирает libghostty-vt под MSVC и GNU, а GUI остаётся нашей задачей.

### План для следующей версии (статус после M8)
1. ~~Rebase на `upstream/main` после `v1.4.0`~~ **сделано в M8** (слияние `m8/merge-1.4`, версия `1.4.1-dev-win.3`, не `1.4.0-win.1`: `build.zig.zon` уже `1.4.1-dev`).
2. ~~Прогнать все unit-группы и e2e `-Milestone all`~~: unit-группы (`win32`, `windows`, `d3d11`, config) прошли в середине M8, итоговый прогон перед релизом; GUI e2e M8 идёт одним пакетом (Task 24, владельца нет за машиной).
3. Проверить на Windows: **осталось** анимацию Kitty на D3D11 (п. 34) и RAM-строку `scrollback` при лимите 50 МБ (Task 24); mode 2033 и `CSI 8 t` сделаны (сценарии `visibility-hidden`, `csi8-resize`).
4. ~~Сверить исправления безопасности по ссылкам и вставке с нашей политикой `shell_open` и drop~~ **сделано в M8** (Task 6: невидимые символы в ссылках, C1 в путях drop, `$PWD` в приглашении Git Bash).
5. ~~OSC 5522, перетаскивание сплитов, освобождение GPU у скрытых вкладок~~ **сделано в M8**. Дальше: отмена перемещения сплита (п. 29), перекрытые окна (п. 30), EcoQoS (п. 31), ответы 5522 в Git Bash (п. 32), палитра команд, полоса «процесс завершился», «Review Windows…», запоминание поиска (раздел выше).
6. Проверка сочетаний клавиш: «уже GTK 1.4, менять нечего» (`ctrl+shift+page_up/down` = `move_tab`, `ctrl+shift+arrow_up/down` = `jump_to_prompt` в нашем дереве с win.1; R-M8-6).
