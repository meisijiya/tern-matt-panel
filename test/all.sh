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

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
	for a in "$@"; do
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
	bash "$here/e2e.sh" $keep
	rc=$?
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
