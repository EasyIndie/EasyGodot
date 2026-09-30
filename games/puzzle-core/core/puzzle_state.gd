# puzzle_state.gd — 一个可序列化的谜题状态。
# 状态 = shape + orientation + position + mechanism（未来机关扩展点）。
# 唯一不变式：world_cells() 是所有判定（合法性/胜负/求解去重）的唯一依据。
extends RefCounted

const Util = preload("res://core/util.gd")

var shape = null          # Shape 实例
var orientation: int = 0  # 24 方向之一
var position: Vector3i = Vector3i.ZERO
var mechanism: Dictionary = {}


func _init(p_shape = null, p_orientation: int = 0, p_position: Vector3i = Vector3i.ZERO, p_mechanism: Dictionary = {}) -> void:
	shape = p_shape
	orientation = p_orientation
	position = p_position
	mechanism = p_mechanism.duplicate()


func cells_at(orient: int, pos: Vector3i) -> Array:
	# 给定方向与位置下的世界单元集合（Array[Vector3i]）
	var out: Array = []
	for c in shape.oriented_cells(orient):
		out.append(c + pos)
	return out


func world_cells() -> Array:
	return cells_at(orientation, position)


func canonical_key() -> String:
	# 用于求解器去重的规范键：按世界单元排序后的字符串
	var cs: Array = Util.sort_cells(world_cells())
	var s := ""
	for c in cs:
		s += "%d,%d,%d;" % [c.x, c.y, c.z]
	return s


func to_dict() -> Dictionary:
	return {
		"shape": shape.id,
		"orientation": orientation,
		"position": [position.x, position.y, position.z],
		"mechanism": mechanism.duplicate(),
	}
