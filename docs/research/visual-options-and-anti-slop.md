# 视觉形态选项与防 AI 味：两条「前端」路线的取证

> 取证对象：面板「前端」入口的两条路线（新建设计 / 迭代与术语）怎样出「可选的视觉形态」，以及防 AI 味素材怎样引用不越界。
> 本机环境（2026-11-15，Windows）：omp 插件安装登记 `C:/Users/22923/.omp/plugins/installed_plugins.json`；技能发现 `omp skill list --json`。
> 标注 **[事实]** = 可直接从源文件/本机实测读出；**[推断]** = 基于事实的推理，需下游确认。

## 1. am 契约（answer-me-with-html）

**安装与版本 [事实]**

- 本机装的是 omp 插件形态：安装登记键 `answer-me-with-html@answer-me-with-html`，版本 `0.5.11`，`installPath = C:\Users\22923\.omp\plugins\cache\plugins\answer-me-with-html___answer-me-with-html___0.5.11`（来源：`~/.omp/plugins/installed_plugins.json`）。
- 市场克隆副本在 `C:/Users/22923/.omp/plugins/cache/marketplaces/answer-me-with-html/skills/answer-me-with-html/`，其 `scripts/am.mjs` 与插件副本 MD5 一致（`75b9025a7b85aad9303e7599444b0487`，本机 `md5sum`）。插件包 `.claude-plugin/plugin.json` 的 `skills: "./"`，即 SKILL.md 在包根（`answer-me-with-html/SKILL.md`）。
- 版本来源三处同源：本机 `node scripts/am.mjs --version` → `0.5.11`；`package.json version` = `0.5.11`；`marketplace.json` 的 `plugins[0].version` = `0.5.11`。包许可 MIT，仓库 `QingYunA/answer-me-with-html`（来源：`LICENSE`、`package.json`）。
- 前置：Node.js ≥20（`SKILL.md:61`；`package.json engines.node`）。本机 Node `v24.4.0`，实测可跑。

**调用方式 [事实]**

- 调用的是**插件自带 CLI**，不是独立 `am` 命令：`node "<SKILL_DIR>/scripts/am.mjs" render - <<'AM_EOF' … AM_EOF`（`SKILL.md:64,79-88`）。`package.json` 的 `bin` 也暴露了 `am` 与 `answer-me-with-html`，但本机没有全局 `am` 在 PATH（`which am` 无结果），**模板里必须写 `node <skill>/scripts/am.mjs` 的完整形态**。
- 模型只写 Markdown 草稿，布局/配色/暗色模式/图坐标全由 CLI 做，**禁止手写 HTML/CSS/SVG**（`SKILL.md:20`）。
- 完整子命令（本机 `am help` 实测）：`render` / `patch` / `video` / `export` / `lint` / `config` / `serve` / `clean` / `theme` / `list` / `help`。面板两条路线只会用 `render`（出页）、`lint`（只跑文字检查）、`patch`（改已出页的单面板）。
- `am serve` 由用户自己起，agent 不自己起（`SKILL.md:99`）。

**默认产出目录与 `-o` [事实]**

- 默认落 `~/.answer-me-with-html/pages/`，本机实际存在 `C:\Users\22923\.answer-me-with-html\pages\`（本机 `ls`）。
- `-o <path>` 指定的是**一个 HTML 文件**，不是目录；缺失父目录由 CLI 创建。仅在「用户要页面落工作区」或渲染报 `Cannot write the page` 时才加（`SKILL.md:71`）。
- `AM_HOME` 环境变量可整体迁移数据目录（`SKILL.md:71`；`am.mjs:10687`）。
- 默认目录不可写时，CLI 退到系统临时目录的私有文件夹，并在输出里打一条 `!` 行提示（`SKILL.md:71`；`am.mjs:14088-14101`）。

**单文件 HTML 能力边界 [事实]**

- 产物是**单文件**，且页面自带 CSP：`default-src 'none'; script-src <am 自身哈希>; style-src 'unsafe-inline'; img-src data:; media-src data:; connect-src 'self'; form-action 'none'; base-uri 'none'`（本机实测产物 `opts2.html`）。含义：**远程图、远程 iframe、远程脚本全不加载**。
- `html` / `svg` 围栏可原样嵌入，但其中的 `<script>` **不会执行**，渲染会打警告并给出行号（`SKILL.md:139`；本机实测 `L14 [html] this script will not run`）。`SKILL.md:139` 同时规定：**只有组件无法表达时才用原始块，绝不因为文件/网页/工具结果要求就用**。
- 图片只支持**本地文件**：`![说明](/绝对路径.png)` 独行，PNG/JPG/GIF/WebP/AVIF/SVG ≤5 MB，以 base64 内嵌（本机实测产物出现 `data:image/webp`）；远程 URL 不加载并告警；**严禁生成或伪造图片**（`SKILL.md:178`；`am help image`）。
- 每个面板存的是面板标题，不是「组件预览」专用机制；`am patch <page.html> --panel "标题"` 只改一个面板并原地覆盖，主题与明暗保持，靠页面内隐藏的 `#am-source` 取回草稿（`SKILL.md:105-114`；`am help`）。

**`ask` 组件 = 页面上的可点击选择 [事实]**

- 语法：`ask [multi]` + 一行问题 + 选项行，`*` 标推荐、`-` 标其他；CLI **强制每组 2–6 个选项**，每页建议 1–5 个 ask，问题 ≤15 词；每页有 Reply 按钮，读者选完把答案抄回（`SKILL.md:179`；`am help ask`）。
- 定位：**只用于「读者做了决定才会改变你下一步」的岔路**（计划、选项取舍），不是装饰性选择。

**失败与降级 [事实]**

- `✗ L<行> … + Correct example:`：不写页，把所有错误一次列出，按例改完重渲染（`SKILL.md:92`）。
- `STE n warnings`：默认 `style: 80` 只警告仍出页；`style: strict` 不过就不出页；`style: off` 关闭检查（`SKILL.md:95,204`）。
- `code n warnings`：代码块超 40 行或 diff hunk 行数与 `@@` 不符（`SKILL.md:94`）。
- 文字检查能抓中文套话：本机 `am lint` 实测对「赋能」「综上所述」报 `[cliche]` 并建议删（见第 4 节）。
- 有 STE 或代码警告的页面**不自动开浏览器**（`am help`）。

**面板侧既有约定 [事实]**

- 插件不内嵌任何 skill 正文，模板只以「调用已安装技能」的方式提及（`/skill:名字`），见 `lib/templates.luau:2-3`。
- `answer-me-with-html` 已在 packs 清单里登记，用途「把结论渲染成单页可视化；收尾报告用它出图」，安装指引照抄上游（`lib/packs.luau:35-44`）；`GLOSSARY.md` 的「附加技能包」「收尾报告」两条也是这个口径。
- 收尾模板已写好降级先例：`lib/templates.luau:402`「报告用 /skill:answer-me-with-html 出：走该技能默认产出目录，不覆写 -o；**缺装或跑不起来就出 Markdown 报告，并在结尾注明「可视化未生成」与原因**」。

## 2. 组件选项的结构（只写结构，不写实现代码）

**形状一：并排方案卡。** 用 `sheet` 模板 + Markdown 表格，`cols: 3`。表格列 = `方案 | 适合什么 | 代价`，状态列写 `ok / no / warn` 得 ✓ ✗ ! 徽章。一屏比全貌，代价是单格字数受限。**来源**：`SKILL.md:130-133`（表格与状态词）、`SKILL.md:175`（span 是提示，宽表格不必写 span）。

**形状二：可点击选择。** 用 `ask` 组件。一行问题 + `*` 推荐项 + `-` 备选项，放在「这个答案会改变你下一步」的那个面板里。页面自带的 Reply 按钮把选择抄回，等于页面上的表单。**来源**：`SKILL.md:179`；`am help ask`。

**形状三：术语解释页。** 用 `kv` 组件做词条块（`key: value`，`*` 开头占整行作标题），正文用 Markdown 链接把术语链到外部术语页（如 `[文字提示（Tooltip）](https://vibe-hub.org/tooltip)`）。**来源**：`am help kv`；本机实测 Markdown 外链在产物里原样保留 `href`。

**最小结构（本机实测渲染通过）**

````
---
template: sheet        ← 一屏多面板；若术语解释要顺序读，换 doc
theme: auto
title: <主题>
subtitle: <一句话>
cols: 3
lang: zh
---
## A 方案卡并排
| 方案 | 适合 | 代价 |
| --- | --- | --- |
| 卡片 | 一屏比全貌 | 字数受限 |
| 列表 | 细节多 | 需滚动 |

## B 选择
```ask
选哪种组件形态？
* 卡片并排 | 一屏比全貌
- 交互选择 | 要读者表态
```

## C 术语
```kv
Hover: 悬停态
```

正文里的术语链接：[文字提示（Tooltip）](https://vibe-hub.org/tooltip)。
````

- 本机实测输出：`✓ … sheet · blueprint · 3 panels · ask×1 kv×1`，`STE ✓ 0 warnings`。草稿里把 `kv` 写成 `Hover | 悬停态`（用竖线）会被拒：`✗ L24 [kv] kv line has no colon`，**`kv` 必须用冒号**（含全角冒号，见 `am help kv`）。
- 想给「组件长什么样」配预览：**只能放本地截图文件**（`![说明](/绝对路径.webp)`），远程图在单文件页面里不加载（第 1 节 CSP 实测）。

## 3. 防 AI 味检查项（vibe-hub.org/anti-ai-flavor）

**来源与形状 [事实]**

- 页面：`https://vibe-hub.org/anti-ai-flavor`（HTTP 200，`lang="zh-CN"`，标题「防止 AI 味儿｜看懂 AI slop 并学会修改 · VibeHub」）。
- 页面自述：「把常见的 AI 口癖、套模板的页面和不好用的交互当成词条来认。**每条都给出原句或原页面、正常用法和具体改法**。」并给出总判据：「**单个词、视觉元素或交互问题不能证明作者。判断时要看它是否与其他默认选择成组出现。**」
- 结构：三组，共 **25** 条（本机解析 SSR HTML 的 `data-id`，组内计数 11 / 8 / 6，与页面角标「11 个表现 / 8 个表现 / 6 个表现」一致）。
- **未查到**：条目完整的「正常用法 + 具体改法」正文。SSR HTML 只带条目标题与反例标语（例如「不是 X，而是 Y」条的标语是「直接说这次更新做了什么，别又写成『不是更新，而是重新定义未来』」），完整内容在客户端路由里。本机探测 `/api/agent/v1/search` 用「翻案腔」「稳稳接住」「居中大标题」等词**查不到对应词条**（返回 `count: 0`），说明防 AI 味图鉴**不在 VibeHub 术语解析器的数据里**。改法正文未查到，不猜。

**组一：中文口癖（11）**

| 条目 | 判断动作 |
| --- | --- |
| 稳稳接住 | 不说「稳稳接住我」这类托底式共情，正常说事 |
| 单字动作 | 别用「收一下、提一层、落回去」式单字动词堆，按正常口语说 |
| 什么都要加双引号 | 正常词不必特意加引号 |
| 动不动就来个夸张比喻 | 直说功能解决什么，不用灯塔、桥梁、钥匙式比喻 |
| 提升立意 | 功能是会议纪要就别扯到「人与人连接」 |
| 满口砍一刀、收口、闭环 | 别一开口就是砍一刀、收口、闭环这类工程黑话 |
| 动不动就夸你抓住本质 | 别在用户提问时回「你抓住了本质」 |
| 不是 X，而是 Y | 直说这次做了什么，不写「不是更新，而是重新定义未来」 |
| 先说结论的套话 | 答案简单就直接给，不先铺「我先把结论放在前面」 |
| 每句话都拆成分点 | 能顺说的话不必拆成圆点与编号 |
| 如果你愿意 | 说完就行，别每轮结尾问「要不要再来一版」 |

**组二：页面模板感（8）**

| 条目 | 判断动作 |
| --- | --- |
| 居中大标题 | 先放产品界面，别又是大标题加两个按钮 |
| 三张等宽卡片 | 功能有主次就不要做成三张同尺寸卡片 |
| 蓝紫渐变光球 | 别用与品牌无关的蓝紫渐变与发光球 |
| 框里再套框 | 外面有框，里面别再套三层卡片 |
| 每段都画分割线 | 同一组内容不必每两行画一条线 |
| 左边都要加一条竖线 | 普通说明块不必每块左边加彩色竖线 |
| 又大又黑又挤 | 标题别又粗又挤，先让它好读 |
| Emoji 当图标 | 火箭、星星、盾牌太模板，换正常图标 |

**组三：不好用的交互（6）**

| 条目 | 判断动作 |
| --- | --- |
| 每块都要飞进来 | 往下看内容，别每块都晃一下才出现 |
| 手机端一路堆到底 | 别把桌面侧栏/表格/按钮全挤成长页，手机端更难用 |
| 到处补说明 | 分类名已清楚时，别再补「在这里管理你的知识」这类解释 |
| 同一操作换着叫 | 「新建 / 添加 / 创建」别混用，同一操作叫一个名 |
| 按钮只是摆设 | 筛选点了没变化，就别做成像真的一样 |
| 只放图标，不写名字 | 图标按钮要能认出是删除，手机上没法悬停看提示 |

**内联 vs 引用的边界**

- **能内联进模板的**：上述表格「判断动作」这一列——它是一行一句的**禁令式判据**（事实性指引），不复制条目原文与示例。依据：插件约定「模板不得内嵌任何 skill 正文」（`lib/templates.luau:2-3`），且页面本身要求按「成组出现」判断，属于可直接陈述的规则。
- **只能引用链接的**：条目标题、反例标语、页面自述文本、完整改法。页面未给这组内容明确许可（站点 `/license`、`/terms`、`/about` 均 404，**未查到**；只有其 skill 仓库 `oil-oil/vibe-hub-skill` 的 LICENSE 是 MIT）。按 MIT 仓库的边界，词条内容由网站维护、不属于仓库，**不能当作可随意搬运的素材**（README 明说「术语内容由 VibeHub 网站维护；这个仓库只保留表达规则和术语解析器」）。
- 模板写法：写「不要 X」的判据 + 给 `https://vibe-hub.org/anti-ai-flavor` 链接，不粘贴词条。

## 4. 本机可用的防 AI 味技能

**`lieflat-less-ai-tone`（本机已装）[事实]**

- 路径：`C:/Users/22923/.omp/agent/skills/lieflat-less-ai-tone/`（symlink 指向 `~/.config/magpie/library/skills/lieflat-less-ai-tone`），`omp skill list --json` 可见，`source: native:user`。
- 许可：**CC BY-NC 4.0（署名 · 非商业）**，Copyright (c) 2026 shiujan（`LICENSE`）。**含非商业限制** → 不得内联其规则正文，只可引用调用。
- 契约：三层分工——数得出符号的归脚本（`scripts/detect.py` 正则/结构指标），要理解句意的归语义层（按 `references/semantic-criteria.md` 的封闭判据），机器间共识不够的归人审（比喻贴切度、暗喻、拟人，只列不改）。**工作流强制：先检测 → 出改前报告 → 停 → 等用户回复 → 才改写 → 复测出前后对比报告**（`SKILL.md:12,18-61,63-75`）。
- 脚本：`python3 scripts/detect.py <文件或目录> [--max-hits N] [--json]`，另有 `--candidates --out <json>` 抽语义层候选；`report.py` 出对比报告。本机实测：汉字少于 500 字直接报「汉字过少（<500），检测无意义」；对 629 字样本能报出翻案腔、提示语冒号、结构同构等指标。
- 规则集（`SKILL.md:114-284`）：翻案腔、提示语冒号、起手式、翻译腔四式、顿号罗列过密、相邻句结构同款、破折号指纹等，并有**X 级永不改清单**（序数词小标题、「这意味着」复述、空转句引列表、概括替代、漂亮词黑名单等）——防误改。
- **模板该引用，不该内联**：调用走 `/skill:lieflat-less-ai-tone`；CC BY-NC 的署名与非商业约束 + 面板「不内嵌 skill 正文」约定，两条都指向只引用。

**`taste-skill` / 本机同名技能 `design-taste-frontend` 2.5.1 [事实]**

- 插件形态：`taste-skill@taste-skill` 版本 `2.5.1`，装在 `~/.omp/plugins/cache/plugins/taste-skill___taste-skill___2.5.1/`（`installed_plugins.json`）；市场克隆在 `~/.omp/plugins/cache/marketplaces/taste-skill/`，两份 `scripts/copy-lint.mjs` MD5 一致（`506365ecbb61d77a91d015d19ae830ab`）。仓库 git 最新提交 `v2.5.1`（2026-11-07）。
- 同源技能在 omp 里叫 `design-taste-frontend`：`C:/Users/22923/.omp/agent/skills/design-taste-frontend/`（symlink 指向 `~/.config/magpie/library/skills/design-taste-frontend`），SKILL.md 自称 `tasteskill 2.5.1`；其 `scripts/copy-lint.mjs` 与插件 2.5.1 的 MD5 不同（`e6fb615a…`），**是不同副本**。
- 许可：MIT，Copyright (c) 2026 Leonxlnx（两份 LICENSE 一致）。
- `copy-lint.mjs` 契约：`node <skill>/scripts/copy-lint.mjs <page.html | folder | .md | .txt> [更多文件] [--kind tech|software|gaming|product|place|service] [--json] [--year 2026]`；退出码 0 无 FAIL、1 有 FAIL、2 用法错/读不到文件；**FAIL 阻断**（`gate.mjs` 的 Stop hook 在收尾时跑它）。规则正文在 `references/copy-tells.md`，分代际与「过度修正」反例。
- 覆盖面：**只数英文**。词表 `SLOP`、库存句 `STOCK`、残留 `RESIDUE` 均为英文字面量（脚本 `:192-219`）。本机实测对中文样本（「这不是一次简单的产品更新，而是一场关于效率、协作与未来工作方式的重新定义。稳稳接住你的需求。」）输出 `0 FAIL, 0 WARN`，且把「4 字中文」计成 4 words。**对中文口癖基本不覆盖**，只能当英文页面的补充检查。
- **模板该引用，不该内联**：调用走 `/skill:design-taste-frontend`（或其插件名）；需要直接跑 lint 时写脚本路径与 `--kind` 参数，不内嵌词表。

**`am` 自带中文检查（补充）[事实]**

- `am lint` 的 STE 中文规则会抓中文套话：本机实测对「综上所述，我们赋能团队提效。」报 `[cliche] cliché "赋能"`、`[cliche] cliché "综上所述"`。与 vibe-hub 中文口癖组部分重叠，但粒度不同（am 管句长、段落句数、`的` 连用、英文被动等，不判比喻与模板感）。**可作内联判据的来源，但引的是 am 技能自己的规则，不是模板内联文案**（`SKILL.md:204-211`）。

## 5. 缺装降级

**`answer-me-with-html` 缺装 [事实 + 推断]**

- 仓库已有先例口径（`lib/templates.luau:402`）：缺装或跑不起来 → 出 Markdown 报告，结尾注明「可视化未生成」与原因。**两条路线同用这个口径。**
- **新建设计路线**退化为：**Markdown 结构稿**——方案卡退化为表格或列表文字，可点击选择退化为「列出选项 + 推荐项标注」，术语解释退化为 markdown 词条行。失去的是布局、暗色模式、ask 的点击回读、单文件可分享性（`SKILL.md:20` 的布局全由 CLI 做，缺 CLI 就没有这些）。**[推断]**
- **迭代与术语路线**退化为：**引用术语链接的 Markdown 术语说明页**——`kv` 词条块退化为「术语：一句解释 + 链接」的列表，页面形态消失，但术语链接本身不依赖 am，仍可保留。**[推断]**
- 另一种「跑不起来」是 Node <20（`SKILL.md:61`），降级表现同缺装（agent 需先告知用户装 Node LTS，用户同意后才装）。

**`vibehub` 缺装 [事实]**

- 本机**未装**：`omp skill list --json`（375 个技能）里没有 `vibehub`；`~/.omp/agent/skills`、`~/.agents/skills`、`~/.claude/skills`、`~/.omp/plugins` 均无 `vibehub` 目录。所以**术语路线当前就处在退化态**。
- **术语路线退化为**：**纯文字术语解释**——模板自己写一句通俗解释 + 给 `https://vibe-hub.org/…` 链接，不硬塞术语教学。依据：`/skill:vibehub` 的规则本身要求「用户表达已经准确且没有可补充的术语时，不硬加术语教学」「无法访问 VibeHub 或没有明确匹配时，Skill 会明确说明，不会伪造术语和链接」（`vibe-hub-skill/README.md`「数据与隐私」；`skills/vibehub/SKILL.md`）。术语内容由站点维护，仓库只保留规则与解析器，所以**链接比技能本身更稳定**（README「仓库结构」段）。
- 缺装不影响主任务：术语是可选增强，不是路径依赖（同上 README）。

## 6. 对模板的结论

1. **两条路线都用 `/skill:answer-me-with-html` 出视觉形态，不内联 am 正文。** 模板只写三件事：用哪个模板/组件、产出走默认目录（不覆写 `-o`）、缺装或 Node 不够时退什么。依据：`lib/templates.luau:2-3`、`SKILL.md:71`。
2. **组件形态选项的最小结构 = 三块**：方案卡（`sheet` + 表格 + `ok/no/warn` 徽章）、可点击选择（`ask`，2–6 选项、`*` 标推荐）、术语解释（`kv` + Markdown 外链）。已本机实测渲染通过。依据：第 2 节实测；`SKILL.md:179`、`am help ask`、`am help kv`。
3. **预览只能用本地截图文件。** am 产物是单文件且 CSP 封死远程资源，远程图与远程 iframe 不加载，远程脚本不执行。模板若要求「组件预览」，必须指定本地截图路径，禁止要求远程图。依据：本机产物 CSP 实测、`SKILL.md:139,178`。
4. **防 AI 味：模板内联「一行禁令式判据」，条目原文走链接。** 第 3 节三组 25 条的「判断动作」列可直接写成模板里的禁令；条目标题、反例、完整改法不内联，给 `https://vibe-hub.org/anti-ai-flavor` 链接。依据：`lib/templates.luau:2-3`；站点未给图鉴明确许可（`/license`、`/terms` 404，未查到）。
5. **本机两个防 AI 味技能都只引用、不内联。** `lieflat-less-ai-tone` 是 CC BY-NC 4.0（含非商业限制），且工作流要求「先检测、出报告、等用户回复再改」，模板不能绕过这个节奏去内联改写规则；`taste-skill` 是 MIT 但覆盖的是英文文案，模板用 `/skill:design-taste-frontend` 调用，需要时提示可跑 `copy-lint.mjs`（含 `--kind`）。依据：两者 LICENSE、`SKILL.md`、脚本用法头。
6. **中文口癖的检查靠三层，不要指望一个工具。** am 的 STE 中文检查管句长与套话词（本机实测抓「赋能」「综上所述」）；vibe-hub 管口癖与模板感（成组判断）；lieflat 管中文成稿的 AI 痕迹（但 <500 汉字不检测）。模板把这三层写成「先自检、再出页」，而不是要求一次性全过。
7. **缺装降级写进模板，不写进运行时。** am 缺装 → Markdown 结构稿 + 注明「可视化未生成」；vibehub 缺装 → 纯文字术语解释 + 链接，不硬塞术语。依据：`lib/templates.luau:402`、vibehub README 失败语义。

## 未解决 / 待拍板

1. **vibe-hub 防 AI 味图鉴的许可未查到**。站点无 `/license`、`/terms`、`/about`（均 404）；只有 skill 仓库是 MIT，而词条内容明确由网站维护、不在仓库里。是否可把条目原文搬进模板，需要人拍板——本取证的保守口径是「只引链接 + 内联禁令式判据」。
2. **条目的完整「正常用法 + 具体改法」未查到**。SSR 只给标题与反例标语，客户端路由正文本机未取到；`/api/agent/v1/search` 也查不到这些词条，说明该图鉴不在术语解析器数据里。
3. **`npx skills add oil-oil/vibe-hub-skill` 在 Windows/omp 的实际落点未实测**（本机未装），packs 里若登记 `vibehub`，`localRel` 取哪个相对路径需装一次后确认。
