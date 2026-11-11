#!/usr/bin/env bash
# 一把跑全套门禁：单元测试（luau CLI）+ 真机 e2e（GUI）。
#
#   test/all.sh [选项]
#
# 选项：
#   --unit-only   只跑单元测试
#   --e2e-only    只跑 e2e
#   --keep        e2e 跑完不关窗口
#
# 依赖：luau CLI、tern（能起 --control 窗口）、gh（已登录）、本机已装中文技能包。
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
# 转发给 Git Bash 的那份参数：解析会 shift 掉 $@，先留一份。
forward=("$@")

run_unit=1
run_e2e=1
keep=""
while [ $# -gt 0 ]; do
	case "$1" in
	--unit-only) run_e2e=0 ;;
	--e2e-only) run_unit=0 ;;
	--keep) keep="--keep" ;;
	*) echo "unknown option: $1" >&2; exit 2 ;;
	esac
	shift
done

# ---- 环境归位：Windows 上 bash 可能是 WSL，Windows 的 .exe 在 WSL 里跑不了 ----
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
		echo "need Git Bash to run Windows .exe tools" >&2
		exit 1
	fi
	here_git="$(cd "$here" && pwd)"
	case "$here_git" in
	/mnt/[a-z]/*) here_git="/${here_git#/mnt/}" ;;
	esac
	args=""
	for a in "${forward[@]}"; do
		args="$args $(printf '%q' "$a")"
	done
	exec "$gitbash" -lc "cd '$here_git/..' && bash test/all.sh$args"
fi

resolve_tool() {
	local name="$1"
	shift
	if command -v "$name" >/dev/null 2>&1; then
		command -v "$name"
		return 0
	fi
	for p in "$@"; do
		if [ -f "$p" ]; then
			echo "$p"
			return 0
		fi
	done
	return 1
}

fail=0
envfail=0

if [ "$run_unit" -eq 1 ]; then
	luau="$(resolve_tool luau "/c/tools/luau/luau.exe" || true)"
	if [ -z "$luau" ]; then
		echo "unit: SKIP 找不到 luau CLI" >&2
		envfail=1
	else
		echo "== 单元测试 =="
		if bash "$here/build.sh" "$luau"; then
			echo "unit: PASS"
		else
			echo "unit: FAIL" >&2
			fail=1
		fi
	fi
fi

if [ "$run_e2e" -eq 1 ]; then
	echo "== 真机 e2e =="
	# set -e 下直接接 rc=$? 会让失败用例在半路把脚本带走，改成 ||。
	rc=0
	bash "$here/e2e.sh" $keep || rc=$?
	if [ "$rc" -eq 0 ]; then
		echo "e2e: PASS"
	elif [ "$rc" -eq 2 ]; then
		echo "e2e: 环境不可用（用例全被跳过）" >&2
		envfail=1
	else
		echo "e2e: FAIL" >&2
		fail=1
	fi
fi

if [ "$fail" -ne 0 ]; then
	echo "all: FAIL" >&2
	exit 1
fi
if [ "$envfail" -ne 0 ]; then
	echo "all: 环境不可用（有层没验到）" >&2
	exit 2
fi
echo "all: PASS"
exit 0
