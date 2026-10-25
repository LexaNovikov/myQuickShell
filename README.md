# Quickshell panel

Персональная панель для Wayland на Quickshell. В ней есть плеер MPRIS, календарь Google, уведомления с быстрым ответом, Wi-Fi, Bluetooth, ночной режим, управление звуком и яркостью, а также блокировка и переход в сон.

## Возможности

- управление MPRIS-плеером через `playerctl`;
- Wi-Fi через NetworkManager (`nmcli`);
- Bluetooth через BlueZ (`bluetoothctl`);
- громкость PipeWire/PulseAudio и громкость отдельных приложений;
- яркость экрана через `brightnessctl`;
- загрузка событий из приватной ссылки Google Calendar в формате iCalendar;
- уведомления на пять секунд, действия уведомлений и inline reply;
- ночной режим через Noctalia или `wlsunset`;
- блокировка сеанса и сон через Noctalia либо systemd-logind.

## Требования

- Wayland-композитор. Конфигурация проверена с Niri.
- Arch Linux или EndeavourOS для готовой команды установки ниже.
- Quickshell 0.3.2 или новее.
- Шрифт **SF Pro Rounded** для точного совпадения с дизайном. Без него Qt подставит системный шрифт.

Пакеты перечислены в [`dependencies.txt`](dependencies.txt). Noctalia необязательна: без неё ночной режим использует вложенный `bin/wlsunset`, а блокировка отправляется через `loginctl`.

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

## Блокировка экрана

С Noctalia используются её команды блокировки. Без Noctalia вызывается `loginctl lock-session`; поэтому в сеансе должен быть запущен экран блокировки, который реагирует на сигнал systemd-logind. Команда сна выполняется через `systemctl suspend`.

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
| `system-stats.sh` | загрузка процессора и оперативной памяти |
| `assets/` | растровые глифы интерфейса |
| `bin/wlsunset` | fallback для ночного режима на Linux x86_64 |

## Проверка после переноса

```bash
cd ~/.config/quickshell
qmllint shell.qml
command -v qs playerctl nmcli bluetoothctl brightnessctl pactl perl curl
```

Затем проверьте плеер, Wi-Fi, Bluetooth, звук, яркость, календарь и уведомление с быстрым ответом. Если другой демон уведомлений уже запущен, завершите его перед запуском панели: владельцем интерфейса `org.freedesktop.Notifications` может быть только один процесс.
