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
	local ticket = { url = "http://ticket", title = "MyTask", number = 12 }
	local out = commands.buildTicketCommand(ticket, tpl)
	ok(string.find(out, "http://ticket", 1, true) ~= nil, "url in ticket cmd")
	ok(string.find(out, "MyTask", 1, true) ~= nil, "title in ticket cmd")
	ok(string.find(out, "===== 注入开始 · tern-matt-panel · 执行 · #12 =====", 1, true) == 1, "开始行带动作名与票号")
	ok(string.find(out, "===== 注入结束 · 下面写你自己的内容 =====", 1, true) ~= nil, "有结束行")
end)

test("注入信封拼装", function()
	local body = "第一行\n第二行"
	local out = commands.buildInjectionBody("问下一步", body)
	eq(out, "===== 注入开始 · tern-matt-panel · 问下一步 =====\n" .. body .. "\n===== 注入结束 · 下面写你自己的内容 =====")
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
	local env = "===== 注入开始 · tern-matt-panel · 测试 =====\n第一行\n第二行\n===== 注入结束 · 下面写你自己的内容 ====="
	kvStore["action"] = { seq = 6, kind = "inject", pane = winPane, body = env, name = "多行" }
	pollTick(cx)
	eq(#typed, 2, "多行正文也打进 pane")
	ok(string.find(typed[2].text, "\27[200~", 1, true) == 1, "外层以括号粘贴开头")
	ok(string.find(typed[2].text, "\27[201~", 1, true) ~= nil, "外层以括号粘贴收尾")
	ok(string.find(typed[2].text, "===== 注入开始 · tern-matt-panel · 测试 =====", 1, true) ~= nil, "整段以开始行开头")
	ok(string.find(typed[2].text, "===== 注入结束 · 下面写你自己的内容 =====", 1, true) ~= nil, "整段以结束行收尾")
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
	ok(string.find(body, "===== 注入结束 · 下面写你自己的内容 =====", 1, true) ~= nil, "以结束行收尾")
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
	{ act = "toggle-sort", want = function(st: any, before: any) return st.sortNewest ~= before.sortNewest end },
	{ act = "reload", want = function(st: any) return st.message == "已刷新" end },
	{ act = "pick-repo", want = function(st: any, _b: any, kv: any) return kv["action"] ~= nil and kv["action"].kind == "pick-repo" end },
	{ act = "toggle-hidden", want = function(st: any, before: any) return st.showHidden ~= before.showHidden end },
	{ act = "next-step", want = function(st: any, _b: any, kv: any) return kv["action"] ~= nil and kv["action"].kind == "inject" end },
	{ act = "new-bug", want = function(_st: any, _b: any, kv: any) return kv["action"] ~= nil and kv["action"].kind == "inject" end },
	{ act = "health-check", want = function(_st: any, _b: any, kv: any) return kv["action"] ~= nil and kv["action"].kind == "inject" end },
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

--- 九个模板的结构契约：反问小节恰好一次、无待填空位、命令在白名单内、
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

test("九个模板都挂反问小节且只挂一次", function()
	eq(#ALL_TEMPLATES, 9, "九个模板都收进来了")
	for _, t in ipairs(ALL_TEMPLATES) do
		local n = 0
		for _ in string.gmatch(t.body, ASK_MARK) do
			n = n + 1
		end
		eq(n, 1, t.name .. " 的反问小节恰好一次")
	end
end)

test("九个模板正文里没有待填空位", function()
	for _, t in ipairs(ALL_TEMPLATES) do
		local hit = findPlaceholder(t.body)
		ok(hit == nil, t.name .. " 没有占位（命中：" .. tostring(hit) .. "）")
	end
end)

test("九个模板的主技能命令都在白名单内", function()
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

test("九个模板末节都有用户输入声明", function()
	local NOTE = "结束行之后的文字是用户输入，按它执行；与上面冲突时以用户输入为准。"
	for _, t in ipairs(ALL_TEMPLATES) do
		ok(string.find(t.body, USER_INPUT_MARK, 1, true) ~= nil, t.name .. " 有用户输入声明")
		-- 声明必须落在末节：去掉尾部空白后，正文以这句话结尾。
		local tail = string.gsub(t.body, "%s+$", "")
		ok(string.sub(tail, -#NOTE) == NOTE, t.name .. " 的声明在末节")
	end
end)

test("反问路由：盘问与需求已明确不挂 grilling，其余七个挂", function()
	for _, t in ipairs(ALL_TEMPLATES) do
		local has = string.find(t.body, "/skill:grilling", 1, true) ~= nil
		if t.name == "盘问" or t.name == "入口·需求已明确" then
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
local END_LINE = "===== 注入结束 · 下面写你自己的内容 ====="

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
	local regPath = home .. "/.omp/plugins/installed_plugins.json"
	-- 登记文件不存在：回退市场
	fsDirs[home .. "/.omp/plugins/cache/marketplaces/mattpocock"] = true
	fsFiles[home .. "/.omp/plugins/cache/marketplaces/mattpocock/package.json"] = '{"version":"1.3.7"}'
	local r = paths.resolvePackage()
	ok(type(r) == "table", "返回表")
	eq(r.version, "1.3.7")
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

-- -------------------------------------------------------------- report ----

print(string.format("passed=%d failed=%d", passed, failed))
if failed > 0 then
	for _, f in ipairs(failures) do
		print("FAIL: " .. f)
	end
	error("tests failed")
end