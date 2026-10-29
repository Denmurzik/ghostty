# Следующая версия (после win.2): что осталось

Дата: 2026-10-29. Что не вошло в `1.3.2-dev-win.2`, по приоритету. Источники:
`issues-after-v1.md` (§ 6a аудит, статусы после win.2), `m7/msys-key-loss.md`,
ledger M7 (`.superpowers/sdd/M7-win2/progress.md`), финальное ревью M7.

## Высокий приоритет

1. **Пункт «Open Ghostty here» в основном меню Windows 11.**
   - Windows отказывает неподписанному sparse-пакету с исполняемой активацией: ошибка 0x80073D2B, событие AppXDeploymentServer 796.
   - Нужен настоящий сертификат подписи кода (Authenticode/Azure Trusted Signing). С ним подписываем `ghostty-explorer.msix` и издателя.
   - Код готов: `src/explorer_command/` (DLL прошла ревью), `dist/windows/sparse/`, ветка регистрации в установщике сейчас выключена.
   - Проверить, что `ghostty.exe`, запущенный из меню, не получает identity пакета: `ENABLE_PROCESS_TREE` действует только на детей.
2. **Подпись сборок** (audit 7.1): SmartScreen «Unknown publisher», Smart App Control. Тот же сертификат, что и в п. 1.
3. **Kitty-картинки и SGR 58 в Git Bash.**
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
10. Буфер обмена: rich/HTML копирование (2.4), selection clipboard и OSC 5522 (2.5).
11. Перетаскивание сплитов (3.2), цвета вкладок и «Show All Tabs» (3.3), изменение размера quick terminal (3.4), подсветка панели (3.5).
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
23. Локализация интерфейса (8.3). Устаревшие пометки «macOS only/GTK only» в документации Config.zig (9.1). `bell-audio-path` не только WAV (9.2). `drag-handle` (9.3). Два правила `TERMINFO` (9.4).
24. WSL: кастомный hostname в `wsl.conf` не наследует папку; `/c/x` превращается в `C:\x`.
25. Тесты: нестабильный сценарий scrollbar; латентность на 60 Гц (ограничена кадром); split-many teardown на границе 100 мс; шум запуска процессов в tmux-cli.
26. Ручные проверки владельца: Retry установщика при запущенном Ghostty; ARM64 на устройстве.
