--!strict
-- 技能包发现：定位本机已装的中文 mattpocock 技能组根目录，读其版本。
-- 只读探测；失败返回 nil，让上层显示安装提示而非崩。
-- 仅本文件使用 tern.*（fs / getenv）。

local M = {}

M.REGISTRY_KEY = "mattpocock-skills@mattpocock"

--- 取 home 目录：Windows 用 USERPROFILE，其余用 HOME；tern.fs 不展开 ~。
function M.home(): string?
	local p = tern.getenv("USERPROFILE")
	if p and p ~= "" then
		return p
	end
	return tern.getenv("HOME")
end

--- 把路径里的反斜杠统一成正斜杠。
local function norm(p: string): string
	return (p or ""):gsub("\\", "/")
end

--- 从 omp 安装登记文本里取本技能包条目的 {installPath, version}。
--- 只扫完整 JSON 对象（字符串值无嵌套）；半截/缺字段返回 nil；
--- 多条目取第一个有 installPath 的条目。
function M.parseRegistryEntry(text: any, key: any): { installPath: string, version: string? }?
	if type(text) ~= "string" or type(key) ~= "string" then
		return nil
	end
	local ki = text:find(key, 1, true)
	if not ki then
		return nil
	end
	local colon = text:find(":", ki + #key)
	if not colon then
		return nil
	end
	-- 跳过空白
	local i = colon + 1
	while i <= #text and (text:sub(i, i) == " " or text:sub(i, i) == "\t" or text:sub(i, i) == "\n" or text:sub(i, i) == "\r") do
		i += 1
	end
	if i > #text then
		return nil
	end
	local region = nil
	if text:sub(i, i) == "[" then
		local close = text:find("]", i)
		if not close then
			return nil
		end
		region = text:sub(i + 1, close - 1)
	elseif text:sub(i, i) == "{" then
		local close = text:find("}", i)
		if not close then
			return nil
		end
		region = text:sub(i, close)
	else
		return nil
	end
	-- 在 region 内扫完整对象，取第一个有 installPath 的
	local pos = 1
	while true do
		local b = region:find("{", pos)
		if not b then
			break
		end
		local c = region:find("}", b)
		if not c then
			break
		end
		local obj = region:sub(b, c)
		local ip = obj:match('"installPath"%s*:%s*"(.-)"')
		local ver = obj:match('"version"%s*:%s*"(.-)"')
		if ip and ip ~= "" then
			return { installPath = ip, version = ver }
		end
		pos = c + 1
	end
	return nil
end

--- 解析安装登记：登记副本优先；副本不存在回退市场克隆；再不行保留 cache/plugins 扫描。
--- 第二个返回值 "registry-unreadable" 表示登记里有本包条目但读不出（调用方保留上次值）。
function M.resolvePackage(): ({ root: string, version: string? }?, string?)
	local home = M.home()
	-- 1. 登记
	local entry = nil
	local regExists = false
	local hasKey = false
	if home then
		local regPath = home .. "/.omp/plugins/installed_plugins.json"
		local ok, text = pcall(tern.fs.read, regPath)
		if ok and type(text) == "string" then
			regExists = true
			hasKey = text:find(M.REGISTRY_KEY, 1, true) ~= nil
			entry = M.parseRegistryEntry(text, M.REGISTRY_KEY)
		end
	end
	if entry and entry.installPath and entry.installPath ~= "" then
		local root = norm(entry.installPath)
		local exists = false
		pcall(function() exists = tern.fs.exists(root) end)
		if exists then
			local version = entry.version
			if not version or version == "" then
				version = M.packageVersion(root)
			end
			return { root = root, version = version }
		end
		-- 副本不存在：继续往市场克隆回退。
	end
	-- key 存在但条目解析不出 → 读失败，保留上次值，不切换到别的副本。
	if regExists and hasKey and entry == nil then
		return nil, "registry-unreadable"
	end
	-- 登记文件不存在或没有本包条目：市场克隆回退
	if home then
		local market = norm(home .. "/.omp/plugins/cache/marketplaces/mattpocock")
		local exists = false
		pcall(function() exists = tern.fs.exists(market) end)
		if exists then
			return { root = market, version = M.packageVersion(market) }
		end
	end
	-- 3. cache/plugins 扫描兜底
	if home then
		local plugins = norm(home .. "/.omp/plugins/cache/plugins")
		local exists = false
		pcall(function() exists = tern.fs.exists(plugins) end)
		if exists then
			local ok, names = pcall(tern.fs.list, plugins)
			if ok then
				for _, name in ipairs(names) do
					if name:match("^mattpocock___mattpocock%-skills__") then
						local r = plugins .. "/" .. name
						return { root = r, version = M.packageVersion(r) }
					end
				end
			end
		end
	end
	return nil
end

--- 探测技能包根：现在委托 resolvePackage，保持兼容。
function M.skillPackageRoot(): string?
	local p = M.resolvePackage()
	if p then
		return p.root
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

export type SkillProbe = {
	-- home 目录；nil 时跳过所有 home 下的通道。
	home: string?,
	-- 技能名（面板用 /skill:名字 调用的那个）。
	name: string,
	-- 面板当前仓库根；nil 时跳过项目级通道。
	projectRoot: string?,
	-- omp 安装登记原文；nil 表示没有登记文件。
	registryText: string?,
	-- 登记里的键；nil 表示不查登记这条通道。
	registryKey: string?,
	-- marketplace 缓存目录名前缀（<id>___）；nil 表示不扫缓存。
	cachePrefix: string?,
}

export type SkillHit = {
	-- 副本根目录。
	root: string,
	-- 命中哪条通道（状态文案与排查用）。
	source: string,
	-- 版本；登记/package.json/frontmatter 都取不到时是 nil（不等于「未装」）。
	version: string?,
}

--- 路径在不在。探针抛错按「不在」算：探测不能崩。
function M.pathExists(path: string): boolean
	if path == "" then
		return false
	end
	local ok, v = pcall(tern.fs.exists, path)
	return ok and v == true
end

--- 读 SKILL.md frontmatter 里的版本号；没有就 nil。
--- 只看 frontmatter 段，正文里的 version: 不算数。
function M.docVersion(path: string): string?
	local ok, text = pcall(tern.fs.read, path)
	if not ok or type(text) ~= "string" then
		return nil
	end
	local head = text:match("^%-%-%-%s*\r?\n(.-)\r?\n%-%-%-")
	if not head then
		return nil
	end
	local v = head:match("version:%s*[\"']?([^\"'\r\n]+)")
	if not v then
		return nil
	end
	v = v:match("^%s*(.-)%s*$") or v
	if v == "" then
		return nil
	end
	return v
end

--- 版本兜底：package.json → 技能目录里的 SKILL.md → 插件包的 skills/<name>/SKILL.md。
function M.versionFromDir(root: string, name: string): string?
	local v = M.packageVersion(root)
	if v and v ~= "" then
		return v
	end
	local v2 = M.docVersion(root .. "/SKILL.md")
	if v2 then
		return v2
	end
	return M.docVersion(root .. "/skills/" .. name .. "/SKILL.md")
end

--- 找外部技能在本机的副本。
--- 通道顺序固定：登记 → omp 技能目录 → skills CLI 全局 → skills CLI 项目级
--- → Claude 技能目录 → marketplace 缓存兜底。同一技能多份副本只出一个：
--- 第一个命中的通道说了算。
--- 软链按「目标存在即跟随」处理；断链或目标不在 → 不命中，继续下一档。
function M.findSkillDir(p: SkillProbe): SkillHit?
	local name = p.name
	if name == "" then
		return nil
	end
	local home = p.home
	local root0 = p.projectRoot
	-- 1. 安装登记：登记里的版本优先于目录里的 package.json。
	if p.registryKey and p.registryText then
		local entry = M.parseRegistryEntry(p.registryText, p.registryKey)
		if entry and entry.installPath and entry.installPath ~= "" then
			local root = norm(entry.installPath)
			if M.pathExists(root) then
				local version = entry.version
				if not version or version == "" then
					version = M.versionFromDir(root, name)
				end
				return { root = root, source = "登记", version = version }
			end
		end
	end
	-- 2. 目录通道：按优先级第一个存在的就是它。
	local dirs: { { path: string, label: string } } = {}
	if home then
		table.insert(dirs, { path = home .. "/.omp/agent/skills/" .. name, label = "omp 技能目录" })
		table.insert(dirs, { path = home .. "/.agents/skills/" .. name, label = "skills CLI 全局" })
	end
	if root0 then
		table.insert(dirs, { path = root0 .. "/.agents/skills/" .. name, label = "skills CLI 项目级" })
	end
	if home then
		table.insert(dirs, { path = home .. "/.claude/skills/" .. name, label = "Claude 技能目录" })
	end
	for _, d in ipairs(dirs) do
		local path = norm(d.path)
		if M.pathExists(path) then
			return { root = path, source = d.label, version = M.versionFromDir(path, name) }
		end
	end
	-- 3. marketplace 缓存兜底：目录名形如 <前缀>___<来源>___<版本>。
	if p.cachePrefix and home then
		local dir = norm(home .. "/.omp/plugins/cache/plugins")
		local ok, names = pcall(tern.fs.list, dir)
		if ok and type(names) == "table" then
			for _, n in ipairs(names) do
				if string.sub(n, 1, #p.cachePrefix) == p.cachePrefix then
					local root = dir .. "/" .. n
					return { root = root, source = "marketplace 缓存", version = M.versionFromDir(root, name) }
				end
			end
		end
	end
	return nil
end

return M
