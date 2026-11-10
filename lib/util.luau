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

--- 终端列宽：CJK / 全角 / 假名 / 韩文按 2 列，其余 1 列。
--- 只用于排版预算，不追求 Unicode 完整性（组合字符、ZWJ 都不处理）。
function M.textWidth(s: string): number
	local w = 0
	for _, code in utf8.codes(s) do
		if code >= 0x1100 then
			w += 2
		else
			w += 1
		end
	end
	return w
end

--- 把一串宽度装进 cols 列：贪心换行，每项之间算 gap 列。
--- 单项比 cols 还宽时也独占一行（宁可溢出，不能凭空丢按钮）。
function M.packRows(widths: { number }, cols: number, gap: number): { { number } }
	local rows: { { number } } = {}
	local cur: { number } = {}
	local used = 0
	for i, w in ipairs(widths) do
		local need = if #cur == 0 then w else used + gap + w
		if #cur > 0 and need > cols then
			table.insert(rows, cur)
			cur = {}
			used = 0
			need = w
		end
		table.insert(cur, i)
		used = need
	end
	if #cur > 0 then
		table.insert(rows, cur)
	end
	return rows
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

--- 陈旧判据：只有 now/fetchedAt 都是 number 且 now - fetchedAt > threshold 才 true。
function M.isStale(now: any, fetchedAt: any, threshold: number): boolean
	if type(now) ~= "number" then
		return false
	end
	if type(fetchedAt) ~= "number" then
		return false
	end
	return (now - fetchedAt) > threshold
end


return M
