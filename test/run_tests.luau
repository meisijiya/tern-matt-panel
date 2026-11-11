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
local processFixtures: { any } = {}
local processCalls: { { argv: { string }, opts: any } } = {}
-- 测试用 JSON 载荷：stdout 写 key，decode 返回对应表；避免在测试里写 JSON 解析器。
local jsonPayloads: { [string]: any } = {}
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
			if f.results then
				f.index = (f.index or 0) + 1
				local result = f.results[f.index] or f.results[#f.results]
				return { result = result, defer = f.defer }
			end
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
			local seen: { [string]: boolean } = {}
			local prefix = path .. "/"
			-- 目录与文件都算条目：真实 fs 的 list 不会只返回文件。
			local function add(full: string)
				if string.sub(full, 1, #prefix) ~= prefix then
					return
				end
				local rest = string.sub(full, #prefix + 1)
				if rest == "" or string.find(rest, "/", 1, true) then
					return
				end
				if not seen[rest] then
					seen[rest] = true
					table.insert(out, rest)
				end
			end
			for p in pairs(fsFiles) do
				add(p)
			end
			for d in pairs(fsDirs) do
				add(d)
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
			-- 真机只认 actions.click（顶层 click 被静默忽略 → 死按钮）。
			-- 桩在这里直接报错，免得单测把「点了没反应」放过去。
			if type(p.click) == "string" then
				error("按钮的点击必须挂在 actions.click 上：" .. tostring(t))
			end
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
	json = {
		decode = function(text: string): any
			local value = jsonPayloads[text]
			if value == nil then
				error("no json payload: " .. tostring(text))
			end
			return value
		end,
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
	jsonPayloads = {}
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

test("util.isStale 边界", function()
	local now = 100000
	ok(not util.isStale(now, now - 7199, 7200), "1h59m 不红")
	ok(not util.isStale(now, now - 7200, 7200), "2h 整不红（严格大于）")
	ok(util.isStale(now, now - 7201, 7200), "2h+1s 红")
	ok(not util.isStale(now, "2026-11-10 10:00", 7200), "无秒数不红")
	ok(not util.isStale(now, nil, 7200), "没有时刻不红")
	ok(not util.isStale(nil, now - 9999, 7200), "没有当前时间不红")
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
	local onlyFog = tracker.parseSections("## 尚未明确\n- 只有迷雾\n")
	eq(onlyFog.fog, "- 只有迷雾")
	eq(onlyFog.outOfScope, nil, "缺范围外就是 nil")
	local stopped = tracker.parseSections("## 尚未明确\n迷雾\n### 子标题\n不该进迷雾")
	eq(stopped.fog, "迷雾", "子标题截断本节")
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
	eq(util.parseRemoteUrl("meisijiya/tern-matt-panel"), "meisijiya/tern-matt-panel", "bare owner/repo")
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
	local ticket = { url = "http://ticket", title = "MyTask", number = 12 }
	local out = commands.buildTicketCommand(ticket, tpl)
	ok(string.find(out, "http://ticket", 1, true) ~= nil, "url in ticket cmd")
	ok(string.find(out, "MyTask", 1, true) ~= nil, "title in ticket cmd")
	ok(string.find(out, "===== 注入开始 · tern-matt-panel · 执行 · #12 =====", 1, true) == 1, "开始行带动作名与票号")
	ok(string.find(out, "===== 注入结束 · 下面是用户输入的内容 =====", 1, true) ~= nil, "有结束行")
end)

test("注入信封拼装", function()
	local body = "第一行\n第二行"
	local out = commands.buildInjectionBody("问下一步", body)
	eq(out, "===== 注入开始 · tern-matt-panel · 问下一步 =====\n" .. body .. "\n===== 注入结束 · 下面是用户输入的内容 =====\n")
	ok(string.find(out, "· #", 1, true) == nil, "没有票号时不带票号段")
	local out2 = commands.buildInjectionBody("执行", body, 7)
	ok(string.find(out2, "===== 注入开始 · tern-matt-panel · 执行 · #7 =====", 1, true) == 1, "有票号时带 · #编号")
	eq(commands.buildInjectionBody("体检", ""), "", "正文为空不产出信封")
	eq(commands.buildInjectionBody("体检", "   \n\t "), "", "正文只有空白不产出信封")
end)

test("技能单行注入不套信封", function()
	local out = commands.buildSkillCommand({ name = "wayfinder" })
	eq(out, "/skill:wayfinder")
	ok(string.find(out, "=====", 1, true) == nil, "没有信封")
	ok(string.find(out, "\n", 1, true) == nil, "仍是单行")
end)

test("templates.render 缺的占位符留原样", function()
	local tpl = { id = "x", title = "x", body = "repo={repo} 缺={nope}" }
	local out = templates.render(tpl, { repo = "o/r" })
	ok(string.find(out, "repo=o/r", 1, true) ~= nil, "repo substituted")
	ok(string.find(out, "缺={nope}", 1, true) ~= nil, "missing placeholder kept")
end)

test("问下一步只调 ask-matt，不再搬任务板快照", function()
	local out = templates.render(templates.NEXT_STEP, { repo = "me/repo" })
	ok(string.find(out, "/skill:ask-matt", 1, true) == 1, "首行是技能命令")
	ok(string.find(out, "me/repo", 1, true) ~= nil, "带仓库")
	ok(string.find(out, "只做分析", 1, true) ~= nil, "写明只读边界")
	ok(string.find(out, "gh issue list", 1, true) ~= nil, "让它自己核事实")
	ok(string.find(out, "#12 wayfinder:task", 1, true) == nil, "没有票行")
	ok(string.find(out, "@me", 1, true) == nil, "没有认领人")
	ok(string.find(out, "已关闭：", 1, true) == nil, "没有已关闭统计")
	for _, banned in ipairs({ "抓取时间", "分钟前", "已过时", "缓存", "置信" }) do
		ok(string.find(out, banned, 1, true) == nil, "正文不该出现：" .. banned)
	end
end)

--- omp 只认 /skill: 前缀：注入正文里出现裸斜杠命令，会话就解析不到技能。
local function outerSlashCmds(text: string): { string }
	local out: { string } = {}
	for word in string.gmatch(text, "%f[%S]/([%w%-]+)") do
		table.insert(out, word)
	end
	return out
end

test("注入正文里的斜杠命令一律带 skill: 前缀", function()
	local bodies = {
		{ "问下一步", templates.render(templates.NEXT_STEP, { repo = "o/r" }) },
		{ "提 BUG", templates.render(templates.NEW_BUG, { repo = "o/r" }) },
		{ "体检", templates.render(templates.HEALTH_CHECK, { repo = "o/r" }) },
	}
	for _, e in ipairs(templates.ENTRIES) do
		table.insert(bodies, { e.title, templates.renderEntry(e, "o/r") })
	end
	for _, tpl in ipairs(templates.TEMPLATES) do
		table.insert(bodies, { tpl.title, templates.render(tpl, { url = "u", title = "t" }) })
	end
	for _, item in ipairs(bodies) do
		local name = item[1]
		local text = item[2]
		local cmds = outerSlashCmds(text)
		for _, c in ipairs(cmds) do
			ok(c == "skill" or string.sub(c, 1, 5) == "skill", name .. " 有不带 skill: 的斜杠命令：/" .. c)
		end
	end
end)

test("新增需求两条路、提 BUG、体检各调对技能", function()
	local explore = templates.entryById("explore")
	local implement = templates.entryById("implement")
	ok(explore ~= nil and implement ~= nil, "两条路都在")
	local e = templates.renderEntry(explore :: any, "me/repo")
	ok(string.find(e, "/skill:wayfinder", 1, true) ~= nil, "探索走 wayfinder")
	ok(string.find(e, "blockedBy", 1, true) ~= nil, "讲了并行与串行")
	local i = templates.renderEntry(implement :: any, "me/repo")
	ok(string.find(i, "/skill:grill-with-docs", 1, true) ~= nil, "实施走 grill-with-docs")
	ok(string.find(i, "/skill:to-spec", 1, true) ~= nil, "收尾提醒 to-spec")

	local bug = templates.render(templates.NEW_BUG, { repo = "me/repo" })
	ok(string.find(bug, "/skill:wayfinder", 1, true) ~= nil, "提 BUG 调 wayfinder")
	ok(string.find(bug, "me/repo", 1, true) ~= nil, "带仓库")
	ok(string.find(bug, "bug 标签", 1, true) ~= nil, "要求打 bug 标签")
	ok(string.find(bug, "查重", 1, true) ~= nil, "建单前查重")
	ok(string.find(bug, "复现步骤", 1, true) ~= nil, "索取要素在")

	local health = templates.render(templates.HEALTH_CHECK, { repo = "me/repo" })
	ok(string.find(health, "游离", 1, true) ~= nil, "说清什么算游离")
	ok(string.find(health, "等人点头", 1, true) ~= nil, "先出清单再动手")
	ok(string.find(health, "不关闭票", 1, true) ~= nil, "禁止越界写操作")
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
test("窗口半边把 inject 填进空闲 agent 的输入框并回写成功", function()
	local winPane = 42
	local typed: { { pane: number, text: string } } = {}
	local cx: any = {
		pane = winPane,
		run = function(_self: any, pane: number, text: string)
			table.insert(typed, { pane = pane, text = text })
		end,
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
			-- 填输入框不走 ask：ask 一定会提交，用户就没有补内容的机会了
			ask = function(_self: any, _pane: number, _text: string)
				error("不该调用 agents:ask —— 提示词只能填进输入框")
			end,
		},
	}
	-- 宿主写进去的填入请求
	kvStore["action"] = { seq = 5, kind = "inject", pane = winPane, body = "hello", name = "测试" }
	-- 轮询回调在加载时就注册了，reset() 会清空 timers 表，所以用加载时抓的那一份
	ok(pollTick ~= nil, "window registered a poll timer")
	pollTick(cx)

	eq(#typed, 1, "正文打进 pane 一次")
	eq(typed[1].pane, winPane)
	ok(string.find(typed[1].text, "hello", 1, true) ~= nil, "body delivered")
	local res = kvStore["inject_result"]
	ok(type(res) == "table", "result written back")
	eq(res.ok, true, "reported success")
	eq(res.seq, 5, "seq echoed")

	-- 多行正文必须包成括号粘贴：否则终端会在第一个换行处把消息发出去，
	-- 用户就没机会补内容了。整段文本是信封包着的正文。
	local env = "===== 注入开始 · tern-matt-panel · 测试 =====\n第一行\n第二行\n===== 注入结束 · 下面是用户输入的内容 =====\n"
	kvStore["action"] = { seq = 6, kind = "inject", pane = winPane, body = env, name = "多行" }
	pollTick(cx)
	eq(#typed, 2, "多行正文也打进 pane")
	ok(string.find(typed[2].text, "\27[200~", 1, true) == 1, "外层以括号粘贴开头")
	ok(string.find(typed[2].text, "===== 注入结束 · 下面是用户输入的内容 =====\n\27[201~", 1, true) ~= nil, "结束行与换行都在括号粘贴内部")
	eq(string.sub(typed[2].text, -6), "\27[201~", "括号粘贴以结束符收尾")
	ok(string.find(string.sub(typed[2].text, -6), "\n", 1, true) == nil, "结束符之后没有换行")
	ok(string.find(string.sub(typed[2].text, -6), "\r", 1, true) == nil, "结束符之后没有回车")
	ok(string.find(typed[2].text, "===== 注入开始 · tern-matt-panel · 测试 =====", 1, true) ~= nil, "整段以开始行开头")
	ok(string.find(typed[2].text, "===== 注入结束 · 下面是用户输入的内容 =====", 1, true) ~= nil, "整段以结束行收尾")
	ok(string.find(typed[2].text, "\r", 1, true) == nil, "不带回车，不提交")
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

test("聚焦只戳当前 tab 里的面板，不惊动别的 tab", function()
	local panelA, panelB, term = 101, 202, 303
	local events: { { pane: number, act: string? } } = {}
	local cx: any = {
		pane = panelA,
		session = {
			focused = function() return term end,
			panes = function()
				return {
					{ pane = panelA, tab = 1, program = "tern-matt-panel.matt" },
					{ pane = panelB, tab = 2, program = "tern-matt-panel.matt" },
					{ pane = term, tab = 2, program = "powershell.exe" },
				}
			end,
			event = function(_self: any, pane: number, ev: any)
				table.insert(events, { pane = pane, act = ev and ev.act })
			end,
		},
		agents = { list = function() return {} end },
	}

	handlers["focus"]({ pane = term, tab = 2 }, cx)
	eq(#events, 1, "tab 2 里只有一个面板该被戳")
	eq(events[1].pane, panelB, "戳的是该 tab 里的面板")
	eq(events[1].act, "auto-reload", "发的是自动刷新")

	events = {}
	handlers["focus"]({ pane = panelA, tab = 1 }, cx)
	eq(#events, 1, "切到 tab 1 也只戳一个")
	eq(events[1].pane, panelA, "戳 tab 1 的面板")
end)

test("工具条在宽窄面板都露出全部按钮", function()
	local broad = panel.init(mkCx(120), {}, nil)
	broad.view = "board"
	local wide = panel.view(broad, mkCx(120))
	local wideTexts = buttonTexts(wide.main, {})
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
	ok(util.contains(wideTexts, "新增需求"), "broad: 新增需求常驻")
	ok(util.contains(wideTexts, "提 BUG"), "broad: 提 BUG 常驻")
	ok(util.contains(wideTexts, "体检"), "broad: 体检常驻")
	ok(util.contains(tightTexts, "新增需求"), "narrow: 新增需求也在")
end)

--- 造一份带仓库/票的 state，供「问下一步」用。
local function nextStepState()
	local st = panel.init(mkCx(120), {}, nil)
	st.repo = "me/repo"
	st.maps = { { number = 1, title = "地图一", url = "", state = "OPEN", body = "", tickets = {} } }
	st.tickets = {
		{ number = 12, title = "修 X", body = "", state = "OPEN", url = "u12",
			labels = { "wayfinder:task" }, assignees = { "me" }, blockedBy = {}, type = "task",
			parent = 1, isSpec = false, createdAt = "2026-11-01T00:00:00Z" },
	}
	return st
end

test("问下一步只注入 ask-matt 提示词，不再派子代理", function()
	local st = nextStepState()
	panel.event(st, { ev = "action", act = "next-step" }, mkCx(120))

	local action = kvStore["action"]
	ok(type(action) == "table", "写了注入请求")
	eq(action.kind, "inject", "走普通注入，不起子代理")
	local body = action.body
	ok(string.find(body, "===== 注入开始 · tern-matt-panel · 问下一步 =====", 1, true) == 1, "以开始行开头")
	ok(string.find(body, "===== 注入结束 · 下面是用户输入的内容 =====", 1, true) ~= nil, "以结束行收尾")
	ok(string.find(body, "/skill:ask-matt", 1, true) ~= nil, "正文里有技能命令")
	ok(string.find(body, "me/repo", 1, true) ~= nil, "带仓库")
	ok(string.find(body, "#12 wayfinder:task", 1, true) == nil, "不再搬票面")
	ok(string.find(tostring(st.message), "填入中", 1, true) ~= nil, "提示填入中")
	eq(st.pendingSeq, action.seq, "一次动作只发一次注入请求")
end)

--- 收一棵节点树里的全部文字（text 的 spans、button/badge 的 t、md 的 text）。
local function allText(node: any, out: { string }): { string }
	out = out or {}
	if type(node) ~= "table" then
		return out
	end
	local p = node.p
	if type(p) == "table" then
		local spans = p.spans
		if type(spans) == "string" then
			table.insert(out, spans)
		elseif type(spans) == "table" then
			if type(spans.t) == "string" then
				-- 单个 span：ui.text(ui.span(...))
				table.insert(out, spans.t)
			else
				for _, sp in ipairs(spans) do
					if type(sp) == "string" then
						table.insert(out, sp)
					elseif type(sp) == "table" and type(sp.t) == "string" then
						table.insert(out, sp.t)
					end
				end
			end
		end
		if type(p.t) == "string" then
			table.insert(out, p.t)
		end
		if type(p.text) == "string" then
			table.insert(out, p.text)
		end
		if type(p.label) == "table" and type(p.label.t) == "string" then
			table.insert(out, p.label.t)
		end
	end
	-- 卡片标题走 node.head，不在 p 里；不读它就会漏掉卡名。
	local head = node.head
	if type(head) == "table" then
		if type(head.t) == "string" then
			table.insert(out, head.t)
		else
			for _, sp in ipairs(head) do
				if type(sp) == "string" then
					table.insert(out, sp)
				elseif type(sp) == "table" and type(sp.t) == "string" then
					table.insert(out, sp.t)
				end
			end
		end
	end
	for _, kid in ipairs(node.c or {}) do
		allText(kid, out)
	end
	return out
end

--- 工具条上每个 click 值都必须在动作表里：删掉分支而按钮还在，
--- 用户点下去就是没反应，且任何单测都不会红。
local ACTION_CASES = {
	{ act = "view-skills", want = function(st: any) return st.view == "skills" end },
	{ act = "view-board", want = function(st: any) return st.view == "board" end },
	{ act = "view-packs", want = function(st: any) return st.view == "packs" end },
	{ act = "toggle-sort", want = function(st: any, before: any) return st.sortNewest ~= before.sortNewest end },
	{ act = "reload", want = function(st: any) return st.message == "已刷新" end },
	{ act = "pick-repo", want = function(st: any, _b: any, kv: any) return kv["action"] ~= nil and kv["action"].kind == "pick-repo" end },
	{ act = "toggle-hidden", want = function(st: any, before: any) return st.showHidden ~= before.showHidden end },
	{ act = "next-step", want = function(st: any, _b: any, kv: any) return kv["action"] ~= nil and kv["action"].kind == "inject" end },
	{ act = "new-bug", want = function(_st: any, _b: any, kv: any) return kv["action"] ~= nil and kv["action"].kind == "inject" end },
	{ act = "health-check", want = function(_st: any, _b: any, kv: any) return kv["action"] ~= nil and kv["action"].kind == "inject" end },
	{ act = "wrap-up", want = function(_st: any, _b: any, kv: any) return kv["action"] ~= nil and kv["action"].kind == "inject" end },
	{ act = "packs-refresh", want = function(st: any)
		-- 四种文案同前缀：进行中 / 刚查过 / 已查 N 套 / 没什么可查
		return string.find(tostring(st.message), "版本检查", 1, true) ~= nil
	end },
	{ act = "copy-pack-repo:omp-skill-forge", want = function(st: any) return string.find(tostring(st.message), "已复制仓库链接", 1, true) ~= nil end },
	{ act = "new-demand", want = function(st: any) return st.newDemand == true end },
	{ act = "back-board", want = function(st: any) return st.view == "board" end },
}

test("工具条每个按钮都接上了动作分支", function()
	for _, c in ipairs(ACTION_CASES) do
		local st = nextStepState()
		st.view = "board"
		st.ticket = st.tickets[1]
		st.view = "ticket"
		local before = { sortNewest = st.sortNewest, showHidden = st.showHidden }
		kvStore["action"] = nil
		panel.event(st, { ev = "action", act = c.act }, mkCx(120))
		ok(c.want(st, before, kvStore), "动作没反应：" .. c.act)
	end
end)

test("工具条 click 值全部有分支覆盖", function()
	local known: { [string]: boolean } = {}
	for _, c in ipairs(ACTION_CASES) do
		known[c.act] = true
	end
	-- 这几条需要真实票/技能，另有用例覆盖
	known["inject-skill"] = true
	known["copy-ticket"] = true
	known["open-ticket"] = true
	known["auto-reload"] = true
	known["load-more-closed"] = true
	known["reset-repo"] = true

	local st = nextStepState()
	st.view = "board"
	local clicks: { string } = {}
	local function walk(n: any)
		if type(n) ~= "table" then
			return
		end
		local a = type(n.p) == "table" and n.p.actions or nil
		if type(a) == "table" and type(a.click) == "string" then
			table.insert(clicks, a.click)
		end
		for _, kid in ipairs(n.c or {}) do
			walk(kid)
		end
	end
	walk(panel.view(st, mkCx(120)).main)
	ok(#clicks > 0, "工具条上有按钮")
	for _, c in ipairs(clicks) do
		if string.sub(c, 1, 4) == "new:" then
			ok(templates.entryById(string.sub(c, 5)) ~= nil, "入口不存在：" .. c)
		else
			ok(known[c] == true, "按钮指向没有分支的动作：" .. c)
		end
	end
end)

test("底部显示数据时刻，且刷新中不清空已有内容", function()
	local st = nextStepState()
	st.view = "board"
	st.fetchedAtSec = 1762000000
	local dockText = table.concat(allText(panel.view(st, mkCx(120)).dock, {}), " | ")
	ok(string.find(dockText, "数据 ", 1, true) ~= nil, "dock 显示数据时刻：" .. dockText)

	-- 刷新中：已有票就继续显示，不许整块换成「正在拉取…」
	st.loading = true
	local mainText = table.concat(allText(panel.view(st, mkCx(120)).main, {}), " | ")
	ok(string.find(mainText, "正在拉取", 1, true) == nil, "有数据时不显示占位")
	ok(string.find(mainText, "me/repo", 1, true) ~= nil, "旧内容还在")
end)

--- 找 dock 里第一个带「数据 」的 span，返回它的文字与样式。
local function dataSpan(node: any): { t: string, s: string? }?
	local p = node.p
	if type(p) == "table" and type(p.spans) == "table" and type(p.spans.t) == "string" then
		if string.find(p.spans.t, "数据 ", 1, true) == 1 then
			return p.spans
		end
	end
	for _, kid in ipairs(node.c or {}) do
		local got = dataSpan(kid)
		if got then
			return got
		end
	end
	return nil
end

test("数据超过两小时提示刷新，旧格式不提示", function()
	local st = nextStepState()
	st.view = "board"
	st.fetchedAtSec = 0
	local span = dataSpan(panel.view(st, mkCx(120)).dock)
	ok(span ~= nil, "dock 有数据 span")
	ok(string.find(span.t, "· 建议刷新", 1, true) ~= nil, "陈旧时提示刷新：" .. span.t)
	eq(span.s, "error", "陈旧时用 error 样式")

	st.fetchedAtSec = nil
	st.legacyFetchedAt = "2026-11-10 10:00"
	local span2 = dataSpan(panel.view(st, mkCx(120)).dock)
	ok(span2 ~= nil, "旧格式也有数据 span")
	ok(string.find(span2.t, "建议刷新", 1, true) == nil, "旧格式永不判陈旧：" .. span2.t)
	eq(span2.s, "muted", "旧格式用 muted 样式")
end)

test("没识别到仓库时不给问下一步", function()
	local st = panel.init(mkCx(120), {}, nil)
	kvStore["action"] = nil
	panel.event(st, { ev = "action", act = "next-step" }, mkCx(120))
	ok(kvStore["action"] == nil, "没有仓库就不注入")
	ok(string.find(tostring(st.message), "先识别到仓库", 1, true) ~= nil, "说清缺什么")
end)

test("常驻三条：新增需求/提 BUG/体检", function()
	local st = nextStepState()
	panel.event(st, { ev = "action", act = "new-bug" }, mkCx(120))
	eq(kvStore["action"].kind, "inject")
	ok(string.find(kvStore["action"].body, "复现步骤", 1, true) ~= nil, "提 BUG 正文带索取要素")

	panel.event(st, { ev = "action", act = "health-check" }, mkCx(120))
	ok(string.find(kvStore["action"].body, "游离", 1, true) ~= nil, "体检正文带游离判据")

	kvStore["action"] = nil
	panel.event(st, { ev = "action", act = "new-demand" }, mkCx(120))
	eq(st.view, "board", "切到任务板")
	eq(st.newDemand, true, "叫出两条路")
	ok(kvStore["action"] == nil, "选择前不注入")
end)

--- 模板的结构契约：反问小节恰好一次、无待填空位、命令在白名单内、
--- 末节有用户输入声明、反问路由正确。
local ALL_TEMPLATES: { { name: string, body: string } } = {}
for _, tpl in ipairs(templates.TEMPLATES) do
	table.insert(ALL_TEMPLATES, {
		name = tpl.title,
		body = templates.render(tpl, { url = "http://x/1", title = "票标题" }),
	})
end
table.insert(ALL_TEMPLATES, { name = templates.NEXT_STEP.title, body = templates.render(templates.NEXT_STEP, { repo = "me/repo" }) })
table.insert(ALL_TEMPLATES, { name = templates.NEW_BUG.title, body = templates.render(templates.NEW_BUG, { repo = "me/repo" }) })
table.insert(ALL_TEMPLATES, { name = templates.HEALTH_CHECK.title, body = templates.render(templates.HEALTH_CHECK, { repo = "me/repo" }) })
table.insert(ALL_TEMPLATES, { name = templates.WRAP_UP.title, body = templates.render(templates.WRAP_UP, { repo = "me/repo", root = "D:/r" }) })
for _, e in ipairs(templates.ENTRIES) do
	table.insert(ALL_TEMPLATES, { name = e.injectAction, body = templates.renderEntry(e, "me/repo") })
end

local ASK_MARK = "## 反问（信息不全时先问）"
local USER_INPUT_MARK = "结束行之后的文字是用户输入"
local SKILL_WHITELIST = {
	"/skill:ask-matt",
	"/skill:wayfinder",
	"/skill:grill-with-docs",
	"/skill:prototype",
	"/skill:research",
	"/skill:grilling",
	-- 收尾提醒用的既有技能名
	"/skill:to-spec",
	"/skill:to-tickets",
	-- 收尾动作引用的技能：审 diff、交付、复盘、可视化、交接、选路
	"/skill:code-review",
	"/skill:pr",
	"/skill:retro",
	"/skill:answer-me-with-html",
	"/skill:handoff",
	"/skill:forge-router",
}
-- 待填空位：中文括号里带「填」，或以「：」结尾的空填写行。
local function findPlaceholder(body: string): string?
	local hit = body:match("（[^）]*填[^）]*）")
	if hit then
		return hit
	end
	for line in string.gmatch(body, "[^\n]+") do
		if string.match(line, "：$") and #line < 40 then
			return line
		end
	end
	return nil
end

test("每条模板都挂反问小节且只挂一次", function()
	eq(#ALL_TEMPLATES, 10, "十条模板都收进来了")
	for _, t in ipairs(ALL_TEMPLATES) do
		local n = 0
		for _ in string.gmatch(t.body, ASK_MARK) do
			n = n + 1
		end
		eq(n, 1, t.name .. " 的反问小节恰好一次")
	end
end)

test("每条模板正文里没有待填空位", function()
	for _, t in ipairs(ALL_TEMPLATES) do
		local hit = findPlaceholder(t.body)
		ok(hit == nil, t.name .. " 没有占位（命中：" .. tostring(hit) .. "）")
	end
end)

test("模板里的技能命令都在白名单内", function()
	for _, t in ipairs(ALL_TEMPLATES) do
		for cmd in string.gmatch(t.body, "/skill:[%w%-_]+") do
			local allowed = false
			for _, w in ipairs(SKILL_WHITELIST) do
				if cmd == w then
					allowed = true
				end
			end
			ok(allowed, t.name .. " 的命令 " .. cmd .. " 在白名单内")
		end
	end
end)

test("每条模板末节都有用户输入声明", function()
	local NOTE = "结束行之后的文字是用户输入，按它执行；与上面冲突时以用户输入为准。"
	for _, t in ipairs(ALL_TEMPLATES) do
		ok(string.find(t.body, USER_INPUT_MARK, 1, true) ~= nil, t.name .. " 有用户输入声明")
		-- 声明必须落在末节：去掉尾部空白后，正文以这句话结尾。
		local tail = string.gsub(t.body, "%s+$", "")
		ok(string.sub(tail, -#NOTE) == NOTE, t.name .. " 的声明在末节")
	end
end)

test("反问路由：盘问、需求已明确、收尾不挂 grilling，其余挂", function()
	for _, t in ipairs(ALL_TEMPLATES) do
		local has = string.find(t.body, "/skill:grilling", 1, true) ~= nil
		if t.name == "盘问" or t.name == "入口·需求已明确" or t.name == "收尾" then
			ok(not has, t.name .. " 不挂 grilling")
		else
			ok(has, t.name .. " 挂 grilling")
		end
	end
end)

--- T4：六个模板（四个票动作 + 两个入口）按统一骨架排布，主技能命令正确，
--- 交付形状写清，入口两条路由要点仍在。
local SKELETON_ORDER = { "## 目标", "## 事实核验", "## 边界" }

local function posOf(body: string, needle: string): number
	return string.find(body, needle, 1, true) or -1
end

local T4_BODIES: { { name: string, body: string } } = {}
for _, tpl in ipairs(templates.TEMPLATES) do
	table.insert(T4_BODIES, { name = tpl.title, body = templates.render(tpl, { url = "http://x/1", title = "票标题" }) })
end
for _, e in ipairs(templates.ENTRIES) do
	table.insert(T4_BODIES, { name = e.injectAction, body = (e.body:gsub("{repo}", "me/repo")) })
end

test("T4 六个模板的骨架段落顺序一致", function()
	eq(#T4_BODIES, 6, "四个票动作 + 两个入口")
	for _, t in ipairs(T4_BODIES) do
		local last = -1
		for _, mark in ipairs(SKELETON_ORDER) do
			local p = posOf(t.body, mark)
			ok(p > 0, t.name .. " 有段落 " .. mark)
			ok(p > last, t.name .. " 的段落顺序 " .. mark)
			last = p
		end
		local ask = posOf(t.body, ASK_MARK)
		ok(ask > last, t.name .. " 的反问小节在骨架段落之后")
		local deliver = posOf(t.body, "## 交付")
		local judge = posOf(t.body, "## 判断与交付")
		ok(deliver > 0 or judge > 0, t.name .. " 有交付形状段落")
		ok(ask > deliver and ask > judge, t.name .. " 的交付形状在反问之前")
	end
end)

test("T4 六个模板的主技能命令正确", function()
	local expect = {
		["盘问"] = "/skill:grill-with-docs",
		["原型"] = "/skill:prototype",
		["调研"] = "/skill:research",
		["入口·还没想清楚"] = "/skill:wayfinder",
		["入口·需求已明确"] = "/skill:grill-with-docs",
	}
	for _, t in ipairs(T4_BODIES) do
		local want = expect[t.name]
		if want then
			ok(posOf(t.body, want) > 0, t.name .. " 用 " .. want)
		end
	end
	-- 执行票不挂技能，只保留认领并执行、回报结论的指令
	local task = templates.byId("task")
	ok(task ~= nil, "执行票模板在")
	local taskBody = templates.render(task :: any, { url = "http://x/1", title = "票标题" })
	ok(string.find(taskBody, "/skill:grill-with-docs", 1, true) == nil, "执行票不挂主技能")
	ok(string.find(taskBody, "/skill:prototype", 1, true) == nil, "执行票不挂主技能")
	ok(string.find(taskBody, "/skill:research", 1, true) == nil, "执行票不挂主技能")
	ok(string.find(taskBody, "/skill:wayfinder", 1, true) == nil, "执行票不挂主技能")
	ok(string.find(taskBody, "认领并执行", 1, true) ~= nil, "执行票保留认领并执行")
	ok(string.find(taskBody, "回报", 1, true) ~= nil, "执行票保留回报结论")
end)

test("T4 票动作模板带票链接，执行票带标题与先问不直接开工", function()
	for _, tpl in ipairs(templates.TEMPLATES) do
		local body = templates.render(tpl, { url = "http://x/1", title = "票标题" })
		ok(string.find(body, "http://x/1", 1, true) ~= nil, tpl.title .. " 带票链接")
	end
	local task = templates.byId("task")
	local taskBody = templates.render(task :: any, { url = "http://x/1", title = "票标题" })
	ok(string.find(taskBody, "票标题", 1, true) ~= nil, "执行票带任务标题")
	ok(string.find(taskBody, "先问", 1, true) ~= nil, "执行票要求先问")
	ok(string.find(taskBody, "不直接开工", 1, true) ~= nil, "执行票要求不直接开工")
end)

test("T4 两个入口的路由要点仍在", function()
	local explore = templates.entryById("explore")
	local implement = templates.entryById("implement")
	ok(explore ~= nil and implement ~= nil, "两个入口都在")
	ok(string.find(explore.body, "blockedBy", 1, true) ~= nil, "explore 保留 blockedBy 判断")
	ok(string.find(explore.body, "并行", 1, true) ~= nil, "explore 保留并行")
	ok(string.find(explore.body, "串行", 1, true) ~= nil, "explore 保留串行")
	ok(string.find(explore.body, "/skill:wayfinder", 1, true) ~= nil, "explore 走 wayfinder")
	ok(string.find(implement.body, "/skill:grill-with-docs", 1, true) ~= nil, "implement 走 grill-with-docs")
	ok(string.find(implement.body, "/skill:to-spec", 1, true) ~= nil, "implement 提醒 to-spec")
	ok(string.find(implement.body, "/skill:to-tickets", 1, true) ~= nil, "implement 提醒 to-tickets")
	ok(string.find(implement.body, "手动执行", 1, true) ~= nil, "implement 两步由用户手动执行")
end)

test("T4 每个模板都写清交付形状与可复核信息", function()
	for _, t in ipairs(T4_BODIES) do
		local body = t.body
		ok(string.find(body, "条", 1, true) ~= nil, t.name .. " 写清产出几条")
		ok(
			string.find(body, "票号", 1, true) ~= nil or string.find(body, "文件", 1, true) ~= nil,
			t.name .. " 写清可复核信息"
		)
	end
end)

--- T3：三个按钮模板（问下一步 / 提 BUG / 体检）按统一骨架排布，
--- 公共措辞合并成一段，且各自写清场景化的交付形状。
local T3_BUTTONS: { { name: string, body: string } } = {
	{ name = "问下一步", body = templates.render(templates.NEXT_STEP, { repo = "me/repo" }) },
	{ name = "提 BUG", body = templates.render(templates.NEW_BUG, { repo = "me/repo" }) },
	{ name = "体检", body = templates.render(templates.HEALTH_CHECK, { repo = "me/repo" }) },
}

local function countOf(text: string, needle: string): number
	local n = 0
	for _ in string.gmatch(text, needle) do
		n = n + 1
	end
	return n
end

test("T3 三个按钮按统一骨架排布：目标 → 事实核验 → 边界 → 交付 → 反问", function()
	eq(#T3_BUTTONS, 3, "三个按钮模板")
	for _, t in ipairs(T3_BUTTONS) do
		local goal = posOf(t.body, "## 目标")
		local facts = posOf(t.body, "## 事实核验与工具（先查后问）")
		local bound = posOf(t.body, "## 边界")
		local deliver = posOf(t.body, "## 交付")
		ok(goal > 0, t.name .. " 有目标段")
		ok(facts > goal, t.name .. " 事实核验在目标之后")
		ok(bound > facts, t.name .. " 边界在事实核验之后")
		ok(deliver > bound, t.name .. " 交付在边界之后")
		ok(posOf(t.body, ASK_MARK) > deliver, t.name .. " 反问在交付之后")
	end
end)

test("T3 公共段合并成一段，同一要求不再两处重复", function()
	for _, t in ipairs(T3_BUTTONS) do
		eq(countOf(t.body, "## 事实核验与工具（先查后问）"), 1, t.name .. " 公共段恰好一次")
		eq(countOf(t.body, "票的读写一律走 gh"), 1, t.name .. " gh 读写只写一次")
		eq(countOf(t.body, "2~4 条可选做法"), 1, t.name .. " 收尾可选做法只写一次")
		eq(countOf(t.body, "先读票正文、评论与仓内相关内容"), 1, t.name .. " 先读再问只写一次")
		eq(countOf(t.body, "\n## 工具"), 0, t.name .. " 不再有单独的 ## 工具 段")
		eq(countOf(t.body, "## 调查（先查后问）"), 0, t.name .. " 不再有单独的 ## 调查 段")
	end
end)

test("T3 问下一步写死交付形状与判断顺序", function()
	local body = T3_BUTTONS[1].body
	ok(string.find(body, "最多 3 条", 1, true) ~= nil, "最多 3 条")
	ok(string.find(body, "没核到的：", 1, true) ~= nil, "末行写没核到的")
	ok(string.find(body, "没核到的：无", 1, true) ~= nil, "全都核到写无")
	ok(string.find(body, "做什么 · 用哪个技能命令 · 第一步具体动作 · 一句依据", 1, true) ~= nil, "每条一行的四要素")
	ok(string.find(body, "有坏的正", 1, true) ~= nil, "坏了的正优先")
	ok(string.find(body, "有卡住的活", 1, true) ~= nil, "卡住的活优先")
	ok(string.find(body, "能解锁下游最多", 1, true) ~= nil, "解锁下游最多")
	ok(string.find(body, "盘问 > 调研 > 原型 > 执行", 1, true) ~= nil, "阶段顺序")
end)

test("T3 提 BUG 的索取要素各出现一次且不替报告人编", function()
	local body = T3_BUTTONS[2].body
	for _, part in ipairs({ "现象与影响范围", "期望", "复现步骤", "频率", "OS", "日志" }) do
		eq(countOf(body, part), 1, "提 BUG 的要素「" .. part .. "」恰好一次")
	end
	ok(string.find(body, "不替报告人编", 1, true) ~= nil, "不替报告人编")
	ok(string.find(body, "needs-info", 1, true) ~= nil, "缺的标 needs-info")
	ok(string.find(body, "全扫一遍", 1, true) ~= nil, "查重要全扫")
	ok(string.find(body, "--state open --label bug", 1, true) ~= nil, "扫 open 的 bug 票")
	ok(string.find(body, "--state closed --label bug", 1, true) ~= nil, "扫 closed 的 bug 票")
	ok(string.find(body, "这些是不是同一个问题", 1, true) ~= nil, "命中要问报告人")
	ok(string.find(body, "在旧单下评论", 1, true) ~= nil, "同问题旧单开着则评论补信息")
	ok(string.find(body, "按回归处理", 1, true) ~= nil, "同问题旧单已关则按回归新建")
	ok(string.find(body, "查重记录", 1, true) ~= nil, "查重记录")
end)

test("T3 体检先出建议清单等点头，只做两种结构动作", function()
	local body = T3_BUTTONS[3].body
	ok(string.find(body, "只做两种结构动作", 1, true) ~= nil, "只做两种结构动作")
	ok(string.find(body, "挂到合适的地图下", 1, true) ~= nil, "挂到地图下")
	ok(string.find(body, "开一张新地图", 1, true) ~= nil, "开新地图")
	ok(string.find(body, "等点头", 1, true) ~= nil, "等点头")
	ok(string.find(body, "停下来等点头", 1, true) ~= nil, "写完停下来等点头")
	ok(string.find(body, "不自动往票上写评论", 1, true) ~= nil, "不自动写评论")
	ok(string.find(body, "一律写进建议", 1, true) ~= nil, "其余写进建议")
	ok(string.find(body, "三条同时成立才算", 1, true) ~= nil, "什么算游离的判据")
	ok(string.find(body, "Destination 与 Notes", 1, true) ~= nil, "挑地图的判据")
end)

--- 注入链路的端到端断言：票动作与两个入口都经统一出口，
--- 载荷首尾是信封行，一次动作只发一次请求。
local END_LINE = "===== 注入结束 · 下面是用户输入的内容 ====="

test("票动作注入的正文套信封且带票号", function()
	local st = nextStepState()
	st.ticket = st.tickets[1]
	kvStore["action"] = nil
	panel.event(st, { ev = "action", act = "act:task" }, mkCx(120))
	local action = kvStore["action"]
	ok(type(action) == "table", "写了注入请求")
	eq(action.kind, "inject", "走注入")
	ok(#action.body > 0, "正文非空")
	ok(string.find(action.body, "===== 注入开始 · tern-matt-panel · 执行 · #12 =====", 1, true) == 1, "开始行带动作名与票号")
	ok(string.find(action.body, END_LINE, 1, true) ~= nil, "以结束行收尾")
	eq(st.pendingSeq, action.seq, "一次动作只发一次注入请求")
end)

test("两个入口注入的正文套信封", function()
	for _, case in ipairs({ { id = "explore", act = "入口·还没想清楚" }, { id = "implement", act = "入口·需求已明确" } }) do
		local st = nextStepState()
		kvStore["action"] = nil
		panel.event(st, { ev = "action", act = "new:" .. case.id }, mkCx(120))
		local action = kvStore["action"]
		ok(type(action) == "table", case.id .. " 写了注入请求")
		eq(action.kind, "inject", case.id .. " 走注入")
		ok(string.find(action.body, "===== 注入开始 · tern-matt-panel · " .. case.act .. " =====", 1, true) == 1, case.id .. " 以开始行开头")
		ok(string.find(action.body, END_LINE, 1, true) ~= nil, case.id .. " 以结束行收尾")
		eq(st.pendingSeq, action.seq, case.id .. " 一次动作只发一次注入请求")
	end
end)

test("没识别到仓库时入口正文不留空的仓库填写行", function()
	local st = panel.init(mkCx(120), {}, nil)
	st.repo = nil
	kvStore["action"] = nil
	panel.event(st, { ev = "action", act = "new:explore" }, mkCx(120))
	local action = kvStore["action"]
	ok(type(action) == "table", "写了注入请求")
	ok(string.find(action.body, "仓库：\n", 1, true) == nil, "没有空的仓库行")
	ok(string.find(action.body, "（先识别仓库）", 1, true) ~= nil, "写明先识别仓库")
end)


test("paths.parseRegistryEntry 正常", function()
	local text = '{"mattpocock-skills@mattpocock":{"installPath":"/home/.omp/plugins/cache/plugins/foo","version":"1.3.5"}}'
	local r = paths.parseRegistryEntry(text, "mattpocock-skills@mattpocock")
	ok(type(r) == "table", "返回表")
	eq(r.installPath, "/home/.omp/plugins/cache/plugins/foo")
	eq(r.version, "1.3.5")
end)

test("paths.parseRegistryEntry 缺 key", function()
	local text = '{"other":{"installPath":"/x","version":"1.0.0"}}'
	local r = paths.parseRegistryEntry(text, "mattpocock-skills@mattpocock")
	eq(r, nil)
end)

test("paths.parseRegistryEntry 半截 JSON", function()
	local text = '{"mattpocock-skills@mattpocock":{"installPath":"/x","version":"1.3.5"'
	local r = paths.parseRegistryEntry(text, "mattpocock-skills@mattpocock")
	eq(r, nil)
end)

test("paths.parseRegistryEntry 多条目取首个有 installPath", function()
	local text = '{"mattpocock-skills@mattpocock":[{"installPath":"","version":"1.0.0"},{"installPath":"/real","version":"1.3.5"}]}'
	local r = paths.parseRegistryEntry(text, "mattpocock-skills@mattpocock")
	ok(type(r) == "table", "返回表")
	eq(r.installPath, "/real")
	eq(r.version, "1.3.5")
end)

test("paths.resolvePackage 登记副本优先", function()
	local home = "C:/home"
	env.HOME = home
	env.USERPROFILE = home
	local regPath = home .. "/.omp/plugins/installed_plugins.json"
	local key = paths.REGISTRY_KEY
	local text = '{"' .. key .. '":{"installPath":"' .. home .. '/.omp/plugins/cache/plugins/regcopy","version":"1.3.5"}}'
	fsFiles[regPath] = text
	fsDirs[home .. "/.omp/plugins"] = true
	fsDirs[home .. "/.omp/plugins/cache/plugins/regcopy"] = true
	local pkgDir = home .. "/.omp/plugins/cache/plugins/regcopy"
	fsFiles[pkgDir .. "/package.json"] = '{"version":"9.9.9"}'
	fsDirs[home .. "/.omp/plugins/cache/marketplaces/mattpocock"] = true
	fsFiles[home .. "/.omp/plugins/cache/marketplaces/mattpocock/package.json"] = '{"version":"1.3.7"}'
	local r = paths.resolvePackage()
	ok(type(r) == "table", "返回表")
	eq(r.root, (home .. "/.omp/plugins/cache/plugins/regcopy"):gsub("\\","/"))
	eq(r.version, "1.3.5")
end)

test("paths.resolvePackage 无本包 key 回退市场", function()
	local home = "C:/home3"
	env.HOME = home
	env.USERPROFILE = home
	local regPath = home .. "/.omp/plugins/installed_plugins.json"
	fsFiles[regPath] = '{"other-plugin":{"installPath":"/x","version":"1.0.0"}}'
	fsDirs[home .. "/.omp/plugins/cache/marketplaces/mattpocock"] = true
	fsFiles[home .. "/.omp/plugins/cache/marketplaces/mattpocock/package.json"] = '{"version":"1.3.7"}'
	local r = paths.resolvePackage()
	ok(type(r) == "table", "返回表")
	eq(r.version, "1.3.7")
end)

test("paths.resolvePackage 副本不存在回退市场", function()
	local home = "C:/home2"
	env.HOME = home
	env.USERPROFILE = home
	local key = paths.REGISTRY_KEY
	-- 登记里有本包条目，但 installPath 指向的副本不存在 → 回退市场。
	fsFiles[home .. "/.omp/plugins/installed_plugins.json"] =
		'{"' .. key .. '":{"installPath":"' .. home .. '/.omp/plugins/cache/plugins/gone","version":"1.3.5"}}'
	fsDirs[home .. "/.omp/plugins/cache/marketplaces/mattpocock"] = true
	fsFiles[home .. "/.omp/plugins/cache/marketplaces/mattpocock/package.json"] = '{"version":"1.3.7"}'
	local r, err = paths.resolvePackage()
	ok(type(r) == "table", "返回表")
	eq(r.version, "1.3.7")
	eq(err, nil, "副本不存在不是读失败")
end)

test("paths.resolvePackage 半截登记保留上次值（unreadable）", function()
	local home = "C:/home4"
	env.HOME = home
	env.USERPROFILE = home
	local key = paths.REGISTRY_KEY
	fsFiles[home .. "/.omp/plugins/installed_plugins.json"] =
		'{"' .. key .. '":{"installPath":"/gone","version":"1.3.5"'
	fsDirs[home .. "/.omp/plugins/cache/marketplaces/mattpocock"] = true
	fsFiles[home .. "/.omp/plugins/cache/marketplaces/mattpocock/package.json"] = '{"version":"1.3.7"}'
	local r, err = paths.resolvePackage()
	eq(r, nil, "解析不出条目")
	eq(err, "registry-unreadable", "调用方据此保留上次值")
end)

test("skills.readPackage 版本同根", function()
	local root = "/tmp/skillpkg"
	fsDirs[root .. "/skills"] = true
	fsDirs[root .. "/skills/engineering"] = true
	fsDirs[root .. "/skills/engineering/s1"] = true
	fsFiles[root .. "/skills/engineering/s1/SKILL.md"] = "---\nname: s1\ndescription: d\n---\n正文"
	local pkg = skills.readPackage(root, "2.0.0")
	ok(type(pkg) == "table", "返回表")
	eq(pkg.version, "2.0.0")
	eq(pkg.root, root)
end)

test("胶囊无版本", function()
	ok(type(statusFn) == "function", "statusFn 已注册")
	local res = statusFn(nil)
	ok(type(res) == "table", "返回表")
	eq(res[1].text, "Matt", "无版本时只显示 Matt")
end)

test("focus 后版本更新", function()
	local home = "C:/home"
	env.HOME = home
	env.USERPROFILE = home
	local regPath = home .. "/.omp/plugins/installed_plugins.json"
	local key = paths.REGISTRY_KEY
	local text = '{"' .. key .. '":{"installPath":"' .. home .. '/.omp/plugins/cache/plugins/regcopy","version":"1.3.5"}}'
	fsFiles[regPath] = text
	fsDirs[home .. "/.omp/plugins/cache/plugins/regcopy"] = true
	fsFiles[home .. "/.omp/plugins/cache/plugins/regcopy/package.json"] = '{"version":"9.9.9"}'
	local cx = { session = { focused = function() return nil end, panes = function() return {} end, event = function() end } }
	if handlers["focus"] then
		pcall(function() handlers["focus"]({ pane = 1, tab = 1 }, cx) end)
	end
	local res = statusFn(nil)
	eq(res[1].text, "Matt 1.3.5", "focus 后胶囊显示登记版本")
end)

test("focus 后 chrome.refresh 被调", function()
	local before = chromeRefreshes
	local cx = { session = { focused = function() return nil end, panes = function() return {} end, event = function() end } }
	if handlers["focus"] then
		pcall(function() handlers["focus"]({ pane = 1, tab = 1 }, cx) end)
	end
	ok(chromeRefreshes > before, "refresh 被调")
end)

test("tracker 解析 GraphQL nodes 形状的标签与受理人", function()
	local t = tracker.parseIssue({
		number = 7,
		title = "x",
		state = "OPEN",
		labels = { nodes = { { name = "wayfinder:task" }, { name = "ready-for-agent" } } },
		assignees = { nodes = { { login = "me" } } },
	})
	ok(t ~= nil)
	eq(#t.labels, 2)
	eq(t.labels[1], "wayfinder:task")
	eq(t.assignees[1], "me")
	eq(t.type, "task")
	eq(t.isSpec, true)
end)

test("tracker.parseIssuePage 解析一页与分页信息", function()
	local payload = {
		data = { repository = { issues = {
			nodes = { { number = 1 }, { number = 2 } },
			pageInfo = { hasNextPage = true, endCursor = "c1" },
		} } },
	}
	local page = tracker.parseIssuePage(payload)
	ok(page ~= nil)
	eq(#page.issues, 2)
	eq(page.issues[2].number, 2)
	eq(page.hasNextPage, true)
	eq(page.endCursor, "c1", "转发游标")

	local last = tracker.parseIssuePage({ data = { repository = { issues = {
		nodes = { { number = 3 } },
		pageInfo = { hasNextPage = false, endCursor = "c2" },
	} } } })
	eq(last.hasNextPage, false, "最后一页")

	eq(tracker.parseIssuePage({}), nil, "坏形返回 nil")
	eq(tracker.parseIssuePage({ data = { repository = { issues = {} } } }).hasNextPage, false, "缺 pageInfo 当作没有下一页")
end)

test("tracker.mergeIssues 按票号去重且保留先到顺序", function()
	local a = { { number = 2, title = "a" }, { number = 1, title = "b" } }
	local b = { { number = 1, title = "dup" }, { number = 3, title = "c" } }
	local out = tracker.mergeIssues(a, b)
	eq(#out, 3)
	eq(out[1].number, 2)
	eq(out[2].number, 1)
	eq(out[2].title, "b", "同号保留先到的")
	eq(out[3].number, 3)
end)

test("tracker.capIssues 截到上限", function()
	local list = {}
	for i = 1, 501 do
		table.insert(list, { number = i })
	end
	local out = tracker.capIssues(list, 500)
	eq(#out, 500)
	eq(out[500].number, 500)
	eq(#tracker.capIssues({ { number = 1 } }, 500), 1, "未超限原样返回")
end)

test("tracker.orderDirection 映射到上游排序", function()
	eq(tracker.orderDirection(true), "DESC")
	eq(tracker.orderDirection(false), "ASC")
end)

test("open 侧必须全量：阻塞票在 201 位时仍判定阻塞", function()
	local tickets = {}
	for i = 1, 202 do
		tickets[i] = {
			number = i, title = "t" .. i, body = "", state = "OPEN", url = "",
			labels = {}, assignees = {}, blockedBy = {}, type = nil, parent = nil,
			isSpec = false, createdAt = "2026-11-01T00:00:00Z",
		}
	end
	tickets[1].blockedBy = { 201 }
	local full = tracker.computeFrontier(tickets)
	for _, t in ipairs(full) do
		ok(t.number ~= 1, "被 201 位 OPEN 票阻塞的票不能进可领")
	end
	local partial = {}
	for i = 1, 200 do
		table.insert(partial, tickets[i])
	end
	local wrong = tracker.computeFrontier(partial)
	local seen = false
	for _, t in ipairs(wrong) do
		if t.number == 1 then
			seen = true
		end
	end
	ok(seen, "丢掉 201 页就会把它误判成可领（证明必须全量）")
end)

--- 分页状态：1 张 open + N 张已关，还有下一页。
local function pagedState(closedCount: number?): any
	local st = panel.init(mkCx(120), {}, nil)
	st.view = "board"
	st.repo = "me/repo"
	st.openIssues = { { number = 1, title = "open", state = "OPEN" } }
	st.closedIssues = {}
	for i = 1, (closedCount or 1) do
		table.insert(st.closedIssues, { number = 100 + i, title = "closed" .. i, state = "CLOSED" })
	end
	st.tickets = tracker.parseIssues(tracker.mergeIssues(st.openIssues, st.closedIssues))
	st.maps = {}
	st.closedHasNext = true
	st.closedCursor = "c1"
	st.fetchedAtSec = os.time()
	return st
end

--- 按钮文字里有「加载更多」前缀（标签带条数，不能用精确相等判断不存在）。
local function hasLoadMore(texts: { string }): boolean
	for _, t in ipairs(texts) do
		if string.find(t, "加载更多", 1, true) == 1 then
			return true
		end
	end
	return false
end

test("已关组有下一页时出现加载更多，点一次追加下一页", function()
	local st = pagedState(1)
	local texts = buttonTexts(panel.view(st, mkCx(120)).main, {})
	ok(hasLoadMore(texts), "组内末尾出现加载更多")
	st.loading = true
	ok(not hasLoadMore(buttonTexts(panel.view(st, mkCx(120)).main, {})), "刷新在途时不给续拉")
	st.loading = false
	jsonPayloads["PAGE2"] = { data = { repository = { issues = {
		nodes = { { number = 200, title = "c200", state = "CLOSED" } },
		pageInfo = { hasNextPage = false, endCursor = "c2" },
	} } } }
	processFixtures = { { match = "states:CLOSED", result = { status = 0, stdout = "PAGE2", stderr = "" } } }
	panel.event(st, { ev = "action", act = "load-more-closed" }, mkCx(120))
	eq(#st.closedIssues, 2, "一页追加")
	eq(st.closedIssues[1].number, 101, "旧页在前")
	eq(st.closedIssues[2].number, 200, "新页追加在后")
	eq(st.closedHasNext, false, "上游没有下一页")
	eq(st.closedLoading, false, "加载态复位")
	eq(#st.tickets, 3, "票列表重建")
	local argv = table.concat(processCalls[#processCalls].argv, " ")
	ok(string.find(argv, "after=c1", 1, true) ~= nil, "续拉带旧游标：" .. argv)
	ok(string.find(argv, "direction=DESC", 1, true) ~= nil, "默认最新在前")
	ok(string.find(argv, "first:50", 1, true) ~= nil, "每页 50")
	ok(string.find(argv, "states:CLOSED", 1, true) ~= nil, "只拉已关")
	ok(not hasLoadMore(buttonTexts(panel.view(st, mkCx(120)).main, {})), "没有下一页时按钮消失")
end)

test("续拉缺 endCursor 时不保留下一页游标", function()
	local st = pagedState(1)
	jsonPayloads["NO_CURSOR"] = { data = { repository = { issues = {
		nodes = { { number = 200, title = "c200", state = "CLOSED" } },
		pageInfo = { hasNextPage = true, endCursor = nil },
	} } } }
	processFixtures = { { match = "states:CLOSED", result = { status = 0, stdout = "NO_CURSOR", stderr = "" } } }
	panel.event(st, { ev = "action", act = "load-more-closed" }, mkCx(120))
	eq(#st.closedIssues, 2, "这一页仍追加")
	eq(st.closedHasNext, false, "没有游标就不能继续翻")
	eq(st.closedCursor, nil)
end)

test("续拉空页不改变现有票", function()
	local st = pagedState(2)
	jsonPayloads["EMPTY_PAGE"] = { data = { repository = { issues = {
		nodes = {}, pageInfo = { hasNextPage = false, endCursor = nil },
	} } } }
	processFixtures = { { match = "states:CLOSED", result = { status = 0, stdout = "EMPTY_PAGE", stderr = "" } } }
	panel.event(st, { ev = "action", act = "load-more-closed" }, mkCx(120))
	eq(#st.closedIssues, 2)
	eq(st.closedHasNext, false)
	eq(st.closedLoading, false)
end)

test("续拉在途时重复点击只发一次请求", function()
	local st = pagedState(1)
	jsonPayloads["SLOW"] = { data = { repository = { issues = {
		nodes = { { number = 200, title = "c200", state = "CLOSED" } },
		pageInfo = { hasNextPage = false, endCursor = "c2" },
	} } } }
	processFixtures = { { match = "states:CLOSED", result = { status = 0, stdout = "SLOW", stderr = "" }, defer = true } }
	processCalls = {}
	panel.event(st, { ev = "action", act = "load-more-closed" }, mkCx(120))
	panel.event(st, { ev = "action", act = "load-more-closed" }, mkCx(120))
	local hits = 0
	for _, call in ipairs(processCalls) do
		if string.find(table.concat(call.argv, " "), "states:CLOSED", 1, true) then
			hits += 1
		end
	end
	eq(hits, 1, "在途时第二次点击被挡")
	flushProcess()
	eq(#st.closedIssues, 2)
	eq(st.closedLoading, false)
end)

test("续拉坏页保持旧数据并复位加载态", function()
	local st = pagedState(2)
	jsonPayloads["BAD_PAGE"] = { data = {} }
	processFixtures = { { match = "states:CLOSED", result = { status = 0, stdout = "BAD_PAGE", stderr = "" } } }
	panel.event(st, { ev = "action", act = "load-more-closed" }, mkCx(120))
	eq(#st.closedIssues, 2)
	eq(st.closedLoading, false)
	ok(string.find(tostring(st.message), "已关票拉取失败", 1, true) ~= nil, "提示失败")
end)

test("续拉失败保留游标以便重试", function()
	local st = pagedState(2)
	processFixtures = { { match = "states:CLOSED", result = { status = 1, stdout = "", stderr = "boom" } } }
	panel.event(st, { ev = "action", act = "load-more-closed" }, mkCx(120))
	eq(st.closedCursor, "c1", "游标没被清掉")
	eq(st.closedHasNext, true, "还能重试")
	eq(st.closedLoading, false)
end)

test("加载更多条数按已加载已关票算，不被顶层 spec 过滤影响", function()
	local st = pagedState(1)
	table.insert(st.closedIssues, {
		number = 500, title = "closed spec", state = "CLOSED",
		labels = { "ready-for-agent" }, assignees = {}, blockedBy = {},
	})
	st.tickets = tracker.parseIssues(tracker.mergeIssues(st.openIssues, st.closedIssues))
	local texts = buttonTexts(panel.view(st, mkCx(120)).main, {})
	ok(util.contains(texts, "加载更多（已 2 条）"), "条数用原始已关票数，不是过滤后的组数：" .. table.concat(texts, ","))
end)

test("已关组到 500 上限后不再显示加载更多", function()
	local st = pagedState(500)
	ok(not hasLoadMore(buttonTexts(panel.view(st, mkCx(120)).main, {})), "上限后按钮消失")
	processCalls = {}
	panel.event(st, { ev = "action", act = "load-more-closed" }, mkCx(120))
	eq(#processCalls, 0, "上限后不再发请求")
end)

test("切排序丢弃已关页并按新方向重拉", function()
	local st = pagedState(2)
	jsonPayloads["OPEN_ASC"] = { data = { repository = { issues = {
		nodes = { { number = 1, title = "open", state = "OPEN" } },
		pageInfo = { hasNextPage = false, endCursor = nil },
	} } } }
	jsonPayloads["PAGE_ASC"] = { data = { repository = { issues = {
		nodes = { { number = 300, title = "oldest", state = "CLOSED" } },
		pageInfo = { hasNextPage = true, endCursor = "a1" },
	} } } }
	processFixtures = {
		{ match = "remote", result = { status = 0, stdout = "https://github.com/me/repo.git", stderr = "" } },
		{ match = "states:OPEN", result = { status = 0, stdout = "OPEN_ASC", stderr = "" } },
		{ match = "states:CLOSED", result = { status = 0, stdout = "PAGE_ASC", stderr = "" } },
	}
	processCalls = {}
	panel.event(st, { ev = "action", act = "toggle-sort" }, mkCx(120))
	eq(st.sortNewest, false)
	eq(#st.closedIssues, 1, "回到第一页")
	eq(st.closedIssues[1].number, 300)
	local last = ""
	for _, call in ipairs(processCalls) do
		local argv = table.concat(call.argv, " ")
		if string.find(argv, "states:CLOSED", 1, true) then
			last = argv
		end
	end
	ok(string.find(last, "states:CLOSED", 1, true) ~= nil, "找到已关页请求")
	ok(string.find(last, "direction=ASC", 1, true) ~= nil, "方向映射到上游：" .. last)
	eq(st.closedCursor, "a1")
	eq(st.closedHasNext, true)
end)

test("续拉在途时切排序：旧回调作废，不把旧方向页混进新序列", function()
	local st = pagedState(1)
	jsonPayloads["PAGE_OLD"] = { data = { repository = { issues = {
		nodes = { { number = 999, title = "stale", state = "CLOSED" } },
		pageInfo = { hasNextPage = false, endCursor = "old" },
	} } } }
	processFixtures = {
		{ match = "remote", result = { status = 0, stdout = "https://github.com/me/repo.git", stderr = "" } },
		{ match = "states:CLOSED", result = { status = 0, stdout = "PAGE_OLD", stderr = "" }, defer = true },
	}
	panel.event(st, { ev = "action", act = "load-more-closed" }, mkCx(120))
	ok(st.closedLoading == true, "续拉在途")
	panel.event(st, { ev = "action", act = "toggle-sort" }, mkCx(120))
	flushProcess()
	eq(#st.closedIssues, 1, "旧方向的续拉回调被世代号丢弃")
	eq(st.closedIssues[1].number, 101)
end)

test("冷却中切排序：旧游标作废，按钮消失", function()
	local st = pagedState(2)
	st.cooldownUntil = os.time() + 60
	processCalls = {}
	panel.event(st, { ev = "action", act = "toggle-sort" }, mkCx(120))
	eq(st.sortNewest, false)
	eq(st.closedHasNext, false, "旧游标作废")
	eq(st.closedCursor, nil)
	ok(not hasLoadMore(buttonTexts(panel.view(st, mkCx(120)).main, {})), "冷却中不显示加载更多")
	for _, call in ipairs(processCalls) do
		ok(string.find(table.concat(call.argv, " "), "states:CLOSED", 1, true) == nil, "冷却中不发已关请求")
	end
end)

test("切排序重拉失败：保留旧内容但不再用旧游标续拉", function()
	local st = pagedState(2)
	jsonPayloads["OPEN_FAIL"] = { data = { repository = { issues = {
		nodes = { { number = 1, title = "open", state = "OPEN" } },
		pageInfo = { hasNextPage = false, endCursor = nil },
	} } } }
	processFixtures = {
		{ match = "remote", result = { status = 0, stdout = "https://github.com/me/repo.git", stderr = "" } },
		{ match = "states:OPEN", result = { status = 0, stdout = "OPEN_FAIL", stderr = "" } },
		{ match = "states:CLOSED", result = { status = 1, stdout = "", stderr = "boom" } },
	}
	panel.event(st, { ev = "action", act = "toggle-sort" }, mkCx(120))
	eq(#st.closedIssues, 2, "旧已关内容保留")
	eq(st.closedHasNext, false, "旧游标不能继续用")
	eq(st.closedCursor, nil)
	ok(not hasLoadMore(buttonTexts(panel.view(st, mkCx(120)).main, {})), "不再显示加载更多")
	ok(string.find(tostring(st.message), "已关票拉取失败", 1, true) ~= nil, "提示失败")
end)

test("假数据翻页：50 → 100 → 120，去重且到末页按钮消失", function()
	local st = pagedState(0)
	local nodes2, nodes3 = {}, {}
	for i = 151, 200 do
		table.insert(nodes2, { number = i, title = "c" .. i, state = "CLOSED" })
	end
	for i = 201, 220 do
		table.insert(nodes3, { number = i, title = "c" .. i, state = "CLOSED" })
	end
	jsonPayloads["P2"] = { data = { repository = { issues = {
		nodes = nodes2, pageInfo = { hasNextPage = true, endCursor = "c2" },
	} } } }
	jsonPayloads["P3"] = { data = { repository = { issues = {
		nodes = nodes3, pageInfo = { hasNextPage = false, endCursor = "c3" },
	} } } }
	-- 首屏也造 50 条，避免依赖 pagedState 的编号。
	for i = 101, 150 do
		table.insert(st.closedIssues, { number = i, title = "c" .. i, state = "CLOSED" })
	end
	st.tickets = tracker.parseIssues(st.closedIssues)
	processFixtures = { { match = "states:CLOSED", results = {
		{ status = 0, stdout = "P2", stderr = "" },
		{ status = 0, stdout = "P3", stderr = "" },
	} } }
	eq(#st.closedIssues, 50, "首屏 50")
	panel.event(st, { ev = "action", act = "load-more-closed" }, mkCx(120))
	eq(#st.closedIssues, 100, "第一次续拉到 100")
	ok(hasLoadMore(buttonTexts(panel.view(st, mkCx(120)).main, {})), "还有下一页")
	panel.event(st, { ev = "action", act = "load-more-closed" }, mkCx(120))
	eq(#st.closedIssues, 120, "第二次续拉到 120")
	eq(st.closedHasNext, false, "末页")
	ok(not hasLoadMore(buttonTexts(panel.view(st, mkCx(120)).main, {})), "末页按钮消失")
	local seen = {}
	for _, t in ipairs(st.closedIssues) do
		ok(not seen[t.number], "票号重复：" .. tostring(t.number))
		seen[t.number] = true
	end
end)

test("续拉失败保留已加载内容并提示，不清屏", function()
	local st = pagedState(2)
	local before = #st.closedIssues
	processFixtures = { { match = "states:CLOSED", result = { status = 1, stdout = "", stderr = "boom" } } }
	panel.event(st, { ev = "action", act = "load-more-closed" }, mkCx(120))
	eq(#st.closedIssues, before, "已加载内容还在")
	eq(#st.tickets, 3, "票列表没被清空")
	ok(string.find(tostring(st.message), "已关票拉取失败", 1, true) ~= nil, "提示失败")
end)

test("分页游标与条数不跨面板块持久化", function()
	local st = pagedState(2)
	local saved = panel.save(st)
	eq(saved.closedCursor, nil)
	eq(saved.closedHasNext, nil)
	eq(saved.openIssues, nil)
	eq(saved.closedIssues, nil)
end)

--- 找带指定 key 后缀的列表节点。
local function listFor(node: any, suffix: string): any?
	if type(node) ~= "table" then
		return nil
	end
	local p = node.p
	if node.k == "list" and type(p) == "table" and type(p.key) == "string"
		and string.sub(p.key, -#suffix) == suffix then
		return node
	end
	for _, kid in ipairs(node.c or {}) do
		local got = listFor(kid, suffix)
		if got then
			return got
		end
	end
	return nil
end

test("已关闭组保持上游顺序，open 组按创建时间本地排序", function()
	local st = pagedState(0)
	st.openIssues = {
		{ number = 1, title = "open-old", state = "OPEN", createdAt = "2026-01-01T00:00:00Z" },
		{ number = 2, title = "open-new", state = "OPEN", createdAt = "2026-02-01T00:00:00Z" },
	}
	st.closedIssues = {
		{ number = 11, title = "closed-old", state = "CLOSED", createdAt = "2026-01-01T00:00:00Z" },
		{ number = 12, title = "closed-new", state = "CLOSED", createdAt = "2026-02-01T00:00:00Z" },
	}
	st.tickets = tracker.parseIssues(tracker.mergeIssues(st.openIssues, st.closedIssues))
	local main = panel.view(st, mkCx(120)).main
	local closed = listFor(main, "_closed")
	eq(closed.c[1].label, "closed-old", "已关闭第一行是上游第一行")
	eq(closed.c[2].label, "closed-new")
	local open = listFor(main, "_claimable")
	eq(open.c[1].label, "open-new", "open 组最新在前")
end)

test("刷新按游标拉完 open 所有页，再拉已关首屏", function()
	jsonPayloads["OPEN1"] = { data = { repository = { issues = {
		nodes = { { number = 1, title = "a", state = "OPEN" }, { number = 2, title = "b", state = "OPEN" } },
		pageInfo = { hasNextPage = true, endCursor = "c1" },
	} } } }
	jsonPayloads["OPEN2"] = { data = { repository = { issues = {
		nodes = { { number = 3, title = "c", state = "OPEN" } },
		pageInfo = { hasNextPage = false, endCursor = "c2" },
	} } } }
	jsonPayloads["CLOSED1"] = { data = { repository = { issues = {
		nodes = { { number = 9, title = "z", state = "CLOSED" } },
		pageInfo = { hasNextPage = true, endCursor = "d1" },
	} } } }
	processFixtures = {
		{ match = "remote", result = { status = 0, stdout = "https://github.com/me/repo.git", stderr = "" } },
		{ match = "states:OPEN", results = {
			{ status = 0, stdout = "OPEN1", stderr = "" },
			{ status = 0, stdout = "OPEN2", stderr = "" },
		} },
		{ match = "states:CLOSED", result = { status = 0, stdout = "CLOSED1", stderr = "" } },
	}
	processCalls = {}
	local st = panel.init(mkCx(120), {}, nil)
	eq(#st.openIssues, 3, "open 翻了两页")
	eq(#st.closedIssues, 1, "已关首屏一页")
	eq(#st.tickets, 4, "四张票都进了状态")
	eq(st.closedHasNext, true, "已关还有下一页")
	eq(st.closedCursor, "d1")
	local openCalls = 0
	for _, call in ipairs(processCalls) do
		if string.find(table.concat(call.argv, " "), "states:OPEN", 1, true) then
			openCalls += 1
		end
	end
	eq(openCalls, 2, "open 确实发了两发")
end)

test("点地图行按需拉正文并解析迷雾/范围外", function()
	local st = panel.init(mkCx(120), {}, nil)
	st.view = "board"
	st.repo = "me/repo"
	st.maps = { { number = 1, title = "地图一", url = "u1", state = "OPEN", body = "", tickets = {} } }
	processFixtures = { {
		match = "repos/me/repo/issues/1",
		result = { status = 0, stdout = "## 尚未明确\n- 先做 A\n\n## 范围外\n- 不做 B\n", stderr = "" },
	} }
	processCalls = {}
	panel.event(st, { ev = "select", item = "main.1.123.1" }, mkCx(120))
	eq(#processCalls, 1, "发了一次正文请求")
	local argv = table.concat(processCalls[1].argv, " ")
	ok(string.find(argv, "repos/me/repo/issues/1", 1, true) ~= nil, "按票号拉正文")
	eq(st.maps[1].bodyLoaded, true)
	eq(st.maps[1].fog, "- 先做 A", "解析尚未明确")
	eq(st.maps[1].outOfScope, "- 不做 B", "解析范围外")
	local text = table.concat(allText(panel.view(st, mkCx(120)).main, {}), " | ")
	ok(string.find(text, "尚未明确（迷雾）", 1, true) ~= nil, "显示迷雾节")
	ok(string.find(text, "范围外", 1, true) ~= nil, "显示范围外节")
end)

test("刷新后仍在地图页：重建的 Map 会补拉正文", function()
	local st = panel.init(mkCx(120), {}, nil)
	st.view = "map"
	st.mapSel = 1
	st.repo = "me/repo"
	st.maps = { { number = 1, title = "地图一", url = "u1", state = "OPEN", body = "", bodyLoaded = true, tickets = {} } }
	jsonPayloads["OPEN_MAP"] = { data = { repository = { issues = {
		nodes = { { number = 1, title = "地图一", state = "OPEN", labels = { nodes = { { name = "wayfinder:map" } } } } },
		pageInfo = { hasNextPage = false, endCursor = nil },
	} } } }
	jsonPayloads["CLOSED_EMPTY"] = { data = { repository = { issues = {
		nodes = {}, pageInfo = { hasNextPage = false, endCursor = nil },
	} } } }
	processFixtures = {
		{ match = "remote", result = { status = 0, stdout = "https://github.com/me/repo.git", stderr = "" } },
		{ match = "states:OPEN", result = { status = 0, stdout = "OPEN_MAP", stderr = "" } },
		{ match = "states:CLOSED", result = { status = 0, stdout = "CLOSED_EMPTY", stderr = "" } },
		{ match = "repos/me/repo/issues/1", result = { status = 0, stdout = "## 尚未明确\n- 补拉成功\n", stderr = "" } },
	}
	processCalls = {}
	panel.event(st, { ev = "action", act = "reload" }, mkCx(120))
	eq(#st.maps, 1, "刷新后地图还在")
	eq(st.maps[1].bodyLoaded, true, "仍在地图页会补拉正文")
	eq(st.maps[1].fog, "- 补拉成功", "迷雾重新解析")
	local hit = false
	for _, call in ipairs(processCalls) do
		if string.find(table.concat(call.argv, " "), "repos/me/repo/issues/1", 1, true) then
			hit = true
		end
	end
	ok(hit, "刷新后发了地图正文请求")
end)

test("手动指定仓库优先于 cwd 的 remote", function()
	kvStore["repo"] = { repo = "me/manual", pane = 7 }
	jsonPayloads["EMPTY_O"] = { data = { repository = { issues = {
		nodes = {}, pageInfo = { hasNextPage = false, endCursor = nil },
	} } } }
	jsonPayloads["EMPTY_C"] = { data = { repository = { issues = {
		nodes = {}, pageInfo = { hasNextPage = false, endCursor = nil },
	} } } }
	processFixtures = {
		{ match = "remote", result = { status = 0, stdout = "https://github.com/me/cwd.git", stderr = "" } },
		{ match = "states:OPEN", result = { status = 0, stdout = "EMPTY_O", stderr = "" } },
		{ match = "states:CLOSED", result = { status = 0, stdout = "EMPTY_C", stderr = "" } },
	}
	processCalls = {}
	local st = panel.init(mkCx(120), {}, nil)
	eq(st.repo, "me/manual", "手动值覆盖 cwd remote")
	eq(st.repoManual, true)
	local sawRemote = false
	local sawManual = false
	for _, call in ipairs(processCalls) do
		local argv = table.concat(call.argv, " ")
		if string.find(argv, "remote", 1, true) then
			sawRemote = true
		end
		if string.find(argv, "owner=me", 1, true) and string.find(argv, "name=manual", 1, true) then
			sawManual = true
		end
	end
	ok(sawManual, "请求打到手动仓库")
	ok(not sawRemote, "手动模式不再推断 cwd")
	st.view = "board"
	local text = table.concat(allText(panel.view(st, mkCx(120)).main, {}), " | ")
	ok(string.find(text, "刷新仍用这个仓库", 1, true) ~= nil, "标出手动来源")
end)

test("手动值为空时回到 cwd 的 remote", function()
	kvStore["repo"] = { repo = "", pane = 7 }
	jsonPayloads["EMPTY_O"] = { data = { repository = { issues = {
		nodes = {}, pageInfo = { hasNextPage = false, endCursor = nil },
	} } } }
	jsonPayloads["EMPTY_C"] = { data = { repository = { issues = {
		nodes = {}, pageInfo = { hasNextPage = false, endCursor = nil },
	} } } }
	processFixtures = {
		{ match = "remote", result = { status = 0, stdout = "https://github.com/me/cwd.git", stderr = "" } },
		{ match = "states:OPEN", result = { status = 0, stdout = "EMPTY_O", stderr = "" } },
		{ match = "states:CLOSED", result = { status = 0, stdout = "EMPTY_C", stderr = "" } },
	}
	local st = panel.init(mkCx(120), {}, nil)
	eq(st.repo, "me/cwd", "空手动值回退 cwd")
	eq(st.repoManual, false)
end)

test("重置仓库清掉手动值并回到 cwd", function()
	kvStore["repo"] = { repo = "me/manual", pane = 7 }
	jsonPayloads["EMPTY_O"] = { data = { repository = { issues = {
		nodes = {}, pageInfo = { hasNextPage = false, endCursor = nil },
	} } } }
	jsonPayloads["EMPTY_C"] = { data = { repository = { issues = {
		nodes = {}, pageInfo = { hasNextPage = false, endCursor = nil },
	} } } }
	processFixtures = {
		{ match = "remote", result = { status = 0, stdout = "https://github.com/me/cwd.git", stderr = "" } },
		{ match = "states:OPEN", result = { status = 0, stdout = "EMPTY_O", stderr = "" } },
		{ match = "states:CLOSED", result = { status = 0, stdout = "EMPTY_C", stderr = "" } },
	}
	local st = panel.init(mkCx(120), {}, nil)
	eq(st.repo, "me/manual")
	-- 造一点旧仓库状态：重置必须整份清掉，而不是只换标题。
	st.tickets = { { number = 1, title = "old", body = "", state = "OPEN", url = "", labels = {}, assignees = {}, blockedBy = {}, isSpec = false } }
	st.maps = { { number = 1, title = "old map", url = "", state = "OPEN", body = "", tickets = {} } }
	st.openIssues = { { number = 1 } }
	st.closedIssues = { { number = 2 } }
	st.closedCursor = "old"
	st.closedHasNext = true
	st.mapSel = 1
	processCalls = {}
	panel.event(st, { ev = "action", act = "reset-repo" }, mkCx(120))
	eq(kvStore["repo"].repo, "", "手动值已清")
	eq(st.repo, "me/cwd", "回到 cwd 仓库")
	eq(st.repoManual, false)
	eq(#st.tickets, 0, "旧票已清")
	eq(#st.maps, 0, "旧地图已清")
	eq(#st.openIssues, 0)
	eq(#st.closedIssues, 0)
	eq(st.closedCursor, nil)
	eq(st.closedHasNext, false)
	eq(st.mapSel, nil)
	local sawCwd = false
	for _, call in ipairs(processCalls) do
		local argv = table.concat(call.argv, " ")
		if string.find(argv, "owner=me", 1, true) and string.find(argv, "name=cwd", 1, true) then
			sawCwd = true
		end
	end
	ok(sawCwd, "重置后请求打到 cwd 仓库")
end)

test("地图正文失败可重试且不留半截", function()
	local st = panel.init(mkCx(120), {}, nil)
	st.view = "board"
	st.repo = "me/repo"
	st.maps = { { number = 1, title = "地图一", url = "u1", state = "OPEN", body = "", tickets = {} } }
	processFixtures = { {
		match = "repos/me/repo/issues/1",
		result = { status = 1, stdout = "", stderr = "boom" },
	} }
	panel.event(st, { ev = "select", item = "main.1.123.1" }, mkCx(120))
	eq(st.maps[1].bodyLoaded, false, "失败不标记已加载，允许重试")
	eq(st.maps[1].body, "")
	eq(st.maps[1].fog, nil)
	ok(string.find(tostring(st.message), "取地图正文失败", 1, true) ~= nil, "提示失败")
end)

test("地图正文没有两节时不伪造内容", function()
	local st = panel.init(mkCx(120), {}, nil)
	st.view = "board"
	st.repo = "me/repo"
	st.maps = { { number = 1, title = "地图一", url = "u1", state = "OPEN", body = "", tickets = {} } }
	processFixtures = { {
		match = "repos/me/repo/issues/1",
		result = { status = 0, stdout = "普通正文，没有小节", stderr = "" },
	} }
	panel.event(st, { ev = "select", item = "main.1.123.1" }, mkCx(120))
	eq(st.maps[1].bodyLoaded, true)
	eq(st.maps[1].fog, nil)
	eq(st.maps[1].outOfScope, nil)
	local text = table.concat(allText(panel.view(st, mkCx(120)).main, {}), " | ")
	ok(string.find(text, "尚未明确（迷雾）", 1, true) == nil, "不显示空迷雾节")
	ok(string.find(text, "范围外", 1, true) == nil, "不显示空范围外节")
end)

test("地图正文在途时重复点击只发一次请求", function()
	local st = panel.init(mkCx(120), {}, nil)
	st.view = "board"
	st.repo = "me/repo"
	st.maps = { { number = 1, title = "地图一", url = "u1", state = "OPEN", body = "", tickets = {} } }
	processFixtures = { {
		match = "repos/me/repo/issues/1",
		result = { status = 0, stdout = "## 尚未明确\n- 慢请求\n", stderr = "" },
		defer = true,
	} }
	processCalls = {}
	panel.event(st, { ev = "select", item = "main.1.123.1" }, mkCx(120))
	panel.event(st, { ev = "select", item = "main.1.123.1" }, mkCx(120))
	eq(#processCalls, 1, "只请求一次")
	flushProcess()
	eq(st.maps[1].bodyLoaded, true)
	eq(st.maps[1].fog, "- 慢请求")
end)


-- ------------------------------------------------------------ 外部技能包 ----

--- 文本里是否出现过某段话（文本收集器按 span 切开，版本号常带着缩进）。
local function hasText(list: { string }, needle: string): boolean
	for _, v in ipairs(list) do
		if string.find(v, needle, 1, true) then
			return true
		end
	end
	return false
end

test("packs 清单：三套、id 唯一、都带仓库与安装指引", function()
	eq(#packs.PACKS, 3)
	local seen: { [string]: boolean } = {}
	for _, p in ipairs(packs.PACKS) do
		ok(not seen[p.id], "id 重复：" .. p.id)
		seen[p.id] = true
		ok(p.repo ~= "", p.id .. " 缺仓库")
		ok(#p.install > 0, p.id .. " 缺安装指引")
		ok(p.purpose ~= "", p.id .. " 缺用途")
	end
end)

test("packs.versionLabel 缺版本不留空", function()
	eq(packs.versionLabel(nil), "未知版本")
	eq(packs.versionLabel(""), "未知版本")
	eq(packs.versionLabel("0.5.10"), "0.5.10")
end)

test("packs.stateOf 区分已装与未装", function()
	local p = packs.byId("omp-skill-forge")
	ok(p ~= nil, "找到包")
	local off = packs.stateOf(p, false, nil)
	eq(off.status, "未装")
	eq(off.installed, false)
	eq(off.url, "https://github.com/meisijiya/omp-skill-forge")
	local on = packs.stateOf(p, true, "0.5.0")
	eq(on.status, "已装")
	eq(on.version, "0.5.0")
end)

--- 造一份登记：两套走登记的包都写进去。
local function writeRegistry(mattVersion: string?, amVersion: string?)
	local matt = mattVersion and ('"version":"' .. mattVersion .. '",') or ""
	local am = amVersion and ('"version":"' .. amVersion .. '",') or ""
	-- 主技能组的登记键是真实值（不是这里的字面量），所以直接取 paths.REGISTRY_KEY。
	fsFiles["C:/home/.omp/plugins/installed_plugins.json"] = table.concat({
		'{"version":2,"plugins":{',
		'"' .. paths.REGISTRY_KEY .. '":[{"scope":"user","installPath":"C:/p/matt",', matt, '"enabled":true}],',
		'"answer-me-with-html@answer-me-with-html":[{"scope":"user","installPath":"C:/p/am",', am, '"scope":"user"}]}}',
	})
end

test("技能包：登记里的两套按 installPath 判已装，本地目录那套按目录判", function()
	writeRegistry("1.3.5", "0.5.10")
	fsDirs["C:/p/matt"] = true
	fsDirs["C:/p/am"] = true
	fsDirs["C:/home/.omp/agent/local/omp-skill-forge"] = true
	fsFiles["C:/home/.omp/agent/local/omp-skill-forge/package.json"] = '{"name":"omp-skill-forge","version":"0.5.0"}'
	local st = panel.init(mkCx(120), {}, nil)
	eq(#st.packs, 3)
	local by: { [string]: any } = {}
	for _, p in ipairs(st.packs) do
		by[p.id] = p
	end
	eq(by["mattpocock"].installed, true)
	eq(by["mattpocock"].version, "1.3.5")
	eq(by["answer-me-with-html"].version, "0.5.10")
	eq(by["omp-skill-forge"].version, "0.5.0")
end)

test("技能包：登记没写版本时回退安装根的 package.json", function()
	writeRegistry(nil, nil)
	fsDirs["C:/p/matt"] = true
	fsFiles["C:/p/matt/package.json"] = '{"name":"mattpocock-skills","version":"9.9.9"}'
	fsDirs["C:/p/am"] = true
	local st = panel.init(mkCx(120), {}, nil)
	local by: { [string]: any } = {}
	for _, p in ipairs(st.packs) do
		by[p.id] = p
	end
	eq(by["mattpocock"].version, "9.9.9")
	eq(by["answer-me-with-html"].status, "已装")
	eq(by["omp-skill-forge"].status, "未装")
end)

test("技能包：登记有条目但目录不在 → 未装", function()
	writeRegistry("1.3.5", "0.5.10")
	local st = panel.init(mkCx(120), {}, nil)
	local by: { [string]: any } = {}
	for _, p in ipairs(st.packs) do
		by[p.id] = p
	end
	eq(by["mattpocock"].status, "未装")
	eq(by["mattpocock"].version, "1.3.5")
end)

test("技能包视图：三张卡露出标题、版本与安装指引，窄面板也有入口", function()
	writeRegistry("1.3.5", "0.5.10")
	fsDirs["C:/p/matt"] = true
	fsDirs["C:/p/am"] = true
	fsDirs["C:/home/.omp/agent/local/omp-skill-forge"] = true
	fsFiles["C:/home/.omp/agent/local/omp-skill-forge/package.json"] = '{"version":"0.5.0"}'
	local st = panel.init(mkCx(120), {}, nil)
	st.view = "packs"
	local texts = allText(panel.view(st, mkCx(120)).main, {})
	ok(util.contains(texts, "mattpocock 技能组"), "有主技能组卡")
	ok(util.contains(texts, "answer-me-with-html"), "有可视化包卡")
	ok(util.contains(texts, "omp-skill-forge"), "有选路包卡")
	ok(hasText(texts, "1.3.5"), "露出主技能组版本")
	ok(hasText(texts, "0.5.10"), "露出可视化包版本")
	ok(hasText(texts, "0.5.0"), "露出选路包版本")
	local tight = panel.init(mkCx(24), {}, nil)
	local ttexts = buttonTexts(panel.view(tight, mkCx(24)).main, {})
	ok(util.contains(ttexts, "技能包"), "窄面板也有技能包入口")
end)

test("技能包：复制仓库链接与安装指引", function()
	local st = panel.init(mkCx(120), {}, nil)
	local copied: { string } = {}
	local cx: any = mkCx(120)
	cx.copy = function(_self: any, text: string)
		table.insert(copied, text)
	end
	panel.event(st, { ev = "action", act = "copy-pack-repo:omp-skill-forge" }, cx)
	eq(copied[1], "https://github.com/meisijiya/omp-skill-forge")
	panel.event(st, { ev = "action", act = "copy-pack-install:answer-me-with-html" }, cx)
	ok(string.find(copied[2], "claude plugin install answer-me-with-html@answer-me-with-html", 1, true) ~= nil, "安装指引是上游原文")
end)


test("packs.tagFromOutput 去掉 v 前缀与空白", function()
	eq(packs.tagFromOutput("v0.5.0\n"), "0.5.0")
	eq(packs.tagFromOutput("  1.2.3 "), "1.2.3")
	eq(packs.tagFromOutput(""), nil)
	eq(packs.tagFromOutput(nil), nil)
end)

test("packs.compareVersion 边界", function()
	eq(packs.compareVersion("0.5.0", "0.5.0"), "same")
	eq(packs.compareVersion("0.5.0", "v0.6.0"), "older")
	eq(packs.compareVersion("1.3.5", "1.3.2"), "newer")
	eq(packs.compareVersion("0.5", "0.5.0"), "same")
	eq(packs.compareVersion("abc", "1.0.0"), "unknown")
	eq(packs.compareVersion(nil, "1.0.0"), "unknown")
end)

test("packs.withCheck 五种状态与失败保留上次", function()
	local p = packs.byId("omp-skill-forge")
	ok(p ~= nil, "找到包")
	local base = packs.stateOf(p, true, "0.5.0")
	eq(packs.withCheck(base, "0.6.0", false, "10:00").status, "待更新")
	eq(packs.withCheck(base, "0.5.0", false, "10:00").status, "已是最新")
	eq(packs.withCheck(base, "0.4.9", false, "10:00").status, "本地较新")
	eq(packs.withCheck(base, "abc", false, "10:00").status, "无法比较")
	local ok1 = packs.withCheck(base, "0.5.0", false, "10:00")
	local failed1 = packs.withCheck(ok1, nil, true, "11:00")
	eq(failed1.status, "检查失败 · 上次 10:00")
	eq(failed1.latest, "0.5.0", "失败时保留上次结果")
	eq(packs.withCheck(base, nil, true, nil).status, "检查失败", "从没成功过就不写上次")
	eq(packs.withCheck(packs.stateOf(p, false, nil), "9.9.9", false, "10:00").status, "未装")
end)

--- 装好三套包：登记两套 + 本地目录一套。
local function installedPacks()
	writeRegistry("1.3.5", "0.5.10")
	fsDirs["C:/p/matt"] = true
	fsDirs["C:/p/am"] = true
	fsDirs["C:/home/.omp/agent/local/omp-skill-forge"] = true
	fsFiles["C:/home/.omp/agent/local/omp-skill-forge/package.json"] = '{"version":"0.5.0"}'
end

local function packsBy(st: any): { [string]: any }
	local by: { [string]: any } = {}
	for _, p in ipairs(st.packs) do
		by[p.id] = p
	end
	return by
end

test("技能包刷新：查上游版本写回状态，不碰任务板", function()
	installedPacks()
	processFixtures = {
		{ match = "repos/devcxl/mattpocock-skills-zh/releases/latest", result = { status = 0, stdout = "v1.3.5\n" } },
		{ match = "repos/QingYunA/answer-me-with-html/releases/latest", result = { status = 0, stdout = "v0.5.11\n" } },
		{ match = "repos/meisijiya/omp-skill-forge/releases/latest", result = { status = 0, stdout = "v0.5.0\n" } },
	}
	local st = panel.init(mkCx(120), {}, nil)
	local base = #processCalls
	local lastLoad = st.lastLoadAt
	panel.event(st, { ev = "action", act = "packs-refresh" }, mkCx(120))
	eq(#processCalls - base, 3, "三套各查一次")
	local by = packsBy(st)
	eq(by["mattpocock"].status, "已是最新")
	eq(by["answer-me-with-html"].status, "待更新")
	eq(by["omp-skill-forge"].status, "已是最新")
	eq(st.lastLoadAt, lastLoad, "不动任务板的刷新时刻")
end)

test("技能包刷新：5 分钟内连点不重复查询", function()
	installedPacks()
	processFixtures = {
		{ match = "/releases/latest", result = { status = 0, stdout = "v0.5.0\n" } },
	}
	local st = panel.init(mkCx(120), {}, nil)
	local base = #processCalls
	panel.event(st, { ev = "action", act = "packs-refresh" }, mkCx(120))
	panel.event(st, { ev = "action", act = "packs-refresh" }, mkCx(120))
	eq(#processCalls - base, 3, "第二次被节流")
	ok(string.find(tostring(st.message), "刚查过", 1, true) ~= nil, "提示节流")
end)

test("技能包刷新：上游查不到时保留上次结果并标检查失败", function()
	installedPacks()
	processFixtures = {
		{ match = "/releases/latest", result = { status = 0, stdout = "v0.5.0\n" } },
	}
	local st = panel.init(mkCx(120), {}, nil)
	panel.event(st, { ev = "action", act = "packs-refresh" }, mkCx(120))
	local by = packsBy(st)
	eq(by["omp-skill-forge"].latest, "0.5.0")
	-- 绕过节流再来一次，这次上游查不到
	st.packsCheckedAt = nil
	processFixtures = {}
	panel.event(st, { ev = "action", act = "packs-refresh" }, mkCx(120))
	by = packsBy(st)
	eq(by["omp-skill-forge"].latest, "0.5.0", "保留上次成功的结果")
	ok(string.find(by["omp-skill-forge"].status, "检查失败", 1, true) == 1, "标检查失败")
end)

test("技能包视图有独立刷新按钮", function()
	installedPacks()
	local st = panel.init(mkCx(120), {}, nil)
	st.view = "packs"
	local texts = buttonTexts(panel.view(st, mkCx(120)).main, {})
	ok(util.contains(texts, "刷新版本"), "视图里有自己的刷新")
end)


test("收尾模板：七段齐全、越权禁令、报告七段与降级路径", function()
	local body = templates.render(templates.WRAP_UP, { repo = "me/repo", root = "D:/repo" })
	local phases = {
		"第 1 段 · 盘点现状", "第 2 段 · 审 diff", "第 3 段 · 文档更新",
		"第 4 段 · 清理与收拢", "第 5 段 · 交付", "第 6 段 · 复盘", "第 7 段 · 报告与交接",
	}
	for _, t in ipairs(phases) do
		ok(string.find(body, t, 1, true) ~= nil, "缺阶段：" .. t)
	end
	ok(string.find(body, "出口判定", 1, true) ~= nil, "每段要有出口判定")
	ok(string.find(body, "## 越权禁令", 1, true) ~= nil, "有越权禁令")
	ok(string.find(body, "删除类动作", 1, true) ~= nil, "删除要等点头")
	ok(string.find(body, "单向门", 1, true) ~= nil, "合并是单向门")
	ok(string.find(body, "验收对照", 1, true) ~= nil, "报告要有验收对照")
	ok(string.find(body, "临时目录", 1, true) ~= nil, "交接写临时目录")
	ok(string.find(body, "Markdown 报告", 1, true) ~= nil, "缺装降级路径")
	ok(string.find(body, "回退到开发", 1, true) == nil, "不写没约定的说法")
	ok(string.find(body, "{repo}", 1, true) == nil, "占位符都填了")
	ok(string.find(body, "{root}", 1, true) == nil, "占位符都填了")
end)

test("收尾模板：技能命令前后留空格", function()
	local body = templates.render(templates.WRAP_UP, { repo = "me/repo", root = "D:/repo" })
	for _, cmd in ipairs({
		"/skill:retro", "/skill:code-review", "/skill:forge-router",
		"/skill:pr", "/skill:answer-me-with-html", "/skill:handoff",
	}) do
		local at = string.find(body, cmd, 1, true)
		ok(at ~= nil, "缺技能引用：" .. cmd)
		local before = if at == 1 then "\n" else string.sub(body, at - 1, at - 1)
		local after = string.sub(body, at + #cmd, at + #cmd)
		ok(before == " " or before == "\n", cmd .. " 前面没隔开")
		ok(after == " " or after == "\n", cmd .. " 后面没隔开")
	end
end)

test("收尾：注入套信封，未识别仓库不注入", function()
	local st = nextStepState()
	panel.event(st, { ev = "action", act = "wrap-up" }, mkCx(120))
	local action = kvStore["action"]
	ok(type(action) == "table", "写了注入请求")
	eq(action.kind, "inject")
	ok(string.find(action.body, "===== 注入开始 · tern-matt-panel · 收尾 =====", 1, true) == 1, "信封动作名是收尾")
	ok(string.find(action.body, "me/repo", 1, true) ~= nil, "带仓库")
	ok(string.find(action.body, "===== 注入结束 · 下面是用户输入的内容 =====", 1, true) ~= nil, "以结束行收尾")

	kvStore["action"] = nil
	local none = panel.init(mkCx(120), {}, nil)
	none.repo = nil
	panel.event(none, { ev = "action", act = "wrap-up" }, mkCx(120))
	eq(kvStore["action"], nil, "没仓库不发注入")
	ok(string.find(tostring(none.message), "先识别到仓库", 1, true) ~= nil, "提示先识别仓库")
end)

test("收尾：缺装外部包时仍注入并说明缺口", function()
	local st = nextStepState()
	panel.event(st, { ev = "action", act = "wrap-up" }, mkCx(120))
	ok(kvStore["action"] ~= nil, "缺装也照样注入")
	ok(string.find(tostring(st.message), "未装", 1, true) ~= nil, "提示哪套没装")
end)


test("模板口径：每条都有角色句与第一性原理，技能命令前后留空格", function()
	local bodies: { { name: string, body: string } } = {}
	for _, t in ipairs(templates.TEMPLATES) do
		table.insert(bodies, { name = t.title, body = templates.render(t, { url = "http://x", title = "T" }) })
	end
	for _, t in ipairs({ templates.NEXT_STEP, templates.NEW_BUG, templates.HEALTH_CHECK, templates.WRAP_UP }) do
		table.insert(bodies, { name = t.title, body = templates.render(t, { repo = "me/repo", root = "D:/r" }) })
	end
	eq(#bodies, 8, "票动作四条 + 按钮四条")
	for _, b in ipairs(bodies) do
		ok(string.find(b.body, "从第一性原理出发。", 1, true) ~= nil, b.name .. " 缺第一性原理")
		ok(string.find(b.body, "你是这个仓库的资深工程师", 1, true) ~= nil, b.name .. " 缺角色句")
	end
end)

test("模板口径：三个按钮共用工具段，且引用了选路表", function()
	for _, t in ipairs({ templates.NEXT_STEP, templates.NEW_BUG, templates.HEALTH_CHECK }) do
		local body = templates.render(t, { repo = "me/repo" })
		ok(string.find(body, "/skill:forge-router 的选路表", 1, true) ~= nil, t.title .. " 缺选路表")
		ok(string.find(body, "## 事实核验与工具（先查后问）", 1, true) ~= nil, t.title .. " 缺工具段")
	end
end)

test("收尾模板：顺序是 目标 → 触发语义 → 越权禁令 → 七段 → 反问", function()
	local body = templates.WRAP_UP.body
	local goal = string.find(body, "## 目标", 1, true)
	local trig = string.find(body, "## 触发语义", 1, true)
	local bound = string.find(body, "## 越权禁令", 1, true)
	local seg1 = string.find(body, "## 第 1 段", 1, true)
	local ask = string.find(body, "## 反问", 1, true)
	ok(goal and trig and bound and seg1 and ask, "五段都在")
	ok(goal < trig and trig < bound and bound < seg1 and seg1 < ask, "顺序要串起来")
end)

test("模板口径：小节顺序一致（目标 → 核验 → 边界 → 交付）", function()
	local all = {}
	for _, t in ipairs(templates.TEMPLATES) do
		table.insert(all, t)
	end
	for _, t in ipairs({ templates.NEXT_STEP, templates.NEW_BUG, templates.HEALTH_CHECK }) do
		table.insert(all, t)
	end
	-- 收尾是多阶段模板，四段锚点换成它自己的顺序，见下一条用例。
	for _, t in ipairs(all) do
		local body = t.body
		local goal = string.find(body, "## 目标", 1, true)
		local check = string.find(body, "## 事实核验", 1, true) or string.find(body, "## 事实核验与工具", 1, true)
		ok(goal ~= nil, t.title .. " 缺目标段")
		ok(check ~= nil, t.title .. " 缺核验段")
		ok(goal < check, t.title .. " 目标应在核验前")
		local boundary = string.find(body, "## 边界", 1, true)
		ok(boundary ~= nil, t.title .. " 缺边界段")
		ok(check < boundary, t.title .. " 核验应在边界前")
		local deliver = string.find(body, "## 交付", 1, true)
		ok(deliver ~= nil, t.title .. " 缺交付段")
		ok(boundary < deliver, t.title .. " 边界应在交付前")
	end
end)


test("模板口径：每个占位符都在行内带了说明", function()
	local bodies: { { name: string, body: string } } = {}
	for _, t in ipairs(templates.TEMPLATES) do
		table.insert(bodies, { name = t.title, body = t.body })
	end
	for _, t in ipairs({ templates.NEXT_STEP, templates.NEW_BUG, templates.HEALTH_CHECK, templates.WRAP_UP }) do
		table.insert(bodies, { name = t.title, body = t.body })
	end
	for _, e in ipairs(templates.ENTRIES) do
		table.insert(bodies, { name = e.injectAction, body = e.body })
	end
	for _, b in ipairs(bodies) do
		-- 每个占位符至少要有一行「说明：{占位符}」的独立写法；
		-- 正文里顺带出现（比如 gh issue view {url}）不算说明。
		local keys: { [string]: boolean } = {}
		for key in string.gmatch(b.body, "{(%w+)}") do
			keys[key] = true
		end
		for key in pairs(keys) do
			local labelled = false
			for line in string.gmatch(b.body, "[^\n]+") do
				local trimmed = (string.gsub(line, "%s+$", ""))
				if string.sub(trimmed, -(#key + 2)) == "{" .. key .. "}" and string.find(trimmed, "：", 1, true) then
					labelled = true
				end
			end
			ok(labelled, b.name .. " 的占位符 {" .. key .. "} 没有行内说明")
		end
	end
end)


test("技能包刷新：重新探测不丢上次查到的版本", function()
	installedPacks()
	processFixtures = {
		{ match = "/releases/latest", result = { status = 0, stdout = "v0.6.0\n" } },
	}
	local st = panel.init(mkCx(120), {}, nil)
	panel.event(st, { ev = "action", act = "packs-refresh" }, mkCx(120))
	eq(packsBy(st)["omp-skill-forge"].status, "待更新")
	-- 刷新（reload）会重新探测本地状态；上游结论要留着
	panel.event(st, { ev = "action", act = "reload" }, mkCx(120))
	local p = packsBy(st)["omp-skill-forge"]
	eq(p.latest, "0.6.0", "上游版本还在")
	eq(p.status, "待更新", "状态没退回已装")
end)


--- 收一棵树里的按钮，逐个要求点击挂在 actions.click 上（真机只认这个字段）。
local function buttonClickViolations(node: any, out: { string })
	if type(node) ~= "table" then
		return out
	end
	if node.k == "button" then
		local a = type(node.p) == "table" and node.p.actions or nil
		if type(a) ~= "table" or type(a.click) ~= "string" then
			table.insert(out, tostring(node.p and node.p.t))
		end
	end
	for _, kid in ipairs(node.c or {}) do
		buttonClickViolations(kid, out)
	end
	return out
end

test("所有视图的按钮点击都挂在 actions.click 上", function()
	local views: { string } = { "skills", "board", "map", "ticket", "packs" }
	for _, v in ipairs(views) do
		local st = nextStepState()
		st.view = v
		if v == "map" then
			st.mapSel = 1
		elseif v == "ticket" then
			st.ticket = st.tickets[1]
		end
		local bad = buttonClickViolations(panel.view(st, mkCx(120)).main, {})
		eq(#bad, 0, v .. " 视图里有按钮没挂 actions.click：" .. table.concat(bad, "、"))
	end
end)

test("技能包：登记里没有时回退插件缓存里的同名副本", function()
	-- 不写登记文件，只在缓存目录放一份
	fsDirs["C:/home/.omp/plugins/cache/plugins/answer-me-with-html___answer-me-with-html___0.5.10"] = true
	fsFiles["C:/home/.omp/plugins/cache/plugins/answer-me-with-html___answer-me-with-html___0.5.10/package.json"] = '{"version":"0.5.10"}'
	local st = panel.init(mkCx(120), {}, nil)
	local by = packsBy(st)
	eq(by["answer-me-with-html"].status, "已装")
	eq(by["answer-me-with-html"].version, "0.5.10")
	eq(by["mattpocock"].status, "未装")
end)


test("技能包：检查失败后再刷新仍保留上次查到的上游版本", function()
	installedPacks()
	processFixtures = {
		{ match = "/releases/latest", result = { status = 0, stdout = "v0.6.0\n" } },
	}
	local st = panel.init(mkCx(120), {}, nil)
	panel.event(st, { ev = "action", act = "packs-refresh" }, mkCx(120))
	eq(packsBy(st)["omp-skill-forge"].latest, "0.6.0")
	-- 上游查不到（release 与 tags 都失败）
	st.packsCheckedAt = nil
	processFixtures = {}
	panel.event(st, { ev = "action", act = "packs-refresh" }, mkCx(120))
	local afterFail = packsBy(st)["omp-skill-forge"]
	eq(afterFail.latest, "0.6.0", "失败也保住已查到的版本")
	-- 再点工具条刷新：重新探测不能把版本号清掉
	panel.event(st, { ev = "action", act = "reload" }, mkCx(120))
	eq(packsBy(st)["omp-skill-forge"].latest, "0.6.0", "reload 后还在")
end)

test("技能包：release 查不到时回退 tags", function()
	installedPacks()
	processFixtures = {
		{ match = "/releases/latest", result = { status = 1, stdout = "", stderr = "Not Found" } },
		{ match = "/tags", result = { status = 0, stdout = "v0.7.0\n" } },
	}
	local st = panel.init(mkCx(120), {}, nil)
	panel.event(st, { ev = "action", act = "packs-refresh" }, mkCx(120))
	local p = packsBy(st)["omp-skill-forge"]
	eq(p.latest, "0.7.0", "从 tags 拿到版本")
	eq(p.status, "待更新")
end)

test("技能包刷新结束后给结论，不停在「检查上游版本」", function()
	installedPacks()
	processFixtures = {
		{ match = "/releases/latest", result = { status = 0, stdout = "v0.6.0\n" } },
	}
	local st = panel.init(mkCx(120), {}, nil)
	panel.event(st, { ev = "action", act = "packs-refresh" }, mkCx(120))
	local m = tostring(st.message)
	ok(string.find(m, "已查 3 套", 1, true) ~= nil, "给出结论：" .. m)
	ok(string.find(m, "待更新", 1, true) ~= nil, "带上待更新套数")
end)


test("注入看门狗：窗口半边没回执时给出排障提示", function()
	local st = nextStepState()
	panel.event(st, { ev = "action", act = "wrap-up" }, mkCx(120))
	eq(st.pendingSeq ~= nil, true, "先进入填入中")
	local seq = st.pendingSeq
	-- 找出看门狗挂的那个 4 秒定时器并放行
	local fired = false
	for _, t in ipairs(timers) do
		if t.ms == 4000 then
			t.fn(nil)
			fired = true
		end
	end
	ok(fired, "挂了看门狗定时器")
	eq(st.pendingSeq, nil, "清掉待回执")
	ok(string.find(tostring(st.message), "窗口半边没响应", 1, true) ~= nil, "提示是排障话术")
	ok(string.find(tostring(st.message), "tern plugin reload", 1, true) ~= nil, "给出具体动作")
	eq(seq ~= nil, true)
end)

test("注入看门狗：回执先到就不再报错", function()
	local st = nextStepState()
	panel.event(st, { ev = "action", act = "wrap-up" }, mkCx(120))
	local seq = st.pendingSeq
	-- 窗口半边回写成功结果，宿主读一次
	kvStore["inject_result"] = { seq = seq, ok = true, name = "收尾" }
	panel.event(st, { ev = "action", act = "refresh" }, mkCx(120))
	eq(st.pendingSeq, nil, "回执到达后不再等待")
	for _, t in ipairs(timers) do
		if t.ms == 4000 then
			t.fn(nil)
		end
	end
	ok(string.find(tostring(st.message), "已填入", 1, true) ~= nil, "提示保持已填入")
	ok(string.find(tostring(st.message), "没响应", 1, true) == nil, "不误报")
end)

-- -------------------------------------------------------------- report ----

print(string.format("passed=%d failed=%d", passed, failed))
if failed > 0 then
	for _, f in ipairs(failures) do
		print("FAIL: " .. f)
	end
	error("tests failed")
end