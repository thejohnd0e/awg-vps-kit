# AWG VPS Kit (кратко по-русски)

[English](README.md) · **Русский**

Установщик AmneziaWG (userspace `amneziawg-go`, UDP 443) для VPS и команда `awg-client` для управления
клиентами. UDP-транспорт работает там, где провайдер душит TCP до зарубежных хостеров. Полная
документация на английском: [README.md](README.md).

## Часть семейства VPS-китов

`quality-vps-kit` — один из нескольких независимых инструментов одного процесса: сначала оценить VPS, затем поднять на нём VPN/proxy-сервисы.

| Проект | Назначение |
|---|---|
| [quality-vps-kit](https://github.com/thejohnd0e/quality-vps-kit) | read-only оценка нового VPS |
| [xray-vps-kit](https://github.com/thejohnd0e/xray-vps-kit) | установщик сервера VLESS/Reality и управление клиентами |
| **awg-vps-kit** (этот репозиторий) | установщик сервера AmneziaWG и управление клиентами |
| [hysteria-vps-kit](https://github.com/thejohnd0e/hysteria-vps-kit) | установщик сервера Hysteria2 и управление клиентами |

Киты независимы: ни один не изменяет и не требует остальных.

## Требования

Debian 12/13 (рекомендуется) или Ubuntu 22.04+, root, публичный IPv4 и открытый UDP-порт (по умолчанию 443;
откройте его и в файрволе хостера), 1 vCPU и 1 ГБ RAM (бинарники собираются из официальных исходников,
это занимает несколько минут), виртуализация KVM/Xen/VMware с `/dev/net/tun`, x86_64 или aarch64.

Намеренно не поддерживается: **firewalld** (поддерживается только `ufw` и собственная таблица nftables
`awg_nat`; при активном firewalld туннель блокируется) и **IPv6** (туннель только IPv4: клиент с нативным
IPv6 отправляет этот трафик мимо VPN).

## Установка

```bash
curl -fsSL https://raw.githubusercontent.com/thejohnd0e/awg-vps-kit/master/install.sh | bash -s -- --subnet 10.79.0 --first-client user_01
```

Скрипт при необходимости ставит `git`, кладёт кит в `/opt/awg-vps-kit` и в конце печатает конфиг первого
клиента. Подробности и все опции: [README.md](README.md).

## Клиенты

```bash
awg-client add NAME    # создать клиента
awg-client show NAME   # показать конфиг ещё раз
awg-client list        # список
awg-client remove NAME # отозвать клиента
```

Одно устройство — один клиент; конфиг одного устройства нельзя использовать на другом.

## Обновление

```bash
curl -fsSL https://raw.githubusercontent.com/thejohnd0e/awg-vps-kit/master/update.sh | bash
```

Добавьте `-s -- --check` после `bash`, чтобы только проверить наличие новой версии. Удаление и остальное:
[README.md](README.md).
