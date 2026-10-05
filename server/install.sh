#!/usr/bin/env bash
# Установка личного WireGuard-VPN на Ubuntu 22.04+/Debian 12+.
# Запуск от root:  sudo bash install.sh
#
# Параметры (необязательные, через переменные окружения):
#   WG_PORT=51820            UDP-порт сервера
#   WG_NET_PREFIX=10.8.0     первые три октета внутренней подсети /24
#   WG_DNS="1.1.1.1, 9.9.9.9" DNS, который получат клиенты
#   WG_ENDPOINT=1.2.3.4      публичный адрес сервера (по умолчанию определяется сам)
#   FIRST_CLIENT=phone       сразу создать первого клиента с этим именем
set -euo pipefail

WG_IFACE="${WG_IFACE:-wg0}"
WG_PORT="${WG_PORT:-51820}"
WG_NET_PREFIX="${WG_NET_PREFIX:-10.8.0}"
WG_DNS="${WG_DNS:-1.1.1.1, 9.9.9.9}"
WG_ENDPOINT="${WG_ENDPOINT:-}"
FIRST_CLIENT="${FIRST_CLIENT:-}"
WG_DIR="${WG_DIR:-/etc/wireguard}"

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

detect_wan_if() {
  ip -4 route show default | awk '{for (i = 1; i <= NF; i++) if ($i == "dev") {print $(i + 1); exit}}'
}

# Печатает серверный wg0.conf. Нужны: SERVER_PRIVATE_KEY, WAN_IF и параметры выше.
render_server_conf() {
  local subnet="${WG_NET_PREFIX}.0/24"
  local up="iptables -I FORWARD -i %i -j ACCEPT; iptables -I FORWARD -o %i -j ACCEPT; iptables -t nat -A POSTROUTING -s $subnet -o $WAN_IF -j MASQUERADE; iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu"
  local down=${up//-I FORWARD/-D FORWARD}
  down=${down//-t nat -A/-t nat -D}
  down=${down//-t mangle -A/-t mangle -D}

  cat <<EOF
[Interface]
Address = ${WG_NET_PREFIX}.1/24
ListenPort = $WG_PORT
PrivateKey = $SERVER_PRIVATE_KEY
PostUp = $up
PostDown = $down

EOF
}

main() {
  [[ $EUID -eq 0 ]] || die "запустите от root: sudo bash install.sh"
  command -v apt-get >/dev/null || die "скрипт рассчитан на Ubuntu/Debian (нужен apt-get)"
  [[ $WG_NET_PREFIX =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || die "WG_NET_PREFIX должен быть вида 10.8.0"
  [[ $WG_PORT =~ ^[0-9]+$ ]] || die "WG_PORT должен быть числом"
  [[ ! -e $WG_DIR/$WG_IFACE.conf ]] || die "$WG_DIR/$WG_IFACE.conf уже существует — установка уже выполнялась. Чтобы переустановить, удалите его вручную (ключи клиентов станут недействительны)."

  local script_dir
  script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  [[ -f $script_dir/vpn-client.sh ]] || die "рядом с install.sh не найден vpn-client.sh (запускайте из клона репозитория)"

  echo "==> Установка пакетов"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq wireguard qrencode iptables curl

  if [[ -z $WG_ENDPOINT ]]; then
    echo "==> Определяю публичный IP сервера"
    WG_ENDPOINT=$(detect_endpoint) || die "не удалось определить публичный IP — задайте вручную: WG_ENDPOINT=1.2.3.4 sudo -E bash install.sh"
  fi
  [[ $WG_ENDPOINT == *:* ]] && WG_ENDPOINT="[$WG_ENDPOINT]"
  WAN_IF=$(detect_wan_if)
  [[ -n $WAN_IF ]] || die "не удалось определить внешний сетевой интерфейс"
  echo "    адрес сервера: $WG_ENDPOINT, внешний интерфейс: $WAN_IF"

  echo "==> Включаю маршрутизацию IPv4"
  echo "net.ipv4.ip_forward = 1" >/etc/sysctl.d/99-wireguard.conf
  sysctl -q -p /etc/sysctl.d/99-wireguard.conf

  echo "==> Генерирую ключи и конфиг сервера"
  umask 077
  mkdir -p "$WG_DIR"
  SERVER_PRIVATE_KEY=$(wg genkey)
  local server_public_key
  server_public_key=$(wg pubkey <<<"$SERVER_PRIVATE_KEY")
  render_server_conf >"$WG_DIR/$WG_IFACE.conf"

  cat >"$WG_DIR/vpn.env" <<EOF
WG_IFACE="$WG_IFACE"
WG_PORT="$WG_PORT"
WG_NET_PREFIX="$WG_NET_PREFIX"
WG_DNS="$WG_DNS"
WG_ENDPOINT="$WG_ENDPOINT"
SERVER_PUBLIC_KEY="$server_public_key"
EOF

  install -m 755 "$script_dir/vpn-client.sh" /usr/local/bin/vpn-client

  # Если на сервере включён ufw — открыть порт (сам ufw мы не включаем, чтобы не отрезать SSH)
  if command -v ufw >/dev/null && ufw status | grep -q '^Status: active'; then
    echo "==> ufw активен, открываю ${WG_PORT}/udp"
    ufw allow "${WG_PORT}/udp" >/dev/null
  fi

  echo "==> Запускаю WireGuard"
  systemctl enable --now "wg-quick@$WG_IFACE"

  echo
  echo "Готово. VPN-сервер запущен на ${WG_ENDPOINT}:${WG_PORT}/udp."
  echo "Если у хостера есть внешний файрвол (облачная панель) — откройте в нём UDP ${WG_PORT}."

  if [[ -n $FIRST_CLIENT ]]; then
    echo
    /usr/local/bin/vpn-client add "$FIRST_CLIENT"
  else
    echo "Создайте первого клиента:  sudo vpn-client add phone"
  fi
}

# Запускаем main только при прямом вызове (чтобы тесты могли подключить файл через source)
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
