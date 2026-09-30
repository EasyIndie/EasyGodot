# puzzle_core.gd — 门面：状态 + 棋盘 的组合操作。
# 供求解器、测试、视觉层、AI 生成器共同使用（共享同一份规则核心）。
extends RefCounted

const Moves = preload("res://core/moves.gd")
const State = preload("res://core/puzzle_state.gd")

var board = null   # Board 实例
var state = null   # PuzzleState 实例


func _init(p_board = null, p_state = null) -> void:
	board = p_board
	state = p_state


func legal_moves() -> Array:
	# 返回可合法执行的 4 个方向（Array[Vector3i]）
	var out: Array = []
	for d in Moves.DIRS:
		var r: Dictionary = Moves.roll_delta(state.shape, state.orientation, d)
		var new_pos: Vector3i = state.position + r["delta"]
		if board.supports(state.cells_at(r["orientation"], new_pos)):
			out.append(d)
	return out


func apply_move(d: Vector3i):
	return apply_move_on(board, state, d)


static func is_sliding(p_state) -> bool:
	# 冰面机制：一次「移动」= 沿该方向连续翻滚，直到**再滚一格就会踩空**为止。
	# 设计取舍：这机制**不引入累积状态**（没有“已碎裂/已访问”集合），
	# 所以状态规范键、求解器、状态空间全部不用改，而且状态空间反而更小。
	# 难度则很高：每一步都是一次不可微调的大位移，只能先想清楚再动手。
	return str(p_state.mechanism.get("move", "")) == "ice"


static func slide_path(p_board, p_state, d: Vector3i) -> Array:
	# 逐步路径 [{orientation, position, pivot}]；空数组表示第一步就踩空（坠落）
	var path: Array = []
	var cur = p_state
	# 上限保护：不可能走超过棋盘格子数
	var limit: int = p_board.grid_x * p_board.grid_z + 4
	for _i in range(limit):
		var r: Dictionary = Moves.roll_delta(cur.shape, cur.orientation, d)
		var next_pos: Vector3i = cur.position + r["delta"]
		if not p_board.supports(cur.cells_at(r["orientation"], next_pos)):
			break
		path.append({"orientation": r["orientation"], "position": next_pos, "pivot": r["pivot"]})
		cur = State.new(cur.shape, r["orientation"], next_pos, cur.mechanism)
	return path


static func apply_move_on(p_board, p_state, d: Vector3i):
	# 单次合法移动（纯函数语义：不修改入参状态，返回新状态或 null）
	if is_sliding(p_state):
		var path: Array = slide_path(p_board, p_state, d)
		if path.is_empty():
			return null   # 第一步就踩空 → 坠落（与边缘掉落一致）
		var last: Dictionary = path[path.size() - 1]
		return State.new(p_state.shape, int(last["orientation"]), last["position"], p_state.mechanism)
	var r: Dictionary = Moves.roll_delta(p_state.shape, p_state.orientation, d)
	var new_pos: Vector3i = p_state.position + r["delta"]
	if not p_board.supports(p_state.cells_at(r["orientation"], new_pos)):
		return null
	return State.new(p_state.shape, r["orientation"], new_pos, p_state.mechanism)


func is_goal(s = null) -> bool:
	var st = state if s == null else s
	return board.is_goal(st.world_cells())


func is_valid(s = null) -> bool:
	var st = state if s == null else s
	return board.supports(st.world_cells())
