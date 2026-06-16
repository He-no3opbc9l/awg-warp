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

Если нужно задать свой порт для AWG-сервера (по умолчанию — автовыбор, начиная с 39548):

```bash
bash init.sh install --port 27015
```

### Режим без WARP

Если WARP не нужен и трафик должен выходить напрямую через VPS:

```bash
bash init.sh install --no-warp
```

```
Клиент → AWG-туннель → VPS → Интернет
```

### Версия протокола AmneziaWG

По умолчанию используется набор параметров обфускации **1.0** (максимальная совместимость со сторонними клиентами). Для более стойкой обфускации (`S3`, `S4`, диапазоны `H1–H4`, DNS-сигнатура `I1`) можно выбрать **2.0**:

```bash
bash init.sh install --awg-version 2.0
```

> ⚠️ Параметры 2.0 понимает только **свежий** билд AmneziaWG в клиенте. Старый клиент, знающий только 1.0, не подключится к 2.0-серверу. Флаги можно комбинировать: `bash init.sh install --no-warp --awg-version 2.0`.

Скрипт автоматически:
- Установит Go, amneziawg-go, awg-tools
- Развернёт `awg-manager.sh` в `/etc/amnezia/amneziawg/`
- Скачает `warp_setup.sh`, запустит WARP-туннель (если не указан `--no-warp`) и инициализирует AWG-сервер (публичный IP определяется автоматически)

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
| `-P <port>` | Порт AWG-сервера (по умолчанию auto, начиная с 39548) |
| `-V <ver>` | Версия параметров обфускации AmneziaWG: `1.0` (по умолчанию) или `2.0` |
| `-I <iface>` | Сетевой интерфейс сервера (по умолчанию auto) |

## Полное удаление awg-warp

```bash
bash init.sh remove
```

Удаляет **только** компоненты awg-warp: WARP-туннель и AWG-интерфейсы, созданные этим скриптом (определяются по маркерам `.awg_iface_*`). Сторонние AWG-серверы в `/etc/amnezia/amneziawg/` **не затрагиваются**.

> Пакеты системы (`wireguard-tools`, `amneziawg-go`, `awg`) не удаляются.


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

---

## TODO

- [ ] Добавить генерацию `I2–I5` для версии 2.0 (доп. CPS-пакеты со счётчиками, timestamp и случайными данными для большей энтропии). Сейчас в 2.0 генерируется только DNS-сигнатура `I1`.
