#!/usr/bin/env bash
# 真机端到端测试：起一个受控 tern 窗口，驱动插件交互，读回渲染树做断言。
#
#   test/e2e.sh [选项]
#
# 选项：
#   --keep        跑完不关窗口（默认跑完关掉）
#   --port N      控制端口（默认 17311，被占用则自动 +1）
#
# 依赖：tern（能起 --control 窗口）、gh（已登录）、本机已装中文技能包。
# 缺任一项 → 该用例记为 SKIP 并说明原因，不算失败。
set -eu

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
		exit 0
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
	exit 0
fi

gh_bin="$(resolve_tool gh \
	"/c/Program Files/GitHub CLI/gh.exe" \
	"/c/Program Files (x86)/GitHub CLI/gh.exe" || true)"
if [ -z "$gh_bin" ]; then
	echo "SKIP: 找不到 gh"
	exit 0
fi

if ! "$gh_bin" auth status >/dev/null 2>&1; then
	echo "SKIP: gh 未登录"
	exit 0
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
	exit 0
fi

# ---- 参数 ----
keep=0
port=17311
while [ $# -gt 0 ]; do
	case "$1" in
	--keep) keep=1; shift ;;
	--port) port="$2"; shift 2 ;;
	*) echo "unknown option: $1" >&2; exit 2 ;;
	esac
done

# ---- 起窗口 ----
log="$here/.e2e.log"
: > "$log"

# 端口占用则顺延
while netstat -ano 2>/dev/null | tr -d '\r' | awk -v p=":$port" '$0 ~ p && /LISTENING/ {found=1} END {exit found?0:1}'; do
	port=$((port + 1))
done

# --dir 要 Windows 路径（Windows 的 exe 不认 /d/...）
repo_win="$(cygpath -w "$repo" 2>/dev/null || echo "$repo")"

"$tern_bin" --control "$port" --dir "$repo_win" > "$log" 2>&1 &
tern_pid=$!
cleanup() {
	if [ "$keep" -eq 0 ]; then
		kill "$tern_pid" 2>/dev/null || true
		wait "$tern_pid" 2>/dev/null || true
	fi
	rm -f "$log"
}
trap cleanup EXIT

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
	bash "$cases"

echo "e2e: 全部用例结束"
