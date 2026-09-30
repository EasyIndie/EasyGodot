# test_generator.gd — 关卡生成器测试（headless）。
extends SceneTree

const Generator = preload("res://tools/level_generator.gd")
const Validate = preload("res://solver/validate.gd")

var checks: int = 0
var failures: int = 0


func _init() -> void:
	_test_generate_all_difficulties()
	_test_difficulty_filter()
	_test_determinism()
	_test_shape_option()
	_test_min_moves_filter()

	var result: Dictionary = {
		"suite": "test_generator",
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


func _test_generate_all_difficulties() -> void:
	# 固定种子，低洞密度，应能生成一批合法关卡
	var gen = Generator.new()
	var res: Dictionary = gen.generate(42, 5, 5, 0.10, "any", 10, 1)
	check(res["levels"].size() == 10, "应生成 10 关，got=" + str(res["levels"].size()) + " stats=" + str(res["stats"]))
	# 每关都应通过质检
	for lv in res["levels"]:
		var r: Dictionary = Validate.validate_dict(lv)
		check(r["status"] == "valid", "生成的关卡应合法: " + str(lv["id"]) + " " + str(r["errors"]))


func _test_difficulty_filter() -> void:
	var gen = Generator.new()
	var res: Dictionary = gen.generate(42, 6, 6, 0.10, "easy", 5, 1)
	check(res["levels"].size() == 5, "应生成 5 个 easy 关卡")
	for d in res["details"]:
		check(d["difficulty"] == "easy", "难度应全为 easy: " + str(d))


func _test_determinism() -> void:
	var g1 = Generator.new()
	var g2 = Generator.new()
	var r1: Dictionary = g1.generate(7, 5, 5, 0.15, "any", 8, 1)
	var r2: Dictionary = g2.generate(7, 5, 5, 0.15, "any", 8, 1)
	check(JSON.stringify(r1["levels"]) == JSON.stringify(r2["levels"]), "相同种子应可复现相同结果")


func _test_shape_option() -> void:
	# 生成器应支持指定形状：默认 domino，也能生成 cube（单格形状）
	var gen = Generator.new()
	var res: Dictionary = gen.generate(11, 6, 6, 0.10, "any", 5, 1, "cube")
	check(res["levels"].size() == 5, "应生成 5 个 cube 关卡，got=" + str(res["levels"].size()))
	for lv in res["levels"]:
		check(lv["start"]["shape"] == "cube", "起始形状应为 cube")
		var r: Dictionary = Validate.validate_dict(lv)
		check(r["status"] == "valid", "生成的 cube 关卡应合法: " + str(r["errors"]))
		check(int(r["optimal_moves"]) >= 1, "cube 关卡应可解")

	var d = Generator.new()
	var res2: Dictionary = d.generate(11, 5, 5, 0.10, "any", 3, 1)
	check(res2["levels"].size() == 3, "不传形状时应仍能生成")
	for lv in res2["levels"]:
		check(lv["start"]["shape"] == "domino", "默认形状应为 domino")


func _test_min_moves_filter() -> void:
	# min_moves 高时可能无法满足（尝试上限），但绝不应产出低于阈值的关卡
	var gen = Generator.new()
	var res: Dictionary = gen.generate(42, 5, 5, 0.10, "any", 10, 4)
	for d in res["details"]:
		check(int(d["optimal_moves"]) >= 4, "最优步数应 ≥ 4: " + str(d))
