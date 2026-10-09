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
#   CLASH_PROBE_URL       覆盖延迟探测 URL（默认 google 204）
#   CLASH_PROBE_TIMEOUT   覆盖探测超时 ms（默认 5000）
#   CLASH_SELECT_GROUP    覆盖要切换的 proxy-group（默认 白嫖机场）

set -euo pipefail

RUNTIME_DIR=/home/vz/Tery/clash-for-linux/runtime
SUBS_FILE=$RUNTIME_DIR/subscriptions.yaml
RUNTIME_CFG=$RUNTIME_DIR/config.yaml
PATCHED_CFG=$RUNTIME_DIR/config.patched.yaml
SUB_CACHE_DIR=$RUNTIME_DIR/cache/subs
SECRET=8790c8111ef235e3
API=http://127.0.0.1:9090

: "${CLASH_PROBE_URL:=https://www.google.com/generate_204}"
: "${CLASH_PROBE_TIMEOUT:=5000}"
: "${CLASH_SELECT_GROUP:=白嫖机场}"
# Claude 不支持 + 高风险国家/地区（含港台常用变体字）
: "${CLASH_BLOCKED_WORDS:=香港 俄羅斯 俄罗斯 印度 巴基斯坦 孟加拉 土耳其 尼日利亞 尼日利亚 肯尼亚 巴西 阿根廷 越南 印尼 菲律賓 菲律宾}"

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

fetch_sub() {
  # 拉订阅：先 direct、再经本地代理、最后 fallback 到上次的 cache
  local url=$1 out=$2
  : >"$out"
  for via in "" "http://127.0.0.1:7890"; do
    local label="${via:-direct}"
    if curl -fsS --max-time 20 ${via:+-x "$via"} -o "$out" "$url" 2>/dev/null; then
      if [ -s "$out" ]; then
        log "  订阅拉取成功（via $label，$(wc -c <"$out") 字节）"
        # 存 cache（按 URL 哈希命名，下次网络挂掉能兜底）
        cp "$out" "$SUB_CACHE_DIR/$(printf %s "$url" | sha256sum | cut -c1-16).yaml"
        return 0
      fi
    fi
    log "  via $label 失败"
  done
  # 兜底 cache
  local cached="$SUB_CACHE_DIR/$(printf %s "$url" | sha256sum | cut -c1-16).yaml"
  if [ -s "$cached" ]; then
    log "  用缓存兜底（$(stat -c %y "$cached" | cut -d. -f1)）"
    cp "$cached" "$out"
    return 0
  fi
  return 1
}

refresh_and_select() {
  local sub_url=${CLASH_SUB_URL:-$(read_active_sub)}
  if [ -z "$sub_url" ]; then
    err "找不到订阅 URL：设 CLASH_SUB_URL 或在 subscriptions.yaml 设 active"
    exit 1
  fi
  log "订阅: $sub_url"

  local fresh=/tmp/clash-fresh.yaml
  fetch_sub "$sub_url" "$fresh" || {
    err "订阅拉取失败且无缓存，沿用现有配置"
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
  [ -s "$fresh_yaml" ] || { err "解码失败，沿用现有配置"; return 0; }
  fresh="$fresh_yaml"

  # Python 阶段：从 fresh 抽 proxies，过滤屏蔽词，合并到 RUNTIME_CFG，落 PATCHED_CFG
  log "过滤 + 合并节点..."
  python3 - "$RUNTIME_CFG" "$fresh" "$PATCHED_CFG" "$CLASH_BLOCKED_WORDS" <<'PY'
import sys, yaml, pathlib, re
base_path, fresh_path, out_path = [pathlib.Path(x) for x in sys.argv[1:4]]
blocked_words = sys.argv[4].split()

base = yaml.safe_load(base_path.read_text()) or {}
fresh = yaml.safe_load(fresh_path.read_text()) or {}

fresh_proxies = fresh.get('proxies') or []
print(f'  订阅原始节点：{len(fresh_proxies)}')

# 过滤
kept, dropped = [], []
for p in fresh_proxies:
    name = p.get('name', '')
    if any(w in name for w in blocked_words):
        dropped.append(name)
        continue
    kept.append(p)
print(f'  过滤后保留 {len(kept)} 节点，屏蔽 {len(dropped)} 节点（含香港/俄罗斯等）')

# 按 server+port+name 去重（订阅里经常有三条"剩余流量"占位）
seen, uniq = set(), []
for p in kept:
    key = (p.get('server'), p.get('port'), p.get('name'))
    if key in seen: continue
    seen.add(key)
    uniq.append(p)
print(f'  去重后 {len(uniq)} 节点')

# 替换 base['proxies']，保留 base['proxy-groups']/rules/dns/tun 不动
base['proxies'] = uniq
new_names = [p['name'] for p in uniq]
valid_names = set(new_names)
group_names = {g['name'] for g in base.get('proxy-groups', [])}
system_names = {'DIRECT', 'REJECT', 'PASS', 'COMPATIBLE'}

# 让 白嫖机场 selector 包含所有新节点（去掉已删的）
for g in base.get('proxy-groups', []):
    if g.get('name') == '白嫖机场':
        keep = [n for n in (g.get('proxies') or []) if n in system_names or n in valid_names]
        g['proxies'] = [n for n in new_names if n not in keep] + keep
        break

# 新订阅可能删掉了老节点（如"剩余流量：987.41 GB"占位），把所有 group
# 里对不存在代理的引用清掉，否则 mihomo reload 会报 "not found"。
for g in base.get('proxy-groups', []):
    if 'proxies' not in g: continue
    cleaned = [n for n in g['proxies']
               if n in valid_names or n in group_names or n in system_names]
    if not cleaned:
        cleaned = ['DIRECT']
    g['proxies'] = cleaned

out_path.write_text(yaml.safe_dump(base, default_flow_style=False, allow_unicode=True, sort_keys=False))
print(f'  写入 {out_path}')
PY

  # Reload mihomo
  log "热载配置..."
  local resp
  resp=$(curl -sS --max-time 10 -X PUT -H "Authorization: Bearer $SECRET" \
        -H "Content-Type: application/json" \
        -d "{\"path\":\"$PATCHED_CFG\"}" "$API/configs")
  if [ -n "$resp" ] && [ "$resp" != "{}" ]; then
    err "热载失败：$resp"
    exit 1
  fi
  log "热载 OK"

  # 延迟测试 + 选最快
  log "延迟测试 ($CLASH_PROBE_URL, 超时 ${CLASH_PROBE_TIMEOUT}ms)..."
  local pick
  pick=$(python3 - "$CLASH_SELECT_GROUP" "$CLASH_PROBE_URL" "$CLASH_PROBE_TIMEOUT" <<'PY'
import sys, json, time
import urllib.request, urllib.parse

group = sys.argv[1]
probe_url = sys.argv[2]
timeout = int(sys.argv[3])
API = 'http://127.0.0.1:9090'
SECRET = '8790c8111ef235e3'

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

info = api_get(f'/proxies/{urllib.parse.quote(group)}')
candidates = [n for n in info.get('all', []) if n not in ('DIRECT', 'REJECT', 'PASS', 'COMPATIBLE')]
print(f'  待测 {len(candidates)} 个候选')

results = []
for name in candidates:
    api_put(f'/proxies/{urllib.parse.quote(group)}', {'name': name})
    time.sleep(0.15)
    try:
        t0 = time.time()
        r = api_get(f'/proxies/{urllib.parse.quote(name)}/delay?url={urllib.parse.quote(probe_url)}&timeout={timeout}')
        ms = r.get('delay')
        if ms and ms > 0:
            results.append((ms, name))
            print(f'    ✓ {name}: {ms}ms')
        else:
            print(f'    ✗ {name}: timeout')
    except Exception as e:
        print(f'    ✗ {name}: {type(e).__name__}')

if not results:
    print('NO_WINNER')
    sys.exit(0)
results.sort()
print(f'WINNER:{results[0][1]}|{results[0][0]}ms')
PY
)
  echo "$pick" | tail -20 | sed 's/^/  /'

  local winner
  winner=$(echo "$pick" | grep -E "^WINNER:" | head -1 | cut -d: -f2- | cut -d'|' -f1)
  if [ -z "$winner" ]; then
    err "所有节点延迟测试失败，保持现状"
    exit 2
  fi
  log "最快节点：$winner"
  curl -sS --max-time 5 -X PUT -H "Authorization: Bearer $SECRET" \
    -H "Content-Type: application/json" \
    -d "{\"name\":\"$winner\"}" "$API/proxies/$(printf %s "$CLASH_SELECT_GROUP" | python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))' "$CLASH_SELECT_GROUP")" >/dev/null
  log "已切换 $CLASH_SELECT_GROUP → $winner"
}

cmd_start() {
  need_mihomo
  refresh_and_select
}

cmd_stop() {
  need_mihomo
  log "把 $CLASH_SELECT_GROUP 切回 DIRECT（外国流量直连，不走代理）"
  curl -sS --max-time 5 -X PUT -H "Authorization: Bearer $SECRET" \
    -H "Content-Type: application/json" \
    -d '{"name":"DIRECT"}' \
    "$API/proxies/$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))' "$CLASH_SELECT_GROUP")" >/dev/null
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
    echo "env:   CLASH_SUB_URL CLASH_BLOCKED_WORDS CLASH_PROBE_URL CLASH_PROBE_TIMEOUT CLASH_SELECT_GROUP"
    exit 2
    ;;
esac
