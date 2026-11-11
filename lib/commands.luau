--!strict
-- 注入命令构造：技能 → 一行 /技能名；其余注入 → 统一信封。

local templates = require("./templates")

local M = {}

--- 技能注入内容：omp 认 `skill:` 前缀，写成 `/skill:名字`。
--- 早先写成 `/名字` 是错的 —— 技能包文档里的 `/wayfinder` 只是叙述写法，
--- omp 的命令解析只认 `/skill:wayfinder`。
function M.buildSkillCommand(skill: { name: string }): string
	return "/skill:" .. skill.name
end

--- 注入信封：统一出口。
--- 格式逐字固定；正文为空就不产出信封（宁可不注入，也不要只发一个空壳）。
function M.buildInjectionBody(action: string, body: string, number: number?): string
	if body:match("^%s*$") then
		return ""
	end
	local head = "===== 注入开始 · tern-matt-panel · " .. action
	if number then
		head = head .. " · #" .. tostring(number)
	end
	head = head .. " ====="
	return head .. "\n" .. body .. "\n===== 注入结束 · 下面是用户输入的内容 =====\n"
end
--- 票注入内容：用对应类型模板渲染，填 url / title，再套统一信封。
function M.buildTicketCommand(ticket: { url: string, title: string, number: number? }, tpl: templates.Template): string
	local body = templates.render(tpl, { url = ticket.url, title = ticket.title })
	return M.buildInjectionBody(tpl.title, body, ticket.number)
end

return M
