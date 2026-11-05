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

--- 替换 {url} / {title} 占位符；未提供的占位符留原样（不静默吞掉，便于发现模板写错）。
function M.render(tpl: Template, vars: { url: string?, title: string? }): string
	local url = vars.url or ""
	local title = vars.title or ""
	return (tpl.body:gsub("{(%w+)}", function(key)
		if key == "url" then
			return url
		end
		if key == "title" then
			return title
		end
		return "{" .. key .. "}"
	end))
end

return M
