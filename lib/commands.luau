--!strict
-- 注入命令构造：技能 → 一行 /技能名；票 → 动作模板渲染结果。

local templates = require("./templates")

local M = {}

--- 技能注入内容：斜杠命令名（name 即 = 斜杠命令名，spec §4）。
function M.buildSkillCommand(skill: { name: string }): string
	return "/" .. skill.name
end

--- 票注入内容：用对应类型模板渲染，填 url / title。
function M.buildTicketCommand(ticket: { url: string, title: string }, tpl: templates.Template): string
	return templates.render(tpl, { url = ticket.url, title = ticket.title })
end

return M
