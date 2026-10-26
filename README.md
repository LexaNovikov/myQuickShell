# Quickshell panel

Персональная панель для Wayland на Quickshell. В ней есть плеер MPRIS, календарь Google, уведомления с быстрым ответом, Wi-Fi, Bluetooth, ночной режим, управление звуком и яркостью, а также блокировка и переход в сон.

## Возможности

- управление MPRIS-плеером через `playerctl`;
- Wi-Fi через NetworkManager (`nmcli`);
- Bluetooth через BlueZ (`bluetoothctl`);
- выбор устройств ввода и вывода PipeWire/PulseAudio, общая громкость и громкость отдельных приложений;
- яркость экрана через `brightnessctl`;
- заряд, здоровье батареи и переключение профилей Eco/Balance/Turbo;
- загрузка событий из приватной ссылки Google Calendar в формате iCalendar;
- уведомления на пять секунд, действия уведомлений и inline reply;
- ночной режим через Noctalia или `wlsunset`;
- собственный экран блокировки через `ext-session-lock-v1`, PAM-пароль и отпечаток пальца;
- экран входа при загрузке в том же стиле через `greetd`, Cage и Quickshell.

## Требования

- Wayland-композитор. Конфигурация проверена с Niri.
- Arch Linux или EndeavourOS для готовой команды установки ниже.
- Quickshell 0.3.2 или новее.
- Шрифт **SF Pro Rounded** для точного совпадения с дизайном. Без него Qt подставит системный шрифт.

Пакеты перечислены в [`dependencies.txt`](dependencies.txt). Noctalia необязательна и используется только для ночного режима; без неё запускается вложенный `bin/wlsunset`. Экран блокировки полностью реализован в Quickshell.

## Установка на Arch Linux / EndeavourOS

Скопируйте весь каталог в стандартное место Quickshell:

```bash
mkdir -p ~/.config/quickshell
cp -a /путь/к/этому/каталогу/. ~/.config/quickshell/
cd ~/.config/quickshell
```

Установите зависимости:

```bash
sudo pacman -S --needed - < dependencies.txt
```

## Установка шрифта

Интерфейс рассчитан на семейство **SF Pro Rounded**. Сам шрифт не лежит в этом каталоге, поэтому его нужно отдельно получить и перенести на новый компьютер. Для текущего оформления нужны как минимум начертания `Regular`, `Semibold` и `Bold`.

Скопируйте файлы `SF-Pro-Rounded-*.otf` в пользовательский каталог шрифтов и пересоберите кэш:

```bash
mkdir -p ~/.local/share/fonts/SF-Pro
cd ~/.local/share/fonts/SF-Pro

# 2. Скачиваем архив с готовыми шрифтами SF Pro
curl -LO https://github.com/sahibjotsaggu/San-Francisco-Pro-Fonts/archive/refs/heads/master.zip

# 3. Распаковываем и достаем нужные файлы
unzip master.zip
mv San-Francisco-Pro-Fonts-master/*.otf .

# 4. Убираем мусор и обновляем системный кэш шрифтов
rm -rf master.zip San-Francisco-Pro-Fonts-master
fc-cache -fv
```

Проверьте, какое семейство выбрал fontconfig:

```bash
fc-match "SF Pro Rounded"
```

Первая строка должна содержать примерно такой результат:

```text
SF-Pro-Rounded-Regular.otf: "SF Pro Rounded" "Regular"
```

Если вместо него выводится `DejaVu Sans` или другой системный шрифт, проверьте имя файла, внутреннее имя семейства и ещё раз выполните `fc-cache -f`. После установки обязательно перезапустите Quickshell, потому что уже запущенный процесс может продолжить использовать старый кэш:

```bash
qs kill
qs -d
```

Без SF Pro Rounded панель запустится, но ширина текста, расположение подписей и визуальное выравнивание глифов могут отличаться.

Включите службы сети и Bluetooth:

```bash
sudo systemctl enable --now NetworkManager.service bluetooth.service
```

Верните исполняемые права вспомогательным файлам, если они потерялись при копировании:

```bash
chmod +x ./*.pl ./*.sh ./bin/wlsunset
```

Запустите панель:

```bash
qs
```

Для просмотра ошибок используйте:

```bash
qs log -f
```

## Автозапуск в Niri

Добавьте в `~/.config/niri/config.kdl`:

```kdl
spawn-at-startup "qs" "-d"
```

После изменения конфигурации Niri перезапустите сеанс или один раз выполните `qs -d` вручную.

## Google Calendar

1. В Google Calendar откройте настройки нужного календаря.
2. Скопируйте **Secret address in iCal format**.
3. Запишите ссылку одной строкой:

```bash
printf '%s\n' 'https://calendar.google.com/calendar/ical/...' > ~/.config/quickshell/google-calendar.url
chmod 600 ~/.config/quickshell/google-calendar.url
```

`google-calendar.url` содержит приватную ссылку. Не публикуйте этот файл и не добавляйте его в публичный репозиторий. Если файл пуст или отсутствует, календарь продолжит работать и покажет отсутствие задач.

## Ночной режим

Настройки панели хранятся в `night-mode.json`.

- Если Noctalia установлена и её файл настроек существует, панель обновляет ночной режим Noctalia.
- В остальных случаях запускается `wlsunset`. В каталоге уже лежит сборка `bin/wlsunset` для Linux x86_64.
- На ARM или другой архитектуре установите системный `wlsunset`: скрипт автоматически выберет его вместо вложенного бинарника.

## Батарея и режимы питания

Заряд, состояние, время до полной зарядки и здоровье аккумулятора читаются напрямую из `/sys/class/power_supply`. На компьютере без батареи панель показывает прочерк и сообщение `No battery detected`.

Кнопки `Eco`, `Balance` и `Turbo` через D-Bus переключают профили `power-saver`, `balanced` и `performance` в power-profiles-daemon. Пакет `power-profiles-daemon` включён в `dependencies.txt`. Доступность Turbo зависит от оборудования и драйвера компьютера.

## Блокировка экрана

Панель использует собственный экран блокировки на Quickshell и не зависит от Noctalia. Он запускается отдельным процессом из каталога `lockscreen/` и блокирует Wayland-сессию через `ext-session-lock-v1`.

- пароль проверяется через системный PAM-профиль `system-auth`;
- отпечаток проверяется параллельно через `pam_fprintd`;
- при выборе сна команда `systemctl suspend` запускается только после того, как композитор подтвердил защищённое состояние экрана;
- при отсутствии `fprintd`, зарегистрированного отпечатка или поддерживаемого сенсора остаётся обычная разблокировка паролем.

После установки `fprintd` зарегистрируйте отпечаток и проверьте его:

```bash
fprintd-enroll
fprintd-verify
```

Для Niri рекомендуется назначить запуск locker-а на сочетание, разрешённое даже во время блокировки. Оно позволит повторно открыть интерфейс, если процесс lock screen аварийно завершится:

```kdl
binds {
    Super+Alt+L allow-when-locked=true { spawn "bash" "-lc" "$HOME/.config/quickshell/session-action.sh lock"; }
}
```

При аварии lock screen Niri намеренно не показывает рабочий стол: сессия остаётся защищённой однотонным фоном. В таком состоянии используйте сочетание выше либо запустите `session-action.sh lock` из другой TTY с правильным `WAYLAND_DISPLAY`.

## Экран входа при загрузке

В каталоге `greeter/` находится отдельный Quickshell-интерфейс для `greetd`. Он использует тот же шрифт, цвета и форму элементов, что панель и lock screen, но запускается до пользовательской сессии. После успешной аутентификации greeter запускает `/usr/bin/niri-session`.

Сначала откройте безопасный preview в текущей сессии. Он не подключён к greetd, не принимает пароль и закрывается по `Esc`:

```bash
cd ~/.config/quickshell
./install-greeter.sh preview
```

Пользователь `greeter` не имеет доступа к домашнему каталогу. Поэтому установщик автоматически копирует SF Pro из `~/.local/share/fonts/SF-Pro/` в `/usr/local/share/fonts/SF-Pro/` и обновляет системный кэш шрифтов.

Установите greeter и назначьте greetd display manager-ом для следующей загрузки:

```bash
sudo ./install-greeter.sh install "$USER"
sudo reboot
```

Установщик:

- проверяет наличие `greetd`, Cage, Quickshell и `niri-session`;
- сохраняет исходные `/etc/greetd/config.toml` и `/etc/pam.d/greetd` в `/etc/greetd/quickshell-backup/`;
- копирует greeter в `/etc/greetd/quickshell-greeter/`, доступный системному пользователю `greeter`;
- устанавливает SF Pro системно, чтобы шрифт был доступен до входа пользователя;
- включает `greetd.service` вместо текущего display manager-а, не останавливая открытую графическую сессию;
- записывает имя пользователя в конфигурацию; на экране входа оно показывается как фиксированная подпись без поля ввода;
- запускает Cage без оконных декораций, поэтому у greeter-а нет рамки и кнопок управления окном.

Если установлен `fprintd` и для выбранного пользователя зарегистрирован отпечаток, проверка пальца запускается сразу при появлении greeter-а и ждёт без короткого таймаута. Если начать вводить пароль, greeter отменит ожидание сенсора и немедленно перезапустит аутентификацию через стандартный `system-local-login`; повторно прикладывать палец после пароля не нужно. На компьютере без сенсора PAM сразу показывает запрос пароля.

Чтобы перенести оформление на ноутбук, скопируйте весь каталог `~/.config/quickshell`, установите зависимости и шрифт, зарегистрируйте отпечаток, проверьте preview и выполните ту же команду установки:

```bash
sudo pacman -S --needed - < dependencies.txt
fprintd-enroll
fprintd-verify
./install-greeter.sh preview
sudo ./install-greeter.sh install "$USER"
sudo reboot
```

После обновления `greeter/shell.qml` повторно выполните `sudo ./install-greeter.sh install "$USER"`, чтобы скопировать новую версию в `/etc/greetd`.

### Возврат к SDDM

Если greeter не запустился, перейдите в TTY через `Ctrl+Alt+F3`, войдите в систему и выполните:

```bash
cd ~/.config/quickshell
sudo ./install-greeter.sh restore-sddm
sudo reboot
```

Вернуть прежнюю конфигурацию greetd и PAM можно отдельно:

```bash
sudo ./install-greeter.sh restore-greetd-config
```

## Разрешения

Если яркость отображается, но не изменяется, добавьте пользователя в группу `video`, затем войдите в систему заново:

```bash
sudo usermod -aG video "$USER"
```

На части ноутбуков `brightnessctl` уже получает доступ через udev, и этот шаг не требуется.

## Структура

| Файл | Назначение |
|---|---|
| `shell.qml` | интерфейс и основная логика панели |
| `audio-status.pl` | текущие аудиоустройства и приложения |
| `google-calendar.pl` | загрузка и разбор iCalendar |
| `google-calendar.url` | приватная ссылка календаря, создаётся пользователем |
| `night-mode-helper.sh` | Noctalia / wlsunset и расписание ночного режима |
| `night-mode.json` | сохранённые параметры ночного режима |
| `session-action.sh` | блокировка и сон |
| `lockscreen/shell.qml` | отдельный безопасный экран блокировки |
| `lockscreen/pam.d/fingerprint` | PAM-профиль проверки отпечатка |
| `greeter/shell.qml` | экран входа через API greetd |
| `greeter/system/` | шаблоны greetd, PAM и запуска через Cage |
| `install-greeter.sh` | preview, установка greeter-а и возврат к SDDM |
| `system-stats.sh` | загрузка процессора и оперативной памяти |
| `assets/` | растровые глифы интерфейса |
| `bin/wlsunset` | fallback для ночного режима на Linux x86_64 |

## Проверка после переноса

```bash
cd ~/.config/quickshell
qmllint shell.qml
qmllint lockscreen/shell.qml
qmllint greeter/shell.qml
command -v qs greetd cage niri-session playerctl nmcli bluetoothctl brightnessctl pactl perl curl fprintd-verify
```

Затем проверьте плеер, Wi-Fi, Bluetooth, звук, яркость, календарь и уведомление с быстрым ответом. Если другой демон уведомлений уже запущен, завершите его перед запуском панели: владельцем интерфейса `org.freedesktop.Notifications` может быть только один процесс.
