# test_progress.gd — 进度持久化 + 回放数据契约测试（headless）。
# 用临时存档路径，不污染 user://progress.json。
extends SceneTree

const Progress = preload("res://meta/progress.gd")
const Moves = preload("res://core/moves.gd")

const TMP := "user://test_progress_tmp.json"

var checks: int = 0
var failures: int = 0


func _init() -> void:
	_remove(TMP)
	_test_best_time()
	_test_fresh()
	_test_record_win()
	_test_persistence()
	_test_unlock_rule()
	_test_corrupt_save()
	_test_replay_label_contract()
	_test_reset()
	_test_reset_campaign()
	_remove(TMP)

	var result: Dictionary = {
		"suite": "test_progress",
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


# ---- 测试组 ----

func _test_fresh() -> void:
	var p = Progress.new(TMP)
	check(p.completed_count() == 0, "全新进度应无通关记录")
	check(not p.is_completed("level_01"), "全新进度不应标记通关")
	check(p.best_moves("level_01") == -1, "全新进度不应有最佳步数")
	check(not p.has_replay("level_01"), "全新进度不应有回放")
	check(p.replay("level_01").is_empty(), "无回放时应返回空字典")


func _test_record_win() -> void:
	var p = Progress.new(TMP)
	var r1: Dictionary = p.record_win("level_01", ["right", "left"])
	check(bool(r1["first_clear"]), "首次通关应标记 first_clear")
	check(bool(r1["improved"]), "首次通关应标记 improved")
	check(int(r1["prev_best"]) == -1, "首次通关前无最佳记录")
	check(p.is_completed("level_01"), "通关后应标记完成")
	check(p.best_moves("level_01") == 2, "最佳步数应为 2")
	check(p.has_replay("level_01"), "首次通关应保存回放")
	check((p.replay("level_01")["moves"] as Array).size() == 2, "回放步数应为 2")

	# 更差的一局：不覆盖最佳
	var r2: Dictionary = p.record_win("level_01", ["right", "left", "forward"])
	check(not bool(r2["improved"]), "步数更多不应算进步")
	check(int(r2["prev_best"]) == 2, "应回报原有最佳")
	check(p.best_moves("level_01") == 2, "最佳步数应保持 2")
	check((p.replay("level_01")["moves"] as Array).size() == 2, "回放不应被更差成绩覆盖")

	# 更好的一局：覆盖最佳 + 回放
	var r3: Dictionary = p.record_win("level_01", ["right"])
	check(bool(r3["improved"]), "步数更少应算进步")
	check(not bool(r3["first_clear"]), "非首次通关不应标记 first_clear")
	check(p.best_moves("level_01") == 1, "最佳步数应更新为 1")
	check((p.replay("level_01")["moves"] as Array).size() == 1, "回放应更新为最短记录")
	check(p.completed_count() == 1, "通关计数应为 1")


func _test_persistence() -> void:
	var p = Progress.new(TMP)
	check(p.save(), "应能写出存档")
	var q = Progress.new(TMP)
	check(q.is_completed("level_01"), "重新读取后应保留通关状态")
	check(q.best_moves("level_01") == 1, "重新读取后应保留最佳步数")
	check(q.has_replay("level_01"), "重新读取后应保留回放")
	check(q.replay("level_01")["moves"] == ["right"], "回放序列应完整还原")
	check(q.runs("level_01").size() == 3, "重新读取后应保留本机榜全部记录")
	check(int(q.runs("level_01")[0]["moves"]) == 1, "本机榜应按步数升序，榜首为 1")


func _test_unlock_rule() -> void:
	var p = Progress.new(TMP)
	p.reset()
	var keys: Array = ["a", "b", "c"]
	check(p.is_unlocked(0, keys), "第 1 关应始终开放")
	check(not p.is_unlocked(1, keys), "未通关前一关时第 2 关应锁定")
	check(not p.is_unlocked(2, keys), "第 3 关应锁定")
	check(not p.is_unlocked(9, keys), "越界索引应锁定")

	p.record_win("a", ["right"])
	check(p.is_unlocked(1, keys), "通关第 1 关后第 2 关应解锁")
	check(not p.is_unlocked(2, keys), "第 3 关仍应锁定")

	p.record_win("b", ["right"])
	check(p.is_unlocked(2, keys), "通关第 2 关后第 3 关应解锁")


func _test_corrupt_save() -> void:
	# 存档损坏不应崩溃，应退回全新进度
	var f := FileAccess.open(TMP, FileAccess.WRITE)
	f.store_string("{ this is not json ")
	f.close()
	var p = Progress.new(TMP)
	check(p.completed_count() == 0, "损坏存档应退回全新进度")
	check(p.best_moves("level_01") == -1, "损坏存档不应带出脏数据")


func _test_replay_label_contract() -> void:
	# 回放存的是方向标签，映射必须稳定且唯一
	var dirs: Array = [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)]
	var seen: Dictionary = {}
	for d in dirs:
		var label: String = Moves.direction_label(d)
		check(label != "?", "每个方向都应有标签: " + str(d))
		check(not seen.has(label), "方向标签应唯一: " + label)
		seen[label] = true
		check(Moves.direction_from_label(label) == d, "标签应能还原方向: " + label)
	check(seen.size() == 4, "应有 4 个唯一方向标签")


func _test_best_time() -> void:
	# 「最快时间」与「最佳步数」是两条独立记录：步数少不代表用时短
	var tmp := "user://test_progress_time.json"
	_remove(tmp)
	var pr = Progress.new(tmp)
	check(pr.best_time("level_01") < 0, "没有记录时最快时间应为 -1")

	# 第一次通关：建立两条记录
	var r1: Dictionary = pr.record_win("level_01", _labels(6), 20000)
	check(int(r1["time_ms"]) == 20000, "返回值应回传本局用时")
	check(bool(r1["time_improved"]), "首次计时算破纪录")
	check(int(pr.best_time("level_01")) == 20000, "最快时间应被记录")
	check(pr.best_labels("level_01") == 6, "步数记录不受计时影响")

	# 更慢但步数更少：步数纪录刷新，时间纪录**不该**被改坏（这是最容易写错的地方）
	var r2: Dictionary = pr.record_win("level_01", _labels(4), 35000)
	check(bool(r2["improved"]), "步数更少应刷新步数纪录")
	check(not bool(r2["time_improved"]), "更慢的一局不算时间纪录")
	check(int(pr.best_time("level_01")) == 20000, "更慢的一局不能覆盖最快时间")
	check(int(r2["prev_best_time"]) == 20000, "返回值应带出旧的时间纪录")
	check(pr.replay("level_01")["move_count"] == 4, "回放跟的是步数纪录（4 步）")

	# 步数更多但更快
	var r3: Dictionary = pr.record_win("level_01", _labels(9), 12000)
	check(not bool(r3["improved"]), "步数更多不应刷新步数纪录")
	check(bool(r3["time_improved"]), "更快的一局应刷新时间纪录")
	check(int(pr.best_time("level_01")) == 12000, "最快时间应更新为 12000")
	check(pr.best_labels("level_01") == 4, "最快时间不能反向改坏步数纪录")

	# 落盘后重新读取
	var pr2 = Progress.new(tmp)
	check(int(pr2.best_time("level_01")) == 12000, "最快时间应能持久化")
	check(pr2.best_time_count() == 1, "有计时记录的关卡数应为 1")
	var rs: Array = pr2.runs("level_01")
	check(rs.size() == 3, "本机榜应有三局")
	var any_time := false
	for r in rs:
		if int(r.get("time_ms", -1)) == 12000:
			any_time = true
	check(any_time, "本机榜每局都应带自己的用时")

	# 未计时的调用（time_ms 缺省）不能污染时间记录
	var pr3 = Progress.new(tmp)
	var r4: Dictionary = pr3.record_win("level_02", _labels(3))
	check(int(r4["time_ms"]) == -1, "缺省用时为 -1（未计时）")
	check(not bool(r4["time_improved"]), "未计时的一局不算时间纪录")
	check(pr3.best_time("level_02") < 0, "未计时的一局不应写入最快时间")

	# 重置要连时间一起清掉
	pr3.reset()
	check(pr3.best_time("level_01") < 0, "重置进度应清掉最快时间")
	check(pr3.best_time_count() == 0, "重置后计时记录数应为 0")
	_remove(tmp)



func _labels(n: int) -> Array:
	var out: Array = []
	for _i in range(n):
		out.append("right")
	return out


func _test_reset() -> void:
	var p = Progress.new(TMP)
	p.record_win("level_01", ["right"])
	check(p.completed_count() == 1, "重置前应有记录")
	p.reset()
	check(p.completed_count() == 0, "重置后应清空通关记录")
	check(not p.has_replay("level_01"), "重置后应清空回放")
	var q = Progress.new(TMP)
	check(q.completed_count() == 0, "重置结果应已落盘")


func _test_reset_campaign() -> void:
	# 「再玩一遍」用的语义：**只清本轮通关进度**。
	# 必须区分两套「通关」：
	#   _completed → 本轮（进度展示 / 顺序解锁的“这一轮” / 庆祝判据）
	#   _ever      → 曾经通关过（解锁依据 + 记录展示），只增不减
	# 混用会踩两个坑：清不掉 → 第二轮打完不再有庆祝；全清 → 没收玩家记录并重锁关卡。
	var p = Progress.new(TMP)
	p.reset()
	p.record_win("level_01", ["right", "down"])
	p.record_win("level_02", ["left"])
	check(p.is_completed("level_01") and p.has_ever_cleared("level_01"), "通关后两个口径都应为真")
	check(not p.replay_round(), "进度与历史一致时不算“重玩一轮”")

	p.reset_campaign()
	check(p.completed_count() == 0, "再玩一遍应清空本轮进度")
	check(p.ever_count() == 2, "再玩一遍应保留历史通关记录")
	check(not p.is_completed("level_01"), "本轮口径应变为未通关")
	check(p.has_ever_cleared("level_01"), "历史口径应仍为通关")
	check(p.best_moves("level_01") == 2, "再玩一遍不应动最佳步数")
	check(p.has_replay("level_01"), "再玩一遍不应删掉最佳回放")
	check(p.runs("level_01").size() > 0, "再玩一遍不应清本机榜")
	check(p.replay_round(), "本轮未补满而历史已满 → 应识别为“重玩一轮”状态")
	# 解锁依据是历史：重玩时不能把已解锁的关卡重新锁上
	var keys: Array = ["level_01", "level_02", "level_03"]
	check(p.is_unlocked(1, keys), "再玩一遍后第 2 关应仍解锁（依据历史）")
	check(p.is_unlocked(2, keys), "再玩一遍后第 3 关应仍解锁（依据历史）")

	# 落盘后再读，两套口径都要能恢复
	var q = Progress.new(TMP)
	check(q.completed_count() == 0, "本轮进度应已落盘")
	check(q.ever_count() == 2, "历史通关应已落盘")
	check(q.replay_round(), "重玩状态应能从存档恢复")

	# 补满本轮后回到“非重玩”状态
	q.record_win("level_01", ["right"])
	q.record_win("level_02", ["right"])
	check(not q.replay_round(), "本轮补满后不应再是“重玩一轮”")

	# 老存档兼容：没有 cleared_ever 字段时用 completed 回填
	var legacy := TMP + ".legacy"
	DirAccess.remove_absolute(ProjectSettings.globalize_path(legacy))
	var f := FileAccess.open(legacy, FileAccess.WRITE)
	f.store_string('{"format":1,"completed":{"level_01":true},"best_moves":{"level_01":3},"replays":{},"runs":{}}')
	f.close()
	var r = Progress.new(legacy)
	check(r.is_completed("level_01"), "老存档的本轮进度应保留")
	check(r.has_ever_cleared("level_01"), "老存档应把 completed 回填为历史通关")
	check(r.is_unlocked(1, ["level_01", "level_02"]), "老存档的解锁应正常")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(legacy))

	# 彻底重置：连历史与解锁一起清
	q.reset()
	check(q.ever_count() == 0, "完全重置应清空历史通关")
	check(not q.is_unlocked(1, ["level_01", "level_02"]), "完全重置后第 2 关应重新锁定")
