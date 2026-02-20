# awg-warp

Двойной туннель **AmneziaWG + Cloudflare WARP** для обхода блокировок.

```
Клиент → AWG-туннель → VPS → WARP-туннель → Cloudflare → Интернет
```

> **Примечание:** совместимо с уже установленными AWG-серверами. Если на VPS уже запущен AWG-интерфейс (awg0, awg1 и т.д.), скрипт создаст новый интерфейс (awg2, awg3 и т.д.) для работы с WARP.

## Установка

```bash
git clone https://github.com/He-no3opbc9l/awg-warp.git
cd awg-warp
bash init.sh install
```

Скрипт автоматически:
- Установит Go, amneziawg-go, awg-tools
- Развернёт `awg-manager.sh` в `/etc/amnezia/amneziawg/`
- Скачает и установит `warp_setup.sh` в `/etc/amnezia/warp/`

После установки запустите WARP:

```bash
bash /etc/amnezia/warp/warp_setup.sh install
```

## Управление пользователями

Все команды выполняются через `/etc/amnezia/amneziawg/awg-manager.sh`.

### Инициализация сервера

```bash
bash /etc/amnezia/amneziawg/awg-manager.sh -i -s <ВНЕШНИЙ_IP_СЕРВЕРА>
```

### Создать пользователя

```bash
bash /etc/amnezia/amneziawg/awg-manager.sh -c -u <имя>
```

Конфиг пользователя будет сохранён в `/root/awg-warp/<имя>.conf`.

### QR-код для подключения

```bash
bash /etc/amnezia/amneziawg/awg-manager.sh -q -u <имя>
```

### Вывести конфиг

```bash
bash /etc/amnezia/amneziawg/awg-manager.sh -p -u <имя>
```

### Удалить пользователя

```bash
bash /etc/amnezia/amneziawg/awg-manager.sh -d -u <имя>
```

### Заблокировать / разблокировать

```bash
bash /etc/amnezia/amneziawg/awg-manager.sh -L -u <имя>   # заблокировать
bash /etc/amnezia/amneziawg/awg-manager.sh -U -u <имя>   # разблокировать
```

## Опции awg-manager

| Флаг | Описание |
|------|----------|
| `-i` | Инициализация сервера (ключи и конфиг) |
| `-c` | Создать нового пользователя |
| `-d` | Удалить пользователя |
| `-L` | Заблокировать пользователя |
| `-U` | Разблокировать пользователя |
| `-p` | Вывести конфиг пользователя |
| `-q` | Вывести QR-код пользователя |
| `-u <user>` | Имя пользователя |
| `-s <host>` | Внешний IP/домен сервера |
| `-N <name>` | Имя AWG-интерфейса (по умолчанию auto: awg0, awg1…) |
| `-I <iface>` | Сетевой интерфейс сервера (по умолчанию auto) |

## Структура файлов

```
/etc/amnezia/
├── amneziawg/
│   ├── awg-manager.sh
│   ├── awg0.conf              # конфиг AWG-сервера
│   └── keys/
│       ├── .server            # внешний IP сервера
│       ├── awg0/              # ключи сервера
│       └── <user>/            # ключи и конфиг пользователя
└── warp/
    ├── warp_setup.sh
    ├── warp0.conf             # конфиг WARP-туннеля
    └── credentials.json       # токен Cloudflare WARP
```
