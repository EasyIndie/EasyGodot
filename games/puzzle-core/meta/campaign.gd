# 首发的教学节奏：短标题用于选关卡片，帮助玩家看到下一关会学到什么。
extends RefCounted

const TITLES: Array = [
	"第一步", "竖立抵达", "避开空洞", "转个方向", "找准落点",
	"绕路前进", "窄路转身", "路线选择", "提前规划", "换个思路",
	"姿态调整", "路线挑战", "初见传送", "出口姿态", "传送挑战",
	"开桥过河", "先后顺序", "桥上挑战", "组合路线", "终章挑战",
]


static func title(index: int) -> String:
	return str(TITLES[index]) if index >= 0 and index < TITLES.size() else "骨牌"
