--!strict
-- 宿主半边：面板的画面（tern.ui 节点树）与数据获取。
--
-- 数据获取放在这一侧：`gh` 子进程与文件读取在宿主半边都能做（实测见
-- docs/research/host-half-runtime.md）。异步回调里改 state 再 cx:render() 即可重画，
-- 不必绕 kv（见 docs/research/host-async-render.md）。
--
-- 需要窗口半边才能做的只有一件：把提示词填进邻近 agent 的输入框（cx:run 是 window-only）。
-- 那一段走 tern.kv 传令：这里写 action 键，窗口半边轮询并执行。

local ui = tern.ui
local backend = require("./lib/backend")
local commands = require("./lib/commands")
local lanes = require("./lib/lanes")
local localtracker = require("./lib/localtracker")
local packs = require("./lib/packs")
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

--- 把时间戳格式化成「2026-11-07 10:51」。沙箱没暴露 os.date 时退化成原始秒数：
--- 提示词里写个时间戳总比写「刚刚」强，用户能据此判断该不该重新拉。
local function fmtTime(t: number?): string?
	if not t then
		return nil
	end
	local ok, v = pcall(function()
		return os.date("%Y-%m-%d %H:%M", t)
	end)
	if ok and type(v) == "string" then
		return v
	end
	return string.format("epoch %d", t)
end
local STALE_SEC = 7200
--- 拉取失败后安静一会儿。限流期间连点刷新只会让恢复更慢。
local COOLDOWN_SEC = 60

--- 自动刷新的最短间隔：窗口获得焦点时才考虑拉，且两次拉取之间至少隔这么久。
--- 焦点事件很频繁（切 pane、切 tab 都触发），而一次刷新要跑一趟 gh（实测 2.8 秒、
--- 约 4 个 GraphQL 点）。60 秒的闸意味着频繁切 tab 时几乎每次都在拉，
--- 面板跟着闪。5 分钟足够：票的变化来自用户自己刚做的操作，回来时会看到。
--- 需要立刻看到最新就按「刷新」或 r。
local AUTO_REFRESH_SEC = 300

--- 技能包查上游版本的最短间隔：手动刷新才查，且不能连点。
--- 三套包的检查要各跑一次 gh，配额是共享的。
local PACK_CHECK_SEC = 300

local ACTION_KEY = "action"
local INJECT_RESULT_KEY = "inject_result"
local REPO_KEY = "repo"
local SEQ_KEY = "seq"
local BLOCK_ID = "matt"

type View = "skills" | "board" | "map" | "ticket" | "packs"

--- 一次「问下一步」的状态。独立进程跑完才有结论，中间态要能渲染。
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
	-- 拉取原始 issue（GraphQL nodes）：open 全量、已关分页累积。
	openIssues: { any },
	closedIssues: { any },
	closedCursor: string?,
	-- 任务板拉取世代：新刷新/切排序递增，旧回调据此丢弃，避免旧方向页混进新序列。
	boardGen: number,
	closedHasNext: boolean,
	closedLoading: boolean,
	-- 选中的地图与票：身份字符串（GitHub 后端是编号，本地后端是 `<工作单元>/<NN>`）
	mapSel: string?,
	ticketSel: string?,
	-- 票按创建时间排：默认最新在上
	sortNewest: boolean,
	-- 工具条「新增需求」把两条路叫出来，选完或再按一次收起
	newDemand: boolean,
	-- 票详情
	ticket: tracker.Ticket?,
	ticketBody: string?,
	-- 正在用 REST 拉某张票的正文；view 里发请求必须靠它防重入
	bodyLoading: number?,
	-- 上次拉取失败后到这个时刻之前不再发请求
	cooldownUntil: number?,
	-- 上次真正发出拉取的时刻；自动刷新按它节流
	lastLoadAt: number?,
	-- 抓取时刻的唯一真源：秒数。显示用的字符串每次都从它格式化，
	-- 不再另存一份 —— 两个字段并存时真机出现过「时间字符串」与「年龄」
	-- 互相矛盾（同一对数据却给出 4.8 分钟和 254 分钟两个答案）。
	fetchedAtSec: number?,
	-- 旧缓存里只有字符串、没有秒数：只能显示，算不出年龄
	legacyFetchedAt: string?,
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
	-- 后端判定（ADR-0003）：用哪套数据源、依据从哪来
	backend: string?, -- "github" | "local"；nil = 判不出来
	backendSource: string?, -- "contract" | "detected" | "manual"
	backendReason: string?,
	localRoot: string?, -- 本地后端的仓库根（绝对路径）
	scanErrors: { { path: string, message: string } },
	skillVersion: string?,
	hasSkills: boolean,
	-- 外部技能包：本地状态（装了没、什么版本）
	packs: { packs.PackState },
	-- 上次向上游检查版本的时刻；节流用，打开视图不发请求
	packsCheckedAt: number?,
}

--- 空状态。init 与 save 恢复共用。
local function blank(): State
	return {
		view = "skills",
		sortNewest = true,
		newDemand = false,
		skills = {},
		lanes = {},
		skillSel = nil,
		skillBody = nil,
		showHidden = false,
		maps = {},
		tickets = {},
		openIssues = {},
		closedIssues = {},
		closedCursor = nil,
		boardGen = 0,
		closedHasNext = false,
		closedLoading = false,
		mapSel = nil,
		ticketSel = nil,
		ticket = nil,
		ticketBody = nil,
		bodyLoading = nil,
		cooldownUntil = nil,
		lastLoadAt = nil,
		fetchedAtSec = nil,
		legacyFetchedAt = nil,
		message = nil,
		pendingSeq = nil,
		loading = false,
		repo = nil,
		root = nil,
		repoManual = false,
		setupHint = nil,
		backend = nil,
		backendSource = nil,
		backendReason = nil,
		localRoot = nil,
		scanErrors = {},
		skillVersion = nil,
		hasSkills = false,
		packs = {},
		packsCheckedAt = nil,
	}
end

--- 显示用的抓取时刻：始终从秒数格式化，旧缓存没有秒数时才退回它自己的字符串。
local function fetchedLabel(state: State): string?
	return fmtTime(state.fetchedAtSec) or state.legacyFetchedAt
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
	local resolved, err = paths.resolvePackage()
	if not resolved then
		-- 登记读失败：保留上次值；确实没装：清空并显示安装提示。
		if err then
			return
		end
		state.hasSkills = false
		state.skills = {}
		state.lanes = {}
		state.skillVersion = nil
		return
	end
	local root = resolved.root
	local pkg = skills.readPackage(root, resolved.version)
	if not pkg then
		if not state.hasSkills then
			state.hasSkills = false
			state.skills = {}
			state.lanes = {}
		end
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

--- 登记里没有（或登记副本不存在）时，回退插件缓存里的同名副本：
--- 目录名形如 <包名>___<来源>___<版本>，与 paths 的兜底口径一致。
local function cachedPackRoot(id: string, home: string?): string?
	if not home then
		return nil
	end
	local dir = home .. "/.omp/plugins/cache/plugins"
	local ok, names = pcall(tern.fs.list, dir)
	if not ok then
		return nil
	end
	for _, n in ipairs(names) do
		if string.sub(n, 1, #id + 3) == id .. "___" then
			return dir .. "/" .. n
		end
	end
	return nil
end

--- 探外部技能包：登记里查得到就按 installPath 探；只有本地目录的按目录探。
--- 只读，不联网：待更新检查由显式的刷新触发。
local function loadPacks(state: State)
	local out: { packs.PackState } = {}
	local home = paths.home()
	local regText: string? = nil
	if home then
		local ok, text = pcall(tern.fs.read, home .. "/.omp/plugins/installed_plugins.json")
		if ok and type(text) == "string" then
			regText = text
		end
	end
	local old: { [string]: packs.PackState } = {}
	for _, p in ipairs(state.packs) do
		old[p.id] = p
	end
	for _, pack in ipairs(packs.PACKS) do
		local installed = false
		local version: string? = nil
		if pack.registryKey then
			local entry = paths.parseRegistryEntry(regText, pack.registryKey)
			if entry then
				local exists = false
				pcall(function()
					exists = tern.fs.exists(entry.installPath)
				end)
				installed = exists
				version = entry.version
				if installed and (not version or version == "") then
					version = paths.packageVersion(entry.installPath)
				end
			end
			if not installed then
				local root = cachedPackRoot(pack.id, home)
				if root then
					installed = true
					version = paths.packageVersion(root)
				end
			end
		elseif pack.localRel and home then
			local root = home .. "/" .. pack.localRel
			local exists = false
			pcall(function()
				exists = tern.fs.exists(root)
			end)
			installed = exists
			if installed then
				version = paths.packageVersion(root)
			end
		end
		local next_ = packs.stateOf(pack, installed, version)
		-- 重新探测会丢掉上次查到的上游版本：刷新/切视图后状态不能凭空退回「已装」。
		local prev = old[pack.id]
		if prev and prev.checkedAt and next_.installed then
			next_ = packs.withCheck(next_, prev.latest, prev.failed, prev.checkedAt)
		end
		table.insert(out, next_)
	end
	state.packs = out
end

--- 查上游最新版本：逐套跑 gh release，结论写回对应包。
--- 只由显式刷新触发（打开视图不发请求），失败保留上一次的结果。
local function checkPacks(state: State, cx: BlockCx)
	local now = nowSec()
	if not now then
		state.message = "版本检查：拿不到时间，跳过"
		cx:render()
		return
	end
	if state.packsCheckedAt and now - state.packsCheckedAt < PACK_CHECK_SEC then
		state.message = string.format("版本检查：刚查过，%d 秒后再查", PACK_CHECK_SEC - (now - state.packsCheckedAt))
		cx:render()
		return
	end
	local checked = 0
	local remaining = 0
	state.message = "版本检查：进行中…"

	--- 每次查完一套就收敛一次；全部回来时把「检查中」换成结论。
	local function finish(id: string, tag: string?)
		for i, cur in ipairs(state.packs) do
			if cur.id == id then
				local failed = tag == nil
				local label = if failed then cur.checkedAt else fmtTime(nowSec())
				state.packs[i] = packs.withCheck(cur, tag, failed, label)
			end
		end
		remaining -= 1
		if remaining > 0 then
			cx:render()
			return
		end
		local outdated, failedCount = 0, 0
		for _, cur in ipairs(state.packs) do
			if cur.status == "待更新" then
				outdated += 1
			elseif string.find(cur.status, "检查失败", 1, true) then
				failedCount += 1
			end
		end
		state.message = string.format("版本检查：已查 %d 套 · %d 套待更新", checked, outdated)
		if failedCount > 0 then
			state.message ..= string.format(" · %d 套检查失败", failedCount)
		end
		cx:render()
	end

	for _, ps in ipairs(state.packs) do
		if not ps.installed then
			continue
		end
		checked += 1
		remaining += 1
		local id = ps.id
		local repo = ps.repo
		--- 先查 release；只打 tag 的仓库查不到 release，回退 tags。
		local function onTags(result: any)
			local tag: string? = nil
			if result and result.status == 0 then
				tag = packs.tagFromOutput(tostring(result.stdout or ""))
			end
			finish(id, tag)
		end
		tern.process.run({
			"gh", "api", "repos/" .. repo .. "/releases/latest", "--jq", ".tag_name",
		}):next(function(result: any)
			local tag: string? = nil
			if result and result.status == 0 then
				tag = packs.tagFromOutput(tostring(result.stdout or ""))
			end
			if tag then
				finish(id, tag)
				return
			end
			tern.process.run({
				"gh", "api", "repos/" .. repo .. "/tags", "--jq", ".[0].name",
			}):next(onTags)
		end)
	end
	-- 只在真的发出检查时开始计时：一套都没装就别浪费下一个五分钟。
	if checked > 0 then
		state.packsCheckedAt = now
	else
		state.message = "版本检查：没有已安装的技能包，没什么可查"
	end
	cx:render()
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
	local open: { any } = {}
	local closed: { any } = {}
	for _, issue in ipairs(value.issues) do
		if type(issue) == "table" then
			if issue.state == "OPEN" then
				table.insert(open, issue)
			else
				table.insert(closed, issue)
			end
		end
	end
	state.openIssues = open
	state.closedIssues = closed
	state.closedCursor = nil
	state.closedHasNext = false
	state.closedLoading = false
	state.loading = false
	state.tickets = tracker.parseIssues(value.issues)
	state.maps = tracker.groupByMap(value.issues)
	state.fetchedAtSec = if type(value.fetchedAtSec) == "number" then value.fetchedAtSec else nil
	state.legacyFetchedAt = if type(value.fetchedAt) == "string" then value.fetchedAt else nil
	return true
end

--- 真正拉 issue 的那一步。
local fetchIssues: (State, BlockCx, string, number) -> ()
local fetchClosedPage: (State, BlockCx, string, boolean, number) -> ()
local ensureMapBody: (State, BlockCx, string) -> ()

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
	-- 取属性也要包进 pcall：tern.json 不存在时 `tern.json.decode` 本身就抛，
	-- 那样会把整个拉取流程带崩，而不是走「解析失败」这条正常退路。
	local ok, value = pcall(function()
		return tern.json.decode(text)
	end)
	if not ok or type(value) ~= "table" then
		return nil
	end
	return value
end

--- 记住仓库根：提示词里指文档路径要用真正的根，本地后端的扫描也以它为界。
--- 面板所在目录可能只是仓库里的一层。
local function resolveRoot(state: State, cx: BlockCx)
	local cwd = cx.cwd
	if not cwd or cwd == "" then
		return
	end
	tern.process.run({ "git", "-C", cwd, "rev-parse", "--show-toplevel" }):next(function(result: any)
		if result and result.status == 0 then
			local root = util.trim(tostring(result.stdout or ""))
			if root ~= "" then
				state.root = root
				state.localRoot = if state.backend == "local" then root else nil
			end
		end
	end)
end

--- 拉任务板：先判后端，再按后端取数据。
---
--- 后端由目标仓库的跟踪器约定文件决定（ADR-0003），面板不持有选择：
---   GitHub  → `gh api graphql` 游标分页
---   本地 md → 扫 `.scratch/<工作单元>/`，一次读进内存
--- 判不出来就落到 setup 卡，说清卡在哪一步。
local function loadBoard(state: State, cx: BlockCx)
	local now = nowSec()
	if now and state.cooldownUntil and now < state.cooldownUntil then
		state.message = string.format("上次拉取失败，%d 秒后再试", state.cooldownUntil - now)
		cx:render()
		return
	end
	-- 新一轮拉取：旧的在途回调随后都会被世代号丢弃，不能靠 loading 挡住。
	state.boardGen += 1
	local gen = state.boardGen
	-- 记下发出时刻：自动刷新用它节流。放在所有早退之前，
	-- 否则「识别不到仓库」这种稳态会让节流永远不生效。
	state.lastLoadAt = nowSec()
	state.loading = true

	--- 清空当前仓库的数据，用于判不出后端 / 识别不到仓库。
	local function clearBoard(reason: string?)
		state.loading = false
		state.repo = nil
		state.repoManual = false
		state.backend = nil
		state.backendSource = nil
		state.backendReason = reason
		state.localRoot = nil
		state.tickets = {}
		state.maps = {}
		state.openIssues = {}
		state.closedIssues = {}
		state.closedCursor = nil
		state.closedHasNext = false
		state.closedLoading = false
		state.ticket = nil
		state.ticketBody = nil
		state.mapSel = nil
		state.ticketSel = nil
		state.setupHint = reason or "当前目录没识别到 git remote"
		state.fetchedAtSec = nil
		state.legacyFetchedAt = nil
		state.message = nil
		cx:render()
	end

	--- 换数据源时把上一个仓库的显示状态清掉，别让旧票挂在新仓库名下。
	local function clearRows()
		state.scanErrors = {}
		state.tickets = {}
		state.maps = {}
		state.openIssues = {}
		state.closedIssues = {}
		state.closedCursor = nil
		state.closedHasNext = false
		state.closedLoading = false
		state.ticket = nil
		state.ticketBody = nil
		state.mapSel = nil
		state.ticketSel = nil
		state.fetchedAtSec = nil
		state.legacyFetchedAt = nil
	end

	--- 开始拉某个 GitHub 仓库。manual=true 表示来自「换仓库」。
	local function beginGithub(repo: string, manual: boolean)
		if gen ~= state.boardGen then
			return
		end
		state.setupHint = nil
		state.backend = "github"
		state.localRoot = nil
		if state.repo ~= repo then
			clearRows()
		end
		state.repo = repo
		state.repoManual = manual
		fetchIssues(state, cx, repo, gen)
		resolveRoot(state, cx)
	end

	--- 本地 markdown 后端：一次扫描 → 内存快照，不再读盘。
	local function beginLocal(root: string)
		if gen ~= state.boardGen then
			return
		end
		state.setupHint = nil
		state.repo = nil
		state.repoManual = false
		state.backend = "local"
		state.localRoot = root
		state.root = root
		clearRows()
		local scan = localtracker.scan(root)
		state.maps = scan.maps
		state.tickets = scan.tickets
		state.scanErrors = scan.errors
		state.loading = false
		state.fetchedAtSec = nowSec()
		state.legacyFetchedAt = nil
		-- 读不动的文件由任务板常驻列出，这里不再另发一条只闪一次的提示。
		if #scan.errors == 0 and #state.tickets == 0 and #state.maps == 0 then
			state.message = "这个 .scratch 目录里还没有地图与票"
		end
		cx:render()
	end

	--- 手动指定的仓库：只在本窗口、且只在 GitHub 后端下生效。
	--- 后端本身由仓库契约决定，手动选择改不了它（ADR-0003）——
	--- 否则本地 markdown 仓库会被一条存过的 owner/repo 顶成 GitHub 后端。
	local manualRepo: string? = nil
	do
		local ok, value = pcall(tern.kv.get, REPO_KEY)
		if ok and type(value) == "table" and value.pane == cx.pane
			and type(value.repo) == "string" and value.repo ~= "" then
			manualRepo = value.repo
		end
	end

	-- 判后端的依据：仓库根、origin、约定文件、.scratch 目录。
	local cwd = cx.cwd
	if not cwd or cwd == "" then
		clearBoard("宿主没给工作目录")
		return
	end
	tern.process.run({ "git", "-C", cwd, "rev-parse", "--show-toplevel" }):next(function(result: any)
		if gen ~= state.boardGen then
			return
		end
		local root = cwd
		if result and result.status == 0 then
			local top = util.trim(tostring(result.stdout or ""))
			if top ~= "" then
				root = top
			end
		end
		state.root = root
		tern.process.run({ "git", "-C", root, "remote", "get-url", "origin" }):next(function(remote: any)
			if gen ~= state.boardGen then
				return
			end
			local originUrl: string? = nil
			if remote and remote.status == 0 then
				local url = util.trim(tostring(remote.stdout or ""))
				if url ~= "" then
					originUrl = url
				end
			end
			local contractText: string? = nil
			local okRead, text = pcall(tern.fs.read, root .. "/" .. backend.CONTRACT_PATH)
			if okRead and type(text) == "string" then
				contractText = text
			end
			local okScratch, hasScratch = pcall(tern.fs.exists, root .. "/" .. localtracker.SCRATCH)
			local decision = backend.decide({
				contractText = contractText,
				originUrl = originUrl,
				hasScratch = okScratch and hasScratch == true,
			})
			if decision.backend == "local" then
				state.backendSource = decision.source
				state.backendReason = decision.reason
				beginLocal(root)
				return
			end
			if decision.backend == "github" then
				if manualRepo then
					state.backendSource = "manual"
					state.backendReason = "按手动指定的仓库"
					beginGithub(manualRepo, true)
					return
				end
				local repo = util.parseRemoteUrl(originUrl or "")
				if not repo then
					clearBoard("按 GitHub 后端处理，但这条 remote 解析不出 owner/repo：" .. (originUrl or "（没有 origin）"))
					return
				end
				state.backendSource = decision.source
				state.backendReason = decision.reason
				beginGithub(repo, false)
				return
			end
			clearBoard(decision.reason)
		end)
	end)
end

--- 已关票累积上限。
local CLOSED_CAP = 500

--- GraphQL 查询：每页 50，排序方向由上游执行。states 只取 OPEN/CLOSED 两个字面量，
--- 免得往 gh 传数组参数。after 省略时就是第一页。
local function graphqlQuery(stateName: string): string
	return table.concat({
		"query($owner:String!,$name:String!,$direction:OrderDirection!,$after:String){",
		"repository(owner:$owner,name:$name){issues(first:", tostring(tracker.PAGE_SIZE),
		",states:", stateName, ",after:$after,orderBy:{field:CREATED_AT,direction:$direction}){",
		"pageInfo{hasNextPage endCursor}",
		"nodes{number title state url createdAt labels(first:50){nodes{name}}",
		" assignees(first:10){nodes{login}} parent{number}",
		" blockedBy(first:50){nodes{number}}}",
		"}}}",
	})
end

local function graphqlArgv(repo: string, stateName: string, direction: string, after: string?): { string }?
	local owner, name = string.match(repo, "^([^/]+)/(.+)$")
	if not owner or not name then
		return nil
	end
	local argv = {
		"gh", "api", "graphql",
		"-f", "query=" .. graphqlQuery(stateName),
		"-F", "owner=" .. owner,
		"-F", "name=" .. name,
		"-F", "direction=" .. direction,
	}
	if after and after ~= "" then
		table.insert(argv, "-f")
		table.insert(argv, "after=" .. after)
	end
	return argv
end

--- 从 gh 结果里取一页；失败返回 nil。
local function readPage(result: any): { issues: { any }, hasNextPage: boolean, endCursor: string? }?
	if result == nil or result.status ~= 0 then
		return nil
	end
	local payload = decodeIssues(tostring(result.stdout or ""))
	if not payload then
		return nil
	end
	return tracker.parseIssuePage(payload)
end

--- 用当前 open/closed 原始票重建显示数据。
local function rebuildBoard(state: State)
	local all = tracker.mergeIssues(state.openIssues, state.closedIssues)
	state.tickets = tracker.parseIssues(all)
	state.maps = tracker.groupByMap(all)
end

--- 拉取失败：保留已看到的数据，冷却，必要时退到缓存。
local function failLoad(state: State, cx: BlockCx, repo: string, message: string)
	state.loading = false
	local now = nowSec()
	if now then
		state.cooldownUntil = now + COOLDOWN_SEC
	end
	state.message = message
	if applyCachedIssues(state, repo) then
		state.message = state.message
			.. "（显示上次拉到的数据"
			.. (if fetchedLabel(state) then "，" .. fetchedLabel(state) else "")
			.. "）"
	end
	cx:render()
end

--- 已关票一页：reset 时成功后才替换，失败保留旧内容；否则续拉下一页。
--- 每次 reset 递增世代号：在途的续拉/旧刷新回调随后会被丢弃。
fetchClosedPage = function(state: State, cx: BlockCx, repo: string, reset: boolean, gen: number)
	if reset then
		state.boardGen += 1
		gen = state.boardGen
	elseif state.closedLoading or not state.closedHasNext then
		return
	end
	local direction = tracker.orderDirection(state.sortNewest)
	local argv = graphqlArgv(repo, "CLOSED", direction, if reset then nil else state.closedCursor)
	if not argv then
		state.loading = false
		state.message = "仓库名解析失败：" .. repo
		cx:render()
		return
	end
	state.closedLoading = true
	tern.process.run(argv):next(function(result: any)
		if gen ~= state.boardGen then
			return
		end
		state.closedLoading = false
		local page = readPage(result)
		if not page then
			state.loading = false
			state.message = "已关票拉取失败：" .. tostring(if result then result.stderr else "无输出")
			if reset then
				-- 旧游标属于旧方向，不能继续拿来「加载更多」。
				state.closedHasNext = false
				state.closedCursor = nil
				-- open 已经拉全了：已关页失败也要先把 open 侧显示出来。
				rebuildBoard(state)
				ensureMapBody(state, cx, repo)
			end
			cx:render()
			return
		end
		local base = if reset then {} else state.closedIssues
		local merged = tracker.mergeIssues(base, page.issues)
		local hasNext = page.hasNextPage and page.endCursor ~= nil
		if #merged >= CLOSED_CAP then
			merged = tracker.capIssues(merged, CLOSED_CAP)
			hasNext = false
		end
		state.closedIssues = merged
		state.closedCursor = page.endCursor
		state.closedHasNext = hasNext
		state.loading = false
		rebuildBoard(state)
		if reset then
			-- 刷新会重建 Map，正文标记回到未加载；仍在地图页就补拉一次。
			ensureMapBody(state, cx, repo)
		end
		if #state.tickets == 0 then
			state.message = "这个仓库还没有 issue"
		end
		-- 缓存带着时刻：拉取失败退到缓存时，接收方能判断这份数据是不是过期的。
		local now = nowSec()
		state.fetchedAtSec = now
		state.legacyFetchedAt = nil
		pcall(tern.kv.set, ISSUES_CACHE_KEY, {
			repo = repo,
			issues = tracker.mergeIssues(state.openIssues, state.closedIssues),
			fetchedAtSec = state.fetchedAtSec,
		})
		cx:render()
	end)
end

--- 刷新：open 全量翻页（前沿判定必须看到每张 OPEN 阻塞票），再拉已关首屏一页。
fetchIssues = function(state: State, cx: BlockCx, repo: string, gen: number)
	local acc: { any } = {}
	local direction = tracker.orderDirection(state.sortNewest)

	local step: (string?) -> ()
	step = function(after: string?)
		local argv = graphqlArgv(repo, "OPEN", direction, after)
		if not argv then
			failLoad(state, cx, repo, "仓库名解析失败：" .. repo)
			return
		end
		tern.process.run(argv):next(function(result: any)
			if gen ~= state.boardGen then
				return
			end
			local page = readPage(result)
			if not page then
				failLoad(state, cx, repo, "gh 拉取失败：" .. tostring(if result then result.stderr else "无输出"))
				return
			end
			acc = tracker.mergeIssues(acc, page.issues)
			-- 上游说有下一页且给了游标就继续；游标缺失时收尾，避免死循环。
			if page.hasNextPage and page.endCursor then
				step(page.endCursor)
				return
			end
			state.openIssues = acc
			fetchClosedPage(state, cx, repo, true, gen)
		end)
	end
	step(nil)
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

--- 注入回执看门狗：窗口半边没起来（最典型是热重载读到了半成品文件）时，
--- 提示会永远停在「填入中」，用户只会觉得按钮坏了。几秒没回执就换成排障提示。
--- 宿主半边不保证有 tern.timer：拿不到就跳过，不能因此报错。
local function watchInjection(state: State, cx: BlockCx, seq: number, name: string)
	local ok, timer = pcall(function()
		return tern.timer
	end)
	if not ok or type(timer) ~= "function" then
		return
	end
	pcall(timer, 4000, function()
		-- 不清 pendingSeq：窗口半边可能只是慢（热重载、机器忙），
		-- 迟到的回执还要靠它认领，否则会把「已填入」判成失败。
		if state.pendingSeq ~= seq then
			return
		end
		state.message = "还没回执：" .. name .. " —— 窗口半边可能没起来：跑 tern plugin reload 后重开面板；正文可能已经填进输入框"
		cx:render()
	end)
end

--- 把一段文本填进邻近 agent 的输入框（真正执行在窗口半边），不提交。
--- 用户看过、补完自己的内容再按回车。
---
--- 宿主不能自己下"成功"的结论：填入可能失败（没 agent、写不进去）。
--- 所以这里只标"填入中"，等窗口半边把结果写回 INJECT_RESULT_KEY 再改口。
local function inject(state: State, cx: BlockCx, body: string, name: string)
	if body == "" then
		state.message = "没有正文，不注入"
		return
	end
	local seq = sendAction(state, cx, "inject", body, name)
	state.pendingSeq = seq
	state.message = "填入中：" .. name
	watchInjection(state, cx, seq, name)
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
		then "已填入：" .. tostring(value.name or "")
		else "填入失败：" .. tostring(value.name or "") .. " —— " .. tostring(value.error or "")
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

--- 模板里 {repo} 的取值：GitHub 用 owner/repo，本地用仓库根路径。
local function repoLabel(state: State): string
	return state.repo or state.localRoot or "（先识别仓库）"
end

--- 给模板变量补上后端相关的句子与仓库标识。
local function templateVars(state: State, extra: { [string]: string }?): { [string]: string }
	local vars = templates.backendVars(state.backend, {})
	vars.backend = state.backend
	vars.repo = repoLabel(state)
	vars.root = state.root or repoLabel(state)
	for k, v in pairs(extra or {}) do
		vars[k] = v
	end
	return vars
end

---------------------------------------------------------------- 渲染

-- 列表的行 id 前缀：区域.列表key.行id。鼠标点选与键盘移动共用同一份选中状态。
local SKILL_LIST = "skills"
local MAP_LIST = "maps"
local MAP_TICKET_LIST = "maptickets"
local TICKET_LIST = "tickets"
local SPEC_LIST = "specs"

--- 把一组票做成可点列表：每行给 key（= 票身份），选中态跟着 ticketSel 走。
--- 票类型 → 图标。tern 的图标集里没有 `ticket`，只能用现有名字；
--- wayfinder 的四类票各给一个形近的图标，好让行首能一眼分出类型。
local TYPE_ICON: { [string]: string } = {
	grilling = "message",
	prototype = "wrench",
	research = "search",
	task = "check",
}

local function makeList(items: { any }, tickets: { tracker.Ticket }, key: string, selected: string?, hint: string): Node
	local list = ui.list(items)
	local kids = list.c or {}
	for i, t in ipairs(tickets) do
		local p: { [string]: any } = kids[i].p or {}
		p.key = t.id
		kids[i].p = p
	end
	local lp: { [string]: any } = list.p or {}
	lp.key = key
	lp.selected = selected
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

--- 技能包区：面板引用的外部包，各一张卡。
--- 这里只报本地状态与安装方式，不代装、不代改；待更新检查走刷新。
local function packsView(state: State): Node
	local main: { Node } = {}
	table.insert(main, ui.text({
		ui.span("外部技能包", "strong"),
		ui.span("  面板引用它们，但不自带、不代装", "muted"),
	}))
	-- 自己的刷新：只查这三套包的上游版本，不碰任务板。
	table.insert(main, ui.row({
		ui.button("刷新版本", {
			icon = "refresh",
			size = "sm",
			key = "packs-refresh",
			actions = { click = "packs-refresh" },
		}),
	}))
	if #state.packs == 0 then
		table.insert(main, ui.text(ui.span("没有可展示的技能包", "muted")))
		return ui.col(main)
	end
	for _, p in ipairs(state.packs) do
		local kids: { Node } = {
			ui.text(ui.span(p.purpose, "muted")),
			ui.text(ui.link(p.url, p.url)),
		}
		for _, line in ipairs(p.install) do
			table.insert(kids, ui.code(line, "bash"))
		end
		table.insert(kids, ui.row({
			ui.button("复制链接", {
				icon = "link",
				size = "sm",
				actions = { click = "copy-pack-repo:" .. p.id },
			}),
			ui.button("复制安装", {
				icon = "copy",
				size = "sm",
				actions = { click = "copy-pack-install:" .. p.id },
			}),
		}))
		local head: { any } = {
			ui.span(p.title, "strong"),
			ui.span("  " .. packs.versionLabel(p.version), "muted"),
		}
		-- 「待更新」要能看出升到哪一版，否则用户只知道有新版。
		if p.latest then
			table.insert(head, ui.span("  → 上游 " .. p.latest, "muted"))
		end
		table.insert(main, ui.card(head, kids, {
			icon = "tasks",
			meta = ui.span(p.status, if p.installed then "muted" else "warning"),
		}))
	end
	return ui.col(main)
end

--- 任务板顶部：数据源是哪个后端、依据从哪来、仓库是什么。
local function backendHint(state: State): string
	local source = if state.backendSource == "contract"
		then "按约定文件"
		elseif state.backendSource == "manual"
			then "按手动指定"
			elseif state.backendSource == "detected"
				then "按识别"
				else ""
	local parts: { string } = {}
	if source ~= "" then
		table.insert(parts, source)
	end
	if state.backendReason and state.backendReason ~= "" then
		table.insert(parts, state.backendReason)
	end
	return table.concat(parts, " · ")
end

--- 阻塞边显示：id 里带工作单元时只显示编号部分。
local function shortId(id: string): string
	return (string.match(id, "([^/]+)$")) or id
end

--- 本地后端的票文件/地图文件绝对路径（扫描结果给的是仓库相对路径）。
local function filePath(state: State, rel: string?): string?
	if not rel or not state.localRoot then
		return nil
	end
	return state.localRoot .. "/" .. rel
end

--- 任务板区：地图列表与前沿票列表，都是可点的。
--- 新增需求的两条路：需求还没摸清走 wayfinder 画地图；已经明确就直接 grill 收敛成 spec。
--- 只甩一条 /wayfinder 会误导需求已经清楚的人。
local function entryChooser(): Node
	local col: { Node } = { ui.text(ui.span("新增需求 —— 先选一条路", "strong")) }
	local row: { Node } = {}
	for _, e in ipairs(templates.ENTRIES) do
		table.insert(row, ui.button(e.title, {
			icon = if e.id == "explore" then "map" else "message",
			size = "sm",
			variant = "primary",
			actions = { click = "new:" .. e.id },
		}))
	end
	table.insert(col, ui.row(row))
	for _, e in ipairs(templates.ENTRIES) do
		table.insert(col, ui.text({
			ui.span("· " .. e.title .. "：", "muted"),
			ui.span(e.hint, "muted"),
		}))
	end
	return ui.col(col)
end

local function boardView(state: State, cx: BlockCx): Node
	local main: { Node } = {}

	-- 已经有数据时刷新不清屏：清屏会让整块面板闪一下，
	-- 而焦点切换本来就可能每分钟触发一次刷新。空板才给占位。
	if state.loading and #state.tickets == 0 and #state.maps == 0 then
		table.insert(main, ui.text(ui.span("正在拉取…", "muted")))
		return ui.col(main)
	end
	if state.backend == "local" then
		table.insert(main, ui.text({
			ui.span(state.localRoot or "本地仓库", "strong"),
			ui.span("  本地 markdown", "muted"),
		}))
		table.insert(main, ui.text(ui.span(backendHint(state), "muted")))
	elseif state.repo then
		table.insert(main, ui.text({
			ui.span(state.repo, "strong"),
			ui.span(if state.repoManual
				then "  手动指定 · 刷新仍用这个仓库"
				else "  来自当前目录的 git remote", "muted"),
		}))
		local hint = backendHint(state)
		if hint ~= "" then
			table.insert(main, ui.text(ui.span(hint, "muted")))
		end
	end
	-- 判不出后端：说清卡在哪，并给下一步。别把别的仓库的票画在这。
	if state.setupHint then
		table.insert(main, ui.text(ui.span("没识别到跟踪器", "warning")))
		table.insert(main, ui.text({
			ui.span("原因：", "muted"),
			ui.span(state.setupHint, "muted"),
		}))
		table.insert(main, ui.text(ui.span(
			"面板按仓库的跟踪器约定文件（" .. backend.CONTRACT_PATH .. "）判后端；没有就按 origin 与 .scratch 识别。"
				.. "先跑 /skill:setup-matt-pocock-skills 把跟踪器配好。", "muted"
		)))
		-- 手动指定只在 GitHub 侧有意义：后端由仓库契约决定，不是面板的选择。
		if state.backend ~= "local" then
			table.insert(main, ui.row({
				ui.button("手动指定 owner/repo", {
					icon = "repo",
					size = "sm",
					variant = "primary",
					actions = { click = "pick-repo" },
				}),
			}))
		end
	end

	-- 读不动的文件常驻显示：只报一次就消失，用户会把缺行当成「票没了」。
	if #state.scanErrors > 0 then
		local names: { string } = {}
		for i, e in ipairs(state.scanErrors) do
			if i > 8 then
				table.insert(names, string.format("…共 %d 个", #state.scanErrors))
				break
			end
			table.insert(names, e.path)
		end
		table.insert(main, ui.text({
			ui.span(string.format("%d 个票/地图文件读不动：", #state.scanErrors), "warning"),
			ui.span(table.concat(names, "、"), "muted"),
		}))
	end

	-- 空仓库时直接把两条路摆出来；有票时靠工具条的「新增需求」按钮随时叫出来。
	if (#state.tickets == 0 and (state.repo or state.backend == "local")) or state.newDemand then
		table.insert(main, entryChooser())
	end

	-- 地图
	local mapItems: { any } = {}
	for _, m in ipairs(state.maps) do
		table.insert(mapItems, {
			label = m.title,
			detail = string.format("%d 张子票", #m.tickets),
			icon = "map",
			tone = if m.id == state.mapSel then "accent" else nil,
		})
	end
	local mapList = ui.list(mapItems)
	local mapKids = mapList.c or {}
	for i, m in ipairs(state.maps) do
		local p: { [string]: any } = mapKids[i].p or {}
		p.key = m.id
		mapKids[i].p = p
	end
	local mapLp: { [string]: any } = mapList.p or {}
	mapLp.key = MAP_LIST
	mapLp.selected = state.mapSel
	mapLp.empty = { ui.span(
			if state.backend == "local" then "没有 map.md · 跑 /skill:wayfinder 建一张" else "没有 wayfinder:map 地图 · 跑 /wayfinder 建一张",
			"muted"
		) }
	mapLp.max = { lines = math.max(4, math.floor((cx.rows - 12) / 2)) }
	mapList.p = mapLp
	-- 和 Spec、四组票一样做成可折叠卡片：一张地图占一块地方，
	-- 项目里有好几张地图时纯列表会把下面的票挤出屏幕。
	table.insert(main, ui.card(ui.text({
		ui.span("地图", "strong"),
		ui.span(if state.backend == "local"
			then "  .scratch/<工作单元>/map.md · 子票挂在它名下"
			else "  wayfinder:map · 子票挂在它名下", "muted"),
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
				tone = if entry.spec.id == state.ticketSel then "accent" else nil,
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
			hint = "没有关闭的票", icon = "file", tone = "muted", closed = true },
	}
	-- 空组也要画：卡片标题上的「0 张」本身就是信息，少画一张卡用户就以为那一组不存在。
	for _, g in ipairs(groups) do
		-- 已关闭组按上游页序追加，不跨页重排；open 侧是全量，本地重排等价于全局序。
		if not g.closed then
			g.items = tracker.sortByCreated(g.items, state.sortNewest)
		end
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
					table.insert(nums, "#" .. shortId(n))
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
			local tone = if t.id == state.ticketSel then
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
		if #g.items == 0 or g.closed then
			props.collapsed = true
		end
		local children: { Node } = { list }
		-- 已关组是分页的：还有下一页且没到上限时，组内末尾给「加载更多」。
		-- 条数用已加载的原始已关票数（含被四组过滤掉的顶层 spec），与游标口径一致。
		if g.closed and state.closedHasNext and not state.loading and #state.closedIssues < CLOSED_CAP then
			table.insert(children, ui.row({
				ui.button(
					(if state.closedLoading then "加载中…" else string.format("加载更多（已 %d 条）", #state.closedIssues)),
					{
						icon = "refresh",
						size = "sm",
						actions = { click = "load-more-closed" },
					}
				),
			}))
		end
		table.insert(main, ui.card(head, children, props))
	end

	return ui.col(main)
end

--- 本地后端的票没有远端链接：复制与打开都落到仓库相对路径上。
local function ticketClip(state: State, t: tracker.Ticket): string
	local where = if state.backend == "local" then (t.path or "") else t.url
	return t.title .. "\n" .. where
end

--- 打开票：GitHub 开链接，本地 markdown 调文档视图。
local function openTicketTarget(state: State, cx: BlockCx, t: tracker.Ticket)
	if state.backend == "local" then
		local abs = filePath(state, t.path)
		if not abs then
			state.message = "这张票没有对应的本地文件"
			return
		end
		sendAction(state, cx, "open-doc", abs, t.path or abs)
		state.message = "已请求打开：" .. (t.path or abs) .. "（改完按 r 刷新）"
		return
	end
	if t.url == "" then
		state.message = "这张票没有链接"
		return
	end
	cx:open(t.url)
end

--- 任务板里当前选中的地图。
local function selectedMap(state: State): tracker.Map?
	for _, m in ipairs(state.maps) do
		if m.id == state.mapSel then
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
	local localMode = state.backend == "local"
	if localMode then
		table.insert(main, ui.text({
			ui.span(m.title, "strong"),
			ui.span(string.format("  %s · %d 张子票", m.path or "", #m.tickets), "muted"),
		}))
	else
		table.insert(main, ui.text({
			ui.span(m.title, "strong"),
			ui.span(string.format("  #%d · %d 张子票", m.number, #m.tickets), "muted"),
		}))
		table.insert(main, ui.text(ui.link(m.url, m.url, "muted")))
	end

	-- 地图级前沿：该地图里未关闭、未阻塞、未认领的票。
	-- 一次算完整张地图的子票集合：单张票算不出来「被同地图的票阻塞」。
	local mapFrontier: { tracker.Ticket } = {}
	for _, t in ipairs(tracker.computeFrontier(m.tickets)) do
		table.insert(mapFrontier, t)
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
				table.insert(nums, "#" .. shortId(n))
			end
			table.insert(parts, "等 " .. table.concat(nums, ","))
		end
		if t.type then
			table.insert(parts, t.type)
		end
		if t.state ~= "OPEN" then
			table.insert(parts, "已关闭")
		end
		local tone = if t.id == state.ticketSel then
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
		p.key = t.id
		kids[i].p = p
	end
	local lp: { [string]: any } = list.p or {}
	lp.key = MAP_TICKET_LIST
	lp.selected = state.ticketSel
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
	if not m.bodyLoaded then
		table.insert(main, ui.text(ui.span("正在读地图正文…", "muted")))
	end
	if m.fog and m.fog ~= "" then
		table.insert(main, ui.rule(ui.span("尚未明确（迷雾）")))
		table.insert(main, ui.md(m.fog))
	end
	if m.decisions and m.decisions ~= "" then
		table.insert(main, ui.rule(ui.span("已有决策")))
		table.insert(main, ui.md(m.decisions))
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
	if localMode and m.path then
		table.insert(buttons, ui.button("打开文档", {
			icon = "file",
			size = "sm",
			actions = { click = "open-doc" },
		}))
		table.insert(main, ui.row(buttons))
		table.insert(main, ui.text(ui.span("该文件 agent 也会写：改完按 r 刷新。", "warning")))
	else
		table.insert(main, ui.row(buttons))
	end

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

--- 地图正文也只按需拉：列表查询不含 body，迷雾/范围外靠它解析。
local function loadMapBody(state: State, cx: BlockCx, repo: string, m: tracker.Map)
	if m.bodyLoaded or state.bodyLoading == m.number then
		return
	end
	state.bodyLoading = m.number
	tern.process.run({
		"gh", "api",
		string.format("repos/%s/issues/%d", repo, m.number),
		"--jq", ".body",
	}):next(function(result: any, _err: any, _cx: any)
		state.bodyLoading = nil
		if result ~= nil and result.status == 0 then
			local body = tostring(result.stdout or "")
			m.body = body
			m.bodyLoaded = true
			local sections = tracker.parseSections(body)
			m.fog = sections.fog
			m.outOfScope = sections.outOfScope
		else
			m.bodyLoaded = false
			m.body = ""
			state.message = "取地图正文失败：" .. tostring(if result then result.stderr else "无输出")
		end
		cx:render()
	end)
end

--- 刷新后仍停在地图页时补拉当前地图正文。
ensureMapBody = function(state: State, cx: BlockCx, repo: string)
	if state.view ~= "map" then
		return
	end
	local m = selectedMap(state)
	if m then
		loadMapBody(state, cx, repo, m)
	end
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
	if state.backend == "local" then
		table.insert(main, ui.text(ui.span(t.path or "", "muted")))
	else
		table.insert(main, ui.text(ui.link(t.url, t.url, "muted")))
	end

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
	if state.backend == "local" then
		if t.path then
			table.insert(buttons, ui.button("打开文档", {
				icon = "file",
				size = "sm",
				actions = { click = "open-doc" },
			}))
		end
	else
		table.insert(buttons, ui.button("打开链接", {
			icon = "link",
			size = "sm",
			actions = { click = "open-ticket" },
		}))
	end
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
			table.insert(nums, "#" .. shortId(n))
		end
		table.insert(main, ui.text(ui.span("等这些先完成：" .. table.concat(nums, "、"), "warning")))
	end

	-- 本地后端：状态另起一行结构化显示，正文就是票文件全文（扫描时已读进内存）。
	if state.backend == "local" then
		if t.path then
			table.insert(main, ui.text(ui.span("该文件 agent 也会写：你在文档视图里改，agent 可能在别处改同一份文件。", "warning")))
		end
		local parts: { string } = { if t.state == "OPEN" then "打开" else "已关闭" }
		if t.claimed then
			table.insert(parts, "已认领")
		end
		if t.type then
			table.insert(parts, t.type)
		end
		if t.unresolvedBlockers then
			table.insert(parts, "有阻塞引用指向不存在的票")
		end
		table.insert(main, ui.text({
			ui.span("状态：", "muted"),
			ui.span(table.concat(parts, " · "), "strong"),
		}))
		if t.body ~= "" then
			table.insert(main, ui.rule(ui.span("票文件")))
			table.insert(main, ui.md(t.body))
		end
		return ui.col(main)
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
		-- 常驻三条：参考实现里这两条路、提 BUG、体检是随时能按的
		{ label = "新增需求", icon = "plus", click = "new-demand" },
		{ label = "提 BUG", icon = "warning", click = "new-bug" },
		{ label = "体检", icon = "check", click = "health-check" },
		{ label = "收尾", icon = "pr", click = "wrap-up" },
		{ label = "技能", icon = "sparkle", click = "view-skills",
			variant = if state.view == "skills" then "primary" else "default" },
		{ label = "任务板", icon = "map", click = "view-board",
			variant = if state.view == "board" then "primary" else "default" },
		{ label = "技能包", icon = "tasks", click = "view-packs",
			variant = if state.view == "packs" then "primary" else "default" },
		-- 窗口半边写完注入结果后要戳宿主重画，戳的就是这个按钮的节点 id
		-- （区块.区域.按钮 key）。没有 key 就没人能戳到它。
		-- 按钮自己的动作叫 reload，与窗口戳过来的 refresh 区分开：
		-- 前者重新拉数据，后者只是让宿主重画一次好读到回写结果。
		{ label = "刷新", icon = "refresh", key = "refresh", click = "reload" },
		{ label = if state.showHidden then "隐藏实验技能" else "显示实验技能", icon = "eye", click = "toggle-hidden" },
	}
	-- 后端由仓库契约决定：本地后端下没有「换仓库」（换的是 GitHub 的 owner/repo）。
	if state.backend ~= "local" then
		-- 位置在「刷新」之后、「显示实验技能」之前，与原顺序一致。
		table.insert(buttons, #buttons - 1, { label = "换仓库", icon = "repo", click = "pick-repo" })
	end
	-- 手动切过仓库时给一个出口：清掉覆盖，回到 cwd 的 remote。
	if state.repoManual and state.backend ~= "local" then
		table.insert(buttons, { label = "重置仓库", icon = "back", click = "reset-repo" })
	end
	-- 任务板视图下多两个按钮：问下一步（交给会话里的 ask-matt）、排序开关。
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

--- 底部提示条：键位说明、数据时刻、最近一条提示。
--- 自动刷新拉到 5 分钟后，光看面板分不清数据是刚拉的还是十分钟前的，
--- 所以把拉取时刻直接摊在这里；要最新就按刷新。
local function dockView(state: State): Node
	local items: { Node } = {
		ui.text(ui.span("点行看内容 · 点按钮操作", "muted")),
	}
	local at = fetchedLabel(state)
	if at then
		local stale = false
		local now = nowSec()
		if now and state.fetchedAtSec then
			stale = util.isStale(now, state.fetchedAtSec, STALE_SEC)
		end
		if stale then
			table.insert(items, ui.text(ui.span("数据 " .. at .. " · 建议刷新", "error")))
		else
			table.insert(items, ui.text(ui.span("数据 " .. at, "muted")))
		end
	end

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
		if t.id == state.ticketSel then
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
		loadPacks(state)
		loadBoard(state, cx)
		return state
	end,

	title = function(state: State): string
		if state.view == "skills" then
			return string.format("Matt 面板 · 技能 %d", #state.skills)
		elseif state.view == "board" then
			return string.format("Matt 面板 · 前沿 %d", #tracker.computeFrontier(state.tickets))
		elseif state.view == "packs" then
			return string.format("Matt 面板 · 技能包 %d", #state.packs)
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
		elseif state.view == "packs" then
			main = ui.col({ toolbar(state, cx), packsView(state) })
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
			loadPacks(state)
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
					if cur and t.id == cur.id then
						at = i
						break
					end
				end
				local next_ = if key.name == "up" then math.max(1, at - 1) else math.min(#frontier, at + 1)
				if frontier[next_] then
					state.ticketSel = frontier[next_].id
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
				cx:copy(ticketClip(state, t))
				state.message = "已复制票信息"
				return true
			end
			if key.name == "o" then
				local t = selectedTicket(state)
				if not t then
					return false
				end
				openTicketTarget(state, cx, t)
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
						if t.id == cur then
							at = i
							break
						end
					end
				end
				local next_ = if key.name == "up" then math.max(1, at - 1) else math.max(1, at + 1)
				if m and m.tickets[next_] then
					state.ticketSel = m.tickets[next_].id
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
			inject(state, cx, commands.buildTicketCommand({ url = t.url, title = t.title, number = t.number, path = t.path, backend = state.backend }, tpl), t.title)
			return true
		end
		if key.name == "c" then
			local t = state.ticket
			if not t then
				return false
			end
			cx:copy(ticketClip(state, t))
			state.message = "已复制票信息"
			return true
		end
		if key.name == "o" then
			local t = state.ticket
			if not t then
				return false
			end
			openTicketTarget(state, cx, t)
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
				local m = selectedMap(state)
				if m then
					for _, t in ipairs(m.tickets) do
						if t.id == item then
							state.ticketSel = item
							state.ticket = t
							state.ticketBody = nil
							state.view = "ticket"
							break
						end
					end
				end
			elseif state.view == "board" then
				-- 行 key 就是身份：GitHub 后端是编号字符串，本地后端是 `<工作单元>/<NN>`。
				if item ~= "" then
					-- 地图行：进去看地图详情
					local isMap = false
					for _, m in ipairs(state.maps) do
						if m.id == item then
							isMap = true
							break
						end
					end
					if isMap then
						state.mapSel = item
						state.ticketSel = nil
						state.view = "map"
						if state.repo then
							local m = selectedMap(state)
							if m then
								loadMapBody(state, cx, state.repo, m)
							end
						end
						return
					end
					-- 票行：四组（可领 / 已认领 / 被阻塞 / 已关闭）与 Spec 都按票号找，
					-- 不再只认前沿 —— 已认领和已关闭的票也得点得开。
					-- 单击就进详情：地图行本来就是单击进入，票行原来要双击，
					-- 同一块面板里两种手感，用户会以为"点不开"。
					for _, t in ipairs(state.tickets) do
						if t.id == item then
							state.ticketSel = item
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
		if act == "view-packs" then
			state.view = "packs"
			state.message = nil
			return
		end
		if act == "packs-refresh" then
			checkPacks(state, cx)
			return
		end
		if string.sub(act, 1, 15) == "copy-pack-repo:" then
			local p = packs.byId(string.sub(act, 16))
			if not p then
				return
			end
			cx:copy(packs.repoUrl(p.repo))
			state.message = "已复制仓库链接：" .. p.title
			return
		end
		if string.sub(act, 1, 18) == "copy-pack-install:" then
			local p = packs.byId(string.sub(act, 19))
			if not p then
				return
			end
			cx:copy(table.concat(p.install, "\n"))
			state.message = "已复制安装指引：" .. p.title
			return
		end
		if string.sub(act, 1, 4) == "new:" then
			local e = templates.entryById(string.sub(act, 5))
			if e then
				inject(state, cx, commands.buildInjectionBody(e.injectAction, templates.render(e, templateVars(state))), e.title)
			end
			return
		end
		if act == "toggle-sort" then
			state.sortNewest = not state.sortNewest
			state.message = if state.sortNewest then "最新在上" else "最早在上"
			-- 换方向：旧游标立即作废，免得冷却/失败时「加载更多」接回旧方向。
			state.boardGen += 1
			state.closedHasNext = false
			state.closedCursor = nil
			-- 已关组从第一页按新方向重拉；open 组本地重排等价于全局序。
			loadBoard(state, cx)
			return
		end
		if act == "load-more-closed" then
			if state.repo and state.closedHasNext and not state.loading and #state.closedIssues < CLOSED_CAP then
				fetchClosedPage(state, cx, state.repo, false, state.boardGen)
			end
			return
		end
		if act == "next-step" then
			if not (state.repo or state.backend == "local") then
				state.message = "先识别到仓库，再问下一步"
				return
			end
			inject(state, cx, commands.buildInjectionBody("问下一步", templates.render(templates.NEXT_STEP, templateVars(state))), "问下一步")
			return
		end
		if act == "new-demand" then
			state.view = "board"
			state.newDemand = not state.newDemand
			state.message = nil
			return
		end
		if act == "new-bug" then
			inject(state, cx, commands.buildInjectionBody("提 BUG", templates.render(templates.NEW_BUG, templateVars(state))), "提 BUG")
			return
		end
		if act == "wrap-up" then
			if not (state.repo or state.backend == "local") then
				state.message = "先识别到仓库，再收尾"
				return
			end
			-- 缺装不拦：模板自带降级路径，这里只把缺口说清。
			local missing: { string } = {}
			for _, p in ipairs(state.packs) do
				if not p.installed then
					table.insert(missing, p.title)
				end
			end
			inject(
				state,
				cx,
				commands.buildInjectionBody("收尾", templates.render(templates.WRAP_UP, templateVars(state))),
				"收尾"
			)
			if #missing > 0 then
				state.message = "填入中：收尾（未装 " .. table.concat(missing, "、") .. "，相关步骤走降级路径）"
			end
			return
		end
		if act == "health-check" then
			inject(state, cx, commands.buildInjectionBody("体检", templates.render(templates.HEALTH_CHECK, templateVars(state))), "体检")
			return
		end
		if act == "auto-reload" then
			-- 窗口半边每次聚焦都戳一下；真正拉不拉由这里定，焦点本身不花配额。
			-- 三道闸：正在拉 / 失败冷却中 / 距上次拉取不足 5 分钟。
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
			loadPacks(state)
			loadBoard(state, cx)
			state.message = "已刷新"
			return
		end
		if act == "reset-repo" then
			tern.kv.set(REPO_KEY, { repo = "", pane = cx.pane })
			state.message = "已恢复跟随当前目录"
			loadBoard(state, cx)
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
			cx:copy(ticketClip(state, t))
			state.message = "已复制票信息"
			return
		end
		if act == "open-doc" then
			-- 路径只来自扫描结果，不拼用户输入。
			local rel: string? = nil
			if state.view == "map" then
				local m = selectedMap(state)
				rel = m and m.path or nil
			elseif state.ticket then
				rel = state.ticket.path
			end
			local abs = filePath(state, rel)
			if not abs then
				state.message = "这个对象没有对应的本地文件"
				return
			end
			sendAction(state, cx, "open-doc", abs, rel or abs)
			state.message = "已请求打开：" .. (rel or abs) .. "（改完按 r 刷新）"
			return
		end
		if act == "open-ticket" then
			local t = state.ticket
			if not t then
				return
			end
			openTicketTarget(state, cx, t)
			return
		end
		if string.sub(act, 1, 4) == "act:" then
			local tpl = templates.byId(string.sub(act, 5))
			local t = state.ticket
			if not tpl or not t then
				return
			end
			inject(state, cx, commands.buildTicketCommand({ url = t.url, title = t.title, number = t.number, path = t.path, backend = state.backend }, tpl), t.title)
		end
	end,

	save = function(state: State): any
		return {
			view = state.view,
			showHidden = state.showHidden,
			repo = state.repo,
			skillSel = state.skillSel,
			newDemand = state.newDemand,
		}
	end,
})
