# 开发与真机验证

改动后的门禁与真机入口。命令都在仓库根执行。

## 单测与静态检查

必须用 Git Bash。本机裸 `bash` 首项解析到 `C:\WINDOWS\system32\bash.exe`（WSL），看不到 `/c/...` 路径，会报「没有 luau-analyze」这类假警报；两个脚本已内置守卫，会以退出码 2 拦下并打印下面的命令。

```bash
"/c/Program Files/Git/bin/bash.exe" test/build.sh /c/tools/luau/luau.exe
# 全量（含 e2e）：
"/c/Program Files/Git/bin/bash.exe" test/all.sh --unit-only
```

`test/build.sh` 会拼接模块、跑 luau CLI，并用 `luau-analyze` 查 `Unknown global`。模块清单在脚本里定义一次、顺序即依赖（`util` 必须最前）；与 `lib/*.luau` 对不上会直接失败。CI 同一入口见 `.github/workflows/check.yml`。

## 真机 e2e（attach-only）

只接已经开着的受控窗口，e2e 不自己起窗。先由人手动开**一个**：

```bash
cd /d/26code/tern-matt-panel   # cmd; PowerShell 用 cd D:\...
tern --control 17311 .
```

`--dir` 在复用已有 session 时可能落不到目标目录；用位置参数 `.`。开完确认窗口 cwd：

```bash
tern inspect
```

看到该 tab 的 cwd 就是仓库根才继续。另开一个终端：

```bash
bash test/e2e.sh --port 17311
# 或让脚本自己探 17311–17315：
bash test/all.sh --e2e-only
```

测完关掉自己开的那个窗口：

```bash
tern ctl --control 17311 quit
```

不要用 `--launch`，不要重复起窗；Tern 窗口一份就是一份 GPU/内存开销。

## 面板定位与点击

```bash
tern ctl --control 17311 tree '.sf-button'   # 只看按钮及坐标
tern ctl --control 17311 pick X Y            # 先确认坐标命中的元素
```

`ctl` 的 `--control` 指向窗口端点；如果 shell 本身在 Tern 面板里，命令可能落到当前窗口。优先用 `test/e2e.sh`，不要手动读 `daemon.state` 或日志找端口。

## 需要大量已关票时

当前仓库票少时「加载更多」不会出现。用临时目录挂一个票多的 remote：

```bash
mkdir -p D:/26code/wt/pager-fixture
cd D:/26code/wt/pager-fixture
git init
git remote add origin https://github.com/FeatherHunter/dsh-mattpocock-skills-deck.git
tern --control 17312 .
```

任务板 → 展开「已关闭」→ 点「加载更多（已 N 条）」。测完 `tern ctl --control 17312 quit` 并删临时目录。

## 审 diff（评审 agent）

评审只给两样东西：`git diff main...HEAD` 与规格全文（`gh issue view <规格号>`），并要求 400 字以内的 `文件:行: 严重度: 一句话问题 + 修法`。不要让评审者自己去读未改动的 1900 行文件；实测两个评审子代理各自跑到 30 分钟无输出，成本远高于收益。
