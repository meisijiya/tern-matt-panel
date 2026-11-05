# 中文技能包全景调研（mattpocock-skills-zh）

> 调研对象：本地已安装技能包 `mattpocock-skills`（中文汉化版）。
> 主安装路径（合约指定以本地副本为准）：
> `C:/Users/22923/.omp/plugins/cache/marketplaces/mattpocock/skills/`
> 对照安装路径（omp 插件 1.3.5）：
> `C:/Users/22923/.omp/plugins/cache/plugins/mattpocock___mattpocock-skills___1.3.5/skills/`
>
> 下文所有 `skills/...` 路径均相对于主安装路径。行号引用本地文件实际行。
> 标注 **[事实]** = 可直接从源文件读出；**[推断]** = 基于事实的推理，需下游确认。

---

## 0. 总览与两安装差异 [事实]

- 技能总数为 **39 个**，分布在 4 个非空目录 + 1 个空目录：
  - `engineering/`：20 个
  - `productivity/`：7 个
  - `misc/`：4 个
  - `in-progress/`：8 个
  - `deprecated/`：0 个（目录仅含 README，说明“被淘汰的技能会被删除”，`skills/deprecated/README.md:1-3`）
- 两份安装（market 缓存 vs 插件 1.3.5）的文件树**存在差异**：
  - `in-progress/software-factory/`（SKILL.md + EXAMPLE-TASKS.md / GIT-HOSTS.md / OBSERVABILITY-PLATFORMS.md / RUNNERS.md / TICKET-TRACKERS.md）**仅存在于 market 缓存，插件 1.3.5 缺失**。
  - 其余 38 个技能两处文件树一致（逐文件 `find` 比对，仅 `software-factory` 6 个文件为差异项）。
  - `in-progress/README.md:9-13` 声称“插件不会给你这些（in-progress 技能）”，但插件 1.3.5 实际包含了除 `software-factory` 外的 7 个 in-progress 技能——**说明 1.3.5 是介于“不含 in-progress”与“含全部 in-progress”之间的中间态**。[推断]
- 上游仓库（合约给定 `https://github.com/devcxl/mattpocock-skills-zh`）与本地副本是否一致**未联网核验**，合约规定本地副本为准。下游需要“最新”时建议重新 `skills add` 并比对。

---

## 1. 技能总表（问题 a）[事实]

下表 `name` = SKILL.md frontmatter 的 `name:` 字段（即斜杠命令名）；`size` = SKILL.md 字节数；`extra` = 除 SKILL.md 外的随包文件。

### engineering/（20）

| dir | name | SKILL.md 字节 | extra 文件 | 一句话描述（来源：SKILL.md description） |
|---|---|---|---|---|
| engineering/ask-matt | ask-matt | 12285 | PHASE-BOUNDARIES.md, agents/ | 技能路由器（`SKILL.md:3`） |
| engineering/code-review | code-review | 7233 | agents/ | 双轴审查 diff：规范 + 规格（`SKILL.md:3`） |
| engineering/codebase-design | codebase-design | 6710 | DEEPENING.md, DESIGN-IT-TWICE.md, agents/ | 深度模块共享词汇（`SKILL.md:3`） |
| engineering/diagnosing-bugs | diagnosing-bugs | 8949 | agents/, scripts/ | 疑难 bug/性能回归诊断循环（`SKILL.md:3`） |
| engineering/domain-modeling | domain-modeling | 3224 | ADR-FORMAT.md, GLOSSARY-FORMAT.md, agents/ | 构建/完善领域模型（`SKILL.md:3`） |
| engineering/grill-with-docs | grill-with-docs | 263 | agents/ | 盘问并生成文档（ADR+术语表）（`SKILL.md:3`） |
| engineering/implement | implement | 634 | agents/ | 基于 spec/tickets 实现（`SKILL.md:3`） |
| engineering/implement-spec | implement-spec | 2815 | agents/ | 实现 /to-spec 与 /to-tickets 的产物（`SKILL.md:3`） |
| engineering/improve-codebase-architecture | improve-codebase-architecture | 6137 | HTML-REPORT.md, agents/ | 扫描深化机会→HTML 报告→盘问（`SKILL.md:3`） |
| engineering/pr | pr | 4229 | CREDITS.md, agents/ | 撰写 PR body 模板（`SKILL.md:3`） |
| engineering/prototype | prototype | 2835 | LOGIC.md, UI.md, agents/ | 可抛弃原型回答设计问题（`SKILL.md:3`） |
| engineering/research | research | 795 | agents/ | 后台 agent 一手来源调研→Markdown（`SKILL.md:3`） |
| engineering/retro | retro | 4149 | agents/ | 编码会话回顾→环境改进建议（`SKILL.md:3`） |
| engineering/setup-matt-pocock-skills | setup-matt-pocock-skills | 7569 | agents/, domain.md, issue-tracker-*.md, triage-labels.md | 仓库级配置（跟踪器/标签/领域文档）（`SKILL.md:3`） |
| engineering/tdd | tdd | 3599 | agents/, mocking.md, tests.md | 测试驱动开发（`SKILL.md:3`） |
| engineering/to-spec | to-spec | 2691 | agents/ | 对话→spec 并发布到跟踪器（`SKILL.md:3`） |
| engineering/to-tickets | to-tickets | 5753 | agents/ | 计划→tracer-bullet ticket（含阻塞边）（`SKILL.md:3`） |
| engineering/triage | triage | 6513 | AGENT-BRIEF.md, OUT-OF-SCOPE.md, agents/ | issue/PR 推过分类角色状态机（`SKILL.md:3`） |
| engineering/wayfinder | wayfinder | 12807 | agents/ | 大块工作→决策 ticket 共享地图（`SKILL.md:3`） |
| engineering/wizard | wizard | 4240 | agents/, template.sh | 生成交互式 bash 向导（`SKILL.md:3`） |

### productivity/（7）

| dir | name | 字节 | extra | 描述 |
|---|---|---|---|---|
| productivity/grill-me | grill-me | 182 | agents/ | 无状态盘问打磨计划（`SKILL.md:3`） |
| productivity/grilling | grilling | 1986 | agents/ | 盘问原语：轮次/前沿/设计树（`SKILL.md:3`） |
| productivity/handoff | handoff | 882 | agents/ | 对话→交接文档（argument-hint，`SKILL.md:4`） |
| productivity/teach | teach | 8763 | GLOSSARY/LEARNING-RECORD/MISSION/RESOURCES-FORMAT.md, agents/ | 跨会话教学（`SKILL.md:3`） |
| productivity/to-questionnaire | to-questionnaire | 2924 | agents/ | 决策缺口→问卷（`SKILL.md:3`） |
| productivity/wait-what | wait-what | 379 | agents/ | 重解释上一条消息（`SKILL.md:3`） |
| productivity/writing-for-agents | writing-for-agents | 12082 | SKILL-MECHANICS.md, agents/ | 为 agent 编写文档参考（`SKILL.md:3`） |

### misc/（4）

| dir | name | 字节 | extra | 描述 |
|---|---|---|---|---|
| misc/git-guardrails-claude-code | git-guardrails-claude-code | 2467 | agents/, scripts/ | Claude Code 危险 git 命令护栏（`SKILL.md:3`） |
| misc/migrate-to-shoehorn | migrate-to-shoehorn | 3002 | agents/ | 测试 `as` 断言→shoehorn（`SKILL.md:3`） |
| misc/scaffold-exercises | scaffold-exercises | 3912 | agents/ | 练习目录结构脚手架（`SKILL.md:3`） |
| misc/setup-pre-commit | setup-pre-commit | 2509 | agents/ | Husky pre-commit 钩子（`SKILL.md:3`） |

### in-progress/（8）

| dir | name | 字节 | extra | 描述 |
|---|---|---|---|---|
| in-progress/chief-of-staff | chief-of-staff | 5095 | agents/ | 长会话协调子 agent+日程（`SKILL.md:3`） |
| in-progress/claude-handoff | claude-handoff | 1327 | agents/ | 对话→后台 agent 接手（argument-hint，`SKILL.md:4`） |
| in-progress/loop-me | loop-me | 2725 | agents/ | 盘问出工作流规格（argument-hint，`SKILL.md:5`） |
| in-progress/setup-ts-deep-modules | setup-ts-deep-modules | 8119 | agents/, dependency-cruiser.config.cjs | dependency-cruiser 接入（`SKILL.md:3`） |
| in-progress/software-factory | software-factory | 6528 | EXAMPLE-TASKS.md, GIT-HOSTS.md, OBSERVABILITY-PLATFORMS.md, RUNNERS.md, TICKET-TRACKERS.md | 软件工厂设计语言（`SKILL.md:3`） |
| in-progress/writing-beats | writing-beats | 5130 | agents/ | 素材→节拍之旅（`SKILL.md:3`） |
| in-progress/writing-fragments | writing-fragments | 3572 | agents/ | 挖掘写作碎片（`SKILL.md:3`） |
| in-progress/writing-shape | writing-shape | 6029 | agents/ | 素材→成篇文章（`SKILL.md:3`） |

---

## 2. 每个技能解决什么问题、产出什么（问题 b）[事实]

> “产出”指技能运行后落到仓库/跟踪器/文件系统的**产物形态**，均可在 SKILL.md 内文或 description 找到依据。

| name | 解决的问题 | 产出（PRODUCES） | 依据 |
|---|---|---|---|
| ask-matt | 用户不知用哪个技能 | 路由建议（不落盘，纯对话） | `SKILL.md:3,15-89` |
| code-review | 分支/PR 是否符合规范与规格 | 并排双轴审查报告（并行子 agent） | `SKILL.md:6-12` |
| codebase-design | 模块接口/接缝设计缺统一词汇 | 设计词汇训练（被其他技能引用，不单独落盘） | `SKILL.md:3,9-15` |
| diagnosing-bugs | 难啃 bug/偶发/回归 | 根因 + 回归测试（脱敏输出） | `SKILL.md:3,9-15` |
| domain-modeling | 领域术语混乱/决策未记录 | 更新 `GLOSSARY.md` 与 `docs/adr/` ADR | `SKILL.md:3,9-15` |
| grill-with-docs | 计划/设计需打磨 | 调用 grilling + domain-modeling，落 ADR/术语表 | `SKILL.md:7`（仅 3 行） |
| implement | 已有 spec/tickets 待实现 | 代码改动（驱动 tdd、收尾 code-review） | `SKILL.md:7-15` |
| implement-spec | 整份 spec 需在集成分支实现 | 集成分支上的代码（任务图并行） | `SKILL.md:7-9,13,36` |
| improve-codebase-architecture | 代码库架构摩擦 | 可视化 HTML 报告 + 候选方案盘问 | `SKILL.md:3,7-9` |
| pr | 写 PR body | PR body 文本（模板） | `SKILL.md:6-12` |
| prototype | 设计问题需可运行答案 | 可分享 HTML（逻辑/UI 变体），保留为 `prototype/<name>` 分支 | `SKILL.md:14-17,52` |
| research | 需一手来源调研 | 带引用的 Markdown 笔记文件 | `SKILL.md:9-13` |
| retro | 会话后如何改进 agent 环境 | 环境改进建议（按严重度排序） | `SKILL.md:7-9` |
| setup-matt-pocock-skills | 工程技能缺仓库级配置 | `docs/agents/*.md` + `CLAUDE.md/AGENTS.md` 的 `## Agent skills` 块 | `SKILL.md:3,7-12,步骤4-5` |
| tdd | 测试先行构建 | 红-绿-重构测试（垂直切片） | `SKILL.md:3,9-13` |
| to-spec | 对话未固化为 spec | 一份 spec（发布到 issue 跟踪器） | `SKILL.md:3,9-11` |
| to-tickets | 计划未拆成可执行 ticket | 一组 tracer-bullet ticket（声明阻塞边） | `SKILL.md:3,38,60-65` |
| triage | 外来 issue/PR 未分类 | 分类标签 + agent 就绪任务简报 | `SKILL.md:3,9-11` |
| wayfinder | 大块模糊工作（>1 会话） | 共享地图（wayfinder:map）+ 决策 ticket（wayfinder:<type>） | `SKILL.md:7,13,103-127` |
| wizard | 需人类执行的繁琐步骤 | 交互式 bash 向导脚本 | `SKILL.md:7-13` |
| grill-me | 无工作目录时盘问 | 设计树（不落盘） | `SKILL.md:7` |
| grilling | 盘问原语 | 设计树（轮次/前沿） | `SKILL.md:3,9-15` |
| handoff | 交接给另一 agent | 临时目录交接文档（含建议技能） | `SKILL.md:7-9` |
| teach | 跨会话教概念 | 教学工作区文件（lessons/ 等） | `SKILL.md:7-9` |
| to-questionnaire | 决策缺口在他人脑中 | Markdown 问卷 | `SKILL.md:7-9` |
| wait-what | 上条消息未接住 | 重解释（对话） | `SKILL.md:7` |
| writing-for-agents | 写 agent 文档缺规范 | 文档写作规则参考（被写技能时引用） | `SKILL.md:3,9-13` |
| git-guardrails-claude-code | 危险 git 命令无护栏 | PreToolUse 钩子配置 | `SKILL.md:3,7-9` |
| migrate-to-shoehorn | 测试 `as` 断言类型不安全 | 迁移后的测试代码 | `SKILL.md:3,7-9` |
| scaffold-exercises | 练习脚手架 | 练习目录结构 + commit | `SKILL.md:3,7-9` |
| setup-pre-commit | 缺 pre-commit 钩子 | Husky/lint-staged/Prettier 配置 | `SKILL.md:3,7-9` |
| chief-of-staff | 长期目标需协调 | 子 agent 编排 + 日程（长会话） | `SKILL.md:3,7-9` |
| claude-handoff | 后台 agent 接手 | 交接摘要 + 启动 `claude --bg` | `SKILL.md:7-11` |
| loop-me | 盘问出工作流规格 | 工作流规格文档（有状态） | `SKILL.md:7-9` |
| setup-ts-deep-modules | TS 仓库缺深度模块约束 | dependency-cruiser 规则 + 验证 | `SKILL.md:3,7-9` |
| software-factory | 设计软件工厂缺共同语言 | 设计语言参考（讨论用，不落盘） | `SKILL.md:3,7-11` |
| writing-beats | 文章需节拍之旅 | 逐节拍文章文档 | `SKILL.md:9-13` |
| writing-fragments | 写作碎片挖掘 | 碎片 Markdown 文档 | `SKILL.md:9-13` |
| writing-shape | 素材塑形成文章 | 独立文章文档 | `SKILL.md:9-13` |

---

## 3. 技能间联动与继承链（问题 c）[事实]

### 3.1 总路由器
`ask-matt`（`SKILL.md:15-89`）是唯一的顶层路由器，定义了**主干流程**与**入口匝道**，并列出底层词汇。它本身不产出文件，只把用户导向具体技能。

### 3.2 主干流程（想法 → 交付）依赖链 [事实，来自 ask-matt/SKILL.md:15-40]
```
grill-with-docs ──► [可选 handoff ⇄ prototype ⇄ handoff]
        │
        ▼  (多会话构建?)
   to-spec ──► to-tickets ──┬─► implement  (逐 ticket，每张间 /clear)
                           └─► implement-spec (任务图并行，集成分支)
        │                         │
        └── 两者都驱动 ──► tdd ──► code-review
                                        │
                                        ▼
                                      pr  (模型调用，写 PR body)
                                        │
                                        ▼
                                      retro (闭合循环)
```
- 关键文本依据：`SKILL.md:19`（grill-with-docs 起点）、`:25`（to-spec→to-tickets）、`:26-27`（implement / implement-spec 二选一）、`:30`（tdd + code-review）、`:30-33`（pr）、`:34`（retro）。
- 上下文卫生约束：`SKILL.md:37-40`（to-tickets 前保持单窗口；逼近“智能区”时 /compact）。

### 3.3 入口匝道（汇入主干）[事实，ask-matt/SKILL.md:42-55]
- bug/请求堆积 → `triage` → `implement`（`:46-49`）
- 有东西坏了 → `diagnosing-bugs` →（修完）`retro` → 必要时 `improve-codebase-architecture`（`:50-51`）
- 庞大模糊工作 → `wayfinder`（绘制地图）→ 地图清晰后交接给 `to-spec` 并入主干（`:52-55`）

### 3.4 底层词汇（被其他技能引用的参考，本身不落盘）[事实，ask-matt/SKILL.md:80-86]
- `domain-modeling`：被 `grill-with-docs` 驱动，是 `GLOSSARY.md` 的唯一维护者。
- `codebase-design`：被 `tdd`、`improve-codebase-architecture` 引用（深度模块词汇）。
- `grilling`：盘问原语，被 `grill-me`、`grill-with-docs`、`triage`、`wayfinder`、`improve-codebase-architecture`、`loop-me` 在内部调用（`SKILL.md:86`；`grill-with-docs/SKILL.md:7`；`triage` 见 README；`wayfinder/SKILL.md:79,111,124`；`loop-me/SKILL.md:7`）。
- `writing-for-agents`：被 `retro` 调用（`ask-matt/SKILL.md:34-36` 步骤1）。

### 3.5 显式“调用 Skill 工具并传入 X”的硬链接 [事实]
| 调用方 | 被调用 | 依据 |
|---|---|---|
| grill-with-docs | grilling, domain-modeling | `grill-with-docs/SKILL.md:7` |
| implement | tdd, code-review | `implement/SKILL.md:11-15` |
| implement-spec | code-review | `implement-spec/SKILL.md:38-39` |
| improve-codebase-architecture | codebase-design | `improve-codebase-architecture/SKILL.md:9-11` |
| retro | writing-for-agents | `ask-matt/SKILL.md:34-36` |
| setup-ts-deep-modules | codebase-design | `setup-ts-deep-modules/SKILL.md:9-11` |
| triage / wayfinder / loop-me / grill-with-docs | grilling (+domain-modeling) | `ask-matt/SKILL.md:86`；`wayfinder/SKILL.md:79,111,124`；`loop-me/SKILL.md:7` |
| to-spec / to-tickets / triage / implement / implement-spec | setup-matt-pocock-skills（前置依赖） | 多处“若未配置请运行 /setup-matt-pocock-skills”，如 `to-spec/SKILL.md:9`、`to-tickets/SKILL.md:9`、`triage/SKILL.md:9`、`implement-spec/SKILL.md:9` |

### 3.6 文本依赖图（入口/终端标注）[事实]
```
[入口 / 路由器]
  ask-matt ──────────────────► (一切)
  setup-matt-pocock-skills ──► 所有读写跟踪器的技能的前置配置（非流程节点，是环境依赖）

[入口匝道 / 起点]
  triage        ──► implement ──► tdd ──► code-review ──► pr ──► retro
  diagnosing-bugs ──► retro ──► improve-codebase-architecture ──► grill-with-docs
  wayfinder ──► to-spec ──► to-tickets ──► {implement | implement-spec} ──► tdd ──► code-review ──► pr ──► retro

[主干 / 中间]
  grill-with-docs ──(内部)──► grilling + domain-modeling
  to-spec ──► to-tickets ──► implement / implement-spec

[终端 / 收尾]
  retro      （循环闭合，无下游）
  pr         （提交前最后一步，模型调用）
  code-review（多路径汇聚的审查点，下游是 pr 或修复）

[底层词汇 / 被引用，不独立成流程]
  grilling, domain-modeling, codebase-design, writing-for-agents

[独立 / 旁路（不汇入主干）]
  research, prototype, wizard, handoff, claude-handoff, teach, to-questionnaire,
  wait-what, grill-me, chief-of-staff, loop-me, software-factory,
  writing-beats/fragments/shape, git-guardrails-claude-code, migrate-to-shoehorn,
  scaffold-exercises, setup-pre-commit, setup-ts-deep-modules
```
**入口点**：ask-matt（路由）、triage、diagnosing-bugs、wayfinder、grill-with-docs（用户手动起点）。
**终端点**：retro、pr、code-review（汇聚收尾）。
**枢纽/扇出点**：to-tickets（分叉 implement/implement-spec）、code-review（多源汇聚）、grilling（多技能内部调用）。

---

## 4. 调用约定：`/技能名` 是否解析到技能（问题 d）[事实]

### 4.1 两种可达性
每个技能在 `engineering/README.md:6-8`、`productivity/README.md:6-8` 被分为两类：
- **用户调用（User-invoked）**：frontmatter 带 `disable-model-invocation: true`，**只有用户主动输入才可达**。依据 `engineering/README.md:7`：“只有你输入它们时才可达（Claude Code：`disable-model-invocation: true`）”。
- **模型调用（Model-invoked）**：无该标志，模型或用户均可调用，靠丰富触发措辞让模型主动拿起来用（`engineering/README.md:21`）。

### 4.2 `/技能名` 是否解析到技能：**是（全部 39 个）** [事实+推断]
- `name:` 字段即斜杠命令名（如 `name: to-tickets` → `/to-tickets`）。所有 SKILL.md 均含 `name:`。
- `disable-model-invocation: true` **只关闭模型的隐式自动调用**，**不关闭斜杠调用**。用户在任何技能上敲 `/<name>` 都能触发。换言之：`/技能名` 对所有 39 个技能都解析；差别仅在“模型能否未经用户许可自行调用”。
- 4 个技能额外带 `argument-hint`（slash 后的参数提示）：`handoff`、`teach`、`claude-handoff`、`loop-me`（分别见各自 `SKILL.md:4-5`）。

### 4.3 用户调用清单（24 个，含 `disable-model-invocation: true`）
engineering：ask-matt, grill-with-docs, implement, implement-spec, improve-codebase-architecture, retro, setup-matt-pocock-skills, to-spec, to-tickets, triage, wayfinder（11）
productivity：grill-me, handoff, teach, to-questionnaire, wait-what（5）
in-progress：chief-of-staff, claude-handoff, loop-me, setup-ts-deep-modules, software-factory, writing-beats, writing-fragments, writing-shape（8）
合计 24。

### 4.4 模型调用清单（15 个，无该标志）
engineering：code-review, codebase-design, diagnosing-bugs, domain-modeling, pr, prototype, research, tdd, wizard（9）
productivity：grilling, writing-for-agents（2）
misc：git-guardrails-claude-code, migrate-to-shoehorn, scaffold-exercises, setup-pre-commit（4）
合计 15。

### 4.5 其他调用形式
- 部分技能通过“调用 Skill 工具并传入 `<name>`”被其他技能内部唤起（见 3.5），这是一种**技能间编程式调用**，非斜杠。
- `setup-matt-pocock-skills` 明确是“提示驱动，非确定性脚本”（`SKILL.md:7`），即它靠对话引导而非自动执行。

---

## 5. 哪些适合做面板“动作”、哪些不适合（问题 e）[事实+推断]

> 判定标准：**面板动作** = agent 可“一键触发并产出明确仓库/跟踪器产物”，无需长轮次人机对话、非纯路由/参考/配置。

### 5.1 适合做面板动作（agent 可直接执行，有落盘/可执行产物）
| 技能 | 动作性质 | 依据 |
|---|---|---|
| to-spec | 生成 spec issue | `SKILL.md:9-11` |
| to-tickets | 生成 ticket 群（阻塞边） | `SKILL.md:38,60-65` |
| implement | 写代码（逐 ticket） | `SKILL.md:7-15` |
| implement-spec | 集成分支实现 | `SKILL.md:7-9,13` |
| code-review | 双轴审查报告 | `SKILL.md:6-12` |
| tdd | 写测试 | `SKILL.md:3,9-13` |
| prototype | 生成 HTML 原型 | `SKILL.md:14-17` |
| research | 写调研笔记 | `SKILL.md:9-13` |
| triage | 分类 + 任务简报 | `SKILL.md:9-11` |
| diagnosing-bugs | 诊断 + 回归测试 | `SKILL.md:3,9-15` |
| improve-codebase-architecture | HTML 报告 | `SKILL.md:3,7-9` |
| wayfinder | 画地图 + ticket | `SKILL.md:7,103-127` |
| retro | 环境建议 | `SKILL.md:7-9` |
| pr | PR body | `SKILL.md:6-12` |
| wizard | 生成向导脚本 | `SKILL.md:7-13` |
| scaffold-exercises | 练习脚手架 | `SKILL.md:3,7-9` |
| setup-pre-commit | 钩子配置 | `SKILL.md:3,7-9` |
| git-guardrails-claude-code | 护栏配置 | `SKILL.md:3,7-9` |
| migrate-to-shoehorn | 测试迁移 | `SKILL.md:3,7-9` |
| setup-ts-deep-modules | cruiser 接入 | `SKILL.md:3,7-9` |
| writing-shape / writing-beats / writing-fragments | 写作产物 | 各自 `SKILL.md:9-13` |
| teach | 教学工作区 | `SKILL.md:7-9` |
| loop-me | 工作流规格 | `SKILL.md:7-9` |
| to-questionnaire | 问卷文档 | `SKILL.md:7-9` |
| handoff / claude-handoff | 交接文档/启后台 | `handoff/SKILL.md:7-9`；`claude-handoff/SKILL.md:7-11` |

### 5.2 不适合做面板动作（路由 / 配置 / 参考 / 长轮次 HITL 对话）
| 技能 | 不适合原因 | 依据 |
|---|---|---|
| **ask-matt** | 纯路由器，不落盘 | `SKILL.md:3,15-89` |
| **setup-matt-pocock-skills** | 一次性仓库配置，提示驱动 | `SKILL.md:3,7` |
| **grilling / grill-with-docs / grill-me** | 需轮次人机对话（前沿/设计树），非一键动作 | `grilling/SKILL.md:9-15`；`ask-matt/SKILL.md:80-86` |
| **wait-what** | 被动重解释，触发型而非主动动作 | `SKILL.md:7` |
| **software-factory** | 设计讨论的共享语言参考，不落盘 | `SKILL.md:3,7-11` |
| **codebase-design / domain-modeling / writing-for-agents** | 底层词汇/参考，被其他技能调用，不宜独立成按钮 | `ask-matt/SKILL.md:80-86` |
| **chief-of-staff** | 长会话编排（跨多轮），非单动作 | `SKILL.md:3,7-9` |

**[推断]** 面板“动作按钮集”应优先取自 5.1；路由（ask-matt）、配置（setup-*）、长轮次盘问（grilling 系）、参考词汇（codebase-design 等）更适合做“模式/入口”或后台能力，而非可点击的一次性动作。这与 issue #1 的 wayfinder 地图模型（地图=wayfinder:map，ticket=wayfinder:<type>）天然契合：把 to-spec/to-tickets/wayfinder/implement/code-review/retro 做成地图驱动的动作，把 grill 系作为“进入地图前的打磨”入口。

---

## 6. 包内已原生存在的“阶段/进度”语义（问题 f）[事实]

这些语义可直接被游戏化面板复用，无需重新发明：

### 6.1 主干阶段链：想法 → 交付 [ask-matt/SKILL.md:15]
- 阶段顺序：grill-with-docs → to-spec → to-tickets → implement/implement-spec → tdd → code-review → pr → retro。
- 明确的“阶段边界（phase boundary）”概念：`ask-matt/SKILL.md:69-71`、`PHASE-BOUNDARIES.md:1-5`，阶段边界上 5 个选项（继续 / /clear / /handoff / /compact / 拆分 subagent）。
- “智能区（smart zone）”上限概念：`ask-matt/SKILL.md:40`（约 150k token，逼近时 /compact）。

### 6.2 前沿（frontier）[多技能共识]
- `grilling`：设计树的前沿 = 前提已确定的决策，可立即问（`ask-matt/SKILL.md:86`）。
- `to-tickets`：按前沿推进 = 阻塞项已完成的 ticket（`SKILL.md:65`）。
- `implement-spec`：任务图的前沿 = 可立即领取的 ticket（`SKILL.md:13,36`）。
- `wayfinder`：前沿 = 打开、未阻塞、未分配的子 ticket，即已知领域边界（`SKILL.md:69`）；本地跟踪器前沿查询 `issue-tracker-local.md:28`、GitHub `issue-tracker-github.md:48`、GitLab `issue-tracker-gitlab.md:44`。
- **这是 issue #1 wayfinder 地图“前沿=open+unblocked+unassigned”的直接来源。**

### 6.3 战争迷雾（fog of war）/ 毕业（graduate）[wayfinder/SKILL.md:82-101]
- 地图故意不完整：活跃 ticket 之外是“战争迷雾”（`SKILL.md:82-84`）。
- 解决一个 ticket 清除前方迷雾，把可明确内容“毕业”为新 ticket（`SKILL.md:84-85,91,126`）。
- “尚未明确（unclear）”区存模糊影像；迷雾 vs ticket 的判定标准是“现在能否精确陈述问题”（`SKILL.md:88-91`）。
- “范围外（out of scope）”一旦排除永不再毕业，前沿停在目的地（`SKILL.md:97-101`）。
- **可直接映射为面板的“已探索/迷雾/范围外”三态。**

### 6.4 地图 / 阻塞边 / 任务图 [wayfinder + to-tickets + implement-spec]
- 共享地图：`wayfinder:map` 标签，子 ticket 用 `wayfinder:<type>`（`SKILL.md:7,113-114,123`）。
- 阻塞边：tracker 原生依赖；全部阻塞者关闭即解除阻塞（`wayfinder/SKILL.md:69`；`to-tickets/SKILL.md:38,62-63`）。
- 任务图：implement-spec 把 ticket 读作有阻塞关系的任务图（`implement-spec/SKILL.md:13`）。
- **与 issue #1 完全一致：地图=wayfinder:map issue，tickets=子 issue 带 wayfinder:<type>，阻塞=GitHub 原生依赖。**

### 6.5 分类状态机（triage）[triage/SKILL.md:9-11]
- issue/PR 推过“分类角色组成的小型状态机”：分类→验证→必要时盘问→写出 agent 就绪任务简报。
- PR 即“带代码的 issue”，共用同一状态机（`SKILL.md:11`）。
- **可复用为面板 ticket 的生命周期状态。**

### 6.6 轮次（rounds）/ 设计树（design tree）[grilling，ask-matt/SKILL.md:86]
- 盘问以轮次推进，每轮问完整个前沿；讨论映射为设计树，每决策分支出子决策。
- **可复用为面板“决策树展开进度”。**

---

## 7. 关键结论速查（供下游决策 ticket）

1. **总量**：39 技能（eng20 / prod7 / misc4 / in-prog8 / deprecated0）。
2. **两安装差异**：仅 `in-progress/software-factory` 存在于 market 缓存、缺失于插件 1.3.5；其余一致。本地副本为准。
3. **调用**：`/技能名` 对全部 39 个都解析；`disable-model-invocation: true`（24 个）仅关模型自动调用，不关斜杠。4 个带 `argument-hint`。
4. **入口/终端**：入口 ask-matt/triage/diagnosing-bugs/wayfinder/grill-with-docs；终端 retro/pr/code-review；枢纽 to-tickets、code-review、grilling。
5. **面板动作候选**：5.1 的 25 个可执行技能；避免把 ask-matt、setup-*、grilling 系、codebase-design/domain-modeling/writing-for-agents、chief-of-staff、software-factory、wait-what 做成一次性按钮。
6. **可复用进度语义**：阶段链、前沿、战争迷雾/毕业、地图/阻塞边/任务图、triage 状态机、轮次/设计树——与 issue #1 wayfinder 模型同构，可直接复用。

---
*调研完成于本地安装副本；未联网比对上游 devcxl/mattpocock-skills-zh，未找到（上游一致性）处已标注。*
