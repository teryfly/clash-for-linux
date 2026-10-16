#!/usr/bin/env bash
# proxy.sh — 一键拉订阅 / 过滤 Claude 不支持的国家地区 / 延迟测试 / 切最快节点
#
# 用法：
#   ./proxy.sh start    # 更新节点 + 加载 + 选最快 + 切换
#   ./proxy.sh stop     # 把 白嫖机场 切回 DIRECT（不走代理）
#   ./proxy.sh restart  # stop + start
#   ./proxy.sh status   # 当前选中节点 + 历史延迟 + 最近一次更新结果
#
# 可调：
#   CLASH_SUB_URL         覆盖订阅 URL（默认读 subscriptions.yaml 的 active）
#   CLASH_BLOCKED_WORDS   覆盖屏蔽词（空格分隔，默认见脚本内）
#   CLASH_BANNER_WORDS    覆盖「广告位假节点」词（空格分隔）：命中者不进
#                         url-test/fallback 候选。机场把"剩余流量/套餐到期"这类
#                         信息位做成真节点下发，它们指向广告 sink、不是出口，
#                         一旦被自动组选中，订阅域名（规则把它们钉在自动组上）
#                         就永远取不到——见 heal_groups。
#   CLASH_PROBE_URL       覆盖延迟探测 URL（默认 google 204）
#   CLASH_PROBE_TIMEOUT   覆盖探测超时 ms（默认 5000）
#   CLASH_SELECT_GROUP    覆盖要切换的 proxy-group（默认 白嫖机场）
#   CLASH_VERIFY_URLS     域名级验收目标（空格分隔），由 start.sh 传入模型网关。
#                         「出得了站」不等于「业务送得到」：winner 除了过 google 204，
#                         还要真能握上手，否则换完节点照样 SSL: UNEXPECTED_EOF。
#   CLASH_RELOAD_SETTLE   热载之后等待的秒数（默认 5）——见 reload_cfg。
#   CLASH_FETCH_RETRY     同一个出口上拉订阅的次数（默认 3），先原地重试再谈改道。
#   CLASH_FETCH_RETRY_WAIT 原地重试之间等几秒（默认 4）。
#   CLASH_TRY_DIRECT      =1 时在「经本地代理」之前先试一次真直连。默认关闭：
#                         订阅域名在 Cloudflare 上，境内直连会被 TLS 重置，
#                         这条结构上不可能成功（tun+fake-ip 还会把"直连"也
#                         卷进 mihomo，让它和经 7890 变成同一条路）。

set -euo pipefail

RUNTIME_DIR=/home/vz/Tery/clash-for-linux/runtime
SUBS_FILE=$RUNTIME_DIR/subscriptions.yaml
RUNTIME_CFG=$RUNTIME_DIR/config.yaml
PATCHED_CFG=$RUNTIME_DIR/config.patched.yaml
HEALED_CFG=$RUNTIME_DIR/config.healed.yaml
SUB_CACHE_DIR=$RUNTIME_DIR/cache/subs
SECRET=8790c8111ef235e3
API=http://127.0.0.1:9090

: "${CLASH_PROBE_URL:=https://www.google.com/generate_204}"
: "${CLASH_PROBE_TIMEOUT:=5000}"
: "${CLASH_SELECT_GROUP:=白嫖机场}"
: "${CLASH_MIXED_PORT:=7890}"
# 选最快之后按延迟从小到大实测几条「真的送得出去」，其余不试。
# 见 pick 那段：mihomo 的 delay 只测节点握手，最快的那条完全可能紧接着就拨号超时。
: "${CLASH_VERIFY_TOP:=5}"
LOCAL_PROXY="http://127.0.0.1:$CLASH_MIXED_PORT"
# Claude 不支持 + 高风险国家/地区（含港台常用变体字）
: "${CLASH_BLOCKED_WORDS:=香港 俄羅斯 俄罗斯 印度 巴基斯坦 孟加拉 土耳其 尼日利亞 尼日利亚 肯尼亚 巴西 阿根廷 越南 印尼 菲律賓 菲律宾}"
# 信息位/引流位节点：名字像节点、实际不是出口
: "${CLASH_BANNER_WORDS:=剩余流量 距离下次 套餐到期 官网 客户端 请每月更 免流 更换客户端 若无}"
# 自动组健康检查：明文 HTTP 会被部分机场劫持且与重复 HEAD 不兼容（mihomo 自己
# 在日志里警告过），86400s 又让组一天才复测一次，足以死死停在一个死节点上。
: "${CLASH_HEALTH_URL:=https://www.gstatic.com/generate_204}"
: "${CLASH_HEALTH_INTERVAL:=600}"
# 域名级验收目标（空格分隔）：模型网关之类「业务真正会走的那条路」。延迟测试和出站
# 实测都只看 CLASH_PROBE_URL，而 google 204 只证明这条线路出得了站——实测过一条对
# google 全通、对订阅域名直接 TLS 重置的 家宽 线路被当成 winner 选中。
: "${CLASH_VERIFY_URLS:=}"
: "${CLASH_RELOAD_SETTLE:=5}"
: "${CLASH_FETCH_RETRY:=3}"
: "${CLASH_FETCH_RETRY_WAIT:=4}"

#: 订阅拉取的最终状态，由 fetch_sub 写、refresh_and_select 末行打印。
#: 必须打在最后一行：proxy.sh 自己 tail -20、平台的 LOG_TAIL_LINES 也只有 20 行，
#: 打早了就被延迟表刷掉了，UI 里就只剩「成功」。
SUB_STATUS="未知"

#: 启动配置（mihomo 重启后读的那份）有没有被本轮刷新发布。同样是末行摘要的一部分：
#: 不可写时要的那两条 sudo 命令太长，写在中间会被 20 行窗口刷掉。
STARTUP_CFG_STATUS="未发布（本轮未走到热载阶段）"

mkdir -p "$SUB_CACHE_DIR"

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
err() { printf '[%s] \033[31m%s\033[0m\n' "$(date +%H:%M:%S)" "$*" >&2; }

need_mihomo() {
  if ! pgrep -f "mihomo.*$RUNTIME_DIR" >/dev/null 2>&1; then
    err "mihomo 进程未运行，请先 sudo systemctl start clash-for-linux"
    exit 1
  fi
  curl -sS --max-time 2 -H "Authorization: Bearer $SECRET" "$API/configs" >/dev/null \
    || { err "mihomo API 不可达 ($API)"; exit 1; }
}

read_active_sub() {
  # 从 subscriptions.yaml 解析 active source 的 URL
  python3 - "$SUBS_FILE" <<'PY'
import sys, yaml, pathlib
p = pathlib.Path(sys.argv[1])
if not p.exists():
    sys.exit(0)
d = yaml.safe_load(p.read_text()) or {}
active = d.get('active')
sources = d.get('sources') or {}
if active and active in sources:
    print(sources[active].get('url', ''))
PY
}

#: 把「组修复」抽出来复用：先用现有节点跑一次（拉订阅之前），再用新订阅节点跑
#: 一次（热载之前）。两次的差别只有节点来源。
#: 用法：heal_groups <base配置> <节点来源> <输出> <屏蔽词>
heal_groups() {
  python3 - "$1" "$2" "$3" "$4" "$CLASH_BANNER_WORDS" \
            "$CLASH_HEALTH_URL" "$CLASH_HEALTH_INTERVAL" <<'PY'
import sys, yaml, pathlib

base_path, src_path, out_path = [pathlib.Path(x) for x in sys.argv[1:4]]
blocked, banner = sys.argv[4].split(), sys.argv[5].split()
health_url, health_interval = sys.argv[6], int(sys.argv[7])

base = yaml.safe_load(base_path.read_text()) or {}
src = yaml.safe_load(src_path.read_text()) or {}
groups = base.get('proxy-groups') or []
group_names = {g['name'] for g in groups}
system_names = {'DIRECT', 'REJECT', 'PASS', 'COMPATIBLE'}

fresh = src.get('proxies') or []
print(f'  订阅原始节点：{len(fresh)}')

kept = [p for p in fresh if not any(w in p.get('name', '') for w in blocked)]
print(f'  过滤后保留 {len(kept)} 节点，屏蔽 {len(fresh) - len(kept)} 节点（含香港/俄罗斯等）')

# 按 server+port+name 去重（订阅里经常有三条"剩余流量"占位）
seen, uniq = set(), []
for p in kept:
    key = (p.get('server'), p.get('port'), p.get('name'))
    if key in seen:
        continue
    seen.add(key)
    uniq.append(p)
print(f'  去重后 {len(uniq)} 节点')

base['proxies'] = uniq
new_names = [p['name'] for p in uniq]
valid = set(new_names)
# 广告位假节点在 select 组里留着当信息展示没问题，但当不了自动组的候选：
# 它们指向广告 sink，一旦被 url-test 选中，落在自动组上的规则就全瞎了。
auto_names = [n for n in new_names if not any(w in n for w in banner)]
print(f'  自动组候选 {len(auto_names)} 节点（剔除 {len(new_names) - len(auto_names)} 个广告位/引流位节点）')

for g in groups:
    name, gtype = g.get('name'), g.get('type')
    old = g.get('proxies') or []
    if gtype in ('url-test', 'fallback'):
        # 只写真代理名：把组名写进自动组会成引用环，mihomo 热载直接报错
        g['proxies'] = auto_names or old
        g['url'] = health_url
        iv = g.get('interval')
        if not isinstance(iv, int) or iv > health_interval:
            g['interval'] = health_interval
        if not g.get('max-failed'):
            # 连续失败 N 次就触发整组复测：没有它，坏节点能一直霸占到下次 interval
            g['max-failed'] = 3
    elif gtype == 'select':
        # 老顺序里仍然有效的名字保持在前面，新节点接上，嵌套组名与内置策略不动
        keep = [n for n in old if n in valid]
        extras = [n for n in old if n in group_names or n in system_names]
        g['proxies'] = [n for n in new_names if n not in keep] + keep + extras
    print(f'    {name}[{gtype}] 成员 {len(old)} → {len(g.get("proxies") or [])}')

# 新订阅可能删掉了老节点；任何组引用到不存在的代理，mihomo reload 会报 not found
for g in groups:
    if 'proxies' not in g:
        continue
    cleaned = [n for n in g['proxies']
               if n in valid or n in group_names or n in system_names]
    g['proxies'] = cleaned or ['DIRECT']

out_path.write_text(yaml.safe_dump(base, default_flow_style=False,
                                  allow_unicode=True, sort_keys=False))
print(f'  写入 {out_path}')
PY
}

#: 用 python 造 JSON body。节点名来自远端订阅，直接拼字符串的话名字里一个引号就能
#: 把请求体改写成别的字段；路径同理（start.sh 允许用 PROXY_SH= 指到带空格的位置）。
json_obj() {
  python3 -c 'import json, sys
print(json.dumps(dict(zip(sys.argv[1::2], sys.argv[2::2])), ensure_ascii=False))' "$@"
}

url_quote() { python3 -c 'import sys, urllib.parse
print(urllib.parse.quote(sys.argv[1]))' "$1"; }

#: 把本轮验证过的配置发布成 mihomo 的**启动**配置。
#: scripts/core/runtime.sh:537 里 `-f $RUNTIME_DIR/config.yaml` 是硬编码的（systemd
#: unit 只有 clashctl start-direct，没有 -f 可指），而那份 config.yaml 由 root 持有、
#: 停在上游最后一次生成的日子。不发布它，mihomo 一重启、或任何人调一次不带 path 的
#: PUT /configs，就会从那份化石配置重新加载 —— 刚刷进来的新节点当场蒸发。
publish_startup_cfg() {
  local src=$1 target=$RUNTIME_CFG owner
  if [ ! -w "$target" ]; then
    owner=$(stat -c %U "$target" 2>/dev/null || echo '?')
    STARTUP_CFG_STATUS="未发布：$target 属主 $owner 不可写，mihomo 重启会回退到旧快照（日志里有那两条一次性 sudo）"
    err "  启动配置 $target 不可写（属主 $owner）：本轮新节点只活在运行中的 mihomo 里，它一重启就回退。要持久化只需这两条一次性命令："
    err "    sudo cp -a $target $(dirname "$target")/config.upstream.bak.yaml"
    err "    sudo chown $(id -un):$(id -gn) $target"
    return 1
  fi
  # 只保留上一代：真出了事，一条 cp 就能退回去，不需要 accumulating 一堆 .bak.N
  cp -p "$target" "$target.prev" 2>/dev/null || true
  if cp "$src" "$target.tmp" && mv -f "$target.tmp" "$target"; then
    STARTUP_CFG_STATUS="已发布（重启不再回退）"
    log "  已发布启动配置：$target（mihomo 重启后不再回退到旧快照）"
    return 0
  fi
  rm -f "$target.tmp" 2>/dev/null || true
  STARTUP_CFG_STATUS="发布失败：$target 写不进去"
  err "  启动配置发布失败：$target 写不进去（本轮选路已成功，不影响退出码）"
  return 1
}

#: 热载。**任何时候都必须带 path**：PUT /configs 只给 mode/ports 时 mihomo 会从
#: 它启动时的 -f 配置（runtime/config.yaml，root 拥有的一份旧快照）整体重载，
#: 刚刷进去的新节点当场蒸发。
#: 热载成功后必须等一会儿再往下走：重载会让 mihomo 对在跑的整组（47 个节点）立刻
#: 开一轮健康检查，这个窗口里新建的 TLS 连接会被重置——实测拉订阅的第一跳就撞在
#: 上面，报成 curl 35「TLS 被重置」。那不是节点坏了（同一个节点几分钟后 10/10 全通），
#: 而旧代码把它当成坏节点，每轮都白改道一次、白留一行红色报错。
reload_cfg() {
  local target=$1 resp
  resp=$(curl -sS --max-time 10 -X PUT -H "Authorization: Bearer $SECRET" \
        -H "Content-Type: application/json" \
        -d "$(json_obj path "$target")" "$API/configs")
  if [ -n "$resp" ] && [ "$resp" != "{}" ]; then
    err "热载失败：$resp"
    return 1
  fi
  # 等这轮整组体检跑过去，别让下一步（拉订阅 / verify_loaded）踩在窗口里。
  sleep "$CLASH_RELOAD_SETTLE"
  return 0
}

#: 把一个组切到某个节点。名字不在该组成员里时 mihomo 回 400——这不是致命错误
#: （例如订阅组还没被本轮重建过），如实说清楚并继续，别把整次刷新判成失败。
switch_group() {
  local group=$1 name=$2 resp
  resp=$(curl -sS --max-time 5 -X PUT -H "Authorization: Bearer $SECRET" \
    -H "Content-Type: application/json" \
    -d "$(json_obj name "$name")" \
    "$API/proxies/$(url_quote "$group")" 2>/dev/null)
  if [ -n "$resp" ] && [ "$resp" != "{}" ]; then
    err "  切换 $group → $name 失败：$resp"
    return 1
  fi
  return 0
}

#: 本次写出的配置里，哪些 group 的声明成员在线上不存在。有漂移就打出来并回 1：
#: mihomo 重启、或外部有一次不带 path 的 PUT /configs，都会把线上配置打回启动时
#: 那份旧快照，症状正是「明明刷过订阅，出口还是那批死节点」。
group_drift() {
  python3 - "$1" "$API" "$SECRET" <<'PY'
import json, sys, urllib.parse, urllib.request, yaml, pathlib
cfg, api, secret = sys.argv[1], sys.argv[2], sys.argv[3]
d = yaml.safe_load(pathlib.Path(cfg).read_text()) or {}
bad = []
for g in d.get('proxy-groups') or []:
    want = set(g.get('proxies') or [])
    if not want:
        continue
    req = urllib.request.Request(
        api + f'/proxies/{urllib.parse.quote(g["name"])}',
        headers={'Authorization': f'Bearer {secret}'})
    try:
        live = set(json.load(urllib.request.urlopen(req, timeout=5)).get('all') or [])
    except Exception as e:
        bad.append(f'{g["name"]}(查询失败 {type(e).__name__})')
        continue
    if want - live:
        bad.append(f'{g["name"]}(缺 {len(want - live)} 个)')
print(' '.join(bad))
sys.exit(1 if bad else 0)
PY
}

#: 不一致就先重新热载一次（这一步通常就够），仍然不一致就如实报「新节点未生效」——
#: 静默继续会让下一轮刷新又走回那条死路线，而且没人知道。
verify_loaded() {
  local target=$1 got
  if got=$(group_drift "$target"); then
    return 0
  fi
  err "  线上配置与本次结果不一致：$got —— 已被回退（mihomo 重启或外部 PUT /configs 未带 path），重新热载"
  reload_cfg "$target" || true
  if got=$(group_drift "$target"); then
    log "  重新热载后已一致"
    return 0
  fi
  err "  重新热载后仍不一致：$got —— 新节点未生效，需检查 mihomo 的启动配置指向"
  return 1
}

#: 订阅域名命中哪个组。机场的规则把订阅域名单独钉在 自动选择 上，而拉订阅要走的
#: 恰恰就是它——这个组一旦停在死节点上，刷新就永远修不好自己（鸡生蛋）。
sub_group_for() {
  python3 - "$1" "$PATCHED_CFG" "$HEALED_CFG" "$RUNTIME_CFG" <<'PY'
import sys, pathlib, yaml, urllib.parse
host = urllib.parse.urlparse(sys.argv[1]).hostname or ''
for cfg in sys.argv[2:]:
    p = pathlib.Path(cfg)
    if not p.exists():
        continue
    d = yaml.safe_load(p.read_text()) or {}
    names = {g.get('name') for g in d.get('proxy-groups') or []}
    for rule in d.get('rules') or []:
        parts = str(rule).split(',')
        if len(parts) < 3:
            continue
        kind, arg, target = parts[0], parts[1], parts[-1]
        if target not in names:
            continue
        if kind == 'DOMAIN' and arg == host:
            print(target); sys.exit(0)
        if kind == 'DOMAIN-SUFFIX' and (host == arg or host.endswith('.' + arg)):
            print(target); sys.exit(0)
    break  # 只看第一份存在的配置，规则三份是一样的
PY
}

#: 拉不通时才介入：把订阅域名所在的那个组钉到一条真能出去的成员线路上。
#: 顺序很重要——不能用「预先探测」代替这一步，因为刚热载完 mihomo 正在跑整组
#: 体检，此时同步探测会大面积超时，报出一堆「所有成员都探不通」的假警报
#: （实测被这样骗过一次，而紧接着的拉取是成功的）。拉取本身就是对这条路线最准的探测。
ensure_sub_group_exit() {
  local group=$1
  [ -n "$group" ] || { echo "    订阅域名未命中独立组，无从改道"; return 1; }
  python3 - "$group" "$CLASH_SELECT_GROUP" "$API" "$SECRET" "$CLASH_PROBE_URL" <<'PY'
import json, sys, time, urllib.parse, urllib.request
group, select_group, api, secret, probe = sys.argv[1:6]
HDR = {'Authorization': f'Bearer {secret}'}

def get(path, timeout=8):
    return json.load(urllib.request.urlopen(urllib.request.Request(api + path, headers=HDR), timeout=timeout))

def put(path, body):
    req = urllib.request.Request(api + path, data=json.dumps(body).encode(),
                                 headers={**HDR, 'Content-Type': 'application/json'}, method='PUT')
    return urllib.request.urlopen(req, timeout=8).read()

def q(s):
    return urllib.parse.quote(s)

SYSTEM = {'DIRECT', 'REJECT', 'PASS', 'COMPATIBLE'}
info = get(f'/proxies/{q(group)}')
members = [n for n in (info.get('all') or []) if n not in SYSTEM]
now = info.get('now')

def reachable(name):
    try:
        return (get(f'/proxies/{q(name)}/delay?url={urllib.parse.quote(probe)}&timeout=3000', 6)
                .get('delay') or 0) > 0
    except Exception:
        return False

# 业务此刻在用的出口优先：它是上一次刷新实测选出来的最快节点
order = []
try:
    current = get(f'/proxies/{q(select_group)}').get('now')
    if current in members:
        order.append(current)
except Exception:
    pass
order += [n for n in members if n not in order]
probed = order[:10]

for name in probed:
    if reachable(name):
        put(f'/proxies/{q(group)}', {'name': name})
        time.sleep(0.2)
        print(f'    {group} 原出口 {now!r} 不通，已改钉到可用节点 {name}')
        sys.exit(0)
print(f'    ⚠ {group} 试探了 {len(probed)}/{len(members)} 个成员都不通，'
      f'订阅只能走缓存兜底（本轮 heal_groups 已重建它的成员表，下轮起应由 mihomo 自己复测恢复）')
sys.exit(1)
PY
}

#: curl 退出码 → 人话。「失败」两个字不足以让人判断是该换订阅地址还是该重启 mihomo。
curl_reason() {
  case "$1" in
    6) echo '域名解析失败' ;;
    7) echo '连不上（代理端口没开？）' ;;
    22) echo 'HTTP 错误（订阅地址可能被网关拦了）' ;;
    28) echo '超时' ;;
    35) echo 'TLS 被重置（该域名直连被墙，或被出口节点阻断）' ;;
    52) echo '空回复' ;;
    56) echo '连接被重置' ;;
    *) echo "curl 退出码 $1" ;;
  esac
}

#: 缓存按 URL 哈希命名，换订阅地址自然不会误用旧地址的缓存
sub_hash() { printf %s "$1" | sha256sum | cut -c1-16; }

cache_sub() {
  # 存 cache：下次网络挂掉时还能兜底
  cp "$2" "$SUB_CACHE_DIR/$(sub_hash "$1").yaml"
}

#: 单次拉取。$1 = 代理地址（空串表示真直连）
do_fetch() {
  local via=$1 out=$2 url=$3 args=(-fsS --max-time 15)
  [ -n "$via" ] && args+=(-x "$via")
  curl "${args[@]}" -o "$out" "$url" 2>/dev/null
}

#: 拉取失败的成因。rc=0 但正文为空是订阅地址失效/被截断的常见形态，
#: 报成「curl 退出码 0」等于没报。
fetch_fail_reason() {
  if [ "$1" = 0 ]; then
    echo '返回空内容（订阅地址可能已失效或换过了）'
  else
    curl_reason "$1"
  fi
}

#: 最近一次 fetch_via 的 curl 退出码，供调用方报成因。
LAST_FETCH_RC=0

#: 一个出口上的拉取：失败先**原地**重试，别急着改道。
#: 热载窗口里新建的 TLS 连接会被重置（见 reload_cfg），第一跳撞上就是一行假的
#: 「TLS 被重置」；真坏的节点怎么重试都不通，那时才轮到下面的改道分支。
#: 不加这一段的话，每轮刷新都要白改道一次、白切一个节点、白留一行红色报错。
fetch_via() {
  local via=$1 out=$2 url=$3 attempt=1
  while :; do
    : >"$out"
    LAST_FETCH_RC=0
    do_fetch "$via" "$out" "$url" || LAST_FETCH_RC=$?
    if [ "$LAST_FETCH_RC" = 0 ] && [ -s "$out" ]; then
      if [ "$attempt" != 1 ]; then
        log "  $attempt 次尝试才拉通（前面栽的是热载窗口，不是节点坏了）"
      fi
      return 0
    fi
    if [ "$attempt" -ge "$CLASH_FETCH_RETRY" ]; then
      return 1
    fi
    attempt=$((attempt + 1))
    sleep "$CLASH_FETCH_RETRY_WAIT"
  done
}

fetch_sub() {
  # 拉订阅：经本地代理 →（不通则改道后再试一次）→（可选）真直连 → 上次的 cache 兜底。
  # 顺序与旧版相反过：旧版先「direct」再 7890，而 tun.enable+auto-route+dns-hijack
  # 会把所谓 direct 也卷进 mihomo、命中同一条规则，于是两条回退其实是同一条路，
  # 每次都成对失败；且订阅域名在 Cloudflare 上，境内真直连必被 TLS 重置。
  local url=$1 out=$2 sub_group=$3
  : >"$out"

  local -a vias=("$LOCAL_PROXY")
  [ "${CLASH_TRY_DIRECT:-0}" = 1 ] && vias+=("")
  local via repaired=0
  for via in "${vias[@]}"; do
    local label="via ${via:-direct}"
    if fetch_via "$via" "$out" "$url"; then
      log "  订阅拉取成功（$label，$(wc -c <"$out") 字节）"
      cache_sub "$url" "$out"
      SUB_STATUS="新鲜（$label）"
      return 0
    fi
    log "  $label 失败：$(fetch_fail_reason "$LAST_FETCH_RC")"

    # 拉不通，最可能就是订阅域名被规则钉在的那个组停在死节点上（这正是旧版永远
    # 修不好自己的地方：要修的路线正是它用来取修复文件的路线）。改道后再试一次。
    if [ "$repaired" = 0 ] && [ -n "$sub_group" ] && [ "$via" = "$LOCAL_PROXY" ]; then
      repaired=1
      log "  尝试为 $sub_group 改道到可用出口后重试"
      if ensure_sub_group_exit "$sub_group"; then
        rc=0; do_fetch "$via" "$out" "$url" || rc=$?
        if [ "$rc" = 0 ] && [ -s "$out" ]; then
          log "  订阅拉取成功（改道后，$label，$(wc -c <"$out") 字节）"
          cache_sub "$url" "$out"
          SUB_STATUS="新鲜（$label，改道后）"
          return 0
        fi
        log "  改道后仍失败：$(fetch_fail_reason "$rc")"
      fi
    fi
  done

  # 兜底 cache
  local cached="$SUB_CACHE_DIR/$(sub_hash "$url").yaml"
  if [ -s "$cached" ]; then
    local age
    age=$(( ($(date +%s) - $(stat -c %Y "$cached")) / 86400 ))
    err "  订阅未能更新，沿用缓存（$(stat -c %y "$cached" | cut -d. -f1)，约 ${age} 天前）——节点可能已过期"
    cp "$cached" "$out"
    SUB_STATUS="缓存（约 ${age} 天前）"
    return 0
  fi
  SUB_STATUS="无缓存"
  return 1
}

refresh_and_select() {
  local sub_url=${CLASH_SUB_URL:-$(read_active_sub)}
  if [ -z "$sub_url" ]; then
    err "找不到订阅 URL：设 CLASH_SUB_URL 或在 subscriptions.yaml 设 active"
    exit 1
  fi
  log "订阅: $sub_url"

  # 拉订阅之前，先把「订阅域名所在的那个组」修健康。这一步是本脚本能自愈的关键：
  # 机场用一条 DOMAIN 规则把订阅域名单独钉在自动组上，而修复动作要靠拉取订阅才能
  # 完成——用一条坏掉的路线去取修好这条路线所需的东西，旧版因此永远修不好自己。
  # 先用上一轮的节点跑一次 heal_groups 并热载，本轮拉取就走在健康路线上。
  local sub_group prev_cfg
  sub_group=$(sub_group_for "$sub_url")
  prev_cfg=$RUNTIME_CFG
  [ -s "$PATCHED_CFG" ] && prev_cfg=$PATCHED_CFG
  if [ -n "$sub_group" ]; then
    log "预修复自动组（订阅域名归属 $sub_group）..."
    if heal_groups "$prev_cfg" "$prev_cfg" "$HEALED_CFG" "$CLASH_BLOCKED_WORDS"; then
      reload_cfg "$HEALED_CFG" && log "  预修复已热载" \
        || err "  预修复热载失败，本轮拉取按现状尝试"
    else
      err "  预修复生成配置失败，本轮拉取按现状尝试"
    fi
  fi

  local fresh=/tmp/clash-fresh.yaml
  fetch_sub "$sub_url" "$fresh" "$sub_group" || {
    err "订阅拉取失败且无缓存，沿用现有配置"
    log "订阅状态: $SUB_STATUS"
    return 0
  }

  # 解码阶段：base64 + share URI → clash proxies YAML
  # 订阅返回的三种形态都处理：(a) clash yaml 直接可用、(b) base64 包裹的
  # share URI、(c) 纯文本 share URI。解码结果落到 $fresh_yaml。
  local fresh_yaml=/tmp/clash-fresh.yaml.decoded
  log "解码订阅（base64 + share URI → clash proxies）..."
  python3 - "$fresh" "$fresh_yaml" <<'PY'
import sys, pathlib, base64, urllib.parse, re, yaml

src = pathlib.Path(sys.argv[1]).read_text()
out = pathlib.Path(sys.argv[2])

def is_yaml(s):
    try:
        d = yaml.safe_load(s)
        return isinstance(d, dict) and 'proxies' in d
    except Exception:
        return False

# Try parse as clash YAML first
if is_yaml(src):
    out.write_text(src)
    print('  格式：clash YAML，直接用')
    sys.exit(0)

# Try base64 decode
decoded = src
try:
    decoded = base64.b64decode(src, validate=False).decode('utf-8', errors='replace')
except Exception:
    pass

# Parse share URIs: hysteria2:// / vless:// / trojan:// / vmess:// / ss://
def clean_name(n):
    return ''.join(c for c in urllib.parse.unquote(n) if c.isprintable() and ord(c) >= 32).strip()

def parse_hysteria2(body, name):
    m = re.match(r'^([^@]+)@([^:?\\]+):(\d+)(\?.*)?$', body)
    if not m: return None
    pw, host, port, qs = m.groups()
    p = dict(urllib.parse.parse_qsl(qs.lstrip('?'))) if qs else {}
    return {'name': name, 'type': 'hysteria2', 'server': host, 'port': int(port),
            'password': pw, 'sni': p.get('sni', ''), 'up': 40, 'down': 200,
            'skip-cert-verify': p.get('insecure', '0') == '1',
            'ports': p.get('mport', '50000-53000')}

def parse_vless(body, name):
    m = re.match(r'^([^@]+)@([^:?\\]+):(\d+)(\?.*)?$', body)
    if not m: return None
    uuid, host, port, qs = m.groups()
    p = dict(urllib.parse.parse_qsl(qs.lstrip('?'))) if qs else {}
    r = {'name': name, 'type': 'vless', 'server': host, 'port': int(port),
         'uuid': uuid, 'udp': True, 'network': p.get('type', 'tcp'),
         'tls': True, 'sni': p.get('sni', ''),
         'client-fingerprint': 'chrome', 'skip-cert-verify': False}
    if p.get('type') == 'ws':
        r['ws-opts'] = {'path': p.get('path', '/'),
                        'headers': {'Host': p.get('host', p.get('sni', ''))}}
    return r

def parse_trojan(body, name):
    m = re.match(r'^([^@\\]+)@([^:?\\]+):(\d+)(\?.*)?$', body)
    if not m:
        # 有些机场的 trojan 链接 password@host:port 前带了 '\'
        m = re.match(r'^\\?([^@\\]+)@([^:?\\]+):(\d+)(\?.*)?$', body)
        if not m: return None
    pw, host, port, qs = m.groups()
    p = dict(urllib.parse.parse_qsl(qs.lstrip('?'))) if qs else {}
    r = {'name': name, 'type': 'trojan', 'server': host, 'port': int(port),
         'password': pw, 'udp': True, 'tls': True,
         'sni': p.get('sni', p.get('peer', '')),
         'client-fingerprint': p.get('fp', 'chrome'),
         'skip-cert-verify': p.get('allowInsecure', '0') == '1',
         'network': p.get('type', 'tcp')}
    if p.get('type') == 'ws':
        r['ws-opts'] = {'path': p.get('path', '/'),
                        'headers': {'Host': p.get('host', p.get('sni', ''))}}
    return r

def parse_vmess(body, name):
    try:
        import json as _j
        d = _j.loads(base64.b64decode(body).decode())
        return {'name': name, 'type': 'vmess', 'server': d.get('add'),
                'port': int(d.get('port', 0)), 'uuid': d.get('id'),
                'alterId': int(d.get('aid', 0)), 'cipher': 'auto', 'udp': True,
                'tls': d.get('tls') == 'tls', 'sni': d.get('sni') or d.get('host'),
                'network': d.get('net', 'tcp')}
    except Exception:
        return None

PARSERS = {'hysteria2': parse_hysteria2, 'vless': parse_vless,
           'trojan': parse_trojan, 'vmess': parse_vmess}

proxies, seen = [], set()
for line in decoded.splitlines():
    line = line.strip()
    if not line or '://' not in line: continue
    proto, rest = line.split('://', 1)
    parser = PARSERS.get(proto)
    if not parser: continue
    if '#' in rest:
        body, name = rest.rsplit('#', 1)
        name = clean_name(name)
    else:
        body, name = rest, f'{proto}-node'
    if name in seen:
        name = f'{name}-{len(seen)}'
    seen.add(name)
    p = parser(body, name)
    if p: proxies.append(p)

if not proxies:
    print('  ⚠ 解码后无可用节点，沿用现有配置', file=sys.stderr)
    sys.exit(1)

yaml.safe_dump({'proxies': proxies}, open(out, 'w'),
               default_flow_style=False, allow_unicode=True, sort_keys=False)
print(f'  格式：share URI，解码得到 {len(proxies)} 个节点')
PY
  [ -s "$fresh_yaml" ] || { err "解码失败，沿用现有配置"; log "订阅状态: $SUB_STATUS"; return 0; }
  fresh="$fresh_yaml"

  # 从 fresh 抽 proxies，过滤屏蔽词，把所有 group 的成员表与健康检查一起重建，
  # 落 PATCHED_CFG。base 优先取上一行预修复的产物，免得把刚修好的组结构又丢回旧快照。
  log "过滤 + 合并节点..."
  local merge_base=$RUNTIME_CFG
  [ -s "$HEALED_CFG" ] && merge_base=$HEALED_CFG
  heal_groups "$merge_base" "$fresh" "$PATCHED_CFG" "$CLASH_BLOCKED_WORDS" \
    || { err "合并失败，沿用现有配置"; return 0; }

  # Reload mihomo
  log "热载配置..."
  reload_cfg "$PATCHED_CFG" || { err "热载失败，进程未被改配置"; exit 1; }
  log "热载 OK"
  verify_loaded "$PATCHED_CFG" || true
  # 只有在「线上确实加载到了本轮结果」之后才发布：把一个没验证过的配置写成启动
  # 配置，等于把下一次的重启也押上。
  publish_startup_cfg "$PATCHED_CFG" || true

  # 延迟测试 + 选最快
  log "延迟测试 ($CLASH_PROBE_URL, 超时 ${CLASH_PROBE_TIMEOUT}ms)；域名级验收：订阅域名${CLASH_VERIFY_URLS:+ + $(printf %s "$CLASH_VERIFY_URLS" | tr ' ' ',')}"
  local pick
  pick=$(python3 - "$CLASH_SELECT_GROUP" "$CLASH_PROBE_URL" "$CLASH_PROBE_TIMEOUT" \
                         "$LOCAL_PROXY" "$CLASH_VERIFY_TOP" \
                         "$sub_url" "$sub_group" "$CLASH_VERIFY_URLS" <<'PY'
import sys, json, time, subprocess
import urllib.request, urllib.parse, urllib.error

group = sys.argv[1]
probe_url = sys.argv[2]
timeout = int(sys.argv[3])
local_proxy = sys.argv[4]
verify_top = int(sys.argv[5])
sub_url = sys.argv[6].strip()
sub_group = sys.argv[7].strip()
verify_urls = [u for u in sys.argv[8].split() if u]
API = 'http://127.0.0.1:9090'
SECRET = '8790c8111ef235e3'
SYSTEM = ('DIRECT', 'REJECT', 'PASS', 'COMPATIBLE')

def api_get(path):
    req = urllib.request.Request(API + path, headers={'Authorization': f'Bearer {SECRET}'})
    with urllib.request.urlopen(req, timeout=5) as r:
        return json.load(r)

def api_put(path, body):
    req = urllib.request.Request(API + path, data=json.dumps(body).encode(),
                                headers={'Authorization': f'Bearer {SECRET}',
                                         'Content-Type': 'application/json'},
                                method='PUT')
    with urllib.request.urlopen(req, timeout=5) as r:
        return r.read()

def q(s):
    return urllib.parse.quote(s)

info = api_get(f'/proxies/{q(group)}')
candidates = [n for n in info.get('all', []) if n not in SYSTEM]
was_now = info.get('now')

# 订阅域名被机场规则钉在 sub_group 上，所以对它的实测只有在把 sub_group 也钉到
# 候选节点上才算测这条候选。先把 sub_group 的当前出口记下来，失败时要还原。
sub_was_now = None
if sub_group and sub_group != group:
    try:
        sub_was_now = api_get(f'/proxies/{q(sub_group)}').get('now')
    except Exception:
        pass

print(f'  待测 {len(candidates)} 个候选')

results = []
for name in candidates:
    api_put(f'/proxies/{q(group)}', {'name': name})
    time.sleep(0.15)
    try:
        r = api_get(f'/proxies/{q(name)}/delay?url={urllib.parse.quote(probe_url)}&timeout={timeout}')
        ms = r.get('delay')
        if ms and ms > 0:
            results.append((ms, name))
            print(f'    ✓ {name}: {ms}ms')
        else:
            print(f'    ✗ {name}: timeout')
    except Exception as e:
        print(f'    ✗ {name}: {type(e).__name__}')

def restore():
    # 上面这个循环已经把这些组钉到最后一个被测节点上了；「保持现状」得真的是现状
    for grp, prev in ((group, was_now), (sub_group, sub_was_now)):
        if not (grp and prev):
            continue
        try:
            api_put(f'/proxies/{q(grp)}', {'name': prev})
        except Exception:
            pass

if not results:
    restore()
    print(f'NO_WINNER 全部候选都测不出延迟，已还原 {group} → {was_now}')
    sys.exit(0)

results.sort()

# 最快不等于送得出去。mihomo 的 delay 只测到节点握手为止，而且机场里有一批「偶尔
# 通一次」的不稳定线路：实测过 83ms 的 台湾家宽2-Gemini 选中后每条真实连接都超时，
# 也实测过 马来西亚2 连续 2 次探测里第 1 次通、第 2 次就 000，把 start.sh 的独立
# 连通性实测判死、整次刷新报失败。所以按延迟从小到大，用业务真正会走的那条路
# （本地混合端口 + 规则）连发两次，取两条都出得了站的。
opener = urllib.request.build_opener(urllib.request.ProxyHandler(
    {'http': local_proxy, 'https': local_proxy}))

def egress_probe(repeat=2):
    codes = []
    for _ in range(repeat):
        try:
            with opener.open(probe_url, timeout=12) as r:
                codes.append(r.status)
        except urllib.error.HTTPError as e:
            codes.append(e.code)
        except Exception:
            codes.append(0)
        if not (200 <= codes[-1] < 400):
            break
        time.sleep(0.15)
    return codes

#: 域名级验收：订阅域名 + 业务网关（CLASH_VERIFY_URLS，由 start.sh 从模型配置传下来）。
#: google 204 只证明「这条线路出得了站」，不证明业务域名握得上手 —— 2026-10-16 实测
#: 过一条对 google 连回两次 204、对订阅域名直接 TLS 重置（curl 35）的家宽线路被选成
#: winner，随后又被同步回 自动选择，于是下一轮拉订阅开局就报「TLS 被重置」。
#: 两类目标的判据不一样：
#:   网关：应用层答了话就算通（401/403/405 都是没带口令，不是网络坏了）；
#:   订阅：按下一轮 do_fetch 的 `curl -f` 口径判 2xx —— 订阅地址被出口拦成 403
#:         就等于这轮拉不到新节点，不能算这条候选可用。
#: 探针用 curl 不用 urllib：Cloudflare/WAF 按 UA 挡 Python-urllib，实测同一节点
#: 同一时刻 curl 拿 200、urllib 拿 403 —— 那是探针自己被拦，不是路线坏了。
targets = []
if sub_url:
    targets.append(('订阅域名', sub_url, 'fetch'))
for _u in verify_urls:
    targets.append((urllib.parse.urlparse(_u).hostname or _u, _u, 'egress'))

def domain_probe(url, repeat=2):
    """经本地代理取 url 两次。返回 (不通的次数, 最后的 curl 退出码, 最后的状态码)。

    两次都要拿到应用层应答才算这条线路稳：单次实测放过人 —— 2026-10-16 选出来的
    台湾家宽B3-直连AI 在选路时 poe 回 403（算通），几分钟后同一节点同一域名直接
    SSL_ERROR_SYSCALL（curl 35），而 run 就是死在这上面。
    """
    rc, code, bad = 0, 0, 0
    for i in range(repeat):
        p = subprocess.run(['curl', '-sS', '-o', '/dev/null', '-w', '%{http_code}',
                            '--max-time', '12', '-x', local_proxy, url],
                           capture_output=True, text=True)
        out = p.stdout.strip()
        rc, code = p.returncode, (int(out) if out.isdigit() else 0)
        if rc != 0:
            bad += 1
        if i + 1 < repeat:
            time.sleep(0.3)
    return bad, rc, code

tested = 0
for ms, name in results[:verify_top]:
    api_put(f'/proxies/{q(group)}', {'name': name})
    # 订阅域名的实测要把这条候选钉到 自动选择 上才测得着（规则把它钉在那个组上）。
    # 钉不上 = 它根本不在订阅组的候选里（广告位节点会过延迟测试，但它不是出口），
    # 这种「快」不能算赢：下一轮拉订阅走的还是别的节点。
    sub_pinned = True
    if sub_group and sub_group != group:
        try:
            api_put(f'/proxies/{q(sub_group)}', {'name': name})
        except Exception:
            sub_pinned = False
    time.sleep(0.2)
    tested += 1
    codes = egress_probe()
    if not (len(codes) >= 2 and all(200 <= c < 400 for c in codes)):
        print(f'    ✗ {name}（{ms}ms）出站不稳：{"->".join(map(str, codes))}，换下一条')
        continue
    blocked = []
    for label, url, kind in targets:
        if label == '订阅域名' and not sub_pinned:
            blocked.append('订阅域名=该节点不在订阅组候选里')
            continue
        bad, rc, code = domain_probe(url)
        if bad:
            why = f'(curl {rc})' if rc else f'(HTTP {code})'
            blocked.append(f'{label}={bad}/2 次不通{why}')
        elif kind == 'fetch' and not (200 <= code < 300):
            blocked.append(f'{label}=HTTP {code}')
    if blocked:
        why = '、'.join(blocked)
        print(f'    ✗ {name}（{ms}ms）出得了站但 {why}，换下一条')
        continue
    reach = f'，{len(targets)} 个业务域名可达' if targets else ''
    print(f'    ✓ 实测可出站：{name}（延迟 {ms}ms，连续 {len(codes)} 次 '
          f'{"->".join(map(str, codes))}{reach}，第 {tested} 个候选）')
    print(f'WINNER:{name}|{ms}ms')
    break
else:
    restore()
    print(f'NO_WINNER 最快的 {tested} 条实测都不能稳定送出业务流量，已还原 {group} → {was_now}')
PY
)
  echo "$pick" | tail -20 | sed 's/^/  /'

  local winner
  winner=$(echo "$pick" | grep -E "^WINNER:" | head -1 | cut -d: -f2- | cut -d'|' -f1)
  if [ -z "$winner" ]; then
    err "没有一条既快又能稳定送出业务流量（含订阅域名）的线路，保持现状"
    echo "$pick" | grep -E "^NO_WINNER" | sed 's/^/  /' >&2
    log "启动配置: $STARTUP_CFG_STATUS"
    log "订阅状态: $SUB_STATUS"
    exit 2
  fi
  log "最快节点：$winner"
  switch_group "$CLASH_SELECT_GROUP" "$winner" || true
  log "已切换 $CLASH_SELECT_GROUP → $winner"

  # 订阅域名所在的组跟着切到同一个节点：下一轮刷新取订阅时走的，就是这一轮
  # 实测最快、且**已经用它拉通过订阅**（见上面 targets 里的 订阅域名）的那条线路。
  # 这句是 2026-10-16 那次循环的解药：当时 winner 只过了 google 204，同步过来就把
  # 刚被证明会 TLS 重置的线路又钉回了订阅组，下一轮开局就得改道。
  if [ -n "$sub_group" ] && [ "$sub_group" != "$CLASH_SELECT_GROUP" ]; then
    if switch_group "$sub_group" "$winner"; then
      log "已同步 $sub_group → $winner（订阅拉取走同一条出口）"
    else
      err "  $sub_group 未能同步（该节点不在它的成员表里？下一轮 heal_groups 会重建）"
    fi
  fi

  # 这两行摘要必须是结尾：延迟表 echo 的是 tail -20，平台和本脚本都只看最后 20 行，
  # 打早了就被刷掉，UI 里就只剩「成功」两个字。
  log "启动配置: $STARTUP_CFG_STATUS"
  log "订阅状态: $SUB_STATUS"
}

cmd_start() {
  need_mihomo
  refresh_and_select
}

cmd_stop() {
  need_mihomo
  log "把 $CLASH_SELECT_GROUP 切回 DIRECT（外国流量直连，不走代理）"
  switch_group "$CLASH_SELECT_GROUP" DIRECT
  log "OK"
}

cmd_status() {
  need_mihomo
  python3 - <<PY
import json, urllib.request, urllib.parse
API = 'http://127.0.0.1:9090'
SECRET = '$SECRET'
def g(p):
    r = urllib.request.urlopen(urllib.request.Request(API+p, headers={'Authorization': f'Bearer {SECRET}'}), timeout=5)
    return json.load(r)
info = g('/proxies/$(python3 -c 'import urllib.parse;print(urllib.parse.quote("'${CLASH_SELECT_GROUP}'"))')')
print(f"${CLASH_SELECT_GROUP}: now = {info.get('now')}")
hist = info.get('history') or []
if hist:
    last = hist[-1]
    print(f"  last delay: {last.get('delay', '?')}ms @ {last.get('time')}")
print(f"  alive: {info.get('alive')}")
PY
  echo "订阅域名归属组：$(sub_group_for "${CLASH_SUB_URL:-$(read_active_sub)}")（拉订阅走的就是它，须与业务出口一致）"
  echo "启动配置：$(stat -c '%y  属主 %U' "$RUNTIME_CFG" 2>/dev/null) —— 与 patched 同日才算真的持久化了"
  echo "最近订阅更新："
  ls -lht "$SUB_CACHE_DIR" 2>/dev/null | head -5
}

case "${1:-}" in
  start)   cmd_start ;;
  stop)    cmd_stop ;;
  restart) cmd_stop; sleep 1; cmd_start ;;
  status)  cmd_status ;;
  *)
    echo "usage: $0 {start|stop|restart|status}"
    echo "env:   CLASH_SUB_URL CLASH_BLOCKED_WORDS CLASH_BANNER_WORDS CLASH_PROBE_URL"
    echo "       CLASH_PROBE_TIMEOUT CLASH_SELECT_GROUP CLASH_TRY_DIRECT CLASH_VERIFY_TOP"
    echo "       CLASH_VERIFY_URLS CLASH_RELOAD_SETTLE CLASH_FETCH_RETRY CLASH_FETCH_RETRY_WAIT"
    echo "       CLASH_MIXED_PORT CLASH_HEALTH_URL CLASH_HEALTH_INTERVAL"
    exit 2
    ;;
esac
