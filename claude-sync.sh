#!/usr/bin/env bash
# 通过 WebDAV 同步 Claude Code 的 ~/.claude/settings.json
set -euo pipefail

# 黑名单：不上传；下载时保留本机的值。
# 顶层键直接写，嵌套键写成 父键.子键（如 env.ANTHROPIC_API_KEY），* 匹配任意字符。
BLACKLIST='
model effortLevel modelSettings enabledPlugins extraKnownMarketplaces hooks
'
LOCAL="$HOME/.claude/settings.json"
REMOTE_NAME="claude-settings.json"

usage() {
  cat <<'USAGE'
用法: claude-sync.sh <upload|download> --url <WebDAV 目录> --user <用户名> --pass <密码>
                      [--add <字段>] [--remove <字段>]

  upload    过滤黑名单字段后，上传本机 settings.json
  download  下载远端配置写入本机，本机的黑名单字段保持不变

  --add     在默认黑名单上增加字段
  --remove  从默认黑名单中去掉字段
            两者都可重复使用，一次也可写多个（空格或逗号分隔）
USAGE
  exit 2
}

MODE="${1:-}"; [ "$MODE" = upload ] || [ "$MODE" = download ] || usage; shift
URL=""; USER_NAME=""; PASS=""; ADD=""; DEL=""
while [ $# -gt 0 ]; do
  [ $# -ge 2 ] || usage
  case "$1" in
    --url) URL="$2" ;;
    --user) USER_NAME="$2" ;;
    --pass) PASS="$2" ;;
    --add) ADD="$ADD $2" ;;
    --remove) DEL="$DEL $2" ;;
    *) usage ;;
  esac
  shift 2
done
[ -n "$URL" ] && [ -n "$USER_NAME" ] && [ -n "$PASS" ] || usage

for c in curl jq diff; do command -v "$c" >/dev/null || { echo "缺少 $c"; exit 1; }; done

# 按 --add / --remove 调整黑名单
if [ -n "$ADD$DEL" ]; then
  bl() { jq -rn --arg bl "$BLACKLIST" --arg add "$ADD" --arg del "$DEL" \
    'def words($s): [$s | splits("[\\s,]+") | select(length > 0)]; '"$1"; }
  while IFS= read -r f; do echo "黑名单里没有 ${f}，忽略"; done < <(bl '(words($del) - words($bl) - words($add))[]')
  BLACKLIST=$(bl '(words($bl) + (words($add) - words($bl))) - words($del) | join(" ")')
  echo "本次黑名单：$BLACKLIST"
fi

LIB='
def re: "^" + gsub("\\*"; ".*") + "$";
def hit($k; $ps): any($ps[]; . as $p | $k | test($p | re));
def pats: [$bl | splits("\\s+") | select(length > 0)];
def top: [pats[] | select(contains(".") | not)];
def subs($k): [pats[] | select(contains(".")) | split(".") | . as $a | select($k | test($a[0] | re)) | .[1:] | join(".")];
def drop: with_entries(.key as $k | select(hit($k; top) | not) | subs($k) as $s
  | if ($s | length) > 0 and (.value | type) == "object"
    then .value |= with_entries(.key as $kk | select(hit($kk; $s) | not)) else . end);
def pick: with_entries(.key as $k
  | if hit($k; top) then .
    else subs($k) as $s | select(($s | length) > 0 and (.value | type) == "object")
      | .value |= with_entries(.key as $kk | select(hit($kk; $s))) | select(.value | length > 0)
    end);
def names: pick | to_entries[] | .key as $k
  | if hit($k; top) then $k else .value | keys[] | "\($k).\(.)" end;
'
jqf() { jq -r --arg bl "$BLACKLIST" "$LIB $1" "$2"; }

W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
DIR_URL="${URL%/}/"
FILE_URL="$DIR_URL$REMOTE_NAME"

# 凭据经 stdin 传给 curl，不出现在 curl 的命令行里
CRED="$USER_NAME:$PASS"; CRED=${CRED//\\/\\\\}; CRED=${CRED//\"/\\\"}
dav() { printf 'user = "%s"\n' "$CRED" | curl -K - -sS "$@"; }

# 下载远端到 $1，远端不存在时写入 {}
fetch() {
  local code
  code=$(dav -o "$1" -w '%{http_code}' "$FILE_URL")
  if [ "$code" = 404 ]; then echo '{}' >"$1"
  elif [ "$code" = 401 ]; then echo "认证失败（401），检查用户名和密码"; exit 1
  elif [ "${code:0:1}" != 2 ]; then echo "下载失败：HTTP $code"; exit 1
  fi
  jq -e 'type == "object"' "$1" >/dev/null || { echo "远端文件不是有效的 JSON 对象"; exit 1; }
}

# 显示 $1 → $2 的差异并确认；从终端读取，兼容 curl | bash
confirm() {
  if diff -q <(jq -S . "$1") <(jq -S . "$2") >/dev/null; then echo "没有变化"; exit 0; fi
  echo "---- $3的变更 ----"
  diff -u <(jq -S . "$1") <(jq -S . "$2") | tail -n +3 || true
  local ok
  read -rp "确认写入$3？[y/N] " ok </dev/tty
  [ "$ok" = y ] || [ "$ok" = Y ] || { echo "已取消"; exit 0; }
}

if [ "$MODE" = upload ]; then
  [ -f "$LOCAL" ] || { echo "找不到 $LOCAL"; exit 1; }
  jq -e 'type == "object"' "$LOCAL" >/dev/null || { echo "$LOCAL 不是有效的 JSON 对象"; exit 1; }
  jqf drop "$LOCAL" >"$W/up.json"
  echo "已排除字段：$(jqf names "$LOCAL" | tr '\n' ' ')"
  fetch "$W/remote.json"
  confirm "$W/remote.json" "$W/up.json" 远端
  dav -o /dev/null -X MKCOL "$DIR_URL" || true
  code=$(dav -o /dev/null -w '%{http_code}' -T "$W/up.json" "$FILE_URL")
  [ "${code:0:1}" = 2 ] || { echo "上传失败：HTTP $code"; exit 1; }
  echo "已上传到 $FILE_URL"
else
  fetch "$W/remote.json"
  if [ -f "$LOCAL" ]; then cp "$LOCAL" "$W/local.json"; else echo '{}' >"$W/local.json"; fi
  # 远端字段为准，本机黑名单字段保留
  jq -n --arg bl "$BLACKLIST" --slurpfile r "$W/remote.json" --slurpfile l "$W/local.json" \
    "$LIB (\$r[0] | drop) * (\$l[0] | pick)" >"$W/new.json"
  confirm "$W/local.json" "$W/new.json" 本机
  mkdir -p "$(dirname "$LOCAL")"
  if [ -f "$LOCAL" ]; then cp "$LOCAL" "$LOCAL.bak"; echo "已备份到 $LOCAL.bak"; fi
  cp "$W/new.json" "$LOCAL"
  echo "已写入 $LOCAL"
fi
