--!strict
-- 窗口半边：调色板命令、状态栏胶囊，以及把宿主半边发来的注入请求转交给邻近 agent。
--
-- 面板本身在宿主半边（host.luau）。两个半边不共享 Lua 状态，
-- 这里用 tern.kv 传令：宿主写 action 键，窗口轮询它并执行。
--
-- cx:run 是 window-only，所以「把提示词填进 agent 输入框」只能在这一侧完成。

local commands = require("./lib/commands")
local paths = require("./lib/paths")
local skills = require("./lib/skills")
local templates = require("./lib/templates")
local util = require("./lib/util")

local KIND = "tern-matt-panel.matt"
local ACTION_KEY = "action"
local INJECT_RESULT_KEY = "inject_result"
local REPO_KEY = "repo"
local POLL_MS = 300
--- 注入后核对输入框的延迟：cx:run 之后 surface 要过几个帧才更新（实测 300ms 内）。
local VERIFY_MS = 320

-- 最近聚焦的 agent：面板没有绑定目标时的兜底。
local lastAgent: number? = nil
-- 已经处理过的请求序号，避免重复注入。
local seenSeq = 0
-- 版本胶囊缓存：加载时读一次，focus 时重读；formatter 只读缓存。
local cachedVersion: string? = nil

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

--- 多行正文包成括号粘贴：终端会当成一次粘贴整段塞进输入框，
--- 不会在第一个换行处把消息提前发出去。
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

--- 原生 omp 输入框的正文，从串流面读。
--- 原生 omp 的 chat 面没有无障碍树（view 对 chat 返回 nil 或没有 value），
--- 实时可读的只有 surface 里的 composer editor 节点。
--- 优先认作 composer 的 editor：节点或祖先带 composer role，或 id 以 .line/input 结尾
--- （omp 的输入框）。读不到就返回 nil：没有 editor、旧版 Tern 都不该当成「空框」。
--- 注意：非焦点/隐藏 tab 的 chat 读到的 text 会是空串，判失败前调用方还要确认 pane 是焦点块。
local function surfaceComposerText(cx: WindowCx, pane: number): string?
	local ok, surface = pcall(function()
		return cx.session:surface(pane, { depth = 60, nodes = 5000 })
	end)
	if not ok or type(surface) ~= "table" then
		return nil
	end
	local marked: string? = nil
	local anywhere: string? = nil
	local function walk(n: any, inComposer: boolean)
		if type(n) ~= "table" then
			return
		end
		local p = n.p
		local composer = inComposer
		if type(p) == "table" and type(p.role) == "string" and string.find(p.role, "composer", 1, true) ~= nil then
			composer = true
		end
		if n.k == "editor" and type(p) == "table" and type(p.text) == "string" then
			if anywhere == nil then
				anywhere = p.text
			end
			local byId = type(n.id) == "string" and string.find(n.id, "line/input", 1, true) ~= nil
			if marked == nil and (composer or byId) then
				marked = p.text
			end
		end
		for _, kid in ipairs(n.c or {}) do
			walk(kid, composer)
		end
	end
	walk(surface.main, false)
	walk(surface.dock, false)
	return marked or anywhere
end

--- 空白的差别不算差别：正文比对一律去掉空白再比。
local function textHas(text: string, marker: string): boolean
	return string.find(string.gsub(text, "%s+", ""), marker, 1, true) ~= nil
end

--- 核对用的指纹：去掉空白后的前 24 字。
local function markerOf(body: string): string
	local flat = string.gsub(body, "%s+", "")
	return string.sub(flat, 1, math.min(24, #flat))
end

--- 无障碍树里的输入框是不是真有这段正文。
--- 只有终端/旧版 Tern 走到这里（原生 omp chat 走 surface）。
--- 节点在但读不出内容时判「看不懂」，不能当成「没填进去」——那是把成功当失败。
local function composerHas(cx: WindowCx, pane: number, marker: string): boolean?
	local ok, view = pcall(function()
		return cx.session:view(pane, { depth = 10 })
	end)
	if not ok or type(view) ~= "table" then
		return nil
	end
	local found = false
	local readable = false
	local hit = false
	local function collect(n: any, acc: { string })
		if type(n) ~= "table" then
			return
		end
		if type(n.value) == "string" and n.value ~= "" then
			table.insert(acc, n.value)
		end
		if type(n.text) == "string" and n.text ~= "" then
			table.insert(acc, n.text)
		end
		for _, kid in ipairs(n.children or {}) do
			collect(kid, acc)
		end
	end
	local function walk(n: any)
		if hit or type(n) ~= "table" then
			return
		end
		if n.role == "MultilineTextInput" then
			local readonly = false
			for _, st in ipairs(n.states or {}) do
				if st == "readonly" then
					readonly = true
				end
			end
			if not readonly then
				found = true
				local parts: { string } = {}
				collect(n, parts)
				local text = table.concat(parts, "")
				if text ~= "" then
					readable = true
					local flat = string.gsub(text, "%s+", "")
					if string.find(flat, marker, 1, true) then
						hit = true
					end
				end
			end
		end
		for _, kid in ipairs(n.children or {}) do
			walk(kid)
		end
	end
	walk(view)
	if not found or not readable then
		return nil
	end
	return hit
end

--- 把正文填进某个 agent 的输入框，不提交。
--- 用 cx:run 逐字打进 pane（多行包成括号粘贴），用户看过、补完再自己按回车。
--- 只负责送；「填进去了没有」由调用方读回核对（surface 的输入框要下一拍才更新）。
local function fillAgent(cx: WindowCx, pane: number, body: string): string?
	local isAgent = false
	for _, agent in ipairs(cx.agents:list()) do
		if agent.pane == pane then
			isAgent = true
			if agent.delivery_error then
				return tostring(agent.delivery_error)
			end
			break
		end
	end
	if not isAgent then
		return "找不到那个 agent"
	end
	local ok, err = pcall(function()
		cx:run(pane, pasteText(body))
	end)
	if not ok then
		return tostring(err)
	end
	return nil
end

--- 写剪贴板：cx:copy 不返回值，只能区分「抛错」与「没抛错」。
--- 返回错误说明；nil 表示没报错（不保证内容真进去了）。
--- 真机上出现过复制静默失败，所以任何「已复制」的提示都必须经过这里，
--- 抛错时要如实说出来，不能一律报成功。
local function copyOrErr(cx: WindowCx, body: string): string?
	local ok, err = pcall(function()
		cx:copy(body)
	end)
	if ok then
		return nil
	end
	return tostring(err)
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
		cx:prompt({ placeholder = "owner/repo", value = action.body, icon = "list" }):next(function(repo, _err, cx)
			if not repo or not cx then
				return
			end
			repo = string.gsub(repo, "^%s+", "")
			repo = string.gsub(repo, "%s+$", "")
			if repo == "" then
				-- 空串 = 恢复跟随当前目录的 git remote。
				tern.kv.set(REPO_KEY, { repo = "", pane = pane })
				cx:toast("info", "恢复跟随当前目录", "按刷新重新识别仓库")
				return
			end
			local normalized = util.parseRemoteUrl(repo)
			if not normalized then
				cx:toast("error", "仓库格式不对", "填 owner/repo 或 GitHub 链接")
				return
			end
			repo = normalized
			-- 带上 pane：手动指定的仓库只对本窗口有效。
			-- 不绑 pane 的话，所有窗口都会读到这一份，新项目里开面板会显示别的仓库。
			tern.kv.set(REPO_KEY, { repo = repo, pane = pane })
			cx:toast("success", "仓库：" .. repo, "按面板里的 r 刷新")
		end)
		return
	end

	-- open-doc：把本地后端的票 / 地图 / 规格文件调进 tern 的文档视图，
	-- 人在那里改（平台自带撤销、自动保存、原子写）。路径由宿主按扫描结果给出。
	if action.kind == "open-doc" then
		local opened, paneOrErr = pcall(function()
			return cx.docs:open(action.body, { how = "tab" })
		end)
		-- 回执走 kv：宿主据此把「已请求打开」改成「已打开」或失败原因，
		-- 光靠 toast 会一闪而过，用户回头看不到结果。
		local okOpen = opened and paneOrErr ~= nil
		pcall(function()
			tern.kv.set(INJECT_RESULT_KEY, {
				seq = seq,
				ok = okOpen,
				name = tostring(action.name or ""),
				error = if okOpen then "" else tostring(paneOrErr),
			})
			cx.session:event(pane, { ev = "action", id = "main.refresh", act = "refresh" })
		end)
		if okOpen then
			cx:toast("info", "已打开文档：" .. tostring(action.name or ""), "改完回面板按 r 刷新。")
		else
			cx:toast("error", "打开文档失败", tostring(paneOrErr))
		end
		return
	end

	-- compose：只把内容放进剪贴板，连输入框都不碰。
	-- 技能面板双击走这条，用于「想换个地方贴」的场景。
	if action.kind == "compose" then
		local err = copyOrErr(cx, action.body)
		if err then
			cx:toast("error", "复制失败：" .. tostring(action.name or ""), err)
			return
		end
		cx:toast("info", "已复制：" .. tostring(action.name or ""), "粘到输入框再决定发不发。")
		return
	end

	if action.kind == "ask" then
		-- 「发送」通道：原生 omp 只认 ask，能真正进输入框并提交。
		local target = (if pane then agentFor(cx, pane) else nil) or lastAgent or agentPaneOf(cx)
		if not target then
			local copyErr = copyOrErr(cx, action.body)
			local tail = if copyErr then "剪贴板也写不进去：" .. copyErr else "正文已复制到剪贴板。"
			cx:toast("info", "没有可用的 agent", tail)
			pcall(function()
				tern.kv.set(INJECT_RESULT_KEY, { seq = seq, ok = false, name = tostring(action.name or ""), error = "没有可用的 agent（" .. tail .. "）" })
				cx.session:event(pane, { ev = "action", id = "main.refresh", act = "refresh" })
			end)
			return
		end
		local sent, sendErr = pcall(function()
			cx.agents:ask(target, action.body)
		end)
		pcall(function()
			tern.kv.set(INJECT_RESULT_KEY, {
				seq = seq,
				ok = sent,
				name = tostring(action.name or ""),
				error = if sent then "" else tostring(sendErr),
			})
			cx.session:event(pane, { ev = "action", id = "main.refresh", act = "refresh" })
		end)
		if sent then
			cx:toast("success", "已发送：" .. tostring(action.name or ""), "正文已进 agent 输入框并提交。")
		else
			cx:toast("error", "发送失败：" .. tostring(action.name or ""), tostring(sendErr))
		end
		return
	end

	if action.kind ~= "inject" then
		return
	end

	-- 结果回写：宿主不能自己下"成功"的结论，填入可能失败。
	-- 写回后戳宿主一下，让它重画（否则提示停在"填入中"）。
	local function report(ok: boolean, err: string?)
		pcall(function()
			tern.kv.set(INJECT_RESULT_KEY, {
				seq = seq,
				ok = ok,
				name = tostring(action.name or ""),
				error = err or "",
			})
		end)
		-- 通知宿主重画：往 pane 发一个 action 事件，宿主的 event 处理里会读 kv。
		-- id 必须指向真实节点 —— 宿主那边是工具条上的「刷新」按钮（key = "refresh"），
		-- 节点 id 是 <区块>.<区域>.<按钮key>。用编造的 id 事件会被丢掉，提示会停在「填入中」。
		pcall(function()
			cx.session:event(pane, { ev = "action", id = "main.refresh", act = "refresh" })
		end)
	end

	local agent = (if pane then agentFor(cx, pane) else nil) or lastAgent or agentPaneOf(cx)
	if not agent then
		-- 没有 agent 就退到剪贴板，别让用户白点一次。
		local copyErr = copyOrErr(cx, action.body)
		local tail = if copyErr then "剪贴板也写不进去：" .. copyErr else "正文已复制到剪贴板。"
		cx:toast("info", "没有可用的 agent", tail)
		report(false, "没有可用的 agent（" .. tail .. "）")
		return
	end
	local err = fillAgent(cx, agent, action.body)
	if err then
		local copyErr = copyOrErr(cx, action.body)
		local tail = if copyErr then "剪贴板复制也失败：" .. copyErr else "正文已复制"
		cx:toast("error", "填入失败：" .. tostring(action.name or ""), err .. "（" .. tail .. "）")
		report(false, err .. "（" .. tail .. "）")
		return
	end
	local marker = markerOf(action.body)
	-- 原生 omp 的输入框在 surface 里，且 cx:run 之后要下一拍才出现正文（实测 <= 300ms），
	-- 立刻读必然是空框。所以先确认这条路可读，再隔一拍核对。
	-- 非焦点 / 隐藏 tab 的 chat 读到的 text 是空串（composer 不在实时 surface 里），
	-- 所以「读成空框」只有在它正是焦点块时才算真失败，否则判不了、按成功算。
	if surfaceComposerText(cx, agent) ~= nil then
		tern.timer(VERIFY_MS, function(nextCx)
			local c: WindowCx = nextCx or cx
			local text = surfaceComposerText(c, agent)
			local focused = false
			pcall(function()
				focused = c.session:focused() == agent
			end)
			local live = text ~= nil and (text ~= "" or focused)
			if text ~= nil and not textHas(text, marker) and live then
				local copyErr = copyOrErr(c, action.body)
				local tail = if copyErr then "剪贴板复制也失败：" .. copyErr else "正文已复制"
				c:toast("error", "填入失败：" .. tostring(action.name or ""), "输入框没收到正文（" .. tail .. "）")
				report(false, "输入框没收到正文（" .. tail .. "）")
				return
			end
			c:toast("success", "已填入输入框：" .. tostring(action.name or ""), "看过、补完自己提交。")
			report(true, nil)
		end)
		return
	end
	local delivered = composerHas(cx, agent, marker)
	if delivered == false then
		local copyErr = copyOrErr(cx, action.body)
		local tail = if copyErr then "剪贴板复制也失败：" .. copyErr else "正文已复制"
		cx:toast("error", "填入失败：" .. tostring(action.name or ""), "输入框没收到正文（" .. tail .. "）")
		report(false, "输入框没收到正文（" .. tail .. "）")
		return
	end
	cx:toast("success", "已填入输入框：" .. tostring(action.name or ""), "看过、补完自己提交。")
	report(true, nil)
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
		end)
	end
	tern.timer(POLL_MS, poll)
end

tern.command({
	id = "panel",
	title = "Matt 面板",
	icon = "list",
	run = openPanel,
})

tern.command({
	id = "skills",
	title = "技能速览",
	icon = "sparkle",
	run = function(cx: WindowCx)
		local resolved = paths.resolvePackage()
		local root = resolved and resolved.root
		if not root then
			cx:toast(
				"info",
				"没找到中文技能包",
				"安装：https://github.com/devcxl/mattpocock-skills-zh"
			)
			return
		end
		local pkg = skills.readPackage(root, resolved and resolved.version)
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
			local copyErr = copyOrErr(cx, item.body)
			local agent = lastAgent or agentPaneOf(cx)
			if not agent then
				if copyErr then
					cx:toast("error", "没有聚焦的 agent", "剪贴板也写不进去：" .. copyErr)
					return
				end
				cx:toast("info", "已复制：" .. item.label, "没有聚焦的 agent")
				return
			end
			local err = fillAgent(cx, agent, item.body)
			if err then
				cx:toast("error", "填入失败：" .. item.label, err)
				return
			end
			cx:toast("success", "已填入输入框：" .. item.label)
		end)
	end,
})

--- 胶囊只当插件入口：不显示任何数字。
--- 数字会随「当前是哪个仓库」变，而胶囊是窗口级的，切 tab 后对不上就是错的。
tern.chrome.status(function(_pane)
	local text = "Matt"
	if cachedVersion and cachedVersion ~= "" then
		text = "Matt " .. cachedVersion
	end
	return {
		{
			text = text,
			icon = "list",
			command = "plugin.tern-matt-panel.panel",
		},
	}
end)

--- 聚焦时提醒面板「可以刷了」。
--- 只戳「刚拿到焦点的那个 tab」里的面板：别的 tab 里开着的面板不该跟着刷，
--- 否则每个 tab 各开一个面板时，一次切 tab 会把所有面板同时拉一遍。
--- 拉不拉仍由宿主按 5 分钟节流，这里只负责把「这个 tab 亮了」这个事实传过去。
local function pingPanelsInTab(cx: WindowCx, tab: number)
	local ok, panes = pcall(cx.session.panes, cx.session)
	if not ok or type(panes) ~= "table" then
		return
	end
	for _, p in ipairs(panes) do
		-- 插件块的 program 就是「插件id.块id」（见 tern ls）
		if p.tab == tab and (p.program == KIND or p.kind == KIND) then
			pcall(function()
				cx.session:event(p.pane, { ev = "action", id = "main.refresh", act = "auto-reload" })
			end)
		end
	end
end

tern.on("focus", function(ev: any, cx)
	-- 重读版本并刷新状态栏胶囊；读失败保留上次值。
	pcall(function()
		local resolved, err = paths.resolvePackage()
		if resolved and resolved.version and resolved.version ~= "" then
			cachedVersion = resolved.version
		elseif not err then
			cachedVersion = nil
		end
	end)
	pcall(function() tern.chrome.refresh() end)
	rememberAgent(cx)
	if ev and type(ev.tab) == "number" then
		pingPanelsInTab(cx, ev.tab)
	end
end)

-- 窗口重启后第一次看到的请求当作已处理，避免重复注入。
do
	local ok, action = pcall(tern.kv.get, ACTION_KEY)
	if ok and type(action) == "table" and type(action.seq) == "number" then
		seenSeq = action.seq
	end
end

do
	pcall(function()
		local resolved = paths.resolvePackage()
		if resolved and resolved.version and resolved.version ~= "" then
			cachedVersion = resolved.version
		end
	end)
end

-- 轮询从加载就开始：面板可以随时打开（也可能已经开着）。
tern.timer(POLL_MS, poll)
