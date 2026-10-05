#!/usr/bin/env bash
# Установка VLESS+Reality (Xray) на Ubuntu 22.04+/Debian 12+.
# Трафик выглядит как обычное HTTPS-соединение с чужим сайтом — это обходит DPI там,
# где WireGuard режется (например, в Беларуси).
# Запуск от root:  sudo bash install-reality.sh
#
# Параметры (необязательные, через переменные окружения):
#   REALITY_PORT=443              TCP-порт сервера
#   REALITY_SNI=www.microsoft.com сайт-прикрытие (должен поддерживать TLS 1.3 и HTTP/2)
#   REALITY_ENDPOINT=1.2.3.4      публичный адрес сервера (по умолчанию определяется сам)
#   FIRST_CLIENT=phone            сразу создать первого клиента с этим именем
set -euo pipefail

REALITY_PORT="${REALITY_PORT:-443}"
REALITY_SNI="${REALITY_SNI:-www.microsoft.com}"
REALITY_ENDPOINT="${REALITY_ENDPOINT:-}"
FIRST_CLIENT="${FIRST_CLIENT:-}"
XRAY_DIR="${XRAY_DIR:-/usr/local/etc/xray}"
XRAY_BIN="${XRAY_BIN:-xray}"
XRAY_INSTALLER_URL="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"

die() {
  echo "Ошибка: $*" >&2
  exit 1
}

detect_endpoint() {
  local ip url
  for url in https://api.ipify.org https://ifconfig.me; do
    if ip=$(curl -fsS4 --max-time 10 "$url" 2>/dev/null) && [[ $ip =~ ^[0-9.]+$ ]]; then
      echo "$ip"
      return 0
    fi
  done
  return 1
}

# Генерирует REALITY_PRIVATE_KEY / REALITY_PUBLIC_KEY / REALITY_SHORT_ID.
# Формат вывода `xray x25519` менялся между версиями (Private key / PrivateKey,
# Public key / Password (PublicKey)), поэтому разбираем его по шаблонам.
gen_reality_keys() {
  local out
  out=$("$XRAY_BIN" x25519)
  REALITY_PRIVATE_KEY=$(awk -F': *' 'tolower($1) ~ /^private ?key$/ {print $2; exit}' <<<"$out")
  [[ -n $REALITY_PRIVATE_KEY ]] || die "не удалось получить приватный ключ из 'xray x25519'"
  out=$("$XRAY_BIN" x25519 -i "$REALITY_PRIVATE_KEY")
  REALITY_PUBLIC_KEY=$(awk -F': *' 'tolower($1) ~ /public ?key|^password/ {print $2; exit}' <<<"$out")
  [[ -n $REALITY_PUBLIC_KEY ]] || die "не удалось получить публичный ключ из 'xray x25519 -i'"
  REALITY_SHORT_ID=$(openssl rand -hex 8)
}

# Печатает config.json для Xray. Нужны: REALITY_PRIVATE_KEY, REALITY_SHORT_ID и параметры выше.
# Логи доступа выключены. Исходящий трафик в частные и служебные сети блокируется,
# чтобы клиент не мог добраться до внутренней сети хостера и metadata-сервиса (169.254.169.254).
render_xray_config() {
  jq -n \
    --argjson port "$REALITY_PORT" \
    --arg sni "$REALITY_SNI" \
    --arg priv "$REALITY_PRIVATE_KEY" \
    --arg sid "$REALITY_SHORT_ID" \
    '{
      log: {loglevel: "warning", access: "none"},
      inbounds: [{
        tag: "vless-reality",
        port: $port,
        protocol: "vless",
        settings: {clients: [], decryption: "none"},
        streamSettings: {
          network: "tcp",
          security: "reality",
          realitySettings: {
            show: false,
            dest: ($sni + ":443"),
            xver: 0,
            serverNames: [$sni],
            privateKey: $priv,
            shortIds: [$sid]
          }
        }
      }],
      outbounds: [
        {protocol: "freedom", tag: "direct"},
        {protocol: "blackhole", tag: "block"}
      ],
      routing: {
        domainStrategy: "IPIfNonMatch",
        rules: [{
          type: "field",
          outboundTag: "block",
          ip: [
            "0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8",
            "169.254.0.0/16", "172.16.0.0/12", "192.168.0.0/16",
            "::1/128", "fc00::/7", "fe80::/10"
          ]
        }]
      }
    }'
}

main() {
  [[ $EUID -eq 0 ]] || die "запустите от root: sudo bash install-reality.sh"
  command -v apt-get >/dev/null || die "скрипт рассчитан на Ubuntu/Debian (нужен apt-get)"
  [[ $REALITY_PORT =~ ^[0-9]+$ ]] || die "REALITY_PORT должен быть числом"
  [[ $REALITY_SNI =~ ^[A-Za-z0-9.-]+$ ]] || die "REALITY_SNI должен быть доменным именем, например www.microsoft.com"
  [[ ! -e $XRAY_DIR/reality.env ]] || die "$XRAY_DIR/reality.env уже существует — установка уже выполнялась. Чтобы переустановить, удалите его и $XRAY_DIR/config.json вручную (ссылки клиентов станут недействительны)."

  local script_dir
  script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  [[ -f $script_dir/vless-client.sh ]] || die "рядом с install-reality.sh не найден vless-client.sh (запускайте из папки server)"

  echo "==> Установка пакетов"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq curl jq qrencode openssl unzip

  echo "==> Установка Xray (официальный установщик XTLS/Xray-install)"
  local installer
  installer=$(mktemp)
  curl -fsSL "$XRAY_INSTALLER_URL" -o "$installer"
  bash "$installer" install
  rm -f "$installer"
  command -v "$XRAY_BIN" >/dev/null || die "xray не найден после установки"

  if [[ -z $REALITY_ENDPOINT ]]; then
    echo "==> Определяю публичный IP сервера"
    REALITY_ENDPOINT=$(detect_endpoint) || die "не удалось определить публичный IP — задайте вручную: REALITY_ENDPOINT=1.2.3.4 sudo -E bash install-reality.sh"
  fi
  [[ $REALITY_ENDPOINT == *:* ]] && REALITY_ENDPOINT="[$REALITY_ENDPOINT]"

  echo "==> Генерирую ключи и конфиг"
  gen_reality_keys
  umask 077
  mkdir -p "$XRAY_DIR"
  render_xray_config >"$XRAY_DIR/config.json"
  "$XRAY_BIN" run -test -format json -config "$XRAY_DIR/config.json" >/dev/null || die "Xray не принял сгенерированный конфиг"

  cat >"$XRAY_DIR/reality.env" <<EOF
REALITY_PORT="$REALITY_PORT"
REALITY_SNI="$REALITY_SNI"
REALITY_ENDPOINT="$REALITY_ENDPOINT"
REALITY_PUBLIC_KEY="$REALITY_PUBLIC_KEY"
REALITY_SHORT_ID="$REALITY_SHORT_ID"
EOF

  # Служба Xray работает не от root — даём ей группе чтение конфига (ключ не должен быть world-readable)
  local svc_user
  svc_user=$(systemctl show -p User --value xray 2>/dev/null || true)
  if [[ -n $svc_user ]] && id "$svc_user" >/dev/null 2>&1; then
    chgrp "$(id -gn "$svc_user")" "$XRAY_DIR/config.json"
    chmod 640 "$XRAY_DIR/config.json"
  fi

  install -m 755 "$script_dir/vless-client.sh" /usr/local/bin/vless-client

  if command -v ufw >/dev/null && ufw status | grep -q '^Status: active'; then
    echo "==> ufw активен, открываю ${REALITY_PORT}/tcp"
    ufw allow "${REALITY_PORT}/tcp" >/dev/null
  fi

  echo "==> Запускаю Xray"
  systemctl enable xray >/dev/null 2>&1
  systemctl restart xray
  sleep 1
  systemctl is-active --quiet xray || die "Xray не запустился. Смотрите: journalctl -u xray -n 30 --no-pager"

  echo
  echo "Готово. VLESS+Reality запущен на ${REALITY_ENDPOINT}:${REALITY_PORT}/tcp (маскировка под ${REALITY_SNI})."
  echo "Если у хостера есть внешний файрвол (облачная панель) — откройте в нём TCP ${REALITY_PORT}."

  if [[ -n $FIRST_CLIENT ]]; then
    echo
    /usr/local/bin/vless-client add "$FIRST_CLIENT"
  else
    echo "Создайте первого клиента:  sudo vless-client add phone"
  fi
}

# Запускаем main только при прямом вызове (чтобы тесты могли подключить файл через source)
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
