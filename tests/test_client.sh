#!/usr/bin/env bash
# Тесты server/vpn-client.sh и server/install.sh (render_server_conf).
# Запуск: bash tests/test_client.sh   (нужны wireguard-tools и qrencode)
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}
ok() { echo "ok   - $*"; }

assert_contains() { grep -qF -- "$2" "$1" || fail "в $1 нет строки: $2"; }
assert_not_contains() { ! grep -qF -- "$2" "$1" || fail "в $1 не должно быть строки: $2"; }

export WG_DIR="$TMP/wg"
export WG_APPLY=0
mkdir -p "$WG_DIR"

# --- серверный конфиг из install.sh ---
# shellcheck source=/dev/null
source "$ROOT/server/install.sh"
WG_DIR="$TMP/wg"
SERVER_PRIVATE_KEY=$(wg genkey)
# shellcheck disable=SC2034  # используется внутри render_server_conf
WAN_IF=eth0
# install.sh создаёт конфиг с umask 077 — воспроизводим это
(umask 077 && render_server_conf >"$WG_DIR/wg0.conf")

assert_contains "$WG_DIR/wg0.conf" "Address = 10.8.0.1/24"
assert_contains "$WG_DIR/wg0.conf" "ListenPort = 51820"
assert_contains "$WG_DIR/wg0.conf" "-t nat -A POSTROUTING -s 10.8.0.0/24 -o eth0 -j MASQUERADE"
assert_contains "$WG_DIR/wg0.conf" "-t nat -D POSTROUTING -s 10.8.0.0/24 -o eth0 -j MASQUERADE"
assert_contains "$WG_DIR/wg0.conf" "iptables -D FORWARD -i %i -j ACCEPT"
PostDown=$(grep '^PostDown' "$WG_DIR/wg0.conf")
[[ $PostDown != *" -A "* && $PostDown != *" -I "* ]] || fail "PostDown не должен добавлять правила: $PostDown"
cp "$WG_DIR/wg0.conf" "$TMP/check.conf"
wg-quick strip "$TMP/check.conf" >/dev/null || fail "wg-quick не принял серверный конфиг"
ok "серверный конфиг корректен"

SERVER_PUBLIC_KEY=$(wg pubkey <<<"$SERVER_PRIVATE_KEY")
cat >"$WG_DIR/vpn.env" <<EOF
WG_IFACE="wg0"
WG_PORT="51820"
WG_NET_PREFIX="10.8.0"
WG_DNS="1.1.1.1, 9.9.9.9"
WG_ENDPOINT="203.0.113.7"
SERVER_PUBLIC_KEY="$SERVER_PUBLIC_KEY"
EOF

CLIENT="$ROOT/server/vpn-client.sh"
CLIENTS_DIR="$WG_DIR/clients"

# --- add ---
bash "$CLIENT" add alice >/dev/null
bash "$CLIENT" add bob >/dev/null
assert_contains "$CLIENTS_DIR/alice.conf" "Address = 10.8.0.2/32"
assert_contains "$CLIENTS_DIR/bob.conf" "Address = 10.8.0.3/32"
assert_contains "$CLIENTS_DIR/alice.conf" "Endpoint = 203.0.113.7:51820"
assert_contains "$CLIENTS_DIR/alice.conf" "AllowedIPs = 0.0.0.0/0, ::/0"
assert_contains "$CLIENTS_DIR/alice.conf" "PublicKey = $SERVER_PUBLIC_KEY"
assert_contains "$WG_DIR/wg0.conf" "AllowedIPs = 10.8.0.2/32"
assert_contains "$WG_DIR/wg0.conf" "AllowedIPs = 10.8.0.3/32"
ok "add выдаёт уникальные адреса"

# публичный ключ в серверном конфиге соответствует приватному ключу клиента
priv=$(awk '$1 == "PrivateKey" {print $3}' "$CLIENTS_DIR/alice.conf")
pub=$(wg pubkey <<<"$priv")
assert_contains "$WG_DIR/wg0.conf" "PublicKey = $pub"
# preshared-ключ одинаков у клиента и сервера
psk=$(awk '$1 == "PresharedKey" {print $3}' "$CLIENTS_DIR/alice.conf")
assert_contains "$WG_DIR/wg0.conf" "PresharedKey = $psk"
ok "ключи клиента и сервера согласованы"

# права на файлы с приватными ключами
[[ $(stat -c %a "$CLIENTS_DIR/alice.conf") == 600 ]] || fail "alice.conf должен иметь права 600"
[[ $(stat -c %a "$WG_DIR/wg0.conf") == 600 ]] || fail "wg0.conf должен иметь права 600"
ok "права на файлы 600"

# итоговый серверный конфиг по-прежнему валиден
cp "$WG_DIR/wg0.conf" "$TMP/check.conf"
wg-quick strip "$TMP/check.conf" >/dev/null || fail "wg-quick не принял конфиг после add"

# --- list ---
bash "$CLIENT" list >"$TMP/list.txt"
assert_contains "$TMP/list.txt" "alice"
assert_contains "$TMP/list.txt" "10.8.0.3/32"
ok "list показывает клиентов"

# --- remove ---
bash "$CLIENT" remove alice >/dev/null
assert_not_contains "$WG_DIR/wg0.conf" "alice"
assert_not_contains "$WG_DIR/wg0.conf" "AllowedIPs = 10.8.0.2/32"
assert_contains "$WG_DIR/wg0.conf" "AllowedIPs = 10.8.0.3/32"
assert_contains "$WG_DIR/wg0.conf" "ListenPort = 51820"
[[ ! -e $CLIENTS_DIR/alice.conf ]] || fail "alice.conf не удалён"
cp "$WG_DIR/wg0.conf" "$TMP/check.conf"
wg-quick strip "$TMP/check.conf" >/dev/null || fail "wg-quick не принял конфиг после remove"
ok "remove отзывает только нужного клиента"

# освободившийся адрес переиспользуется
bash "$CLIENT" add carol >/dev/null
assert_contains "$CLIENTS_DIR/carol.conf" "Address = 10.8.0.2/32"
ok "освободившийся адрес переиспользуется"

# --- ошибки ---
if bash "$CLIENT" add bob >/dev/null 2>&1; then fail "дубликат имени должен быть отклонён"; fi
if bash "$CLIENT" add '../evil' >/dev/null 2>&1; then fail "имя с .. должно быть отклонено"; fi
if bash "$CLIENT" add 'a b' >/dev/null 2>&1; then fail "имя с пробелом должно быть отклонено"; fi
if bash "$CLIENT" remove ghost >/dev/null 2>&1; then fail "удаление несуществующего должно падать"; fi
ok "некорректные имена и дубликаты отклоняются"

echo "Все тесты пройдены"
