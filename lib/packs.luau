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
			"git clone https://github.com/mattpocock/skills",
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
	-- 状态文案：已装 / 未装；上游检查接上后追加待更新等。
	status: string,
	-- 上游最新版本（检查过后才有）。
	latest: string?,
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
	}
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
