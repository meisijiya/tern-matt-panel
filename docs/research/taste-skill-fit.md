# taste-skill 2.5.1 该不该进「前端」模板（取证）

> 调研对象：本机已装的 `design-taste-frontend`（tasteskill 2.5.1）反模板前端技能。
> 一手来源：
> - `C:/Users/22923/.omp/agent/skills/design-taste-frontend/SKILL.md`（正文行号均指此文件）
> - `C:/Users/22923/.omp/plugins/cache/plugins/taste-skill___taste-skill___2.5.1/skills/taste-skill/` 下的 `SKILL.md`、`scripts/*.mjs`、`assets/layout/check.mjs`
> - 本机命令输出（Node / 浏览器 / ffmpeg 探测）与在临时目录里实跑脚本的计时
> - `D:/26code/tern-matt-panel/lib/packs.luau`、`lib/paths.luau`、`host.luau`（面板技能包视图口径）
>
> 标注 **[事实]** = 直接读源文件/跑命令得到；**[推断]** = 基于事实的推理，需下游确认。
> 约定：本报告只做取证，不涉及实现；脚本均在系统临时目录实跑，未在本仓库写任何文件。

---

## 0. 结论先行

- 技能本体是**整站/落地页级**的完整交付流程，核心价值在「真实浏览器里跑的检查器 + 收尾门禁」，不是一套可拆的组件样式库。[事实]
- 本机环境**满足**它的硬前提：Node 24.4.0（要求 22+）、Chrome 与 Edge 均已安装（脚本用硬编码绝对路径探测，不需要 CHROME_PATH）、ffmpeg 8.1.1 在 PATH（仅照片转码用，可选）。[事实]
- 它声明的 **Stop hook 在 omp 不生效**：omp 的技能 frontmatter 校验不认 `hooks` 键，且 omp 只从 `.claude/hooks/pre|post/` 加载钩子；本机所有 `CLAUDE_*` 回退路径都不存在。门禁必须由模板显式调 `gate.mjs`。[事实][推断]
- 单轮全量门禁实测 **约 60s**；单次 `consistency.mjs --quick` **约 46s**、`shoot.mjs` 单图 **约 21s**、`layout/check.mjs` **约 13s**；`copy-lint.mjs` **0.12s** 且不开浏览器。[事实]
- 三档建议：**整站新建/整体重设计 = 必用（全链）**；**组件级或既有页面局部改动 = 仅借 copy-lint + 局部检查项，不跑整门**；**无浏览器/非前端交付 = 不用**。[推断，依据见第 4、7 节]

---

## 1. 技能定位

- frontmatter：`name: design-taste-frontend`，`tasteskill 2.5.1, the anti-slop frontend skill`，并声明了一个 `hooks: Stop`（`SKILL.md:1-20`）。[事实]
- 定位：把公司站点做到 figma.com / x.ai 的水准——平实文案、一套系统、每屏一个区块、左右边距对齐、真实照片与真实产品 UI、hero 入场 + 每页一两个时刻、仅 tech/gaming 类页面用 shader 与场景、克制微交互，并「在真实浏览器里用检查器和收尾门禁强制执行」（`SKILL.md:4-13`）。[事实]
- 硬前提：**Node 22+ 与 Chrome、Edge 或 Chromium**（ffmpeg 可选）（`SKILL.md:28`；README.md:86）。[事实]
- 交付形态：空目录 → 把 `assets` 拷进项目、从 `assets/starter.html` 起手；已有工程 → 用自己栈、组件取 starter 的 markup 与 class、套件拷进 `public/assets` 当纯文件加载；要求 Next.js 的走 `output: 'export'` 静态导出（`SKILL.md:160-164`）。[事实]
- 体量：技能根 **39M / 1631 个文件**——`assets` 37M（starter.html、system.css/js、layout、ui、motion、photos、effects、objects、scenes、moments、icons、diagrams 等）、`scripts` 1.6M、`references` 440K、`library` 68K（`du`/`find` 实测，根 `~/.config/magpie/library/skills/design-taste-frontend`）。[事实]
- 它要求「开工前先按业务分型、按屏规划，再写 markup」，是一个**流程型**技能，不是样式工具箱（`SKILL.md:156`、`README.md:99-106`）。[事实]

---

## 2. 强制输入

技能要求开工时先确定、并写进页面/门禁的输入：

| 输入 | 用途 | 出处 |
|---|---|---|
| 业务分型 kind | `software / gaming / tech / product / service / place` 之一，写在计划第一行并声明在 `<html data-type>`、`<meta name="page-type">`、`<meta name="site-kind">`（place 另加 `page-kind`） | `SKILL.md:58-76` |
| 主行动 primary | 一个交易动作（Book a room / Order a cake / Start a free trial；地方类无交易则 Get directions） | `SKILL.md:167-168` |
| 品类 category | 「卖什么」，供门禁与检查器判定 | `SKILL.md:172` |
| 真实素材 | logo、截图、照片、价格、地址、营业时间 | `SKILL.md:168` |
| trade | 供 `start.mjs deal` 配调色板（cafe/bakery/saas/devtool/fintech/ai/game/hardware…） | `start.mjs:14-16` |
| 照片（地方类） | 整页 12–20 张（紧凑 8–12）；客户无照片时走 draft 路径 + 在线搜索（`photos.mjs`），再按张数定页长 | `SKILL.md:87-91` |
| 图标 | 用 `icons.mjs` 落地真实产品图标，最后一步扫描页面 | `SKILL.md:241` |
| starter / system CSS | 必须沿用套件的 `system.css`、`layout.css`、`ui/cards.css`、`motion/motion.css`、`backgrounds.css`、`icons.css`、`ui/base.css` 等，顺序不可乱 | `starter.html:39-52` |
| 门禁参数 | `--start <页面|URL>` + `--kind` + `--category` + `--primary` | `SKILL.md:172` |

**组件级工作用不到的输入**（在组件场景下是纯负担）：

- 业务分型的页面级声明：组件没有 `<html data-type>` / `page-type` meta，检查器按整页结构判定，组件场景无从落这些 meta。[事实+推断]
- 照片数量规则、moments/scenes/effects 的分型规则：组件级交付一般不含整页叙事与大场景。[事实]
- `deal.mjs` hero、`start.mjs` 调色板/字配、六段选择列表（nav/footer/close/rhythm/buttons/mark）：这是「整页由哪些区块构成」的决策，组件级不需要。[事实]
- copy-voice 层（fact sheet、voice card、register、moves）：文案层工具，组件级改写文案用不到完整流程。[事实]
- 照片/图标库的整体引入：只有需要真实照片、真实产品图标时才用；纯样式组件不必。[事实]

---

## 3. 环境实测

### 3.1 只读探测

- `node --version` → **v24.4.0**，满足 Node 22+。[事实]
- `where chrome` / `where msedge` / `where chromium` → **均找不到**（PATH 上无浏览器）。[事实]
- 但浏览器已安装，脚本按硬编码绝对路径探测：`C:/Program Files/Google/Chrome/Application/chrome.exe` 与 `C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe` 均存在。[事实]
- `shoot.mjs:116-120`、`assets/layout/check.mjs:49-51`、`scripts/perf.mjs:79-82` 的探测列表都含上述路径；`consistency.mjs:4601-4617` 用 `CHROME_PATH` → ProgramFiles → LOCALAPPDATA → Edge 的同样顺序，找不到才 `throw`。[事实]
- 结论：**本机无需设 `CHROME_PATH`**，脚本能自己找到 Chrome。[推断，依据上条]
- `ffmpeg -version` → **ffmpeg version 8.1.1-full_build** 在 PATH。[事实] ffmpeg 只在 `photos.mjs` 里用于 WebP 转码与手机裁切，属可选能力（`README.md:86`，`photos.mjs:59-67,808-934`）。[事实]

### 3.2 脚本可运行性实测（临时目录，未写仓库）

用一张最小探测页（`software` 型，含 hero + 一个按钮）实跑，全部在 Git Bash：

| 脚本 / 命令 | 实测耗时 | 行为 | 失败形态 | 副作用 |
|---|---|---|---|---|
| `copy-lint.mjs index.html --kind software` | **0.12s** | 只读文本，不开浏览器 | 输出 FAIL/WARN 计数，退出 0 | 无 |
| `consistency.mjs index.html --quick --widths 1440,390 --json` | **46.4s** | 起一个 headless Chrome（WebGL 走 CPU/swiftshader），HTTP 自伺服 127.0.0.1，测 1440/390 | 有 FAIL → **退出 1**；输出 JSON 报告 | 写 `.taste-skill/consistency/`（10 张 crop .jpg + `rendered.html` + `report.json`） |
| `assets/layout/check.mjs --url index.html --sizes 1440x900,390x844 --json` | **13.4s** | 起自己的 headless Chrome | 有 finding → 退出 1 | 写 `--shots` 目录（本次未指定） |
| `shoot.mjs --url index.html --w 1440 --out shots/1440.png --no-tiles` | **20.7s** | 逐屏截图后在 Node 里拼接（避免多 WebGL canvas 长页卡死） | 失败抛错 | 写 `shots/1440.png` |
| `gate.mjs --start index.html --kind … --category … --primary …` | <1s | 建立构建标记 | 无标记时退出 0 | 写 `.taste-skill/build.json`（3 轮） |
| `gate.mjs --hook claude`（已 arm、无页面） | **0.12s** | 读 stdin，无构建/无页面时放行 | **退出 0**，stdout 打 JSON `{"decision":"block",...}` | 写 `gate.json` 历史 |
| `gate.mjs index.html`（全量门禁，已 arm） | **60.0s** | 跑 consistency(quick) + layout/check + copy-lint + kit-edited + checker-gaming | **退出 1**，末行 `GATE: FAIL 11 (round 1 of 3)` | 写 `.taste-skill/gate.json`、crops |

- 门禁状态机退出码：`0` PASS/OFF/DONE，`1` FAIL/OPEN，`2` ERROR，`3` SETUP（`gate.mjs:36-38`）。[事实]
- 门禁「不困住 agent」的保险：每轮封顶 3 轮；hook 模式下每个 block 计数，超 `轮次+4` 或 6 小时内 30 次后一律放行；无页面/框架源码壳各 block 一次后放行；构建空闲 24h、跨会话、多文件夹编排者均放行（`gate.mjs` 头部注释）。[事实]
- **omp 会话里的可行性**：脚本都是纯 Node、无第三方依赖、各自起自己的 headless Chrome 并用 PID 收尾，前台串行跑即可，符合 omp 的 bash 工具能力；唯一代价是**耗时**——全量门禁单轮 60s、多断点全宽检查更长，模板里必须把它当成一个显式的长步骤，而不是零成本断言。[事实+推断]
- **Stop hook 在 omp 的生效性**：`SKILL.md:14-19` 的 frontmatter 声明了 `hooks: Stop`，命令只在 `$CLAUDE_SKILL_DIR` / `$CLAUDE_PLUGIN_ROOT` / `$CLAUDE_PROJECT_DIR` 等 `CLAUDE_*` 变量存在时找 `gate.mjs`。实测：本机这些变量**均未设置**（`env` 只有 `CLAUDECODE=1`），且 `~/.claude/skills/design-taste-frontend/`、`~/.agents/skills/design-taste-frontend/` **都不存在**——回退路径全空，钩子找不到脚本、静默放行。[事实]
- 更深一层：从 omp 二进制取证，其技能 frontmatter 校验只认 `name / description / license / allowed-tools / metadata / compatibility` 六个键，出现其它键会报 `unexpected frontmatter field`；omp 加载钩子走的是 `.claude/hooks/pre/` 与 `.claude/hooks/post/`，**没有从技能 frontmatter 执行 `hooks:` 的通路**（`omp.exe` 内嵌 JS `vne` 键表与 `GSe` 校验、以及发现器描述串）。[事实（二进制内嵌字符串）]
- 注意：该技能仍出现在 `omp skill list`（`source: native:user`），说明 omp 容忍了这个未知键、正常加载了技能正文；即「校验器存在」但**不阻断加载**，而**钩子本身不会被触发**。[事实+推断]

---

## 4. 适用面矩阵

### 4.1 整站 / 落地页（新建或整体重设计）

| 能用的部分 | 说明 | 出处 |
|---|---|---|
| 全部流程 | 分型 → 文案层 → 按屏规划 → deal 调色板/字/hero/时刻 → 建页 → 检查器 → 门禁 → 报告 | `SKILL.md:158-296` |
| 9 条 house rules | 无图注、每视觉都渲染、每屏一区块、左右边距对齐、hover 微动、真实照片与图标、时刻/场景按分型、联系信息规则 | `SKILL.md:34-56` |
| 检查器 id 集 | `consistency.mjs`（screens/edges/chrome/spacing/a11y…）、`layout/check.mjs`、`perf.mjs`、`copy-lint.mjs` | `SKILL.md:298-363` |
| 门禁 rounds | 最多 3 轮，PASS/OPEN/DONE 收口 | `SKILL.md:278-289` |

**没有浪费的步骤**——这正是技能的目标场景。

### 4.2 组件级工作（单组件/局部 UI）

| 能用的部分 | 说明 | 出处 |
|---|---|---|
| `copy-lint.mjs` | 0.12s、不开浏览器，改文案时快速查 slop 词/套话/残渣 | `SKILL.md:260,268` |
| `system.css` 的 token/网格/按钮/卡片规范 | 取用「一套系统」的约束，保证组件不破坏统一性 | `SKILL.md:139,142,342-345` |
| `consistency.mjs` 的局部检查项 | 边距对齐、对比度、one-system、按钮/卡片一致性等单点判定 | `SKILL.md:298-363` |
| `perf.mjs` | 图片体积、WebGL 上下文数、布局抖动 | `SKILL.md:154,354` |

**浪费 / 会误伤的步骤**：

- 跑整门（`gate.mjs`）会按整页结构判定，组件必然大量误报：`cta`（hero 无按钮）、`copy-fact`（首屏无硬事实）、`hero-fold`/`screen-short`（区块不满一屏）、`one-section`/`section-height`、`page-meta`/`share-meta` 等——实测一张最小探测页就拿到 11 个 FAIL（第 3.2 节）。[事实+推断]
- deal 调色板/字/hero、`deal.mjs`、moments/effects/scenes、照片张数规则、copy-voice 完整层：组件级无对应对象。[事实]
- 结论：组件级**只借工具、不跑流程**；若要门禁，只跑 `copy-lint` 加针对性检查项，不要把整门当验收。[推断]

### 4.3 既有页面重构

| 能用的部分 | 说明 | 出处 |
|---|---|---|
| 检查器 + copy-lint | 重构时最有价值的是「找出模板感/AI 味」的客观判据：边距、对比、文案、照片、动效、性能 | `SKILL.md:298-363` |
| 套件 token 体系 | 既有工程可只取 token 与规范，逐步对齐「一套系统」 | `SKILL.md:162-164,342-345` |

**代价 / 浪费的步骤**：

- 技能对既有工程的口径是「组件取 starter 的 markup 与 class、套件拷进 `public/assets` 当纯文件加载」（`SKILL.md:161-164`），即**整体迁移到套件结构**才能让门禁通过；不做迁移、只改局部，门禁的 `kit-edited`（页面加载的 assets 文件与技能副本不一致）、`page-meta`、`one-section`、`hero-enter`、`moment-none` 会持续 FAIL。[事实+推断]
- 若只想「诊断既有页面」，用检查器读一次即可，**不必 arm 门禁、不必走 3 轮**；门禁的价值在「反复改到通过」，对一次性诊断是浪费。[推断]

---

## 5. 安装与版本

### 5.1 上游安装方式

- `npx skills add https://github.com/Leonxlnx/taste-skill --skill "design-taste-frontend"`，走 vercel-labs/agent-skills CLI（`README.md:81-84`）。[事实]
- Claude Code 插件：`/plugin marketplace add Leonxlnx/taste-skill` + `/plugin install taste-skill@taste-skill`，技能带 `taste-skill:` 前缀（`README.md:89-96`）。[事实]
- Codex 插件：`codex plugin marketplace add Leonxlnx/taste-skill` + `codex plugin add taste-skill@taste-skill`（`README.md`）。[事实]
- 从 clone 安装：`./install.sh` 符号链接进 `~/.claude/skills`（`--codex` / `--all-agents`），Windows 用真链接或目录 junction，保证 `git pull` 原地更新（`install.sh:1-14`）。[事实]

### 5.2 本机实际落点与版本来源

- omp 插件登记：键 `taste-skill@taste-skill`，`installPath = C:\Users\22923\.omp\plugins\cache\plugins\taste-skill___taste-skill___2.5.1`，`version = 2.5.1`，装于 2026-11-11（`~/.omp/plugins/installed_plugins.json`；`omp plugin list --json` 同值）。[事实]
- 插件缓存是 git 克隆，停在 tag **v2.5.1**（`git log` → `Merge pull request #196 from Leonxlnx/v2.5.1`；`git describe --tags` → `v2.5.1`）。[事实]
- 版本声明：插件根 `.claude-plugin/marketplace.json` 与 `.codex-plugin/plugin.json` 均写 `version: 2.5.1`、`license: MIT`、`skills: ["./skills/taste-skill"]`。[事实]
- omp 暴露的技能入口：`design-taste-frontend`，`source: native:user`，路径 `C:\Users\22923\.omp\agent\skills\design-taste-frontend\SKILL.md`（`omp skill list --json`）。[事实]
- 该入口是符号链接 → `C:\Users\22923\.config\magpie\library\skills\design-taste-frontend`（`ls -la ~/.omp/agent/skills` 实测），与插件缓存的 SKILL.md **内容一致**（`diff` 仅 CRLF/LF 差异，退出 0）。[事实]
- 插件缓存根**没有 `package.json`**（`ls` 实测）——面板用 `paths.packageVersion(root)` 读 `<root>/package.json` 取版本，此处会返回 nil，即**按缓存目录探测时版本为「未知」**。[事实]

### 5.3 面板技能包视图该用哪个键 / 路径

面板技能包清单在 `lib/packs.luau` 的 `M.PACKS`，每包需 `id / title / purpose / repo`，二选一给出落点：

- `registryKey`：omp 安装登记里的键，`host.luau loadPacks` 先按它从 `~/.omp/plugins/installed_plugins.json` 取 `{installPath, version}`（`lib/packs.luau:15-18`、`host.luau:270-306`）。
- `localRel`：相对 home 的本地目录，`registryKey` 为 nil 时用（`lib/packs.luau:17-18`、`host.luau:307-317`）。
- 登记里查不到时回退扫描 `~/.omp/plugins/cache/plugins/<id>___*`（`host.luau:249-266` `cachedPackRoot`，匹配前缀 `id .. "___"`）。[事实]

**taste-skill 应填**：`registryKey = "taste-skill@taste-skill"`。理由：本机已按此键登记，`host.luau:287-306` 会直接拿到 `installPath` 与 `version: 2.5.1`；若只靠缓存兜底，则因插件缓存无 `package.json`，版本显示为「未知版本」（`lib/packs.luau:195-200`）。[事实+推断]

> 注意：插件缓存的技能根是 `<installPath>/skills/taste-skill/`，面板的 `skills.readPackage` 期望 `<root>/skills/<分类>/<技能>/SKILL.md`，而 taste-skill 是 `skills/taste-skill/SKILL.md`（无分类层）。所以**技能包视图若复用现有「列分类下技能」的口径，taste-skill 的布局与现有三包（mattpocock 有分类层）不同**，需要单列处理或只展示包状态、不展开技能列表。[事实+推断]

---

## 6. 许可证与引用

- 许可证：**MIT**，`LICENSE` 首行 `MIT License`、`Copyright (c) 2026 Leonxlnx`；插件元数据 `license: MIT`（`.claude-plugin/marketplace.json`、`.codex-plugin/plugin.json`）。[事实]
- MIT 义务：在所有副本或实质性部分中保留上述版权与许可声明（`LICENSE` 正文）。[事实]
- **引用边界**：面板仓库的既有纪律是「对技能目录只读，绝不把正文复制进本仓库或插件数据目录」（`lib/skills.luau:4` 注释）。因此面板**只引用技能、不复制 assets**，与 MIT 及面板设计一致。[事实]
- 但技能自身的运行步骤要求**把套件 assets 拷进被设计的目标项目**（`SKILL.md:160-164`），门禁还会比对页面加载的 assets 是否与技能副本一致（`kit-edited`，`gate.mjs` 头部注释）。即：**「引用技能」≠「不拷 assets」**——运行时由 agent 把 assets 拷进**被设计的项目**，这是技能要求的一步；面板仓库本身仍不持有副本。[事实+推断]
- 技能内部也禁止照抄参考站点的代码/文案/图片/签名效果（`SKILL.md:375`），与「只引用、不搬运素材」的边界一致。[事实]

---

## 7. 建议（三档）

### 7.1 必用（整站 / 落地页的新建或整体重设计）

**依据**：技能的全部价值——分型驱动的规划、一套系统的 token/markup、真实浏览器检查器、收尾门禁——都为整站/落地页而设，没有为组件裁剪的多余步骤。本机环境满足硬前提，全链可跑（第 3 节）。门禁的 3 轮上限与反困住机制保证它不会无休止阻塞（`gate.mjs` 头部）。**「前端」模板的「新建设计」路线应当直接引用本技能，并把 `gate.mjs` 作为模板里的显式收尾步骤。**[推断，依据第 1、3、4.1 节]

### 7.2 仅整站用（组件级 / 既有页面局部改动）

**依据**：组件级场景下，门禁按整页结构判定会大量误报（实测最小页即 11 FAIL，第 3.2、4.2 节），跑整门是浪费且误导。既往页面重构若不整体迁移到套件结构，`kit-edited`/`page-meta`/`one-section`/`moment-none` 会持续 FAIL（第 4.3 节）。此时**只借 `copy-lint.mjs`（0.12s）、`perf.mjs` 与 `consistency.mjs` 的局部检查项**做诊断，不 arm 门禁、不跑 3 轮。[推断，依据第 2、4.2、4.3 节]

### 7.3 不用（无浏览器环境 / 非前端交付 / 仅需写组件样式）

**依据**：所有视觉判定都依赖 headless Chrome，脚本找不到浏览器时 `check.mjs` 直接退出 2、`consistency.mjs` 直接抛错（第 3.1、3.2 节）；无前端产出（纯后端、文档、非页面交付）时整套分型/deal/照片/时刻流程没有对象。此档跳过，避免引入无法运行的门禁。[推断，依据第 3、2 节]

### 7.4 对「前端」模板的一条硬提醒

技能的 **Stop hook 在 omp 不生效**（第 3.2 节）。若「前端」模板想让门禁真正兜底，必须把「跑 `gate.mjs`、修到 PASS/OPEN、报告 GATE 行」写成模板内的**显式步骤**，不能依赖技能 frontmatter 的 `hooks: Stop`。[事实+推断]

---

## 附：仍未解决 / 需人拍板的点

1. **面板技能包视图对 taste-skill 的展开方式**：其布局是 `skills/taste-skill/SKILL.md`（无分类层），与现有 `skills/<分类>/<技能>/SKILL.md` 口径不同，需定「只展示包状态」还是「单列展开技能」。（第 5.3 节）
2. **是否接受「组件级借用但不走整门」**：这偏离技能「整链强制执行」的原始口径，属对技能的裁剪使用，需确认面板模板是否允许这种半用。（第 4.2、7.2 节）
3. **门禁耗时在 omp 会话中的预算**：全量门禁单轮约 60s、修复轮次累加，模板是否把这一步列为「可被用户中断的后台/长步骤」而非普通断言，需定档。（第 3.2 节）
