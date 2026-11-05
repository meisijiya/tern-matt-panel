--!strict
-- 纯逻辑工具：trim / startsWith / splitLines / slug / deepCopy / contains。
-- 不依赖 tern，可在 luau CLI 下单测。v1 不做文本编辑，故不含 UTF-16 光标那套。

local M = {}

--- 去掉首尾空白。
function M.trim(s: string): string
	return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- 字符串是否以 prefix 开头。
function M.startsWith(s: string, prefix: string): boolean
	return string.sub(s, 1, #prefix) == prefix
end

--- 按行切分，兼容 \r\n 与 \n，去掉行尾 \r。
function M.splitLines(s: string): { string }
	local out: { string } = {}
	local start = 1
	while start <= #s do
		local nl = string.find(s, "\n", start, true)
		if nl then
			local line = s:sub(start, nl - 1)
			if line:sub(-1) == "\r" then
				line = line:sub(1, -2)
			end
			table.insert(out, line)
			start = nl + 1
		else
			local line = s:sub(start)
			if line:sub(-1) == "\r" then
				line = line:sub(1, -2)
			end
			table.insert(out, line)
			break
		end
	end
	return out
end

--- slug：小写字母数字，其余折成单个连字符。
function M.slug(s: string): string
	local out = ""
	local dash = false
	for i = 1, #s do
		local c = s:sub(i, i):lower()
		if c:match("[a-z0-9]") then
			out ..= c
			dash = false
		elseif not dash and out ~= "" then
			out ..= "-"
			dash = true
		end
	end
	return (out:gsub("-+$", ""))
end

--- 深拷贝一张表（仅 JSON 兼容的值）。
function M.deepCopy<T>(v: T): T
	if type(v) ~= "table" then
		return v
	end
	local out = {}
	for k, val in v do
		out[k] = M.deepCopy(val)
	end
	return out
end

--- 数组里的某项是否存在。
function M.contains(list: { any }, needle: any): boolean
	for _, v in ipairs(list) do
		if v == needle then
			return true
		end
	end
	return false
end

--- 从 git remote 的 URL 里取 owner/repo。
--- 认这些形状：git@github.com:o/r.git、https://github.com/o/r.git、
--- ssh://git@host/o/r、以及不带 .git 后缀的网页地址。
--- 认不出返回 nil —— 调用方据此退到手动指定，而不是拿半个地址去查。
function M.parseRemoteUrl(url: string): string?
	local u = M.trim(url)
	if u == "" then
		return nil
	end
	-- 去掉末尾斜杠，避免 `/repo/` 被当成空 repo
	u = (u:gsub("/+$", ""))
	-- .git 后缀可有可无
	local base = (u:gsub("%.git$", ""))
	local owner, repo = string.match(base, "[:/]([%w_.-]+)/([%w_.-]+)$")
	if owner and repo then
		return owner .. "/" .. repo
	end
	return nil
end

return M
