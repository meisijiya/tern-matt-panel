--!strict
-- 票动作模板：插件自有配置，随插件分发；绝不内嵌任何 skill 正文。
-- 模板只以"调用已安装技能"的方式提及（/grill-with-docs 等），内容中文单语。

local M = {}

export type Template = {
	id: string,
	title: string,
	body: string,
}

--- 四个票动作模板，按 wayfinder 票类型分（issue #9 决策）。
--- task 不挂技能，只给票链接 + 执行指令；其余三类只调用对应技能。
local TEMPLATES: { Template } = {
	{
		id = "grilling",
		title = "盘问",
		body = "请使用 /grill-with-docs 技能，对以下需求做盘问式审查，找出隐藏假设与尚未拍板的决策。\n需求链接：{url}",
	},
	{
		id = "prototype",
		title = "原型",
		body = "请使用 /prototype 技能，为以下需求快速做出可运行的原型，验证想法是否站得住。\n需求链接：{url}",
	},
	{
		id = "research",
		title = "调研",
		body = "请使用 /research 技能，围绕以下主题展开调研，给出结论与一手来源。\n需求链接：{url}",
	},
	{
		id = "task",
		title = "执行",
		body = "请认领并执行以下任务，完成后回报结论。\n任务标题：{title}\n任务链接：{url}",
	},
}
M.TEMPLATES = TEMPLATES

--- 「问下一步」：把任务板快照装进信封，交给会话里的 /skill:ask-matt 排序。
--- 面板自己不做判断：它只提供可核对的事实（票、依赖方向、规格进度、文档锚点）
--- 和排序判据。缺事实时要求 agent 自己用 gh 核实，而不是顺着快照猜。
M.NEXT_STEP = {
	id = "next-step",
	title = "问下一步",
	body = table.concat({
		"/skill:ask-matt",
		"项目 {repo} 的任务板，{rootLabel}：{root}",
		"数据源：GitHub issue（gh issue list）；不一致时以 gh 的结果为准。",
		"",
		"判断前先读这几处；文件不存在就跳过，不用报告缺失，也不要凭空引用：",
		"- 领域词汇：{root}/GLOSSARY.md",
		"- 已定决策：{root}/docs/adr/",
		"- 规格：{root}/docs/spec/",
		"",
		"可领（未关闭、未认领、无 OPEN 阻塞）共 {claimableCount} 张：",
		"{claimable}",
		"",
		"已认领共 {assignedCount} 张：",
		"{assigned}",
		"",
		"被阻塞共 {blockedCount} 张：",
		"{blocked}",
		"",
		"地图：",
		"{maps}",
		"",
		"已关闭：{closedLine}",
		"",
		"规格（含已关闭的，to-spec 的产物与其工单进度）：",
		"{specs}",
		"",
		"流程链：/skill:ask-matt 定位 → /skill:grill-with-docs 盘问（写 GLOSSARY/ADR）→ /skill:to-spec → /skill:to-tickets 拆票 → /skill:implement 逐票实施（小改在同一上下文直接 /skill:implement）→ /skill:tdd → /skill:code-review → /skill:pr。大而模糊才用 /skill:wayfinder；坏了用 /skill:diagnosing-bugs。",
		"",
		"排序判据，按序比较：",
		"1. 解锁下游多者优先（票行里的「被 #N 等待」就是下游）；",
		"2. 同档按阶段：grilling > research > prototype > task；",
		"3. 仍同档，创建时间旧者优先。",
		"以上字段全部来自 gh，不含正文、迷雾、范围外与 spec 细节；需要就用 gh 读。不要编造票号、标题、标签或依赖。",
		"",
		"输出（最多 3 张，不要复述整份快照）：",
		"| 票 | 为什么是现在 | 技能命令 | 第一步动作 |",
		"每张票下面一行「依据：…」写你实际读过的票号或文件。",
	}, "\n"),
}

--- 每桶最多列多少张，避免把整个任务板塞进提示词。
local BRIEF_MAX = 12

export type TicketBrief = {
	number: number,
	title: string,
	type: string?,
	blockedBy: { number },
	parent: number?,
	createdAt: string?,
	-- 非 wayfinder:* 的标签：测试数据、优先级这类信号都在这里
	labels: { string }?,
	assignees: { string }?,
}

export type SpecBrief = {
	number: number,
	title: string,
	open: number,
	total: number,
	-- "OPEN" / "CLOSED"：已关闭的 spec 和进行中的不是一回事，别并列
	state: string?,
}

export type NextStepExtra = {
	-- 仓库根目录：给 agent 指 GLOSSARY / ADR / spec 的去处
	root: string?,
	-- root 是真 git 仓库根（true），还是退化成了当前工作目录（nil/false）
	rootIsRepo: boolean?,
	-- 全部未关闭的票：用来算「被谁等待」这个反向依赖
	all: { TicketBrief }?,
	specs: { SpecBrief }?,
	-- 已关闭的票（只取数量与最近几张的标题）
	closed: { TicketBrief }?,
}

local function ticketLine(t: TicketBrief, waitedBy: { string }): string
	local kind = if t.type then "wayfinder:" .. t.type else "无类型"
	local line = string.format("- #%d %s %s", t.number, kind, t.title)
	if t.createdAt and #t.createdAt >= 10 then
		line = line .. " · " .. string.sub(t.createdAt, 1, 10)
	end
	if t.parent then
		line = line .. string.format(" · 父 #%d", t.parent)
	end
	if #t.blockedBy > 0 then
		local nums: { string } = {}
		for _, n in ipairs(t.blockedBy) do
			table.insert(nums, "#" .. tostring(n))
		end
		line = line .. " · 等 " .. table.concat(nums, ",")
	end
	if #waitedBy > 0 then
		line = line .. " · 被 " .. table.concat(waitedBy, ",") .. " 等待"
	end
	if t.assignees and #t.assignees > 0 then
		line = line .. " · @" .. table.concat(t.assignees, ",@")
	end
	-- wayfinder:* 已经用类型表达过了，剩下的标签才是额外信息（测试数据、优先级…）
	local extra: { string } = {}
	for _, label in ipairs(t.labels or {}) do
		if not string.find(label, ":", 1, true) then
			table.insert(extra, label)
		end
	end
	if #extra > 0 then
		line = line .. " · 标签 " .. table.concat(extra, ",")
	end
	return line
end

--- 反向依赖：哪些票的 blockedBy 里出现了这张票。
local function waitedIndex(all: { TicketBrief }): { [number]: { string } }
	local out: { [number]: { string } } = {}
	for _, t in ipairs(all) do
		for _, b in ipairs(t.blockedBy) do
			local list = out[b]
			if not list then
				list = {}
				out[b] = list
			end
			table.insert(list, "#" .. tostring(t.number))
		end
	end
	return out
end

--- 已关闭只给数量与最近几张标题：判断「这个阶段收没收尾」用它，不必把整组搬进来。
local CLOSED_MAX = 5
local function closedText(items: { TicketBrief }): string
	if #items == 0 then
		return "0 张"
	end
	local titles: { string } = {}
	for i, t in ipairs(items) do
		if i > CLOSED_MAX then
			break
		end
		table.insert(titles, string.format("#%d %s", t.number, t.title))
	end
	local tail = if #items > CLOSED_MAX then string.format("，另有 %d 张", #items - CLOSED_MAX) else ""
	return string.format("%d 张（最新建立的：%s%s）", #items, table.concat(titles, "；"), tail)
end

local function bucketText(items: { TicketBrief }, waited: { [number]: { string } }): string
	if #items == 0 then
		return "（无）"
	end
	local out: { string } = {}
	for i, t in ipairs(items) do
		if i > BRIEF_MAX then
			table.insert(out, string.format("- …还有 %d 张", #items - BRIEF_MAX))
			break
		end
		table.insert(out, ticketLine(t, waited[t.number] or {}))
	end
	return table.concat(out, "\n")
end

--- 把任务板快照摊成模板占位符的值。纯函数，好单测。
function M.nextStepVars(
	repo: string,
	buckets: { claimable: { TicketBrief }, assigned: { TicketBrief }, blocked: { TicketBrief } },
	maps: { { number: number, title: string } },
	extra: NextStepExtra?
): { [string]: string }
	local waitList = if extra and extra.all then waitedIndex(extra.all) else {}

	local mapLines: { string } = {}
	for _, m in ipairs(maps) do
		table.insert(mapLines, string.format("- #%d %s", m.number, m.title))
	end

	local specLines: { string } = {}
	for _, s in ipairs(if extra and extra.specs then extra.specs else {}) do
		local state = if s.state == "CLOSED" then "已关闭" else "进行中"
		local progress = if s.total == 0
			then "未拆工单"
			else string.format("未完成 %d 张，共 %d 张", s.open, s.total)
		table.insert(specLines, string.format(
			"- #%d %s · %s · %s",
			s.number,
			s.title,
			state,
			progress
		))
	end

	return {
		repo = repo,

		closedLine = closedText(extra and extra.closed or {}),
		root = if extra and extra.root then extra.root else "（未知，按当前工作目录找）",
		rootLabel = if extra and extra.rootIsRepo then "仓库根目录" else "当前工作目录",
		claimableCount = tostring(#buckets.claimable),
		assignedCount = tostring(#buckets.assigned),
		blockedCount = tostring(#buckets.blocked),
		claimable = bucketText(buckets.claimable, waitList),
		assigned = bucketText(buckets.assigned, waitList),
		blocked = bucketText(buckets.blocked, waitList),
		maps = if #mapLines > 0 then table.concat(mapLines, "\n") else "（无）",
		specs = if #specLines > 0 then table.concat(specLines, "\n") else "（无）",
	}
end

--- 仓库空的时候给两条路，对应参考实现的「探索地图 / 实施地图」二选一：
--- 需求还没摸清走 wayfinder 画地图；需求已经明确直接 grill 收敛成 spec。
--- 只甩一条 /wayfinder 会误导 —— 需求清楚的人不需要画地图。
export type Entry = { id: string, title: string, hint: string, body: string }

local ENTRIES: { Entry } = {
	{
		id = "explore",
		title = "还没想清楚：建路线图",
		hint = "跑 /wayfinder 画一张地图，把未知与范围拆成决策票",
		body = "请使用 /wayfinder 技能，为这个仓库建立一张路线图（地图 issue）。\n仓库：{repo}",
	},
	{
		id = "implement",
		title = "需求已明确：直接对齐",
		hint = "跑 /grill-with-docs 把需求问清，再 /to-spec → /to-tickets 拆成可做的票",
		body = "请使用 /grill-with-docs 技能，把下面这件事问清楚，收敛成可执行的 spec。\n仓库：{repo}\n\n需求：",
	},
}
M.ENTRIES = ENTRIES

--- 按 id 取入口；找不到返回 nil。
function M.entryById(id: string): Entry?
	for _, e in ipairs(M.ENTRIES) do
		if e.id == id then
			return e
		end
	end
	return nil
end

--- 替换入口模板里的占位符。
function M.renderEntry(e: Entry, repo: string): string
	return (e.body:gsub("{repo}", repo))
end

--- 按 id 取模板；找不到返回 nil。
function M.byId(id: string): Template?
	for _, t in ipairs(M.TEMPLATES) do
		if t.id == id then
			return t
		end
	end
	return nil
end

--- 按票类型取模板；票没有 wayfinder:<type> 标签时返回 nil。
function M.byTicketType(kind: string?): Template?
	if not kind then
		return nil
	end
	return M.byId(kind)
end

--- 替换模板里的 {占位符}。缺的占位符留原样（不静默吞掉，便于发现模板写错）。
function M.render(tpl: Template, vars: { [string]: string }): string
	return (tpl.body:gsub("{(%w+)}", function(key: string)
		return vars[key] or ("{" .. key .. "}")
	end))
end

return M
