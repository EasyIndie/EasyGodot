# validate.gd — 关卡质检门：合法性(Schema) → 可解性(Solver) → 难度。
# 这是 AI 生成关卡流水线的核心过滤环节：产出结构化报告，供智能体/CI 决策。
extends RefCounted

const Loader = preload("res://core/level_loader.gd")
const Solver = preload("res://solver/solver.gd")


static func validate_dict(data: Dictionary) -> Dictionary:
	var errors: Array = []
	var warnings: Array = []

	# 1. 加载（含结构合法性）
	var lv: Dictionary = Loader.load_dict(data)
	if lv.has("error"):
		errors.append("load: " + str(lv))
		return _report(str(data.get("id", "?")), "invalid", errors, warnings)

	var board = lv["board"]
	var start = lv["start"]

	# 2. 起点必须落在实心格上
	if not board.supports(start.world_cells()):
		errors.append("start not on solid ground")

	# 3. 目标非空且落在实心格上
	if board.goal.is_empty():
		errors.append("goal is empty")
	for g in board.goal:
		var cell := Vector3i(g.x, 0, g.y)
		if not board.is_inside(cell):
			errors.append("goal out of bounds: " + str(g))
		elif board.is_hole(cell):
			errors.append("goal on hole: " + str(g))

	# 4. 洞在棋盘内（越界视为警告）
	for h in board.holes:
		if not board.is_inside(Vector3i(h.x, 0, h.y)):
			warnings.append("hole out of bounds: " + str(h))

	# 5. 起点即目标（合法但无意义，警告）
	if board.is_goal(start.world_cells()):
		warnings.append("start is already at goal")

	if errors.size() > 0:
		return _report(board.id, "invalid", errors, warnings)

	# 6. 可解性 + 难度
	var sol: Dictionary = Solver.new(board, start).solve()
	if not sol["solvable"]:
		return _report(board.id, "unsolvable", errors, warnings, sol)

	return _report(board.id, "valid", errors, warnings, sol)


static func _report(id: String, status: String, errors: Array, warnings: Array, sol: Dictionary = {}) -> Dictionary:
	var r: Dictionary = {"level_id": id, "status": status, "errors": errors, "warnings": warnings}
	for k in sol:
		r[k] = sol[k]
	return r
