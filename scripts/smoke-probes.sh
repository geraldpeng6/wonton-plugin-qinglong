# shellcheck shell=bash
# scripts/smoke.sh 的一项一项探测，跟着插件走。没写的项会 FAIL 并给出写法，不会默认放行。
#
# 青龙是 sso none：应用自己的登录。冒烟实例是全新的，identity_check 走一遍上游的首次初始化
# （网关后面 PUT /api/user/init 建管理员），再登录拿应用令牌验证当前用户；data_write 用应用
# 接口建一条停用的定时任务当数据标记，升级/重装后 data_check 登录回去找它。
# 凭据只活在这份文件和一次性冒烟实例里，实例跑完即删。
#
# 变量：SMOKE_WEB_URL 是应用的网页入口（套件已去尾斜杠，但可能带路径，比如 SSO 登录页）；
#       拼 API 路径用 SMOKE_WEB_ORIGIN（只有 scheme://host:port，入口的路径不掺进来），别直接接在 SMOKE_WEB_URL 后面。

QL_USER="smoke"
QL_PASS="Wonton-Smoke-2.24"

web_assert() { # 青龙是 SPA，外壳里只有 root 节点和 umi 产物；stdin 只能读一次，先存下来
  local page
  page="$(cat)"
  grep -q 'id="root"' <<<"$page" && grep -qE 'umi\.[0-9a-f]+\.(js|css)' <<<"$page"
}

ql_token() { # 登录拿青龙的 Bearer 令牌；登录失败（未初始化时业务码 450、HTTP 仍是 200）先按上游首次打开的流程建管理员再登录
  local resp token
  resp="$(curl -fsS -b "$SMOKE_JAR" -X POST "$SMOKE_WEB_ORIGIN/api/user/login" \
    -H 'Content-Type: application/json' \
    -d "{\"username\":\"$QL_USER\",\"password\":\"$QL_PASS\"}")" || resp=""
  token="$(jq -r '.data.token // empty' <<<"$resp")"
  if [[ -z "$token" ]]; then
    curl -fsS -b "$SMOKE_JAR" -X PUT "$SMOKE_WEB_ORIGIN/api/user/init" \
      -H 'Content-Type: application/json' \
      -d "{\"username\":\"$QL_USER\",\"password\":\"$QL_PASS\"}" >/dev/null || {
      echo "初始化管理员失败"; return 1
    }
    resp="$(curl -fsS -b "$SMOKE_JAR" -X POST "$SMOKE_WEB_ORIGIN/api/user/login" \
      -H 'Content-Type: application/json' \
      -d "{\"username\":\"$QL_USER\",\"password\":\"$QL_PASS\"}")" || {
      echo "初始化后登录失败"; return 1
    }
    token="$(jq -r '.data.token // empty' <<<"$resp")"
    [[ -n "$token" ]] || { echo "登录响应里没有令牌：$(head -c 120 <<<"$resp")"; return 1; }
  fi
  printf '%s' "$token"
}

identity_check() {
  local token user
  token="$(ql_token)" || return 1
  user="$(curl -fsS -b "$SMOKE_JAR" -H "Authorization: Bearer $token" "$SMOKE_WEB_ORIGIN/api/user")" || {
    echo "取当前用户失败"; return 1
  }
  grep -qF "\"username\":\"$QL_USER\"" <<<"$user" || {
    echo "当前用户不是 $QL_USER：$(head -c 200 <<<"$user")"; return 1
  }
}

# 数据：定时任务是青龙的用户数据，跟着数据目录走；升级/重装后还在就算保住了。
data_write() {
  local marker="smoke-$RANDOM$RANDOM" token resp code
  token="$(ql_token)" || return 1
  resp="$(curl -fsS -b "$SMOKE_JAR" -X POST "$SMOKE_WEB_ORIGIN/api/crons" \
    -H "Authorization: Bearer $token" -H 'Content-Type: application/json' \
    -d "{\"name\":\"$marker\",\"command\":\"echo $marker\",\"schedule\":\"0 9 * * *\"}")" || {
    echo "建定时任务失败"; return 1
  }
  code="$(jq -r '.code' <<<"$resp")"
  [[ "$code" == "200" ]] || { echo "建定时任务返回 code=$code：$(head -c 200 <<<"$resp")"; return 1; }
  printf '%s' "$marker" >"$SMOKE_STATE"
}

data_check() {
  local marker token crons
  marker="$(cat "$SMOKE_STATE")" || { echo "没有数据标记"; return 1; }
  token="$(ql_token)" || return 1
  crons="$(curl -fsS -b "$SMOKE_JAR" -H "Authorization: Bearer $token" \
    "$SMOKE_WEB_ORIGIN/api/crons?searchValue=$marker")" || {
    echo "查定时任务失败"; return 1
  }
  grep -qF "$marker" <<<"$crons" || {
    echo "找不到标记任务 $marker：$(head -c 300 <<<"$crons")"; return 1
  }
}
