# test_generator.gd — 关卡生成器测试（headless）。
extends SceneTree

const Shapes = preload("res://core/shapes.gd")
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
	# 起始姿态由**形状自己的方向表**决定：生成器不该认识任何具体形状。
	# 因此每个生成的关卡，其 orientation 都必须是该形状方向表里的名字。
	var gen = Generator.new()
	var names: Array = Shapes.orientation_names("domino")
	check(names.size() == 3, "domino 应有 3 个语义方向")
	var res: Dictionary = gen.generate(11, 6, 6, 0.10, "any", 5, 1, "domino")
	check(res["levels"].size() == 5, "应生成 5 个关卡，got=" + str(res["levels"].size()))
	var seen_orient: Dictionary = {}
	for lv in res["levels"]:
		check(lv["start"]["shape"] == "domino", "起始形状应为 domino")
		check(names.has(str(lv["start"]["orientation"])), "起始姿态应取自方向表")
		seen_orient[str(lv["start"]["orientation"])] = true
		var r: Dictionary = Validate.validate_dict(lv)
		check(r["status"] == "valid", "生成的关卡应合法: " + str(r["errors"]))
		check(int(r["optimal_moves"]) >= 1, "关卡应可解")
	check(seen_orient.size() > 1, "多次生成应覆盖到多种起始姿态")

	# 生成的关卡 JSON 不应带任何机关字段（机制已移除，不在产物里留痕）
	check(not res["levels"][0].has("mechanic"), "生成的关卡不应含 mechanic 字段")


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
