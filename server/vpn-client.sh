#!/usr/bin/env bash
# Управление клиентами WireGuard.
#   vpn-client add NAME     создать клиента, показать QR-код
#   vpn-client show NAME    показать конфиг и QR-код существующего клиента
#   vpn-client list         список клиентов и время последнего подключения
#   vpn-client remove NAME  отозвать доступ клиента
set -euo pipefail

WG_DIR="${WG_DIR:-/etc/wireguard}"
ENV_FILE="${WG_ENV_FILE:-$WG_DIR/vpn.env}"
# WG_APPLY=0 — не трогать запущенный интерфейс (нужно для тестов)
WG_APPLY="${WG_APPLY:-1}"

die() {
  echo "Ошибка: $*" >&2
  exit 1
}

[[ -r $ENV_FILE ]] || die "не найден $ENV_FILE — сначала запустите install.sh (от root)"
# shellcheck source=/dev/null
source "$ENV_FILE"
# из vpn.env: WG_IFACE WG_PORT WG_NET_PREFIX WG_DNS WG_ENDPOINT SERVER_PUBLIC_KEY

CONF="$WG_DIR/$WG_IFACE.conf"
CLIENTS_DIR="$WG_DIR/clients"

[[ -w $WG_DIR ]] || die "нужны права root (запустите через sudo)"

valid_name() {
  [[ $1 =~ ^[A-Za-z0-9_-]{1,32}$ ]]
}

require_name() {
  local name=${1:-}
  [[ -n $name ]] || die "укажите имя клиента"
  valid_name "$name" || die "имя клиента: латиница, цифры, - и _ (до 32 символов)"
}

next_ip() {
  local i
  for i in $(seq 2 254); do
    if ! grep -qE "^AllowedIPs = ${WG_NET_PREFIX//./\\.}\\.$i/32\$" "$CONF"; then
      echo "${WG_NET_PREFIX}.$i"
      return 0
    fi
  done
  die "в подсети ${WG_NET_PREFIX}.0/24 закончились адреса"
}

# Применить wg0.conf к работающему интерфейсу без разрыва текущих соединений
apply_config() {
  [[ $WG_APPLY == 1 ]] || return 0
  if ip link show "$WG_IFACE" >/dev/null 2>&1; then
    wg syncconf "$WG_IFACE" <(wg-quick strip "$WG_IFACE")
  fi
}

print_qr() {
  if command -v qrencode >/dev/null 2>&1; then
    qrencode -t ansiutf8 <"$1"
  else
    echo "(qrencode не установлен — QR-код недоступен, используйте файл $1)" >&2
  fi
}

cmd_add() {
  local name=${1:-}
  require_name "$name"
  [[ ! -e $CLIENTS_DIR/$name.conf ]] || die "клиент '$name' уже существует"

  local ip priv pub psk
  ip=$(next_ip)
  priv=$(wg genkey)
  pub=$(wg pubkey <<<"$priv")
  psk=$(wg genpsk)

  umask 077
  mkdir -p "$CLIENTS_DIR"

  # AllowedIPs ::/0 нужен, чтобы IPv6-трафик не уходил мимо туннеля
  cat >"$CLIENTS_DIR/$name.conf" <<EOF
[Interface]
PrivateKey = $priv
Address = $ip/32
DNS = $WG_DNS

[Peer]
PublicKey = $SERVER_PUBLIC_KEY
PresharedKey = $psk
Endpoint = $WG_ENDPOINT:$WG_PORT
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF

  cat >>"$CONF" <<EOF
# BEGIN peer $name
[Peer]
PublicKey = $pub
PresharedKey = $psk
AllowedIPs = $ip/32
# END peer $name

EOF

  apply_config

  echo "Клиент '$name' создан: $ip"
  echo "Конфиг: $CLIENTS_DIR/$name.conf"
  echo "QR-код (содержит приватный ключ — не публикуйте и не пересылайте):"
  print_qr "$CLIENTS_DIR/$name.conf"
}

cmd_show() {
  local name=${1:-}
  require_name "$name"
  [[ -e $CLIENTS_DIR/$name.conf ]] || die "клиент '$name' не найден"
  cat "$CLIENTS_DIR/$name.conf"
  echo
  print_qr "$CLIENTS_DIR/$name.conf"
}

cmd_list() {
  local f name ip priv pub hs when found=0
  printf '%-20s %-16s %s\n' "ИМЯ" "АДРЕС" "ПОСЛЕДНЕЕ ПОДКЛЮЧЕНИЕ"
  for f in "$CLIENTS_DIR"/*.conf; do
    [[ -e $f ]] || continue
    found=1
    name=$(basename "$f" .conf)
    ip=$(awk '$1 == "Address" {print $3}' "$f")
    priv=$(awk '$1 == "PrivateKey" {print $3}' "$f")
    pub=$(wg pubkey <<<"$priv")
    hs=$(wg show "$WG_IFACE" latest-handshakes 2>/dev/null | awk -v k="$pub" '$1 == k {print $2}') || true
    if [[ -n $hs && $hs != 0 ]]; then
      when=$(date -d "@$hs" '+%Y-%m-%d %H:%M:%S')
    else
      when="никогда"
    fi
    printf '%-20s %-16s %s\n' "$name" "$ip" "$when"
  done
  [[ $found == 1 ]] || echo "(клиентов пока нет — создайте: vpn-client add NAME)"
}

cmd_remove() {
  local name=${1:-}
  require_name "$name"
  [[ -e $CLIENTS_DIR/$name.conf ]] || die "клиент '$name' не найден"

  # имя уже провалидировано, в sed-выражение попадают только [A-Za-z0-9_-]
  sed -i "/^# BEGIN peer $name\$/,/^# END peer $name\$/d" "$CONF"
  # схлопнуть лишние пустые строки, оставшиеся после удаления блока
  sed -i '/^$/N;/^\n$/D' "$CONF"
  rm -f "$CLIENTS_DIR/$name.conf"

  apply_config
  echo "Клиент '$name' удалён, доступ отозван."
}

usage() {
  cat <<EOF
Использование: vpn-client <команда> [имя]

  add NAME     создать клиента и показать QR-код
  show NAME    показать конфиг и QR-код клиента
  list         список клиентов
  remove NAME  удалить клиента (отозвать доступ)
EOF
}

case "${1:-}" in
  add) cmd_add "${2:-}" ;;
  show) cmd_show "${2:-}" ;;
  list) cmd_list ;;
  remove) cmd_remove "${2:-}" ;;
  -h | --help | help | "") usage ;;
  *)
    usage >&2
    exit 1
    ;;
esac
