--!strict
-- wayfinder 地图与票的归一化：解析 gh issue list --json 产出的对象。
-- 不解析成 JSON 字符串（宿主半边负责解码），本模块吃已解码的 Lua 表，纯逻辑可单测。
-- 解析容错：gh 字段缺省时降级为空/默认，不崩（spec §7 已知 gh 输出形状随版本变）。

local util = require("./util")

local M = {}

export type Ticket = {
	number: number,
	title: string,
	body: string,
	state: string,
	url: string,
	labels: { string },
	assignees: { string },
	blockedBy: { number },
	type: string?, -- "grilling" | "prototype" | "research" | "task"，无 wayfinder:<type> 标签时 nil
	parent: number?, -- 父 issue 号：决策票挂地图，工单挂 spec
	isSpec: boolean, -- 带 ready-for-agent 标签 = to-spec 的产物
}

--- 按状态把票分成四组，供任务板分组展示。
export type Buckets = {
	claimable: { Ticket }, -- 未关闭 + 未认领 + 不被未关闭的票阻塞
	assigned: { Ticket }, -- 未关闭 + 已认领
	blocked: { Ticket }, -- 未关闭 + 未认领 + 被未关闭的票阻塞
	closed: { Ticket },
}

export type Map = {
	number: number,
	title: string,
	url: string,
	state: string,
	body: string,
	fog: string?,
	outOfScope: string?,
	tickets: { Ticket },
}

--- 把 labels 字段统一成 {string}（gh 可能给字符串数组或 {name} 数组）。
local function readLabels(v: any): { string }
	local out: { string } = {}
	if type(v) == "table" then
		for _, l in ipairs(v) do
			if type(l) == "string" then
				table.insert(out, l)
			elseif type(l) == "table" and type(l.name) == "string" then
				table.insert(out, l.name)
			end
		end
	end
	return out
end

--- 把 assignees 字段统一成 {login 字符串}。
local function readAssignees(v: any): { string }
	local out: { string } = {}
	if type(v) == "table" then
		for _, a in ipairs(v) do
			if type(a) == "table" and type(a.login) == "string" then
				table.insert(out, a.login)
			elseif type(a) == "string" then
				table.insert(out, a)
			end
		end
	end
	return out
end

--- 把 blockedBy 字段统一成 {number}。
--- gh 的形状是 {nodes={{number=..}},totalCount=n}；也接受裸数字数组或 {number} 对象数组。
local function readBlockedBy(v: any): { number }
	local out: { number } = {}
	local function collect(list: any)
		if type(list) ~= "table" then
			return
		end
		for _, b in ipairs(list) do
			if type(b) == "number" then
				table.insert(out, b)
			elseif type(b) == "table" and type(b.number) == "number" then
				table.insert(out, b.number)
			end
		end
	end
	if type(v) ~= "table" then
		return out
	end
	-- gh 的包装形状：{nodes={...}}。
	if type(v.nodes) == "table" then
		collect(v.nodes)
		return out
	end
	collect(v)
	return out
end

--- 从标签推断票类型：唯一取第一个命中的 wayfinder:<type>，其余 wayfinder:* 忽略。
local function readType(labels: { string }): string?
	for _, l in ipairs(labels) do
		if l == "wayfinder:grilling" then
			return "grilling"
		elseif l == "wayfinder:prototype" then
			return "prototype"
		elseif l == "wayfinder:research" then
			return "research"
		elseif l == "wayfinder:task" then
			return "task"
		end
	end
	return nil
end

--- 解析一张票（或地图子票）。number 缺失视为无效，返回 nil。
function M.parseIssue(json: any): Ticket?
	local number = json.number
	if type(number) ~= "number" then
		return nil
	end
	local labels = readLabels(json.labels)
	local body = type(json.body) == "string" and json.body or ""
	local parentNum: number? = nil
	local parent = json.parent
	if type(parent) == "table" and type(parent.number) == "number" then
		parentNum = parent.number
	end
	return {
		number = number,
		title = type(json.title) == "string" and json.title or "",
		body = body,
		state = type(json.state) == "string" and json.state or "",
		url = type(json.url) == "string" and json.url or "",
		labels = labels,
		assignees = readAssignees(json.assignees),
		blockedBy = readBlockedBy(json.blockedBy),
		type = readType(labels),
		parent = parentNum,
		isSpec = util.contains(labels, "ready-for-agent"),
	}
end

--- 抽出地图正文里 "## 尚未明确" / "## 范围外" 两节纯文本，缺失返回 nil。
function M.parseSections(body: string): { fog: string?, outOfScope: string? }
	local function section(heading: string): string?
		local lines = util.splitLines(body)
		local startIdx: number? = nil
		for i, line in ipairs(lines) do
			if line:match("^##%s+" .. heading .. "%s*$") then
				startIdx = i
				break
			end
		end
		if not startIdx then
			return nil
		end
		local collected: { string } = {}
		for j = (startIdx :: number) + 1, #lines do
			local l = lines[j]
			if l:match("^#%s") or l:match("^##%s") or l:match("^###%s") then
				break
			end
			table.insert(collected, l)
		end
		return util.trim(table.concat(collected, "\n"))
	end
	return {
		fog = section("尚未明确"),
		outOfScope = section("范围外"),
	}
end

--- 解析地图 issue：number 缺失返回 nil；迷雾/范围外由正文节提取。
function M.parseMap(json: any): Map?
	local number = json.number
	if type(number) ~= "number" then
		return nil
	end
	local body = type(json.body) == "string" and json.body or ""
	local sections = M.parseSections(body)
	return {
		number = number,
		title = type(json.title) == "string" and json.title or "",
		url = type(json.url) == "string" and json.url or "",
		state = type(json.state) == "string" and json.state or "",
		body = body,
		fog = sections.fog,
		outOfScope = sections.outOfScope,
		tickets = {},
	}
end

--- 前沿：state==OPEN 且未被 OPEN 票阻塞且无人认领的票。
--- 被 CLOSED 票阻塞不计入阻塞（阻塞者关闭即解除），仍视作可领。
function M.computeFrontier(tickets: { Ticket }): { Ticket }
	local byNumber: { [number]: Ticket } = {}
	for _, t in ipairs(tickets) do
		byNumber[t.number] = t
	end
	local out: { Ticket } = {}
	for _, t in ipairs(tickets) do
		if t.state ~= "OPEN" then
			continue
		end
		if #t.assignees > 0 then
			continue
		end
		local blocked = false
		for _, b in ipairs(t.blockedBy) do
			local blocker = byNumber[b]
			if blocker and blocker.state == "OPEN" then
				blocked = true
				break
			end
		end
		if not blocked then
			table.insert(out, t)
		end
	end
	return out
end

--- 把票按「现在能不能干」分成四组，供任务板分组展示。
--- 与 computeFrontier 同一套判据，只是不再丢掉已认领 / 被阻塞 / 已关闭的票 ——
--- 那些票在面板上看不到，用户就以为任务板是空的。
function M.classify(tickets: { Ticket }): Buckets
	local byNumber: { [number]: Ticket } = {}
	for _, t in ipairs(tickets) do
		byNumber[t.number] = t
	end
	local out: Buckets = { claimable = {}, assigned = {}, blocked = {}, closed = {} }
	for _, t in ipairs(tickets) do
		if t.state ~= "OPEN" then
			table.insert(out.closed, t)
			continue
		end
		if #t.assignees > 0 then
			table.insert(out.assigned, t)
			continue
		end
		local blocked = false
		for _, b in ipairs(t.blockedBy) do
			local blocker = byNumber[b]
			if blocker and blocker.state == "OPEN" then
				blocked = true
				break
			end
		end
		if blocked then
			table.insert(out.blocked, t)
		else
			table.insert(out.claimable, t)
		end
	end
	return out
end

--- 把 spec 与它拆出的工单归组。
--- spec = 带 ready-for-agent 标签且没有父 issue 的 issue；工单 = 父 issue 指向该 spec 的子 issue。
--- 不递归：只看一层，够用且不会因为环状 parent 打转。
function M.groupBySpec(tickets: { Ticket }): { { spec: Ticket, tickets: { Ticket } } }
	local out: { { spec: Ticket, tickets: { Ticket } } } = {}
	local index: { [number]: number } = {}
	for _, t in ipairs(tickets) do
		if t.isSpec and t.parent == nil then
			table.insert(out, { spec = t, tickets = {} })
			index[t.number] = #out
		end
	end
	for _, t in ipairs(tickets) do
		if t.parent ~= nil and index[t.parent] then
			table.insert(out[index[t.parent]].tickets, t)
		end
	end
	return out
end

--- 把一组 gh issue（已解码）里的非地图 issue 解析成票。
function M.parseIssues(issues: { any }): { Ticket }
	local out: { Ticket } = {}
	for _, issue in ipairs(issues) do
		local labels = readLabels(issue.labels)
		if not util.contains(labels, "wayfinder:map") then
			local t = M.parseIssue(issue)
			if t then
				table.insert(out, t)
			end
		end
	end
	return out
end

--- 把一组 issue（地图 + 子票）按地图归组：地图带 wayfinder:map 标签，子票通过 parent 字段挂到地图。
--- 输入为 gh 解码后的原始对象数组（需包含 parent.number 才能挂接）；返回每个地图及其子票。
function M.groupByMap(issues: { any }): { Map }
	local maps: { Map } = {}
	local mapByNumber: { [number]: Map } = {}
	local childrenOf: { [number]: { any } } = {}
	for _, issue in ipairs(issues) do
		local labels = readLabels(issue.labels)
		local isMap = util.contains(labels, "wayfinder:map")
		if isMap then
			local m = M.parseMap(issue)
			if m then
				maps[m.number] = m
				mapByNumber[m.number] = m
			end
		else
			local parentNum: number? = nil
			local parent = issue.parent
			if type(parent) == "table" and type(parent.number) == "number" then
				parentNum = parent.number
			end
			if parentNum then
				childrenOf[parentNum] = childrenOf[parentNum] or {}
				table.insert(childrenOf[parentNum], issue)
			end
		end
	end
	for num, m in pairs(mapByNumber) do
		local kids = childrenOf[num]
		if kids then
			for _, kid in ipairs(kids) do
				local t = M.parseIssue(kid)
				if t then
					table.insert(m.tickets, t)
				end
			end
		end
	end
	local ordered: { Map } = {}
	for _, m in pairs(maps) do
		table.insert(ordered, m)
	end
	return ordered
end

return M
