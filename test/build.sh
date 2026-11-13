#!/usr/bin/env bash
# 跑 test/run_tests.luau：把桩、lib/、host.luau、window.luau 和断言拼成一个脚本，
# 再交给 luau CLI。luau 的 require 在独立沙箱里跑，桩进不去，所以只能拼接。
#
#   test/build.sh [path-to-luau]
#
# luau 依次取 $1、$TERNS_LUAU、PATH 上的 luau。
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
repo="$(dirname "$here")"
runner="$here/run_tests.luau"
# 拼接结果放在仓库里：Windows 的 luau.exe 读不了 WSL 的 /tmp。
# 拼好的 bundle 放插件目录外：插件目录里任何文件变动都会触发 Tern 热重载，
# 而热重载会把正在跑的「问下一步」打断。放临时目录就彻底躲开这个副作用。
# 放仓库的上一级：既在插件目录之外（不触发热重载），又和仓库同一磁盘，
# 不会被 WSL 与 Windows 的 /tmp 路径差异绊住。
out="$(cd "$here/../.." && pwd)/.tern-matt-panel.bundle.luau"
trap 'rm -f "$out"' EXIT

# 拼接会把所有模块先定义好，于是「host 里忘了 require 某个模块」这种错
# 在单测里永远抓不到 —— 真机才炸（await failed / runtime error）。
# 所以先静态查一遍：代码里用到的 lib 模块，宿主/窗口文件必须自己 require。
# 顺序有依赖：被依赖的放前面（require 行会被剥掉，后声明的 local 在前文是 nil）。
mods="util paths packs skills lanes tracker backend localtracker templates commands"
have="$(ls lib/*.luau 2>/dev/null | sed 's#.*/##; s#\.luau$##' | sort | tr '\n' ' ')"
want="$(printf '%s\n' $mods | sort | tr '\n' ' ')"
if [ "$have" != "$want" ]; then
	echo "模块清单与 lib/ 不一致：新增模块要加进上面的 mods（注意依赖顺序）。" >&2
	echo "  lib/: $have" >&2
	echo "  清单: $want" >&2
	exit 1
fi

for src in host.luau window.luau; do
	for mod in $mods; do
		if grep -qE "(^|[^%w_.])${mod}\." "$repo/$src" 2>/dev/null \
			&& ! grep -qE "require\(\"\./lib/${mod}\"\)" "$repo/$src"; then
			echo "$src: 用了 ${mod}. 但没有 require(\"./lib/${mod}\")" >&2
			exit 1
		fi
	done
done

luau="${1:-${TERNS_LUAU:-}}"
if [[ -z "$luau" ]]; then
	if command -v luau >/dev/null 2>&1; then
		luau="$(command -v luau)"
	else
		echo "no luau CLI: pass one as \$1 or set \$TERNS_LUAU" >&2
		echo "  download: https://github.com/luau-lang/luau/releases" >&2
		exit 1
	fi
fi

# WSL 里 "C:/…" 不是有效路径，换成 /mnt/c/…。
case "$luau" in
[A-Za-z]:[\\/]*)
	if command -v wslpath >/dev/null 2>&1; then
		luau="$(wslpath -u "$luau")"
	fi
	;;
esac

# 未定义全局：写错作用域（把别处的局部变量当全局用）只有 luau-analyze 抓得到，
# 真机上表现为 "attempt to call a nil value"，定位代价极高。实测漏过一个
# `git -C cwd`（cwd 只存在于别的函数里）。
# 只查 Unknown global 这一类并排除 tern：存量类型告警上百条，混进来就没人看了。
# 分析器必须从 luau 同目录找 —— 它不在 PATH 上；找不到就大声说出来，别静默跳过。
analyze=""
for cand in "$(dirname "$luau")/luau-analyze" "$(dirname "$luau")/luau-analyze.exe" \
	"$(dirname "$luau")/luau-analyze"; do
	if [ -f "$cand" ] || [ -x "$cand" ]; then
		analyze="$cand"
		break
	fi
done
if [ -z "$analyze" ]; then
	echo "未定义全局检查无法执行：$(dirname "$luau") 下没有 luau-analyze（同 luau releases）" >&2
	exit 1
else
	bad="$(cd "$repo" && "$analyze" --formatter=plain host.luau window.luau 2>&1 \
		| grep "Unknown global" | grep -v "'tern'" || true)"
	if [ -n "$bad" ]; then
		echo "未定义全局（不是 tern API，是真 bug）：" >&2
		echo "$bad" >&2
		exit 1
	fi
fi


python_cmd="$(command -v python3 || command -v python)"
"$python_cmd" - "$runner" "$repo" "$out" "$mods" <<'PY'
import io
import os
import re
import sys

runner_path, repo, out_path, mods_arg = sys.argv[1:5]
MARKER = "-- ==== MODULES ===="
REQUIRE = re.compile(r'^local \w+ = require\("\./(lib/)?\w+"\)\n', re.M)
# 与 bash 侧同一份清单：由 lib/ 目录推导，不用手改两处。
MODULES = mods_arg.split()


def source(path):
	with io.open(path, encoding="utf-8") as fh:
		text = fh.read()
	if text.startswith("--!strict\n"):
		text = text[len("--!strict\n"):]
	return REQUIRE.sub("", text)


with io.open(runner_path, encoding="utf-8") as fh:
	runner = fh.read()
head, tail = runner.split(MARKER, 1)

parts = [head]
for name in MODULES:
	body = source(os.path.join(repo, "lib", name + ".luau"))
	parts.append("local %s = (function()\n%s\nend)()\n" % (name, body))
for name in ("host", "window"):
	body = source(os.path.join(repo, name + ".luau"))
	parts.append("do -- %s.luau\n%s\nend\n" % (name, body))
parts.append(tail)

os.makedirs(os.path.dirname(out_path), exist_ok=True)
with io.open(out_path, "w", encoding="utf-8", newline="\n") as fh:
	fh.write("".join(parts))
print(out_path)
PY

# Windows 的 luau.exe 读不了 WSL 的 /tmp，换成它认得的路径。
if [[ "$luau" == *.exe ]] && command -v wslpath >/dev/null 2>&1; then
	out="$(wslpath -w "$out")"
fi

"$luau" "$out"