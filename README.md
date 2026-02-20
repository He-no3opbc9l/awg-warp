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
- Скачает `warp_setup.sh`, запустит WARP-туннель и инициализирует AWG-сервер (публичный IP определяется автоматически)

## После установки — 2 шага

### Шаг 1 — Создать пользователя

```bash
bash /etc/amnezia/amneziawg/awg-manager.sh -c -u <имя>
```

### Шаг 2 — Получить конфиг

```bash
bash /etc/amnezia/amneziawg/awg-manager.sh -q -u <имя>   # QR-код
bash /etc/amnezia/amneziawg/awg-manager.sh -p -u <имя>   # текстовый конфиг
cat /root/awg-warp/<имя>.conf                             # скопировать конфиг напрямую
```

---

## Управление пользователями

Все команды выполняются через `/etc/amnezia/amneziawg/awg-manager.sh`.

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

## Полное удаление awg-warp

При инициализации `awg-manager.sh -i` оставляет маркер-файл `.awg_iface_<name>` в `/etc/amnezia/amneziawg/`. Скрипт удаления ориентируется именно на эти маркеры — сторонние AWG-серверы в той же папке затронуты **не будут**.

```bash
# 1. Остановить и удалить только AWG-интерфейсы, созданные awg-warp (по маркерам .awg_iface_*)
for marker in /etc/amnezia/amneziawg/.awg_iface_*; do
    [ -f "$marker" ] || continue
    name=$(cat "$marker")
    awg-quick down "$name" 2>/dev/null || true
    systemctl disable "awg-quick@${name}.service" 2>/dev/null || true
    rm -f "/etc/amnezia/amneziawg/${name}.conf"
    rm -rf "/etc/amnezia/amneziawg/keys/${name}"
    rm -f "$marker"
done

# 2. Удалить пользовательские ключи и awg-manager (только если нет чужих конфигов)
if ! ls /etc/amnezia/amneziawg/awg*.conf &>/dev/null 2>&1; then
    rm -rf /etc/amnezia/amneziawg/keys
    rm -f /etc/amnezia/amneziawg/awg-manager.sh
    rmdir /etc/amnezia/amneziawg 2>/dev/null || true
fi

# 3. Остановить и удалить WARP-туннель
wg-quick down /etc/amnezia/warp/warp0.conf 2>/dev/null || true
systemctl disable wg-quick@warp0.service 2>/dev/null || true
rm -f /etc/systemd/system/wg-quick@warp0.service
systemctl daemon-reload
rm -rf /etc/amnezia/warp

# 4. Удалить /etc/amnezia если она стала пустой
rmdir /etc/amnezia 2>/dev/null || true

# 5. Почистить оставшиеся ip rules от WARP
ip rule del fwmark 51820 lookup main suppress_prefixlength 0 priority 90 2>/dev/null || true
ip rule list | grep 'lookup 51820' | awk '{print $1}' | sed 's/://' | \
    xargs -I{} ip rule del prio {} 2>/dev/null || true

# 6. Убрать директорию проекта (опционально)
rm -rf /root/awg-warp
```

> **Не затрагивается:** сторонние AWG/WireGuard-конфиги и интерфейсы без маркера `.awg_iface_*`, пакеты системы (`wireguard-tools`, `amneziawg-go`, `awg`).


---

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
