--!strict
-- 票动作模板：插件自有配置，随插件分发；绝不内嵌任何 skill 正文。
-- 模板只以"调用已安装技能"的方式提及（/grill-with-docs 等），内容中文单语。

local M = {}

export type Template = {
	id: string,
	title: string,
	body: string,
}

--- 四个票动作模板，按 wayfinder 票类型分（issue #9 决策）。
--- task 不挂技能，只给票链接 + 执行指令；其余三类只调用对应技能。
local TEMPLATES: { Template } = {
	{
		id = "grilling",
		title = "盘问",
		body = "请使用 /skill:grill-with-docs 技能，对以下需求做盘问式审查，找出隐藏假设与尚未拍板的决策。\n需求链接：{url}",
	},
	{
		id = "prototype",
		title = "原型",
		body = "请使用 /skill:prototype 技能，为以下需求快速做出可运行的原型，验证想法是否站得住。\n需求链接：{url}",
	},
	{
		id = "research",
		title = "调研",
		body = "请使用 /skill:research 技能，围绕以下主题展开调研，给出结论与一手来源。\n需求链接：{url}",
	},
	{
		id = "task",
		title = "执行",
		body = "请认领并执行以下任务，完成后回报结论。\n任务标题：{title}\n任务链接：{url}",
	},
}
M.TEMPLATES = TEMPLATES

--- 公共小节：好几条模板共用同一段话，只写一遍，改一次就全改。
--- 不内嵌技能正文：这里只是「调用哪个技能 + 用什么方式想 + 交付什么」。
local FIRST = "从第一性原理出发。"

local INVESTIGATION = table.concat({
	"## 调查（先查后问）",
	"- [ ] 先读票正文、评论与仓内相关内容，再提问。",
	"- [ ] 优先复用仓内既有笔记（查找与存放都循仓内习惯）；复用时只记路径与一句结论，不粘贴全文。",
	"- [ ] 既有笔记答不了，再按 /skill:research 规则新查一次，一句话说明为什么不适用，把新笔记路径回填正文。",
	"- [ ] 提问前用一句话说明已查阅范围。",
}, "\n")

local TOOLS = table.concat({
	"## 工具",
	"- [ ] 票的读写一律走 gh（gh issue list / view / create / comment / edit --add-label）。",
	"- [ ] 每轮回复收尾前先判断一次：用户接下来几乎一定会做什么？想得到就给 2~4 条可选做法并标出你推荐的那条；想不到就不写。",
}, "\n")

--- 「问下一步」：只调 ask-matt 技能，外加一段写清怎么想、怎么给的提示。
--- 面板不再搬运任务板快照：事实由会话自己用 gh 核，面板只给判断顺序与交付形状。
M.NEXT_STEP = {
	id = "next-step",
	title = "问下一步",
	body = table.concat({
		"/skill:ask-matt",
		"",
		FIRST,
		"",
		"项目 {repo}。判断这个项目此刻的下一步该做什么。",
		"",
		"## 边界",
		"- [ ] 只做分析：不改仓库、不认领票、不关闭票、不建 PR。",
		"- [ ] 结论必须能被别人复核：每条都写清你实际读过哪个票号或哪个文件。",
		"",
		"## 先自己核事实",
		"- [ ] 用 gh 读开放票与依赖（gh issue list --state open），再用 git status 看手上有没有半成品；不要凭记忆猜进度。",
		"- [ ] 仓里这几处存在就先读，不存在就跳过，不要引用不存在的东西：GLOSSARY.md、docs/adr/、docs/spec/。",
		"",
		"## 判断顺序（前一档有就不要再往后看）",
		"- [ ] 有坏的正：能复现的故障优先于任何新功能。",
		"- [ ] 有卡住的活：已认领却停住的、被阻塞但阻塞方已关闭的。",
		"- [ ] 能解锁下游最多的一件事。",
		"- [ ] 都不明显时按阶段：盘问 > 调研 > 原型 > 执行。",
		"",
		"## 交付",
		"- [ ] 最多 3 条，每条一行：做什么 · 用哪个技能命令 · 第一步具体动作 · 一句依据。",
		"- [ ] 最后一行写「没核到的：…」；全都核到了就写「没核到的：无」。",
	}, "\n"),
}

--- 「提 BUG」：按 wayfinder 规则建 bug 票，正文给报告人四项填空，
--- 建单前强制扫一遍已有 bug 票查重（关键词搜索会漏，必须全扫）。
M.NEW_BUG = {
	id = "new-bug",
	title = "提 BUG",
	body = table.concat({
		"/skill:wayfinder",
		"请帮我新增一个 BUG 单（严格遵循 wayfinder 技能规则）。",
		"",
		FIRST,
		"",
		"仓库：{repo}",
		"新建的单必须带 bug 标签；还没诊断过就同时带 needs-triage。",
		"",
		"## 澄清",
		"- [ ] 有假设先用 grilling 澄清，不默认；已给的不重问。",
		"- [ ] 四项全空时先回问报告人，不要替他编；只答出一部分就照常建单，缺的地方标 needs-info。",
		"",
		"下面四项是帮报告人把情况说清楚的提示，不是四道必答题：知道多少写多少，说不清的可以空着。",
		"实际（看到了什么现象；知道影响范围就一并写上）：",
		"期望（原本预期是什么样；与实际看到的差异写清楚）：",
		"复现步骤（能说清前置条件和场景就先写，再按编号步骤写；偶发的话写下大概频率）：",
		"环境信息（知道的话写 OS 版本、软件版本、运行环境）：",
		"",
		INVESTIGATION,
		"",
		"## 查重（建单前必做）",
		"- [ ] 收齐「实际」后全扫一遍，不要用关键词搜索代替：先 gh issue list --state open --label bug --limit 200，再 --state closed --label bug --limit 200。",
		"- [ ] 标题像的用 gh issue view 看正文；清单没取全就把这句写进查重记录。",
		"- [ ] 有命中时先别下结论：把最多 3 个候选（编号、标题、像在哪）列给报告人，问一句「这些是不是同一个问题」，等到回答再决定。",
		"- [ ] 同一个问题且旧单开着：不建新单，在旧单下评论补现象与复现步骤，旧单不关。",
		"- [ ] 同一个问题且旧单已关闭：按回归处理，建新单并在正文写明「回归：原单 #编号」。",
		"- [ ] 报告人确认不是，或没有命中：建新单，正文写明看过的候选与报告人的回答。",
		"",
		"## 查重记录（写进新单正文，没有命中也要写）",
		"- [ ] 扫描：查了哪些状态与标签、各拿到多少张。",
		"- [ ] 命中：候选编号与标题；没有就写「无」。",
		"- [ ] 报告人确认：怎么回答的。",
		"- [ ] 结论：新建 / 关联哪张旧单 / 按回归新建。",
		"",
		TOOLS,
	}, "\n"),
}

--- 「体检」：把游离的开放票归位。只做两种结构动作（挂到地图下、开新地图），
--- 先出建议清单，人点头才动手；其余一律不碰。
M.HEALTH_CHECK = {
	id = "health-check",
	title = "体检",
	body = table.concat({
		"/skill:wayfinder",
		"请给这个仓库的开放票做一次体检，把游离的票归位（严格遵循 wayfinder 技能规则）。",
		"",
		FIRST,
		"",
		"仓库：{repo}",
		"范围是整个仓库的开放票，不跟随面板当前的筛选。",
		"",
		"## 一、什么算游离",
		"三条同时成立才算：票未关闭、票自己不是地图、票没有父票（不在任何地图的子票里）。",
		"不按标签排除：写着等人动手、写着不打算做的票同样算游离，标签只在报告里用来分区。",
		"在此之上对每张游离票判一句「这张能不能单张票处理掉」：能的话也可以留在原地，只在报告里登记一行并写明理由。",
		"",
		"## 二、只做两件结构动作",
		"1. 建原生子议题边：把票挂到合适的地图下。",
		"2. 为人点过头的票开一张新地图。",
		"一律不碰：已关闭的票、任何票的标题与正文、标签与认领状态、别的仓库；不关闭票、不删评论、不改源码、不发版、不提交。清单里要动其中任何一项的，都不做，改成写进建议等人处理。",
		"",
		"## 三、交付：先出建议清单，等人点头才动手",
		"- [ ] 每条写一句结论：挂到哪张地图下 / 建议自立成一张新地图 / 建议留在原地不动，各配一句理由。",
		"- [ ] 写完停下来等点头。不要自动往票上写评论：动手留下的原生边就是留痕。",
		"",
		"## 四、挑地图的判据",
		"- [ ] 读每张地图的 Destination 与 Notes 做语义归类。",
		"- [ ] 挑不出唯一一张就列 2 到 3 个候选让人选，不硬选；一张都不合适就按第三节建议自立成图（只写最小的 Destination 草稿）；连自立也说不通，就建议留在原地并写明理由。",
		"",
		"## 五、当前后端的科目",
		"GitHub 后端：用 gh 读票与依赖（gh issue list / gh issue view）；写边只用 gh 的 issue 依赖接口，其余写操作一概不做。",
		"",
		TOOLS,
	}, "\n"),
}

--- 仓库空的时候给两条路，对应参考实现的「探索地图 / 实施地图」二选一：
--- 需求还没摸清走 wayfinder 画地图；需求已经明确直接 grill 收敛成 spec。
--- 只甩一条 /wayfinder 会误导 —— 需求清楚的人不需要画地图。
export type Entry = { id: string, title: string, injectAction: string, hint: string, body: string }

local ENTRIES: { Entry } = {
	{
		id = "explore",
		title = "还没想清楚：建路线图",
		injectAction = "入口·还没想清楚",
		hint = "跑 /skill:wayfinder 画一张地图，把未知与范围拆成决策票",
		body = table.concat({
			"/skill:wayfinder",
			"请帮我处理一个需求（严格遵循 wayfinder 技能规则）。",
			"",
			FIRST,
			"",
			"仓库：{repo}",
			"",
			INVESTIGATION,
			"",
			"## 并行与串行",
			"- [ ] 画 map、定 sub-issue 时就把并行与串行想清楚：能同时开工、互不等待就是并行，不用另外标注——并行就是彼此之间不连 blockedBy 边；必须等前一个办完才能开工的才是串行，后一个的 blockedBy 指着前一个。",
			"- [ ] 串行只留在真有先后要求的地方：后一个要用前一个的结论、共用同一组文件或接口、合拢会打架的，先串行；各自独立、合拢不打架的，才并行。",
			"",
			"## 收尾",
			"- [ ] 结束前把 blockedBy 再查一遍：不多不少、串行链条没断没绕圈、并行的票真能同时开工；对不上先把边改对。",
			"- [ ] 建了新 map 就写明编号，并说清哪些 sub-issue 并行、哪些串行、谁等谁；没建成就写明下一步。",
			"",
			TOOLS,
		}, "\n"),
	},
	{
		id = "implement",
		title = "需求已明确：直接对齐",
		injectAction = "入口·需求已明确",
		hint = "跑 /skill:grill-with-docs 把需求问清，再 /skill:to-spec → /skill:to-tickets 拆成可做的票",
		body = table.concat({
			"/skill:grill-with-docs",
			"请帮我讨论一个需求（严格遵循 grill-with-docs 技能规则）。",
			"",
			FIRST,
			"",
			"仓库：{repo}",
			"",
			INVESTIGATION,
			"",
			"## 需求",
			"（在这里写清这一次要讨论什么）",
			"",
			"## 收尾（下面两步由用户手动执行，不要替他做）",
			"- [ ] 讨论结束、结论对齐后，提醒用户手动执行一次 /skill:to-spec，把结论生成规格 issue。",
			"- [ ] 规格 issue 生成后，再提醒用户手动执行一次 /skill:to-tickets，把规格拆成实施 issue。",
			"",
			TOOLS,
		}, "\n"),
	},
}
M.ENTRIES = ENTRIES

--- 按 id 取入口；找不到返回 nil。
function M.entryById(id: string): Entry?
	for _, e in ipairs(M.ENTRIES) do
		if e.id == id then
			return e
		end
	end
	return nil
end

--- 替换入口模板里的占位符。
function M.renderEntry(e: Entry, repo: string): string
	return (e.body:gsub("{repo}", repo))
end

--- 按 id 取模板；找不到返回 nil。
function M.byId(id: string): Template?
	for _, t in ipairs(M.TEMPLATES) do
		if t.id == id then
			return t
		end
	end
	return nil
end

--- 按票类型取模板；票没有 wayfinder:<type> 标签时返回 nil。
function M.byTicketType(kind: string?): Template?
	if not kind then
		return nil
	end
	return M.byId(kind)
end

--- 替换模板里的 {占位符}。缺的占位符留原样（不静默吞掉，便于发现模板写错）。
function M.render(tpl: Template, vars: { [string]: string }): string
	return (tpl.body:gsub("{(%w+)}", function(key: string)
		return vars[key] or ("{" .. key .. "}")
	end))
end

return M
