--!strict
-- 泳道：直接取自技能包原生阶段链（spec §4）。插件自带映射，因为包本身不声明 lane。
-- 不在任何命名 lane 的技能落入「旁路与专项」，绝不丢弃。

local util = require("./util")
local skills = require("./skills")

local M = {}

export type Skill = skills.Skill

export type Lane = {
	id: string,
	title: string,
	skills: { string },
}

--- 五个泳道，技能名取自 spec §4；「旁路与专项」留空，由 groupSkills 兜底填充。
local LANES: { Lane } = {
	{ id = "entry", title = "入口", skills = { "ask-matt", "triage", "diagnosing-bugs", "wayfinder", "grill-with-docs" } },
	{ id = "planning", title = "规划", skills = { "to-spec", "to-tickets" } },
	{ id = "implementation", title = "实施", skills = { "implement", "implement-spec", "tdd" } },
	{ id = "review", title = "审查与交付", skills = { "code-review", "pr", "retro" } },
	{ id = "side", title = "旁路与专项", skills = {} },
}
M.LANES = LANES

--- 返回包含该技能的泳道，不在任何泳道返回 nil。
function M.laneOf(name: string): Lane?
	for _, lane in ipairs(M.LANES) do
		if util.contains(lane.skills, name) then
			return lane
		end
	end
	return nil
end

--- 按 lane 顺序归组；未命中的技能落入最后一个 lane（旁路与专项）。
function M.groupSkills(skillsIn: { Skill }): { Lane }
	local out: { Lane } = {}
	local placed: { [string]: boolean } = {}
	for _, lane in ipairs(M.LANES) do
		local group: Lane = { id = lane.id, title = lane.title, skills = {} }
		for _, sk in ipairs(skillsIn) do
			if util.contains(lane.skills, sk.name) then
				table.insert(group.skills, sk.name)
				placed[sk.name] = true
			end
		end
		table.insert(out, group)
	end
	local side = out[#out]
	for _, sk in ipairs(skillsIn) do
		if not placed[sk.name] then
			table.insert(side.skills, sk.name)
		end
	end
	return out
end

return M
