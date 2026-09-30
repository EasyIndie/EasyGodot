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


static func apply_move_on(p_board, p_state, d: Vector3i):
	# 单次合法移动（纯函数语义：不修改入参状态，返回新状态或 null）
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
