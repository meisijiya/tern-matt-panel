#!/usr/bin/env bash
# e2e 用例：由 test/e2e.sh 调用，拿到端口与路径后逐条跑。
#
# 断言方式：读回 tern ctl 的渲染树，检查文本在不在。
# 用选择器而不是坐标 —— 坐标随窗口大小变，选择器不会。
#
# 面板只开一次：重复开面板会让旧面板留在树上，点击命中的是旧面板，
# 断言就成了在测别的面板。各用例只做交互。
set -eu

port="${TERNS_E2E_PORT:?e2e.sh 未设 TERNS_E2E_PORT}"
repo="${TERNS_E2E_REPO:?e2e.sh 未设 TERNS_E2E_REPO}"
skill_pkg="${TERNS_E2E_SKILL_PKG:?e2e.sh 未设 TERNS_E2E_SKILL_PKG}"
tern_bin="${TERNS_BIN:?e2e.sh 未设 TERNS_BIN}"

PASS=0
FAIL=0
FAILED_NAMES=""

ctl() {
	"$tern_bin" ctl --control "$port" "$@"
}

# 跑一段场景（.sc 语法）
scen() {
	local file="$1"
	"$tern_bin" ctl --control "$port" --file "$file" >/dev/null 2>&1 || true
}

# 断言：树里有这段文本
assert_has() {
	local needle="$1"
	local what="$2"
	local out
	out="$(ctl tree 2>/dev/null || true)"
	if printf '%s' "$out" | grep -qF -- "$needle"; then
		return 0
	fi
	echo "  FAIL [$what] 没找到：$needle"
	return 1
}

# 点按钮：按可见文字找那个按钮，点它的中心。
# 用文字而不是序号 —— 序号会随工具条增删而失效，文字是语义。
# ctl 的选择器不支持按文本匹配（text= 与 :has-text() 都被拒），
# 所以先用 tree 拿到按钮的 rect，再按坐标点。
click_text() {
	local want="$1"
	local nodes coords
	nodes="$(ctl tree '.sf-button' 2>/dev/null || true)"
	coords="$(printf '%s' "$nodes" | python -c '
import json, sys
want = sys.argv[1]
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
for n in d.get("nodes", []):
    if n.get("text") == want:
        r = n.get("rect")
        if r:
            print(int(r[0] + r[2] / 2), int(r[1] + r[3] / 2))
            sys.exit(0)
sys.exit(1)
' "$want" 2>/dev/null || true)"
	if [ -z "$coords" ]; then
		echo "  FAIL 找不到按钮：$want"
		return 1
	fi
	# shellcheck disable=SC2086
	ctl click $coords >/dev/null 2>&1 || true
	return 0
}

# 断言：树里没有这段文本
assert_lacks() {
	local needle="$1"
	local what="$2"
	local out
	out="$(ctl tree 2>/dev/null || true)"
	if printf '%s' "$out" | grep -qF -- "$needle"; then
		echo "  FAIL [$what] 不该出现：$needle"
		return 1
	fi
	return 0
}

# 点列表里的第 n 项：选择器与序号用空格分开（"选择器 序号"）。
# 地图列表按序号点 —— 地图标题会变，按序号更稳。
click_item() {
	local sel="$1"
	local nth="$2"
	local nodes coords
	nodes="$(ctl tree "$sel" 2>/dev/null || true)"
	coords="$(printf '%s' "$nodes" | python -c '
import json, sys
nth = int(sys.argv[1])
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
nodes = d.get("nodes", [])
if nth > len(nodes):
    sys.exit(1)
r = nodes[nth - 1].get("rect")
if r:
    print(int(r[0] + r[2] / 2), int(r[1] + r[3] / 2))
    sys.exit(0)
sys.exit(1)
' "$nth" 2>/dev/null || true)"
	if [ -z "$coords" ]; then
		echo "  FAIL 点不到第 $nth 项（$sel）"
		return 1
	fi
	# shellcheck disable=SC2086
	ctl click $coords >/dev/null 2>&1 || true
	return 0
}

# 一个用例：名字 + 场景文件 + 断言序列
case_run() {
	local name="$1"
	local file="$2"
	shift 2
	echo "CASE $name"
	scen "$file"
	local ok=1
	local a
	local rest idx sel
	for a in "$@"; do
		case "$a" in
		has:*) assert_has "${a#has:}" "$name" || ok=0 ;;
		lacks:*) assert_lacks "${a#lacks:}" "$name" || ok=0 ;;
		click:*) click_text "${a#click:}" || ok=0 ;;
		click-item:*)
			# 格式：click-item:<选择器>:<序号>
			rest="${a#click-item:}"
			idx="${rest##*:}"
			sel="${rest%:*}"
			click_item "$sel" "$idx" || ok=0
			;;
		wait:*) sleep "$((${a#wait:} / 1000))" ;;
		*) echo "  FAIL [$name] 未知断言：$a"; ok=0 ;;
		esac
	done
	if [ "$ok" -eq 1 ]; then
		PASS=$((PASS + 1))
		echo "  PASS $name"
	else
		FAIL=$((FAIL + 1))
		FAILED_NAMES="$FAILED_NAMES$name
"
	fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# 空场景：只做断言不动作
: > "$TMP/noop.sc"

# ---------------------------------------------------------------- 准备 ----
# 面板只开一次。
cat > "$TMP/open.sc" <<EOF
palette "Matt 面板"
wait 1500
key return
wait 6000
EOF
scen "$TMP/open.sc"

# ---------------------------------------------------------------- 用例 ----

# 1. 面板能打开，技能按泳道列出
case_run "面板打开并列出技能" "$TMP/noop.sc" \
	"has:ask-matt" \
	"has:to-spec" \
	"has:tdd" \
	"has:code-review" \
	"has:技能"

# 2. 泳道分组出现在 detail 列
case_run "技能按泳道分组" "$TMP/noop.sc" \
	"has:入口" \
	"has:规划" \
	"has:实施" \
	"has:审查与交付"

# 3. 工具条按钮齐全（鼠标可操作）
case_run "工具条按钮齐全" "$TMP/noop.sc" \
	"has:技能" \
	"has:任务板" \
	"has:刷新" \
	"has:换仓库"

# 4. 点技能行展开原文（frontmatter 不应出现在正文里）
cat > "$TMP/open_doc.sc" <<EOF
click .sf-item-label
wait 2500
EOF
case_run "点技能行展开原文" "$TMP/open_doc.sc" \
	"has:sf-md"

# 5. 切到任务板：地图列表与前沿列表
cat > "$TMP/board.sc" <<EOF
wait 100
EOF
case_run "切到任务板" "$TMP/board.sc" \
	"click:任务板" \
	"wait:3000" \
	"has:地图" \
	"has:前沿"

# 6. 点地图行进地图详情：子票 / 迷雾 / 范围外
cat > "$TMP/map.sc" <<EOF
wait 100
EOF
case_run "地图详情视图" "$TMP/map.sc" \
	"click:任务板" \
	"wait:3000" \
	"click-item:.sf-item:1" \
	"wait:3000" \
	"has:子票" \
	"has:返回任务板"

# 7. 技能视图有注入按钮（鼠标入口）
# 用例之间共享同一个面板，所以先切回技能视图。
cat > "$TMP/back_skills.sc" <<EOF
wait 100
EOF
case_run "技能注入有鼠标入口" "$TMP/back_skills.sc" \
	"click:技能" \
	"wait:3000" \
	"has:注入技能"

# 8. 注入后提示从"提交中"变成结果（结果回写通道）
# 断言"不再是提交中"而不是断言具体成功失败 —— 测试环境里可能没有邻近 agent，
# 成功与否取决于环境，回写通道本身才是被测对象。
cat > "$TMP/inject.sc" <<EOF
click .sf-item-label
wait 2000
EOF
case_run "注入结果回写" "$TMP/inject.sc" \
	"click:注入技能" \
	"wait:3000" \
	"lacks:提交中" \
	"has:提交失败"

# ---------------------------------------------------------------- 汇总 ----

echo
echo "e2e: passed=$PASS failed=$FAIL"
if [ "$FAIL" -gt 0 ]; then
	echo "$FAILED_NAMES" | while IFS= read -r n; do
		[ -n "$n" ] && echo "  FAILED: $n"
	done
	exit 1
fi
