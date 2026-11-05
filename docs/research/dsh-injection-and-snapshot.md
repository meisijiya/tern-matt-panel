# DSH 版注入模板与任务板快照取证（issue #6）

- 取证对象：https://github.com/FeatherHunter/dsh-mattpocock-skills-deck （分支 `main`，取证时 tree sha `7be6c68b07eb81b108ce0f6584b7bfaf12dbe3ce`）
- 取证方式：按工单要求**未做 git clone**，全部经 `raw.githubusercontent.com` 原文与 `api.github.com` contents/tree 接口只读获取；下文 `path:line` 均为 2026-11-05 读取的 `main` 版本行号。
- 范围：只答「注入了什么文本」「任务板数据从哪来、票有哪些字段、blocked/frontier/map-detail 怎么算」，不设计 tern 版本。

---

## 一、已定位

### A. 技能卡（skill card）点击注入的文本

**结论：技能卡注入的文本就是一行 `/技能名`，没有模板、没有插值变量。**

| 事实 | 出处 |
| --- | --- |
| 技能页签「注入聊天」按钮：`onLoad: function (name) { inject(st, '/' + name) }` | `src/client/views/SkillsTab.ts:79` |
| 悬浮技能列表点击：`onClick: function (e) { e.stopPropagation(); inject(s, '/' + sk.name); closeSkillPop() }`（`aria-label` 也是 `'/' + sk.name`） | `src/client/floating/SkillFloatList.ts:128-129` |
| 行内注入按钮渲染（文案 key `sd.injectChat`） | `src/client/views/skillDetail/PixelSkillRow.ts:35-41` |
| 头注释自述「注入＝把 /技能名 写进对话输入框的老行为 inject」 | `src/client/views/SkillsTab.ts:6-7` |

**注入通道 `inject()`**：`src/client/kernel/api-io.ts:62-67`
- `:64` deck 关闭的工作区先经 `deckPromptFiltered(text, true)` 去掉 deck 工具提醒行（实现在 `src/client/kernel/deck-prompt-filter.ts`）；
- `:65` `withTrailingNewline` 补尾换行；
- `:66` 走 `st.injector(bodyText)` 并弹「已注入」toast；
- `:67` 没有 injector 时降级复制到剪贴板。

**`st.injector` 落点**：`src/client/statusbar/StatusBar.ts:146` 与 `:153` —— `s.injector = props.inputActions.setDraft`，即写进对话输入框草稿。

### B. 票（ticket）点击注入的文本

**结论：点票据行的「执行/诊断/…」按钮，注入的是一份动作模板渲染结果；模板真源是 `config/prompts/*.yaml`，构建期编译成 `src/client/kernel/prompt-data.ts`（不入库），运行时按占位符插值。**

调用链（每步 path:line）：

1. 行级动作按钮 `src/client/kernel/row-actions.ts:123` `mkRowAction` → `:150` `onClick: function (e) { e.stopPropagation(); inject(st, text) }`。
2. 注入文本由 `rowActionText`（`src/client/kernel/row-actions.ts:83`）产出：
   - 标签分类 `rowActionKind`（`:49`）：无标签/`needs-triage`→diagnose、`ready-for-human`→takeover、`needs-info`→supplement、`bug`→fix、`wayfinder:grilling`→discuss、`wayfinder:research`→research、`wayfinder:prototype`→prototype、`wayfinder:task`→execute、`ready-for-agent`→implement（阶梯实现 `:49-65`）。
   - 容器（探索地图/规格）先走三态文案 `containerPromptText`（`row-actions.ts:94-95`；实现 `src/client/kernel/container-view.ts:106-123`，用 `promptTextFor(st,'specComplete'|'specSplit'|'specExecute', …)`）。
   - 其余八种：`renderTemplate('diagnose'|'takeover'|'supplement'|'fix'|'discuss'|'research'|'prototype', { url: url }, st)`（`row-actions.ts:111-117`）；implement 直接 `promptText('tpl.implement', { url })`（`:118`）；兜底 `startText`（`:119`，实现在 `src/client/kernel/router.ts:185-207`，其中 execute 模板带 `number/url/title` 三变量，见 `:207`）。
3. `renderTemplate`（`src/client/kernel/config.ts:66-79`）：`tplText` 取文（`:64` = 用户覆盖文本 → `TPL_DEFAULT`），先把 `{{x}}` 转义成字面 `{x}`，再用已知占位符替换 `{x}`；未知占位符原样保留。
4. `TPL_DEFAULT`（`config.ts:51-63`）默认文本全部转发 `promptTextFor(st, 'tpl.X')`（`src/client/kernel/prompts-backend.ts:95`：`promptText(id, backendParamsFor(st, params))`）。
5. `promptText`（`src/client/kernel/prompts.ts:176-188`）按语言链取正文并插值，替换正则 `\{(\w+)\}` 在 `:187`；数据来自 `PROMPTS = PROMPT_TEMPLATE_DATA`（`prompts.ts:28`）。
6. 用户可覆盖的 11 条动作模板与优先级：`src/client/kernel/settings-templates.ts:55` `TPL_SETTING_NAMES` 清单（文件→旧 localStorage 键 `dsws.templates`→默认，读口 `config.ts:64` `tplText`）。

**模板真源（config/prompts）与生成模块（两条路都给）**

- 源之一 `config/prompts/ticket-action-templates.yaml`（族 `ticket-action-templates`），各模板起始行：
  `tpl.diagnose:1`、`tpl.discuss:54`、`tpl.execute:63`、`tpl.fix:72`、`tpl.handoff1:113`、`tpl.handoff2:126`、`tpl.implement:157`、`tpl.prototype:198`、`tpl.research:221`、`tpl.supplement:230`、`tpl.takeover:291`。
- 跨族公共小节 `config/prompts/shared-sections.yaml`：`sharedTools:14`、`investigation:28`、`mapTicketAdvanceOpening:47`、`mapTicketAdvanceWrapUp:66`、`mapTicketAdvance:77`、`repoBootstrap:90`、`firstPrinciples:106`。模板里写 `{{shared:<id>}}`，**读取时就展开成完整正文**（`shared-sections.yaml:2`；展开实现 `scripts/lib/prompt-config.mts:298` `expandSharedSections`，标记正则 `:246`，小节 id 清单 `:233`）。
- id 与占位符单源：`scripts/lib/prompt-config.mts:169-202` `PROMPT_TEMPLATE_IDS`（`tpl.*` 各条在 `:187-195`、`tpl.handoff1` `:196`、`tpl.handoff2` `:197`，占位符分别为 `[url]`/`[ts]`/`[path]`）；五族清单 `:160-166`。
- 生成器：`scripts/generate-prompt-config.mts:41` `OUT_PATH = src/client/kernel/prompt-data.ts`；文件头 `:4-7` 说明「写成 … prompt-data.ts —— 这份生成物不入库，构建时现场生成」，`:14-17` 说明它由 `scripts/build.mts` 登记成内核模块 `promptData` 拼进 `src/client/index.ts`。**该生成物在 main 树中不存在（见「未找到」）。**
- 消费端：`src/client/kernel/prompts.ts:28` `PROMPTS = PROMPT_TEMPLATE_DATA`。

**模板原文（节选，`config/prompts/ticket-action-templates.yaml`，zh 正文）**

`tpl.diagnose`（`:6-30`，占位符 `url`）：

```text
/triage
{url}

{{shared:firstPrinciples}}

按 /triage 技能诊断这张 issue；诊断不等于修复，只弄清问题与分流：不改业务代码、不开始实施。
…
{{shared:investigation}}
…
{{shared:sharedTools}}
```

`tpl.implement`（`:162-181`，占位符 `url`）：

```text
/implement
{url}

按 /implement 技能实施这张票。
…
{{shared:firstPrinciples}}
…
{{shared:sharedTools}}
```

（`tpl.execute`/`tpl.discuss`/`tpl.research` 正文整段就是 `{{shared:mapTicketAdvance}}`，见 `:63-71`、`:54-62`、`:221-229`。）

**插值变量清单（已定位）**

| 模板 | 变量 | 出处 |
| --- | --- | --- |
| `tpl.diagnose/fix/implement/discuss/research/prototype/execute/takeover/supplement` | `{url}` | `config/prompts/ticket-action-templates.yaml` 各条 `placeholders`；`scripts/lib/prompt-config.mts:187-195` |
| `tpl.handoff1` | `{ts}` | `ticket-action-templates.yaml:113-115`；`prompt-config.mts:196` |
| `tpl.handoff2` | `{path}` | `ticket-action-templates.yaml:126-128`；`prompt-config.mts:197` |
| execute（用户可编辑稿） | 允许 `number/url/title` | `src/client/kernel/config.ts:42` `TPL_PH.execute`；强制 `url` 见 `TPL_REQUIRED` `:46` |
| 所有模板 | `{cli}`/`{cliBrand}` 有中性兜底，不会裸奔 | `src/client/kernel/prompts.ts:32`（`VOCABULARY_DEFAULT`）、`:151`（`vocabularyParamsFrom`） |
| 允许的占位符全集 | `url number title ts file path` | `src/client/kernel/config.ts:39` `PH` |

公共小节在生成时已整段展开，所以**运行时注入的正文里不再有 `{{shared:*}}`**（未展开会当场抛错：`scripts/lib/prompt-config.mts:340`、`:349`）。

### C. 检查项动作 `inject-prompt`（附带，非卡片/票，但同一注入机制）

- 动作枚举 `src/client/kernel/actions.ts:23`：`inject-prompt / open-url / rpc / form / refresh / wizard / contract-op`。
- 分发 `actions.ts:53-80`：`inject-prompt` 需要 `action.prompt` 字符串；优先 `ctx.resolvePrompt(action.prompt, promptArgs)` 解析完整引导文案（`:60-65`），`null` 表示什么都不注入，否则回落把 `action.prompt` 原样注入；最后 `await ctx.inject(promptText, promptArgs)`（`:79`）。

### D. 任务板数据从哪来（fetch 链路）

1. **客户端入口**：`src/refresh/rooms/client/snapshot-sync.ts:149` `loadSnapshot`；`:199-202` `host.call('wf.snapshot', args)`（`force` 时改打 `wf.refresh`）。
2. **宿主电话注册**：`src/host/index.ts:248` `harness.handle('wf.snapshot', …)`；装配处 `src/host/index.ts:228`（`createSessionSnapshot`，同时注入 `computeLevels/groupTickets`，`_group()` 实现加载在 `:318` → `src/host/ticketGrouping.ts`）。
3. **快照处理器**：`src/refresh/rooms/host/session-snapshot-cache.ts:80` `createSessionSnapshot`、`:111` `handleSnapshot`。
4. **数据主来源 = 本地快照库首屏回放**，库没有才在线重建（`session-snapshot-cache.ts:133-134` 注释「#1870 面板数据的主来源是本地快照库…工作副本只在库里还没有这一轮数据时兜底」；实现 `src/refresh/rooms/host/snapshot-library-first-screen.ts`）。
5. **在线重建编排**：`src/host/tracker/snapshot.ts:198` `createSnapshotComposer`、`:277` `composeSnapshot`；`tracker.list(ref, { state: 'open' }, ctx)` 取全量开放票（`:316`）；开放地图的子票按容器补拉（工作集，`:325-360`）；组装 `assembleSnapshot(ref, rows)`（调用 `snapshot.ts:368`；实现 `src/host/tracker/snapshotAssemble.ts:106`）；deck 派生 `deriveDeck(snapshot)`（调用 `snapshot.ts:373`；实现 `src/tracker/deck-derive.ts:260`）。
6. **后端接口（契约）**：`src/tracker/contract/index.ts:18-26` `Tracker` typedef —— `list` `:22`、`counts` `:23`、`listPage` `:24`、`get` `:25`、`getDependencies` `:26`；`listSubIssues` `:56`。实现按「unsupported 诚实回」（`:7-14`）。
7. **注册表**：`src/tracker/registry/core.ts:149` `get(id)`、`:212` `describe(handle, backendId)`（宿主两处分别在 `session-snapshot-cache.ts:152-155`、`:325-328` 调 `reg.describe({cwd}, backendId)`）。
8. **GitHub 后端实现**：`src/tracker/rooms/github/read/issues.ts:126` `listIssues`（房间目录还有 `read/maps.ts`、`read/sub-issues.ts`、`read/issues-rest-list.ts` 等，REST 降级在房间内收口）。
9. **只读会话封装（列表/地图/索引三条读路径）**：`src/refresh/rooms/host/issue-list-fetch.ts` —— `fetchMaps` `:147`（`session.list(ref, { labels:['wayfinder:map'], state:'open' }, ctx)` `:149`）、`fetchIssues` `:170`（`session.list(ref, undefined, ctx)` `:172`）、索引分页 `session.listPage` `:199-220`；文件头 `:7-11` 说明「列表→session.list、地图票→session.list、索引→session.listPage；gh 直调三级兜底已删」。
10. **状态口径升格**：`src/host/index.ts:164-165` `upcaseState/upcaseSnapStates`（composer 归一的 `open/closed` 在此升格为客户端要的 `OPEN/CLOSED`）。
11. **地图详情按需取子票**：`wf.mapTickets` 注册 `src/host/index.ts:230`；实现 `src/host/mapTickets.ts:26-30`（只调契约 `listSubIssues`，翻页拉全一张地图的子票）；旧的单票 GraphQL 查询串在 `src/host/index.ts:45` `QUERY`（`subIssues/blockedBy` 字段就在这里声明）。

### E. 一张票带哪些字段（field list）

| 层次 | 字段 | 出处 |
| --- | --- | --- |
| 契约行 `Issue` | `key, effortId, type('issue'\|'map'\|'spec'), title, state('open'\|'closed'), body, url, createdAt, updatedAt, closedAt, parentKey, author?, assignees?, labels?(name/color/description), milestone?, customFields?, reason, blockedBy?(IssueRef[]), comments?, isPullRequest?, mergedAt?, reviews?` | `src/shared/tracker/shape.ts:213-239` |
| 列表行（快照 `issues`/行数据） | `number, title, state('OPEN'\|'CLOSED'), assignees(login[]), labels({name,color}[]), author?, updatedAt, createdAt`，PR 额外 `isPullRequest, mergedAt` | `src/refresh/rooms/host/issue-list-fetch.ts:73-87` `rowOf` |
| 地图子票（GraphQL 原始行归一） | `number, type, state('OPEN'\|'CLOSED'), claimedBy(assignees[0].login 或 ''), blockedBy(number[]), blocks(number[]), labels(name[]), url, progress(## 进度 N%，null=未表达)` | `src/host/mapBody.ts:123-140` `mapTicket`；GraphQL 字段来源 `src/host/index.ts:45` |
| 快照行归一化补格 | `number`（由 key 折）、`blockedBy` 压成数字数组、`blockedByRefs`（阻塞者 key/title/status 旁表）、`blocks`（缺省 `[]`）、`claimedBy`（assignees 派生，空串） | `src/host/tracker/snapshotAssemble.ts:258-271` `normalizeTicket`（`:217` `claimedByOf`、`:238` `blockedByRefsOf`） |
| 分组口径最小字段 | `number, state, blockedBy(必填), blockedByRefs?, claimedBy?` | `src/tracker/kernel/grouping.ts:27-51` `GroupingTicket`、`:54-61` `BlockingRef` |
| 快照补算字段 | `t.level`（DAG 深度，由 `computeLevels` 回填） | `src/refresh/rooms/host/session-snapshot-cache.ts:215-219`、`:394-398` |
| 整份快照 | `Snapshot = { repository, maps(MapNode{tickets}), issues, deck(DeckProjection) }`；`MapStats = { total, open, closed, frontier, claimed, blocked, indeterminate }` | `src/shared/tracker/shape.ts:340-345`、`:278-286`、`:315-330` |

### F. blocked / frontier / map-detail 视图怎么算

**分层与分组的两份同源实现（改一处必须同步改另一处）**

- 真源（tracker 层 + 门禁用）：`src/tracker/kernel/grouping.ts`
  - `blockerBlocks` `:123-138`：本批有该票 → 看它 `state === 'OPEN'`；不在本批 → 看 `blockedByRefs` 引用态，只有明确 `'CLOSED'` 才放行，`OPEN`/未知/无旁表一律按挡着（安全侧，注释 `:115-121`）。
  - `computeLevels` `:148-190`：`blockedBy` DAG 最长路径深度（root=0，`level(x)=1+max(直接阻塞者)`，图外引用按叶子）；层内再细分 `:179-186`：`layer.frontier`（OPEN 且未认领且不被挡）、`layer.claimed`、`layer.blocked`。
  - `groupTickets` `:220-235`：五桶 `total/open/closed/frontier/claimed/blocked` + `levels/levelOf`；三态定义在 `:225-227`（frontier 与 claimed/blocked 可重叠视角，注释 `:208-218`）。
  - `TicketLevel` 形状 `:64-81`（`frontier:76`、`claimed:78`、`blocked:80`）。
  - 再导出：`src/tracker/body-parse.ts:279` `export { computeLevels, groupTickets } from './kernel/grouping.js'`。
- 宿主副本（零依赖、动态 import 用）：`src/host/ticketGrouping.ts`
  - `createTicketGrouping` `:38`；`computeLevels` `:75`；`groupTickets` `:116`；层内 `:104-110`（`frontier:107`、`claimed:108`、`blocked:109`）；跨容器判定 `blockerBlocks` `:58-73`（与 grouping.ts 同口径，交叉核对用例 `tests/verify-map-first-frame.ts`，见 `ticketGrouping.ts:15-17`）。

**调用点**

- 快照首屏与重建逐 map 计算：`src/refresh/rooms/host/session-snapshot-cache.ts:215-221`（回填 `t.level`、写 `m.stats = groupTickets(tickets)`）与 `:394-400`（同口径的回退支路）。
- deck 投影（agent 侧可见的统计）：`src/tracker/deck-derive.ts:260` `deriveDeck`、`:319` `stats` 初始化、`:332` `stats.frontier++`（OPEN + 认领已知且空 + 不被挡）、`:212` 破链依赖 NOT-FOUND → 安全算 blocked（文件头 `:9-13` 口径）。
- deck 工具的可接过滤：`src/deck/tools/map-snapshot.ts:61`（`frontierOnly` 参数）、`:219-235`（按派生口径筛并回报条数）。
- 客户端列表/漏斗：`src/client/kernel/store-derived.ts:156-179` `compute`（每张票单趟分进 `open/closed/frontier/claimed/blocked` 五桶；`openBlocker` 判定 `:162`、分桶 `:168-175`）、`:179` `frontierAll`、`:296` `frontierCount`、`:116` `mapBlockOf`。
- 地图详情看板（map-detail view）：`src/client/views/mapDetailV2/model/tickets/ticketBoard.ts:30`（状态序 `doing/ready/blocked/closed`）、`:76` `orderOpenTickets`（被挡段排序，`:39-43` 说明挡路者未知排最后）、`:104` `orderTicketBoard`、`:109-116` `boardCountsOf`（注释 `:108` 自述「与宿主 groupTickets 的五个桶同口径」）。
- 地图详情数据：首屏 `snapshot.maps[].tickets`；点开时 `wf.mapTickets` 现拉全子票（`src/host/index.ts:230`、`src/host/mapTickets.ts:26-30`）。

---

## 二、未找到

1. **`src/client/kernel/prompt-data.ts`（生成模块实体）在 main 树中未找到** —— 该文件按设计「生成物不入库，构建时现场生成」（`scripts/generate-prompt-config.mts:4-7`、`:41`）；递归 tree 里只有无关的 `tests/lib/prompt-data.ts`。因此无法引用生成物行号，生成规则以上述生成器与 YAML 两处为准。
2. **技能卡注入前的「确认弹窗」实现未找到** —— 两个注入调用点（`SkillsTab.ts:79`、`SkillFloatList.ts:129`）都是直接注入；仓库仅有截图 `assets/init/中文-深色-4-点击确认后-注入prompt.png`（tree 列表可见），对应确认步骤代码未定位。
3. **技能卡注入的多行模板未找到（不存在）** —— 技能卡注入文本只有 `/技能名`；多行模板只存在于票据动作（B 节）与检查项动作（C 节）。
4. 未对 DSH 仓库做 git clone / 本地构建（工单明确禁止 clone；生成器 `generate-prompt-config.mts` 未实跑，`prompt-data.ts` 产物未实测展开结果）。
