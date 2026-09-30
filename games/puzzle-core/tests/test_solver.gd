# test_solver.gd — 求解器 + 质检门测试（headless 运行）。
extends SceneTree

const Moves = preload("res://core/moves.gd")
const Core = preload("res://core/puzzle_core.gd")
const Loader = preload("res://core/level_loader.gd")
const Solver = preload("res://solver/solver.gd")
const Validate = preload("res://solver/validate.gd")
const Fixtures = preload("res://tests/fixtures.gd")

var checks: int = 0
var failures: int = 0


func _init() -> void:
	_test_grade()
	_test_solve_fixture()
	_test_replay_solution()
	_test_validate_valid()
	_test_validate_invalid()
	_test_validate_unsolvable()

	var result: Dictionary = {
		"suite": "test_solver",
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


func _load(path: String) -> Dictionary:
	var lv: Dictionary = Loader.load_file(path)
	return lv


# ---- 测试组 ----

func _test_grade() -> void:
	check(Solver.grade(3, 100) == "easy", "3 步应 easy")
	check(Solver.grade(8, 100) == "medium", "8 步应 medium")
	check(Solver.grade(15, 100) == "hard", "15 步应 hard")
	check(Solver.grade(20, 100) == "expert", "20 步应 expert")
	check(Solver.grade(-1, 10) == "unsolvable", "负步数应 unsolvable")


func _test_solve_fixture() -> void:
	var lv: Dictionary = Loader.load_dict(Fixtures.level_8moves())
	var sol: Dictionary = Solver.new(lv["board"], lv["start"]).solve()
	check(sol["solvable"], "夹具应可解")
	check(sol["optimal_moves"] == 8, "夹具最优应为 8 步，got=" + str(sol["optimal_moves"]))
	check(sol["solution"].size() == 8, "解路径应为 8 步")
	check(sol["difficulty"] == "medium", "夹具难度应为 medium")
	check(sol["reachable_states"] > 0, "可达状态数应 > 0")


func _test_replay_solution() -> void:
	# 验证解路径真实可行：逐步应用解，最终应达成目标
	var lv: Dictionary = Loader.load_dict(Fixtures.level_8moves())
	var board = lv["board"]
	var cur = lv["start"]
	var sol: Dictionary = Solver.new(board, cur).solve()
	for label in sol["solution"]:
		var d: Vector3i = Moves.direction_from_label(label)
		cur = Core.apply_move_on(board, cur, d)
		check(cur != null, "解中的移动应合法: " + str(label))
	check(board.is_goal(cur.world_cells()), "应用完整解后应达成目标")


func _test_validate_valid() -> void:
	var r: Dictionary = Validate.validate_dict(Fixtures.level_8moves())
	check(r["status"] == "valid", "合法关卡应 valid: " + str(r["errors"]))
	check(r["solvable"], "合法关卡应可解")
	check(r["optimal_moves"] == 8, "最优步数应一致")


func _test_validate_invalid() -> void:
	# 目标在洞上 → invalid
	var r: Dictionary = Validate.validate_dict({
		"id": "bad_goal", "grid": {"x": 4, "z": 4},
		"holes": [[3, 3]], "goal": [[3, 3]],
		"start": {"shape": "domino", "orientation": "standing", "position": [0, 0, 0]},
	})
	check(r["status"] == "invalid", "目标在洞上应 invalid")
	check(r["errors"].size() > 0, "应有错误信息")

	# 起点悬空（在洞上）→ invalid
	var r2: Dictionary = Validate.validate_dict({
		"id": "bad_start", "grid": {"x": 4, "z": 4},
		"holes": [[0, 0]], "goal": [[3, 3]],
		"start": {"shape": "domino", "orientation": "standing", "position": [0, 0, 0]},
	})
	check(r2["status"] == "invalid", "起点在洞上应 invalid")


func _test_validate_unsolvable() -> void:
	# 两个孤立平台互不相连 → 起点合法但目标不可达 → unsolvable
	var r: Dictionary = Validate.validate_dict({
		"id": "disconnected", "grid": {"x": 4, "z": 4},
		"holes": [[0, 1], [0, 2], [0, 3], [1, 0], [1, 1], [1, 2], [1, 3], [2, 0], [2, 1], [2, 2], [2, 3], [3, 0], [3, 1], [3, 2]],
		"goal": [[3, 3]],
		"start": {"shape": "domino", "orientation": "standing", "position": [0, 0, 0]},
	})
	check(r["status"] == "unsolvable", "孤立起点应 unsolvable: " + str(r))
