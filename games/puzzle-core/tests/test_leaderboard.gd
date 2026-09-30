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
		{"key": "level_02", "shape": "cube", "optimal": 5},
		{"key": "level_03", "shape": "domino", "optimal": 7},
	]


func _moves(n: int) -> Array:
	var out: Array = []
	for _i in range(n):
		out.append("right")
	return out


# ---- 测试组 ----

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
	check(Leaderboard.detail_text(entries, p, 1).contains("方块"), "cube 关应显示方块")
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
