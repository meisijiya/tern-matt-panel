# Tern Matt 面板

把[中文 mattpocock 技能包](https://github.com/devcxl/mattpocock-skills-zh) 做成一个游戏化的可视面板 —— 面板的操作对象是**技能包**，借鉴 [DSH 插件](https://github.com/FeatherHunter/dsh-mattpocock-skills-deck) 的交互形态，但真源是技能包。

## 它做什么

- **技能面板**：按技能包原生的阶段链（入口 → 规划 → 实施 → 审查与交付 → 旁路与专项）浏览技能，点行看 `SKILL.md` 原文，一键把 `/skill:技能名` 送进旁边的 agent。
- **任务板**：wayfinder 的地图列表 → 前沿票（未关闭、未阻塞、未认领）。点票看详情，按票类型给出对应动作，一键送进 agent。
- **状态栏胶囊**：显示面板实际使用的技能包版本（`Matt <version>`）并作为面板入口。版本取自 omp 的插件安装登记，与技能列表、agent 加载的副本同源；没装技能包时退成 `Matt`。不显示票数——胶囊是窗口级的，票数随 tab 的仓库变。

## 硬约束

- **插件不自带任何 skill 正文**。技能来自用户单独安装的 https://github.com/devcxl/mattpocock-skills-zh ，插件运行时探测本机安装位置并只读引用。技能组版本随上游仓库更新，插件不锁版本、不维护副本。
- 探测不到技能包时，面板显示安装提示并给出仓库链接；面板不代装、不代下载、不代升级。
- 票的动作按 **wayfinder 票类型**（grilling / prototype / research / task）分类，不按 triage 标签分类。

## 安装

```bash
tern plugin link /path/to/tern-matt-panel
```

技能包另装：

```bash
git clone https://github.com/devcxl/mattpocock-skills-zh
```

装成 omp 技能包，或放到插件探测得到的位置即可。面板只读它。

## 用法

全部操作都有鼠标入口，面板以鼠标为主。键盘代码仍在（`Tab` 实测可切视图），其余键未在真机验证，界面不宣传。

| 操作 | 怎么点 |
| --- | --- |
| 切换视图（技能 / 任务板 / 技能包） | 顶部「技能」「任务板」「技能包」按钮 |
| 看技能原文 | 点技能行 |
| 注入到 agent | 技能视图点「注入技能」，票详情点动作按钮；正文**填进输入框**，不替你提交。模板注入套一层信封（开始行 → 正文 → 「下面是用户输入的内容」结束行 → 换行），你的需求从下一行开始写 |
| 看票详情 | 点任务板里的票行（单击即开） |
| 打开文档改票（仅本地 markdown 后端） | 票详情 / 地图详情点「打开文档」，调出 tern 的 Markdown 文档视图；平台自带撤销、自动保存、原子写。改完按 `r` 刷新。该文件 agent 也可能同时在写 |
| 收起 / 展开分组 | 点卡片标题 |
| 往更早的已关票翻 | 展开「已关闭」组，点末尾「加载更多（已 N 条）」；一次一页，最多累积 500 条 |
| 排序（最新 / 最早在上） | 任务板顶部排序按钮 |
| 问下一步该做什么 | 任务板顶部「问下一步」：注入 `/skill:ask-matt` 与一段「怎么核事实、怎么给结论」的提示 |
| 新增需求 | 工具条「新增需求」：叫出两条路，没想清楚走 wayfinder 画地图，需求已明确走 grill-with-docs 收敛成 spec |
| 提 BUG | 工具条「提 BUG」：按 wayfinder 规则建 bug 票，带五项索取要素与建单前查重 |
| 体检 | 工具条「体检」：把游离的开放票归位，先出建议清单，人点头才动手 |
| 收尾 | 工具条「收尾」：按七段（盘点 / 审 diff / 文档 / 清理 / 交付 / 复盘 / 报告交接）工程化收口；每段有出口判定，删除与合并等你点头，最后出一份可视化报告与交接文档 |
| 看外部技能包 | 工具条「技能包」：三套外部包的版本、状态、仓库链接与安装指引；视图内「刷新版本」单独查上游更新，不动任务板 |
| 刷新 | 点「刷新」或按 `r`；切回面板所在 tab 时会自动检查，但 5 分钟内最多一次（一次刷新要跑一趟 gh，约 2.8 秒） |
| 换仓库（仅 GitHub 后端） | 点「换仓库」，填 `owner/repo` 或 GitHub 链接；切换按窗口保存。点「重置仓库」回到当前目录的 git remote |
| 显示 / 隐藏实验技能 | 点「显示实验技能」 |
| 返回任务板 | 点「返回任务板」 |

提示词一律**只填进输入框**（多行用括号粘贴，不会在换行处提前发出），你补完自己的内容再按回车。没有邻近 agent 时退到剪贴板并提示，不会失败。

工具条按面板宽度换行：面板拖窄后按钮折到下一行，不会被裁掉。

「问下一步」只把 `/skill:ask-matt` 加一段提示词填进输入框：让它先用 `gh` 核事实（开放票、依赖、手上有没有半成品），再按「坏了先修 > 卡住的活 > 解锁下游最多 > 阶段顺序」给出最多 3 条建议，每条写明依据。面板不再搬运任务板快照 —— 事实由会话自己核，避免面板与仓库两份数据打架。

「提 BUG」「体检」的正文按参考实现的模板改写，只把 `deck_` 工具换成 `gh`。

常驻按钮（新增需求 / 提 BUG / 体检 / 收尾）在任何视图都能按；「问下一步」只在任务板视图出现。

「收尾」声明你已手工验收通过，但不代表没有问题：发现真问题时它会停下来，问你是回到开发还是开一张 BUG 票。两件未在真机验证过的事：报告需要 `answer-me-with-html` 的 `am`（Node ≥20），跑不起来就出 Markdown 报告；`retro` / `handoff` 的元数据禁止模型自动调用，模板内联了它们的规则摘要。

「技能包」视图列三套外部包：mattpocock 技能组、answer-me-with-html、omp-skill-forge。前两套按 omp 安装登记找，第三套按本地安装根目录探测。缺装只提示、不代装；安装指引照抄上游原文。

## 与参考实现的关系

本插件是 [dsh-mattpocock-skills-deck](https://github.com/FeatherHunter/dsh-mattpocock-skills-deck) 的 tern 适配版：功能形态尽量对齐，落在 tern 能力边界内的部分换成等价实现。逐项对照（对得上 / 简化 / 范围外 / 因平台约束改造）见 [`docs/spec/对照参考实现.md`](docs/spec/对照参考实现.md)。

## 架构

```
plugin.toml    插件清单：一个 block（面板）
host.luau      宿主半边：画面（tern.ui 节点树）+ 数据获取（gh 子进程、读技能目录）
window.luau    窗口半边：命令、状态栏胶囊、把注入请求转交给邻近 agent
lib/           纯逻辑（可在 luau CLI 下单测，不依赖 tern）
styles.css     排版，颜色交给主题
test/          luau CLI 桩测试
```

两个半边不共享 Lua 状态，用 `tern.kv` 传令：宿主写请求 → 窗口轮询 → 执行 → 结果回写。

- **数据获取在宿主半边**：`gh` 子进程、读技能目录都在这里（实测见 `docs/research/host-half-runtime.md`）。
- **注入在窗口半边**：`cx:run` / `cx.agents:ask` 都是 window-only（`docs/research/host-async-render.md`）。注入用 `cx:run` 打字，不提交。

## 任务板数据源

后端由**目标仓库自己的跟踪器契约**决定（ADR-0003），面板不提供切换：

- 仓库里有 `docs/agents/issue-tracker.md` 且标题声明 GitHub 或本地 markdown → 按声明走；
- 没有约定文件时按可观察证据识别（origin 指向 GitHub → GitHub；存在 `.scratch/` → 本地 markdown），界面写明「按约定文件」/「按识别」；
- 判不出来时出 setup 卡，提示先跑 `/skill:setup-matt-pocock-skills`。

GitHub 后端走 `gh api graphql`；本地 markdown 后端读 `.scratch/<工作单元>/` 下的 `map.md` / `spec.md` / `issues/NN-<slug>.md`。两种后端产出同一套地图 / 票 / 前沿结构，分组与注入共用。GitHub 模式下仓库仍可「换仓库」按窗口覆盖（存插件 kv），「重置仓库」回到当前目录的 git remote。面板只读，不写跟踪器数据。细节以 [`docs/spec/v1.md`](docs/spec/v1.md) §7 为准。

## 开发

```bash
bash test/all.sh --unit-only     # 单测 + luau-analyze
```

改了 `lib/` 下的模块后要 `tern plugin unlink` 再 `link`：`require` 有缓存。

真机验证只接受已开着的受控窗口，不自己起窗；完整步骤、`tern inspect` 核对 cwd、`ctl tree/pick` 与关窗命令见 [`docs/agents/dev.md`](docs/agents/dev.md)。

## 规格与依据

- `docs/spec/v1.md` —— v1 规格（已定稿）
- `GLOSSARY.md` —— 领域词汇（地图 / 前沿 / 票 / 阻塞边 / 泳道 / 注入 …）
- `docs/adr/` —— 难逆转的决策：技能外置、gh 单后端
- `docs/research/` —— 取证文档：DSH 版对照、tern 能力边界、宿主半边实测、技能包全景调研
