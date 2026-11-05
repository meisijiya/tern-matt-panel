--!strict
-- 技能包发现：定位本机已装的中文 mattpocock 技能组根目录，读其版本。
-- 只读探测；失败返回 nil，让上层显示安装提示而非崩。
-- 仅本文件使用 tern.*（fs / getenv）。

local M = {}

--- 取 home 目录：Windows 用 USERPROFILE，其余用 HOME；tern.fs 不展开 ~。
function M.home(): string?
	local p = tern.getenv("USERPROFILE")
	if p and p ~= "" then
		return p
	end
	return tern.getenv("HOME")
end

--- 探测技能包根：先 marketplaces/mattpocock，再 plugins 下找 mattpocock___mattpocock-skills__*。
--- 任一命中即返回，都不在返回 nil。
function M.skillPackageRoot(): string?
	local home = M.home()
	if not home then
		return nil
	end
	local market = home .. "/.omp/plugins/cache/marketplaces/mattpocock"
	if pcall(tern.fs.exists, market) and tern.fs.exists(market) then
		return market
	end
	local plugins = home .. "/.omp/plugins/cache/plugins"
	if not pcall(tern.fs.exists, plugins) or not tern.fs.exists(plugins) then
		return nil
	end
	local ok, names = pcall(tern.fs.list, plugins)
	if not ok then
		return nil
	end
	for _, name in ipairs(names) do
		if name:match("^mattpocock___mattpocock%-skills__") then
			return plugins .. "/" .. name
		end
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
