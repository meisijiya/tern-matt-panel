--!strict
-- 插件逻辑的测试：不需要 Tern 在跑。
--
--   luau test/run_tests.luau
--
-- tern 的 API 用内存桩顶替：kv 是一个表，fs 是一张路径表。
-- 桩只实现被测代码真正用到的那部分。

-- ---------------------------------------------------------------- stub ----

local kvStore: { [string]: any } = {}
local fsFiles: { [string]: string } = {}
local fsDirs: { [string]: boolean } = {}
local env: { [string]: string } = { HOME = "C:/home", USERPROFILE = "C:/home" }
local toasts: { { level: string, text: string, sub: string? } } = {}
local copied: { string } = {}
local timers: { { ms: number, fn: (any) -> () } } = {}
local commands: { [string]: any } = {}
local statusFn: ((any) -> any)? = nil
local chromeRefreshes = 0
local handlers: { [string]: (any, any) -> any } = {}
local blockDefs: { [string]: any } = {}
local asked: { { pane: number, text: string } } = {}
local typed: { { pane: number, text: string } } = {}

local function copy(v: any): any
	if type(v) ~= "table" then
		return v
	end
	local out = {}
	for k, val in pairs(v) do
		out[k] = copy(val)
	end
	return out
end

local function dirOf(path: string): string
	return string.match(path, "^(.*)/[^/]*$") or ""
end

local function baseOf(path: string): string
	return string.match(path, "([^/]*)$") or path
end

local ternStub: any

local function runProcess(argv: { string }, optsOrCb: any, cb: any): any
	local result = { status = 0, stdout = "", stderr = "", timed_out = false }
	local callback: ((any, any) -> ())? = nil
	if type(optsOrCb) == "function" then
		callback = optsOrCb
	elseif type(cb) == "function" then
		callback = cb
	end
	if callback then
		callback(result, nil)
		return
	end
	local aw: any = {}
	function aw:next(fn: (any, any, any) -> ())
		fn(result, nil, nil)
	end
	return aw
end

ternStub = {
	kv = {
		get = function(key: string): any
			return copy(kvStore[key])
		end,
		set = function(key: string, value: any)
			kvStore[key] = copy(value)
		end,
	},
	fs = {
		exists = function(path: string): boolean
			return fsFiles[path] ~= nil or fsDirs[path] == true
		end,
		read = function(path: string): string
			local text = fsFiles[path]
			if text == nil then
				error("no such file: " .. path)
			end
			return text
		end,
		write = function(path: string, text: string)
			fsFiles[path] = text
			fsDirs[dirOf(path)] = true
		end,
		list = function(path: string): { string }
			local out = {}
			local prefix = path .. "/"
			for p in pairs(fsFiles) do
				if string.sub(p, 1, #prefix) == prefix and not string.find(string.sub(p, #prefix + 1), "/", 1, true) then
					table.insert(out, string.sub(p, #prefix + 1))
				end
			end
			table.sort(out)
			return out
		end,
		mkdir = function(path: string)
			fsDirs[path] = true
		end,
		remove = function(path: string)
			fsFiles[path] = nil
		end,
	},
	getenv = function(name: string): string?
		return env[name]
	end,
	now = function(): number
		return 0
	end,
	chrome = {
		status = function(fn: (any) -> any)
			statusFn = fn
		end,
		refresh = function()
			chromeRefreshes += 1
		end,
	},
	timer = function(ms: number, fn: (any) -> ())
		table.insert(timers, { ms = ms, fn = fn })
		return { cancel = function() end }
	end,
	command = function(def: any)
		commands[def.id] = def
	end,
	on = function(name: string, fn: (any, any) -> any)
		handlers[name] = fn
	end,
	block = {
		define = function(id: string, def: any)
			blockDefs[id] = def
		end,
	},
	ui = {
		span = function(t: string, s: string?): any
			return { t = t, s = s }
		end,
		text = function(spans: any): any
			return { k = "text", p = { spans = spans } }
		end,
		col = function(children: { any }): any
			return { k = "col", c = children }
		end,
		row = function(children: { any }): any
			return { k = "row", c = children }
		end,
		list = function(items: { any }): any
			return { k = "list", p = {}, c = items }
		end,
		badge = function(t: string, tone: string): any
			return { k = "badge", p = { t = t, tone = tone } }
		end,
		button = function(t: string?, props: any?): any
			local p: { [string]: any } = props or {}
			p.t = t
			return { k = "button", p = p }
		end,
		md = function(text: string): any
			return { k = "md", p = { text = text } }
		end,
		node = function(kind: string, props: any?): any
			return { k = kind, p = props or {} }
		end,
		section = function(props: any): any
			return { k = "section", p = props or {} }
		end,
		rule = function(label: any): any
			return { k = "rule", p = { label = label } }
		end,
	},
	process = {
		run = runProcess,
	},
	log = function(...) end,
}

local function reset()
	kvStore = {}
	fsFiles = {}
	fsDirs = {}
	toasts = {}
	copied = {}
	timers = {}
	chromeRefreshes = 0
	asked = {}
	typed = {}
end

reset()
tern = ternStub

local util = (function()
-- 纯逻辑工具：trim / startsWith / splitLines / slug / deepCopy / contains。
-- 不依赖 tern，可在 luau CLI 下单测。v1 不做文本编辑，故不含 UTF-16 光标那套。

local M = {}

--- 去掉首尾空白。
function M.trim(s: string): string
	return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- 字符串是否以 prefix 开头。
function M.startsWith(s: string, prefix: string): boolean
	return string.sub(s, 1, #prefix) == prefix
end

--- 按行切分，兼容 \r\n 与 \n，去掉行尾 \r。
function M.splitLines(s: string): { string }
	local out: { string } = {}
	local start = 1
	while start <= #s do
		local nl = string.find(s, "\n", start, true)
		if nl then
			local line = s:sub(start, nl - 1)
			if line:sub(-1) == "\r" then
				line = line:sub(1, -2)
			end
			table.insert(out, line)
			start = nl + 1
		else
			local line = s:sub(start)
			if line:sub(-1) == "\r" then
				line = line:sub(1, -2)
			end
			table.insert(out, line)
			break
		end
	end
	return out
end

--- slug：小写字母数字，其余折成单个连字符。
function M.slug(s: string): string
	local out = ""
	local dash = false
	for i = 1, #s do
		local c = s:sub(i, i):lower()
		if c:match("[a-z0-9]") then
			out ..= c
			dash = false
		elseif not dash and out ~= "" then
			out ..= "-"
			dash = true
		end
	end
	return (out:gsub("-+$", ""))
end

--- 深拷贝一张表（仅 JSON 兼容的值）。
function M.deepCopy<T>(v: T): T
	if type(v) ~= "table" then
		return v
	end
	local out = {}
	for k, val in v do
		out[k] = M.deepCopy(val)
	end
	return out
end

--- 数组里的某项是否存在。
function M.contains(list: { any }, needle: any): boolean
	for _, v in ipairs(list) do
		if v == needle then
			return true
		end
	end
	return false
end

return M

end)()
local paths = (function()
-- 技能包发现：定位本机已装的中文 mattpocock 技能组根目录，读其版本。
-- 只读探测；失败返回 nil，让上层显示安装提示而非崩。
-- 仅本文件使用 tern.*（fs / getenv）。

local M = {}

--- 取 home 目录：Windows 用 USERPROFILE，其余用 HOME；tern.fs 不展开 ~。
function M.home(): string?
	local p = tern.getenv("USERPROFILE")
	if p and p ~= "" then
		return p
	end
	return tern.getenv("HOME")
end

--- 探测技能包根：先 marketplaces/mattpocock，再 plugins 下找 mattpocock___mattpocock-skills__*。
--- 任一命中即返回，都不在返回 nil。
function M.skillPackageRoot(): string?
	local home = M.home()
	if not home then
		return nil
	end
	local market = home .. "/.omp/plugins/cache/marketplaces/mattpocock"
	if pcall(tern.fs.exists, market) and tern.fs.exists(market) then
		return market
	end
	local plugins = home .. "/.omp/plugins/cache/plugins"
	if not pcall(tern.fs.exists, plugins) or not tern.fs.exists(plugins) then
		return nil
	end
	local ok, names = pcall(tern.fs.list, plugins)
	if not ok then
		return nil
	end
	for _, name in ipairs(names) do
		if name:match("^mattpocock___mattpocock%-skills__") then
			return plugins .. "/" .. name
		end
	end
	return nil
end

--- 读技能包根的 package.json 的 version；不存在/不可解析时返回 nil。
--- 不写 JSON 解析器：只扫字面量 "version" 后跟的引号字符串。
function M.packageVersion(root: string): string?
	local path = root .. "/package.json"
	if not pcall(tern.fs.exists, path) or not tern.fs.exists(path) then
		return nil
	end
	local ok, text = pcall(tern.fs.read, path)
	if not ok then
		return nil
	end
	local ver = text:match('"version"%s*:%s*"(.-)"')
	return ver
end

return M

end)()
local skills = (function()
-- 技能包读取：解析 SKILL.md frontmatter、构造技能记录、列目录读整包。
-- 仅本模块允许使用 tern.fs；其余 lib 纯逻辑，便于 luau CLI 单测。
-- 对技能目录只读：绝不把正文复制进本仓库或插件数据目录。


local M = {}

export type Skill = {
	name: string,
	description: string,
	category: string,
	size: number,
	extras: { string },
	-- SKILL.md 的绝对路径：点开才读正文时要用。
	path: string,
}

export type SkillPackage = {
	root: string,
	version: string?,
	skills: { Skill },
}

--- 取路径的父目录。
local function parentOf(p: string): string
	local norm = p:gsub("[\\/]+", "/"):gsub("/$", "")
	local parent = norm:match("^(.*)/[^/]+$")
	return parent or ""
end

--- 取路径的最后一段（basename）。
local function basename(p: string): string
	local norm = p:gsub("[\\/]+", "/"):gsub("/$", "")
	local base = norm:match("/([^/]+)$")
	return base or norm
end

--- frontmatter 切分：以 "---" 行夹住 key: value。
function M.splitFrontmatter(text: string): (string?, string)
	local head, body = string.match(text, "^%-%-%-\r?\n(.-)\r?\n%-%-%-\r?\n(.*)$")
	if not head then
		return nil, text
	end
	return head, body
end

--- 只认 key: value，value 原样保留（参考 tern-prompt-panel/lib/templates.luau）。
function M.parseFrontmatter(text: string): { [string]: string }
	local meta = {}
	for line in string.gmatch(text, "[^\r\n]+") do
		local key, value = string.match(line, "^([%w_%-]+):%s*(.*)$")
		if key then
			meta[key] = util.trim(value)
		end
	end
	return meta
end

--- 解析单个技能：dir=技能目录，path=SKILL.md 路径，text=SKILL.md 正文。
--- category 取自技能目录在 skills/ 下的父分类（如 engineering）。
--- extras 只列技能目录内的兄弟文件名（不含 SKILL.md），绝不读其正文。
--- frontmatter 缺 name 视为无效技能，返回 nil。
function M.parseSkill(dir: string, path: string, text: string): Skill?
	local head = M.splitFrontmatter(text)
	if not head then
		return nil
	end
	local meta = M.parseFrontmatter(head)
	local name = meta.name
	local description = meta.description or ""
	if not name or name == "" then
		return nil
	end
	local category = basename(parentOf(dir))
	local extras: { string } = {}
	local ok, names = pcall(tern.fs.list, dir)
	if ok then -- 探针失败（无权限/不存在）时静默给空表，不崩。
		for _, n in ipairs(names) do
			if n ~= "SKILL.md" then
				table.insert(extras, n)
			end
		end
	end
	return {
		name = name,
		description = description,
		category = category,
		size = #text,
		extras = extras,
		path = path,
	}
end

--- 读一个技能的 SKILL.md 正文。点开才读，不预读。
--- frontmatter 已经解析过，展示时要去掉：正文区只留技能说明本身。
function M.readDoc(skill: Skill): string?
	local ok, text = pcall(tern.fs.read, skill.path)
	if not ok or type(text) ~= "string" then
		return nil
	end
	local head, body = M.splitFrontmatter(text)
	if head then
		return util.trim(body)
	end
	return text
end

--- 这个技能是不是默认隐藏的分类（in-progress / deprecated）。
function M.isHidden(skill: Skill): boolean
	return skill.category == "in-progress" or skill.category == "deprecated"
end

--- 列 root/skills/<category>/<skill>/SKILL.md，构造整包；根或 skills 目录不存在返回 nil。
function M.readPackage(root: string): SkillPackage?
	if not root or not (pcall(tern.fs.exists, root .. "/skills") and tern.fs.exists(root .. "/skills")) then
		return nil
	end
	local skills: { Skill } = {}
	local okCats, cats = pcall(tern.fs.list, root .. "/skills")
	if not okCats then
		return nil
	end
	for _, cat in ipairs(cats) do
		local catDir = root .. "/skills/" .. cat
		local okSkills, skillDirs = pcall(tern.fs.list, catDir)
		if okSkills then
			for _, sdir in ipairs(skillDirs) do
				local skillDir = catDir .. "/" .. sdir
				local skPath = skillDir .. "/SKILL.md"
				if pcall(tern.fs.exists, skPath) and tern.fs.exists(skPath) then
					local ok, text = pcall(tern.fs.read, skPath)
					if ok then
						local sk = M.parseSkill(skillDir, skPath, text)
						if sk then
							table.insert(skills, sk)
						end
					end
				end
			end
		end
	end
	return {
		root = root,
		version = paths.packageVersion(root),
		skills = skills,
	}
end

return M

end)()
local lanes = (function()
-- 泳道：直接取自技能包原生阶段链（spec §4）。插件自带映射，因为包本身不声明 lane。
-- 不在任何命名 lane 的技能落入「旁路与专项」，绝不丢弃。


local M = {}

export type Skill = skills.Skill

export type Lane = {
	id: string,
	title: string,
	skills: { string },
}

--- 五个泳道，技能名取自 spec §4；「旁路与专项」留空，由 groupSkills 兜底填充。
local LANES: { Lane } = {
	{ id = "entry", title = "入口", skills = { "ask-matt", "triage", "diagnosing-bugs", "wayfinder", "grill-with-docs" } },
	{ id = "planning", title = "规划", skills = { "to-spec", "to-tickets" } },
	{ id = "implementation", title = "实施", skills = { "implement", "implement-spec", "tdd" } },
	{ id = "review", title = "审查与交付", skills = { "code-review", "pr", "retro" } },
	{ id = "side", title = "旁路与专项", skills = {} },
}
M.LANES = LANES

--- 返回包含该技能的泳道，不在任何泳道返回 nil。
function M.laneOf(name: string): Lane?
	for _, lane in ipairs(M.LANES) do
		if util.contains(lane.skills, name) then
			return lane
		end
	end
	return nil
end

--- 按 lane 顺序归组；未命中的技能落入最后一个 lane（旁路与专项）。
function M.groupSkills(skillsIn: { Skill }): { Lane }
	local out: { Lane } = {}
	local placed: { [string]: boolean } = {}
	for _, lane in ipairs(M.LANES) do
		local group: Lane = { id = lane.id, title = lane.title, skills = {} }
		for _, sk in ipairs(skillsIn) do
			if util.contains(lane.skills, sk.name) then
				table.insert(group.skills, sk.name)
				placed[sk.name] = true
			end
		end
		table.insert(out, group)
	end
	local side = out[#out]
	for _, sk in ipairs(skillsIn) do
		if not placed[sk.name] then
			table.insert(side.skills, sk.name)
		end
	end
	return out
end

return M

end)()
local tracker = (function()
-- wayfinder 地图与票的归一化：解析 gh issue list --json 产出的对象。
-- 不解析成 JSON 字符串（宿主半边负责解码），本模块吃已解码的 Lua 表，纯逻辑可单测。
-- 解析容错：gh 字段缺省时降级为空/默认，不崩（spec §7 已知 gh 输出形状随版本变）。


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

end)()
local templates = (function()
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

end)()
local commands = (function()
-- 注入命令构造：技能 → 一行 /技能名；票 → 动作模板渲染结果。


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

end)()
do -- host.luau
-- 宿主半边：面板的画面（tern.ui 节点树）与数据获取。
--
-- 数据获取放在这一侧：`gh` 子进程与文件读取在宿主半边都能做（实测见
-- docs/research/host-half-runtime.md）。异步回调里改 state 再 cx:render() 即可重画，
-- 不必绕 kv（见 docs/research/host-async-render.md）。
--
-- 需要窗口半边才能做的只有一件：把提示词注入邻近 agent（cx.agents:ask 是 window-only）。
-- 那一段走 tern.kv 传令：这里写 action 键，窗口半边轮询并执行。

local ui = tern.ui

local ACTION_KEY = "action"
local RESULT_KEY = "result"
local REPO_KEY = "repo"
local SEQ_KEY = "seq"
local BLOCK_ID = "matt"

type View = "skills" | "board" | "ticket"

type State = {
	view: View,
	-- 技能面板
	skills: { skills.Skill },
	lanes: { lanes.Lane },
	-- 选中的技能名（列表用名字做行 id，鼠标点选与键盘移动共用）
	skillSel: string?,
	skillBody: string?,
	showHidden: boolean,
	-- 任务板
	maps: { tracker.Map },
	tickets: { tracker.Ticket },
	-- 选中的地图号与票号
	mapSel: number?,
	ticketSel: number?,
	-- 票详情
	ticket: tracker.Ticket?,
	ticketBody: string?,
	-- 通用
	message: string?,
	loading: boolean,
	repo: string?,
	skillVersion: string?,
	hasSkills: boolean,
}

--- 空状态。init 与 save 恢复共用。
local function blank(): State
	return {
		view = "skills",
		skills = {},
		lanes = {},
		skillSel = nil,
		skillBody = nil,
		showHidden = false,
		maps = {},
		tickets = {},
		mapSel = nil,
		ticketSel = nil,
		ticket = nil,
		ticketBody = nil,
		message = nil,
		loading = false,
		repo = nil,
		skillVersion = nil,
		hasSkills = false,
	}
end

--- 按泳道顺序排平的技能表，上下移动与选中都用它。
local function flatSkills(state: State): { skills.Skill }
	local byName: { [string]: skills.Skill } = {}
	for _, s in ipairs(state.skills) do
		byName[s.name] = s
	end
	local out: { skills.Skill } = {}
	for _, lane in ipairs(state.lanes) do
		for _, name in ipairs(lane.skills) do
			local s = byName[name]
			if s then
				table.insert(out, s)
			end
		end
	end
	return out
end

--- 装填技能面板：探测技能包，读清单，按泳道分组。
local function loadSkills(state: State)
	local root = paths.skillPackageRoot()
	if not root then
		state.hasSkills = false
		state.skills = {}
		state.lanes = {}
		state.skillVersion = nil
		return
	end
	local pkg = skills.readPackage(root)
	if not pkg then
		state.hasSkills = false
		state.skills = {}
		state.lanes = {}
		return
	end
	state.hasSkills = true
	state.skillVersion = pkg.version
	local visible: { skills.Skill } = {}
	for _, s in ipairs(pkg.skills) do
		if state.showHidden or not skills.isHidden(s) then
			table.insert(visible, s)
		end
	end
	state.skills = visible
	state.lanes = lanes.groupSkills(visible)
end

--- 真正拉 issue 的那一步。
local fetchIssues: (State, BlockCx, string) -> ()

--- 从 git remote 推断 owner/repo。
local function inferRepo(cx: BlockCx, cb: (string?) -> ())
	local cwd = cx.cwd
	if not cwd then
		cb(nil)
		return
	end
	tern.process.run({ "git", "-C", cwd, "remote", "get-url", "origin" }):next(function(result: any, _err: any, _cx: any)
		if result == nil or result.status ~= 0 then
			cb(nil)
			return
		end
		local url = tostring(result.stdout or "")
		local owner, repo = string.match(url, "[:/]([^/:]+)/([^/%.]+)%.git")
		if owner and repo then
			cb(owner .. "/" .. repo)
		else
			cb(nil)
		end
	end)
end

--- 把 gh 的 JSON 输出解码成表。解码失败返回 nil。
local function decodeIssues(text: string): { any }?
	local ok, value = pcall(tern.json.decode, text)
	if not ok or type(value) ~= "table" then
		return nil
	end
	return value
end

--- 拉任务板：地图、票、依赖。用 gh 的 JSON 输出。
local function loadBoard(state: State, cx: BlockCx)
	if state.loading then
		return
	end
	state.loading = true
	-- 用户手动指定的仓库优先（写在 kv 里，跨窗口共享）。
	local ok, value = pcall(tern.kv.get, REPO_KEY)
	local chosen: string? = nil
	if ok and type(value) == "table" and type(value.repo) == "string" and value.repo ~= "" then
		chosen = value.repo
	end
	local repo = chosen or state.repo
	if not repo then
		inferRepo(cx, function(found: string?)
			if not found then
				state.loading = false
				state.message = "找不到仓库：当前目录不是 git 仓库，按 R 手动指定"
				cx:render()
				return
			end
			state.repo = found
			fetchIssues(state, cx, found)
		end)
		return
	end
	state.repo = repo
	fetchIssues(state, cx, repo)
end

--- 真正拉 issue 的那一步。
fetchIssues = function(state: State, cx: BlockCx, repo: string)
	local fields = "number,title,body,state,url,labels,assignees,parent,blockedBy"
	tern.process.run({
		"gh",
		"issue",
		"list",
		"--repo",
		repo,
		"--state",
		"all",
		"--limit",
		"200",
		"--json",
		fields,
	}):next(function(result: any, _err: any, _cx: any)
		if result == nil or result.status ~= 0 then
			state.loading = false
			state.message = "gh 拉取失败：" .. tostring(if result then result.stderr else "无输出")
			cx:render()
			return
		end
		local issues = decodeIssues(tostring(result.stdout or ""))
		if not issues then
			state.loading = false
			state.message = "gh 输出解析失败"
			cx:render()
			return
		end
		state.tickets = tracker.parseIssues(issues)
		state.maps = tracker.groupByMap(issues)
		state.loading = false
		if #state.tickets == 0 then
			state.message = "这个仓库还没有 issue"
		end
		-- 状态栏胶囊要数字，写进 result 键给窗口半边读。
		tern.kv.set(RESULT_KEY, {
			frontier = #tracker.computeFrontier(state.tickets),
			version = state.skillVersion or "—",
		})
		cx:render()
	end)
end

--- 写一条给窗口半边的指令。
---
--- seq 必须全局单调递增并持久化：窗口半边启动时会把 kv 里已有的 action.seq 当作"已处理"，
--- 若新请求的 seq 不比它大，请求会被静默丢弃。所以序号要同时越过
--- 计数器与现存 action 的 seq（两者可能不同步——计数器是新的，action 是旧的）。
local function nextSeq(): number
	local last = 0
	local ok, value = pcall(tern.kv.get, SEQ_KEY)
	if ok and type(value) == "table" and type(value.n) == "number" then
		last = value.n
	end
	local okAction, action = pcall(tern.kv.get, ACTION_KEY)
	if okAction and type(action) == "table" and type(action.seq) == "number" and action.seq > last then
		last = action.seq
	end
	local seq = last + 1
	tern.kv.set(SEQ_KEY, { n = seq })
	return seq
end

local function sendAction(state: State, cx: BlockCx, kind: string, body: string, name: string)
	tern.kv.set(ACTION_KEY, {
		seq = nextSeq(),
		kind = kind,
		pane = cx.pane,
		body = body,
		name = name,
	})
end

--- 让窗口半边弹输入框问仓库名。当前目录不是 git 仓库、或用户想换仓库时用。
local function pickRepo(state: State, cx: BlockCx)
	tern.kv.set(ACTION_KEY, {
		seq = nextSeq(),
		kind = "pick-repo",
		pane = cx.pane,
		body = state.repo or "",
		name = "仓库",
	})
end

--- 注入一段文本到邻近 agent（真正执行在窗口半边）。
local function inject(state: State, cx: BlockCx, body: string, name: string)
	sendAction(state, cx, "inject", body, name)
	state.message = "已提交：" .. name
end

--- 票的动作按钮：按票类型给出。
local function actionsFor(t: tracker.Ticket): { { kind: string, tpl: string, label: string, icon: string } }
	local out = {}
	if not t.type then
		return out
	end
	for _, tpl in ipairs(templates.TEMPLATES) do
		if tpl.id == t.type then
			table.insert(out, { kind = t.type, tpl = tpl.id, label = tpl.title, icon = "sparkle" })
		end
	end
	return out
end

---------------------------------------------------------------- 渲染

-- 列表的行 id 前缀：区域.列表key.行id。鼠标点选与键盘移动共用同一份选中状态。
local SKILL_LIST = "skills"
local MAP_LIST = "maps"
local TICKET_LIST = "tickets"

--- 技能区：按泳道分组，全部走一个可点列表。
--- 泳道用 detail 列显示在行尾，鼠标点行即选中。
local function skillsView(state: State, cx: BlockCx): Node
	local main: { Node } = {}

	if not state.hasSkills then
		table.insert(main, ui.text(ui.span("没找到中文技能包", "warning")))
		table.insert(main, ui.text(ui.link(
			"安装：https://github.com/devcxl/mattpocock-skills-zh",
			"https://github.com/devcxl/mattpocock-skills-zh"
		)))
		table.insert(main, ui.text(ui.span(
			"面板不自带技能，也不代装。装好后点「刷新」。",
			"muted"
		)))
		return ui.col(main)
	end

	local flat = flatSkills(state)
	local items: { any } = {}
	for _, s in ipairs(flat) do
		local lane = ""
		for _, l in ipairs(state.lanes) do
			if table.find(l.skills, s.name) then
				lane = l.title
				break
			end
		end
		table.insert(items, {
			label = s.name,
			detail = lane,
			value = "/" .. s.name,
			icon = "sparkle",
			tone = if s.name == state.skillSel then "accent" else nil,
		})
	end

	local list = ui.list(items)
	local kids = list.c or {}
	for i, s in ipairs(flat) do
		local p: { [string]: any } = kids[i].p or {}
		p.key = s.name
		kids[i].p = p
	end
	local lp: { [string]: any } = list.p or {}
	lp.key = SKILL_LIST
	lp.selected = state.skillSel
	lp.empty = { ui.span("没有技能", "muted") }
	lp.max = { lines = math.max(6, cx.rows - 8) }
	list.p = lp

	table.insert(main, ui.text({
		ui.span("技能", "strong"),
		ui.span(string.format("  %s · %d 个", state.skillVersion or "未知版本", #flat), "muted"),
	}))
	table.insert(main, list)

	if state.skillBody then
		table.insert(main, ui.rule(ui.span(state.skillSel or "")))
		table.insert(main, ui.md(state.skillBody))
	end

	return ui.col(main)
end

--- 任务板区：地图列表与前沿票列表，都是可点的。
local function boardView(state: State, cx: BlockCx): Node
	local main: { Node } = {}

	if state.loading then
		table.insert(main, ui.text(ui.span("正在拉取…", "muted")))
		return ui.col(main)
	end
	if state.repo then
		table.insert(main, ui.text({
			ui.span(state.repo, "muted"),
			ui.span("  点行选中，点「刷新」重取", "muted"),
		}))
	end

	-- 地图
	local mapItems: { any } = {}
	for _, m in ipairs(state.maps) do
		table.insert(mapItems, {
			label = m.title,
			detail = string.format("%d 票", #m.tickets),
			icon = "map",
			tone = if m.number == state.mapSel then "accent" else nil,
		})
	end
	local mapList = ui.list(mapItems)
	local mapKids = mapList.c or {}
	for i, m in ipairs(state.maps) do
		local p: { [string]: any } = mapKids[i].p or {}
		p.key = tostring(m.number)
		mapKids[i].p = p
	end
	local mapLp: { [string]: any } = mapList.p or {}
	mapLp.key = MAP_LIST
	mapLp.selected = if state.mapSel then tostring(state.mapSel) else nil
	mapLp.empty = { ui.span("没有 wayfinder:map 地图", "muted") }
	mapLp.max = { lines = math.max(4, math.floor((cx.rows - 12) / 2)) }
	mapList.p = mapLp
	table.insert(main, ui.text(ui.span("地图", "strong")))
	table.insert(main, mapList)

	-- 前沿票
	local frontier = tracker.computeFrontier(state.tickets)
	local ticketItems: { any } = {}
	for _, t in ipairs(frontier) do
		table.insert(ticketItems, {
			label = t.title,
			detail = t.type,
			icon = "ticket",
			tone = if t.number == state.ticketSel then "accent" else nil,
		})
	end
	local ticketList = ui.list(ticketItems)
	local ticketKids = ticketList.c or {}
	for i, t in ipairs(frontier) do
		local p: { [string]: any } = ticketKids[i].p or {}
		p.key = tostring(t.number)
		ticketKids[i].p = p
	end
	local ticketLp: { [string]: any } = ticketList.p or {}
	ticketLp.key = TICKET_LIST
	ticketLp.selected = if state.ticketSel then tostring(state.ticketSel) else nil
	ticketLp.empty = { ui.span("没有可领的票", "muted") }
	ticketLp.max = { lines = math.max(4, math.floor((cx.rows - 12) / 2)) }
	ticketList.p = ticketLp
	table.insert(main, ui.text(ui.span(string.format("前沿（%d）", #frontier), "strong")))
	table.insert(main, ticketList)

	return ui.col(main)
end

--- 票详情区：描述、动作按钮、阻塞关系。
local function ticketView(state: State): Node
	local t = state.ticket
	if not t then
		return ui.text(ui.span("从任务板点一张票", "muted"))
	end
	local main: { Node } = {}
	table.insert(main, ui.text({
		ui.span(t.title, "strong"),
		ui.span("  " .. tostring(t.type or "无类型"), "muted"),
	}))
	table.insert(main, ui.text(ui.link(t.url, t.url, "muted")))

	local buttons: { Node } = {}
	for _, a in ipairs(actionsFor(t)) do
		table.insert(buttons, ui.button(a.label, {
			icon = a.icon,
			variant = "primary",
			size = "sm",
			actions = { click = "act:" .. a.tpl },
		}))
	end
	table.insert(buttons, ui.button("复制", {
		icon = "copy",
		size = "sm",
		actions = { click = "copy-ticket" },
	}))
	table.insert(buttons, ui.button("打开链接", {
		icon = "link",
		size = "sm",
		actions = { click = "open-ticket" },
	}))
	table.insert(buttons, ui.button("返回任务板", {
		icon = "back",
		size = "sm",
		actions = { click = "back-board" },
	}))
	table.insert(main, ui.row(buttons))

	if #t.blockedBy > 0 then
		table.insert(main, ui.text(ui.span("被阻塞：" .. table.concat(t.blockedBy, ", "), "muted")))
	end

	local body = state.ticketBody or ""
	if body ~= "" then
		table.insert(main, ui.rule(ui.span("描述")))
		table.insert(main, ui.md(body))
	end

	return ui.col(main)
end

--- 顶部工具条：鼠标能点的视图切换与常用操作。
local function toolbar(state: State): Node
	local buttons: { Node } = {
		ui.button("技能", {
			icon = "sparkle",
			size = "sm",
			variant = if state.view == "skills" then "primary" else "default",
			actions = { click = "view-skills" },
		}),
		ui.button("任务板", {
			icon = "map",
			size = "sm",
			variant = if state.view == "board" then "primary" else "default",
			actions = { click = "view-board" },
		}),
		ui.button("刷新", {
			icon = "refresh",
			size = "sm",
			actions = { click = "refresh" },
		}),
		ui.button("换仓库", {
			icon = "repo",
			size = "sm",
			actions = { click = "pick-repo" },
		}),
		ui.button(if state.showHidden then "隐藏实验技能" else "显示实验技能", {
			icon = "eye",
			size = "sm",
			actions = { click = "toggle-hidden" },
		}),
	}
	return ui.row(buttons)
end

--- 底部提示条：键位说明。
local function dockView(state: State): Node
	local items: { Node } = {
		ui.text(ui.span("鼠标点行选中 · 点按钮操作", "muted")),
		ui.text(ui.span("↑↓ 移动 · Enter 看原文 · i 注入", "muted")),
	}
	if state.message then
		table.insert(items, ui.text(ui.span(state.message, "accent")))
	end
	return ui.row(items)
end

---------------------------------------------------------------- 块定义

--- 技能列表里当前选中的技能。
local function selectedSkill(state: State): skills.Skill?
	local flat = flatSkills(state)
	if #flat == 0 then
		return nil
	end
	for _, s in ipairs(flat) do
		if s.name == state.skillSel then
			return s
		end
	end
	return flat[1]
end

--- 任务板里当前选中的票（前沿里的）。
local function selectedTicket(state: State): tracker.Ticket?
	local frontier = tracker.computeFrontier(state.tickets)
	if #frontier == 0 then
		return nil
	end
	for _, t in ipairs(frontier) do
		if t.number == state.ticketSel then
			return t
		end
	end
	return frontier[1]
end

--- 选中一个技能并读出原文。
local function openSkill(state: State, name: string)
	local byName: { [string]: skills.Skill } = {}
	for _, s in ipairs(state.skills) do
		byName[s.name] = s
	end
	local s = byName[name]
	if not s then
		return
	end
	state.skillSel = name
	state.skillBody = skills.readDoc(s)
end

tern.block.define(BLOCK_ID, {
	init = function(cx: BlockCx, _args: { string }, saved: any): State
		local state = blank()
		if type(saved) == "table" then
			state.view = (saved.view :: View) or "skills"
			state.showHidden = saved.showHidden == true
			state.repo = if type(saved.repo) == "string" then saved.repo else nil
			state.skillSel = if type(saved.skillSel) == "string" then saved.skillSel else nil
		end
		loadSkills(state)
		loadBoard(state, cx)
		return state
	end,

	title = function(state: State): string
		if state.view == "skills" then
			return string.format("Matt 面板 · 技能 %d", #state.skills)
		elseif state.view == "board" then
			return string.format("Matt 面板 · 前沿 %d", #tracker.computeFrontier(state.tickets))
		end
		return string.format("Matt 面板 · %s", state.ticket and state.ticket.title or "票")
	end,

	view = function(state: State, cx: BlockCx): BlockView
		local main: Node
		if state.view == "skills" then
			main = ui.col({ toolbar(state), skillsView(state, cx) })
		elseif state.view == "board" then
			main = ui.col({ toolbar(state), boardView(state, cx) })
		else
			main = ui.col({ toolbar(state), ticketView(state) })
		end
		return { main = main, dock = dockView(state) }
	end,

	key = function(state: State, key: Key, cx: BlockCx): boolean?
		if key.name == "tab" then
			if state.view == "skills" then
				state.view = "board"
			else
				state.view = "skills"
			end
			state.message = nil
			return true
		end
		if key.name == "escape" then
			if state.view == "ticket" then
				state.view = "board"
				state.ticket = nil
				state.ticketBody = nil
				return true
			end
			return false
		end
		if key.name == "r" and not key.shift then
			loadSkills(state)
			loadBoard(state, cx)
			state.message = "已刷新"
			return true
		end
		if key.name == "r" and key.shift then
			pickRepo(state, cx)
			return true
		end
		if key.name == "s" then
			state.showHidden = not state.showHidden
			loadSkills(state)
			state.message = if state.showHidden then "显示 in-progress / deprecated" else "只显示正式技能"
			return true
		end

		if state.view == "skills" then
			local flat = flatSkills(state)
			if key.name == "up" then
				local cur = selectedSkill(state)
				local at = 1
				for i, s in ipairs(flat) do
					if cur and s.name == cur.name then
						at = i
						break
					end
				end
				state.skillSel = flat[math.max(1, at - 1)].name
				state.skillBody = nil
				return true
			end
			if key.name == "down" then
				local cur = selectedSkill(state)
				local at = 1
				for i, s in ipairs(flat) do
					if cur and s.name == cur.name then
						at = i
						break
					end
				end
				state.skillSel = flat[math.min(#flat, at + 1)].name
				state.skillBody = nil
				return true
			end
			if key.name == "enter" then
				local s = selectedSkill(state)
				if not s then
					return false
				end
				-- Enter 只负责看原文；注入走 i 键，避免"按两次"这种要记住的约定。
				if state.skillBody then
					state.skillBody = nil
				else
					state.skillSel = s.name
					state.skillBody = skills.readDoc(s)
				end
				return true
			end
			if key.name == "i" then
				local s = selectedSkill(state)
				if not s then
					return false
				end
				inject(state, cx, commands.buildSkillCommand(s), s.name)
				return true
			end
			if key.name == "c" then
				local s = selectedSkill(state)
				if not s then
					return false
				end
				cx:copy(s.name)
				state.message = "已复制：" .. s.name
				return true
			end
			return false
		end

		if state.view == "board" then
			local frontier = tracker.computeFrontier(state.tickets)
			if key.name == "up" or key.name == "down" then
				local cur = selectedTicket(state)
				local at = 1
				for i, t in ipairs(frontier) do
					if cur and t.number == cur.number then
						at = i
						break
					end
				end
				local next_ = if key.name == "up" then math.max(1, at - 1) else math.min(#frontier, at + 1)
				if frontier[next_] then
					state.ticketSel = frontier[next_].number
				end
				return true
			end
			if key.name == "enter" then
				local t = selectedTicket(state)
				if not t then
					return false
				end
				state.ticket = t
				state.ticketBody = t.body
				state.view = "ticket"
				return true
			end
			if key.name == "c" then
				local t = selectedTicket(state)
				if not t then
					return false
				end
				cx:copy(t.title .. "\n" .. t.url)
				state.message = "已复制票信息"
				return true
			end
			if key.name == "o" then
				local t = selectedTicket(state)
				if not t then
					return false
				end
				cx:open(t.url)
				return true
			end
			return false
		end

		-- 票详情
		if key.name == "i" then
			local t = state.ticket
			if not t then
				return false
			end
			local tpl = templates.byTicketType(t.type)
			if not tpl then
				state.message = "这张票没有类型，没有对应动作"
				return true
			end
			inject(state, cx, commands.buildTicketCommand(t, tpl), t.title)
			return true
		end
		if key.name == "c" then
			local t = state.ticket
			if not t then
				return false
			end
			cx:copy(t.title .. "\n" .. t.url)
			state.message = "已复制票信息"
			return true
		end
		if key.name == "o" then
			local t = state.ticket
			if not t then
				return false
			end
			cx:open(t.url)
			return true
		end
		return false
	end,

	event = function(state: State, ev: UiEvent, cx: BlockCx)
		-- 列表点选：鼠标点行与键盘移动共用同一份选中状态。
		-- ev.item 形如 "main.<块号>.<列表key>.<行id>"，块号每窗不同，
		-- 所以只取最后一段当行 id。
		if (ev.ev == "select" or ev.ev == "activate") and type(ev.item) == "string" then
			local item = ev.item
			local last = string.match(item, "([^%.]+)$")
			if last then
				item = last
			end
			if state.view == "skills" then
				openSkill(state, item)
			elseif state.view == "board" then
				local n = tonumber(item)
				if n then
					local frontier = tracker.computeFrontier(state.tickets)
					for _, t in ipairs(frontier) do
						if t.number == n then
							state.ticketSel = n
							if ev.ev == "activate" then
								state.ticket = t
								state.ticketBody = t.body
								state.view = "ticket"
							end
							break
						end
					end
				end
			end
			return
		end
		if ev.ev ~= "action" or type(ev.act) ~= "string" then
			return
		end

		local act = ev.act
		if act == "view-skills" then
			state.view = "skills"
			state.message = nil
			return
		end
		if act == "view-board" then
			state.view = "board"
			state.message = nil
			return
		end
		if act == "refresh" then
			loadSkills(state)
			loadBoard(state, cx)
			state.message = "已刷新"
			return
		end
		if act == "pick-repo" then
			pickRepo(state, cx)
			return
		end
		if act == "toggle-hidden" then
			state.showHidden = not state.showHidden
			loadSkills(state)
			state.message = if state.showHidden then "显示 in-progress / deprecated" else "只显示正式技能"
			return
		end
		if act == "back-board" then
			state.view = "board"
			state.ticket = nil
			state.ticketBody = nil
			return
		end
		if act == "copy-ticket" then
			local t = state.ticket
			if not t then
				return
			end
			cx:copy(t.title .. "\n" .. t.url)
			state.message = "已复制票信息"
			return
		end
		if act == "open-ticket" then
			local t = state.ticket
			if not t then
				return
			end
			cx:open(t.url)
			return
		end
		if string.sub(act, 1, 4) == "act:" then
			local tpl = templates.byId(string.sub(act, 5))
			local t = state.ticket
			if not tpl or not t then
				return
			end
			inject(state, cx, commands.buildTicketCommand(t, tpl), t.title)
		end
	end,

	save = function(state: State): any
		return {
			view = state.view,
			showHidden = state.showHidden,
			repo = state.repo,
			skillSel = state.skillSel,
		}
	end,
})

end
do -- window.luau
-- 窗口半边：调色板命令、状态栏胶囊，以及把宿主半边发来的注入请求转交给邻近 agent。
--
-- 面板本身在宿主半边（host.luau）。两个半边不共享 Lua 状态，
-- 这里用 tern.kv 传令：宿主写 action 键，窗口轮询它并执行。
--
-- cx.agents:ask 是 window-only，所以注入只能在这一侧完成。


local KIND = "tern-matt-panel.matt"
local ACTION_KEY = "action"
local RESULT_KEY = "result"
local REPO_KEY = "repo"
local POLL_MS = 300

-- 最近聚焦的 agent：面板没有绑定目标时的兜底。
local lastAgent: number? = nil
-- 已经处理过的请求序号，避免重复注入。
local seenSeq = 0

--- 聚焦的 pane 是不是一个 agent。
local function agentPaneOf(cx: WindowCx): number?
	local focused = cx.session:focused()
	if not focused then
		return nil
	end
	for _, agent in ipairs(cx.agents:list()) do
		if agent.pane == focused then
			return agent.pane
		end
	end
	return nil
end

local function rememberAgent(cx: WindowCx)
	local pane = agentPaneOf(cx)
	if pane then
		lastAgent = pane
	end
end

--- 打开一个新面板：每个面板自己找旁边的 agent。
local function openPanel(cx: WindowCx)
	rememberAgent(cx)
	local pane = cx:new_block(KIND, nil, "beside")
	if pane == nil then
		cx:toast("error", "Matt 面板没有加载", "把插件装在运行面板的机器上。")
	end
end

--- 多行正文包成括号粘贴：agent 的输入框会整段粘进去，不会在第一个换行处提交。
local function pasteText(body: string): string
	if string.find(body, "\n", 1, true) then
		return "\27[200~" .. body .. "\27[201~"
	end
	return body
end

--- 切分树里目标 pane 的同胞子树，由近到远；目标不在树里时返回 nil。
local function siblingsOf(tree: any, target: number): { any }?
	if type(tree) ~= "table" then
		return nil
	end
	if tree.pane == target then
		return {}
	end
	for i = 1, #tree do
		local inner = siblingsOf(tree[i], target)
		if inner then
			local out: { any } = {}
			for _, s in ipairs(inner) do
				table.insert(out, s)
			end
			for j = 1, #tree do
				if j ~= i and tree[j] then
					table.insert(out, tree[j])
				end
			end
			return out
		end
	end
	return nil
end

--- 一棵子树里的全部 pane，按树的顺序。
local function panesIn(tree: any, out: { number }): { number }
	if type(tree) ~= "table" then
		return out
	end
	if tree.pane then
		table.insert(out, tree.pane)
	end
	for i = 1, #tree do
		panesIn(tree[i], out)
	end
	return out
end

--- 面板自己旁边的 agent：同 tab 的切分树里离它最近的 agent 块。
local function agentFor(cx: WindowCx, panelPane: number): number?
	local tab = cx.session:tab_of(panelPane)
	local layout = if tab then cx.session:layout(tab) else nil
	if not layout then
		return nil
	end
	local agents: { [number]: boolean } = {}
	for _, a in ipairs(cx.agents:list()) do
		agents[a.pane] = true
	end
	for _, sub in ipairs(siblingsOf(layout.root, panelPane) or {}) do
		for _, id in ipairs(panesIn(sub, {})) do
			if agents[id] then
				return id
			end
		end
	end
	return nil
end

--- 把正文发给某个 agent。出错时返回错误说明。
local function sendToAgent(cx: WindowCx, pane: number, body: string): string?
	for _, agent in ipairs(cx.agents:list()) do
		if agent.pane == pane then
			if agent.state == "working" then
				return "agent 正在忙，等它空闲再试"
			end
			if agent.delivery_error then
				return tostring(agent.delivery_error)
			end
			local ok, err = pcall(function()
				cx.agents:ask(pane, body)
			end)
			if not ok then
				return tostring(err)
			end
			return nil
		end
	end
	return "找不到那个 agent"
end

--- 状态栏用的数字：前沿票数与技能组版本。宿主半边算好后写在 result 键里。
local summary = { frontier = 0, version = "—" }

local function readSummary()
	local ok, value = pcall(tern.kv.get, RESULT_KEY)
	if not ok or type(value) ~= "table" then
		return
	end
	local frontier = value.frontier
	local version = value.version
	local changed = false
	if type(frontier) == "number" and frontier ~= summary.frontier then
		summary.frontier = frontier
		changed = true
	end
	if type(version) == "string" and version ~= summary.version then
		summary.version = version
		changed = true
	end
	if changed then
		tern.chrome.refresh()
	end
end

--- 执行宿主半边发来的请求。
---
--- kv 是全局的（所有窗口共享），所以要用 pane 归属来区分是哪个窗口的请求：
--- 宿主半边写请求时带上自己的 pane id，窗口半边只处理自己窗口里存在的那个 pane。
local function handleAction(cx: WindowCx)
	local ok, action = pcall(tern.kv.get, ACTION_KEY)
	if not ok or type(action) ~= "table" then
		return
	end
	local seq = action.seq
	if type(seq) ~= "number" or seq <= seenSeq then
		return
	end
	seenSeq = seq
	if type(action.body) ~= "string" then
		return
	end

	-- 不是本窗口的 pane，交给别的窗口处理。
	local pane = if type(action.pane) == "number" then action.pane else nil
	local mine = false
	if pane then
		-- pane lookup 对已关闭的 pane 可能抛错，不能让它冒泡。
		local okPane, info = pcall(cx.session.pane, cx.session, pane)
		mine = okPane and info ~= nil
	end
	if not mine then
		return
	end
	if action.kind == "pick-repo" then
		-- cx:prompt 只有窗口半边有，所以仓库名在这里问、在这里写回 kv。
		cx:prompt({ placeholder = "owner/repo", value = action.body, icon = "deck" }):next(function(repo, _err, cx)
			if not repo or not cx then
				return
			end
			repo = string.gsub(repo, "^%s+", "")
			repo = string.gsub(repo, "%s+$", "")
			if repo == "" then
				return
			end
			tern.kv.set(REPO_KEY, { repo = repo })
			cx:toast("success", "仓库：" .. repo, "按面板里的 r 刷新")
		end)
		return
	end

	if action.kind ~= "inject" then
		return
	end

	local agent = (if pane then agentFor(cx, pane) else nil) or lastAgent or agentPaneOf(cx)
	if not agent then
		-- 没有 agent 就退到剪贴板，别让用户白点一次。
		cx:copy(action.body)
		cx:toast("info", "没有可用的 agent", "正文已复制到剪贴板。")
		return
	end
	local err = sendToAgent(cx, agent, pasteText(action.body))
	if err then
		cx:copy(action.body)
		cx:toast("error", "提交失败：" .. tostring(action.name or ""), err .. "（正文已复制）")
		return
	end
	cx:toast("success", "已提交：" .. tostring(action.name or ""))
end

local poll: (WindowCx?) -> ()

poll = function(cx)
	-- 请求本身带 pane id，归属判断在 handleAction 里做，
	-- 所以这里不必先判断面板开没开（pane.block 在窗口 inspection 里未必填）。
	--
	-- 整段必须 pcall：出错冒泡会跳过下面的重新排 timer，
	-- 轮询链一断，窗口半边就再也收不到请求了。
	if cx then
		pcall(function()
			handleAction(cx)
			readSummary()
		end)
	end
	tern.timer(POLL_MS, poll)
end

tern.command({
	id = "panel",
	title = "Matt 面板",
	icon = "deck",
	run = openPanel,
})

tern.command({
	id = "skills",
	title = "技能速览",
	icon = "sparkle",
	run = function(cx: WindowCx)
		local root = paths.skillPackageRoot()
		if not root then
			cx:toast(
				"info",
				"没找到中文技能包",
				"安装：https://github.com/devcxl/mattpocock-skills-zh"
			)
			return
		end
		local pkg = skills.readPackage(root)
		if not pkg then
			cx:toast("info", "读不到技能包", tostring(root))
			return
		end
		local items: { any } = {}
		for _, s in ipairs(pkg.skills) do
			table.insert(items, {
				label = s.name,
				detail = s.description,
				group = s.category,
				body = commands.buildSkillCommand(s),
			})
		end
		cx:pick({ placeholder = "选一个技能", icon = "sparkle", items = items }):next(function(item, _err, cx)
			if not item or not cx then
				return
			end
			cx:copy(item.body)
			local agent = lastAgent or agentPaneOf(cx)
			if not agent then
				cx:toast("info", "已复制：" .. item.label, "没有聚焦的 agent")
				return
			end
			local err = sendToAgent(cx, agent, pasteText(item.body))
			if err then
				cx:toast("error", "提交失败：" .. item.label, err)
				return
			end
			cx:toast("success", "已提交：" .. item.label)
		end)
	end,
})

tern.chrome.status(function(_pane)
	return {
		{
			text = string.format("%d 可领 · 技能 %s", summary.frontier, summary.version),
			icon = "deck",
			command = "plugin.tern-matt-panel.panel",
		},
	}
end)

tern.on("focus", function(_ev, cx)
	rememberAgent(cx)
end)

-- 窗口重启后第一次看到的请求当作已处理，避免重复注入。
do
	local ok, action = pcall(tern.kv.get, ACTION_KEY)
	if ok and type(action) == "table" and type(action.seq) == "number" then
		seenSeq = action.seq
	end
end

-- 轮询从加载就开始：面板可以随时打开（也可能已经开着）。
tern.timer(POLL_MS, poll)

end


local pollTick: any = timers[1] and timers[1].fn

-- -------------------------------------------------------------- runner ----

local passed, failed = 0, 0
local failures: { string } = {}

local function test(name: string, fn: () -> ())
	reset()
	local ok, err = pcall(fn)
	if ok then
		passed += 1
	else
		failed += 1
		table.insert(failures, name .. ": " .. tostring(err))
	end
end

local function eq(actual: any, expected: any, what: string?)
	local label = what or "value"
	if actual ~= expected then
		error(string.format("%s: expected %s, got %s", label, tostring(expected), tostring(actual)), 2)
	end
end

local function count(t: { [any]: any }): number
	local n = 0
	for _ in pairs(t) do
		n += 1
	end
	return n
end

local function ok(cond: boolean, what: string)
	if not cond then
		error(what, 2)
	end
end

-- ---------------------------------------------------------------- tests ----

test("util.trim", function()
	eq(util.trim("  hello  "), "hello")
	eq(util.trim("\t\nx\r\n"), "x")
end)

test("util.startsWith", function()
	ok(util.startsWith("abcdef", "abc"))
	ok(not util.startsWith("abcdef", "xyz"))
end)

test("util.splitLines", function()
	local lines = util.splitLines("a\r\nb\nc")
	eq(#lines, 3)
	eq(lines[1], "a")
	eq(lines[2], "b")
	eq(lines[3], "c")
end)

test("util.slug", function()
	eq(util.slug("Hello, World!"), "hello-world")
	eq(util.slug("a--b"), "a-b")
end)

test("util.deepCopy", function()
	local src = { list = { 1, 2 }, name = "x" }
	local out = util.deepCopy(src)
	out.list[1] = 9
	eq(src.list[1], 1, "source untouched")
	eq(out.list[1], 9, "copy changed")
end)

test("util.contains", function()
	ok(util.contains({ "a", "b" }, "b"))
	ok(not util.contains({ "a", "b" }, "z"))
end)

test("skills.parseFrontmatter", function()
	local head = "name: wayfinder\ndescription: 路线图\nargument-hint: <topic>\ndisable-model-invocation: true"
	local meta = skills.parseFrontmatter(head)
	eq(meta.name, "wayfinder")
	eq(meta.description, "路线图")
	eq(meta["argument-hint"], "<topic>")
	eq(meta["disable-model-invocation"], "true")
end)

test("skills.parseSkill", function()
	fsDirs["/tmp/skills/engineering"] = true
	fsDirs["/tmp/skills/engineering/wayfinder"] = true
	fsFiles["/tmp/skills/engineering/wayfinder/SKILL.md"] = "---\nname: wayfinder\ndescription: 路线图\n---\n正文"
	fsFiles["/tmp/skills/engineering/wayfinder/tests.md"] = "tests"
	local sk = skills.parseSkill("/tmp/skills/engineering/wayfinder", "/tmp/skills/engineering/wayfinder/SKILL.md", "---\nname: wayfinder\ndescription: 路线图\n---\n正文")
	ok(sk ~= nil, "parsed")
	if sk then
		eq(sk.name, "wayfinder")
		eq(sk.description, "路线图")
		eq(sk.category, "engineering")
		ok(util.contains(sk.extras, "tests.md"), "extras")
	end
end)

test("lanes.laneOf", function()
	eq(lanes.laneOf("wayfinder").title, "入口")
	eq(lanes.laneOf("to-tickets").title, "规划")
	eq(lanes.laneOf("tdd").title, "实施")
	eq(lanes.laneOf("code-review").title, "审查与交付")
	eq(lanes.laneOf("retro").title, "审查与交付")
	ok(lanes.laneOf("research") == nil, "research not a named lane")
end)

test("lanes.groupSkills side lane catches research", function()
	local input = {
		{ name = "research", description = "", category = "x", size = 1, extras = {} },
	}
	local groups = lanes.groupSkills(input)
	local side = groups[#groups]
	ok(util.contains(side.skills, "research"), "research in side lane")
end)

test("lanes.groupSkills keeps unknown", function()
	local input = {
		{ name = "wayfinder", description = "", category = "x", size = 1, extras = {} },
		{ name = "totally-unknown-skill", description = "", category = "x", size = 1, extras = {} },
	}
	local groups = lanes.groupSkills(input)
	local total = 0
	for _, g in ipairs(groups) do
		total += #g.skills
	end
	eq(total, #input, "no drop")
	local side = groups[#groups]
	ok(util.contains(side.skills, "totally-unknown-skill"), "unknown in side")
end)

test("tracker.parseIssue type + assignees", function()
	local t = tracker.parseIssue({
		number = 1,
		title = "t",
		body = "",
		state = "OPEN",
		url = "u",
		labels = { "wayfinder:grilling", "bug" },
		assignees = { { login = "alice" }, "bob" },
	})
	ok(t ~= nil)
	if t then
		eq(t.type, "grilling")
		eq(#t.assignees, 2)
		eq(t.assignees[1], "alice")
		eq(t.assignees[2], "bob")
	end
	local t2 = tracker.parseIssue({
		number = 2,
		title = "t2",
		body = "",
		state = "OPEN",
		url = "u",
		labels = { "bug" },
	})
	ok(t2 ~= nil)
	if t2 then
		eq(t2.type, nil)
	end
end)

test("tracker.parseSections", function()
	local body = "intro\n## 尚未明确\n迷雾内容\n## 范围外\n范围外内容\n## 其他"
	local s = tracker.parseSections(body)
	eq(s.fog, "迷雾内容")
	eq(s.outOfScope, "范围外内容")
	local s2 = tracker.parseSections("no sections here")
	eq(s2.fog, nil)
	eq(s2.outOfScope, nil)
end)

test("tracker.computeFrontier", function()
	local mk = function(n, state, assignees, blockedBy)
		return {
			number = n,
			title = "t" .. tostring(n),
			body = "",
			state = state,
			url = "",
			labels = {},
			assignees = assignees or {},
			blockedBy = blockedBy or {},
			type = nil,
		}
	end
	local t1 = mk(1, "OPEN", {}, {})
	local t2 = mk(2, "OPEN", {}, { 1 }) -- blocked by open t1
	local t3 = mk(3, "OPEN", {}, { 4 }) -- blocked only by closed
	local t4 = mk(4, "CLOSED", {}, {})
	local t5 = mk(5, "OPEN", { "alice" }, {}) -- assigned
	local t6 = mk(6, "CLOSED", {}, {}) -- closed
	local tickets = { t1, t2, t3, t4, t5, t6 }
	local f = tracker.computeFrontier(tickets)
	-- frontier should contain t1 and t3 only
	local nums = {}
	for _, t in ipairs(f) do
		table.insert(nums, t.number)
	end
	ok(util.contains(nums, 1), "t1 in frontier")
	ok(not util.contains(nums, 2), "t2 blocked")
	ok(util.contains(nums, 3), "t3 unblocked")
	ok(not util.contains(nums, 5), "t5 assigned")
	ok(not util.contains(nums, 6), "t6 closed")
end)

test("templates.render", function()
	local tpl = templates.TEMPLATES[1]
	local out = templates.render(tpl, { url = "http://x", title = "T" })
	ok(string.find(out, "http://x", 1, true) ~= nil, "url substituted")
	-- no skill prose: templates must not mention SKILL.md body content
	ok(string.find(out, "SKILL.md", 1, true) == nil, "no skill prose")
end)

test("commands.buildSkillCommand", function()
	eq(commands.buildSkillCommand({ name = "wayfinder" }), "/wayfinder")
end)

test("commands.buildTicketCommand", function()
	local tpl = templates.TEMPLATES[4] -- task
	local ticket = { url = "http://ticket", title = "MyTask" }
	local out = commands.buildTicketCommand(ticket, tpl)
	ok(string.find(out, "http://ticket", 1, true) ~= nil, "url in ticket cmd")
	ok(string.find(out, "MyTask", 1, true) ~= nil, "title in ticket cmd")
end)

-- -------------------------------------------------------------- report ----

print(string.format("passed=%d failed=%d", passed, failed))
if failed > 0 then
	for _, f in ipairs(failures) do
		print("FAIL: " .. f)
	end
	error("tests failed")
end