# rotations.gd — 24 个保定向（行列式 +1）轴对齐旋转，全部用整数矩阵表示。
# 矩阵表示：Array[Vector3i]，M[0..2] 为「列向量」，分别是 e_x、e_y、e_z 的像。
# 应用：world = M * v = M[0]*v.x + M[1]*v.y + M[2]*v.z
#
# 为什么用整数矩阵而非 Basis：求解器要求确定性，避免浮点误差（cos(90°)≈1e-17）。
extends RefCounted

const EX := Vector3i(1, 0, 0)
const EY := Vector3i(0, 1, 0)
const EZ := Vector3i(0, 0, 1)

static var _orientations: Array = []


static func cross(a: Vector3i, b: Vector3i) -> Vector3i:
	return Vector3i(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)


static func dot(a: Vector3i, b: Vector3i) -> int:
	return a.x * b.x + a.y * b.y + a.z * b.z


static func apply(m: Array, v: Vector3i) -> Vector3i:
	return m[0] * v.x + m[1] * v.y + m[2] * v.z


static func compose(a: Array, b: Array) -> Array:
	# 返回 a∘b（先应用 b，再应用 a）
	return [apply(a, b[0]), apply(a, b[1]), apply(a, b[2])]


static func identity() -> Array:
	return [EX, EY, EZ]


static func inverse(m: Array) -> Array:
	# 整数正交矩阵的逆 = 转置
	return [
		Vector3i(m[0].x, m[1].x, m[2].x),
		Vector3i(m[0].y, m[1].y, m[2].y),
		Vector3i(m[0].z, m[1].z, m[2].z),
	]


static func quarter_turn(axis: Vector3i) -> Array:
	# 绕给定轴（必须为 ±EX/±EY/±EZ）旋转 +90°
	if axis == EX:
		return [EX, EZ, -EY]        # (x,y,z) -> (x,-z,y)
	if axis == -EX:
		return inverse([EX, EZ, -EY])
	if axis == EY:
		return [-EZ, EY, EX]        # (x,y,z) -> (z,y,-x)
	if axis == -EY:
		return inverse([-EZ, EY, EX])
	if axis == EZ:
		return [EY, -EX, EZ]        # (x,y,z) -> (-y,x,z)
	if axis == -EZ:
		return inverse([EY, -EX, EZ])
	return identity()


static func all_orientations() -> Array:
	# 生成 24 个保定向轴对齐旋转：e_x 取 6 个轴向之一，e_y 取与其正交的 4 个轴向之一，
	# e_z 由叉积决定（保证行列式 +1）。6*4 = 24。
	if _orientations.is_empty():
		var axes: Array = [EX, -EX, EY, -EY, EZ, -EZ]
		for c0 in axes:
			for c1 in axes:
				if dot(c0, c1) != 0:
					continue
				_orientations.append([c0, c1, cross(c0, c1)])
	return _orientations


static func index_of(m: Array) -> int:
	all_orientations()
	for i in range(_orientations.size()):
		var o: Array = _orientations[i]
		if o[0] == m[0] and o[1] == m[1] and o[2] == m[2]:
			return i
	return -1
