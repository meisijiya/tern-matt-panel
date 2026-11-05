# tern 侧能力边界与环境可用性取证

> 研究对象：Tern 插件平台的宿主半边（`host.luau`，守护进程侧）与窗口半边（`window.luau`，UI 侧）。
> 一手来源：
> - `D:/26code/tern-prompt-panel/tern.d.luau` —— `tern plugin types` 产出的类型定义（行号均指此文件）。
> - `D:/26code/tern-prompt-panel/` 的 `host.luau` / `window.luau` / `lib/*.luau` / `test/run_tests.luau` —— 一个**已落地运行**的 tern 面板插件（提示词库）。
> 环境事实来自本机命令输出。
>
> 分类约定：**做得到** / **做不得** / **需要绕路**。

---

## 0. 总原则（两端共享 vs 单侧独有）

- 上下文定义：`"host"` 在 `host.luau`，`"window"` 在 `window.luau`（tern.d.luau:15-16）。
- 预算：每次进入插件的调用，宿主半边可跑 2s Lua、窗口半边 50ms、chrome formatter 4ms；原生调用（`cx` API、`tern.fs`、`tern.kv`、启动进程、`require` 编译）不计入 Lua 预算，但单次调用墙钟最多十个 budget（tern.d.luau:6-13）。
- 类型注释里写 `host only` / `window only` / `Desktop window only` 的，就是该侧独有（tern.d.luau:4）。**没有**这些标记的 `tern.*` 表成员，两端都有。

---

## 1. tern.ui 可渲染原语清单

完整 builder 表位于 tern.d.luau:2133-2201（`declare tern: { … ui: { … } }`）。

### 1.1 返回 `Node` 的节点 builder

| builder | 签名（行） | 说明 |
|---|---|---|
| `ui.span` / `ui.link` / `ui.path` | :2135 / :2137 / :2139 | 返回 `Span`（带样式的文本 / 链接 / 文件链接），通常作为其它节点的子内容 |
| `ui.text` | :2141 | 文本节点，参数为 `Spans` |
| `ui.col` | :2143 | 垂直堆叠，子项间小间距 |
| `ui.lines` | :2145 | 单行文本流堆叠，无间距 |
| `ui.row` | :2147 | 水平排列，子项间小间距 |
| `ui.card` | :2149 | 带标题卡片（`CardProps`：icon/meta/end + 通用 prop） |
| `ui.section` | :2151 | 轻量折叠组 |
| `ui.rule` | :2153 | 分隔线（可带标签） |
| `ui.badge` | :2155 | 胶囊徽标 |
| `ui.button` | :2157 | 按钮（`ButtonProps`：icon/keys/variant/size/on/disabled/busy） |
| `ui.stats` | :2159 | 统计磁贴一行 |
| `ui.kv` | :2161 | 对齐的键值列表 |
| `ui.table` | :2163 | 表格（`Col[]` + `Cell[]|TableRow[]` + `TableOpts`）；单元格可为 Spans/TextCell/BadgeCell/ButtonCell/MeterCell/SparkCell |
| `ui.tree` | :2169 | 折叠树（`TreeNode[]`） |
| `ui.list` | :2171 | 列表（`Item[]`） |
| `ui.code` | :2173 | 高亮代码（`lang`、`start` 行号） |
| `ui.diff` | :2175 | 统一 diff |
| `ui.md` | :2177 | Markdown |
| `ui.meter` | :2179 | 仪表（0–1，带标签） |
| `ui.progress` | :2181 | 进度条（nil = 不确定） |
| `ui.bars` | :2183 | 柱状图 |
| `ui.spark` | :2185 | 迷你折线图 |
| `ui.ansi` | :2187 | 带 ANSI 颜色的迷你终端文本 |
| `ui.diagnostic` | :2189 | 诊断卡片 |
| `ui.test_summary` | :2191 | 测试通过/失败/跳过汇总 |
| `ui.overflow` | :2193 | “…N more” 行 |
| `ui.node` | :2196 | **任意 TSP 节点** `{k, p, c}`；`tabs` 取 `variant: TabsVariant`，`overlay` 取 `OverlayProps` |
| `ui.el` | :2200 | 通用 HTML 子集元素 `tag`（`div`/`form`/`label`/`button`/`input`…），`props` 含 `class`/`attrs`/`text`/通用 prop |

### 1.2 返回 `MeterCell` 的单元格 builder

- `ui.meter_cell(value, thresholds?)` —— :2165
- `ui.meter_parts_cell(parts)` —— :2167

### 1.3 文本输入 / 编辑原语：**没有专用 builder**

- `tern.ui` 表里**不存在** `ui.input` / `ui.text_input` / `ui.editor` 这类文本框 builder（整张 2133-2201 表无此名）。
- 文本输入/编辑只能走两层“画布”：
  1. **原始 TSP 节点**：`ui.node("input", { key, text, cursor, … })` 与 `ui.node("editor", { key, text, cursor, maxLines, … })`。说明见 tern.d.luau:2196（“任意 TSP 节点 `{k,p,c}`”），`input`/`editor` 是 TSP 节点 kind，并非 tern.ui 一级 builder。
  2. **HTML 子集元素**：`ui.el("input", { type = "checkbox" | "radio", name, value, checked, disabled })` —— 仅支持 checkbox/radio（tern.d.luau:2197-2200），**不是文本框**。
- 判定：**需要绕路**。要拿到可编辑文本框，必须用 `ui.node("input"/"editor")`，且编辑行为要自己实现或开启原生编辑（见 1.4）。

### 1.4 tern-prompt-panel 是否 hand-roll 了编辑模式：**是**

证据链：

- 设计注释 host.luau:7-8：“**块没有开启 edit 特性，所有按键都进 key handler**，所以文本、光标都由这里维护（偏移是 UTF-16 码元）。”
- `tern.block.define("prompts", { … })`（host.luau:934）的 def 中**没有** `features` 字段；对照 tern.d.luau:433-435，`features: { "edit" | "undo" }?` 才是开启 tern 原生编辑（点击放置光标、⇧-箭头选区、`edit` 事件）与撤销的开关。即该插件**刻意不开启**原生编辑。
- `lib/field.luau:4` 注释：“**tern 的 editor/input 节点只是状态的画布：字符输入、删除、光标移动都在这里做。**”——所有字符输入/删除/光标移动由插件自管。字段结构 `Field = { text, cursor }`（field.luau:10-13），光标为 UTF-16 偏移。
- 视图里用 `ui.node("input", { key="f_query", text, cursor, placeholder })`（host.luau:519、575、577、579）和 `ui.node("editor", { key="f_body", text, cursor, maxLines=8 })`（host.luau:581）渲染；按键全部走块级 `key` handler（host.luau:979-982 → `editKey`），再写回 `state.query.cursor` / `draft.*.cursor`。
- 补充：仅 `CanvasSpec.view` 禁止 `input/editor/image` 节点（tern.d.luau:1433）；**插件块**的 `BlockView` 允许 `input/editor`——tern-prompt-panel 正是把它放在块里而非 canvas。

结论（题 a）：**tern.ui 没有文本框原语**。文本编辑只能用 `ui.node("input"/"editor")` 这层“画布”，要么开启 `features={"edit"}` 交给 tern 原生编辑，要么像 tern-prompt-panel 那样 hand-roll（它选了后者）。

---

## 2. host 半边 vs window 半边能力划分

### 2.1 **做不得**（window-only，宿主半边没有）

| 能力 | 标记位置 | tern-prompt-panel 用法 |
|---|---|---|
| `cx.agents`（含 `ask`） | “Window only”（tern.d.luau:772、781-782）；`WindowCx.agents: AgentsCx`（:1862） | `window.luau:36/134/149` `cx.agents:list`，`window.luau:158` `cx.agents:ask` |
| `tern.chrome.status`（**注意是 `tern.chrome`，不是 `cx.chrome`**） | “Window only”（tern.d.luau:2266-2274） | `window.luau:280` `tern.chrome.status(...)` |
| `tern.command`（调色板命令注册） | “Window only”（tern.d.luau:2247-2248） | `window.luau:266`、`window.luau:273` |
| 其它 window-only `cx.*` | `layout`（:1736）、`session`（:1695）、`ActionsCx`/palette（:863）、`BrowserCx`（:1045）、`DisplayCx`（:1064）、`CanvasCx`（:1554）、`DocCx`（:1533）、`BoardCx`（:1019）、`NotebookCx`（:1810）、`ProcsCx`（“Desktop window only” :843）、`GitCx`（“Desktop window only” :891）、`DbCx`（“Desktop window only” :984） | — |
| 其它 window-only `tern.*` | `bind`（:2250）、`override`（:2254）、`route`（:2259）、`files`（:2286）、`css`（:2294）、`secrets`（:2087 “Window only”） | — |

### 2.2 宿主半边独有（window-only 反方向）

- `tern.block.define`（:2217-2221 “Host only”）、`tern.lens.define`（:2223-2227 “Host only”）、`tern.pane`（:2229-2235 “Host only”）。
- 宿主 `cx`（EffectCx / BlockCx）成员：`toast`/`open`/`copy`（:1397-1405），`render`/`save`/`exit`/`frame`/`blob`/`pane`/`cols`/`rows`（:1407-1427）。

### 2.3 **做得到**：底层机器能力两端共享（宿主半边“不缺”）

题问 “timers? processes? network? 宿主缺哪个？” —— 答案是 **宿主半边都不缺**，因为 timer/process/fetch/fs 都在无上下文标记的共享 `tern` 表里：

| 能力 | 位置 | 说明 |
|---|---|---|
| `tern.process.run` | :2117-2124，**无 host/window 标记** | 两端都有；窗口侧“进程在调用线程（窗口半边即 UI 线程）启动”（:2120） |
| `tern.fetch` | :2126-2130，无标记 | 两端都有（HTTP(S) 请求） |
| `tern.fs` | :2097-2115，无标记 | 两端都有（同步文件访问） |
| `tern.timer` | :2070-2071，无标记 | 两端都有；窗口侧回调拿到 fresh `cx` |
| `tern.kv` | :2080-2085，无标记 | 两端都有（跨 VM 共享 JSON KV） |
| `tern.getenv` | :2067-2068，无标记 | 两端都有（读本上下文进程的环境变量） |

结论（题 b）：`cx.agents:ask`、`tern.chrome.status`、命令注册（`tern.command`）等是 **window-only**，宿主半边没有；但宿主半边**具备** timer、子进程、网络、文件、KV、环境变量等全部底层机器能力（走共享 `tern.*`）。所谓“宿主半边缺”的只是 window-only 那一层 UI/集成 API，不是机器能力。

---

## 3. 本机环境可用性事实（题 c）

### 3.1 能否从 tern 窗口半边以子进程调用 `gh`

环境已具备（命令输出）：

```
gh version 2.95.0 (2026-06-17)
gh auth status → ✓ Logged in to github.com account meisijiya (keyring); protocol ssh
```

- 调用路线：`tern.process.run({ "gh", … })`（tern.d.luau:2117-2124），窗口半边可用（:2120）。
- 判定：**做得到**。
- 注意事项（caveats）：
  1. 窗口半边预算 50ms Lua / 单次调用墙钟最多 10 个 budget（**500ms**）；原生调用（启动进程）不计入 Lua 预算，但墙钟有 500ms 上限（tern.d.luau:6-13）。一次 `gh` 调用超过 ~500ms 会触发 budget 并暂停该 hook。
  2. 窗口半边进程“在 **UI 线程**启动”（tern.d.luau:2120）；长时间 `gh` 会阻塞 UI，应走 awaitable / 回调而非忙等。
  3. `cwd` 默认解析到**插件目录**（:64）；`gh` 需要网络与登录态——本机已满足。
  4. 进程继承插件环境（增量 `ProcessOptions.env`，:65-66）；`gh` 须在 PATH 上且已登录（本机满足）。

### 3.2 能否读取用户 omp 插件缓存目录 `~/.omp/plugins/cache/...`

- 路线 A（**做得到**）：`tern.fs` 同步文件访问，对“本上下文机器”的文件有效（tern.d.luau:2097-2115），两端都有。给定绝对路径即可 `read`/`list`/`exists`/`mkdir`/`remove`。
- 关键限制：`tern.fs` **不展开 `~`**——相对路径只解析到插件目录（:2097-2099）。必须自己用 `tern.getenv("HOME")`（macOS/Linux）或 `tern.getenv("USERPROFILE")`（Windows）解析 home，再拼绝对路径。
- tern-prompt-panel 的做法即佐证（同一机制可直接复用于 `plugins/cache`）：
  - `lib/ompcmd.luau:18-24` `M.home()` = `env("HOME")` 否则 `env("USERPROFILE")`（此处 `env` 即 `tern.getenv`）。
  - 拼出 `~/.omp[/profiles/<profile>]/agent/commands`，含 `PI_CONFIG_DIR` / `PI_CODING_AGENT_DIR` / `OMP_PROFILE` 处理（ompcmd.luau:27-37）。
  - 用 `tern.fs.exists` / `tern.fs.read` 实际读取（sync.luau:37-38、catalog.luau:18-22）。
- 路线 B（**需要绕路**）：`tern.process.run` shell 出去（`cat` / `gh api` 等）读同一目录。
- 无专用 omp / 插件缓存 API：grep `tern.d.luau` 与 tern-prompt-panel 源码，未找到 `tern.omp` / `tern.plugins` / `plugins/cache` 之类的封装——**未找到**高层封装，`tern.fs` 与 `tern.process.run` 是仅有的两条路。
- 说明：omp 命令目录在 `~/.omp/agent/commands`（README.md:65、ompcmd.luau:4）；题目给定的插件缓存在 `~/.omp/plugins/cache`，二者机制相同，只是子路径不同。

结论（题 c）：
- `gh`（2.95.0、已登录 meisijiya）**做得到**从窗口半边以子进程调用，走 `tern.process.run`，注意 500ms 墙钟预算与 UI 线程阻塞两点。
- 读取 `~/.omp/plugins/cache/...` **做得到**：用 `tern.getenv` 取 home 拼绝对路径后 `tern.fs.read/list`；无专用 API，`tern.fs` 与 `tern.process.run` 是仅有的两条路；`tern.fs` 不展开 `~`，必须自拼绝对路径。

---

## 4. 能力判定汇总

| 能力 | 判定 | 依据 |
|---|---|---|
| 渲染文本框（专用 builder） | 做不得（无 builder，需绕路用 `ui.node("input"/"editor")`） | tern.d.luau:2133-2201 无 `input`/`text_input` builder |
| 块内文本编辑（hand-roll） | 做得到 | host.luau:7-8、934；field.luau:4；host.luau:519/575-581 |
| 开启 tern 原生编辑 | 做得到（块 `features={"edit"}`） | tern.d.luau:433-435 |
| `cx.agents:ask` | 仅 window | tern.d.luau:772/781-782、1862；window.luau:158 |
| `tern.chrome.status` | 仅 window | tern.d.luau:2266-2274；window.luau:280 |
| 命令注册 `tern.command` | 仅 window | tern.d.luau:2247-2248；window.luau:266 |
| 宿主半边跑子进程 / 网络 / 定时器 / 文件 | 做得到（两端共享） | tern.d.luau:2117-2124、2126-2130、2070-2071、2097-2115 |
| 从窗口半边调 `gh` 子进程 | 做得到（注意 500ms 预算、UI 线程） | tern.d.luau:2117-2124、6-13；本机 `gh 2.95.0` 已登录 |
| 读 `~/.omp/plugins/cache/...` | 做得到（自拼绝对路径 + `tern.fs`） | tern.d.luau:2097-2115、2067-2068；ompcmd.luau:18-37、sync.luau:37-38 |
| 专用 omp/缓存读取 API | 未找到（用 `tern.fs` / `tern.process.run`） | grep 无 `tern.omp`/`tern.plugins`/`plugins/cache` 封装 |
