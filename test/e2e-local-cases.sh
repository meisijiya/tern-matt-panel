#!/usr/bin/env bash
# 本地后端 e2e 用例：由 test/e2e-local.sh 调用（窗口已落在夹具仓库上）。
set -eu

port="${TERNS_E2E_PORT:?e2e-local.sh 未设 TERNS_E2E_PORT}"
fixture="${TERNS_E2E_FIXTURE:?e2e-local.sh 未设 TERNS_E2E_FIXTURE}"
tern_bin="${TERNS_BIN:?e2e-local.sh 未设 TERNS_BIN}"

PASS=0
FAIL=0
FAILED=""

ctl() { timeout 10 "$tern_bin" ctl --control "$port" "$@"; }
scen() { "$tern_bin" ctl --control "$port" --file "$1" >/dev/null 2>&1 || true; }

tree() { ctl tree 2>/dev/null || true; }

assert_has() {
	if tree | grep -qF -- "$1"; then
		return 0
	fi
	echo "  FAIL 没找到：$1"
	return 1
}

assert_lacks() {
	if tree | grep -qF -- "$1"; then
		echo "  FAIL 不该出现：$1"
		return 1
	fi
	return 0
}

wait_for() {
	local needle="$1"
	local ticks=$(( ${2:-20000} / 300 ))
	local blind=0
	while [ "$ticks" -gt 0 ]; do
		local out
		if out="$(tree)" && [ -n "$out" ]; then
			blind=0
			printf '%s' "$out" | grep -qF -- "$needle" && return 0
		else
			blind=$((blind + 1))
			if [ "$blind" -ge 5 ]; then
				echo "  FAIL 窗口失联，中止"
				exit 2
			fi
		fi
		ticks=$((ticks - 1))
		sleep 0.3
	done
	echo "  FAIL 等不到：$needle"
	return 1
}

# 按可见文字点元素（按钮与列表行都用它）：先取 rect，再按中心点。
click_text() {
	local want="$1"
	local coords
	coords="$(tree | python -c '
import json, sys
want = sys.argv[1]
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
for n in d.get("nodes", []):
    if n.get("text") == want:
        r = n.get("rect")
        if r and r[2] > 0 and r[3] > 0:
            print(int(r[0] + r[2] / 2), int(r[1] + r[3] / 2))
            sys.exit(0)
sys.exit(1)
' "$want" 2>/dev/null || true)"
	if [ -z "$coords" ]; then
		echo "  FAIL 找不到可点元素：$want"
		return 1
	fi
	# shellcheck disable=SC2086
	ctl click $coords >/dev/null 2>&1 || true
	return 0
}

run_case() {
	local name="$1"
	shift
	echo "CASE $name"
	local ok=1
	for a in "$@"; do
		case "$a" in
		has:*) assert_has "${a#has:}" || ok=0 ;;
		lacks:*) assert_lacks "${a#lacks:}" || ok=0 ;;
		click:*) click_text "${a#click:}" || ok=0 ;;
		wait-for:*) wait_for "${a#wait-for:}" || ok=0 ;;
		esac
	done
	if [ "$ok" -eq 1 ]; then
		PASS=$((PASS + 1))
		echo "  PASS $name"
	else
		FAIL=$((FAIL + 1))
		FAILED="$FAILED$name
"
	fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
: > "$TMP/noop.sc"

# ---- 开面板 ----
if tree | grep -qF '刷新'; then
	echo "e2e-local: 复用已开的面板"
else
	cat > "$TMP/open.sc" <<EOF
palette "Matt 面板"
wait 1500
key return
wait 8000
EOF
	scen "$TMP/open.sc"
fi

run_case "本地后端识别与依据来源" "$TMP/noop.sc" \
	"click:任务板" \
	"wait-for:本地 markdown" \
	"has:按约定文件"

run_case "地图卡与四组分组" "$TMP/noop.sc" \
	"has:alpha" \
	"has:可领" \
	"has:已认领" \
	"has:被阻塞" \
	"has:已关闭" \
	"has:第二张票" \
	"has:另一条线的第一张票"

run_case "票详情：全文 + 结构化状态 + 打开文档" "$TMP/noop.sc" \
	"click:第二张票" \
	"wait-for:验收二" \
	"has:状态：" \
	"has:已认领" \
	"has:.scratch/alpha/issues/02-second.md" \
	"has:打开文档" \
	"has:该文件 agent 也会写"

run_case "地图详情：迷雾与已决，不显示笔记" "$TMP/noop.sc" \
	"click:返回任务板" \
	"wait-for:可领" \
	"click:alpha" \
	"wait-for:迷雾" \
	"has:已有决策" \
	"has:先做第一张票" \
	"lacks:笔记段不该出现"

# 注入正文：读插件 kv，不读剪贴板（Windows 上不可靠）。
kv="$LOCALAPPDATA/Tern/plugin-data/tern-matt-panel/kv.json"
run_case "盘问注入：仓库相对路径，无远端命令" "$TMP/noop.sc" \
	"click:返回任务板" \
	"wait-for:可领" \
	"click:第二张票" \
	"wait-for:盘问" \
	"click:盘问"

sleep 1
if [ -f "$kv" ]; then
	body="$(python -c '
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
a = d.get("action") or {}
print(a.get("body") or "")
' "$kv" 2>/dev/null || true)"
	if printf '%s' "$body" | grep -qF '.scratch/alpha/issues/02-second.md' \
		&& ! printf '%s' "$body" | grep -qF 'gh issue view' \
		&& ! printf '%s' "$body" | grep -qF 'gh issue list'; then
		PASS=$((PASS + 1))
		echo "  PASS 注入正文（kv）"
	else
		FAIL=$((FAIL + 1))
		FAILED="$FAILED注入正文（kv）
"
		echo "  FAIL 注入正文不含仓库相对路径或仍带远端命令"
	fi
else
	echo "  SKIP 读不到插件 kv（$kv）"
fi

run_case "打开文档：调出 tern 文档视图" "$TMP/noop.sc" \
	"wait-for:打开文档" \
	"click:打开文档" \
	"wait-for:已打开文档:8000"

echo
echo "e2e-local: PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -ne 0 ]; then
	printf 'failed cases:\n%s' "$FAILED" >&2
	exit 1
fi
if [ "$PASS" -eq 0 ]; then
	echo "e2e-local: 一个用例都没跑到（环境不可用）" >&2
	exit 2
fi
exit 0
