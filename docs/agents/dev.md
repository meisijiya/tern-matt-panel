# 开发与真机验证

改动后的门禁与真机入口。命令都在仓库根执行。

## 代码在哪

不写行号（会过期），按职责找：

| 位置 | 职责 |
| --- | --- |
| `host.luau` `loadBoard` | 判后端（约定文件 → 识别）+ 取数：GitHub 走 gh，本地走 `localtracker.scan` |
| `host.luau` `boardView` / `mapView` / `ticketView` | 三个视图的渲染；`packsView` / `skillsView` 同理 |
| `host.luau` `event` | 所有鼠标点击（`act:` 前缀是票动作、`open-doc` 是文档视图） |
| `host.luau` `key` | 所有键盘快捷键 |
| `host.luau` `inject` / `readResult` | 往 kv 写注入请求、读窗口半边的回执 |
| `window.luau` `handleAction` | 窗口半边执行 kv 里的请求（inject / compose / open-doc / pick-repo） |
| `lib/tracker.luau` | 归一化结构与四组分类、前沿、规格归组 |
| `lib/localtracker.luau` | 本地 markdown 后端的扫描与解析（唯一读 `.scratch` 的地方） |
| `lib/templates.luau` | 注入模板；后端差异在 `backendVars` 的占位取值里 |

## 单测与静态检查

必须用 Git Bash。本机裸 `bash` 首项解析到 `C:\WINDOWS\system32\bash.exe`（WSL），看不到 `/c/...` 路径，会报「没有 luau-analyze」这类假警报；两个脚本已内置守卫，会以退出码 2 拦下并打印下面的命令。

```bash
"/c/Program Files/Git/bin/bash.exe" test/build.sh /c/tools/luau/luau.exe
# 全量（含 e2e）：
"/c/Program Files/Git/bin/bash.exe" test/all.sh --unit-only
```

`test/build.sh` 会 `bash -n` 过一遍 `test/*.sh`、拼接模块、跑 luau CLI，并用 `luau-analyze` 查 `Unknown global`。模块清单在脚本里定义一次、顺序即依赖（`util` 必须最前）；与 `lib/*.luau` 对不上会直接失败。CI 同一入口见 `.github/workflows/check.yml`。

## 真机 e2e（attach-only）

只接已经开着的受控窗口，e2e 不自己起窗。先由人手动开**一个**：

```bash
cd /d/26code/tern-matt-panel   # cmd; PowerShell 用 cd D:\...
tern --control 17311 .
```

`--dir` 在复用已有 session 时可能落不到目标目录；用位置参数 `.`。

要验本地 markdown 后端时，工作目录换成夹具仓库。三条实测过的坑：

- **`tern shot` / `tern serve` 不加载插件**：palette 里搜不到「Matt 面板」，别用它们验面板。
- **`tern --control N --dir DIR` 会挂到已有 daemon**：显示的是你原有的所有 tab，`--dir` 不保证成为活动 tab。
- **用例点在活动 tab 上**：先在目标目录里 `tern --control N .`，再核活动 tab 的 cwd；不对就 `tern new tab --cwd DIR` 然后 `tab <序号>` 切过去。

开完确认窗口 cwd：

```bash
tern inspect
```

看到该 tab 的 cwd 就是仓库根才继续。另开一个终端（Git Bash，同上；裸 `bash` 会被守卫以退出码 2 拦下）：

```bash
"/c/Program Files/Git/bin/bash.exe" test/e2e.sh --port 17311
# 或让脚本自己探 17311–17315：
"/c/Program Files/Git/bin/bash.exe" test/all.sh --e2e-only
```

测完关掉自己开的那个窗口：

```bash
tern ctl --control 17311 quit
```

不要用 `--launch`，不要重复起窗；Tern 窗口一份就是一份 GPU/内存开销。

## 本地 markdown 后端的 e2e

本仓自己是 GitHub 模式，所以本地后端只能在夹具仓库上验。夹具是带 `.scratch/` 的临时目录，不联网、不调 `gh`。同样是 attach-only：先由人在夹具目录里开窗口。

```bash
mkdir -p D:/26code/wt/local-fixture && cd D:/26code/wt/local-fixture
git init
tern --control 17312 .        # 窗口 cwd 必须是夹具根
```

`test/e2e-local.sh` 会补齐夹具内容（`.scratch/alpha`、`.scratch/beta` 与约定文件；缺目录或缺 git 仓时自己建），核对窗口 cwd 后跑用例；cwd 不对就 SKIP 退出码 2，绝不自起窗口。

```bash
"/c/Program Files/Git/bin/bash.exe" test/e2e-local.sh --port 17312
# 或只跑这一层：
"/c/Program Files/Git/bin/bash.exe" test/all.sh --e2e-local
```

注入正文的断言读插件 kv（`%LOCALAPPDATA%\Tern\plugin-data\tern-matt-panel\kv.json` 的 `action.body`），不读剪贴板。

跑完：

```bash
tern ctl --control 17312 quit
rm -rf D:/26code/wt/local-fixture
```

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

## 注入无响应时

面板提示停在「填入中」，几秒后变成「窗口半边没响应」= 插件的窗口半边没起来。最常见的原因是改源码时热重载读到了半成品（日志里出现 `plugin window entry failed to load ... lib/templates.luau:NN`），此后不自动恢复。

```bash
tern plugin reload     # 重载插件
```

reload 会丢掉已开的面板，重开后点一次按钮确认提示变成「已填入」。改插件源码时优先写临时文件再原子 rename，避免截断写被热重载读到。
