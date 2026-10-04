# shapes.gd — 形状注册表 + 方向描述符解析。
#
# 设计：形状用「数据登记」而不是「代码分支」——
#   1) REGISTRY       id → 默认姿态的单元集合（已规范化，min 坐标为 0）
#   2) ORIENTATIONS   id → { 语义化描述符: 单元集合 }
# 于是「新增一种方块」= 加两行数据，resolve_orientation / 关卡加载 / 生成器
# 都不需要认识任何具体形状，也不会出现 `if id == "xxx"` 这类分支。
#
# 历史教训：曾经在这里登记过 cube（1×1×1）。单格方块在平面棋盘上没有任何姿态约束，
# 只能沿直线走到目标，玩起来“点几下就通关”；后来试图用冰面打滑机制救它，
# 结果变成“一滑就坠落”，体验更差。最终整个移除。
# 结论：**新形状必须自证好玩**——姿态约束或占地约束至少要占一样，
# 否则它带来的只是操作次数，不是思考。
extends RefCounted

const Shape = preload("res://core/shape.gd")

# 形状注册表：id → 默认姿态（沿 X 横躺）
const REGISTRY := {
	"domino": [Vector3i(0, 0, 0), Vector3i(1, 0, 0)],
}

# 语义化方向表：关卡 JSON 里可以写 "standing" 这类可读名字，而不是裸索引
const ORIENTATIONS := {
	"domino": {
		"lying_x": [Vector3i(0, 0, 0), Vector3i(1, 0, 0)],
		"lying_z": [Vector3i(0, 0, 0), Vector3i(0, 0, 1)],
		"standing": [Vector3i(0, 0, 0), Vector3i(0, 1, 0)],
	},
}

# 形状的玩家可见名字（UI 层用；空串表示未知形状）
const DISPLAY_NAMES := {
	"domino": "骨牌",
}


static func ids() -> Array:
	return REGISTRY.keys()


static func get_shape(id: String):
	if not REGISTRY.has(id):
		return null
	return Shape.new(id, REGISTRY[id])


static func display_name(id: String) -> String:
	return preload("res://meta/i18n.gd").t(str(DISPLAY_NAMES.get(id, id)))


static func orientation_names(id: String) -> Array:
	# 该形状可用的语义化方向名（生成器随机选起始姿态时用）
	var table: Dictionary = ORIENTATIONS.get(id, {})
	var names: Array = table.keys()
	names.sort()   # 确定性
	return names


static func resolve_orientation(shape, descriptor) -> int:
	# 整数索引直接用；字符串走语义化表；未知 → -1（由调用方报 bad_orientation）
	if descriptor is int:
		return descriptor
	if descriptor is String and ORIENTATIONS.has(shape.id):
		var table: Dictionary = ORIENTATIONS[shape.id]
		if table.has(descriptor):
			return shape.orientation_for_cells(table[descriptor])
	return -1
