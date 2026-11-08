# Tern Matt 面板

把[中文 mattpocock 技能包](https://github.com/devcxl/mattpocock-skills-zh) 做成一个游戏化的可视面板 —— 面板的操作对象是**技能包**，借鉴 [DSH 插件](https://github.com/FeatherHunter/dsh-mattpocock-skills-deck) 的交互形态，但真源是技能包。

## 它做什么

- **技能面板**：按技能包原生的阶段链（入口 → 规划 → 实施 → 审查与交付 → 旁路与专项）浏览技能，点行看 `SKILL.md` 原文，一键把 `/skill:技能名` 送进旁边的 agent。
- **任务板**：wayfinder 的地图列表 → 前沿票（未关闭、未阻塞、未认领）。点票看详情，按票类型给出对应动作，一键送进 agent。
- **状态栏胶囊**：可领票数 + 技能组版本。

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
| 切换视图（技能 / 任务板） | 顶部「技能」「任务板」按钮 |
| 看技能原文 | 点技能行 |
| 注入到 agent | 技能视图点「注入技能」，票详情点动作按钮；正文**填进输入框**，不替你提交 |
| 看票详情 | 点任务板里的票行（单击即开） |
| 收起 / 展开分组 | 点卡片标题 |
| 排序（最新 / 最早在上） | 任务板顶部排序按钮 |
| 问下一步该做什么 | 任务板顶部「问下一步」：注入 `/skill:ask-matt` 与一段「怎么核事实、怎么给结论」的提示 |
| 新增需求 | 工具条「新增需求」：叫出两条路，没想清楚走 wayfinder 画地图，需求已明确走 grill-with-docs 收敛成 spec |
| 提 BUG | 工具条「提 BUG」：按 wayfinder 规则建 bug 票，带四项填空与建单前查重 |
| 体检 | 工具条「体检」：把游离的开放票归位，先出建议清单，人点头才动手 |
| 刷新 | 点「刷新」；窗口重新聚焦也会自动检查，但 60 秒内最多一次 |
| 换仓库 | 点「换仓库」 |
| 显示 / 隐藏实验技能 | 点「显示实验技能」 |
| 返回任务板 | 点「返回任务板」 |

提示词一律**只填进输入框**（多行用括号粘贴，不会在换行处提前发出），你补完自己的内容再按回车。没有邻近 agent 时退到剪贴板并提示，不会失败。

工具条按面板宽度换行：面板拖窄后按钮折到下一行，不会被裁掉。

「问下一步」只把 `/skill:ask-matt` 加一段提示词填进输入框：让它先用 `gh` 核事实（开放票、依赖、手上有没有半成品），再按「坏了先修 > 卡住的活 > 解锁下游最多 > 阶段顺序」给出最多 3 条建议，每条写明依据。面板不再搬运任务板快照 —— 事实由会话自己核，避免面板与仓库两份数据打架。

「提 BUG」「体检」的正文按参考实现的模板改写，只把 `deck_` 工具换成 `gh`。

三条常驻按钮（新增需求 / 提 BUG / 体检）在任何视图都能按；「问下一步」只在任务板视图出现。

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

GitHub issue，通过 `gh` CLI。仓库跟随面板所在目录的 git remote 推断，可在面板里手动指定（存 `~/.omp` 侧的插件数据里，跨窗口共享）。v1 只读，不写票。

## 开发

```bash
bash test/build.sh <luau 路径>     # 纯逻辑单测
```

改了 `lib/` 下的模块后要 `tern plugin unlink` 再 `link`：`require` 有缓存。

真机验证：

```bash
tern --control <PORT> --dir <插件目录>     # 手动开一个受控窗口
bash test/e2e.sh --port <PORT>            # 默认接这个窗口，不自己起
bash test/all.sh                          # 单测 + e2e 全跑（e2e 没窗口就按环境不可用计）
```

e2e 默认只接已开的受控窗口：起窗口就是一份 GPU 与内存开销，连跑几轮会把机器拖垮。
`--launch` 才会自己起，且跑完只关闭自己起的那个。

## 规格与依据

- `docs/spec/v1.md` —— v1 规格（已定稿）
- `GLOSSARY.md` —— 领域词汇（地图 / 前沿 / 票 / 阻塞边 / 泳道 / 注入 …）
- `docs/adr/` —— 难逆转的决策：技能外置、gh 单后端
- `docs/research/` —— 取证文档：DSH 版对照、tern 能力边界、宿主半边实测、技能包全景调研
