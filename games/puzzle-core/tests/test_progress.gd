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
	_test_fresh()
	_test_record_win()
	_test_persistence()
	_test_unlock_rule()
	_test_corrupt_save()
	_test_replay_label_contract()
	_test_reset()
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


func _test_reset() -> void:
	var p = Progress.new(TMP)
	p.record_win("level_01", ["right"])
	check(p.completed_count() == 1, "重置前应有记录")
	p.reset()
	check(p.completed_count() == 0, "重置后应清空通关记录")
	check(not p.has_replay("level_01"), "重置后应清空回放")
	var q = Progress.new(TMP)
	check(q.completed_count() == 0, "重置结果应已落盘")
