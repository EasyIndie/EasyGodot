# leaderboard.gd — 本地排行榜与成绩汇总（对应立项文档 MVP 的「排行榜基础」）。
#
# 刻意分成两层，方便日后平滑接服务端：
#   1. **本地层**：直接读 meta/progress.gd 的本机成绩（当前唯一数据源）
#   2. **远端层**：submit_payload() 给出将来 POST 给后端的**标准化载荷**（现在只用于本地记录）
#
# 与具体玩法无关：只依赖 Progress 的 runs()/best_moves() 与关卡元数据 entries。
extends RefCounted

const Shapes = preload("res://core/shapes.gd")

const MAX_SHOWN := 5


# ── 本地榜 ─────────────────────────────────────────────

static func runs(progress, key: String) -> Array:
	return progress.runs(key)


static func board_text(progress, key: String, limit: int = MAX_SHOWN) -> String:
	# 本机榜文本，如 "3 / 4 / 5 步"；无记录返回 ""
	var rs: Array = progress.runs(key)
	if rs.is_empty():
		return ""
	var out: Array = []
	for i in range(mini(limit, rs.size())):
		out.append(str(int(rs[i]["moves"])))
	return " / ".join(out) + " 步"


static func summary(progress, entries: Array) -> Dictionary:
	# 总成绩：已通关数 / 最佳步数总和 / 已走到最优的关卡数
	var completed: int = 0
	var total_best: int = 0
	var optimized: int = 0
	for e in entries:
		var key: String = str(e["key"])
		var best: int = progress.best_moves(key)
		if best < 0:
			continue
		completed += 1
		total_best += best
		var optimal: int = int(e.get("optimal", -1))
		if optimal > 0 and best <= optimal:
			optimized += 1
	return {
		"completed": completed,
		"total": entries.size(),
		"total_best": total_best,
		"optimized": optimized,
	}


static func summary_text(sum: Dictionary) -> String:
	var t := "已通关 %d / %d" % [int(sum["completed"]), int(sum["total"])]
	if int(sum["completed"]) > 0:
		t += "　·　总成绩 %d 步　·　已最优 %d 关" % [int(sum["total_best"]), int(sum["optimized"])]
	return t


static func detail_text(entries: Array, progress, index: int) -> String:
	# 选关界面底部对该关的说明
	if index < 0 or index >= entries.size():
		return ""
	var e: Dictionary = entries[index]
	var parts: Array = ["第 %02d 关" % (index + 1)]
	parts.append(Shapes.display_name(str(e.get("shape", "domino"))))
	var optimal: int = int(e.get("optimal", -1))
	if optimal > 0:
		parts.append("参考 %d 步" % optimal)
	var bt: String = board_text(progress, str(e["key"]))
	parts.append("本机榜：" + (bt if bt != "" else "暂无成绩"))
	return "　·　".join(parts)


# ── 远端接缝（尚未启用）────────────────────────────────

static func submit_payload(key: String, moves: int, at: int, player_id: String = "local") -> Dictionary:
	# 将来 POST 给排行榜后端的最小载荷；当前只在本地记录，方便后续直接对接。
	return {"v": 1, "level": key, "moves": moves, "at": at, "player": player_id}
