#!/usr/bin/env bash
# Управление клиентами VLESS+Reality (Xray).
#   vless-client add NAME     создать клиента, показать ссылку vless:// и QR-код
#   vless-client show NAME    показать ссылку и QR-код существующего клиента
#   vless-client list         список клиентов
#   vless-client remove NAME  отозвать доступ клиента
# Добавление и удаление перезапускают Xray (активные соединения на секунду обрываются).
set -euo pipefail

XRAY_DIR="${XRAY_DIR:-/usr/local/etc/xray}"
XRAY_CONFIG="${XRAY_CONFIG:-$XRAY_DIR/config.json}"
ENV_FILE="${REALITY_ENV_FILE:-$XRAY_DIR/reality.env}"
XRAY_BIN="${XRAY_BIN:-xray}"
# XRAY_APPLY=0 — не перезапускать службу (нужно для тестов)
XRAY_APPLY="${XRAY_APPLY:-1}"

die() {
  echo "Ошибка: $*" >&2
  exit 1
}

[[ -r $ENV_FILE ]] || die "не найден $ENV_FILE — сначала запустите install-reality.sh (от root)"
# shellcheck source=/dev/null
source "$ENV_FILE"
# из reality.env: REALITY_PORT REALITY_SNI REALITY_ENDPOINT REALITY_PUBLIC_KEY REALITY_SHORT_ID

[[ -w $XRAY_CONFIG ]] || die "нужны права root (запустите через sudo)"
command -v jq >/dev/null || die "не установлен jq (apt-get install jq)"

INBOUND='.inbounds[] | select(.tag == "vless-reality")'

valid_name() {
  [[ $1 =~ ^[A-Za-z0-9_-]{1,32}$ ]]
}

require_name() {
  local name=${1:-}
  [[ -n $name ]] || die "укажите имя клиента"
  valid_name "$name" || die "имя клиента: латиница, цифры, - и _ (до 32 символов)"
}

client_id() {
  jq -r --arg n "$1" "$INBOUND | .settings.clients[] | select(.email == \$n) | .id" "$XRAY_CONFIG"
}

# Применить jq-фильтр к конфигу: проверить результат Xray'ом и только потом заменить файл
update_config() {
  local tmp
  tmp=$(mktemp "$XRAY_CONFIG.XXXXXX")
  if ! jq "$@" "$XRAY_CONFIG" >"$tmp"; then
    rm -f "$tmp"
    die "не удалось изменить конфиг"
  fi
  if command -v "$XRAY_BIN" >/dev/null 2>&1; then
    if ! "$XRAY_BIN" run -test -format json -config "$tmp" >/dev/null 2>&1; then
      rm -f "$tmp"
      die "Xray не принял изменённый конфиг, ничего не изменено"
    fi
  fi
  chmod --reference="$XRAY_CONFIG" "$tmp"
  chown --reference="$XRAY_CONFIG" "$tmp" 2>/dev/null || true
  mv "$tmp" "$XRAY_CONFIG"
}

apply_config() {
  [[ $XRAY_APPLY == 1 ]] || return 0
  systemctl restart xray
}

build_link() {
  local id=$1 name=$2
  echo "vless://${id}@${REALITY_ENDPOINT}:${REALITY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUBLIC_KEY}&sid=${REALITY_SHORT_ID}&type=tcp#${name}"
}

print_link() {
  local link=$1
  echo "Ссылка для импорта в приложение (содержит ключ доступа — не публикуйте):"
  echo "$link"
  if command -v qrencode >/dev/null 2>&1; then
    echo
    qrencode -t ansiutf8 "$link"
  else
    echo "(qrencode не установлен — QR-код недоступен, используйте ссылку)" >&2
  fi
}

cmd_add() {
  local name=${1:-} id
  require_name "$name"
  [[ -z $(client_id "$name") ]] || die "клиент '$name' уже существует"

  id=$(cat /proc/sys/kernel/random/uuid)
  update_config --arg id "$id" --arg name "$name" \
    "($INBOUND | .settings.clients) += [{id: \$id, flow: \"xtls-rprx-vision\", email: \$name}]"
  apply_config

  echo "Клиент '$name' создан."
  print_link "$(build_link "$id" "$name")"
}

cmd_show() {
  local name=${1:-} id
  require_name "$name"
  id=$(client_id "$name")
  [[ -n $id ]] || die "клиент '$name' не найден"
  print_link "$(build_link "$id" "$name")"
}

cmd_list() {
  local rows
  rows=$(jq -r "$INBOUND | .settings.clients[] | [.email, .id] | @tsv" "$XRAY_CONFIG")
  if [[ -z $rows ]]; then
    echo "(клиентов пока нет — создайте: vless-client add NAME)"
    return 0
  fi
  printf '%-20s %s\n' "ИМЯ" "UUID"
  while IFS=$'\t' read -r name id; do
    printf '%-20s %s\n' "$name" "$id"
  done <<<"$rows"
}

cmd_remove() {
  local name=${1:-}
  require_name "$name"
  [[ -n $(client_id "$name") ]] || die "клиент '$name' не найден"
  update_config --arg name "$name" \
    "($INBOUND | .settings.clients) |= map(select(.email != \$name))"
  apply_config
  echo "Клиент '$name' удалён, доступ отозван."
}

usage() {
  cat <<EOF
Использование: vless-client <команда> [имя]

  add NAME     создать клиента, показать ссылку vless:// и QR-код
  show NAME    показать ссылку и QR-код клиента
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
