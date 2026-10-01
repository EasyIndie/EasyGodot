# test_leaderboard.gd — 本地排行榜 / 成绩汇总测试（headless）。
# 用临时存档路径，不污染 user://progress.json。
extends SceneTree

const Progress = preload("res://meta/progress.gd")
const Leaderboard = preload("res://meta/leaderboard.gd")

const TMP := "user://test_leaderboard_tmp.json"

var checks: int = 0
var failures: int = 0


func _init() -> void:
	_remove(TMP)
	_test_time()
	_test_empty()
	_test_summary()
	_test_board_text()
	_test_runs_cap()
	_test_detail_text()
	_test_payload()
	_test_migration()
	_remove(TMP)

	var result: Dictionary = {
		"suite": "test_leaderboard",
		"checks": checks,
		"failures": failures,
		"status": "ok" if failures == 0 else "fail",
	}
	print(JSON.stringify(result))
	quit(0 if failures == 0 else 1)


func check(cond: bool, msg: String) -> void:
	checks += 1
	if not cond:
		failures += 1
		push_error("FAIL: " + msg)


func _remove(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _entries() -> Array:
	return [
		{"key": "level_01", "shape": "domino", "optimal": 3},
		{"key": "level_02", "shape": "domino", "optimal": 5},
		{"key": "level_03", "shape": "domino", "optimal": 7},
	]


func _moves(n: int) -> Array:
	var out: Array = []
	for _i in range(n):
		out.append("right")
	return out


# ---- 测试组 ----

func _test_time() -> void:
	# 用时格式化：边界要盯死，因为它是玩家直接读的数
	check(Leaderboard.format_time(-1) == "—", "没有记录显示占位符")
	check(Leaderboard.format_time(0) == "0.0 秒", "0 毫秒")
	check(Leaderboard.format_time(12400) == "12.4 秒", "12.4 秒")
	check(Leaderboard.format_time(999) == "1.0 秒", "不足一秒也显示一位小数")
	check(Leaderboard.format_time(59900) == "59.9 秒", "59.9 秒仍在秒档")
	check(Leaderboard.format_time(60000) == "1:00.0", "整 60 秒切到分钟档")
	check(Leaderboard.format_time(62500) == "1:02.5", "1 分 2.5 秒")
	check(Leaderboard.format_time(3600000) == "60:00.0", "一小时也只是分钟数变大，不跳档")

	var tmp := "user://test_lb_time.json"
	_remove(tmp)
	var pr = Progress.new(tmp)
	check(Leaderboard.best_time_text(pr, "level_01") == "", "无记录时不显示最快用时")

	pr.record_win("level_01", ["right", "right"], 20000)
	check(Leaderboard.best_time_text(pr, "level_01") == "最快 20.0 秒", "有记录时给出最快用时")
	check(Leaderboard.detail_text([{"key": "level_01", "shape": "domino", "optimal": 2}], pr, 0).contains("最快 20.0 秒"),
		"选关详情里要能看到最快用时")

	pr.record_win("level_02", ["right", "right", "right"], 30000)
	var sum: Dictionary = Leaderboard.summary(pr, [
		{"key": "level_01", "optimal": 2}, {"key": "level_02", "optimal": 3}, {"key": "level_03", "optimal": 4},
	])
	check(int(sum["timed"]) == 2, "只有计过时的关卡计入 timed")
	check(int(sum["total_time"]) == 50000, "合计最快用时")
	check(Leaderboard.summary_text(sum).contains("合计最快 50.0 秒"), "汇总文案要含合计最快用时")

	# 旧存档（完全没有时间记录）不该冒出「合计最快 —」
	var pr_old = Progress.new("user://test_lb_time_old.json")
	_remove("user://test_lb_time_old.json")
	pr_old.record_win("level_01", ["right"])
	var sum_old: Dictionary = Leaderboard.summary(pr_old, [{"key": "level_01", "optimal": 1}])
	check(not Leaderboard.summary_text(sum_old).contains("合计最快"), "没有计时记录时不显示合计（避免出现「—」）")
	_remove(tmp)
	_remove("user://test_lb_time_old.json")


func _test_empty() -> void:
	var p = Progress.new(TMP)
	var entries: Array = _entries()
	var s: Dictionary = Leaderboard.summary(p, entries)
	check(int(s["completed"]) == 0, "未通关时 completed 应为 0")
	check(int(s["total_best"]) == 0, "未通关时总成绩应为 0")
	check(int(s["optimized"]) == 0, "未通关时已最优数应为 0")
	check(int(s["total"]) == 3, "total 应等于关卡数")
	check(Leaderboard.board_text(p, "level_01") == "", "无记录时榜单文本应为空")
	check(Leaderboard.summary_text(s) == "已通关 0 / 3", "未通关时汇总文案应简洁")
	check(Leaderboard.detail_text(entries, p, 0).contains("暂无成绩"), "详情应提示暂无成绩")


func _test_summary() -> void:
	var p = Progress.new(TMP)
	p.reset()
	var entries: Array = _entries()
	p.record_win("level_01", _moves(3))   # 正好最优
	p.record_win("level_02", _moves(6))   # 比最优多 1
	var s: Dictionary = Leaderboard.summary(p, entries)
	check(int(s["completed"]) == 2, "应统计 2 关已通关")
	check(int(s["total_best"]) == 9, "总成绩应为 3+6=9")
	check(int(s["optimized"]) == 1, "只有第 1 关走到最优")
	var t: String = Leaderboard.summary_text(s)
	check(t.contains("已通关 2 / 3"), "汇总文案应含通关数: " + t)
	check(t.contains("总成绩 9 步"), "汇总文案应含总成绩: " + t)
	check(t.contains("已最优 1 关"), "汇总文案应含最优数: " + t)

	# 刷新最佳后总成绩应下降
	p.record_win("level_02", _moves(5))
	var s2: Dictionary = Leaderboard.summary(p, entries)
	check(int(s2["total_best"]) == 8, "刷新最佳后总成绩应变 8")
	check(int(s2["optimized"]) == 2, "两关都到最优")


func _test_board_text() -> void:
	var p = Progress.new(TMP)
	p.reset()
	check(Leaderboard.board_text(p, "level_01") == "", "无成绩时为空")
	p.record_win("level_01", _moves(5))
	p.record_win("level_01", _moves(3))
	p.record_win("level_01", _moves(4))
	check(Leaderboard.board_text(p, "level_01") == "3 / 4 / 5 步", "榜单应按步数升序: " + Leaderboard.board_text(p, "level_01"))


func _test_runs_cap() -> void:
	var p = Progress.new(TMP)
	p.reset()
	# 依次打 9/8/7/6/5/4/3 步，只保留最小的 5 条
	for n in [9, 8, 7, 6, 5, 4, 3]:
		p.record_win("level_01", _moves(int(n)))
	var rs: Array = p.runs("level_01")
	check(rs.size() == Progress.MAX_RUNS, "本机榜应只保留 %d 条，got=%d" % [Progress.MAX_RUNS, rs.size()])
	check(int(rs[0]["moves"]) == 3, "榜首应为 3 步")
	check(int(rs[rs.size() - 1]["moves"]) == 7, "第 5 名应为 7 步")
	check(int(rs[0]["at"]) > 0, "记录应带时间戳")


func _test_detail_text() -> void:
	var p = Progress.new(TMP)
	p.reset()
	var entries: Array = _entries()
	p.record_win("level_01", _moves(4))
	var d: String = Leaderboard.detail_text(entries, p, 0)
	check(d.contains("第 01 关"), "详情应含关卡号: " + d)
	check(d.contains("骨牌"), "详情应含形状: " + d)
	check(d.contains("参考 3 步"), "详情应含参考步数: " + d)
	check(d.contains("本机榜：4 步"), "详情应含本机榜: " + d)
	# 形状名统一由 shapes.gd 的 DISPLAY_NAMES 提供（cube 已移除，只剩骨牌）
	check(Leaderboard.detail_text(entries, p, 1).contains("骨牌"), "详情应显示形状名")
	check(Leaderboard.detail_text(entries, p, 99) == "", "越界索引应返回空串")


func _test_payload() -> void:
	var pl: Dictionary = Leaderboard.submit_payload("level_01", 12, 1700000000)
	check(int(pl["v"]) == 1, "载荷应带版本号")
	check(str(pl["level"]) == "level_01", "载荷应带关卡 key")
	check(int(pl["moves"]) == 12, "载荷应带步数")
	check(int(pl["at"]) == 1700000000, "载荷应带时间戳")
	check(str(pl["player"]) == "local", "默认玩家标识为 local")


func _test_migration() -> void:
	# 旧存档只有 best_moves、没有 runs：应自动补一条，保证榜单不为空
	var p = Progress.new(TMP)
	p.reset()
	p.record_win("level_01", _moves(5))
	# 手工抹掉 runs 字段，模拟旧格式
	var f := FileAccess.open(TMP, FileAccess.READ)
	var d: Dictionary = JSON.parse_string(f.get_as_text())
	f.close()
	d.erase("runs")
	var w := FileAccess.open(TMP, FileAccess.WRITE)
	w.store_string(JSON.stringify(d, "\t"))
	w.close()

	var q = Progress.new(TMP)
	check(q.runs("level_01").size() == 1, "旧存档应补出 1 条榜单记录")
	check(int(q.runs("level_01")[0]["moves"]) == 5, "补出的记录应等于最佳步数")
	check(q.best_moves("level_01") == 5, "迁移不应影响最佳步数")
