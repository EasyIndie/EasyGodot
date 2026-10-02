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

static func format_time(ms: int) -> String:
	# 用时展示：1 分钟内用「12.4 秒」，超过用「1:02.5」。
	# 关卡普遍几十秒，所以主用秒；但长时间思考时也得能一眼读出分钟数。
	if ms < 0:
		return "—"
	var total: float = float(ms) / 1000.0
	if total < 60.0:
		return "%.1f 秒" % total
	var m: int = int(total) / 60
	return "%d:%04.1f" % [m, total - float(m * 60)]


static func format_clock(ms: int) -> String:
	# 秒表式显示 m:ss.d：固定宽度（数字位数变化时 HUD 不会左右抖），专供计时器
	if ms < 0:
		return "--:--.-"
	var total: float = float(ms) / 1000.0
	var m: int = int(total) / 60
	return "%d:%04.1f" % [m, total - float(m * 60)]


static func best_time_text(progress, key: String) -> String:
	# 「最快 12.4 秒」；无记录返回 ""
	var t: int = progress.best_time(key)
	return "" if t < 0 else "最快 %s" % format_time(t)


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
	var cleared_round: int = progress.completed_count()   # **本轮**通关数
	var total_best: int = 0
	var optimized: int = 0
	var timed: int = 0          # 有计时记录的关卡数
	var total_time: int = 0     # 各关最快用时之和
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
		var t: int = progress.best_time(key)
		if t >= 0:
			timed += 1
			total_time += t
	return {
		"cleared_round": cleared_round,
		"ever": progress.ever_count(),
		"completed": completed,
		"total": entries.size(),
		"total_best": total_best,
		"optimized": optimized,
		"timed": timed,
		"total_time": total_time,
	}


static func summary_text(sum: Dictionary) -> String:
	# **口径以「本轮」为准**：这是修一个真实的误读 ——
	# 玩家点「再玩一遍」后，汇总若以历史记录打头显示「已通关 20 / 20」，读起来就是
	# "进度根本没清掉"（其实清的是本轮，记录是资产、刻意保留）。所以：
	#   有历史 -> 打头写「本轮 x / M」，历史数据单独标成「曾经通关 / 最好成绩」
	#   无历史 -> 直接写「已通关 x / M」
	var total: int = int(sum["total"])
	var round_cleared: int = int(sum.get("cleared_round", sum["completed"]))
	var ever: int = int(sum.get("ever", sum["completed"]))
	var replaying: bool = ever > round_cleared
	var t: String = ""
	if replaying:
		t = "本轮 %d / %d　·　曾经通关 %d" % [round_cleared, total, ever]
	else:
		t = "已通关 %d / %d" % [round_cleared, total]
	if int(sum["completed"]) > 0:
		var best_label: String = "本机最好成绩" if replaying else "总成绩"
		t += "　·　%s %d 步　·　已最优 %d 关" % [best_label, int(sum["total_best"]), int(sum["optimized"])]
		# 只有真的计过时才显示（旧存档没有时间记录，否则会冒出一个「—」）
		if int(sum.get("timed", 0)) > 0:
			t += "　·　合计最快 %s" % format_time(int(sum["total_time"]))
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
	var tt: String = best_time_text(progress, str(e["key"]))
	if tt != "":
		parts.append(tt)
	return "　·　".join(parts)


# ── 远端接缝（尚未启用）────────────────────────────────

static func submit_payload(key: String, moves: int, at: int, player_id: String = "local") -> Dictionary:
	# 将来 POST 给排行榜后端的最小载荷；当前只在本地记录，方便后续直接对接。
	return {"v": 1, "level": key, "moves": moves, "at": at, "player": player_id}
