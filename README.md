# Tern Matt 面板

把[中文 mattpocock 技能包](https://github.com/devcxl/mattpocock-skills-zh) 做成一个游戏化的可视面板 —— 面板的操作对象是**技能包**，借鉴 [DSH 插件](https://github.com/FeatherHunter/dsh-mattpocock-skills-deck) 的交互形态，但真源是技能包。

## 它做什么

- **技能面板**：按技能包原生的阶段链（入口 → 规划 → 实施 → 审查与交付 → 旁路与专项）浏览技能，点行看 `SKILL.md` 原文，一键把 `/技能名` 送进旁边的 agent。
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

面板里的操作都能用鼠标点，键盘快捷键同样有效。

| 操作 | 鼠标 | 键盘 |
| --- | --- | --- |
| 切换视图（技能 / 任务板） | 点顶部按钮 | `Tab` |
| 选中一项 | 点列表行 | `↑` `↓` |
| 看技能原文 | 点行 | `Enter` |
| 注入到 agent | 票详情里点动作按钮 | `i` |
| 复制 | 票详情里点「复制」 | `c` |
| 打开链接 | 票详情里点「打开链接」 | `o` |
| 刷新 | 点「刷新」 | `r` |
| 换仓库 | 点「换仓库」 | `Shift+R` |
| 显示 / 隐藏实验技能 | 点「显示实验技能」 | `s` |
| 返回任务板 | 点「返回任务板」 | `Esc` |

没有邻近 agent 时，注入会退到剪贴板并提示，不会失败。

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
- **注入在窗口半边**：`cx.agents:ask` 是 window-only（`docs/research/host-async-render.md`）。

## 任务板数据源

GitHub issue，通过 `gh` CLI。仓库跟随面板所在目录的 git remote 推断，可在面板里手动指定（存 `~/.omp` 侧的插件数据里，跨窗口共享）。v1 只读，不写票。

## 开发

```bash
bash test/build.sh <luau 路径>     # 纯逻辑单测
```

改了 `lib/` 下的模块后要 `tern plugin unlink` 再 `link`：`require` 有缓存。

真机验证：

```bash
tern --control <PORT> --dir <插件目录>
tern ctl --control <PORT> --file scenario.sc
```

## 规格与依据

- `docs/spec/v1.md` —— v1 规格（已定稿）
- `docs/research/` —— 取证文档：DSH 版对照、tern 能力边界、宿主半边实测、技能包全景调研
