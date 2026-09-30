# util.gd — 跨模块通用工具（避免重复、保证确定性）。
extends RefCounted


static func cell_lt(a: Vector3i, b: Vector3i) -> bool:
	# 按 (x, y, z) 字典序比较
	if a.x != b.x:
		return a.x < b.x
	if a.y != b.y:
		return a.y < b.y
	return a.z < b.z


static func sort_cells(arr: Array) -> Array:
	# 返回排序后的新数组（Vector3i 无默认比较，需自定义）
	var out: Array = arr.duplicate()
	out.sort_custom(func(a, b): return cell_lt(a, b))
	return out
