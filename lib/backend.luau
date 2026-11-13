--!strict
-- 后端判定：目标仓库的跟踪器约定文件决定用 GitHub 还是本地 markdown。
--
-- 面板不是选择的持有者（ADR-0003）：没有模式切换，也不保存手动选择。
-- 顺序是「约定文件声明 > 可观察证据识别」，界面要显示依据来源。
-- 约定文件只认高置信标题行（`# Issue tracker: …` / `# Issue 跟踪器：…`），
-- 不全文扫关键词 —— 正文里提一句 GitHub 不算声明。

local util = require("./util")

local M = {}

export type Decision = {
	backend: string?, -- "github" | "local"；nil = 判不出来
	source: string?, -- "contract" | "detected"；nil = 没依据
	reason: string, -- 给人看的一句话依据 / 失败原因
}

--- 从约定文件正文取声明的后端。
--- 返回 (backend, declared)：backend 为 nil 时 declared 仍是声明的原文，
--- 用来区分「没声明」与「声明了面板不支持的后端」。
function M.parseContract(text: string?): (string?, string?)
	if not text then
		return nil, nil
	end
	for _, line in ipairs(util.splitLines(text)) do
		local heading = string.match(line, "^#%s+(.-)%s*$")
		if heading then
			-- 全角冒号是多字节，不能塞进字符类（那样只会匹配到它的首字节）。
			local value = string.match(heading, "^[Ii]ssue%s*[Tt]racker%s*:(.*)$")
				or string.match(heading, "^[Ii]ssue%s*[Tt]racker%s*：(.*)$")
				or string.match(heading, "^Issue%s*跟踪器%s*:(.*)$")
				or string.match(heading, "^Issue%s*跟踪器%s*：(.*)$")
			if value then
				value = util.trim(value)
				local v = value:lower()
				if string.find(v, "github", 1, true) then
					return "github", value
				end
				if string.find(v, "local", 1, true) or string.find(v, "本地", 1, true)
					or string.find(v, "markdown", 1, true) then
					return "local", value
				end
				return nil, value
			end
		end
	end
	return nil, nil
end

--- origin 是否指向 GitHub：只认地址里带 github.com 的。
--- 裸 owner/repo 不算证据 —— 那是面板手动输入框的写法，不会出现在 git remote 里。
function M.isGithubRemote(url: string?): boolean
	if not url then
		return false
	end
	local u = util.trim(url):lower()
	return u ~= "" and string.find(u, "github.com", 1, true) ~= nil
end

--- 判后端。约定文件缺失或声明读不懂时才看可观察证据。
function M.decide(opts: { contractText: string?, originUrl: string?, hasScratch: boolean }): Decision
	local backend, declared = M.parseContract(opts.contractText)
	if backend then
		return {
			backend = backend,
			source = "contract",
			reason = "约定文件 " .. M.CONTRACT_PATH,
		}
	end
	if declared then
		return {
			backend = nil,
			source = nil,
			reason = "约定文件声明的是「" .. declared .. "」，面板只支持 GitHub 与本地 markdown",
		}
	end
	if M.isGithubRemote(opts.originUrl) then
		return { backend = "github", source = "detected", reason = "origin 指向 GitHub" }
	end
	if opts.hasScratch then
		return { backend = "local", source = "detected", reason = "仓库里有 " .. ".scratch 目录" }
	end
	return {
		backend = nil,
		source = nil,
		reason = "没找到跟踪器约定文件，也没有 origin 或 .scratch 可作依据",
	}
end

M.CONTRACT_PATH = "docs/agents/issue-tracker.md"

return M
