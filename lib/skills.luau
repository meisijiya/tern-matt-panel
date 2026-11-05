--!strict
-- 技能包读取：解析 SKILL.md frontmatter、构造技能记录、列目录读整包。
-- 仅本模块允许使用 tern.fs；其余 lib 纯逻辑，便于 luau CLI 单测。
-- 对技能目录只读：绝不把正文复制进本仓库或插件数据目录。

local util = require("./util")
local paths = require("./paths")

local M = {}

export type Skill = {
	name: string,
	description: string,
	category: string,
	size: number,
	extras: { string },
	-- SKILL.md 的绝对路径：点开才读正文时要用。
	path: string,
}

export type SkillPackage = {
	root: string,
	version: string?,
	skills: { Skill },
}

--- 取路径的父目录。
local function parentOf(p: string): string
	local norm = p:gsub("[\\/]+", "/"):gsub("/$", "")
	local parent = norm:match("^(.*)/[^/]+$")
	return parent or ""
end

--- 取路径的最后一段（basename）。
local function basename(p: string): string
	local norm = p:gsub("[\\/]+", "/"):gsub("/$", "")
	local base = norm:match("/([^/]+)$")
	return base or norm
end

--- frontmatter 切分：以 "---" 行夹住 key: value。
function M.splitFrontmatter(text: string): (string?, string)
	local head, body = string.match(text, "^%-%-%-\r?\n(.-)\r?\n%-%-%-\r?\n(.*)$")
	if not head then
		return nil, text
	end
	return head, body
end

--- 只认 key: value，value 原样保留（参考 tern-prompt-panel/lib/templates.luau）。
function M.parseFrontmatter(text: string): { [string]: string }
	local meta = {}
	for line in string.gmatch(text, "[^\r\n]+") do
		local key, value = string.match(line, "^([%w_%-]+):%s*(.*)$")
		if key then
			meta[key] = util.trim(value)
		end
	end
	return meta
end

--- 解析单个技能：dir=技能目录，path=SKILL.md 路径，text=SKILL.md 正文。
--- category 取自技能目录在 skills/ 下的父分类（如 engineering）。
--- extras 只列技能目录内的兄弟文件名（不含 SKILL.md），绝不读其正文。
--- frontmatter 缺 name 视为无效技能，返回 nil。
function M.parseSkill(dir: string, path: string, text: string): Skill?
	local head = M.splitFrontmatter(text)
	if not head then
		return nil
	end
	local meta = M.parseFrontmatter(head)
	local name = meta.name
	local description = meta.description or ""
	if not name or name == "" then
		return nil
	end
	local category = basename(parentOf(dir))
	local extras: { string } = {}
	local ok, names = pcall(tern.fs.list, dir)
	if ok then -- 探针失败（无权限/不存在）时静默给空表，不崩。
		for _, n in ipairs(names) do
			if n ~= "SKILL.md" then
				table.insert(extras, n)
			end
		end
	end
	return {
		name = name,
		description = description,
		category = category,
		size = #text,
		extras = extras,
		path = path,
	}
end

--- 读一个技能的 SKILL.md 正文。点开才读，不预读。
--- frontmatter 已经解析过，展示时要去掉：正文区只留技能说明本身。
function M.readDoc(skill: Skill): string?
	local ok, text = pcall(tern.fs.read, skill.path)
	if not ok or type(text) ~= "string" then
		return nil
	end
	local head, body = M.splitFrontmatter(text)
	if head then
		return util.trim(body)
	end
	return text
end

--- 这个技能是不是默认隐藏的分类（in-progress / deprecated）。
function M.isHidden(skill: Skill): boolean
	return skill.category == "in-progress" or skill.category == "deprecated"
end

--- 列 root/skills/<category>/<skill>/SKILL.md，构造整包；根或 skills 目录不存在返回 nil。
function M.readPackage(root: string): SkillPackage?
	if not root or not (pcall(tern.fs.exists, root .. "/skills") and tern.fs.exists(root .. "/skills")) then
		return nil
	end
	local skills: { Skill } = {}
	local okCats, cats = pcall(tern.fs.list, root .. "/skills")
	if not okCats then
		return nil
	end
	for _, cat in ipairs(cats) do
		local catDir = root .. "/skills/" .. cat
		local okSkills, skillDirs = pcall(tern.fs.list, catDir)
		if okSkills then
			for _, sdir in ipairs(skillDirs) do
				local skillDir = catDir .. "/" .. sdir
				local skPath = skillDir .. "/SKILL.md"
				if pcall(tern.fs.exists, skPath) and tern.fs.exists(skPath) then
					local ok, text = pcall(tern.fs.read, skPath)
					if ok then
						local sk = M.parseSkill(skillDir, skPath, text)
						if sk then
							table.insert(skills, sk)
						end
					end
				end
			end
		end
	end
	return {
		root = root,
		version = paths.packageVersion(root),
		skills = skills,
	}
end

return M
