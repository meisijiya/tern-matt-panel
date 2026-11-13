--!strict
-- wayfinder 地图与票的归一化：解析 gh issue list --json 产出的对象。
-- 不解析成 JSON 字符串（宿主半边负责解码），本模块吃已解码的 Lua 表，纯逻辑可单测。
-- 解析容错：gh 字段缺省时降级为空/默认，不崩（spec §7 已知 gh 输出形状随版本变）。

local util = require("./util")

local M = {}

export type Ticket = {
	--- 选择态身份：GitHub 后端是编号的字符串形式；本地后端是 `<工作单元>/<NN>`。
	--- 各工作单元的编号都从 01 起算会重号，所以身份不能只用编号。
	id: string,
	number: number,
	title: string,
	body: string,
	state: string, -- "OPEN" | "CLOSED"
	url: string,
	labels: { string },
	assignees: { string },
	blockedBy: { string }, -- 阻塞票的 id；解析不出对应票时进 unresolvedBlockers
	unresolvedBlockers: boolean?, -- 有指向不存在票的阻塞引用 → 判被阻塞，绝不判可领
	claimed: boolean?, -- 本地后端 Status: claimed（本地契约没有认领人概念）
	type: string?, -- "grilling" | "prototype" | "research" | "task"，无类型时 nil
	parent: number?, -- GitHub：父 issue 号（决策票挂地图，工单挂 spec）
	isSpec: boolean, -- 带 ready-for-agent 标签 = to-spec 的产物；本地后端是 spec.md
	createdAt: string?, -- ISO8601，任务板按它排序；缺省时排到最后
	effort: string?, -- 本地后端的工作单元目录名
	path: string?, -- 本地后端的票文件（仓库相对路径）；文档视图按它打开
}

--- 按状态把票分成四组，供任务板分组展示。
export type Buckets = {
	claimable: { Ticket }, -- 未关闭 + 未认领 + 不被未关闭的票阻塞
	assigned: { Ticket }, -- 未关闭 + 已认领
	blocked: { Ticket }, -- 未关闭 + 未认领 + 被未关闭的票阻塞
	closed: { Ticket },
}

export type Map = {
	id: string, -- 选择态身份，规则同 Ticket.id
	number: number,
	title: string,
	url: string,
	state: string,
	body: string,
	bodyLoaded: boolean?, -- 正文是否已按需拉过（列表查询不含 body）
	fog: string?,
	decisions: string?, -- 已有决策（本地后端的地图正文段）
	outOfScope: string?,
	tickets: { Ticket },
	effort: string?, -- 本地后端的工作单元目录名
	path: string?, -- 本地后端的地图文件（仓库相对路径）
}

--- 取 GraphQL 的 {nodes={…}} 包装里的数组；不是包装就当普通数组。
--- GraphQL 连接的 labels / assignees / blockedBy 都是这个形状，
--- gh 的 JSON 输出是扁平数组 —— 两种形状共用这一条路径，不写两套解析器。
local function nodesOf(v: any): { any }
	if type(v) ~= "table" then
		return {}
	end
	if type(v.nodes) == "table" then
		return v.nodes
	end
	return v
end

--- 把 labels 字段统一成 {string}（gh 给字符串数组或 {name} 数组，
--- GraphQL 给 {nodes={{name=…}}}）。
local function readLabels(v: any): { string }
	local out: { string } = {}
	for _, l in ipairs(nodesOf(v)) do
		if type(l) == "string" then
			table.insert(out, l)
		elseif type(l) == "table" and type(l.name) == "string" then
			table.insert(out, l.name)
		end
	end
	return out
end

--- 把 assignees 字段统一成 {login 字符串}（扁平数组或 {nodes={{login=…}}}）。
local function readAssignees(v: any): { string }
	local out: { string } = {}
	for _, a in ipairs(nodesOf(v)) do
		if type(a) == "table" and type(a.login) == "string" then
			table.insert(out, a.login)
		elseif type(a) == "string" then
			table.insert(out, a)
		end
	end
	return out
end

--- 把 blockedBy 字段统一成 id 数组（裸数字数组、{number} 对象数组或 {nodes={…}}）。
--- GitHub 后端的编号即身份，数字按 tostring 转成 id。
local function readBlockedBy(v: any): { string }
	local out: { string } = {}
	for _, b in ipairs(nodesOf(v)) do
		if type(b) == "number" then
			table.insert(out, tostring(b))
		elseif type(b) == "table" and type(b.number) == "number" then
			table.insert(out, tostring(b.number))
		end
	end
	return out
end

--- 从标签推断票类型：唯一取第一个命中的 wayfinder:<type>，其余 wayfinder:* 忽略。
--- 取 `<前缀>:<种类>` 里的种类。
--- 裸标签返回 nil：只有带前缀的才算流程标签，免得仓库里一个随便的 `task`
--- 标签就把普通 issue 认成 wayfinder 的票。
local function labelKind(l: string): string?
	return string.match(l, "^[%w_%-%.]+:(.+)$")
end

--- wayfinder 的四类票。前缀不限：`wayfinder:research` 和 `myflow:research`
--- 一样认，用户换自己的标签命名空间不必改面板。
local TICKET_KINDS: { [string]: boolean } = {
	grilling = true,
	prototype = true,
	research = true,
	task = true,
}

local function readType(labels: { string }): string?
	for _, l in ipairs(labels) do
		local kind = labelKind(l)
		if kind and TICKET_KINDS[kind] then
			return kind
		end
	end
	return nil
end

--- 地图标签：任意前缀的 `:map`。
local function isMapLabel(labels: { string }): boolean
	for _, l in ipairs(labels) do
		if labelKind(l) == "map" then
			return true
		end
	end
	return false
end

--- spec 标签：to-spec 的原始约定是裸 `ready-for-agent`；
--- 用户把它收进自己的命名空间（`myflow:ready-for-agent`）也认。
local function isSpecLabel(labels: { string }): boolean
	for _, l in ipairs(labels) do
		if l == "ready-for-agent" or labelKind(l) == "ready-for-agent" then
			return true
		end
	end
	return false
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
		id = tostring(number),
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
		isSpec = isSpecLabel(labels),
		createdAt = type(json.createdAt) == "string" and json.createdAt or nil,
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
		id = tostring(number),
		number = number,
		title = type(json.title) == "string" and json.title or "",
		url = type(json.url) == "string" and json.url or "",
		state = type(json.state) == "string" and json.state or "",
		body = body,
		bodyLoaded = false,
		fog = sections.fog,
		outOfScope = sections.outOfScope,
		tickets = {},
	}
end

--- 票是否已被人接手。GitHub 后端看 assignee，本地后端看 `Status: claimed`
--- （本地契约没有认领人概念，只能表达「已被接手」）。
function M.isClaimed(t: Ticket): boolean
	return #t.assignees > 0 or t.claimed == true
end

--- 票是否被阻塞：任一阻塞票仍开着，或阻塞引用指向不存在的票。
--- 后者只由本地后端的扫描器标记（unresolvedBlockers）：GitHub 的依赖边不会悬空，
--- 拉到的集合里找不到只可能是分页没拉全，那时判「不阻塞」才是原本的行为。
function M.isBlocked(t: Ticket, byId: { [string]: Ticket }): boolean
	if t.unresolvedBlockers then
		return true
	end
	for _, b in ipairs(t.blockedBy) do
		local blocker = byId[b]
		if blocker and blocker.state == "OPEN" then
			return true
		end
	end
	return false
end

--- 前沿：state==OPEN 且未被 OPEN 票阻塞且无人认领的票。
--- 被 CLOSED 票阻塞不计入阻塞（阻塞者关闭即解除），仍视作可领。
function M.computeFrontier(tickets: { Ticket }): { Ticket }
	local byId: { [string]: Ticket } = {}
	for _, t in ipairs(tickets) do
		byId[t.id] = t
	end
	local out: { Ticket } = {}
	for _, t in ipairs(tickets) do
		if t.state ~= "OPEN" then
			continue
		end
		if M.isClaimed(t) then
			continue
		end
		local blocked = M.isBlocked(t, byId)
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
	local byId: { [string]: Ticket } = {}
	for _, t in ipairs(tickets) do
		byId[t.id] = t
	end
	local out: Buckets = { claimable = {}, assigned = {}, blocked = {}, closed = {} }
	for _, t in ipairs(tickets) do
		-- 顶层 spec 有自己的卡片；再进四组就是同一张票画两遍。
		if t.isSpec and t.parent == nil then
			continue
		end
		if t.state ~= "OPEN" then
			table.insert(out.closed, t)
			continue
		end
		if M.isClaimed(t) then
			table.insert(out.assigned, t)
			continue
		end
		if M.isBlocked(t, byId) then
			table.insert(out.blocked, t)
		else
			table.insert(out.claimable, t)
		end
	end
	return out
end

--- 按创建时间排序。ISO8601 定长且同格式，字典序就是时间序，不必解日期。
--- 缺 createdAt 的票排在最后 —— 它们不是"最旧"，是"不知道"，混进时间序里会骗人。
function M.sortByCreated(tickets: { Ticket }, newestFirst: boolean): { Ticket }
	local out = table.clone(tickets)
	table.sort(out, function(a, b)
		local ka = a.createdAt
		local kb = b.createdAt
		if ka == nil and kb == nil then
			return a.number < b.number
		end
		if ka == nil then
			return false
		end
		if kb == nil then
			return true
		end
		if ka == kb then
			return a.number < b.number
		end
		if newestFirst then
			return ka > kb
		end
		return ka < kb
	end)
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
		if not isMapLabel(labels) then
			local t = M.parseIssue(issue)
			if t then
				table.insert(out, t)
			end
		end
	end
	return out
end

--- 把一组 issue（地图 + 子票）按地图归组：地图带 `:map` 形式的标签，子票通过 parent 字段挂到地图。
--- 输入为 gh 解码后的原始对象数组（需包含 parent.number 才能挂接）；返回每个地图及其子票。
function M.groupByMap(issues: { any }): { Map }
	local maps: { Map } = {}
	local mapByNumber: { [number]: Map } = {}
	local childrenOf: { [number]: { any } } = {}
	for _, issue in ipairs(issues) do
		local labels = readLabels(issue.labels)
		local isMap = isMapLabel(labels)
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

--- 游标分页：每页条数与排序方向到 GraphQL 参数的映射。
M.PAGE_SIZE = 50

function M.orderDirection(newestFirst: boolean): string
	return if newestFirst then "DESC" else "ASC"
end

--- 合并两批 issue，按 number 去重并保留先到顺序；后者同号不追加。
function M.mergeIssues(existing: { any }, incoming: { any }): { any }
	local out: { any } = table.clone(existing)
	local seen: { [number]: boolean } = {}
	for _, t in ipairs(existing) do
		if type(t) == "table" and type(t.number) == "number" then
			seen[t.number] = true
		end
	end
	for _, t in ipairs(incoming) do
		if type(t) == "table" and type(t.number) == "number" and not seen[t.number] then
			seen[t.number] = true
			table.insert(out, t)
		end
	end
	return out
end

--- 截断到上限；已关票累积上限用。
function M.capIssues(issues: { any }, cap: number): { any }
	if #issues <= cap then
		return issues
	end
	local out: { any } = {}
	for i = 1, cap do
		table.insert(out, issues[i])
	end
	return out
end

--- 解析 `gh api graphql` 的一页：只取 issues.nodes 与 pageInfo，nodes 原样留给 parseIssues/groupByMap。
function M.parseIssuePage(payload: any): { issues: { any }, hasNextPage: boolean, endCursor: string? }?
	if type(payload) ~= "table" then
		return nil
	end
	local data = payload.data
	if type(data) ~= "table" then
		return nil
	end
	local repo = data.repository
	if type(repo) ~= "table" then
		return nil
	end
	local issues = repo.issues
	if type(issues) ~= "table" then
		return nil
	end
	local out: { any } = {}
	if type(issues.nodes) == "table" then
		for _, n in ipairs(issues.nodes) do
			if type(n) == "table" then
				table.insert(out, n)
			end
		end
	end
	local hasNext = false
	local cursor: string? = nil
	local info = issues.pageInfo
	if type(info) == "table" then
		hasNext = info.hasNextPage == true
		if type(info.endCursor) == "string" then
			cursor = info.endCursor
		end
	end
	return { issues = out, hasNextPage = hasNext, endCursor = cursor }
end

return M
