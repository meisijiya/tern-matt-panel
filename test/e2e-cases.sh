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

# 每次 ctl 都套超时：窗口崩了或卡死时立刻返回失败，
# 否则整段用例会无限等，跑不完就只能被外面切断 —— 一切断就留孤儿进程。
ctl() {
	timeout 10 "$tern_bin" ctl --control "$port" "$@"
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

# 反复点列表项直到目标文本出现。
# 竞态来源有两个：① 视图切换后布局会变，取坐标与实际点击之间可能错位；
# ② 外部数据（gh 拉取）可能还没到，列表此刻是空的。
# 幂等做法：点一次，等一小会儿，目标没出现就再点一次，直到超时。
# 点法用选择器而非坐标 —— 平台自己定位元素，命中率高得多。
click_item_until() {
	local sel="$1"
	local nth="$2"
	local needle="$3"
	local timeout_ms="$4"
	local ticks=$(( timeout_ms / 500 ))
	while [ "$ticks" -gt 0 ]; do
		ctl click "$sel" >/dev/null 2>&1 || true
		local out
		out="$(ctl tree 2>/dev/null || true)"
		if printf '%s' "$out" | grep -qF -- "$needle"; then
			return 0
		fi
		ticks=$((ticks - 1))
		sleep 0.5
	done
	echo "  FAIL 点「$sel」后等不到：$needle"
	return 1
}

# 反复点按钮直到目标文本出现（点空了就是"点了没反应"，重试即可）。
click_until() {
	local want="$1"
	local needle="$2"
	local timeout_ms="$3"
	local ticks=$(( timeout_ms / 500 ))
	while [ "$ticks" -gt 0 ]; do
		if click_text "$want" >/dev/null 2>&1; then
			local out
			out="$(ctl tree 2>/dev/null || true)"
			if printf '%s' "$out" | grep -qF -- "$needle"; then
				return 0
			fi
		fi
		ticks=$((ticks - 1))
		sleep 0.5
	done
	echo "  FAIL 点「$want」后等不到：$needle"
	return 1
}

# 反复按选择器点（ctl click 选择器）直到目标文本出现。
# ctl 的选择器点击点的是元素本身，命中与否受布局影响，点空了要重试。
click_sel_until() {
	local sel="$1"
	local needle="$2"
	local timeout_ms="$3"
	local ticks=$(( timeout_ms / 500 ))
	while [ "$ticks" -gt 0 ]; do
		ctl click "$sel" >/dev/null 2>&1 || true
		local out
		out="$(ctl tree 2>/dev/null || true)"
		if printf '%s' "$out" | grep -qF -- "$needle"; then
			return 0
		fi
		ticks=$((ticks - 1))
		sleep 0.5
	done
	echo "  FAIL 点「$sel」后等不到：$needle"
	return 1
}

# 等待某段文本出现（最多 timeout 毫秒）。
# 异步数据（gh 拉取、窗口回写）落盘时间不定，固定 sleep 会偶发失败 ——
# 等条件成立才是稳定的判据。
wait_for() {
	local needle="$1"
	local timeout_ms="$2"
	local ticks=$(( timeout_ms / 300 ))
	local blind=0
	while [ "$ticks" -gt 0 ]; do
		local out
		if out="$(ctl tree 2>/dev/null)" && [ -n "$out" ]; then
			blind=0
			if printf '%s' "$out" | grep -qF -- "$needle"; then
				return 0
			fi
		else
			# 连续读不到渲染树 = 窗口已经没了（GPU 崩、进程被杀）。
			# 这时再等下去毫无意义，还会把进程拖成孤儿。
			blind=$((blind + 1))
			if [ "$blind" -ge 5 ]; then
				echo "  FAIL 窗口失联（连续 5 次读不到渲染树），中止本轮"
				exit 2
			fi
		fi
		ticks=$((ticks - 1))
		sleep 0.3
	done
	echo "  FAIL 等不到：$needle"
	return 1
}

# 依赖不可用时跳过整个用例（不算失败）。
# GitHub GraphQL 有配额，e2e 连跑多次会触发限流 —— 那是环境问题不是产品缺陷。
skip=0
SKIPPED_NAMES=""

# 一个用例：名字 + 场景文件 + 断言序列
case_run() {
	local name="$1"
	local file="$2"
	shift 2
	echo "CASE $name"
	scen "$file"
	local ok=1
	local a
	local rest idx sel tmo needle
	local skipped=0
	for a in "$@"; do
		case "$a" in
		skip-if:*)
			# 前置依赖不可用时跳过本用例（不算失败）。
			# GitHub GraphQL 有配额，e2e 连跑多次会触发限流 —— 那是环境问题。
			needle="${a#skip-if:}"
			local out
			out="$(ctl tree 2>/dev/null || true)"
			if printf '%s' "$out" | grep -qF -- "$needle"; then
				echo "  (跳过原因：树上出现「$needle」）"
				skipped=1
				break
			fi
			;;
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
		wait-for:*)
			rest="${a#wait-for:}"
			idx="${rest##*:}"
			sel="${rest%:*}"
			wait_for "$sel" "$idx" || ok=0
			;;
		click-until:*)
			# 格式：click-until:<选择器>:<序号>:<目标文本>:<超时毫秒>
			rest="${a#click-until:}"
			tmo="${rest##*:}"
			rest="${rest%:*}"
			needle="${rest##*:}"
			rest="${rest%:*}"
			idx="${rest##*:}"
			sel="${rest%:*}"
			click_item_until "$sel" "$idx" "$needle" "$tmo" || ok=0
			;;
		click-btn-until:*)
			# 格式：click-btn-until:<按钮文字>:<目标文本>:<超时毫秒>
			rest="${a#click-btn-until:}"
			tmo="${rest##*:}"
			rest="${rest%:*}"
			needle="${rest##*:}"
			sel="${rest%:*}"
			click_until "$sel" "$needle" "$tmo" || ok=0
			;;
		click-sel-until:*)
			# 格式：click-sel-until:<选择器>:<目标文本>:<超时毫秒>
			rest="${a#click-sel-until:}"
			tmo="${rest##*:}"
			rest="${rest%:*}"
			needle="${rest##*:}"
			sel="${rest%:*}"
			click_sel_until "$sel" "$needle" "$tmo" || ok=0
			;;
		*) echo "  FAIL [$name] 未知断言：$a"; ok=0 ;;
		esac
	done
	if [ "$skipped" -eq 1 ]; then
		skip=$((skip + 1))
		SKIPPED_NAMES="$SKIPPED_NAMES$name
"
		echo "  SKIP $name（前置依赖不可用）"
		return 0
	fi
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
wait 10000
EOF
scen "$TMP/open.sc"

# ---------------------------------------------------------------- 用例 ----

# 1. 面板能打开，技能按泳道列出
case_run "面板打开并列出技能" "$TMP/noop.sc" \
	"wait-for:ask-matt:20000" \
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
wait 100
EOF
case_run "点技能行展开原文" "$TMP/open_doc.sc" \
	"click-sel-until:.sf-item:sf-md:20000"

# 5. 切到任务板：地图卡片与「可领」分组卡片
cat > "$TMP/board.sc" <<EOF
wait 100
EOF
case_run "切到任务板" "$TMP/board.sc" \
	"click-btn-until:任务板:点行选中:20000" \
	"skip-if:没有 wayfinder:map 地图" \
	"has:地图" \
	"has:点行选中"

# 6. 点地图行进地图详情：子票 / 迷雾 / 范围外
cat > "$TMP/map.sc" <<EOF
wait 100
EOF
case_run "地图详情视图" "$TMP/map.sc" \
	"click-btn-until:任务板:点行选中:20000" \
	"skip-if:没有 wayfinder:map 地图" \
	"click-until:.sf-item:1:子票:20000" \
	"has:返回任务板"

# 6b. 票行单击直接进详情：原来要双击才能打开，和地图行的单击手感不一致，
# 用户会以为「点不开」。这里点第 2 个 .sf-item（Spec 行或第一张票行），
# 票详情独有的「打开链接」出现即算通过。
cat > "$TMP/ticket_row.sc" <<EOF
wait 100
EOF
case_run "票行单击进详情" "$TMP/ticket_row.sc" \
	"click-btn-until:任务板:点行选中:20000" \
	"skip-if:没有 wayfinder:map 地图" \
	"click-until:.sf-item:2:打开链接:20000"

# 7. 技能视图有注入按钮（鼠标入口）
# 用例之间共享同一个面板，所以先切回技能视图。
cat > "$TMP/back_skills.sc" <<EOF
wait 100
EOF
case_run "技能注入有鼠标入口" "$TMP/back_skills.sc" \
	"click-btn-until:技能:ask-matt:15000" \
	"has:注入技能"

# 8. 注入后提示从"提交中"变成结果（结果回写通道）
# 断言"不再是提交中"而不是断言具体成功失败 —— 测试环境里可能没有邻近 agent，
# 成功与否取决于环境，回写通道本身才是被测对象。
cat > "$TMP/inject.sc" <<EOF
wait 100
EOF
case_run "注入结果回写" "$TMP/inject.sc" \
	"click-sel-until:.sf-item:sf-md:20000" \
	"click-btn-until:注入技能:提交中:10000" \
	"wait-for:提交失败:20000" \
	"lacks:提交中"

# 9. 「刷新」按钮重新拉数据（它的动作名与窗口戳宿主用的 refresh 刻意分开）
cat > "$TMP/reload.sc" <<EOF
wait 100
EOF
# 断言只到「已刷新」为止 —— 不再要求有票：
# 配额不足时刷新会拉取失败，分组自然是空的，那是有意跳过而非缺陷。
case_run "刷新按钮重新拉数据" "$TMP/reload.sc" \
	"click-btn-until:任务板:点行选中:20000" \
	"skip-if:没有 wayfinder:map 地图" \
	"click-btn-until:刷新:已刷新:20000"

# ---------------------------------------------------------------- 汇总 ----

echo
echo "e2e: passed=$PASS failed=$FAIL skipped=$skip"
if [ "$FAIL" -gt 0 ]; then
	echo "$FAILED_NAMES" | while IFS= read -r n; do
		if [ -n "$n" ]; then echo "  FAILED: $n"; fi
	done
	exit 1
fi
# 全部跳过 = 依赖不可用（如 GitHub 配额耗尽），不是"通过"。
# 退出码 2 = 环境故障主导，让流水线知道这一轮什么都没验到。
if [ "$PASS" -eq 0 ]; then
	echo "e2e: 全部用例被跳过 —— 依赖不可用，本轮未验证到任何东西"
	exit 2
fi
if [ "$skip" -gt 0 ]; then
	echo "$SKIPPED_NAMES" | while IFS= read -r n; do
		if [ -n "$n" ]; then echo "  SKIPPED: $n"; fi
	done
fi
exit 0
