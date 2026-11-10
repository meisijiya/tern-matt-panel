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
function M.resolvePackage(): { root: string, version: string? }?
	local home = M.home()
	-- 1. 登记
	local entry = nil
	if home then
		local regPath = home .. "/.omp/plugins/installed_plugins.json"
		local ok, text = pcall(tern.fs.read, regPath)
		if ok and type(text) == "string" then
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
	end
	-- 2. 市场克隆
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

return M
