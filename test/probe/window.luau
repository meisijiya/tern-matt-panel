-- 真机注入探针（不随插件发布，只给 test/probe-inject.sh 用）。
--
-- 分工：脚本写 kv 请求 {pane, out, marker, nonce}；这里只有拥有该 pane 的窗口动作，
-- 发一次括号粘贴、延迟 320ms 读 composer，把结果写到 out，然后回写 done_nonce。
-- 为什么不在脚本里直接调 cx:run：cx 只有窗口半边有，脚本够不到。

local KEY = "request"
local DONE = "done_nonce"
local VERIFY_MS = 320

--- 输入框正文：认 composer role 或 omp 的 .line/input，读不到返回 nil。
local function composerText(cx: any, pane: number): string?
	local ok, surface = pcall(function()
		return cx.session:surface(pane, { depth = 60, nodes = 5000 })
	end)
	if not ok or type(surface) ~= "table" then
		return nil
	end
	local marked: string? = nil
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
	return marked
end

local function poll(cx: any)
	if not cx then
		return
	end
	-- 顺手公布本机 agent 块，给脚本挑目标（tern ls 不给 command，认不出 omp）。
	pcall(function()
		local list = cx.agents:list()
		local panes = {}
		for _, a in ipairs(list) do
			table.insert(panes, a.pane)
		end
		tern.kv.set("agents", { panes = panes })
	end)
	pcall(function()
		local req = tern.kv.get(KEY)
		if type(req) ~= "table" or type(req.pane) ~= "number" or type(req.out) ~= "string" then
			return
		end
		if tern.kv.get(DONE) == req.nonce then
			return
		end
		-- 只在这个窗口真能看到该 pane 时动作：surface 读得到才算本窗口的块。
		-- （cx.agents:list 是跨会话的，不能拿它判归属。）
		local mine = false
		pcall(function()
			mine = type(cx.session:surface(req.pane, { depth = 1, nodes = 1 })) == "table"
		end)
		if not mine then
			return
		end
		local before = composerText(cx, req.pane)
		local body = "\27[200~" .. tostring(req.marker) .. "\nPROBE_LINE2\27[201~"
		pcall(function()
			cx:run(req.pane, body)
		end)
		tern.timer(VERIFY_MS, function(nextCx)
			local c = nextCx or cx
			local after = composerText(c, req.pane)
			local focused = false
			pcall(function()
				focused = c.session:focused() == req.pane
			end)
			local out = {
				pane = req.pane,
				marker = req.marker,
				nonce = req.nonce,
				before = before,
				after = after,
				focused = focused,
				ok = type(after) == "string"
					and string.find(after, req.marker, 1, true) ~= nil
					and string.find(after, "PROBE_LINE2", 1, true) ~= nil,
			}
			pcall(function()
				tern.fs.write(req.out, tern.json.encode(out, true))
			end)
			pcall(function()
				tern.kv.set(DONE, req.nonce)
			end)
		end)
	end)
	tern.timer(700, poll)
end

tern.timer(700, poll)
