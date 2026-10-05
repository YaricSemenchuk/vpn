#!/usr/bin/env bash
# Тесты server/install-reality.sh (render_xray_config, gen_reality_keys) и server/vless-client.sh.
# Запуск: bash tests/test_reality.sh   (нужны xray, jq, qrencode, openssl)
# Путь к xray можно задать так: XRAY_BIN=/path/to/xray bash tests/test_reality.sh
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

export XRAY_BIN="${XRAY_BIN:-xray}"
command -v "$XRAY_BIN" >/dev/null || {
  echo "SKIP: xray не найден (задайте XRAY_BIN=/path/to/xray)"
  exit 0
}

fail() {
  echo "FAIL: $*" >&2
  exit 1
}
ok() { echo "ok   - $*"; }

export XRAY_DIR="$TMP/xray"
export XRAY_APPLY=0
mkdir -p "$XRAY_DIR"

# --- генерация ключей и конфига ---
# shellcheck source=/dev/null
source "$ROOT/server/install-reality.sh"
XRAY_DIR="$TMP/xray"
gen_reality_keys

[[ -n $REALITY_PRIVATE_KEY && -n $REALITY_PUBLIC_KEY ]] || fail "ключи не сгенерированы"
[[ $REALITY_PRIVATE_KEY != "$REALITY_PUBLIC_KEY" ]] || fail "публичный ключ совпал с приватным"
[[ $REALITY_SHORT_ID =~ ^[0-9a-f]{16}$ ]] || fail "shortId должен быть 16 hex-символов: $REALITY_SHORT_ID"
derived=$("$XRAY_BIN" x25519 -i "$REALITY_PRIVATE_KEY" | awk -F': *' 'tolower($1) ~ /public ?key|^password/ {print $2; exit}')
[[ $derived == "$REALITY_PUBLIC_KEY" ]] || fail "публичный ключ не соответствует приватному"
ok "ключи Reality сгенерированы и согласованы"

(umask 077 && render_xray_config >"$XRAY_DIR/config.json")
"$XRAY_BIN" run -test -format json -config "$XRAY_DIR/config.json" >/dev/null || fail "Xray не принял серверный конфиг"
[[ $(jq -r '.inbounds[0].port' "$XRAY_DIR/config.json") == 443 ]] || fail "порт по умолчанию должен быть 443"
[[ $(jq -r '.inbounds[0].streamSettings.realitySettings.privateKey' "$XRAY_DIR/config.json") == "$REALITY_PRIVATE_KEY" ]] || fail "privateKey не попал в конфиг"
[[ $(jq -r '.log.access' "$XRAY_DIR/config.json") == none ]] || fail "логи доступа должны быть выключены"
jq -e '.routing.rules[] | select(.outboundTag == "block") | .ip | index("169.254.0.0/16")' "$XRAY_DIR/config.json" >/dev/null || fail "нет блокировки metadata-сервиса 169.254.0.0/16"
ok "серверный конфиг валиден (порт, ключ, логи, блокировка частных сетей)"

cat >"$XRAY_DIR/reality.env" <<EOF
REALITY_PORT="443"
REALITY_SNI="www.microsoft.com"
REALITY_ENDPOINT="203.0.113.7"
REALITY_PUBLIC_KEY="$REALITY_PUBLIC_KEY"
REALITY_SHORT_ID="$REALITY_SHORT_ID"
EOF

CLIENT="$ROOT/server/vless-client.sh"
CFG="$XRAY_DIR/config.json"
clients() { jq -r '.inbounds[0].settings.clients[].email' "$CFG"; }

# --- add ---
out=$(bash "$CLIENT" add alice)
bash "$CLIENT" add bob >/dev/null
[[ $(clients | sort | tr '\n' ' ') == "alice bob " ]] || fail "после add в конфиге должны быть alice и bob"
id=$(jq -r '.inbounds[0].settings.clients[] | select(.email == "alice") | .id' "$CFG")
[[ $id =~ ^[0-9a-f-]{36}$ ]] || fail "некорректный UUID: $id"
[[ $(jq -r '.inbounds[0].settings.clients[0].flow' "$CFG") == xtls-rprx-vision ]] || fail "у клиента должен быть flow xtls-rprx-vision"
link=$(grep '^vless://' <<<"$out")
expected="vless://$id@203.0.113.7:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.microsoft.com&fp=chrome&pbk=$REALITY_PUBLIC_KEY&sid=$REALITY_SHORT_ID&type=tcp#alice"
[[ $link == "$expected" ]] || fail "ссылка отличается от ожидаемой:
  $link
  $expected"
"$XRAY_BIN" run -test -format json -config "$CFG" >/dev/null || fail "Xray не принял конфиг после add"
ok "add создаёт клиента и корректную ссылку vless://"

# права файла сохраняются при обновлении
[[ $(stat -c %a "$CFG") == 600 ]] || fail "права config.json изменились: $(stat -c %a "$CFG")"
ok "права config.json сохраняются (600)"

# --- show / list ---
[[ $(bash "$CLIENT" show alice | grep '^vless://') == "$expected" ]] || fail "show выдаёт другую ссылку"
bash "$CLIENT" list >"$TMP/list.txt"
grep -qF "$id" "$TMP/list.txt" || fail "list не показывает UUID alice"
grep -q bob "$TMP/list.txt" || fail "list не показывает bob"
ok "show и list работают"

# --- remove ---
bash "$CLIENT" remove alice >/dev/null
[[ $(clients | tr '\n' ' ') == "bob " ]] || fail "после remove должен остаться только bob"
"$XRAY_BIN" run -test -format json -config "$CFG" >/dev/null || fail "Xray не принял конфиг после remove"
ok "remove отзывает только нужного клиента"

# --- ошибки ---
if bash "$CLIENT" add bob >/dev/null 2>&1; then fail "дубликат имени должен быть отклонён"; fi
if bash "$CLIENT" add '../evil' >/dev/null 2>&1; then fail "имя с .. должно быть отклонено"; fi
if bash "$CLIENT" add 'a"b' >/dev/null 2>&1; then fail "имя с кавычкой должно быть отклонено"; fi
if bash "$CLIENT" remove ghost >/dev/null 2>&1; then fail "удаление несуществующего должно падать"; fi
if bash "$CLIENT" show ghost >/dev/null 2>&1; then fail "show несуществующего должен падать"; fi
[[ $(clients | tr '\n' ' ') == "bob " ]] || fail "ошибочные вызовы изменили конфиг"
ok "некорректные имена и дубликаты отклоняются, конфиг не портится"

echo "Все тесты пройдены"
