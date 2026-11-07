--!strict
-- 宿主半边：面板的画面（tern.ui 节点树）与数据获取。
--
-- 数据获取放在这一侧：`gh` 子进程与文件读取在宿主半边都能做（实测见
-- docs/research/host-half-runtime.md）。异步回调里改 state 再 cx:render() 即可重画，
-- 不必绕 kv（见 docs/research/host-async-render.md）。
--
-- 需要窗口半边才能做的只有一件：把提示词注入邻近 agent（cx.agents:ask 是 window-only）。
-- 那一段走 tern.kv 传令：这里写 action 键，窗口半边轮询并执行。

local ui = tern.ui
local commands = require("./lib/commands")
local lanes = require("./lib/lanes")
local paths = require("./lib/paths")
local skills = require("./lib/skills")
local templates = require("./lib/templates")
local tracker = require("./lib/tracker")
local util = require("./lib/util")

--- 拿当前秒数。宿主沙箱没在类型里暴露 os，用 pcall 兜住：
--- 拿不到就退化成「没有冷却」，宁可多打一次也不崩。
local function nowSec(): number?
	local ok, v = pcall(function()
		return os.time()
	end)
	if ok and type(v) == "number" then
		return v
	end
	return nil
end

--- 拉取失败后安静一会儿。限流期间连点刷新只会让恢复更慢。
local COOLDOWN_SEC = 60

--- 自动刷新的最短间隔：窗口获得焦点时才考虑拉，且两次拉取之间至少隔这么久。
--- 焦点事件很频繁（切 pane 就触发），真正省配额的是这道闸。
local AUTO_REFRESH_SEC = 60

local ACTION_KEY = "action"
local RESULT_KEY = "result"
-- 注入结果单独一个键：RESULT_KEY 已经被前沿/版本摘要占着，不能互相覆盖。
local INJECT_RESULT_KEY = "inject_result"
local REPO_KEY = "repo"
local SEQ_KEY = "seq"
-- 窗口半边要知道往哪个 pane 戳「可以刷了吗」：宿主开块时把自己的 pane 记在这里。
local PANEL_KEY = "panel"
local BLOCK_ID = "matt"

type View = "skills" | "board" | "map" | "ticket"

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
	-- 票按创建时间排：默认最新在上
	sortNewest: boolean,
	-- 票详情
	ticket: tracker.Ticket?,
	ticketBody: string?,
	-- 正在用 REST 拉某张票的正文；view 里发请求必须靠它防重入
	bodyLoading: number?,
	-- 上次拉取失败后到这个时刻之前不再发请求
	cooldownUntil: number?,
	-- 上次真正发出拉取的时刻；自动刷新按它节流
	lastLoadAt: number?,
	-- 通用
	message: string?,
	pendingSeq: number?,
	loading: boolean,
	repo: string?,
	-- git 的仓库根（cwd 可能只是仓库里的一层，也可能不在仓库里）
	root: string?,
	-- 仓库是目录自动识别来的，还是退到上次手动指定的
	repoManual: boolean,
	-- 没识别到仓库时给用户的下一步说明（含失败原因）
	setupHint: string?,
	skillVersion: string?,
	hasSkills: boolean,
}

--- 空状态。init 与 save 恢复共用。
local function blank(): State
	return {
		view = "skills",
		sortNewest = true,
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
		bodyLoading = nil,
		cooldownUntil = nil,
		lastLoadAt = nil,
		message = nil,
		pendingSeq = nil,
		loading = false,
		repo = nil,
		root = nil,
		repoManual = false,
		setupHint = nil,
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

--- 拉取成功的 issue 缓存。拉取失败（多半是 GitHub 限流）时退到这里，
--- 免得面板变成空白 —— 用户刚才还看得到数据。
local ISSUES_CACHE_KEY = "issues_cache"

--- 用缓存里的 issue 填充 state。缓存不属于当前仓库时返回 false。
local function applyCachedIssues(state: State, repo: string): boolean
	local ok, value = pcall(tern.kv.get, ISSUES_CACHE_KEY)
	if not ok or type(value) ~= "table" then
		return false
	end
	if value.repo ~= repo or type(value.issues) ~= "table" then
		return false
	end
	state.tickets = tracker.parseIssues(value.issues)
	state.maps = tracker.groupByMap(value.issues)
	return true
end

--- 真正拉 issue 的那一步。
local fetchIssues: (State, BlockCx, string) -> ()

--- 从 git remote 推断 owner/repo。
--- 失败时把原因带回去：只回 nil，用户看到的永远是「没识别到」，不知道卡在哪。
local function inferRepo(cx: BlockCx, cb: (string?, string?) -> ())
	local cwd = cx.cwd
	if not cwd or cwd == "" then
		cb(nil, "宿主没给工作目录")
		return
	end
	tern.process.run({ "git", "-C", cwd, "remote", "get-url", "origin" }):next(function(result: any, _err: any, _cx: any)
		if result == nil then
			cb(nil, "git 没跑起来（命令本身失败）")
			return
		end
		if result.status ~= 0 then
			local err = tostring(result.stderr or "")
			err = (err:gsub("%s+$", ""))
			cb(nil, string.format("git 退出 %s：%s", tostring(result.status), err:sub(1, 90)))
			return
		end
		local url = tostring(result.stdout or "")
		local repo = util.parseRemoteUrl(url)
		if not repo then
			cb(nil, "这条 remote 解析不出 owner/repo：" .. url:sub(1, 60))
			return
		end
		cb(repo, nil)
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
	local now = nowSec()
	if now and state.cooldownUntil and now < state.cooldownUntil then
		state.message = string.format("上次拉取失败，%d 秒后再试", state.cooldownUntil - now)
		cx:render()
		return
	end
	-- 记下发出时刻：自动刷新用它节流。放在所有早退之前，
	-- 否则「识别不到仓库」这种稳态会让节流永远不生效。
	state.lastLoadAt = nowSec()
	state.loading = true
	-- 目录优先：面板跟着窗口所在项目走。
	-- kv 里的仓库跨窗口共享，优先用它会让每个新窗口都指向另一个项目的老仓库 ——
	-- 用户在新项目开面板看到的却是上一个项目的票。
	inferRepo(cx, function(found: string?, reason: string?)
		local repo = found
		local manual = false
		if not repo then
			-- 只认「本窗口手动指定」的那一份。
			-- 跨窗口共用的旧值会让新项目显示上一个项目的仓库 —— 那正是用户看到的怪象。
			local ok, value = pcall(tern.kv.get, REPO_KEY)
			if ok and type(value) == "table" and value.pane == cx.pane
				and type(value.repo) == "string" and value.repo ~= "" then
				repo = value.repo
				manual = true
			end
		end
		if not repo then
			state.loading = false
			state.repo = nil
			-- 没识别到就清空，别把别的仓库的票挂在这个项目下面。
			state.tickets = {}
			state.maps = {}
			state.ticket = nil
			state.ticketBody = nil
			state.mapSel = nil
			state.ticketSel = nil
			state.setupHint = reason or "当前目录没识别到 git remote"
			state.message = nil
			cx:render()
			return
		end
		state.setupHint = nil
		if state.repo ~= repo then
			-- 换了仓库就把上一个仓库的数据清掉，别让旧票挂在新仓库名下。
			state.tickets = {}
			state.maps = {}
			state.ticket = nil
			state.ticketBody = nil
			state.mapSel = nil
			state.ticketSel = nil
		end
		state.repo = repo
		state.repoManual = manual
		fetchIssues(state, cx, repo)
		-- 面板所在目录可能只是仓库里的一层：提示词里指文档路径要用真正的根。
		tern.process.run({ "git", "-C", cwd, "rev-parse", "--show-toplevel" }):next(function(result: any)
			if result and result.status == 0 then
				local root = util.trim(tostring(result.stdout or ""))
				if root ~= "" then
					state.root = root
				end
			end
		end)
	end)
end

--- 真正拉 issue 的那一步。
fetchIssues = function(state: State, cx: BlockCx, repo: string)
	-- 刻意不拉 body：列表一次 400 点，5000 点/小时只够刷十来次。
	-- body 是成本大头，改成点开某张票时用 REST 单独取（REST 不占 GraphQL 配额）。
	local fields = "number,title,state,url,labels,assignees,parent,blockedBy,createdAt"
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
			local now2 = nowSec()
			if now2 then
				state.cooldownUntil = now2 + COOLDOWN_SEC
			end
			state.message = "gh 拉取失败：" .. tostring(if result then result.stderr else "无输出")
			-- 拉取失败不该把用户已经看到的数据清空 —— 退到上次成功的缓存。
			-- 常见触发是 GitHub 限流，缓存让面板继续可用。
			if applyCachedIssues(state, repo) then
				state.message = state.message .. "（显示上次拉到的数据）"
			end
			cx:render()
			return
		end
		local issues = decodeIssues(tostring(result.stdout or ""))
		if not issues then
			state.loading = false
			state.message = "gh 输出解析失败"
			if applyCachedIssues(state, repo) then
				state.message = state.message .. "（显示上次拉到的数据）"
			end
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
			-- 与任务板「可领」同口径：都要排除顶层 spec，
			-- 否则面板写 4 张、状态栏写 5 张，用户以为哪里算错了。
			frontier = #tracker.classify(state.tickets).claimable,
			version = state.skillVersion or "—",
		})
		-- 存一份缓存：拉取失败时（多半是限流）退到这里，别让面板变空白。
		pcall(tern.kv.set, ISSUES_CACHE_KEY, { repo = repo, issues = issues })
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

local function sendAction(state: State, cx: BlockCx, kind: string, body: string, name: string): number
	local seq = nextSeq()
	tern.kv.set(ACTION_KEY, {
		seq = seq,
		kind = kind,
		pane = cx.pane,
		body = body,
		name = name,
	})
	return seq
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
---
--- 宿主不能自己下"成功"的结论：注入可能失败（没 agent、agent 忙、投递出错）。
--- 所以这里只标"提交中"，等窗口半边把结果写回 RESULT_KEY 再改口。
local function inject(state: State, cx: BlockCx, body: string, name: string)
	local seq = sendAction(state, cx, "inject", body, name)
	state.pendingSeq = seq
	state.message = "提交中：" .. name
end

--- 「问下一步」的注入正文：把任务板快照摊成模板占位符。
--- 面板不做判断，判断留给会话里的 /skill:ask-matt；这里只保证事实够它判断。
local function nextStepBody(state: State, cx: BlockCx): string
	local b = tracker.classify(state.tickets)
	local maps: { { number: number, title: string } } = {}
	for _, m in ipairs(state.maps) do
		table.insert(maps, { number = m.number, title = m.title })
	end
	-- 反向依赖要跨整板算，所以要全量未关闭的票，不只是某一桶。
	local open: { tracker.Ticket } = {}
	for _, t in ipairs(state.tickets) do
		if t.state == "OPEN" then
			table.insert(open, t)
		end
	end
	local specs: { any } = {}
	for _, entry in ipairs(tracker.groupBySpec(state.tickets)) do
		local unfinished = 0
		for _, kid in ipairs(entry.tickets) do
			if kid.state == "OPEN" then
				unfinished += 1
			end
		end
		table.insert(specs, {
			number = entry.spec.number,
			title = entry.spec.title,
			open = unfinished,
			total = #entry.tickets,
		})
	end
	local extra: templates.NextStepExtra = {
		root = state.root or (if cx.cwd and cx.cwd ~= "" then cx.cwd else nil),
		rootIsRepo = state.root ~= nil,
		all = open :: any,
		specs = specs,
	}
	return templates.render(templates.NEXT_STEP, templates.nextStepVars(state.repo :: string, b :: any, maps, extra))
end

--- 读窗口半边写回的结果，更新提示。
--- 结果里的 seq 与请求的 seq 对得上才算这次请求的结论。
local function readResult(state: State)
	local ok, value = pcall(tern.kv.get, INJECT_RESULT_KEY)
	if not ok or type(value) ~= "table" then
		return
	end
	local seq = value.seq
	if type(seq) ~= "number" or seq ~= state.pendingSeq then
		return
	end
	state.pendingSeq = nil
	local ok2 = value.ok == true
	state.message = if ok2
		then "已提交：" .. tostring(value.name or "")
		else "提交失败：" .. tostring(value.name or "") .. " —— " .. tostring(value.error or "")
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
local MAP_TICKET_LIST = "maptickets"
local TICKET_LIST = "tickets"
local SPEC_LIST = "specs"

--- 把一组票做成可点列表：每行给 key（= 票号），选中态跟着 ticketSel 走。
--- 票类型 → 图标。tern 的图标集里没有 `ticket`，只能用现有名字；
--- wayfinder 的四类票各给一个形近的图标，好让行首能一眼分出类型。
local TYPE_ICON: { [string]: string } = {
	grilling = "message",
	prototype = "wrench",
	research = "search",
	task = "check",
}

local function makeList(items: { any }, tickets: { tracker.Ticket }, key: string, selected: number?, hint: string): Node
	local list = ui.list(items)
	local kids = list.c or {}
	for i, t in ipairs(tickets) do
		local p: { [string]: any } = kids[i].p or {}
		p.key = tostring(t.number)
		kids[i].p = p
	end
	local lp: { [string]: any } = list.p or {}
	lp.key = key
	lp.selected = if selected then tostring(selected) else nil
	lp.empty = { ui.span(hint, "muted") }
	list.p = lp
	return list
end

--- 技能区：每个泳道一张可折叠卡片，卡片里是该泳道的技能列表。
--- 之前是一个扁平列表、泳道名塞在行尾小字里 —— 扫一眼分不出组，
--- 于是把泳道真正做成分组。
local function skillsView(state: State, cx: BlockCx): Node
	local main: { Node } = {}

	if not state.hasSkills then
		table.insert(main, ui.text(ui.span("没找到中文技能包", "warning")))
		table.insert(main, ui.text(ui.link(
			"安装：https://github.com/devcxl/mattpocock-skills-zh",
			"https://github.com/devcxl/mattpocock-skills-zh"
		)))
		-- 给可复制的命令：光有链接用户还得自己拼命令
		table.insert(main, ui.code("git clone https://github.com/devcxl/mattpocock-skills-zh", "bash"))
		table.insert(main, ui.text(ui.span(
			"装到 omp 插件缓存的 marketplaces 目录下（或用 omp marketplace 安装）。面板不自带技能，也不代装。装好后点「刷新」。",
			"muted"
		)))
		return ui.col(main)
	end

	table.insert(main, ui.text({
		ui.span("技能", "strong"),
		ui.span(string.format("  %s · %d 个", state.skillVersion or "未知版本", #flatSkills(state)), "muted"),
	}))

	local rows = math.max(4, math.floor((cx.rows - 6) / 2))
	local byName: { [string]: skills.Skill } = {}
	for _, s in ipairs(state.skills) do
		byName[s.name] = s
	end
	for i, lane in ipairs(state.lanes) do
		-- 空泳道不画，免得面板全是空标题。
		if #lane.skills == 0 then
			continue
		end
		local items: { any } = {}
		for _, name in ipairs(lane.skills) do
			local s = byName[name]
			if s then
				table.insert(items, {
					label = s.name,
					value = "/skill:" .. s.name,
					icon = "sparkle",
					tone = if s.name == state.skillSel then "accent" else nil,
				})
			end
		end
		local list = ui.list(items)
		local kids = list.c or {}
		local n = 0
		for _, name in ipairs(lane.skills) do
			if byName[name] then
				n += 1
				local p: { [string]: any } = kids[n].p or {}
				p.key = name
				kids[n].p = p
			end
		end
		local lp: { [string]: any } = list.p or {}
		lp.key = SKILL_LIST .. "_" .. tostring(i)
		lp.selected = state.skillSel
		lp.empty = { ui.span("空", "muted") }
		lp.max = { lines = rows }
		list.p = lp
		table.insert(main, ui.card(ui.span(lane.title, "strong"), {
			ui.text(ui.span(lane.hint, "muted")),
			list,
		}, {
			icon = "sparkle",
			meta = ui.span(string.format("%d 个", n), "muted"),
		}))
	end

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
			ui.span(state.repo, "strong"),
			ui.span(if state.repoManual
				then "  手动指定 · 当前目录没识别到 git remote"
				else "  来自当前目录的 git remote", "muted"),
		}))
	end
	-- 没识别到仓库：说清卡在哪，并给下一步。别把别的仓库的票画在这。
	if state.setupHint then
		table.insert(main, ui.text(ui.span("没识别到仓库", "warning")))
		table.insert(main, ui.text({
			ui.span("原因：", "muted"),
			ui.span(state.setupHint, "muted"),
		}))
		table.insert(main, ui.text(ui.span(
			"面板按当前目录的 git remote 认仓库。目录要有 .git、且配了 origin。", "muted"
		)))
		table.insert(main, ui.row({
			ui.button("手动指定 owner/repo", {
				icon = "repo",
				size = "sm",
				variant = "primary",
				actions = { click = "pick-repo" },
			}),
		}))
	end

	-- 空仓库给两条路，别只甩一条。
	-- 只写「跑 /wayfinder」会误导需求已经明确的人：他不需要画地图，
	-- 直接 grill 需求再 to-spec / to-tickets 更快。
	if #state.tickets == 0 and state.repo then
		table.insert(main, ui.text(ui.span("这个仓库还没有 issue —— 先选一条路", "strong")))
		local entries: { Node } = {}
		for _, e in ipairs(templates.ENTRIES) do
			table.insert(entries, ui.button(e.title, {
				icon = if e.id == "explore" then "map" else "message",
				size = "sm",
				variant = "primary",
				actions = { click = "new:" .. e.id },
			}))
		end
		table.insert(main, ui.row(entries))
		for _, e in ipairs(templates.ENTRIES) do
			table.insert(main, ui.text({
				ui.span("· " .. e.title .. "：", "muted"),
				ui.span(e.hint, "muted"),
			}))
		end
	end

	-- 地图
	local mapItems: { any } = {}
	for _, m in ipairs(state.maps) do
		table.insert(mapItems, {
			label = m.title,
			detail = string.format("%d 张子票", #m.tickets),
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
	mapLp.empty = { ui.span("没有 wayfinder:map 地图 · 跑 /wayfinder 建一张", "muted") }
	mapLp.max = { lines = math.max(4, math.floor((cx.rows - 12) / 2)) }
	mapList.p = mapLp
	-- 和 Spec、四组票一样做成可折叠卡片：一张地图占一块地方，
	-- 项目里有好几张地图时纯列表会把下面的票挤出屏幕。
	table.insert(main, ui.card(ui.text({
		ui.span("地图", "strong"),
		ui.span("  wayfinder:map · 子票挂在它名下", "muted"),
	}), { mapList }, {
		icon = "map",
		meta = ui.span(string.format("%d 张", #state.maps), "muted"),
		collapsible = true,
	}))

	-- Spec：to-spec 的产物是打了 ready-for-agent 标签的 issue，工单是它的子 issue。
	local specs = tracker.groupBySpec(state.tickets)
	if #specs > 0 then
		local specItems: { any } = {}
		for _, entry in ipairs(specs) do
			-- 工单数要能读出完成度：只报总数，用户分不清「还剩几张」。
			local total = #entry.tickets
			local openCount = 0
			for _, kid in ipairs(entry.tickets) do
				if kid.state == "OPEN" then
					openCount += 1
				end
			end
			local detail: string
			local icon = "file"
			if total == 0 then
				detail = "未拆工单"
			elseif openCount == 0 then
				detail = string.format("%d 工单 · 已完成", total)
				icon = "check"
			else
				detail = string.format("%d 工单 · %d 未完成", total, openCount)
			end
			table.insert(specItems, {
				label = entry.spec.title,
				detail = detail,
				icon = icon,
				tone = if entry.spec.number == state.ticketSel then "accent" else nil,
			})
		end
		-- specs 是 {spec, tickets} 组；列表只认 Ticket，传错会得到 key "nil" 的哑行。
		local specTickets: { tracker.Ticket } = {}
		for _, entry in ipairs(specs) do
			table.insert(specTickets, entry.spec)
		end
		local specList = makeList(specItems, specTickets, SPEC_LIST, state.ticketSel, "没有 spec")
		specList.p.max = { lines = math.max(3, math.floor((cx.rows - 16) / 3)) }
		table.insert(main, ui.card(ui.span("Spec", "strong"), { specList }, {
			icon = "file",
			meta = ui.span(string.format("%d 份", #specs), "muted"),
		}))
	end

	-- 票：按「现在能不能干」分四组。只显示前沿会把已认领 / 被阻塞 / 已关闭的票
	-- 全藏起来，用户看到的任务板就成了空板。
	local buckets = tracker.classify(state.tickets)
	-- 每组给不同的图标与色调：四张卡长得一样，扫一眼分不出哪组能干活。
	local groups = {
		{ title = "可领", items = buckets.claimable, key = TICKET_LIST .. "_claimable",
			hint = "没有可领的票", icon = "check", tone = "accent" },
		{ title = "已认领", items = buckets.assigned, key = TICKET_LIST .. "_assigned",
			hint = "没有人认领", icon = "pr", tone = nil },
		{ title = "被阻塞", items = buckets.blocked, key = TICKET_LIST .. "_blocked",
			hint = "没有阻塞的票", icon = "help", tone = "warning" },
		{ title = "已关闭", items = buckets.closed, key = TICKET_LIST .. "_closed",
			hint = "没有关闭的票", icon = "file", tone = "muted" },
	}
	for _, g in ipairs(groups) do
		-- 空组也要画：卡片标题上的「0 张」本身就是信息，
		-- 少画一张卡用户就以为那一组不存在。
		g.items = tracker.sortByCreated(g.items, state.sortNewest)
		local items: { any } = {}
		for _, t in ipairs(g.items) do
			local who = if #t.assignees > 0 then "@" .. t.assignees[1] else nil
			local parts: { string } = {}
			-- 归属：这张票是从哪拆出来的。没有它，四组里的票像凭空冒出来的。
			if t.parent then
				table.insert(parts, "#" .. tostring(t.parent))
			end
			if #t.blockedBy > 0 then
				local nums: { string } = {}
				for _, n in ipairs(t.blockedBy) do
					table.insert(nums, "#" .. tostring(n))
				end
				table.insert(parts, "等 " .. table.concat(nums, ","))
			end
			if t.type then
				table.insert(parts, t.type)
			end
			if who then
				table.insert(parts, who)
			end
			-- 类型用行首图标表达，和标题分开；已关闭的票整行压暗。
			local tone = if t.number == state.ticketSel then
				"accent"
			elseif g.title == "已关闭" then
				"muted"
			else
				nil
			table.insert(items, {
				label = t.title,
				detail = table.concat(parts, " · "),
				icon = TYPE_ICON[t.type] or "check",
				tone = tone,
			})
		end
		local list = makeList(items, g.items, g.key, state.ticketSel, g.hint)
		list.p.max = { lines = math.max(3, math.floor((cx.rows - 16) / 3)) }
		local props: { [string]: any } = {
			icon = g.icon,
			collapsible = true,
		}
		-- card 的 head 只吃单个 span：传 ui.text({...}) 整行标题不渲染。
		-- 组合样式（"strong accent"）和 props.meta 的 tone 也都不生效，
		-- 所以颜色只能整行给一种。
		local head = ui.span(
			g.title .. string.format("  %d 张", #g.items),
			if g.tone then g.tone else "strong"
		)
		-- 空组和已关闭组默认收起，别把界面撑满；有活的组展开。
		if #g.items == 0 or g.title == "已关闭" then
			props.collapsed = true
		end
		table.insert(main, ui.card(head, { list }, props))
	end

	return ui.col(main)
end

--- 任务板里当前选中的地图。
local function selectedMap(state: State): tracker.Map?
	for _, m in ipairs(state.maps) do
		if m.number == state.mapSel then
			return m
		end
	end
	return state.maps[1]
end

--- 地图详情区：地图的子票、迷雾、范围外。
--- 点地图行进来；地图自己的票按类型分组，前沿票单独标出来。
local function mapView(state: State, cx: BlockCx): Node
	local m = selectedMap(state)
	if not m then
		return ui.text(ui.span("从任务板点一张地图", "muted"))
	end
	local main: { Node } = {}
	table.insert(main, ui.text({
		ui.span(m.title, "strong"),
		ui.span(string.format("  #%d · %d 张子票", m.number, #m.tickets), "muted"),
	}))
	table.insert(main, ui.text(ui.link(m.url, m.url, "muted")))

	-- 地图级前沿：该地图里未关闭、未阻塞、未认领的票
	local mapFrontier: { tracker.Ticket } = {}
	for _, t in ipairs(m.tickets) do
		if tracker.computeFrontier({ t })[1] ~= nil then
			table.insert(mapFrontier, t)
		end
	end

	-- 子票列表：一行要能读出「什么类型、卡在谁那里、还开没开」。
	-- 原来 icon 写的是 ticket（tern 图标集没有这个名字，等于没画），
	-- detail 只有 research / 被阻塞 两种，看不出阻塞源也看不出已关闭。
	local items: { any } = {}
	for _, t in ipairs(m.tickets) do
		local parts: { string } = {}
		if #t.blockedBy > 0 then
			local nums: { string } = {}
			for _, n in ipairs(t.blockedBy) do
				table.insert(nums, "#" .. tostring(n))
			end
			table.insert(parts, "等 " .. table.concat(nums, ","))
		end
		if t.type then
			table.insert(parts, t.type)
		end
		if t.state ~= "OPEN" then
			table.insert(parts, "已关闭")
		end
		local tone = if t.number == state.ticketSel then
			"accent"
		elseif t.state ~= "OPEN" then
			"muted"
		else
			nil
		table.insert(items, {
			label = t.title,
			detail = table.concat(parts, " · "),
			icon = TYPE_ICON[t.type] or "check",
			tone = tone,
		})
	end
	local list = ui.list(items)
	local kids = list.c or {}
	for i, t in ipairs(m.tickets) do
		local p: { [string]: any } = kids[i].p or {}
		p.key = tostring(t.number)
		kids[i].p = p
	end
	local lp: { [string]: any } = list.p or {}
	lp.key = MAP_TICKET_LIST
	lp.selected = if state.ticketSel then tostring(state.ticketSel) else nil
	lp.empty = { ui.span("这张地图还没有票", "muted") }
	lp.max = { lines = math.max(4, cx.rows - 14) }
	list.p = lp

	table.insert(main, ui.text(ui.span(string.format("子票（%d）", #m.tickets), "strong")))
	table.insert(main, list)

	if #mapFrontier > 0 then
		table.insert(main, ui.text(ui.span(string.format("前沿（%d）", #mapFrontier), "strong")))
		for _, t in ipairs(mapFrontier) do
			table.insert(main, ui.text(ui.span("· " .. t.title, "accent")))
		end
	end

	-- 迷雾与范围外：地图正文里 wayfinder 的两节，只呈现不解析
	if m.fog and m.fog ~= "" then
		table.insert(main, ui.rule(ui.span("尚未明确（迷雾）")))
		table.insert(main, ui.md(m.fog))
	end
	if m.outOfScope and m.outOfScope ~= "" then
		table.insert(main, ui.rule(ui.span("范围外")))
		table.insert(main, ui.md(m.outOfScope))
	end

	local buttons: { Node } = {
		ui.button("返回任务板", {
			icon = "back",
			size = "sm",
			actions = { click = "back-board" },
		}),
	}
	table.insert(main, ui.row(buttons))

	return ui.col(main)
end

--- 用 REST 取一张票的正文。REST 走 core 配额，不占 GraphQL，单张票成本可以忽略。
local function loadTicketBody(state: State, cx: BlockCx, t: tracker.Ticket)
	local repo = state.repo
	if not repo then
		state.bodyLoading = nil
		return
	end
	tern.process.run({
		"gh", "api",
		string.format("repos/%s/issues/%d", repo, t.number),
		"--jq", ".body",
	}):next(function(result: any, _err: any, _cx: any)
		state.bodyLoading = nil
		if result ~= nil and result.status == 0 then
			state.ticketBody = tostring(result.stdout or "")
		else
			state.ticketBody = ""
			state.message = "取票正文失败：" .. tostring(if result then result.stderr else "无输出")
		end
		cx:render()
	end)
end

--- 票详情区：描述、动作按钮、阻塞关系。
local function ticketView(state: State, cx: BlockCx): Node
	local t = state.ticket
	if not t then
		return ui.text(ui.span("从任务板点一张票", "muted"))
	end
	local main: { Node } = {}
	-- 没打 wayfinder:* 标签的票（比如 spec）没有类型，别硬写「无类型」占位。
	local head: { any } = { ui.span(t.title, "strong") }
	if t.type then
		table.insert(head, ui.span("  " .. t.type, "muted"))
	end
	table.insert(main, ui.text(head))
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

	if t.parent then
		table.insert(main, ui.text(ui.span(string.format("所属：#%d", t.parent), "muted")))
	end
	if #t.blockedBy > 0 then
		local nums: { string } = {}
		for _, n in ipairs(t.blockedBy) do
			table.insert(nums, "#" .. tostring(n))
		end
		table.insert(main, ui.text(ui.span("等这些先完成：" .. table.concat(nums, "、"), "warning")))
	end

	-- 正文不在列表查询里（那是 GraphQL 成本的大头），点开这张票才用 REST 取。
	local body = state.ticketBody
	if body == nil then
		if state.bodyLoading ~= t.number then
			state.bodyLoading = t.number
			loadTicketBody(state, cx, t)
		end
		table.insert(main, ui.text(ui.span("正在取正文…", "muted")))
	elseif body ~= "" then
		table.insert(main, ui.rule(ui.span("描述")))
		table.insert(main, ui.md(body))
	else
		table.insert(main, ui.text(ui.span("这张票没有正文", "muted")))
	end

	return ui.col(main)
end

--- 工具条按钮的排版预算：图标 2 列 + 图标与文字间 1 列 + 左右内边距 2 列。
--- 只用于决定换行，宁可估宽一点。
local BUTTON_CHROME = 5
local BUTTON_GAP = 1

type ToolButton = {
	label: string,
	icon: string,
	variant: string?,
	key: string?,
	click: string,
}

--- 顶部工具条：鼠标能点的视图切换与常用操作。
--- 面板宽度不一，按钮装不进一行就换行 —— 任何宽度下都不许把按钮裁掉。
local function toolbar(state: State, cx: BlockCx): Node
	local buttons: { ToolButton } = {
		{ label = "技能", icon = "sparkle", click = "view-skills",
			variant = if state.view == "skills" then "primary" else "default" },
		{ label = "任务板", icon = "map", click = "view-board",
			variant = if state.view == "board" then "primary" else "default" },
		-- 窗口半边写完注入结果后要戳宿主重画，戳的就是这个按钮的节点 id
		-- （区块.区域.按钮 key）。没有 key 就没人能戳到它。
		-- 按钮自己的动作叫 reload，与窗口戳过来的 refresh 区分开：
		-- 前者重新拉数据，后者只是让宿主重画一次好读到回写结果。
		{ label = "刷新", icon = "refresh", key = "refresh", click = "reload" },
		{ label = "换仓库", icon = "repo", click = "pick-repo" },
		{ label = if state.showHidden then "隐藏实验技能" else "显示实验技能", icon = "eye", click = "toggle-hidden" },
	}
	-- 任务板视图下多两个按钮：问下一步（把票装进信封交给会话排序）、排序开关。
	if state.view == "board" then
		table.insert(buttons, { label = "问下一步", icon = "send", variant = "primary", click = "next-step" })
		table.insert(buttons, {
			label = if state.sortNewest then "最新在上" else "最早在上",
			icon = "refresh",
			click = "toggle-sort",
		})
	end
	-- 技能视图下多一个注入按钮：技能侧的注入也要有鼠标入口（不只是键盘 i）。
	if state.view == "skills" then
		table.insert(buttons, { label = "注入技能", icon = "send", variant = "primary", click = "inject-skill" })
	end

	local widths: { number } = {}
	for _, b in ipairs(buttons) do
		table.insert(widths, util.textWidth(b.label) + BUTTON_CHROME)
	end
	local rows: { Node } = {}
	for _, group in ipairs(util.packRows(widths, cx.cols, BUTTON_GAP)) do
		local nodes: { Node } = {}
		for _, idx in ipairs(group) do
			local b = buttons[idx]
			local props: { [string]: any } = {
				icon = b.icon,
				size = "sm",
				actions = { click = b.click },
			}
			if b.variant then
				props.variant = b.variant
			end
			if b.key then
				props.key = b.key
			end
			table.insert(nodes, ui.button(b.label, props))
		end
		table.insert(rows, ui.row(nodes))
	end
	return ui.col(rows)
end

--- 底部提示条：键位说明。
local function dockView(state: State): Node
	local items: { Node } = {
		ui.text(ui.span("点行看内容 · 点按钮操作", "muted")),
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

--- 任务板里当前选中的票（四组里任一）。
local function selectedTicket(state: State): tracker.Ticket?
	local b = tracker.classify(state.tickets)
	local frontier: { tracker.Ticket } = {}
	for _, t in ipairs(b.claimable) do
		table.insert(frontier, t)
	end
	for _, t in ipairs(b.assigned) do
		table.insert(frontier, t)
	end
	for _, t in ipairs(b.blocked) do
		table.insert(frontier, t)
	end
	for _, t in ipairs(b.closed) do
		table.insert(frontier, t)
	end
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
		-- 记下自己的 pane：窗口半边聚焦时只知道「某个窗口亮了」，
		-- 要靠这个键找到该戳哪个面板。
		pcall(tern.kv.set, PANEL_KEY, { pane = cx.pane })
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
		-- 注入结果由窗口半边写回 kv，view 里读一次更新提示。
		readResult(state)
		local main: Node
		if state.view == "skills" then
			main = ui.col({ toolbar(state, cx), skillsView(state, cx) })
		elseif state.view == "board" then
			main = ui.col({ toolbar(state, cx), boardView(state, cx) })
		elseif state.view == "map" then
			main = ui.col({ toolbar(state, cx), mapView(state, cx) })
		else
			main = ui.col({ toolbar(state, cx), ticketView(state, cx) })
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
			if state.view == "map" then
				state.view = "board"
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
			-- 展平顺序跟界面上的分组顺序一致：可领 → 已认领 → 被阻塞 → 已关闭。
			local buckets = tracker.classify(state.tickets)
			local frontier: { tracker.Ticket } = {}
			for _, t in ipairs(buckets.claimable) do
				table.insert(frontier, t)
			end
			for _, t in ipairs(buckets.assigned) do
				table.insert(frontier, t)
			end
			for _, t in ipairs(buckets.blocked) do
				table.insert(frontier, t)
			end
			for _, t in ipairs(buckets.closed) do
				table.insert(frontier, t)
			end
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
				state.ticketBody = nil
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

		if state.view == "map" then
			local m = selectedMap(state)
			if key.name == "up" or key.name == "down" then
				local cur = state.ticketSel
				local at = 1
				if m then
					for i, t in ipairs(m.tickets) do
						if t.number == cur then
							at = i
							break
						end
					end
				end
				local next_ = if key.name == "up" then math.max(1, at - 1) else math.max(1, at + 1)
				if m and m.tickets[next_] then
					state.ticketSel = m.tickets[next_].number
				end
				return true
			end
			if key.name == "enter" then
				local t = m and m.tickets[1]
				if not t then
					return false
				end
				state.ticket = t
				state.ticketBody = nil
				state.view = "ticket"
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
				if ev.ev == "activate" then
					-- 双击 = 把 /技能名 放进剪贴板，不直接投给 agent。
					-- 注入是替用户做决定，双击只是「准备好」，发不发由人定。
					sendAction(state, cx, "compose", commands.buildSkillCommand({ name = item }), item)
					state.message = "已复制 /skill:" .. item .. "，粘到输入框"
				else
					openSkill(state, item)
				end
			elseif state.view == "map" then
				-- 地图详情里的子票：点开看票详情
				local n = tonumber(item)
				local m = selectedMap(state)
				if n and m then
					for _, t in ipairs(m.tickets) do
						if t.number == n then
							state.ticketSel = n
							state.ticket = t
							state.ticketBody = nil
							state.view = "ticket"
							break
						end
					end
				end
			elseif state.view == "board" then
				local n = tonumber(item)
				if n then
					-- 地图行：进去看地图详情
					local isMap = false
					for _, m in ipairs(state.maps) do
						if m.number == n then
							isMap = true
							break
						end
					end
					if isMap then
						state.mapSel = n
						state.ticketSel = nil
						state.view = "map"
						return
					end
					-- 票行：四组（可领 / 已认领 / 被阻塞 / 已关闭）与 Spec 都按票号找，
					-- 不再只认前沿 —— 已认领和已关闭的票也得点得开。
					-- 单击就进详情：地图行本来就是单击进入，票行原来要双击，
					-- 同一块面板里两种手感，用户会以为"点不开"。
					for _, t in ipairs(state.tickets) do
						if t.number == n then
							state.ticketSel = n
							state.ticket = t
							state.ticketBody = nil
							state.view = "ticket"
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
		-- 窗口半边执行完注入会戳一下，让宿主重画（读回写回的结果）。
		if act == "refresh" then
			readResult(state)
			return
		end
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
		if string.sub(act, 1, 4) == "new:" then
			local e = templates.entryById(string.sub(act, 5))
			if e then
				inject(state, cx, templates.renderEntry(e, state.repo or ""), e.title)
			end
			return
		end
		if act == "toggle-sort" then
			state.sortNewest = not state.sortNewest
			state.message = if state.sortNewest then "最新在上" else "最早在上"
			return
		end
		if act == "next-step" then
			if not state.repo then
				state.message = "先识别到仓库与票，再问下一步"
				return
			end
			inject(state, cx, nextStepBody(state, cx), "问下一步")
			return
		end
		if act == "auto-reload" then
			-- 窗口半边每次聚焦都戳一下；真正拉不拉由这里定，焦点本身不花配额。
			-- 三道闸：正在拉 / 失败冷却中 / 距上次拉取不足 60 秒。
			-- 时钟拿不到就不刷：宁可少刷一次，也不能把节流闸整个绕过。
			local now = nowSec()
			if not now then
				return
			end
			if state.loading then
				return
			end
			if state.cooldownUntil and now < state.cooldownUntil then
				return
			end
			if state.lastLoadAt and now - state.lastLoadAt < AUTO_REFRESH_SEC then
				return
			end
			loadBoard(state, cx)
			return
		end
		if act == "reload" then
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
		if act == "inject-skill" then
			local s = selectedSkill(state)
			if not s then
				state.message = "没有选中技能"
				return
			end
			inject(state, cx, commands.buildSkillCommand(s), s.name)
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
