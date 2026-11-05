# 宿主半边异步回填与重渲染实测（issue #11 的前置取证）

- 对象：本机 tern **0.9.11**（`tern --version` → `tern 0.9.11 (f93bb18)`），Windows。
- 方法：一次性探针插件（用完已删），`host.luau` 注册一个块 `probe2`；`init` 里用 `tern.process.run` 起一个子进程，在回调里做三件事并写报告；窗口半边起来 1 秒后自动 `cx:new_block` 开块；真 GUI 窗口 `tern --control 17903`。

## 一、结论

| 问题 | 结论 |
| --- | --- |
| 宿主半边异步回调里改 `init` 返回的 state 表，`view` 能看到吗 | **能**。`s.counter` 从 0 变 100，view 立刻读到 |
| 回调里 `cx:render()` 生效吗 | **生效**，view 随之重画 |
| 回调里 `cx:save()` 生效吗 | **生效**，无异常 |

**推论**：面板在宿主半边拉数据（`gh` 子进程）后，可以直接把结果写进 state 并 `cx:render()` 重画，**不需要绕 `tern.kv` 中转**。kv 桥接只在"宿主半边 → 窗口半边"（注入 agent、命令、状态栏）时必需。

### 实测输出（原文）

```
WINDOW_LOAD now=159134.70609999998
WINDOW_OPEN_BLOCK now=160166.27260000003
INIT now=2902392.3384 cx=BlockCx: 0x000001bf184b2990
VIEW s.counter=0 mod.hits=0 now=2902408.7304
CB_FIRED status=0 stdout=asyncdata

CB state.counter=100 mod.hits=1
CB cx:render() ok
CB cx:save() ok
VIEW s.counter=100 mod.hits=1 now=2902465.0788
```

要点：回调触发后，紧接着一次 `VIEW` 读到 `s.counter=100` —— **state 的跨异步边界修改可见**，且 `cx:render()` 触发了重画（VIEW 被调用）。

## 二、订正两条旧记录

本机 skill `skill://tern-block-state-lifecycle` 记着：

- "宿主半边不能用 `tern.timer`：回调不触发，块直接 `exited 1`" —— **误判**，见已关闭的 issue #8（成因是探针自身写错导致插件 load 失败）。
- "`init` 返回的 state table 会被 Tern 复制走"，"唯一能通的通道是 `tern.kv`" —— **在 0.9.11 上不成立**。本次实测证明回调里改 state 会被 view 读到。

两条 managed skill 已据此订正。

## 三、对实现的影响

面板架构据此定：

- **宿主半边**：`init` 拉数据 → state 存 → `view` 渲染。异步拉取（`gh`）的回调里写 state + `cx:render()`。
- **窗口半边**：命令、状态栏胶囊、以及"注入邻近 agent"（`cx.agents:ask` 是 window-only）。宿主发指令 → 写 `tern.kv` → 窗口轮询 → 执行 → 写结果 kv → 宿主读结果 toast。
- **kv 只承载"跨半边指令与结果"，不承载面板数据**。

## 四、未覆盖

- 未测"回调里改 state 后 `save` 再重启块"的状态持久化路径（`cx:save()` 调用成功，但未验证重启后的恢复值）。
- 未测窗口半边 `cx.agents:ask` 的真实投递（需要旁边有活着的 omp agent）；该路径沿用 tern-prompt-panel 已上线的实现。
