# DESIGN.md 规格取证笔记

> 一手规格：Google `google-labs-code/design.md`（alpha），Apache 2.0。
> 仓库：https://github.com/google-labs-code/design.md ；spec 路径 `docs/spec.md`。
> CLI：`@google/design.md` 0.4.1（npm），别名 `designmd`。

## 1. 一手来源

| 来源 | URL | 版本/日期 | 许可 |
|---|---|---|---|
| Google design.md spec | github.com/google-labs-code/design.md/blob/main/docs/spec.md | alpha（front matter `version: alpha`） | Apache 2.0（LICENSE） |
| Google 博客（Stitch DESIGN.md 开源） | blog.google/.../stitch-design-md/ | 2026-04-21 | — |
| opendesignmd.com | opendesignmd.com/what-is-design-md/ | 社区库（1186 份），非规范 | — |
| DTCG 2025.10 | designtokens.org/tr/2025.10/format/ | token 语法灵感来源 | — |

## 2. Token 与章节

**Front matter 顶层键**（`---` 包围）：`version`(可选)、`name`(必填)、`description`(可选)、`omitted`(可选)、`colors`、`typography`、`rounded`、`spacing`、`components`。

- 颜色：CSS 任意颜色（hex rgb oklch named 等），hex `#RRGGBB` 推荐默认。
- 字体：`fontFamily/fontSize/fontWeight/lineHeight/letterSpacing/fontFeature/fontVariation`。
- 间距/圆角：Dimension（px/em/rem）或 number。
- 组件：`backgroundColor/textColor/typography/rounded/padding/size/height/width`，变体用独立 key（`button-primary-hover`）。
- Token 引用：`{colors.primary}` 花括号对象路径。

**必备章节（8 个，`##`，按序）**：Overview(Brand & Style) → Colors → Typography → Layout(Layout & Spacing) → Elevation & Depth → Shapes → Components → Do's and Don'ts。可省略，但出现必须按序；未知章节保留不报错。

**消费方对未知内容**：未知章节/颜色/typography 保留；未知组件属性警告但接受；重复章节 heading 或重复顶层 YAML key → 报错拒绝。

## 3. 消费方式

- 文件约定：项目根 `DESIGN.md`，agent 启动/按需读取（与 AGENTS.md/README 指针配合；无自动发现规范，靠项目约定）。
- 两层：YAML tokens 为规范值（normative），Markdown prose 提供上下文（why/how）。描述性颜色名（"Midnight Forest Green"）对应 token 名（`primary`）。
- Token 可导出为 `tokens.json`、Tailwind theme、CSS 变量（`npx @google/design.md export --format ...`），避免双真源：DESIGN.md 为单一真源，其他产物由 export 生成。
- Lint：`npx @google/design.md lint DESIGN.md`（结构校验、引用完整性、WCAG 对比度）。

## 4. 最小骨架（≤30 行，仅结构，无品牌内容）

```yaml
---
version: alpha
name: <project>
colors:
  primary: "#000000"
typography:
  body-md:
    fontFamily: system-ui
    fontSize: 16px
    fontWeight: 400
    lineHeight: 1.5
rounded:
  md: 8px
spacing:
  md: 16px
---
```

```markdown
## Overview
<一段落：品牌个性/目标用户/期望情绪>

## Colors
- **Primary (#000000):** <用途>

## Typography
- **Body:** <字体/尺寸/用途>

## Do's and Don'ts
- Do <...>
- Don't <...>
```

必填：`name` + 至少 `primary` 颜色。其余可选（用 `omitted` 抑制 linter 警告）。

**误读风险**：重复顶层 key；章节顺序错；颜色写非 CSS 字符串；token 引用未加 `{}`；组件属性拼写错误（仅警告，agent 可能忽略）。

## 5. 两种场景

- **从 0 新建**：先写 front matter tokens（name + colors.primary 最小），再 prose；用 `npx @google/design.md lint` 校验；导出 Tailwind/CSS。
- **已有项目迭代**：以现有 CSS 变量/tailwind config 反向填 tokens（export 反向：手动映射）；保留 prose 描述 "why"；用 `diff` 对比版本检测回归（`npx @google/design.md diff before after`，退出码 1 表示回归）。

差异：新建以 token 为先；迭代以现有代码为先、DESIGN.md 为聚合真源，需迁移期避免双写。

## 6. 引用边界

- Apache 2.0：可摘要/引用规范文本进面板模板，需保留版权声明与许可证；不可把上游示例品牌内容（Heritage/Daylight Prestige）当作模板默认值。
- 规范本身（字段名、章节名、消费规则）属事实，不受版权限制；示例 prose 属上游表达，引用需注明来源。
- 结论：模板可内嵌"最小骨架 + 字段说明"（事实性），不得内嵌任何 skill/品牌正文；插件不代装技能。

## 7. 对模板的结论

- 面板 "前端" 入口两条路：新建设计 → 生成最小骨架 + lint；迭代与术语 → 读取现有 DESIGN.md/CSS 变量，聚合为真源，diff 校验。
- 模板只输出 `/skill:名字` 指针，不内嵌 skill 正文；技能包由用户自行安装。
