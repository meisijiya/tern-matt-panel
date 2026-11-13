--!strict
-- 本地 markdown 跟踪器（上游 `.scratch/<工作单元>/` 约定）的读取与解析。
--
-- 目录模型（上游 setup 技能的 issue-tracker-local.md）：
--   .scratch/<工作单元>/map.md         地图
--   .scratch/<工作单元>/spec.md        规格
--   .scratch/<工作单元>/issues/NN-<slug>.md  票，编号从 01 起算
--
-- 票号只在工作单元内唯一，所以身份是 `<工作单元>/<NN>`；阻塞边也只在本单元内解析。
-- 一次扫描把文件全部读进内存，之后的分组、统计、前沿全从内存算。
-- 仅本模块与 lib/skills.luau 使用 tern.fs；解析函数是纯的，可在 luau CLI 下单测。

local util = require("./util")
local tracker = require("./tracker")

local M = {}

M.SCRATCH = ".scratch"
M.CONTRACT_PATH = "docs/agents/issue-tracker.md"

--- 关闭类状态：这些取值都视为已关闭。
local CLOSED_STATUS: { [string]: boolean } = {
	resolved = true,
	completed = true,
	closed = true,
	done = true,
	wontfix = true,
}

--- 票类型的合法取值，与 GitHub 后端的 wayfinder:<type> 标签一一对应。
local KINDS: { [string]: boolean } = {
	grilling = true,
	prototype = true,
	research = true,
	task = true,
}

--- 取 `**Status:** claimed` / `Status: claimed` 行的值，小写；没有返回 nil。
function M.parseStatus(text: string): string?
	for _, line in ipairs(util.splitLines(text)) do
		local v = string.match(line, "^%*%*Status:%*%*%s*(.-)%s*$") or string.match(line, "^Status:%s*(.-)%s*$")
		if v and v ~= "" then
			return v:lower()
		end
	end
	return nil
end

--- 取 `**Type:** task` / `Type: task` 行的值；不是四类之一就当没有类型。
function M.parseType(text: string): string?
	for _, line in ipairs(util.splitLines(text)) do
		local v = string.match(line, "^%*%*Type:%*%*%s*(.-)%s*$") or string.match(line, "^Type:%s*(.-)%s*$")
		if v then
			local kind = string.match(v:lower(), "^([%w_%-]+)")
			if kind and KINDS[kind] then
				return kind
			end
		end
	end
	return nil
end

--- 取 `**Blocked by:** 03, 05` 行里的编号（去掉 `#`，只看数字）。
--- "None (can start immediately)" 这类写法解析不出编号，就是没有阻塞。
function M.parseBlockedBy(text: string): { string }
	local out: { string } = {}
	for _, line in ipairs(util.splitLines(text)) do
		local v = string.match(line, "^%*%*Blocked by:%*%*%s*(.-)%s*$") or string.match(line, "^Blocked by:%s*(.-)%s*$")
		if v then
			for num in string.gmatch(v, "(%d+)") do
				table.insert(out, num)
			end
			break
		end
	end
	return out
end

--- 票标题：第一个 `# ` 标题，去掉 `NN: ` 前缀。
function M.parseTitle(text: string): string?
	for _, line in ipairs(util.splitLines(text)) do
		local h = string.match(line, "^#%s+(.-)%s*$")
		if h then
			return (string.match(h, "^%d+%s*:%s*(.-)$") or h)
		end
	end
	return nil
end

--- 状态归一：状态只有开/关两态，认领单独一个标志。
function M.stateOf(status: string?): { state: string, claimed: boolean }
	if not status then
		return { state = "OPEN", claimed = false }
	end
	if CLOSED_STATUS[status] then
		return { state = "CLOSED", claimed = false }
	end
	if status == "claimed" then
		return { state = "OPEN", claimed = true }
	end
	-- needs-triage / needs-info / ready-for-agent / ready-for-human 等都是打开且未认领。
	return { state = "OPEN", claimed = false }
end

--- 抽一节正文：标题行匹配任一别名（中英两种写法），到下一个同级或更高级标题为止。
local function section(body: string, aliases: { string }): string?
	local lines = util.splitLines(body)
	local startIdx: number? = nil
	for i, line in ipairs(lines) do
		local h = string.match(line, "^##%s+(.-)%s*$")
		if h then
			for _, alias in ipairs(aliases) do
				if h:lower() == alias:lower() then
					startIdx = i
					break
				end
			end
		end
		if startIdx then
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

--- 地图正文的三节。笔记（Notes）不显示，故意不取。
function M.parseSections(body: string): { fog: string?, decisions: string?, outOfScope: string? }
	return {
		fog = section(body, { "尚未明确", "Fog" }),
		decisions = section(body, { "已有决策", "Decisions-so-far", "Decisions so far" }),
		outOfScope = section(body, { "范围外", "Out-of-scope", "Out of scope" }),
	}
end

--- 从 `NN-slug.md` 取编号文本（保留前导零，身份与显示都用它）。
function M.numberOf(filename: string): string?
	return string.match(filename, "^(%d+)%-")
end

--- 读一个文件；失败返回 nil 与一句原因。
local function readFile(path: string): (string?, string?)
	local ok, text = pcall(tern.fs.read, path)
	if not ok then
		return nil, tostring(text)
	end
	return text :: string, nil
end

--- 列目录里的条目；不是目录时返回空表。
local function listDir(path: string): { string }
	local ok, names = pcall(tern.fs.list, path)
	if not ok then
		return {}
	end
	return names
end

local function exists(path: string): boolean
	local ok, v = pcall(tern.fs.exists, path)
	return ok and v == true
end

export type ScanResult = {
	maps: { tracker.Map },
	tickets: { tracker.Ticket },
	errors: { { path: string, message: string } },
}

--- 扫一个仓库根下的 `.scratch/`，产出与 GitHub 后端同构的地图与票。
--- 读不动的文件记进 errors：界面据此报「N 张票读不动」，不静默少显示。
function M.scan(root: string): ScanResult
	local result: ScanResult = { maps = {}, tickets = {}, errors = {} }
	local scratch = root .. "/" .. M.SCRATCH
	if not exists(scratch) then
		return result
	end
	local byId: { [string]: tracker.Ticket } = {}
	local pendingBlockers: { { ticket: tracker.Ticket, keys: { string } } } = {}

	for _, effort in ipairs(listDir(scratch)) do
		local dir = scratch .. "/" .. effort
		local issuesDir = dir .. "/issues"
		local mapPath = dir .. "/map.md"
		local specPath = dir .. "/spec.md"
		local hasIssues = exists(issuesDir)
		if exists(mapPath) or exists(specPath) or hasIssues then
			-- 地图
			local mapId = effort .. "/00"
			local map: tracker.Map? = nil
			if exists(mapPath) then
				local text, err = readFile(mapPath)
				if text then
					local sections = M.parseSections(text)
					map = {
						id = mapId,
						number = 0,
						title = effort,
						url = "",
						state = "OPEN",
						body = text,
						bodyLoaded = true,
						fog = sections.fog,
						decisions = sections.decisions,
						outOfScope = sections.outOfScope,
						tickets = {},
						effort = effort,
						path = M.SCRATCH .. "/" .. effort .. "/map.md",
					}
					table.insert(result.maps, map)
				else
					table.insert(result.errors, { path = M.SCRATCH .. "/" .. effort .. "/map.md", message = err or "读不动" })
				end
			end
			-- 规格：单独一张顶层卡，不混进地图。
			if exists(specPath) then
				local text, err = readFile(specPath)
				if text then
					table.insert(result.tickets, {
						id = effort .. "/spec",
						number = 0,
						title = "规格 · " .. effort,
						body = text,
						state = "OPEN",
						url = "",
						labels = {},
						assignees = {},
						blockedBy = {},
						type = nil,
						parent = nil,
						isSpec = true,
						effort = effort,
						path = M.SCRATCH .. "/" .. effort .. "/spec.md",
					})
				else
					table.insert(result.errors, { path = M.SCRATCH .. "/" .. effort .. "/spec.md", message = err or "读不动" })
				end
			end
			-- 票
			if hasIssues then
				for _, filename in ipairs(listDir(issuesDir)) do
					local num = M.numberOf(filename)
					if num then
						local rel = M.SCRATCH .. "/" .. effort .. "/issues/" .. filename
						local text, err = readFile(issuesDir .. "/" .. filename)
						if text then
							local status = M.parseStatus(text)
							local st = M.stateOf(status)
							local t: tracker.Ticket = {
								id = effort .. "/" .. num,
								number = tonumber(num) or 0,
								title = M.parseTitle(text) or filename,
								body = text,
								state = st.state,
								url = "",
								labels = {},
								assignees = {},
								blockedBy = {},
								claimed = st.claimed,
								type = M.parseType(text),
								parent = nil,
								isSpec = false,
								effort = effort,
								path = rel,
							}
							table.insert(result.tickets, t)
							byId[t.id] = t
							table.insert(pendingBlockers, { ticket = t, keys = M.parseBlockedBy(text) })
							if map then
								table.insert(map.tickets, t)
							end
						else
							table.insert(result.errors, { path = rel, message = err or "读不动" })
						end
					end
				end
			end
		end
	end

	-- 阻塞边在本工作单元内解析；指向不存在的票 → 判被阻塞，绝不判可领。
	for _, pending in ipairs(pendingBlockers) do
		local t = pending.ticket
		for _, key in ipairs(pending.keys) do
			local id = (t.effort or "") .. "/" .. key
			table.insert(t.blockedBy, id)
			if byId[id] == nil then
				t.unresolvedBlockers = true
			end
		end
	end

	return result
end

return M
