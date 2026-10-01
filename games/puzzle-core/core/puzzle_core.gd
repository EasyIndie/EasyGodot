# puzzle_core.gd — 门面：状态 + 棋盘 的组合操作。
# 供求解器、测试、视觉层、AI 生成器共同使用（共享同一份规则核心）。
extends RefCounted

const Moves = preload("res://core/moves.gd")
const State = preload("res://core/puzzle_state.gd")
const MechState = preload("res://core/mech_state.gd")
const Mech = preload("res://core/mechanisms.gd")

var board = null   # Board 实例
var state = null   # PuzzleState 实例


func _init(p_board = null, p_state = null) -> void:
	board = p_board
	state = p_state


func legal_moves(mech = null) -> Array:
	# 返回可合法执行的 4 个方向（Array[Vector3i]）
	var out: Array = []
	for d in Moves.DIRS:
		if apply_step(board, state, mech, d) != null:
			out.append(d)
	return out


func apply_move(d: Vector3i, mech = null):
	var r: Dictionary = apply_step(board, state, mech, d)
	return null if r == null else r["state"]


static func apply_move_on(p_board, p_state, d: Vector3i):
	# 兼容入口（无机关关卡）：内部走同一个 apply_step，避免出现两套步进实现
	var r: Dictionary = apply_step(p_board, p_state, null, d)
	return null if r == null else r["state"]


static func apply_step(p_board, p_state, mech, d: Vector3i):
	# **唯一的步进实现**（纯函数：不修改任何入参）。
	# 返回值：
	#   null                                 → 这一步不成立（目标格在当前机关状态下没有地面）
	#   {"state": s, "mech": m, "fall": f}   → 成立；fall=true 表示"落上去之后地面消失"
	#                                          （例如自己把脚下的桥关掉了）→ 调用方播坠落动画
	# 机关的三个时机都在这里，顺序不能乱：
	#   ① 用**移动前**的机关状态判断能不能落过去（桥还没开就是过不去）
	#   ② 传送（姿态不变）
	#   ③ 落点上的开关生效 / 刚离开的碎裂砖碎掉
	var defs: Array = p_board.mechanisms
	var r: Dictionary = Moves.roll_delta(p_state.shape, p_state.orientation, d)
	var new_pos: Vector3i = p_state.position + r["delta"]
	var to_cells: Array = p_state.cells_at(r["orientation"], new_pos)
	if not Mech.supports(p_board, defs, mech, to_cells):
		return null
	var nxt = State.new(p_state.shape, r["orientation"], new_pos)
	var left_cells: Array = p_state.world_cells()
	var m = mech
	# ② 传送：进到传送格就换位置（姿态不变）。落点如果站不住 → 一样是坠落。
	if not defs.is_empty():
		var tp: Dictionary = Mech.teleport(p_board, defs, nxt, m)
		if bool(tp["moved"]):
			nxt = tp["state"]
			if not Mech.supports(p_board, defs, m, nxt.world_cells()):
				return {"state": nxt, "mech": m, "fall": true}
		# ③ 机关效果（开关 / 碎裂）
		m = Mech.on_enter(p_board, defs, m, nxt.world_cells(), left_cells)
	var fall: bool = not Mech.supports(p_board, defs, m, nxt.world_cells())
	return {"state": nxt, "mech": m, "fall": fall}


func is_goal(s = null) -> bool:
	var st = state if s == null else s
	return board.is_goal(st.world_cells())


func is_valid(s = null, mech = null) -> bool:
	var st = state if s == null else s
	return Mech.supports(board, board.mechanisms, mech, st.world_cells())
