#!/usr/bin/env bash
# 跑 test/run_tests.luau：把桩、lib/、host.luau、window.luau 和断言拼成一个脚本，
# 再交给 luau CLI。luau 的 require 在独立沙箱里跑，桩进不去，所以只能拼接。
#
#   test/build.sh [path-to-luau]
#
# luau 依次取 $1、$TERNS_LUAU、PATH 上的 luau。
set -eu

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(dirname "$here")"
runner="$here/run_tests.luau"
# 拼接结果放在仓库里：Windows 的 luau.exe 读不了 WSL 的 /tmp。
out="$here/.bundle.luau"
trap 'rm -f "$out"' EXIT

# 拼接会把所有模块先定义好，于是「host 里忘了 require 某个模块」这种错
# 在单测里永远抓不到 —— 真机才炸（await failed / runtime error）。
# 所以先静态查一遍：代码里用到的 lib 模块，宿主/窗口文件必须自己 require。
for src in host.luau window.luau; do
	for mod in util paths skills lanes tracker templates commands; do
		if grep -qE "(^|[^%w_.])${mod}\." "$repo/$src" 2>/dev/null \
			&& ! grep -qE "require\(\"\./lib/${mod}\"\)" "$repo/$src"; then
			echo "$src: 用了 ${mod}. 但没有 require(\"./lib/${mod}\")" >&2
			exit 1
		fi
	done
done

# 未定义全局：写错作用域（用了别处的局部变量）只有 luau-analyze 抓得到，
# 真机上表现为 "attempt to call a nil value"，定位代价极高。
# 只查这一类，不管类型告警 —— 存量类型告警太多，混在一起就没人看了。
analyze="$(command -v luau-analyze || dirname "${1:-${TERNS_LUAU:-}}" 2>/dev/null)/luau-analyze.exe"
if [ -x "$analyze" ] || [ -f "$analyze" ]; then
	if bad="$(cd "$repo" && "$analyze" --formatter=plain host.luau window.luau 2>&1 \
		| grep "Unknown global" | grep -v "'tern'")"; then
		if [ -n "$bad" ]; then
			echo "未定义全局（不是 tern API，是真 bug）：" >&2
			echo "$bad" >&2
			exit 1
		fi
	fi
fi

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

python_cmd="$(command -v python3 || command -v python)"
"$python_cmd" - "$runner" "$repo" "$out" <<'PY'
import io
import os
import re
import sys

runner_path, repo, out_path = sys.argv[1:4]
MARKER = "-- ==== MODULES ===="
REQUIRE = re.compile(r'^local \w+ = require\("\./(lib/)?\w+"\)\n', re.M)
MODULES = ["util", "paths", "skills", "lanes", "tracker", "templates", "commands"]


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

with io.open(out_path, "w", encoding="utf-8", newline="\n") as fh:
	fh.write("".join(parts))
print(out_path)
PY

# Windows 的 luau.exe 读不了 WSL 的 /tmp，换成它认得的路径。
if [[ "$luau" == *.exe ]] && command -v wslpath >/dev/null 2>&1; then
	out="$(wslpath -w "$out")"
fi

"$luau" "$out"