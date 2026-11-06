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
--- 面板自己不做判断，只负责把票、地图、流程链摆全，省掉用户复述上下文。
--- 与票动作模板同机制：随插件分发，用户可覆盖。
M.NEXT_STEP = {
	id = "next-step",
	title = "问下一步",
	body = table.concat({
		"/skill:ask-matt",
		"项目 {repo}（tern 面板插件）的任务板快照。",
		"",
		"可领（未关闭、未认领、无 OPEN 阻塞）：",
		"{claimable}",
		"",
		"已认领：",
		"{assigned}",
		"",
		"被阻塞：",
		"{blocked}",
		"",
		"地图：",
		"{maps}",
		"",
		"流程链：/skill:ask-matt 定位 → /skill:grill-with-docs 盘问（写 GLOSSARY/ADR）→ /skill:to-spec → /skill:to-tickets 拆票 → /skill:implement 逐票实施（小改在同一上下文直接 /skill:implement）→ /skill:tdd → /skill:code-review → /skill:pr。大而模糊才用 /skill:wayfinder；坏了用 /skill:diagnosing-bugs。",
		"",
		"请按「解锁最多下游 + 一次会话可交付」给 1~3 张现在该做的票：逐条说明理由、要用的技能命令，并列出「你不确定我掌握什么」的假设。",
	}, "\n"),
}

--- 每桶最多列多少张，避免把整个任务板塞进提示词。
local BRIEF_MAX = 12

export type TicketBrief = {
	number: number,
	title: string,
	type: string?,
	blockedBy: { number },
}

local function ticketLine(t: TicketBrief): string
	local kind = if t.type then "wayfinder:" .. t.type else "无类型"
	return string.format("- #%d %s %s", t.number, kind, t.title)
end

local function bucketText(items: { TicketBrief }, extra: (TicketBrief) -> string?): string
	if #items == 0 then
		return "（无）"
	end
	local out: { string } = {}
	for i, t in ipairs(items) do
		if i > BRIEF_MAX then
			table.insert(out, string.format("- …还有 %d 张", #items - BRIEF_MAX))
			break
		end
		local line = ticketLine(t)
		local tail = if extra then extra(t) else nil
		if tail then
			line = line .. "（" .. tail .. "）"
		end
		table.insert(out, line)
	end
	return table.concat(out, "\n")
end

--- 把任务板快照摊成模板占位符的值。纯函数，好单测。
function M.nextStepVars(
	repo: string,
	buckets: { claimable: { TicketBrief }, assigned: { TicketBrief }, blocked: { TicketBrief } },
	maps: { { number: number, title: string } }
): { [string]: string }
	local mapLines: { string } = {}
	for _, m in ipairs(maps) do
		table.insert(mapLines, string.format("- #%d %s", m.number, m.title))
	end
	return {
		repo = repo,
		claimable = bucketText(buckets.claimable, nil),
		assigned = bucketText(buckets.assigned, nil),
		blocked = bucketText(buckets.blocked, function(t)
			if #t.blockedBy == 0 then
				return nil
			end
			local nums: { string } = {}
			for _, n in ipairs(t.blockedBy) do
				table.insert(nums, "#" .. tostring(n))
			end
			return "等 " .. table.concat(nums, ",")
		end),
		maps = if #mapLines > 0 then table.concat(mapLines, "\n") else "（无）",
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
