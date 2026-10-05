#!/usr/bin/env bash
# Сквозной тест VLESS+Reality на localhost: настоящий Xray-сервер с конфигом из install-reality.sh,
# клиент настраивается по ссылке vless:// из vless-client.sh, трафик идёт через туннель к локальному HTTP-серверу.
# Проверяет: (1) туннель работает по сгенерированной ссылке, (2) с неверным ключом не работает,
# (3) блокировка частных сетей в конфиге действительно срабатывает.
# Запуск: XRAY_BIN=/path/to/xray bash tests/e2e_reality.sh   (нужны xray, jq, openssl, python3, curl)
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
PIDS=()
cleanup() {
  local p
  for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null || true; done
  rm -rf "$TMP"
}
trap cleanup EXIT

export XRAY_BIN="${XRAY_BIN:-xray}"
for cmd in "$XRAY_BIN" jq openssl python3 curl; do
  command -v "$cmd" >/dev/null || {
    echo "SKIP: не найден $cmd"
    exit 0
  }
done

fail() {
  echo "FAIL: $*" >&2
  exit 1
}
ok() { echo "ok   - $*"; }

PORT_REALITY=18443 # Xray-сервер
PORT_DEST=18444    # «сайт-прикрытие» (локальный TLS 1.3)
PORT_HTTP=18080    # цель, к которой ходим через туннель
PORT_SOCKS=11080   # SOCKS-вход клиента

wait_port() {
  for _ in $(seq 1 50); do
    (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null && return 0
    sleep 0.2
  done
  fail "порт $1 не открылся"
}

# Тест нельзя запускать, если нужные порты уже заняты (иначе проверим не свои процессы)
for port in "$PORT_REALITY" "$PORT_DEST" "$PORT_HTTP" "$PORT_SOCKS"; do
  if (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
    fail "порт $port уже занят — завершите старые процессы теста"
  fi
done

# Ждём строку "started" в логе Xray (сырое TCP-подключение к порту Reality нельзя: он пробросит его на «сайт»)
wait_log() {
  for _ in $(seq 1 50); do
    grep -q "started" "$1" 2>/dev/null && return 0
    sleep 0.2
  done
  fail "Xray не запустился, лог $1:
$(cat "$1")"
}

export XRAY_DIR="$TMP/xray"
export XRAY_APPLY=0
mkdir -p "$XRAY_DIR"

# --- сервер: конфиг из install-reality.sh, dest направлен на локальный TLS-сервер ---
# shellcheck source=/dev/null
source "$ROOT/server/install-reality.sh"
XRAY_DIR="$TMP/xray"
# shellcheck disable=SC2034  # используются в render_xray_config
REALITY_SNI=example.test
# shellcheck disable=SC2034
REALITY_PORT=$PORT_REALITY
gen_reality_keys
render_xray_config |
  jq --arg dest "127.0.0.1:$PORT_DEST" --arg lvl "${E2E_LOGLEVEL:-warning}" \
    '.inbounds[0].streamSettings.realitySettings.dest = $dest | .log.loglevel = $lvl' >"$XRAY_DIR/config.json"
cat >"$XRAY_DIR/reality.env" <<EOF
REALITY_PORT="$PORT_REALITY"
REALITY_SNI="$REALITY_SNI"
REALITY_ENDPOINT="127.0.0.1"
REALITY_PUBLIC_KEY="$REALITY_PUBLIC_KEY"
REALITY_SHORT_ID="$REALITY_SHORT_ID"
EOF

link=$(bash "$ROOT/server/vless-client.sh" add tester | grep '^vless://')

# вариант конфига без блокировки частных сетей (цель теста — 127.0.0.1)
jq 'del(.routing.rules)' "$XRAY_DIR/config.json" >"$TMP/server-open.json"

# --- сайт-прикрытие: TLS 1.3 на localhost ---
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$TMP/dest.key" -out "$TMP/dest.crt" \
  -days 1 -subj "/CN=$REALITY_SNI" >/dev/null 2>&1
# Многопоточный: Reality может открывать к прикрытию несколько соединений, а handshake идёт в потоке обработчика
python3 - "$PORT_DEST" "$TMP/dest.crt" "$TMP/dest.key" >/dev/null 2>&1 <<'PY' &
import http.server, ssl, sys
port, crt, key = int(sys.argv[1]), sys.argv[2], sys.argv[3]
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.minimum_version = ssl.TLSVersion.TLSv1_3
ctx.load_cert_chain(crt, key)
srv = http.server.ThreadingHTTPServer(("127.0.0.1", port), http.server.SimpleHTTPRequestHandler)
srv.socket = ctx.wrap_socket(srv.socket, server_side=True, do_handshake_on_connect=False)
srv.serve_forever()
PY
PIDS+=($!)

# --- цель за туннелем: HTTP-сервер с известным содержимым ---
mkdir -p "$TMP/www"
echo "hello-through-reality" >"$TMP/www/ping.txt"
python3 -m http.server "$PORT_HTTP" --bind 127.0.0.1 --directory "$TMP/www" >/dev/null 2>&1 &
PIDS+=($!)

# --- разбор ссылки vless:// и конфиг клиента ---
client_config() { # $1 = публичный ключ для клиента
  python3 - "$link" "$1" "$PORT_SOCKS" <<'PY'
import json, os, sys
from urllib.parse import urlsplit, parse_qs
link, pbk, socks = sys.argv[1], sys.argv[2], int(sys.argv[3])
u = urlsplit(link)
q = {k: v[0] for k, v in parse_qs(u.query).items()}
assert u.scheme == "vless" and q["security"] == "reality" and q["flow"] == "xtls-rprx-vision"
print(json.dumps({
  "log": {"loglevel": os.environ.get("E2E_LOGLEVEL", "warning")},
  "inbounds": [{"listen": "127.0.0.1", "port": socks, "protocol": "socks", "settings": {"udp": False}}],
  "outbounds": [{
    "protocol": "vless",
    "settings": {"vnext": [{"address": u.hostname, "port": u.port,
      "users": [{"id": u.username, "encryption": q["encryption"], "flow": q["flow"]}]}]},
    "streamSettings": {"network": q["type"], "security": "reality",
      "realitySettings": {"serverName": q["sni"], "fingerprint": q["fp"],
        "publicKey": pbk, "shortId": q["sid"]}}
  }]
}))
PY
}

fetch_via_tunnel() {
  # --noproxy '' обязателен: иначе NO_PROXY из окружения (часто содержит 127.0.0.1) заставит curl идти мимо прокси
  curl -fsS --max-time 15 --noproxy '' -x "socks5h://127.0.0.1:$PORT_SOCKS" "http://127.0.0.1:$PORT_HTTP/ping.txt" 2>"$TMP/curl.err"
}

run_case() { # $1 = серверный конфиг, $2 = публичный ключ клиента; печатает ответ или пусто
  local srv cli
  "$XRAY_BIN" run -format json -config "$1" >"$TMP/server.log" 2>&1 &
  srv=$!
  client_config "$2" >"$TMP/client.json"
  "$XRAY_BIN" run -format json -config "$TMP/client.json" >"$TMP/client.log" 2>&1 &
  cli=$!
  wait_log "$TMP/server.log"
  wait_log "$TMP/client.log"
  fetch_via_tunnel || true
  kill "$srv" "$cli" 2>/dev/null || true
  wait "$srv" "$cli" 2>/dev/null || true
}

wait_port "$PORT_DEST"
wait_port "$PORT_HTTP"

# Самопроверка теста: цель доступна напрямую, а через несуществующий прокси — нет.
# Иначе curl ходит мимо туннеля (например, из-за NO_PROXY) и все проверки ниже ничего не доказывают.
[[ $(curl -fsS --max-time 5 --noproxy '*' "http://127.0.0.1:$PORT_HTTP/ping.txt") == "hello-through-reality" ]] || fail "цель недоступна напрямую"
if fetch_via_tunnel >/dev/null; then fail "самопроверка: curl обходит прокси, тест некорректен"; fi

# 1. Правильная ссылка + сервер без блокировки: туннель работает
res=$(run_case "$TMP/server-open.json" "$REALITY_PUBLIC_KEY")
[[ $res == "hello-through-reality" ]] || fail "туннель по сгенерированной ссылке не работает (ответ: '$res')
--- server.log ---
$(cat "$TMP/server.log")
--- client.log ---
$(cat "$TMP/client.log")
--- curl ---
$(cat "$TMP/curl.err" 2>/dev/null)"
ok "трафик проходит через туннель по ссылке из vless-client"

# 2. Неверный публичный ключ: туннель не должен работать
res=$(run_case "$TMP/server-open.json" "$(openssl rand -base64 32 | tr '+/' '-_' | tr -d '=\n')")
[[ -z $res ]] || fail "с неверным ключом туннель не должен работать (ответ: '$res')
--- server.log ---
$(cat "$TMP/server.log")
--- client.log ---
$(cat "$TMP/client.log")
--- client.json ---
$(cat "$TMP/client.json")"
ok "с неверным публичным ключом туннель не работает"

# 3. Боевой конфиг с блокировкой частных сетей: доступ к 127.0.0.1 через туннель закрыт
res=$(run_case "$XRAY_DIR/config.json" "$REALITY_PUBLIC_KEY")
[[ -z $res ]] || fail "доступ к частным адресам через туннель должен быть заблокирован (ответ: '$res')"
ok "через туннель нельзя достучаться до частных адресов (блокировка работает)"

echo "Все сквозные тесты пройдены"
