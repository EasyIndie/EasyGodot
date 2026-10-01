# solver.gd — BFS 求解器：可解性、最优解路径、状态空间指标、难度分级。
# 输入：board + start；输出结构化结果（供关卡验证、难度筛选、AI 生成使用）。
extends RefCounted

const Moves = preload("res://core/moves.gd")
const Core = preload("res://core/puzzle_core.gd")
const Mech = preload("res://core/mechanisms.gd")

var board = null   # Board 实例
var start = null   # PuzzleState 实例


func _init(p_board = null, p_start = null) -> void:
	board = p_board
	start = p_start


func _key(state, mech) -> String:
	# **关键**：状态键必须同时包含方块占用单元与机关状态。
	# 只比占用单元的话，「桥已开」和「桥已关」会被当成同一个状态 → 求解器会返回
	# 一条实际走不通的"解"（而且这种错在简单关卡里看不出来）。
	return state.canonical_key() + "|" + (mech.key() if mech != null else "")


func solve(mech = null) -> Dictionary:
	# BFS 从起点搜索目标，保证找到的是最短解（最少步数）。
	# 机关状态（桥的开合 / 已碎格子）是搜索空间的一部分，见 _key()。
	var visited: Dictionary = {}
	var depth: Dictionary = {}
	var parent: Dictionary = {}
	var k0: String = _key(start, mech)
	var q: Array = [{"state": start, "mech": mech}]
	visited[k0] = true
	depth[k0] = 0
	var goal_node = null

	while q.size() > 0:
		var node: Dictionary = q.pop_front()
		var cur = node["state"]
		var cur_mech = node["mech"]
		if Mech.is_goal(board, board.mechanisms, cur_mech, cur.world_cells()):
			goal_node = node
			break
		var ck: String = _key(cur, cur_mech)
		for i in range(Moves.DIRS.size()):
			# 注意：apply_step 可能返回 null，所以**不能**声明为 Dictionary（GDScript 不允许 null 赋给类型化变量）
			var step = Core.apply_step(board, cur, cur_mech, Moves.DIRS[i])
			if step == null or bool(step["fall"]):
				# 走不过去 / 落上去会掉下去 —— 都不是可解路径上的一步
				continue
			var k: String = _key(step["state"], step["mech"])
			if visited.has(k):
				continue
			visited[k] = true
			depth[k] = depth[ck] + 1
			parent[k] = {"state": cur, "mech": cur_mech, "dir_index": i}
			q.append({"state": step["state"], "mech": step["mech"]})

	if goal_node == null:
		return {
			"solvable": false,
			"reachable_states": visited.size(),
			"optimal_moves": -1,
			"solution": [],
			"difficulty": "unsolvable",
		}

	var gk: String = _key(goal_node["state"], goal_node["mech"])
	var path: Array = []
	var k: String = gk
	while parent.has(k):
		path.push_front(Moves.DIR_LABELS[parent[k]["dir_index"]])
		k = _key(parent[k]["state"], parent[k]["mech"])

	return {
		"solvable": true,
		"reachable_states": visited.size(),
		"optimal_moves": depth[gk],
		"solution": path,
		"difficulty": grade(depth[gk], visited.size()),
	}


static func grade(optimal_moves: int, reachable_states: int) -> String:
	# 难度分级：以最优步数为主。
	# reachable_states（可达状态数）作为复杂度指标单独上报，不参与本分级——
	# 它跟盘面大小强相关，对玩家的实际难度贡献远不如“最少几步”。
	if optimal_moves < 0:
		return "unsolvable"
	var m: int = optimal_moves
	if m <= 4:
		return "easy"
	if m <= 9:
		return "medium"
	if m <= 16:
		return "hard"
	return "expert"
