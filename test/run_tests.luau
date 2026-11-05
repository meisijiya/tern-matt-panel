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

-- ==== MODULES ====

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

test("tracker.classify 四组互斥且覆盖非 spec 票", function()
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
			parent = nil,
			isSpec = false,
		}
	end
	local t1 = mk(1, "OPEN", {}, {})
	local t2 = mk(2, "OPEN", {}, { 1 })
	local t3 = mk(3, "OPEN", { "alice" }, {})
	local t4 = mk(4, "CLOSED", {}, {})
	-- 顶层 spec 有自己的卡片，不该在四组里再出现一遍
	local t5 = mk(5, "OPEN", {}, {})
	t5.isSpec = true
	local b = tracker.classify({ t1, t2, t3, t4, t5 })
	eq(#b.claimable, 1, "claimable")
	eq(b.claimable[1].number, 1)
	eq(#b.blocked, 1, "blocked")
	eq(b.blocked[1].number, 2)
	eq(#b.assigned, 1, "assigned")
	eq(b.assigned[1].number, 3)
	eq(#b.closed, 1, "closed")
	eq(b.closed[1].number, 4)
	-- 非 spec 票一张都不丢
	eq(#b.claimable + #b.assigned + #b.blocked + #b.closed, 4, "no non-spec ticket dropped")
	for _, group in ipairs({ b.claimable, b.assigned, b.blocked, b.closed }) do
		for _, t in ipairs(group) do
			ok(t.number ~= 5, "spec stays out of the four buckets")
		end
	end
end)

test("tracker.groupBySpec 按父 issue 挂工单", function()
	local spec = {
		number = 10, title = "spec", body = "", state = "OPEN", url = "",
		labels = { "ready-for-agent" }, assignees = {}, blockedBy = {}, type = nil,
		parent = nil, isSpec = true,
	}
	local kid = {
		number = 11, title = "工单", body = "", state = "OPEN", url = "",
		labels = { "ready-for-agent" }, assignees = {}, blockedBy = {}, type = nil,
		parent = 10, isSpec = true,
	}
	local orphan = {
		number = 12, title = "无父工单", body = "", state = "OPEN", url = "",
		labels = {}, assignees = {}, blockedBy = {}, type = nil,
		parent = 99, isSpec = false,
	}
	local groups = tracker.groupBySpec({ spec, kid, orphan })
	eq(#groups, 1, "one spec")
	eq(groups[1].spec.number, 10)
	eq(#groups[1].tickets, 1, "one child")
	eq(groups[1].tickets[1].number, 11, "child attached")
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