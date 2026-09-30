# shape.gd — PolyCube 形状：id + 局部单元集合（整数坐标）。
# 局部坐标已规范化（最小坐标移到原点），使「位置」定义稳定。
# 这是工作流「规则与引擎解耦」的核心：Shape 不依赖任何 Node/场景。
extends RefCounted

const Rot = preload("res://core/rotations.gd")
const Util = preload("res://core/util.gd")

var id: String = ""
var cells: Array = []  # Array[Vector3i]，局部坐标（已规范化，min = 0）


func _init(p_id: String = "", p_cells: Array = []) -> void:
	id = p_id
	cells = normalize_cells(p_cells)


static func normalize_cells(p_cells: Array) -> Array:
	if p_cells.is_empty():
		return []
	var min_v: Vector3i = p_cells[0]
	for c in p_cells:
		min_v = Vector3i(min(min_v.x, c.x), min(min_v.y, c.y), min(min_v.z, c.z))
	var out: Array = []
	for c in p_cells:
		out.append(c - min_v)
	return out


func oriented_cells(orientation: int) -> Array:
	# 该形状在给定方向下的局部单元（尚未加 position 平移）
	var m: Array = Rot.all_orientations()[orientation]
	var out: Array = []
	for c in cells:
		out.append(Rot.apply(m, c))
	return out


func orientation_for_cells(target: Array) -> int:
	# 找到使 oriented_cells() 与 target 单元集合一致的方向索引；找不到返回 -1
	var norm_target: Array = normalize_cells(target)
	for i in range(Rot.all_orientations().size()):
		if _same_cell_set(oriented_cells(i), norm_target):
			return i
	return -1


func footprint_of(oriented: Array) -> Array:
	# 忽略高度的占地集合（Array[Vector2i]，去重）
	var s: Dictionary = {}
	for c in oriented:
		s[Vector2i(c.x, c.z)] = true
	return s.keys()


static func _same_cell_set(a: Array, b: Array) -> bool:
	if a.size() != b.size():
		return false
	var sa: Array = Util.sort_cells(a)
	var sb: Array = Util.sort_cells(b)
	for i in range(sa.size()):
		if sa[i] != sb[i]:
			return false
	return true
