--!strict
-- 外部技能包清单：面板引用了哪些包、怎么发现、装没装、什么版本。
-- 纯逻辑：只做表与判定；文件探测、网络检查都在宿主半边。
-- 安装指引照抄上游原文，不自造命令。

local M = {}

export type Pack = {
	id: string,
	title: string,
	-- 面板为什么引用它：一句话说清用途，用户据此判断要不要装。
	purpose: string,
	-- owner/repo，用于仓库链接与「待更新」检查。
	repo: string,
	-- 在 omp 安装登记里的键；nil 表示只按本地目录探测。
	registryKey: string?,
	-- 相对 home 的安装根；registryKey 为 nil 时用。
	localRel: string?,
	-- 安装指引，逐行可复制。
	install: { string },
}

M.PACKS = {
	{
		id = "mattpocock",
		title = "mattpocock 技能组",
		purpose = "入口到交付的技能链；面板的技能视图与泳道都来自它",
		repo = "devcxl/mattpocock-skills-zh",
		registryKey = "mattpocock-skills@mattpocock",
		install = {
			"git clone https://github.com/devcxl/mattpocock-skills-zh",
		},
	},
	{
		id = "answer-me-with-html",
		title = "answer-me-with-html",
		purpose = "把结论渲染成单页可视化；收尾报告用它出图",
		repo = "QingYunA/answer-me-with-html",
		registryKey = "answer-me-with-html@answer-me-with-html",
		install = {
			"claude plugin marketplace add QingYunA/answer-me-with-html",
			"claude plugin install answer-me-with-html@answer-me-with-html",
		},
	},
	{
		id = "omp-skill-forge",
		title = "omp-skill-forge",
		purpose = "选路表与分支、发布、评审技能；模板在选技能时引用它",
		repo = "meisijiya/omp-skill-forge",
		localRel = ".omp/agent/local/omp-skill-forge",
		install = {
			"python tools/deploy.py",
			"omp plugin link ~/.omp/agent/local/omp-skill-forge",
		},
	},
}
export type PackState = {
	id: string,
	title: string,
	purpose: string,
	repo: string,
	url: string,
	install: { string },
	installed: boolean,
	version: string?,
	-- 状态文案：未装 / 已装 / 待更新 / 已是最新 / 本地较新 / 无法比较 / 检查失败
	status: string,
	-- 上游最新版本（检查成功后才有）
	latest: string?,
	-- 上次成功检查的时刻文案；检查失败时状态里引用它
	checkedAt: string?,
	-- 上次检查是否失败；失败时保留上一次的 latest
	failed: boolean,
}

--- 仓库链接：统一 HTTPS 形态，点开就是仓库主页。
function M.repoUrl(repo: string): string
	return "https://github.com/" .. repo
end

--- 由宿主探到的 {已装, 版本} 造一条展示用状态。
function M.stateOf(pack: Pack, installed: boolean, version: string?): PackState
	local status = if installed then "已装" else "未装"
	return {
		id = pack.id,
		title = pack.title,
		purpose = pack.purpose,
		repo = pack.repo,
		url = M.repoUrl(pack.repo),
		install = pack.install,
		installed = installed,
		version = version,
		status = status,
		latest = nil,
		checkedAt = nil,
		failed = false,
	}
end

--- 版本段：先去掉 v 前缀，再取数字段。取不到数字视为不可比较。
local function versionParts(v: string): { number }?
	local s = v:gsub("^%s*[vV]", "")
	local parts: { number } = {}
	for seg in string.gmatch(s, "%d+") do
		table.insert(parts, tonumber(seg) :: number)
	end
	if #parts == 0 then
		return nil
	end
	return parts
end

--- 本地与上游比较：older / same / newer / unknown。
function M.compareVersion(localVersion: string?, remoteVersion: string?): string
	if not localVersion or localVersion == "" or not remoteVersion or remoteVersion == "" then
		return "unknown"
	end
	local a = versionParts(localVersion)
	local b = versionParts(remoteVersion)
	if not a or not b then
		return "unknown"
	end
	local n = math.max(#a, #b)
	for i = 1, n do
		local x = a[i] or 0
		local y = b[i] or 0
		if x < y then
			return "older"
		elseif x > y then
			return "newer"
		end
	end
	return "same"
end

--- gh 的输出就是一行 tag；空输出表示没查到。
function M.tagFromOutput(text: string?): string?
	if type(text) ~= "string" then
		return nil
	end
	local tag = text:match("^%s*(.-)%s*$")
	if not tag or tag == "" then
		return nil
	end
	return (tag:gsub("^[vV]", ""))
end

--- 把一次上游检查写进包状态。失败时保留上一次的成功结果，只改状态文案。
function M.withCheck(ps: PackState, remote: string?, failed: boolean, checkedAt: string?): PackState
	local out: PackState = {
		id = ps.id,
		title = ps.title,
		purpose = ps.purpose,
		repo = ps.repo,
		url = ps.url,
		install = ps.install,
		installed = ps.installed,
		version = ps.version,
		status = ps.status,
		latest = ps.latest,
		checkedAt = ps.checkedAt,
		failed = failed,
	}
	if not ps.installed then
		-- 没装就没得比：只记下上游版本，状态保持「未装」。
		out.latest = remote or ps.latest
		return out
	end
	if failed then
		out.status = if ps.checkedAt
			then "检查失败 · 上次 " .. ps.checkedAt
			else "检查失败"
		return out
	end
	out.latest = remote
	out.checkedAt = checkedAt
	local cmp = M.compareVersion(ps.version, remote)
	if cmp == "older" then
		out.status = "待更新"
	elseif cmp == "same" then
		out.status = "已是最新"
	elseif cmp == "newer" then
		out.status = "本地较新"
	else
		out.status = "无法比较"
	end
	return out
end

--- 版本展示：缺版本时写明未知，不留空。
function M.versionLabel(version: string?): string
	if not version or version == "" then
		return "未知版本"
	end
	return version
end

--- 按 id 取包；找不到返回 nil。
function M.byId(id: string): Pack?
	for _, p in ipairs(M.PACKS) do
		if p.id == id then
			return p
		end
	end
	return nil
end

return M
