# moves.gd — 移动系统：roll（翻滚）。
# 通用几何定义：翻滚 = 绕「前下边」旋转 90°，等价于
#   new_orientation = M ∘ orientation
#   new_position    = position + (I - M) * (pivot - position)
# 其中 M 是绕轴 (d × up) 的 -90° 旋转（使顶部向 +d 倾倒）。
# 该定义对任意 PolyCube 都成立，已在 Domino/Cube 上验证与 Bloxorz 规则一致。
extends RefCounted

const Rot = preload("res://core/rotations.gd")

const UP := Vector3i(0, 1, 0)
const DIRS: Array = [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)]
const DIR_NAMES: Array = ["+x", "-x", "+z", "-z"]
# 人类可读方向名（用于 Replay / 排行榜 / 挑战链接），与 DIRS 顺序一一对应
const DIR_LABELS: Array = ["right", "left", "forward", "backward"]


static func roll_rotation(d: Vector3i) -> Array:
	# 翻滚旋转矩阵：绕轴 (d × up) 的 -90°
	var axis: Vector3i = Rot.cross(d, UP)
	return Rot.inverse(Rot.quarter_turn(axis))


static func roll_delta(shape, orientation: int, d: Vector3i) -> Dictionary:
	# 返回 {"orientation": int, "delta": Vector3i}，纯函数，不改状态
	var m: Array = roll_rotation(d)
	var ori_m: Array = Rot.all_orientations()[orientation]
	var new_orientation: int = Rot.index_of(Rot.compose(m, ori_m))

	# 以 position=0 计算前下边（pivot）的相对位置
	var rel: Array = shape.oriented_cells(orientation)
	var min_y: int = 0
	for c in rel:
		min_y = min(min_y, c.y)

	# 底部单元在 d 方向上的前缘坐标
	var d_sign: int = d.x if d.x != 0 else d.z
	var leading: int = 0
	var found: bool = false
	for c in rel:
		if c.y != min_y:
			continue
		var coord: int = c.x if d.x != 0 else c.z
		if not found:
			leading = coord
			found = true
		elif d_sign > 0:
			leading = max(leading, coord)
		else:
			leading = min(leading, coord)

	# 前缘面坐标 = leading + 0.5*d_sign；底面坐标 = min_y - 0.5
	var pivot := Vector3.ZERO
	if d.x != 0:
		pivot = Vector3(float(leading) + 0.5 * float(d_sign), float(min_y) - 0.5, 0.0)
	else:
		pivot = Vector3(0.0, float(min_y) - 0.5, float(leading) + 0.5 * float(d_sign))

	# Δp = (I - M) * pivot
	var im: Array = Rot.identity()
	var iminusm: Array = [im[0] - m[0], im[1] - m[1], im[2] - m[2]]
	var dpf: Vector3 = _apply_f(iminusm, pivot)
	var delta := Vector3i(roundi(dpf.x), roundi(dpf.y), roundi(dpf.z))

	# pivot 为「前下边」相对 position 的位置（供视觉层做绕边翻滚动画）
	return {"orientation": new_orientation, "delta": delta, "pivot": pivot}


static func _apply_f(m: Array, v: Vector3) -> Vector3:
	return Vector3(m[0]) * v.x + Vector3(m[1]) * v.y + Vector3(m[2]) * v.z


static func direction_index(d: Vector3i) -> int:
	return DIRS.find(d)


static func direction_label(d: Vector3i) -> String:
	var i: int = DIRS.find(d)
	return DIR_LABELS[i] if i >= 0 else "?"


static func direction_from_label(label: String) -> Vector3i:
	var i: int = DIR_LABELS.find(label)
	return DIRS[i] if i >= 0 else Vector3i.ZERO
