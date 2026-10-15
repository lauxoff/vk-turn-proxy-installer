# vk-turn-proxy-installer

Установка VK TURN Proxy (режим SRTP+WRAP) поверх WireGuard на VPS одним скриптом.
В конце скрипт выводит параметры и конфиг для клиентского приложения.

## Проекты и приложение

- Оригинальный проект `vk-turn-proxy`: [cacggghp/vk-turn-proxy](https://github.com/cacggghp/vk-turn-proxy).
- Android-приложение: [MYSOREZ/vk-turn-proxy-android](https://github.com/MYSOREZ/vk-turn-proxy-android). Инструкции по установке приложения и настройке клиента смотрите в его README.
- Приложение для iPhone в TestFlight: [VK TURN Proxy для iOS](https://testflight.apple.com/join/ANm6cmDv).

```
Android-клиент → 127.0.0.1:9000 (локальный порт прокси)
  → TURN/DTLS + WRAP → <VPS>:56000
    → vk-turn-proxy → 127.0.0.1:51820 (WireGuard) → MASQUERADE → интернет
```

## Требования

- Debian/Ubuntu, root
- Для SRTP+WRAP скрипт автоматически скачивает серверный бинарник из [Moroka8/vk-turn-proxy](https://github.com/Moroka8/vk-turn-proxy) (версия `v1.10.1`) и проверяет SHA-256.
- Для другой сборки можно указать `WRAP_BIN_SOURCE=/путь/к/server`; бинарник должен поддерживать флаг `-wrap-key`.

## Установка

```bash
curl -fsSLO https://raw.githubusercontent.com/lauxoff/vk-turn-proxy-installer/main/install-vk-turn-proxy.sh
sudo bash install-vk-turn-proxy.sh
```

Если WRAP-сборка уже лежит в `/opt/vk-turn-proxy/server`, она будет использована без скачивания. `WRAP_BIN_SOURCE` позволяет заменить её своей сборкой.

## Опции

| Флаг | Что делает |
|---|---|
| `--dry-run` | показать план, ничего не менять |
| `--print-only` | заново вывести данные для приложения |
| `--client-key ФАЙЛ` | взять приватный ключ клиента из файла |
| `--client-pub КЛЮЧ` | использовать публичный ключ клиента (приватный остаётся на iPhone) |
| `--wg-port N` / `--turn-port N` | сменить порты (по умолчанию 51820 / 56000) |

Переменные окружения: `PUBLIC_IP`, `WG_IFACE`, `WG_SERVER_IP`, `WG_CLIENT_IP`, `WG_SUBNET`,
`DNS_SERVERS`, `CLIENT_MTU`, `LOCAL_PROXY_PORT`, `WRAP_BIN_SOURCE`.

## Что делает скрипт

- ставит `wireguard-tools`, `iptables`, `curl` и `coreutils` при необходимости;
- скачивает подходящую Linux-сборку WRAP из закреплённого релиза и проверяет её SHA-256;
- настраивает `wg0` (сохраняя ключ сервера и других пиров), NAT, FORWARD и входящий UDP на TURN-порт (включая ufw);
- создаёт systemd-службу `vk-turn-proxy` с WRAP-ключом (существующий ключ сохраняется);
- пишет клиентский конфиг в `/root/vpn-clients/` и выводит параметры, конфиг и QR-код (если есть `qrencode`).

Повторный запуск безопасен: ключи и существующая настройка сохраняются.
