#!/usr/bin/env bash
# 真机注入探针：验证 Tern 这版上 cx:run 还能写进原生 omp 输入框、surface 还能读回。
#
#   test/probe-inject.sh [--pane ID] [--keep]
#
# 依赖：Git Bash、Tern 在跑（有至少一个 omp agent 块）、python。
# 只碰一个块：默认取第一个 omp agent，--pane 指定。
# 结束会把自己注入的探针文本 backspace 掉，并 unlink 探针插件（--keep 保留插件）。
#
# 为什么要脚本：这套事实（cx:run 有效、surface 的 composer 可读、括号粘贴保留换行）
# 会随 Tern 升级腐烂，人工探针每次重写都踩同样的坑。探针插件在 test/probe/。
set -eu

case "${WSL_DISTRO_NAME:-}" in
"") ;;
*)
	echo "检测到 WSL：本脚本要在 Git Bash 下跑。" >&2
	exit 2
	;;
esac
case "$PWD" in
/mnt/*)
	echo "当前目录在 WSL 的 /mnt 下：本脚本要在 Git Bash 下跑。" >&2
	exit 2
	;;
esac

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(dirname "$here")"
probe="$here/probe"
out="$(cd "$repo/.." && pwd)/.tern-matt-panel.probe.json"
tern_bin="${TERN_BIN:-tern}"

pane=""
keep=0
while [ $# -gt 0 ]; do
	case "$1" in
	--pane) pane="${2:?--pane 需要块 id}"; shift 2 ;;
	--keep) keep=1; shift ;;
	*)
		echo "用法：test/probe-inject.sh [--pane ID] [--keep]" >&2
		exit 2
		;;
	esac
done

rm -f "$out"

"$tern_bin" plugin link "$probe" >/dev/null 2>&1 || true
"$tern_bin" plugin reload tern-matt-panel-probe >/dev/null 2>&1 || true

# ---- 目标块：等探针公布 agent 列表（tern ls 不给 command，认不出 omp 块） ----
# 窗口半边随窗口事件重载：先给一个焦点，别干等。
nudge="$("$tern_bin" ls --json | python -c '
import json, sys
data = json.load(sys.stdin)
for session in data.get("sessions", []):
    for tab in session.get("tabs", []):
        for block in tab.get("blocks", []):
            program = block.get("program") or ""
            if block.get("id") and not program.startswith("tern-matt-panel"):
                print(block["id"])
                raise SystemExit
')"
if [ -n "$nudge" ]; then
	"$tern_bin" focus "$nudge" >/dev/null 2>&1 || true
fi

if [ -z "$pane" ]; then
	for _ in $(seq 1 20); do
		pane="$(python -c '
import io, json, os
path = os.path.join(os.environ["LOCALAPPDATA"], "Tern", "plugin-data", "tern-matt-panel-probe", "kv.json")
try:
    with io.open(path, encoding="utf-8") as f:
        data = json.load(f)
    panes = (data.get("agents") or {}).get("panes") or []
    print(panes[0] if panes else "")
except Exception:
    print("")
')"
		if [ -n "$pane" ]; then
			break
		fi
		sleep 0.5
	done
fi
if [ -z "$pane" ]; then
	echo "找不到 agent 块：先在一个 tab 里跑 omp，或用 --pane ID 指定。" >&2
	exit 2
fi

echo "目标块：$pane"

marker="PROBE_$(date +%s)_$$"
nonce="$marker"

# ---- 放请求（kv 在插件数据目录，仓库外） ----
python - "$out" "$pane" "$marker" "$nonce" <<'PY'
import io, json, os, sys

out, pane, marker, nonce = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
path = os.path.join(os.environ["LOCALAPPDATA"], "Tern", "plugin-data", "tern-matt-panel-probe", "kv.json")
data = {}
if os.path.exists(path):
    try:
        with io.open(path, encoding="utf-8") as f:
            data = json.load(f)
    except Exception:
        data = {}
data["request"] = {"pane": pane, "out": out, "marker": marker, "nonce": nonce}
os.makedirs(os.path.dirname(path), exist_ok=True)
with io.open(path, "w", encoding="utf-8") as f:
    f.write(json.dumps(data, ensure_ascii=False))
PY

# 窗口半边随窗口事件重载：给一下焦点，别干等。
"$tern_bin" focus "$pane" >/dev/null 2>&1 || true

# ---- 收尾（任何退出都走）：删掉自己注入的那段、撤请求、卸插件 ----
# 注入文本 = marker + "\n" + PROBE_LINE2；多按一个都会吃掉用户原有草稿。
# 只在「结果文件确实读到了这段文本」时才按 backspace；没读到就说明没写进去，不碰输入框。
cleanup() {
	if [ -f "$out" ] && python - "$out" "$marker" <<'PY'
import io, json, sys

with io.open(sys.argv[1], encoding="utf-8") as f:
    r = json.load(f)
after = r.get("after")
sys.exit(0 if isinstance(after, str) and sys.argv[2] in after else 1)
PY
	then
		total=$(python -c 'import sys; print(len(sys.argv[1]) + 1 + len("PROBE_LINE2"))' "$marker")
		while [ "$total" -gt 0 ]; do
			step=30
			if [ "$total" -lt "$step" ]; then
				step="$total"
			fi
			keys=""
			for _ in $(seq 1 "$step"); do
				keys="$keys backspace"
			done
			# shellcheck disable=SC2086
			"$tern_bin" send "$pane" keys $keys >/dev/null 2>&1 || true
			total=$((total - step))
			sleep 0.3
		done
	fi
	rm -f "$out"
	python - <<'PY'
import io, json, os

path = os.path.join(os.environ["LOCALAPPDATA"], "Tern", "plugin-data", "tern-matt-panel-probe", "kv.json")
if os.path.exists(path):
    try:
        with io.open(path, encoding="utf-8") as f:
            data = json.load(f)
        data.pop("request", None)
        with io.open(path, "w", encoding="utf-8") as f:
            f.write(json.dumps(data, ensure_ascii=False))
    except Exception:
        pass
PY
	if [ "$keep" = "0" ]; then
		"$tern_bin" plugin unlink tern-matt-panel-probe >/dev/null 2>&1 || true
	fi
}
trap cleanup EXIT

# ---- 等结果（窗口半边没重载时不会出现） ----
found=0
for _ in $(seq 1 40); do
	if [ -f "$out" ]; then
		found=1
		break
	fi
	sleep 0.5
done
if [ "$found" != "1" ]; then
	echo "20 秒没有结果：窗口半边可能没重载。切一下 Tern 窗口或重开面板后重跑。" >&2
	exit 3
fi

# ---- 断言 ----
verdict="$(python - "$out" "$marker" <<'PY'
import io, json, sys

out, marker = sys.argv[1], sys.argv[2]
with io.open(out, encoding="utf-8") as f:
    r = json.load(f)
after = r.get("after")
print("before =", repr(r.get("before")))
print("after  =", repr(after))
print("focused =", r.get("focused"))
if not isinstance(after, str):
    print("verdict = read-miss")
elif after == "" and not r.get("focused"):
    # 非焦点/隐藏 tab 的 composer 读成空串：判不了，不是失败。
    print("verdict = unknown")
elif marker + "\nPROBE_LINE2" not in after:
    print("verdict = fail")
elif "\x1b" in after or "200~" in after or "201~" in after:
    # 括号粘贴标记没被吃掉：cx:run 不支持粘贴，多行文本会被写坏。
    print("verdict = escape-leaked")
else:
    print("verdict = pass")
PY
)"
echo "$verdict"

case "$verdict" in
*"verdict = pass"*)
	echo "PASS：cx:run 写入 + surface 读回 + 括号粘贴多行（含换行）都成立。"
	;;
*"verdict = unknown"*)
	echo "判不了：目标块不在前台，surface 读成空串。切到它所在的 tab 再跑一次。" >&2
	exit 5
	;;
*"verdict = read-miss"*)
	echo "读不到 surface 的 composer：Tern 这版改了渲染树？" >&2
	exit 4
	;;
*"verdict = escape-leaked"*)
	echo "括号粘贴标记漏进了输入框：cx:run 不接受括号粘贴。" >&2
	exit 4
	;;
*)
	echo "注入探针失败：cx:run 没把正文写进输入框。" >&2
	exit 4
	;;
esac
