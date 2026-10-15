# vk-turn-proxy-installer

Установка VK TURN Proxy (режим SRTP+WRAP) поверх WireGuard на VPS одним скриптом.
В конце скрипт выводит всё, что нужно ввести в приложении на iPhone.

```
iPhone (WireGuard) → 127.0.0.1:9000 (локально в приложении)
  → TURN/DTLS + WRAP → <VPS>:56000
    → vk-turn-proxy → 127.0.0.1:51820 (WireGuard) → MASQUERADE → интернет
```

## Требования

- Debian/Ubuntu, root
- Серверная сборка vk-turn-proxy **с поддержкой `-wrap`** (скрипт её не скачивает)

## Установка

```bash
curl -fsSLO https://raw.githubusercontent.com/lauxoff/vk-turn-proxy-installer/main/install-vk-turn-proxy.sh
sudo WRAP_BIN_SOURCE=/путь/к/server bash install-vk-turn-proxy.sh
```

Если WRAP-сборка уже лежит в `/opt/vk-turn-proxy/server`, `WRAP_BIN_SOURCE` не нужен.

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

- ставит `wireguard-tools`, `iptables`, `curl` при необходимости;
- настраивает `wg0` (сохраняя ключ сервера и других пиров), NAT, FORWARD и входящий UDP на TURN-порт (включая ufw);
- создаёт systemd-службу `vk-turn-proxy` с WRAP-ключом (существующий ключ сохраняется);
- пишет клиентский конфиг в `/root/vpn-clients/` и выводит параметры, конфиг и QR-код (если есть `qrencode`).

Повторный запуск безопасен: ключи и существующая настройка сохраняются.
