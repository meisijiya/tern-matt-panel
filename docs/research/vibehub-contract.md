# VibeHub 技能引用合约（面板「前端」入口）

> 调研对象：`oil-oil/vibe-hub-skill`（GitHub）的 `skills/vibehub` 子技能 + 其脚本。
> 目的：回答面板模板能否、怎样引用 VibeHub 技能。只写取证，不实现。

## 技能名与触发

- 技能名（SKILL.md frontmatter `name`）：`vibehub`。仓库名 `vibe-hub-skill`，包名 `vibe-hub-skill`（package.json `name`）。来源：`skills/vibehub/SKILL.md:1`；`package.json`。
- 触发：在任何 Vibe Coding 编程任务及其后续补充中持续识别准确术语；用户用口语描述效果/交互/状态/问题时也必须使用；用户要求「说专业一点」、改写需求、询问「这叫什么」或看不懂 Agent 回复时同样使用。表达已经准确且无值得补充术语时不要硬加教学。来源：`SKILL.md` description。
- 调用方式：技能通过 `/skill:vibehub`（或宿主等价）触发；模板里只能引用 `/skill:vibehub`，不得内嵌技能正文。来源：面板约定（templates 只允许 `/skill:名字`）。

## 调用与脚本

- 脚本：`skills/vibehub/scripts/vibehub.mjs`，Node `>=20`（package.json `engines.node`）。
- 唯一命令：`resolve`。参数：`--query <term>`（可重复最多 3 次）、`--site-url <url>`、`--limit <1-5>`（默认 1）、`--compact`、`--timeout <ms>`（1000–60000，默认 10000）、`--help`。来源：脚本 HELP 与 parseArgs。
- 调用示例（上游原文）：`node "<skill-root>/scripts/vibehub.mjs" resolve --query "<候选术语 1>" --query "<候选术语 2>" --compact`。来源：SKILL.md「一次查询候选」。
- 流程：先拉 `${siteUrl}/.well-known/vibehub.json` 取 manifest（需 `apiBaseUrl`、`schemaVersion`）；再对每个 query 调 `${apiBaseUrl}/search?q=...&limit=...`；非 compact 时对每个 summary 再拉 `${apiBaseUrl}/lessons/{id}`。来源：脚本 `resolve()`。
- 输出 JSON：`{ ok, source, schemaVersion, revision, mode, query/count/candidates }`；失败 `{ ok:false, error:{code,message} }` 且 exitCode=1。来源：脚本 output/fail。
- 超时：默认 10000ms，AbortController；超时错误码 `request_timeout`。来源：fetchJson。
- 查询上限 3 个、limit 1–5、timeout 1000–60000，超限抛错。来源：normalizeQueries / resolve 校验。

## 网络与隐私

- 端点：manifest `https://vibe-hub.org/.well-known/vibehub.json`（bundled config siteUrl）；API base 来自 manifest；搜索 `/search`；详情 `/lessons/{id}`。来源：vibehub.config.json + 脚本。
- 请求字段（发给服务端）：仅 `q`（查询词）与 `limit`；HTTP 头 `Accept: application/json`。无 cookie、无鉴权、无用户标识。来源：脚本 fetchJson / searchUrl。
- 脱敏：`sanitizeRemoteText` 在发送前对 query 做脱敏——移除代码块、URL、Windows 路径（`C:\...`）、Unix 绝对路径（`/Users/...` 等）、邮箱；再按 `PRIVATE_VALUE_PATTERNS` 移除 bearer/api_key/access_token/client_secret/password/token 赋值与 JWT。最终截断 120 字符。来源：脚本 `sanitizeRemoteText` / `normalizeQueries`。
- 脱敏是脚本层真实执行（query 必经 `sanitizeRemoteText`），但只覆盖文本模式；技能 SKILL.md 也要求「查询只传脱敏后的短术语，不传源代码、密钥、客户信息、内部网址、邮箱、本地路径或项目材料」。来源：SKILL.md「一次查询候选」。
- 隐私边界：服务端可看到搜索词（脱敏后）；无账号/遥测。未查到隐私政策文本，不 overstated。

## 安装与发现

- 安装命令（上游 README 原文未读到 README；package.json 无 install 字段）：用户提供的 `npx skills add oil-oil/vibe-hub-skill`。本机未安装 vibehub：探测 `~/.omp/agent/skills`、`~/.agents/skills`、`~/.claude/skills`、`~/.omp/plugins` 均无 `vibehub` 目录。来源：本机 ls（2026-11-15）。
- omp 技能发现：omp 从 `~/.omp/agent/skills` 等目录发现；本机该目录为 symlink 集合指向 `~/.config/magpie/library/skills`。vibehub 不在其中，因此 `/skill:vibehub` 本机当前不可用。来源：本机目录结构。
- 面板 packs.luau 发现方式只有两种：`registryKey`（omp 安装登记键）与 `localRel`（相对 home 的本地目录）。对 vibe-hub 应选 `localRel = ".omp/agent/skills/vibehub"` 或安装后的实际相对路径；无 registryKey（上游非 omp marketplace 插件）。版本从 SKILL.md frontmatter 或 package.json 读；上游 package.json version 为 `0.1.0`。来源：lib/packs.luau；package.json。
- 若按 `npx skills add` 安装，落点需实测；本机暂未安装，无法确认最终目录。来源：本机未安装（未查到）。

## 失败与降级

- 离线/无网络：manifest fetch 失败 → `resolver_failed` 或 `request_timeout`，exitCode 1，stdout 为 `{ok:false,...}`。来源：脚本。
- 查不到词条：search 返回 results 数组可能为空 → candidates=[]，`count:0`，仍 `ok:true`。来源：脚本。
- 接口错误（HTTP 非 2xx）：抛错 → `resolver_failed` + HTTP 状态。来源：fetchJson。
- manifest 缺字段：抛错「missing apiBaseUrl or schemaVersion」。来源：resolve。
- 模板降级建议：技能调用失败时模板不得阻塞主任务；只在有可靠匹配时才插入术语内链；无匹配时不硬加教学；网络失败时静默跳过术语提示。来源：SKILL.md + 脚本失败语义。

## 许可证与引用边界

- 许可证：MIT，Copyright (c) 2026 oil-oil。允许使用、复制、修改、合并、发布、分发、再许可、售卖，条件是保留版权声明与许可声明。来源：LICENSE。
- 模板可引用其术语链接（`https://vibe-hub.org/...`）——链接不是受版权保护的表达；可内联少量规则（如「最多 1–3 个术语」「先交付任务再补术语」）作为事实性指引，但不得复制 SKILL.md 正文或脚本代码。来源：MIT + 面板约定。
- 不得把脚本代码或 SKILL.md 全文 vendoring 进插件；插件不代装技能。来源：面板约定。

## 对模板的结论

- 模板可以引用 `/skill:vibehub` 作为可选增强，但必须把技能视为外部依赖：未安装/离线/无匹配时主流程不受影响。
- packs.luau 应以 `localRel` 方式登记（无 registryKey），版本读 package.json/SKILL.md；安装指引照抄上游 `npx skills add oil-oil/vibe-hub-skill`（需用户自行执行）。
- 模板不得内嵌技能正文，只允许 `/skill:vibehub` 调用 + 最多引用 1–3 条规则摘要。

## 未解决 / 待拍板

1. `npx skills add` 在 Windows/omp 的实际安装落点未实测（本机未装）。
2. 隐私政策/数据保留未查到官方文本。
3. 是否把 vibehub 加入 packs 清单（产品决策）。