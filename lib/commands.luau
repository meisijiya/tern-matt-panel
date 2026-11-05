--!strict
-- 注入命令构造：技能 → 一行 /技能名；票 → 动作模板渲染结果。

local templates = require("./templates")

local M = {}

--- 技能注入内容：omp 认 `skill:` 前缀，写成 `/skill:名字`。
--- 早先写成 `/名字` 是错的 —— 技能包文档里的 `/wayfinder` 只是叙述写法，
--- omp 的命令解析只认 `/skill:wayfinder`。
function M.buildSkillCommand(skill: { name: string }): string
	return "/skill:" .. skill.name
end

--- 票注入内容：用对应类型模板渲染，填 url / title。
function M.buildTicketCommand(ticket: { url: string, title: string }, tpl: templates.Template): string
	return templates.render(tpl, { url = ticket.url, title = ticket.title })
end

return M
