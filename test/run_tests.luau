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

-- 按 argv 前缀路由的桩结果表：测试可注入 `omp -p` 的成功/失败/超时输出，
-- 其余命令（git、gh）照旧返回空成功，不影响既有用例。
local processFixtures: { { match: string, result: any, defer: boolean? } } = {}
local processCalls: { { argv: { string }, opts: any } } = {}
-- defer 的调用把回调挂在这里，测试用 flushProcess() 手动放行，
-- 这样才能造出「结果还没回来时又点了一次」这种时序。
local pendingFlush: { any } = {}

local function flushProcess()
	local queued = pendingFlush
	pendingFlush = {}
	for _, fn in ipairs(queued) do
		fn()
	end
end

local function fixtureFor(argv: { string }): any
	local joined = table.concat(argv, " ")
	for _, f in ipairs(processFixtures) do
		if string.find(joined, f.match, 1, true) then
			return f
		end
	end
	return nil
end

local function runProcess(argv: { string }, optsOrCb: any, cb: any): any
	table.insert(processCalls, { argv = argv, opts = if type(optsOrCb) == "table" then optsOrCb else nil })
	local fixture = fixtureFor(argv)
	local result = (fixture and fixture.result) or { status = 0, stdout = "", stderr = "", timed_out = false }
	if fixture and fixture.defer then
		local deferred: any = {}
		function deferred:next(fn: (any, any, any) -> ())
			table.insert(pendingFlush, function()
				fn(result, nil, nil)
			end)
		end
		return deferred
	end
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
		card = function(head: any, children: { any }, props: any?): any
			return { k = "card", head = head, p = props or {}, c = children }
		end,
		link = function(t: string, href: string, tone: string?): any
			return { k = "link", p = { t = t, href = href, tone = tone } }
		end,
		code = function(text: string, syntax: string?): any
			return { k = "code", p = { text = text, syntax = syntax } }
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
	processFixtures = {}
	processCalls = {}
	pendingFlush = {}
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

test("util.parseRemoteUrl 认各种 remote 地址", function()
	eq(util.parseRemoteUrl("git@github.com:meisijiya/tern-matt-panel.git"), "meisijiya/tern-matt-panel", "ssh")
	eq(util.parseRemoteUrl("https://github.com/meisijiya/tern-matt-panel.git"), "meisijiya/tern-matt-panel", "https")
	eq(util.parseRemoteUrl("https://github.com/meisijiya/tern-matt-panel"), "meisijiya/tern-matt-panel", "no .git suffix")
	eq(util.parseRemoteUrl("https://github.com/meisijiya/tern-matt-panel/"), "meisijiya/tern-matt-panel", "trailing slash")
	eq(util.parseRemoteUrl("ssh://git@github.com/meisijiya/tern-matt-panel.git\n"), "meisijiya/tern-matt-panel", "trailing newline")
	eq(util.parseRemoteUrl("git@gitlab.com:group/sub/proj.git"), "sub/proj", "nested group takes last two")
	eq(util.parseRemoteUrl(""), nil, "empty")
	eq(util.parseRemoteUrl("not a url"), nil, "garbage")
end)

test("tracker 认任意前缀的流程标签", function()
	local mk = function(labels)
		return {
			number = 1, title = "t", body = "", state = "OPEN", url = "",
			labels = labels, assignees = {}, blockedBy = {}, parent = nil,
		}
	end
	-- 默认命名空间
	eq(tracker.parseIssue(mk({ "wayfinder:research" })).type, "research", "wayfinder:research")
	-- 用户自定义命名空间
	eq(tracker.parseIssue(mk({ "myflow:prototype" })).type, "prototype", "myflow:prototype")
	eq(tracker.parseIssue(mk({ "acme:grilling" })).type, "grilling", "acme:grilling")
	eq(tracker.parseIssue(mk({ "acme:task" })).type, "task", "acme:task")
	-- 裸标签不算：仓库里随便一个 task 标签不该把普通 issue 认成流程票
	eq(tracker.parseIssue(mk({ "task" })).type, nil, "bare task ignored")
	eq(tracker.parseIssue(mk({ "research" })).type, nil, "bare research ignored")

	-- 地图与 spec 同样放宽前缀
	local map = mk({ "myflow:map" })
	local grouped = tracker.groupByMap({ map })
	eq(#grouped, 1, "myflow:map counts as a map")

	ok(tracker.parseIssue(mk({ "ready-for-agent" })).isSpec, "bare ready-for-agent")
	ok(tracker.parseIssue(mk({ "myflow:ready-for-agent" })).isSpec, "namespaced ready-for-agent")
end)

test("tracker.sortByCreated 默认最新在上，缺时间的排最后", function()
	local mk = function(n, at)
		return {
			number = n, title = "t", body = "", state = "OPEN", url = "",
			labels = {}, assignees = {}, blockedBy = {}, type = nil,
			parent = nil, isSpec = false, createdAt = at,
		}
	end
	local old = mk(1, "2026-01-01T00:00:00Z")
	local mid = mk(2, "2026-06-01T00:00:00Z")
	local new = mk(3, "2026-11-01T00:00:00Z")
	local none = mk(4, nil)

	local desc = tracker.sortByCreated({ old, none, mid, new }, true)
	eq(desc[1].number, 3, "newest first")
	eq(desc[2].number, 2)
	eq(desc[3].number, 1)
	eq(desc[4].number, 4, "missing createdAt sorts last, not oldest")

	local asc = tracker.sortByCreated({ old, none, mid, new }, false)
	eq(asc[1].number, 1, "oldest first")
	eq(asc[2].number, 2)
	eq(asc[3].number, 3)
	eq(asc[4].number, 4, "missing still last")
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
	-- omp 只认 skill: 前缀，不是裸斜杠
	eq(commands.buildSkillCommand({ name = "wayfinder" }), "/skill:wayfinder")
end)

test("commands.buildTicketCommand", function()
	local tpl = templates.TEMPLATES[4] -- task
	local ticket = { url = "http://ticket", title = "MyTask" }
	local out = commands.buildTicketCommand(ticket, tpl)
	ok(string.find(out, "http://ticket", 1, true) ~= nil, "url in ticket cmd")
	ok(string.find(out, "MyTask", 1, true) ~= nil, "title in ticket cmd")
end)

test("templates.render 缺的占位符留原样", function()
	local out = templates.render(templates.NEXT_STEP, { repo = "o/r" })
	ok(string.find(out, "o/r", 1, true) ~= nil, "repo substituted")
	ok(string.find(out, "{claimable}", 1, true) ~= nil, "missing placeholder kept")
end)

test("templates.nextStepVars 摊出真实票清单", function()
	local blockedTicket = { number = 15, title = "等前置", type = "research", blockedBy = { 12, 3 }, createdAt = "2026-10-30T08:00:00Z",
		labels = { "wayfinder:research", "test" }, assignees = {} }
	local buckets = {
		claimable = {
			{ number = 12, title = "修 X", type = "task", blockedBy = {}, createdAt = "2026-11-01T00:00:00Z" },
			{ number = 13, title = "没打标签的票", type = nil, blockedBy = {} },
		},
		assigned = {},
		blocked = { blockedTicket },
	}
	local vars = templates.nextStepVars(
		"me/repo",
		buckets,
		{ { number = 1, title = "地图一" } },
		{
			root = "D:/repo",
			all = { buckets.claimable[1], buckets.claimable[2], blockedTicket },
			specs = {
				{ number = 14, title = "规格十四", open = 1, total = 2, state = "OPEN" },
				{ number = 11, title = "规格十一", open = 0, total = 0, state = "CLOSED" },
			},
			rootIsRepo = true,
		}
	)
	eq(vars.repo, "me/repo")
	eq(vars.root, "D:/repo")
	eq(vars.rootLabel, "仓库根目录")
	eq(vars.claimableCount, "2")
	ok(string.find(vars.claimable, "- #12 wayfinder:task 修 X · 2026-11-01", 1, true) ~= nil, "claimable line")
	ok(string.find(vars.claimable, "- #13 无类型 没打标签的票", 1, true) ~= nil, "untyped line")
	ok(string.find(vars.claimable, "被 #15 等待", 1, true) ~= nil, "reverse dep: 12 unlocks 15")
	eq(vars.assigned, "（无）")
	ok(string.find(vars.blocked, "等 #12,#3", 1, true) ~= nil, "blockers listed")
	eq(vars.maps, "- #1 地图一")
	ok(string.find(vars.specs, "- #14 规格十四 · 进行中 · 未完成 1 张，共 2 张", 1, true) ~= nil, "open spec")
	-- 已关闭的 spec 必须与进行中的区分开：并列会让接收方以为 v1 还没做完
	ok(string.find(vars.specs, "- #11 规格十一 · 已关闭 · 未拆工单", 1, true) ~= nil, "closed spec")
	-- 非 wayfinder 标签是「这是不是真活」的唯一信号，必须进快照
	ok(string.find(vars.blocked, "标签 test", 1, true) ~= nil, "extra labels kept")
	ok(string.find(vars.blocked, "wayfinder:research", 1, true) ~= nil, "type kept separately")

	-- 超过 12 张要收尾，别把整块板塞进提示词
	local many = {}
	for i = 1, 14 do
		many[i] = { number = i, title = "t" .. i, type = "task", blockedBy = {} }
	end
	local v2 = templates.nextStepVars("r", { claimable = many, assigned = {}, blocked = {} }, {})
	ok(string.find(v2.claimable, "还有 2 张", 1, true) ~= nil, "truncated")
	eq(v2.maps, "（无）")
	eq(v2.specs, "（无）")
	eq(v2.root, "（未知，按当前工作目录找）")
	eq(v2.rootLabel, "当前工作目录")
end)

test("lanes 每条泳道都指路", function()
	for _, l in ipairs(lanes.LANES) do
		ok(l.hint ~= nil and l.hint ~= "", l.id .. " has hint")
	end
end)

test("util.textWidth 把 CJK 算成两列", function()
	eq(util.textWidth("刷新"), 4)
	eq(util.textWidth("repo"), 4)
end)

test("util.packRows 装不下就换行且不丢按钮", function()
	local widths = { 6, 6, 6, 6, 6, 14 }
	local wide = util.packRows(widths, 100, 1)
	eq(#wide, 1, "wide panel keeps one row")
	eq(#wide[1], 6, "all buttons in that row")

	local narrow = util.packRows(widths, 12, 1)
	ok(#narrow > 1, "narrow panel wraps")
	local seen: { [number]: boolean } = {}
	for _, row in ipairs(narrow) do
		for _, idx in ipairs(row) do
			ok(not seen[idx], "index " .. idx .. " appears once")
			seen[idx] = true
		end
	end
	eq(#narrow[1], 1, "first row holds the first button only")
	eq(narrow[1][1], 1, "order kept")

	-- 单项比整行还宽：独占一行，宁可溢出也不丢
	local huge = util.packRows({ 40, 6 }, 10, 1)
	eq(#huge, 2, "oversized button gets its own row")
end)

-- ------------------------------------------------------ host 渲染与事件 ----

--- 最小 BlockCx：面板只用到这几个字段。
local function mkCx(cols: number): any
	return {
		pane = 7,
		cwd = "C:/repo",
		rows = 40,
		cols = cols,
		render = function() end,
		copy = function() end,
		open = function() end,
	}
end

--- 窗口半边的投递通道：agent 空闲时 inject 应当真的送出去，并回写成功。
--- 这条路径以前只靠真机点，现在用桩把「空闲 agent」这个前提直接造出来。
test("窗口半边把 inject 交给空闲 agent 并回写成功", function()
	local winPane = 42
	local asks: { { pane: number, text: string } } = {}
	local cx: any = {
		pane = winPane,
		copy = function() end,
		toast = function() end,
		session = {
			pane = function(_self: any, id: number)
				if id == winPane then
					return { id = id }
				end
				return nil
			end,
			focused = function()
				return winPane
			end,
			tab_of = function()
				return 1
			end,
			layout = function()
				return { root = { pane = winPane } }
			end,
			event = function() end,
		},
		agents = {
			list = function()
				return { { pane = winPane, state = "idle" } }
			end,
			ask = function(_self: any, pane: number, text: string)
				table.insert(asks, { pane = pane, text = text })
			end,
		},
	}
	-- 宿主写进去的注入请求
	kvStore["action"] = { seq = 5, kind = "inject", pane = winPane, body = "hello", name = "测试" }
	-- 轮询回调在加载时就注册了，reset() 会清空 timers 表，所以用加载时抓的那一份
	ok(pollTick ~= nil, "window registered a poll timer")
	pollTick(cx)

	eq(#asks, 1, "agent asked once")
	eq(asks[1].pane, winPane)
	ok(string.find(asks[1].text, "hello", 1, true) ~= nil, "body delivered")
	local res = kvStore["inject_result"]
	ok(type(res) == "table", "result written back")
	eq(res.ok, true, "reported success")
	eq(res.seq, 5, "seq echoed")
end)

test("剪贴板写不进去时不许谎报已复制", function()
	local winPane = 42
	local cx: any = {
		pane = winPane,
		copy = function()
			error("clipboard busy")
		end,
		toast = function() end,
		session = {
			pane = function(_self: any, id: number) return (if id == winPane then { id = id } else nil) end,
			focused = function() return winPane end,
			tab_of = function() return 1 end,
			layout = function() return { root = { pane = winPane } } end,
			event = function() end,
		},
		-- 没有可用 agent：必然走剪贴板兜底
		agents = { list = function() return {} end, ask = function() end },
	}
	kvStore["action"] = { seq = 9, kind = "inject", pane = winPane, body = "hi", name = "测试" }
	pollTick(cx)

	local res = kvStore["inject_result"]
	ok(type(res) == "table", "result written")
	eq(res.ok, false, "reported failure")
	ok(string.find(tostring(res.error), "剪贴板也写不进去", 1, true) ~= nil, "names the copy failure")
	ok(string.find(tostring(res.error), "正文已复制", 1, true) == nil, "does not claim success")
end)

test("compose 复制失败不许报已复制", function()
	local winPane = 42
	local cx: any = {
		pane = winPane,
		copy = function() error("clipboard busy") end,
		toast = function() end,
		session = {
			pane = function(_self: any, id: number) return (if id == winPane then { id = id } else nil) end,
			focused = function() return winPane end,
			tab_of = function() return 1 end,
			layout = function() return { root = { pane = winPane } } end,
			event = function() end,
		},
		agents = { list = function() return {} end, ask = function() end },
	}
	local said: { any } = {}
	cx.toast = function(...)
		table.insert(said, { ... })
	end
	kvStore["action"] = { seq = 21, kind = "compose", pane = winPane, body = "x", name = "技能" }
	pollTick(cx)

	-- cx:toast 是冒号调用，实参表第一个是 cx 自己
	eq(#said, 1, "one toast")
	eq(said[1][2], "error", "reported as error")
	ok(string.find(tostring(said[1][3]), "复制失败", 1, true) ~= nil, "names the failure")
	ok(string.find(tostring(said[1][3]), "已复制", 1, true) == nil, "does not claim success")
end)

--- 收一棵节点树里的按钮文字。
local function buttonTexts(node: any, out: { string }): { string }
	out = out or {}
	if type(node) ~= "table" then
		return out
	end
	if node.k == "button" and type(node.p) == "table" and type(node.p.t) == "string" then
		table.insert(out, node.p.t)
	end
	for _, kid in ipairs(node.c or {}) do
		buttonTexts(kid, out)
	end
	return out
end

local panel = blockDefs["matt"]

test("工具条在宽窄面板都露出全部按钮", function()
	local broad = panel.init(mkCx(120), {}, nil)
	broad.view = "board"
	local wide = panel.view(broad, mkCx(120))
	local wideTexts = buttonTexts(wide.main, {})
	eq(#wide.main.c[1].c, 1, "broad: 一行装得下")
	ok(util.contains(wideTexts, "问下一步"), "broad: 有问下一步")
	ok(util.contains(wideTexts, "刷新"), "broad: 有刷新")

	local narrow = panel.init(mkCx(24), {}, nil)
	narrow.view = "board"
	local tight = panel.view(narrow, mkCx(24))
	local tightTexts = buttonTexts(tight.main, {})
	eq(#tightTexts, #wideTexts, "narrow: 按钮一个不少")
	ok(util.contains(tightTexts, "问下一步"), "narrow: 保留问下一步")
	ok(util.contains(tightTexts, "换仓库"), "narrow: 保留换仓库")
	ok(#tight.main.c[1].c > 1, "narrow: 工具条换行")
end)

--- 造一份带仓库/票/地图的 state，供「问下一步」的几个用例共用。
local function nextStepState()
	local st = panel.init(mkCx(120), {}, nil)
	st.repo = "me/repo"
	st.maps = { { number = 1, title = "地图一", url = "", state = "OPEN", body = "", tickets = {} } }
	st.tickets = {
		{ number = 12, title = "修 X", body = "", state = "OPEN", url = "u12",
			labels = { "wayfinder:task" }, assignees = { "me" }, blockedBy = {}, type = "task",
			parent = 1, isSpec = false, createdAt = "2026-11-01T00:00:00Z" },
		{ number = 99, title = "已完成", body = "", state = "CLOSED", url = "u99",
			labels = { "wayfinder:task" }, assignees = {}, blockedBy = {}, type = "task",
			parent = nil, isSpec = false, createdAt = "2026-10-01T00:00:00Z" },
	}
	return st
end

test("问下一步交给独立进程，正文仍只含票面", function()
	processFixtures = { { match = "omp -p", result = { status = 0, stdout = "| 票 | 建议 |\n", stderr = "warn: mcp", timed_out = false } } }
	local st = nextStepState()
	panel.event(st, { ev = "action", act = "next-step" }, mkCx(120))

	-- 不再往会话里灌：没有任何注入请求
	ok(kvStore["action"] == nil, "不写注入请求")

	local call
	for _, c in ipairs(processCalls) do
		if c.argv[1] == "omp" then
			call = c
		end
	end
	ok(call ~= nil, "起了 omp 进程")
	eq(call.argv[2], "-p")
	eq(call.argv[3], "--no-session")
	ok(call.opts ~= nil and call.opts.timeout_ms == 300000, "带超时")
	-- 正文走 argv：真机上走 stdin 会卡住不返回
	local body = tostring(call.argv[4])
	ok(call.opts.stdin == nil, "短正文不塞 stdin")
	ok(string.find(body, "/skill:ask-matt", 1, true) ~= nil, "调用 ask-matt")
	ok(string.find(body, "#12 wayfinder:task 修 X", 1, true) ~= nil, "带真实票行")
	ok(string.find(body, "@me", 1, true) ~= nil, "带了认领人")
	ok(string.find(body, "已关闭：1 张", 1, true) ~= nil, "带了已关闭组")
	for _, banned in ipairs({ "抓取时间", "分钟前", "已过时", "缓存", "新鲜", "可能" }) do
		ok(string.find(body, banned, 1, true) == nil, "正文不该出现：" .. banned)
	end

	eq(st.nextStep.phase, "done", "拿到结果")
	ok(string.find(st.nextStep.text, "建议", 1, true) ~= nil, "保留 stdout")
	ok(st.nextStep.warn ~= nil, "stderr 有内容时作为提示保留")
end)

test("问下一步失败与超时都保留已拿到的部分输出", function()
	processFixtures = { { match = "omp -p", result = { status = 1, stdout = "半截", stderr = "boom\nB", timed_out = false } } }
	local st = nextStepState()
	panel.event(st, { ev = "action", act = "next-step" }, mkCx(120))
	eq(st.nextStep.phase, "error")
	eq(st.nextStep.text, "半截", "保留部分输出")
	ok(string.find(st.nextStep.err, "退出码 1", 1, true) ~= nil, "说清退出码")
	ok(string.find(st.nextStep.err, "B", 1, true) ~= nil, "带 stderr 尾部")

	processFixtures = { { match = "omp -p", result = { status = -1, stdout = "半截", stderr = "", timed_out = true } } }
	local st2 = nextStepState()
	panel.event(st2, { ev = "action", act = "next-step" }, mkCx(120))
	eq(st2.nextStep.phase, "error")
	ok(string.find(st2.nextStep.err, "超时", 1, true) ~= nil, "标超时")
	eq(st2.nextStep.text, "半截", "超时也保留部分输出")
end)

test("问下一步跑着时再点不叠第二次调用", function()
	processFixtures = { { match = "omp -p", defer = true, result = { status = 0, stdout = "答案", stderr = "", timed_out = false } } }
	local st = nextStepState()
	panel.event(st, { ev = "action", act = "next-step" }, mkCx(120))
	eq(st.nextStep.phase, "running", "第一次在跑")
	local before = #processCalls
	panel.event(st, { ev = "action", act = "next-step" }, mkCx(120))
	eq(#processCalls, before, "第二次不再起进程")
	ok(string.find(tostring(st.message), "上一次还在问", 1, true) ~= nil, "给出明确提示")
end)

test("切了仓库，旧答案不许盖到新仓库上", function()
	processFixtures = { { match = "omp -p", defer = true, result = { status = 0, stdout = "旧仓库的答案", stderr = "", timed_out = false } } }
	local st = nextStepState()
	panel.event(st, { ev = "action", act = "next-step" }, mkCx(120))
	eq(st.nextStep.phase, "running")

	-- 结果还没回来就换了仓库：放行后必须丢弃，不许写进新仓库的视图
	st.repo = "other/repo"
	flushProcess()
	eq(st.nextStep.phase, "running", "旧请求的结果被丢掉，状态不再前进")
	eq(st.nextStep.text, "", "没把旧答案写进来")

	-- 反证：仓库没变时同一份结果会被采用
	processFixtures = { { match = "omp -p", defer = true, result = { status = 0, stdout = "答案", stderr = "", timed_out = false } } }
	local st2 = nextStepState()
	panel.event(st2, { ev = "action", act = "next-step" }, mkCx(120))
	flushProcess()
	eq(st2.nextStep.phase, "done", "仓库没变则采用")
	eq(st2.nextStep.text, "答案")
end)

test("块被重建时结果保留，正在跑的标成中断", function()
	-- 结果存在的块：重建后卡片还在，不用再问一次
	local saved = {
		view = "board", showHidden = false, repo = "me/repo", skillSel = nil,
		nextStep = { phase = "done", repo = "me/repo", text = "| 票 | 建议 |", model = "m", seconds = 51 },
	}
	local st = panel.init(mkCx(120), {}, saved)
	eq(st.nextStep.phase, "done", "done 保留")
	eq(st.nextStep.text, "| 票 | 建议 |")
	eq(st.nextStep.seconds, 51)

	-- 正在跑的块：进程已随旧块消失，必须标成中断而不是一直转圈
	local saved2 = {
		view = "board", repo = "me/repo",
		nextStep = { phase = "running", repo = "me/repo", text = "" },
	}
	local st2 = panel.init(mkCx(120), {}, saved2)
	eq(st2.nextStep.phase, "error", "running 降级为中断")
	ok(string.find(tostring(st2.nextStep.err), "中断", 1, true) ~= nil, "说清为什么停")
end)

test("已关闭组只给数量与最新建立的标题", function()
	local closed = {}
	for i = 1, 8 do
		closed[i] = { number = i, title = "收尾票" .. i, blockedBy = {} }
	end
	local vars = templates.nextStepVars("o/r", { claimable = {}, assigned = {}, blocked = {} }, {}, {
		root = "D:/r", all = {}, specs = {}, closed = closed,
	})
	ok(string.find(vars.closedLine, "8 张", 1, true) ~= nil, "count")
	ok(string.find(vars.closedLine, "#1 收尾票1", 1, true) ~= nil, "recent listed")
	ok(string.find(vars.closedLine, "另有 3 张", 1, true) ~= nil, "overflow noted")
end)

-- -------------------------------------------------------------- report ----

print(string.format("passed=%d failed=%d", passed, failed))
if failed > 0 then
	for _, f in ipairs(failures) do
		print("FAIL: " .. f)
	end
	error("tests failed")
end