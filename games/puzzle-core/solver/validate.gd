# validate.gd — 关卡质检门：合法性(Schema) → 可解性(Solver) → 难度。
# 这是 AI 生成关卡流水线的核心过滤环节：产出结构化报告，供智能体/CI 决策。
extends RefCounted

const Loader = preload("res://core/level_loader.gd")
const Solver = preload("res://solver/solver.gd")
const Board = preload("res://core/board.gd")
const Mechanisms = preload("res://core/mechanisms.gd")


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

	# 5b. 机关的表结构检查（坐标、id、引用、成对性）
	_check_mechanisms(board, errors, warnings)

	if errors.size() > 0:
		return _report(board.id, "invalid", errors, warnings)

	# 6. 可解性 + 难度（机关状态自动进入搜索空间）
	var sol: Dictionary = Solver.new(board, start).solve()
	if not sol["solvable"]:
		return _report(board.id, "unsolvable", errors, warnings, sol)

	# 7. **机关是否承重** —— 自动化「好不好玩」的过滤器
	#    把关卡里的机关全部去掉再解一次：
	#      * 仍然可解且步数一样   → 机关是装饰品（玩家永远不需要理解它），警告
	#      * 不可解 / 步数变长     → 机关是承重的，通过
	#    （"好玩"里能自动化的就是这一部分；观感与节奏仍然要人看图决定）
	if board.has_mechanisms():
		var need: int = int(sol["optimal_moves"])
		var alt: Dictionary = Solver.new(_control_board(board), start).solve()
		if bool(alt["solvable"]) and int(alt["optimal_moves"]) > need:
			# 有机关时更短 → 机关在帮忙（正向，不算问题）
			warnings.append("mechanisms help：%s 后需 %d 步（带机关 %d）"
				% [_control_desc(board), int(alt["optimal_moves"]), need])
		elif bool(alt["solvable"]) and int(alt["optimal_moves"]) == need:
			# 步数完全一样 → 玩家永远不需要理解这个机关（装饰品）
			warnings.append("mechanisms are decorative：%s 后仍可解且步数相同（%d 步）"
				% [_control_desc(board), need])
		elif bool(alt["solvable"]):
			# 去掉机关反而更快 → 机关在添乱（设计味道，必须报出来）
			warnings.append("mechanisms hurt：%s 后只需 %d 步，带机关反而要 %d 步"
				% [_control_desc(board), int(alt["optimal_moves"]), need])

	return _report(board.id, "valid", errors, warnings, sol)


static func _control_board(board):
	# 构造「对照盘」：用来判断机关到底承不承重。
	# **必须按机关类型分别对照**，否则会得出错误结论：
	#   bridge/gate/portal：去掉机关 → 那些格子回到"纯空洞"（桥/传送门消失）
	#   fragile          ：把碎裂砖换成**普通实心格**（"如果能反复走会不会更短"）
	#                        —— 直接删掉 fragile 会把它变成空洞，那是另一个问题（路没了），
	#                        测不出"碎裂"这个性质本身有没有用。
	var fragile_tiles: Array = Mechanisms.tiles_of(board.mechanisms, "fragile")
	var holes: Array = board.holes.duplicate()
	for t in fragile_tiles:
		holes.erase(t)   # 碎裂砖下面的格子变回实心（它们本来就是地面）
	# 对照盘**不带任何机关**（这里曾经写反过：把非 fragile 的机关留了下来 →
	# 对照盘其实带机关，于是"去掉机关后仍可解"永远成立，所有机关都被误报成装饰品）
	return Board.new(board.id, board.grid_x, board.grid_z, holes, board.goal, [])


static func _control_desc(board) -> String:
	return "把碎裂砖换成普通实心格" if not Mechanisms.tiles_of(board.mechanisms, "fragile").is_empty() \
		else "去掉机关"


static func _check_mechanisms(board, errors: Array, warnings: Array) -> void:
	var ids: Dictionary = {}
	for d in board.mechanisms:
		var id: String = str(d["id"])
		var kind: String = str(d["kind"])
		if id == "":
			errors.append("mechanism without id (kind=%s)" % kind)
		elif ids.has(id):
			errors.append("duplicate mechanism id: " + id)
		else:
			ids[id] = true
		var pool: Array = d["tiles"] if kind != "portal" else d["links"]
		if pool.is_empty():
			errors.append("mechanism %s (%s) has no tiles" % [id, kind])
		for t in pool:
			var cell := Vector3i(t.x, 0, t.y)
			if not board.is_inside(cell):
				errors.append("mechanism %s tile out of bounds: %s" % [id, str(t)])
		if kind == "portal" and pool.size() < 2:
			errors.append("portal %s needs at least 2 linked tiles" % id)
		if kind == "switch":
			var target: String = str(d["target"])
			if target == "":
				errors.append("switch %s has no target" % id)
			else:
				var td: Dictionary = Mechanisms.find(board.mechanisms, target)
				if td.is_empty():
					errors.append("switch %s targets unknown mechanism: %s" % [id, target])
				elif str(td["kind"]) not in ["bridge", "gate"]:
					errors.append("switch %s should target a bridge/gate, got %s" % [id, str(td["kind"])])


static func _report(id: String, status: String, errors: Array, warnings: Array, sol: Dictionary = {}) -> Dictionary:
	var r: Dictionary = {"level_id": id, "status": status, "errors": errors, "warnings": warnings}
	for k in sol:
		r[k] = sol[k]
	return r
