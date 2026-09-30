# solver.gd — BFS 求解器：可解性、最优解路径、状态空间指标、难度分级。
# 输入：board + start；输出结构化结果（供关卡验证、难度筛选、AI 生成使用）。
extends RefCounted

const Moves = preload("res://core/moves.gd")
const Core = preload("res://core/puzzle_core.gd")

var board = null   # Board 实例
var start = null   # PuzzleState 实例


func _init(p_board = null, p_start = null) -> void:
	board = p_board
	start = p_start


func solve() -> Dictionary:
	# BFS 从起点搜索目标，保证找到的是最短解（最少步数）
	var visited: Dictionary = {}
	var depth: Dictionary = {}
	var parent: Dictionary = {}
	var q: Array = [start]
	visited[start.canonical_key()] = true
	depth[start.canonical_key()] = 0
	var goal_state = null

	while q.size() > 0:
		var cur = q.pop_front()
		if board.is_goal(cur.world_cells()):
			goal_state = cur
			break
		for i in range(Moves.DIRS.size()):
			var ns = Core.apply_move_on(board, cur, Moves.DIRS[i])
			if ns == null:
				continue
			var k: String = ns.canonical_key()
			if visited.has(k):
				continue
			visited[k] = true
			depth[k] = depth[cur.canonical_key()] + 1
			parent[k] = {"state": cur, "dir_index": i}
			q.append(ns)

	if goal_state == null:
		return {
			"solvable": false,
			"reachable_states": visited.size(),
			"optimal_moves": -1,
			"solution": [],
			"difficulty": "unsolvable",
		}

	var gk: String = goal_state.canonical_key()
	var path: Array = []
	var k: String = gk
	while parent.has(k):
		path.push_front(Moves.DIR_LABELS[parent[k]["dir_index"]])
		k = parent[k]["state"].canonical_key()

	return {
		"solvable": true,
		"reachable_states": visited.size(),
		"optimal_moves": depth[gk],
		"solution": path,
		"difficulty": grade(depth[gk], visited.size(), str(goal_state.mechanism.get("move", ""))),
	}


static func grade(optimal_moves: int, reachable_states: int, mechanic: String = "") -> String:
	# 难度分级：以最优步数为主要依据（阈值可调）。
	# reachable_states 作为复杂度补充指标单独上报，不参与本分级。
	if optimal_moves < 0:
		return "unsolvable"
	var m: int = optimal_moves
	if mechanic == "ice":
		# 冰面上一次移动 = 连续翻滚好几格，玩家真正做的是「选方向」而非「走一步」，
		# 决策密度远高于普通关卡，难度不能按步数直接比 —— 这里做保守折算。
		m = optimal_moves * 3
	if m <= 4:
		return "easy"
	if m <= 9:
		return "medium"
	if m <= 16:
		return "hard"
	return "expert"
