#!/usr/bin/env bash
# 本地 markdown 后端的真机 e2e：接一个**已经开着**的受控窗口，窗口的 cwd 必须是
# 夹具仓库（带 .scratch/）。与 test/e2e.sh 一样是 attach-only —— 不自起窗口
# （本机 GPU 反复 device-lost，一个窗口就是一份显存与内存开销）。
#
#   test/e2e-local.sh [--port N] [--fixture DIR]
#
# 准备（人手动，一次性）：
#   mkdir -p D:/26code/wt/local-fixture && cd D:/26code/wt/local-fixture
#   git init && <脚本会自动生成 .scratch 与约定文件>
#   tern --control 17312 .          # 窗口 cwd 必须是夹具仓库根
#
# 跑完由人 `tern ctl --control 17312 quit` 关窗并删夹具目录。
# 窗口 cwd 不对时 SKIP（退出码 2），不去猜、不改别人的窗口。
#
# 依赖：tern（能连 --control 窗口）、本机已装中文技能包。全程不联网、不调 gh。
set -eu

case "${WSL_DISTRO_NAME:-}" in
"") ;;
*)
	echo "检测到 WSL（WSL_DISTRO_NAME=$WSL_DISTRO_NAME）：本脚本要在 Git Bash 下跑。" >&2
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
repo="$(cd "$here/.." && pwd)"

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

fixture="${TERNS_E2E_FIXTURE:-}"
port=""
while [ $# -gt 0 ]; do
	case "$1" in
	--port) port="$2"; shift 2 ;;
	--fixture) fixture="$2"; shift 2 ;;
	*) echo "unknown option: $1" >&2; exit 2 ;;
	esac
done
fixture="${fixture:-$repo/../wt/local-fixture}"
mkdir -p "$fixture"
fixture="$(cd "$fixture" && pwd)"
if [ ! -d "$fixture/.git" ]; then
	git -C "$fixture" init -q .
fi

# ---- 夹具内容：不联网、不依赖任何远程 ----
mkdir -p "$fixture/docs/agents" "$fixture/.scratch/alpha/issues" "$fixture/.scratch/beta/issues"
cat > "$fixture/docs/agents/issue-tracker.md" <<'EOF'
# Issue tracker: Local Markdown（本地 Markdown）

本仓库的 issue 和 spec 以 markdown 文件形式存放在 `.scratch/` 中。
EOF
cat > "$fixture/.scratch/alpha/map.md" <<'EOF'
## 目的地

把 A 这条线做完。

## 笔记

夹具仓库，笔记段不该出现在面板上。

## 已有决策

- 已定：先做第一张票

## 尚未明确

- 迷雾：第二张票的验收怎么定
EOF
cat > "$fixture/.scratch/alpha/spec.md" <<'EOF'
# 规格 A

目标：把 A 做完。验收：面板能看到这条线。
EOF
cat > "$fixture/.scratch/alpha/issues/01-first.md" <<'EOF'
# 01: 第一张票

**What to build:** 让面板看到第一张票。

**Blocked by:** None (can start immediately)

**Status:** resolved

**Type:** task

- [ ] 验收一
EOF
cat > "$fixture/.scratch/alpha/issues/02-second.md" <<'EOF'
# 02: 第二张票

**What to build:** 验证盘问动作注入的正文。

**Blocked by:** 01

**Status:** claimed

**Type:** grilling

- [ ] 验收二
EOF
cat > "$fixture/.scratch/beta/issues/01-other.md" <<'EOF'
# 01: 另一条线的第一张票

**What to build:** 证明同号票不互相覆盖。

**Blocked by:** None (can start immediately)

**Status:** ready-for-agent

**Type:** task

- [ ] 验收三
EOF

ctl() { timeout 10 "$tern_bin" ctl --control "$port" "$@"; }
probe() { "$tern_bin" ctl --control "$1" state >/dev/null 2>&1; }

if [ -z "$port" ]; then
	for cand in 17312 17311 17313 17314 17315; do
		if probe "$cand"; then
			port="$cand"
			break
		fi
	done
fi
if [ -z "$port" ] || ! probe "$port"; then
	cat >&2 <<EOF
SKIP: 没有可接的受控窗口。先手动开一个，窗口 cwd 必须是夹具仓库：
  cd "$fixture" && "$tern_bin" --control 17312 .
然后重跑本脚本。跑完 "$tern_bin" ctl --control 17312 quit。
EOF
	exit 2
fi

# ---- 核对窗口 cwd 就是夹具仓库：不符合就 SKIP，不去猜别人的窗口 ----
fixture_win="$(cygpath -w "$fixture" 2>/dev/null || echo "$fixture")"
inspected="$("$tern_bin" inspect 2>/dev/null || true)"
if [ -n "$inspected" ] && ! printf '%s' "$inspected" | grep -qF -- "$fixture_win" \
	&& ! printf '%s' "$inspected" | grep -qF -- "$fixture"; then
	echo "SKIP: 受控窗口 $port 的 cwd 不是夹具仓库（$fixture_win）；先在那里开窗口" >&2
	exit 2
fi

TERNS_E2E_PORT="$port" \
	TERNS_E2E_FIXTURE="$fixture" \
	TERNS_BIN="$tern_bin" \
	bash "$here/e2e-local-cases.sh"
