# shapes.gd — 形状注册表 + 方向描述符解析。
# 新形状只需在此登记即可被关卡 JSON 引用。
extends RefCounted

const Shape = preload("res://core/shape.gd")

# 常用局部单元（见形状定义）
const CELL_LYING_X: Array = [Vector3i(0, 0, 0), Vector3i(1, 0, 0)]
const CELL_LYING_Z: Array = [Vector3i(0, 0, 0), Vector3i(0, 0, 1)]
const CELL_STANDING: Array = [Vector3i(0, 0, 0), Vector3i(0, 1, 0)]


static func get_shape(id: String):
	match id:
		"domino":
			return Shape.new("domino", CELL_LYING_X)   # 默认方向 = 沿 X 横躺
		"cube":
			return Shape.new("cube", [Vector3i(0, 0, 0)])
	return null


# 关卡 JSON 中 start.orientation 支持整数索引，或以下语义化描述符
static func resolve_orientation(shape, descriptor) -> int:
	if descriptor is int:
		return descriptor
	if shape.cells.size() == 1:
		# 单格形状（如 cube）：所有姿态在规则上等价，任何描述符都映射到 0（identity）
		return 0
	if descriptor is String:
		match descriptor:
			"lying_x":
				return 0 if shape.id == "domino" else shape.orientation_for_cells(CELL_LYING_X)
			"lying_z":
				return shape.orientation_for_cells(CELL_LYING_Z)
			"standing":
				return shape.orientation_for_cells(CELL_STANDING)
	return -1
