# board.gd — 关卡棋盘：网格、空洞、目标，以及合法性/胜负判定。
#
# 「空洞」= 地面缺失（踩空即坠落），不是装饰性暗格；越界同样属于「没有地面」。
# 因此“能不能站住”只有一个依据：is_solid() / supports()。
# 机关扩展点：set_void() 可把实心格动态变成空洞（或恢复），判定自动跟随，
# 不需要在任何地方写死“黑洞表”。
#
# MVP 假设：棋盘是平面（所有实心单元 y=0），无高度差、无叠放。
extends RefCounted

var id: String = ""
var grid_x: int = 8
var grid_z: int = 8
var holes: Array = []   # Array[Vector2i] (x,z)，空洞（无地面）
var goal: Array = []    # Array[Vector2i] (x,z)


func _init(p_id: String = "", p_grid_x: int = 8, p_grid_z: int = 8, p_holes: Array = [], p_goal: Array = []) -> void:
	id = p_id
	grid_x = p_grid_x
	grid_z = p_grid_z
	holes = p_holes.duplicate()
	goal = p_goal.duplicate()


func is_inside(cell: Vector3i) -> bool:
	return cell.x >= 0 and cell.x < grid_x and cell.z >= 0 and cell.z < grid_z


func is_void(cell: Vector3i) -> bool:
	# 空洞：棋盘内但没有地面
	return holes.has(Vector2i(cell.x, cell.z))


func is_hole(cell: Vector3i) -> bool:
	# 兼容旧名：洞 = 空洞
	return is_void(cell)


func is_solid(cell: Vector3i) -> bool:
	# 有地面 = 在棋盘内 且 不是空洞。“是否踩空”的唯一判定。
	return is_inside(cell) and not is_void(cell)


func set_void(v2: Vector2i, on: bool = true) -> void:
	# 机关扩展点：把某格变为 / 恢复为空洞（实心 ↔ 空洞）
	var has: bool = holes.has(v2)
	if on and not has:
		holes.append(v2)
	elif not on and has:
		holes.erase(v2)


func supports(world_cells: Array) -> bool:
	# 方块所有占用单元都必须落在实心格上（MVP 平面棋盘）
	for c in world_cells:
		if not is_solid(c):
			return false
	return true


func footprint(world_cells: Array) -> Array:
	# 忽略高度的占地集合（Array[Vector2i]，去重）
	var s: Dictionary = {}
	for c in world_cells:
		s[Vector2i(c.x, c.z)] = true
	return s.keys()


func is_goal(world_cells: Array) -> bool:
	# 胜负：占地集合与目标集合完全一致（例如骨牌需「竖立」在目标格上）
	var fp: Array = footprint(world_cells)
	if fp.size() != goal.size():
		return false
	for g in goal:
		if not fp.has(g):
			return false
	return true
