# 宿主半边 timer / process 实测复核（issue #8）

- 对象：本机 tern **0.9.11**（`tern --version` → `tern 0.9.11 (f93bb18)`），Windows。
- 方法：造一个一次性探针插件（`D:/26code/_wt/probe-plugin`，用完已删），插件**加载即**在宿主半边跑全部探针，把结果追加写进 `D:/26code/_wt/probe-report.txt`；`tern serve --control 17892` 起 headless 会话（只跑宿主半边），15 秒后读报告。
- 探针不声明 `[[blocks]]`（避免 block 未 define 导致插件整体 load 失败）。

## 一、结论

| 问题 | 结论 |
| --- | --- |
| 宿主半边 `tern.timer` 回调会触发吗 | **会**。500ms 自续链连打 6 tick，间隔 ~500ms，块未 `exited 1` |
| `tern.process.run` 三形态 | **全通**：`cb` 形、`opts+cb` 形、无 cb 返回 awaitable（userdata）后 `:next(cb)` —— 三者都拿到 `status=0` 与 stdout |
| 宿主半边 `tern.fs` / `tern.kv` / `tern.getenv` | **全可用**（`fs.exists`/`fs.read`/`fs.list`、`kv.set`/`kv.get`、`getenv` 都有返回值） |
| 面板的"拉数据 + 刷新"能放宿主半边吗 | **能**。宿主半边具备 timer / 子进程 / 文件 / KV / 环境变量，可独立完成轮询与渲染，**不必**把数据获取挪到窗口半边 |

## 二、实测输出（去重后的关键行）

```
HOST_LOAD now=51081.5148
HOST_TIMER_SCHEDULED ok
PROC_C_returned type=userdata
FS_exists=true
FS_read_len=5260 head={
  "version": 1,
  "marketplaces": [
FS_list_count=16 first=addy-agent-skills
KV_get=table: 0x000001bf18bb3a00
GETENV_USERPROFILE=C:\Users\22923
GETENV_HOME=nil
HOST_SYNC_DONE now=51133.212
PROC_A_cb status=0 stdout=probeA
PROC_B_opts_cb status=0 stdout=probeB
PROC_C_next status=0 stdout=probeC
HOST_TIMER_TICK_1 now=51583.294700000006
HOST_TIMER_TICK_2 now=52089.885
HOST_TIMER_TICK_3 now=52599.6661
HOST_TIMER_TICK_4 now=53104.8862
HOST_TIMER_TICK_5 now=53611.9617
HOST_TIMER_TICK_6 now=54122.9551
```

窗口半边（同一插件的 `window.luau`，`tern serve` 下也会加载）：

```
WINDOW_LOAD now=205090.1244
WINDOW_FS_exists=true
WINDOW_GETENV_USERPROFILE=C:\Users\22923
WINDOW_PROC_cb status=0 stdout=probeW
WINDOW_TIMER_TICK_1 now=205604.5162
WINDOW_TIMER_TICK_2 now=206106.2923
WINDOW_TIMER_TICK_3 now=206609.3891
WINDOW_TIMER_TICK_4 now=207114.1527
```

要点：

- 宿主半边 timer tick 的时间戳间隔稳定在 ~500ms（51583 → 52089 → 52599 → 53104 → 53611 → 54122），说明回调**按预期周期触发**，不是偶然。
- `PROC_C_returned type=userdata`：无 cb 形态返回的是 awaitable 句柄，不是结果表；必须 `:next(cb)` 才能拿到 `status`。
- `GETENV_HOME=nil`（Windows 无 `HOME`），`GETENV_USERPROFILE=C:\Users\22923` 可用 —— 取 home 必须用 `USERPROFILE`。
- `FS_read_len=5260` 读的是 `C:/Users/22923/.omp/marketplaces.json`，**跨出插件目录读绝对路径成立**；`FS_list_count=16` 列出 `C:/Users/22923/.omp/plugins/cache/marketplaces` 的 16 个 marketplace 目录，**读 omp 插件缓存目录可行**。
- `KV_get=table: 0x...`：`tern.kv` 存的是引用（table），跨 VM 读取是否拿到副本未在本次探针覆盖。

## 三、与既有记录的矛盾及解释

本机 skill 记录（`skill://tern-plugin-panel-bridge`、`skill://tern-block-state-lifecycle`，记录于 tern 0.9.9）称"**宿主半边不能用 `tern.timer`：回调不触发，块直接 `exited 1`**"，并把 `tern.kv` 说成宿主与窗口之间"唯一的通道"。

**本次实测与之相反**：宿主半边 timer 正常触发、process 三形态正常、fs/kv/getenv 正常。

对第一次探针失败（block 探针）的解释：那次探针在 `plugin.toml` 里声明了 `[[blocks]] id = "probe"`，但 `host.luau` 在重写后**没有** `tern.block.define("probe", ...)`，插件加载直接失败：

```
probe-host 0.1.0 Probe Host — 1 blocks, 0 lenses, window  failed: block probe is declared in plugin.toml but not defined with tern.block.define
```

插件整体 load 失败 → 宿主半边脚本根本没跑 → 看不到 timer 回调 → 被误读成"宿主半边 timer 不工作"。**旧结论的成因是探针自身写错，不是平台限制。**

类型定义（`D:/26code/tern-prompt-panel/tern.d.luau`）本来就说对了：`tern.timer`(:2070)、`tern.process.run`(:2117)、`tern.fs`(:2097)、`tern.kv`(:2080)、`tern.getenv`(:2067) **没有** `host only` / `window only` 标记；按文件头 :4 的约定，无标记即两端都有。

## 四、仍然成立的部分

- `cx.agents:ask`（:781）、`cx.chrome.status`（:2266 `tern.chrome.status`）、`tern.command`（:2247）确为 window-only：宿主半边拿不到 agent 与调色板。
- `tern.ui` 没有文本框 builder，编辑仍需 `ui.node("input"/"editor")` 手搓。

## 五、留给实现的取舍

宿主半边可独立跑 timer + `gh` 子进程 + 读文件，因此"任务板拉数据"可以放在宿主半边，不必绕 kv 到窗口半边。但：

- 宿主半边单次调用预算 2s Lua、墙钟最多十个 budget（`tern.d.luau:6-13`）；`gh` 一次网络往返可能超预算，需要放 timer 回调里异步做，而不是塞进 `view`。
- 面板要"注入到邻近 agent"仍必须走窗口半边（`cx.agents:ask` 是 window-only），这条 kv 桥接省不掉。
