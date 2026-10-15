#!/usr/bin/env bash
#
# install-vk-turn-proxy.sh — быстрая установка VK TURN Proxy (режим SRTP+WRAP)
# на VPS с WireGuard, для подключения из приложения на iPhone.
#
# Схема:
#   iPhone (встроенный WireGuard)
#     └─ WireGuard Endpoint -> 127.0.0.1:9000   (локальный listener внутри приложения)
#         └─ TURN/DTLS + WRAP -> <VPS>:56000    (транспорт: приложение -> TURN ВК -> VPS)
#             └─ vk-turn-proxy server -> 127.0.0.1:51820 (WireGuard на VPS)
#                 └─ MASQUERADE -> интернет
#
# Скрипт идемпотентный: повторный запуск не ломает рабочую установку.
#
# Использование:
#   bash install-vk-turn-proxy.sh                 # всё автоматически, ключ CLI сгенерировать
#   bash install-vk-turn-proxy.sh --dry-run       # показать план и итоговые значения, ничего не менять
#   bash install-vk-turn-proxy.sh --client-key ФАЙЛ   # взять приватный ключ клиента из файла
#   bash install-vk-turn-proxy.sh --print-only    # только перепечатать значения для приложения
#
set -euo pipefail

#───────────────────────────────────────────────────────────────────────────────
# НАСТРОЙКИ
#───────────────────────────────────────────────────────────────────────────────
WG_IFACE="${WG_IFACE:-wg0}"
WG_PORT="${WG_PORT:-51820}"                 # порт WireGuard на VPS
WG_SERVER_IP="${WG_SERVER_IP:-10.8.0.1}"    # адрес сервера внутри туннеля
WG_CLIENT_IP="${WG_CLIENT_IP:-10.8.0.2}"    # адрес клиента внутри туннеля
WG_SUBNET="${WG_SUBNET:-10.8.0.0/24}"       # подсеть туннеля (для NAT)

TURN_PORT="${TURN_PORT:-56000}"             # UDP-порт, куда стучится приложение
LOCAL_PROXY_PORT="${LOCAL_PROXY_PORT:-9000}" # локальный порт внутри приложения (Endpoint)
DNS_SERVERS="${DNS_SERVERS:-1.1.1.1, 1.0.0.1}"
CLIENT_MTU="${CLIENT_MTU:-1280}"            # для TURN-пути 1280

INSTALL_DIR="${INSTALL_DIR:-/opt/vk-turn-proxy}"
BIN_PATH="${BIN_PATH:-$INSTALL_DIR/server}"
SERVICE_PATH="${SERVICE_PATH:-/etc/systemd/system/vk-turn-proxy.service}"
WG_DIR="${WG_DIR:-/etc/wireguard}"
WG_CONF="$WG_DIR/${WG_IFACE}.conf"
CLIENTS_DIR="${CLIENTS_DIR:-/root/vpn-clients}"
CLIENT_CONF="${CLIENT_CONF:-$CLIENTS_DIR/wg0-client-iphone-turn.conf}"

# Источник WRAP-бинарника. Если он не задан и подходящий бинарь не установлен,
# скрипт скачает закреплённый Linux-релиз совместимого форка и проверит SHA-256.
WRAP_BIN_SOURCE="${WRAP_BIN_SOURCE:-}"
WRAP_BIN_RELEASE="v1.10.1"

DRY_RUN=0
PRINT_ONLY=0
CLIENT_KEY_FILE=""
CLIENT_PUBKEY_OVERRIDE=""

#───────────────────────────────────────────────────────────────────────────────
# ОФОРМЛЕНИЕ
#───────────────────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  B=$'\033[1m'; R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; C=$'\033[36m'; N=$'\033[0m'
else
  B=""; R=""; G=""; Y=""; C=""; N=""
fi
info()  { printf '%s\n' "${C}•${N} $*"; }
ok()    { printf '%s\n' "${G}✓${N} $*"; }
warn()  { printf '%s\n' "${Y}!${N} $*" >&2; }
err()   { printf '%s\n' "${R}✗${N} $*" >&2; }
die()   { err "$*"; exit 1; }
step()  { printf '\n%s\n' "${B}== $* ==${N}"; }
run()   {
  if (( DRY_RUN )); then
    printf '  %s' "${Y}[dry-run]${N}"
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

usage() { sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)     DRY_RUN=1; shift ;;
    --print-only)  PRINT_ONLY=1; shift ;;
    --client-key)  CLIENT_KEY_FILE="${2:?--client-key требует путь к файлу}"; shift 2 ;;
    --client-pub)  CLIENT_PUBKEY_OVERRIDE="${2:?--client-pub требует ключ}"; shift 2 ;;
    --wg-port)     WG_PORT="${2:?--wg-port требует номер порта}"; shift 2 ;;
    --turn-port)   TURN_PORT="${2:?--turn-port требует номер порта}"; shift 2 ;;
    -h|--help)     usage ;;
    *) die "Неизвестный аргумент: $1 (см. --help)" ;;
  esac
done

valid_port() {
  [[ "$1" =~ ^[0-9]{1,5}$ ]] || return 1
  (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

valid_ipv4() {
  local ip="$1" octet
  local -a octets
  [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
  IFS=. read -r -a octets <<<"$ip"
  for octet in "${octets[@]}"; do
    (( 10#$octet <= 255 )) || return 1
  done
}

#───────────────────────────────────────────────────────────────────────────────
# ПРОВЕРКИ
#───────────────────────────────────────────────────────────────────────────────

# Извлекает значение после первого '=' и убирает \r и пробелы по краям.
# ВАЖНО, две ловушки:
#  1) нельзя `awk -F'= *'` — base64-ключ WireGuard сам кончается на '=', и
#     разделитель съел бы последний символ (ключ стал бы 43 байта вместо 44);
#  2) нельзя `sed 's/[[:space:]]*$//'` — на BSD/GNU sed `*` допускает ноль
#     совпадений, и завершающий '=' может быть съеден. Поэтому чистим циклом.
cfg_value() {
  local file="$1" key="$2" val
  [[ -r "$file" ]] || return 0
  val="$(sed -n "s/^${key}[[:space:]]*=[[:space:]]*//p" "$file" | head -1 | tr -d '\r\n')"
  while [[ "$val" == *[[:space:]] ]]; do val="${val%[[:space:]]}"; done
  printf '%s' "$val"
}

step "Проверки окружения"

[[ "$(id -u)" -eq 0 ]] || die "Нужны права root. Запустите через sudo."
(( PRINT_ONLY )) || [[ "$(uname -s)" == "Linux" ]] || die "Скрипт рассчитан на Linux."
[[ "$WG_IFACE" =~ ^[a-zA-Z0-9_.:-]{1,15}$ ]] || die "Некорректное имя WireGuard-интерфейса: $WG_IFACE"
valid_port "$WG_PORT" || die "Некорректный порт WireGuard: $WG_PORT"
valid_port "$TURN_PORT" || die "Некорректный TURN-порт: $TURN_PORT"
valid_port "$LOCAL_PROXY_PORT" || die "Некорректный локальный порт прокси: $LOCAL_PROXY_PORT"
valid_ipv4 "$WG_SERVER_IP" || die "Некорректный IPv4-адрес сервера WireGuard: $WG_SERVER_IP"
valid_ipv4 "$WG_CLIENT_IP" || die "Некорректный IPv4-адрес клиента WireGuard: $WG_CLIENT_IP"
if [[ ! "$WG_SUBNET" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}/([0-9]|[12][0-9]|3[0-2])$ ]] ||
  ! valid_ipv4 "${WG_SUBNET%/*}"; then
  die "Некорректная подсеть WireGuard: $WG_SUBNET"
fi
if [[ ! "$CLIENT_MTU" =~ ^[0-9]{1,5}$ ]] || (( 10#$CLIENT_MTU < 576 || 10#$CLIENT_MTU > 65535 )); then
  die "Некорректный MTU клиента: $CLIENT_MTU"
fi
DNS_PATTERN='^[a-zA-Z0-9.,: -]+$'
[[ "$DNS_SERVERS" =~ $DNS_PATTERN ]] || die "Некорректное значение DNS_SERVERS."

if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  ok "ОС: ${PRETTY_NAME:-unknown} ($(uname -m))"
fi

# Инструменты ставим ДО определения IP: на чистом сервере curl может не быть.
HAVE_WG=1
if (( ! PRINT_ONLY )); then
  for tool in wg wg-quick iptables curl ss sha256sum; do
    command -v "$tool" >/dev/null 2>&1 || MISSING_TOOLS="${MISSING_TOOLS:-} $tool"
  done
  if [[ -n "${MISSING_TOOLS:-}" ]]; then
    command -v apt-get >/dev/null 2>&1 || die "Не хватает:$MISSING_TOOLS. Автоустановка поддерживается только на Debian/Ubuntu."
    info "Доустанавливаю:$MISSING_TOOLS"
    run env DEBIAN_FRONTEND=noninteractive apt-get update -qq
    run env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq wireguard-tools iptables iproute2 curl coreutils
  fi
  for tool in wg wg-quick iptables curl ss sha256sum; do
    command -v "$tool" >/dev/null 2>&1 || { (( DRY_RUN )) || die "Не найден $tool после установки."; }
  done
fi
command -v wg >/dev/null 2>&1 || HAVE_WG=0
(( HAVE_WG )) || { (( DRY_RUN )) && warn "wg не установлен — в dry-run ключи будут заглушками."; }
(( HAVE_WG || DRY_RUN )) || die "Нужен wg (wireguard-tools)."
ok "Инструменты на месте"

OUT_IFACE="$(ip route get 1.1.1.1 2>/dev/null | awk '{ for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit } }' || true)"
[[ -n "$OUT_IFACE" ]] || die "Не удалось определить внешний сетевой интерфейс."
ok "Внешний интерфейс: $OUT_IFACE"

PUBLIC_IP="${PUBLIC_IP:-}"
[[ -n "$PUBLIC_IP" ]] || PUBLIC_IP="$(curl -fsS4 --max-time 10 https://ifconfig.me 2>/dev/null || curl -fsS4 --max-time 10 https://api.ipify.org 2>/dev/null || true)"
if [[ -z "$PUBLIC_IP" ]]; then
  PUBLIC_IP="$(ip -4 addr show scope global | grep -oP 'inet \K[\d.]+' | head -1 || true)"
  [[ "$PUBLIC_IP" =~ ^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.) ]] && \
    warn "IP $PUBLIC_IP — приватный (сервер за NAT?). Задайте вручную: PUBLIC_IP=x.x.x.x bash $0"
fi
[[ "$PUBLIC_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Не удалось определить публичный IP (получено: '${PUBLIC_IP}')."
ok "Публичный IP: $PUBLIC_IP"

# ВАЖНО: ключ сервера берём в порядке приоритета от самого «живого» источника.
# Файл server_private.key может быть устаревшим (от прошлой конфигурации),
# и если взять его, скрипт перепишет туннель с другим ключом сервера —
# приложение перестанет подключаться.
GEN_WG_KEY=0
WG_SERVER_PRIV=""
WG_KEY_SOURCE=""

if command -v wg >/dev/null 2>&1 && wg show "$WG_IFACE" >/dev/null 2>&1; then
  WG_SERVER_PRIV="$(wg show "$WG_IFACE" private-key 2>/dev/null || true)"
  [[ -n "$WG_SERVER_PRIV" ]] && WG_KEY_SOURCE="живого интерфейса $WG_IFACE"
fi

if [[ -z "$WG_SERVER_PRIV" && -s "$WG_CONF" ]] && grep -q '^PrivateKey' "$WG_CONF" 2>/dev/null; then
  WG_SERVER_PRIV="$(cfg_value "$WG_CONF" PrivateKey)"
  WG_KEY_SOURCE="$WG_CONF"
fi

if [[ -z "$WG_SERVER_PRIV" && -s "$WG_DIR/server_private.key" ]]; then
  WG_SERVER_PRIV="$(tr -d '\r\n ' < "$WG_DIR/server_private.key")"
  warn "Беру ключ из $WG_DIR/server_private.key — живого $WG_IFACE и $WG_CONF нет. Если он от старой конфигурации, удалите файл и перезапустите."
  WG_KEY_SOURCE="fallback $WG_DIR/server_private.key"
fi

if [[ -z "$WG_SERVER_PRIV" ]]; then
  GEN_WG_KEY=1
  info "Ключ сервера будет сгенерирован"
else
  SERVER_PUB="$(printf '%s' "$WG_SERVER_PRIV" | wg pubkey 2>/dev/null || true)"
  [[ -n "$SERVER_PUB" ]] || (( DRY_RUN )) || die "Ключ сервера из $WG_KEY_SOURCE некорректен."
  ok "Ключ сервера взят из $WG_KEY_SOURCE"
  ok "Публичный ключ сервера: ${B}${SERVER_PUB}${N}"
fi

# WRAP-ключ: сохраняем существующий, чтобы не сломать уже настроенное приложение
WRAP_KEY=""
if [[ -r "$SERVICE_PATH" ]]; then
  WRAP_KEY="$(grep -oP 'wrap-key \K[a-f0-9]{64}' "$SERVICE_PATH" | head -1 || true)"
fi
if [[ -z "$WRAP_KEY" ]]; then
  # в --print-only нельзя выдумывать ключ: приложение получит неверные данные
  (( PRINT_ONLY )) && die "WRAP-ключ не найден в $SERVICE_PATH — сначала выполните установку."
  WRAP_KEY="$(openssl rand -hex 32 2>/dev/null || head -c32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
fi
ok "WRAP-ключ: ${WRAP_KEY:0:16}…${WRAP_KEY: -8} (полностью будет в итоговом выводе)"

#───────────────────────────────────────────────────────────────────────────────
# WRAP-БИНАРЬ
#───────────────────────────────────────────────────────────────────────────────
step "Серверный бинарь (WRAP)"

binary_supports_wrap() {
  # Go-бинарь печатает usage в stderr и выходит с кодом 2, поэтому:
  # собираем вывод в переменную (|| true) и ищем флаг в ней.
  local out
  [[ -x "$1" ]] || return 1
  out="$("$1" -h 2>&1 || true)"
  grep -q -- '-wrap-key' <<<"$out"
}

select_wrap_release_asset() {
  local arch
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64)
      WRAP_BIN_ASSET="server-linux-amd64"
      WRAP_BIN_SHA256="86f650b7222dc8143e5e984469fd51f13bbf9f580e4a5cfc3eff3e9f3fc05c60"
      ;;
    aarch64|arm64)
      WRAP_BIN_ASSET="server-linux-arm64"
      WRAP_BIN_SHA256="5cfc4966a8cda90ab1a3ba56873202ca0782cb4ac4e9364e4fac1e36352e5d04"
      ;;
    armv7l|armv7)
      WRAP_BIN_ASSET="server-linux-arm"
      WRAP_BIN_SHA256="7c76e766fa9c4733b9300e34ef015b6d8a040a47a14bf9c66284abef330ed6f4"
      ;;
    i386|i486|i586|i686)
      WRAP_BIN_ASSET="server-linux-386"
      WRAP_BIN_SHA256="a1df9d6d11f4ab26f7a699f74916f0d9e694ea4c73e8cfce7a9bd49ce1c1597b"
      ;;
    mips)
      WRAP_BIN_ASSET="server-linux-mips"
      WRAP_BIN_SHA256="1a204f800cfa5d03132d86076480c93bca48d7b2f50bcf77513b05585b716006"
      ;;
    mipsel|mipsle)
      WRAP_BIN_ASSET="server-linux-mipsle"
      WRAP_BIN_SHA256="3df2f2663baaa5e6994abc2529db1eedfd03bbb295da204804822b4d2fe11d10"
      ;;
    mips64el|mips64le)
      WRAP_BIN_ASSET="server-linux-mips64le"
      WRAP_BIN_SHA256="a7f5c39bb001e9e5412a76515ea6fb045d7ff79e302eefee1b3bcb18fadf2adc"
      ;;
    riscv64)
      WRAP_BIN_ASSET="server-linux-riscv64"
      WRAP_BIN_SHA256="631472b5c267c9fd0f5772f9d9325579790b609af03037604ff8d17fdff30901"
      ;;
    *)
      die "Нет WRAP-релиза для архитектуры $arch. Укажите WRAP_BIN_SOURCE=/путь/к/server."
      ;;
  esac
  WRAP_BIN_URL="https://github.com/Moroka8/vk-turn-proxy/releases/download/${WRAP_BIN_RELEASE}/${WRAP_BIN_ASSET}"
}

download_wrap_binary() {
  local tmp actual_sha bin_dir="${BIN_PATH%/*}"
  [[ "$bin_dir" == "$BIN_PATH" ]] && bin_dir="."
  install -d -m 755 "$bin_dir"
  tmp="$(mktemp "$bin_dir/.server.XXXXXX")"
  if ! curl --fail --location --silent --show-error --retry 3 --connect-timeout 10 --max-time 300 \
    --output "$tmp" "$WRAP_BIN_URL"; then
    rm -f "$tmp"
    die "Не удалось скачать WRAP-бинарь: $WRAP_BIN_URL"
  fi
  actual_sha="$(sha256sum "$tmp" | awk '{print $1}')"
  if [[ "$actual_sha" != "$WRAP_BIN_SHA256" ]]; then
    rm -f "$tmp"
    die "SHA-256 загруженного WRAP-бинаря не совпал: ожидался $WRAP_BIN_SHA256, получен $actual_sha."
  fi
  chmod 755 "$tmp"
  if ! binary_supports_wrap "$tmp"; then
    rm -f "$tmp"
    die "Загруженный бинарь не содержит обязательный флаг -wrap-key."
  fi
  [[ -f "$BIN_PATH" ]] && cp -a "$BIN_PATH" "$BIN_PATH.bak.$(date +%F-%H%M%S)"
  mv -f "$tmp" "$BIN_PATH"
  ok "Скачан WRAP-бинарь ${WRAP_BIN_RELEASE} (${WRAP_BIN_ASSET}); SHA-256 проверен"
}

if (( PRINT_ONLY )); then
  info "пропускаю (--print-only)"
elif [[ -n "$WRAP_BIN_SOURCE" ]]; then
  # явно указанный источник имеет приоритет — так можно обновить бинарь
  [[ -f "$WRAP_BIN_SOURCE" ]] || die "WRAP_BIN_SOURCE не найден: $WRAP_BIN_SOURCE"
  binary_supports_wrap "$WRAP_BIN_SOURCE" || die "Указанный бинарь не поддерживает -wrap: $WRAP_BIN_SOURCE"
  if (( DRY_RUN )); then
    info "[dry-run] скопирую $WRAP_BIN_SOURCE -> $BIN_PATH"
  else
    install -d -m 755 "$INSTALL_DIR"
    [[ -f "$BIN_PATH" ]] && cp -a "$BIN_PATH" "$BIN_PATH.bak.$(date +%F-%H%M%S)"
    install -m 755 "$WRAP_BIN_SOURCE" "$BIN_PATH"
    ok "Установлен WRAP-бинарь из $WRAP_BIN_SOURCE"
  fi
elif binary_supports_wrap "$BIN_PATH"; then
  ok "Уже установлен WRAP-бинарь: $BIN_PATH"
elif (( DRY_RUN )); then
  select_wrap_release_asset
  info "[dry-run] скачаю ${WRAP_BIN_URL} -> $BIN_PATH и проверю SHA-256"
else
  select_wrap_release_asset
  download_wrap_binary
fi

#───────────────────────────────────────────────────────────────────────────────
# WIREGUARD
#───────────────────────────────────────────────────────────────────────────────
step "WireGuard ($WG_IFACE, порт $WG_PORT)"

if (( PRINT_ONLY )); then
  info "пропускаю настройку (--print-only)"
else
  run sysctl -qw net.ipv4.ip_forward=1
  if ! grep -rqs '^net.ipv4.ip_forward *= *1' /etc/sysctl.conf /etc/sysctl.d/ 2>/dev/null; then
    if (( DRY_RUN )); then
      info "[dry-run] запишу /etc/sysctl.d/99-wireguard-forward.conf"
    else
      printf 'net.ipv4.ip_forward=1\n' > /etc/sysctl.d/99-wireguard-forward.conf
    fi
  fi

  if (( GEN_WG_KEY )); then
    if (( DRY_RUN )); then
      WG_SERVER_PRIV="<сгенерируется>"
    else
      install -d -m 700 "$WG_DIR"
      WG_SERVER_PRIV="$(wg genkey)"
      printf '%s\n' "$WG_SERVER_PRIV" > "$WG_DIR/server_private.key"
      chmod 600 "$WG_DIR/server_private.key"
      ok "Сгенерирован ключ сервера"
    fi
  fi

  # Клиентский приватный ключ: сохраняем существующий, иначе берём из файла/генерируем
  # Приоритет: явный --client-key > существующий конфиг > генерация.
  CLIENT_PRIV=""
  if [[ -n "$CLIENT_KEY_FILE" ]]; then
    [[ -r "$CLIENT_KEY_FILE" ]] || die "Файл ключа клиента не найден: $CLIENT_KEY_FILE"
    CLIENT_PRIV="$(tr -d '\r\n ' < "$CLIENT_KEY_FILE")"
    ok "Взял ключ клиента из $CLIENT_KEY_FILE"
  elif [[ -s "$CLIENT_CONF" ]] && grep -q '^PrivateKey' "$CLIENT_CONF" 2>/dev/null; then
    CLIENT_PRIV="$(cfg_value "$CLIENT_CONF" PrivateKey)"
    ok "Использую существующий ключ клиента из $CLIENT_CONF"
  elif (( HAVE_WG )); then
    CLIENT_PRIV="$(wg genkey)"
    (( DRY_RUN )) || ok "Сгенерирован новый ключ клиента"
  else
    CLIENT_PRIV="<сгенерируется>"
  fi

  if [[ -n "$CLIENT_PUBKEY_OVERRIDE" ]]; then
    CLIENT_PUB="$CLIENT_PUBKEY_OVERRIDE"
    # приватный ключ живёт на устройстве — в конфиг его писать нельзя (не совпадёт)
    CLIENT_PRIV="<приватный ключ на устройстве>"
    warn "--client-pub: приватный ключ клиента остаётся на iPhone, в $CLIENT_CONF будет заглушка."
  elif (( HAVE_WG )); then
    CLIENT_PUB="$(printf '%s' "$CLIENT_PRIV" | wg pubkey)" || die "Некорректный приватный ключ клиента."
  else
    CLIENT_PUB="<сгенерируется>"
  fi

  # PSK: сохраняем существующий из клиентского конфига
  PSK=""
  if [[ -s "$CLIENT_CONF" ]]; then
    PSK="$(cfg_value "$CLIENT_CONF" PresharedKey)"
  fi
  if [[ -z "$PSK" ]] && (( ! DRY_RUN )); then
    PSK="$(wg genpsk)"
  fi
  [[ -n "$PSK" ]] || PSK="<сгенерируется>"

  # Чужие [Peer] из старого конфига сохраняем — иначе отвалятся другие клиенты VPN.
  OTHER_PEERS=""
  if [[ -s "$WG_CONF" ]]; then
    OTHER_PEERS="$(awk -v pub="$CLIENT_PUB" -v cip="${WG_CLIENT_IP}/32" '
      function flush() {
        if (is_peer && !mine) printf "%s\n", blk
        blk=""; is_peer=0; mine=0
      }
      /^[[:space:]]*\[/ { flush(); is_peer = ($0 ~ /^[[:space:]]*\[Peer\]/) }
      {
        blk = blk $0 "\n"
        if ($0 ~ /^#[[:space:]]*iphone-turn/) mine=1
        line=$0; gsub(/[[:space:]]/, "", line)
        if (line == "PublicKey=" pub) mine=1
        if (line == "AllowedIPs=" cip) mine=1
      }
      END { flush() }' "$WG_CONF")"
    OLD_ADDR="$(cfg_value "$WG_CONF" Address)"
    if [[ -n "$OLD_ADDR" && "${OLD_ADDR%%/*}" != "$WG_SERVER_IP" ]]; then
      warn "В $WG_CONF был Address = $OLD_ADDR, скрипт поставит ${WG_SERVER_IP}. Если это чужая установка, задайте WG_SERVER_IP/WG_CLIENT_IP/WG_SUBNET под неё."
    fi
    [[ -n "$OTHER_PEERS" ]] && info "Сохраняю других пиров: $(grep -c '^\[Peer\]' <<<"$OTHER_PEERS")"
  fi

  if (( DRY_RUN )); then
    info "[dry-run] запишу $WG_CONF и подниму $WG_IFACE"
  else
    [[ -f "$WG_CONF" ]] && cp -a "$WG_CONF" "$WG_CONF.bak.$(date +%F-%H%M%S)"
    install -d -m 700 "$WG_DIR"
    umask 077
    cat > "$WG_CONF" <<EOF
[Interface]
Address = ${WG_SERVER_IP}/${WG_SUBNET#*/}
MTU = 1420
ListenPort = ${WG_PORT}
PrivateKey = ${WG_SERVER_PRIV}
PostUp = iptables -C FORWARD -i ${WG_IFACE} -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -i ${WG_IFACE} -j ACCEPT
PostUp = iptables -C FORWARD -o ${WG_IFACE} -j ACCEPT 2>/dev/null || iptables -I FORWARD 2 -o ${WG_IFACE} -j ACCEPT
PostUp = iptables -t nat -C POSTROUTING -s ${WG_SUBNET} -o ${OUT_IFACE} -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s ${WG_SUBNET} -o ${OUT_IFACE} -j MASQUERADE
PostDown = iptables -D FORWARD -i ${WG_IFACE} -j ACCEPT 2>/dev/null || true
PostDown = iptables -D FORWARD -o ${WG_IFACE} -j ACCEPT 2>/dev/null || true
PostDown = iptables -t nat -D POSTROUTING -s ${WG_SUBNET} -o ${OUT_IFACE} -j MASQUERADE 2>/dev/null || true

[Peer]
# iphone-turn
PublicKey = ${CLIENT_PUB}
PresharedKey = ${PSK}
AllowedIPs = ${WG_CLIENT_IP}/32
EOF
    [[ -n "$OTHER_PEERS" ]] && printf '\n%s\n' "$OTHER_PEERS" >> "$WG_CONF"
    chmod 600 "$WG_CONF"
    umask 022

    systemctl enable "wg-quick@${WG_IFACE}" >/dev/null 2>&1 || true
    if systemctl is-active --quiet "wg-quick@${WG_IFACE}"; then
      systemctl restart "wg-quick@${WG_IFACE}"
    else
      # интерфейс мог быть поднят вручную (wg-quick up) — тогда start упадёт с «already exists»
      ip link show "$WG_IFACE" >/dev/null 2>&1 && { wg-quick down "$WG_IFACE" >/dev/null 2>&1 || ip link del "$WG_IFACE" || true; }
      systemctl start "wg-quick@${WG_IFACE}" || true
    fi
    sleep 2
    systemctl is-active --quiet "wg-quick@${WG_IFACE}" || die "Не удалось поднять $WG_IFACE. Смотрите: journalctl -u wg-quick@${WG_IFACE}"
    ok "WireGuard поднят: $WG_IFACE"
  fi

  # NAT/forward — на случай, если правила снесли
  if (( DRY_RUN )); then
    info "[dry-run] настрою правила iptables для FORWARD, NAT и UDP ${TURN_PORT}"
  else
    iptables -C FORWARD -i "$WG_IFACE" -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -i "$WG_IFACE" -j ACCEPT
    iptables -C FORWARD -o "$WG_IFACE" -j ACCEPT 2>/dev/null || iptables -I FORWARD 2 -o "$WG_IFACE" -j ACCEPT
    iptables -t nat -C POSTROUTING -s "$WG_SUBNET" -o "$OUT_IFACE" -j MASQUERADE 2>/dev/null ||
      iptables -t nat -A POSTROUTING -s "$WG_SUBNET" -o "$OUT_IFACE" -j MASQUERADE
    iptables -C INPUT -p udp --dport "$TURN_PORT" -j ACCEPT 2>/dev/null ||
      iptables -I INPUT 1 -p udp --dport "$TURN_PORT" -j ACCEPT
  fi
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    run ufw allow "${TURN_PORT}/udp"
    ok "ufw: открыт ${TURN_PORT}/udp"
  fi
  if command -v netfilter-persistent >/dev/null 2>&1; then
    run netfilter-persistent save
  else
    run mkdir -p /etc/iptables
    if (( DRY_RUN )); then
      info "[dry-run] запишу правила в /etc/iptables/rules.v4"
    else
      iptables-save > /etc/iptables/rules.v4
    fi
    info "Правила NAT/FORWARD восстанавливаются через PostUp в $WG_CONF; INPUT для ${TURN_PORT}/udp после ребута — поставьте iptables-persistent, если политика INPUT = DROP."
  fi
  ok "NAT, FORWARD и INPUT ${TURN_PORT}/udp настроены"
fi

#───────────────────────────────────────────────────────────────────────────────
# СЕРВИС VK TURN PROXY
#───────────────────────────────────────────────────────────────────────────────
step "Служба vk-turn-proxy (UDP $TURN_PORT -> 127.0.0.1:${WG_PORT})"

if (( PRINT_ONLY )); then
  info "пропускаю настройку (--print-only)"
else
  if (( DRY_RUN )); then
    info "[dry-run] создам $SERVICE_PATH и запущу службу"
  else
    cat > "$SERVICE_PATH" <<EOF
[Unit]
Description=VK TURN Proxy Service (SRTP+WRAP)
After=network-online.target wg-quick@${WG_IFACE}.service
Wants=network-online.target wg-quick@${WG_IFACE}.service
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=simple
User=root
WorkingDirectory=${INSTALL_DIR}
ExecStart=${BIN_PATH} -listen 0.0.0.0:${TURN_PORT} -connect 127.0.0.1:${WG_PORT} -wrap -wrap-key ${WRAP_KEY}
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "$SERVICE_PATH"
    systemctl daemon-reload
    systemctl enable vk-turn-proxy >/dev/null 2>&1 || true
    systemctl restart vk-turn-proxy
    sleep 3
    systemctl is-active --quiet vk-turn-proxy || {
      err "Служба не поднялась. Последние строки лога:"
      journalctl -u vk-turn-proxy -n 15 --no-pager >&2 || true
      die "Остановка."
    }
    ok "Служба запущена и добавлена в автозапуск"
  fi
fi

#───────────────────────────────────────────────────────────────────────────────
# КЛИЕНТСКИЙ КОНФИГ
#───────────────────────────────────────────────────────────────────────────────
if (( ! PRINT_ONLY )) && (( ! DRY_RUN )); then
  step "Клиентский конфиг"
  install -d -m 700 "$CLIENTS_DIR"
  umask 077
  cat > "$CLIENT_CONF" <<EOF
[Interface]
PrivateKey = ${CLIENT_PRIV}
Address = ${WG_CLIENT_IP}/32
DNS = ${DNS_SERVERS}
MTU = ${CLIENT_MTU}

[Peer]
PublicKey = $(printf '%s' "$WG_SERVER_PRIV" | wg pubkey)
PresharedKey = ${PSK}
Endpoint = 127.0.0.1:${LOCAL_PROXY_PORT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
  chmod 600 "$CLIENT_CONF"
  ok "Конфиг клиента: $CLIENT_CONF"
fi

#───────────────────────────────────────────────────────────────────────────────
# САМОПРОВЕРКА
#───────────────────────────────────────────────────────────────────────────────
if (( ! PRINT_ONLY )) && (( ! DRY_RUN )); then
  step "Проверка"
  FAIL=0
  if systemctl is-active --quiet "wg-quick@${WG_IFACE}"; then
    ok "wg-quick@${WG_IFACE}: активен"
  else
    err "wg-quick@${WG_IFACE}: не активен"
    FAIL=1
  fi
  if systemctl is-active --quiet vk-turn-proxy; then
    ok "vk-turn-proxy: активен"
  else
    err "vk-turn-proxy: не активен"
    FAIL=1
  fi
  # вывод сначала в переменную: `cmd | grep -q` при pipefail даёт ложные провалы (SIGPIPE)
  NAT_RULES="$(iptables -t nat -S POSTROUTING 2>/dev/null || true)"
  FWD_RULES="$(iptables -S FORWARD 2>/dev/null || true)"
  UDP_LISTEN="$(ss -ulnH 2>/dev/null || true)"
  if grep -q -- "-s ${WG_SUBNET} -o ${OUT_IFACE} -j MASQUERADE" <<<"$NAT_RULES"; then
    ok "MASQUERADE: есть"
  else
    err "MASQUERADE: отсутствует"
    FAIL=1
  fi
  if grep -q -- "-i ${WG_IFACE} -j ACCEPT" <<<"$FWD_RULES"; then
    ok "FORWARD: есть"
  else
    warn "FORWARD: правила нет"
  fi
  if grep -qE "[:.]${TURN_PORT}[[:space:]]" <<<"$UDP_LISTEN"; then
    ok "UDP ${TURN_PORT}: слушается"
  else
    err "UDP ${TURN_PORT}: не слушается"
    FAIL=1
  fi
  if [[ "$(sysctl -n net.ipv4.ip_forward)" == "1" ]]; then
    ok "ip_forward: 1"
  else
    err "ip_forward: не включён"
    FAIL=1
  fi
  SERVER_PUB="$(printf '%s' "$WG_SERVER_PRIV" | wg pubkey)"
  if [[ "$SERVER_PUB" == *"=" ]]; then
    ok "Публичный ключ сервера вычислен"
  else
    err "Не удалось вычислить публичный ключ"
    FAIL=1
  fi
  if (( FAIL )); then
    die "Часть проверок не прошла — смотрите вывод выше."
  fi
fi

#───────────────────────────────────────────────────────────────────────────────
# ИТОГОВЫЙ ВЫВОД
#───────────────────────────────────────────────────────────────────────────────
SERVER_PUB_DISPLAY="${SERVER_PUB:-$(printf '%s' "${WG_SERVER_PRIV:-}" | wg pubkey 2>/dev/null || echo '<см. сервер>')}"
[[ "$SERVER_PUB_DISPLAY" == *"="* ]] || SERVER_PUB_DISPLAY="<запустите без --dry-run>"

cat <<EOF


${B}╔══════════════════════════════════════════════════════════════════════════╗
║          ГОТОВО. ЧТО ВВОДИТЬ В ПРИЛОЖЕНИИ НА iPHONE                      ║
╚══════════════════════════════════════════════════════════════════════════╝${N}

${B}── Экран Transport ──────────────────────────────────────────────────────${N}
  Адрес сервера          ${C}${PUBLIC_IP}:${TURN_PORT}${N}
  TURN server (optional) ${C}оставить пустым${N}
  Server mode            ${C}SRTP+WRAP${N}        ${Y}← выбрать именно это${N}
  Режим WRAP             ${C}${WRAP_KEY}${N}
                         ${Y}← вставить ключ, если есть отдельное поле${N}
  Use UDP transport      ${C}выключено${N}        (если не работает — включить)
  Connections            ${C}30${N}               (в пределах 30–50)
  Cred pool cooldown     ${C}150${N}

${B}── Экран WireGuard ──────────────────────────────────────────────────────${N}
  Server public key      ${C}${SERVER_PUB_DISPLAY}${N}
                         ${Y}← вставить КОПИРОВАНИЕМ, не набирать руками${N}
  Client address         ${C}${WG_CLIENT_IP}/32${N}
  DNS                    ${C}${DNS_SERVERS}${N}
  Endpoint / адрес WG    ${C}127.0.0.1:${LOCAL_PROXY_PORT}${N}   ${Y}← ОБЯЗАТЕЛЬНО локальный!${N}
  MTU                    ${C}${CLIENT_MTU}${N}

${B}── Приватный ключ клиента ───────────────────────────────────────────────${N}
  Возьмите из файла:     ${C}${CLIENT_CONF}${N}
EOF
if (( DRY_RUN )); then
  printf '  %s\n' "${Y}(в dry-run файл не создаётся)${N}"
elif [[ -r "$CLIENT_CONF" ]]; then
  printf '  PrivateKey:            %s\n' "${C}$(cfg_value "$CLIENT_CONF" PrivateKey)${N}"
  printf '  PresharedKey:          %s\n' "${C}$(cfg_value "$CLIENT_CONF" PresharedKey)${N}"
  printf '\n%s\n' "${B}── Полный клиентский конфиг (можно импортировать целиком) ──────────────${N}"
  sed 's/^/  /' "$CLIENT_CONF"
  if command -v qrencode >/dev/null 2>&1; then
    printf '\n%s\n' "${B}── QR-код конфига ───────────────────────────────────────────────────────${N}"
    qrencode -t ansiutf8 < "$CLIENT_CONF" || true
  fi
else
  printf '  %s\n' "${Y}(файл $CLIENT_CONF не найден — запустите установку)${N}"
fi
cat <<EOF

${B}── Порядок подключения ──────────────────────────────────────────────────${N}
  1) Сохранить настройки в приложении
  2) Запустить прокси, дождаться ${C}Established DTLS connection${N}
  3) Включить VPN
  4) Нажать «Сохранить», добавив приложение в исключения VPN

${B}── Если нет интернета ──────────────────────────────────────────────────${N}
  Проверить на VPS:   ${C}wg show ${WG_IFACE}${N}                        (нужен latest handshake, rx/tx > 0)
  Нет handshake/rx:   проверьте профиль клиента, ключи, Endpoint и подключение proxy
  Есть handshake:     проверьте счётчики FORWARD и NAT ниже
  Счётчики NAT:       ${C}iptables -L FORWARD -n -v${N}          (должны расти с нуля)
  Лог службы:         ${C}journalctl -u vk-turn-proxy -n 50${N}
  ${Y}«message authentication failed» в логе${N} = не совпал WRAP-ключ
  ${Y}пусто в FORWARD${N} = нет клиентских пакетов; сначала проверьте handshake

${B}── Порты ───────────────────────────────────────────────────────────────${N}
  UDP ${TURN_PORT}  — сюда стучится приложение (открыт в iptables INPUT${Y}; проверьте и firewall хостера${N})
  UDP ${WG_PORT}  — WireGuard (наружу не нужен, но не мешает)
  127.0.0.1:${LOCAL_PROXY_PORT} — локальный порт внутри приложения

${B}── Файлы на VPS ────────────────────────────────────────────────────────${N}
  ${WG_CONF}
  ${SERVICE_PATH}
  ${CLIENT_CONF}
EOF
