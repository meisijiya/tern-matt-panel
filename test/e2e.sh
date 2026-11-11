#!/usr/bin/env bash
# 真机端到端测试：起一个受控 tern 窗口，驱动插件交互，读回渲染树做断言。
#
# 窗口与面板都复用：默认接上已经开着的受控 tern 窗口，不自己起（一个窗口就是一份
# GPU 与内存开销）；只有 --launch 才起窗口，且只在 --launch 起的窗口上做关闭。
# 里面已经开着的面板也不再开第二个；跑完不留窗口堆。
#
#   test/e2e.sh [--port N] [--launch] [--keep]
#
# 选项：
#   --port N      接哪个控制端口（默认依次试 17311–17315 与上次记下的端口）
#   --launch      自己起一个受控窗口（默认不；没有可接的窗口就 SKIP）
#   --keep        --launch 起的窗口跑完不关
#
# 依赖：tern（能起 --control 窗口）、gh（已登录）、本机已装中文技能包。
# 缺任一项 → 该用例记为 SKIP 并说明原因，不算失败。
set -eu

# 必须在 Git Bash（MSYS）下跑。WSL 的 bash 看不到 /c/... 与 D:/... 路径，
# 会给出「没有 luau-analyze」「找不到仓库」这类假警报，实测排查成本很高。
# 判据用 PWD：本机 bash 首项解析到 C:\WINDOWS\system32\bash.exe（WSL）。
case "${WSL_DISTRO_NAME:-}" in
"") ;;
*)
	echo "检测到 WSL（WSL_DISTRO_NAME=$WSL_DISTRO_NAME）：本脚本要在 Git Bash 下跑。" >&2
	echo "  \"/c/Program Files/Git/bin/bash.exe\" test/$(basename "$0") $*" >&2
	exit 2
	;;
esac
case "$PWD" in
/mnt/*)
	echo "当前目录在 WSL 的 /mnt 下：本脚本要在 Git Bash 下跑。" >&2
	echo "  \"/c/Program Files/Git/bin/bash.exe\" test/$(basename "$0") $*" >&2
	exit 2
	;;
esac


here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/.." && pwd)"

# ---- 环境归位：Windows 上 bash 可能是 WSL，Windows 的 .exe 在 WSL 里跑不了 ----
# 判定用 bash --version（WSL 报 x86_64-pc-linux-gnu，Git Bash 报 msys/mingw）——
# uname -s 不可靠。
if ! bash --version 2>/dev/null | head -1 | grep -qiE "msys|mingw"; then
	# WSL 里的路径映射：/mnt/c → /c，/mnt/d → /d
	gitbash=""
	for cand in "/mnt/c/Program Files/Git/bin/bash.exe" "/c/Program Files/Git/bin/bash.exe"; do
		if [ -f "$cand" ]; then
			gitbash="$cand"
			break
		fi
	done
	if [ -z "$gitbash" ]; then
		echo "SKIP: 需要 Git Bash（本机 bash 是 WSL，跑不了 Windows 的 .exe）"
		exit 2
	fi
	# Git Bash 里的仓库路径：/mnt/d/x → /d/x，/mnt/c/x → /c/x
	case "$repo" in
	/mnt/[a-z]/*) repo_git="/${repo#/mnt/}" ;;
	*) repo_git="$repo" ;;
	esac
	# args 用 printf %q 逐个转义（路径可能带空格）
	args=""
	for a in "$@"; do
		args="$args $(printf '%q' "$a")"
	done
	exec "$gitbash" -lc "cd '$repo_git' && bash test/e2e.sh$args"
fi

# ---- 解析工具绝对路径 ----
# Windows 的 exe 用 [ -f ] 判存在（没有执行位）；[ -x ] 会误判。
resolve_tool() {
	local name="$1"
	shift
	local c
	if command -v "$name" >/dev/null 2>&1; then
		command -v "$name"
		return 0
	fi
	for c in "$@"; do
		if [ -f "$c" ]; then
			echo "$c"
			return 0
		fi
	done
	return 1
}

tern_bin="$(resolve_tool tern \
	"/c/programs/Tern/tern.exe" \
	"/c/Program Files/Tern/tern.exe" \
	"/c/Users/22923/AppData/Local/Tern/tern.exe" || true)"
if [ -z "$tern_bin" ]; then
	echo "SKIP: 找不到 tern"
	exit 2
fi

gh_bin="$(resolve_tool gh \
	"/c/Program Files/GitHub CLI/gh.exe" \
	"/c/Program Files (x86)/GitHub CLI/gh.exe" || true)"
if [ -z "$gh_bin" ]; then
	echo "SKIP: 找不到 gh"
	exit 2
fi

if ! "$gh_bin" auth status >/dev/null 2>&1; then
	echo "SKIP: gh 未登录"
	exit 2
fi

# 技能包：面板的核心依赖。探测位置与插件一致（见 lib/paths.luau）。
skill_pkg=""
for base in "${USERPROFILE:-}" "${HOME:-}"; do
	[ -z "$base" ] && continue
	if [ -d "$base/.omp/plugins/cache/marketplaces/mattpocock/skills" ]; then
		skill_pkg="$base/.omp/plugins/cache/marketplaces/mattpocock"
		break
	fi
done
if [ -z "$skill_pkg" ]; then
	echo "SKIP: 没装中文技能包（https://github.com/devcxl/mattpocock-skills-zh）"
	exit 2
fi

# ---- GitHub 配额预检 ----
# e2e 每轮要拉两次 issue（打开面板一次 + 刷新用例一次），走的是 GraphQL。
# 实测一次 `gh issue list --json`（含 9 张票的正文）约耗 395 点，一轮约 800 点。
# 配额烧光时 gh 返回 rate limit 错误，任务板列表是空的 —— 那是环境问题不是
# 产品缺陷。所以开跑前先看配额，不够就把任务板用例跳过，别把配额烧光
# 导致后面几轮全红。阈值留一轮的余量。
# 配额低时只提示，不强制跳过 ——
# 面板有上次拉到的数据缓存，限流时照样能验任务板界面。
# 真正跳过的判据是"任务板确实没有数据"，由用例脚本按渲染结果判断。
quota="$("$gh_bin" api rate_limit --jq '.resources.graphql.remaining' 2>/dev/null || echo "")"
if [ -n "$quota" ] && [ "$quota" -lt 1200 ] 2>/dev/null; then
	echo "e2e: GitHub GraphQL 配额只剩 $quota（本轮约需 800 点），任务板可能退到缓存数据"
fi

# ---- 参数 ----
keep=0
launch=0
port=""
while [ $# -gt 0 ]; do
	case "$1" in
	--keep) keep=1; shift ;;
	--launch) launch=1; shift ;;
	--port) port="$2"; shift 2 ;;
	*) echo "unknown option: $1" >&2; exit 2 ;;
	esac
done

# ---- 找控制端点 ----
# 默认不自己起 tern：一个窗口就是一份 GPU 与内存开销，连跑几轮会把机器拖垮。
# 先接已开的受控窗口：--port、上次记下的端口、17311 起的五个端口。
portfile="$here/.e2e.port"
pidfile="$here/.e2e.pid"
log="$here/.e2e.log"
: > "$log"
repo_win="$(cygpath -w "$repo" 2>/dev/null || echo "$repo")"

probe() { "$tern_bin" ctl --control "$1" state >/dev/null 2>&1; }

found=""
for cand in $port $(cat "$portfile" 2>/dev/null || true) 17311 17312 17313 17314 17315; do
	if [ -n "$cand" ] && probe "$cand"; then
		found="$cand"
		break
	fi
done

owned=0
tern_pid=""
if [ -n "$found" ]; then
	port="$found"
	echo "e2e: 接上已开的窗口（控制端口 $port）"
elif [ "$launch" -eq 1 ]; then
	port="${port:-17311}"
	# 端口占用则顺延
	while netstat -ano 2>/dev/null | tr -d '\r' | awk -v p=":$port" '$0 ~ p && /LISTENING/ {found=1} END {exit found?0:1}'; do
		port=$((port + 1))
	done
	"$tern_bin" --control "$port" --dir "$repo_win" > "$log" 2>&1 &
	tern_pid=$!
	owned=1
	echo "$tern_pid" > "$pidfile"
	echo "$port" > "$portfile"
	echo "e2e: 起了窗口（控制端口 $port）"
else
	cat >&2 <<EOF
SKIP: 没有可接的受控 tern 窗口（只有 --launch 才自己起）。
  先在 Tern 里手动开一个受控窗口：
    "$tern_bin" --control 17311 --dir "$repo_win"
  再跑本脚本；端口不是 17311 就用 --port 指定。
EOF
	exit 2
fi

cases_pid=""
cleanup() {
	# 子脚本（用例）也要杀 —— 它自己会循环调 ctl，留着就是孤儿进程，
	# 下次再跑 e2e 就叠一层，窗口越堆越多。
	if [ -n "$cases_pid" ]; then
		kill "$cases_pid" 2>/dev/null || true
		wait "$cases_pid" 2>/dev/null || true
	fi
	if [ "$keep" -eq 0 ] && [ "$owned" -eq 1 ]; then
		# 先走优雅退出：只有窗口正常关闭 daemon 才记账。
		# 直接 kill 会被记成「未关闭会话」，下次 tern 启动全部恢复 ——
		# 跑几次 e2e 就攒出一堆窗口，把 GPU 和内存拖垮。
		"$tern_bin" ctl --control "$port" quit >/dev/null 2>&1 || true
		for _ in $(seq 1 20); do
			if [ -z "$tern_pid" ] || ! kill -0 "$tern_pid" 2>/dev/null; then
				break
			fi
			sleep 0.25
		done
		# 优雅退出没生效才硬杀兜底。
		if [ -n "$tern_pid" ]; then
			kill "$tern_pid" 2>/dev/null || true
			wait "$tern_pid" 2>/dev/null || true
		fi
	fi
	rm -f "$log" "$pidfile" "$portfile"
}
# INT/TERM 必须一起 trap：`timeout 200 bash test/e2e.sh` 发的是 TERM，
# 只 trap EXIT 的话窗口和用例进程都会变成孤儿。
trap cleanup EXIT INT TERM HUP

# 等控制端点就绪
ready=0
for _ in $(seq 1 60); do
	if "$tern_bin" ctl --control "$port" state >/dev/null 2>&1; then
		ready=1
		break
	fi
	sleep 0.5
done
if [ "$ready" -eq 0 ]; then
	echo "FAIL: tern 控制端点没起来（端口 $port）"
	tail -20 "$log" >&2 || true
	exit 1
fi

echo "e2e: 窗口已起，控制端口 $port"

# ---- 跑用例 ----
cases="$here/e2e-cases.sh"
if [ ! -f "$cases" ]; then
	echo "FAIL: 缺用例脚本 $cases"
	exit 1
fi

TERNS_E2E_PORT="$port" \
	TERNS_E2E_REPO="$repo" \
	TERNS_E2E_REPO_WIN="$repo_win" \
	TERNS_E2E_SKILL_PKG="$skill_pkg" \
	TERNS_BIN="$tern_bin" \
	GH_BIN="$gh_bin" \
	bash "$cases" &
cases_pid=$!
cases_rc=0
wait "$cases_pid" || cases_rc=$?
cases_pid=""

echo "e2e: 全部用例结束"
exit "$cases_rc"
