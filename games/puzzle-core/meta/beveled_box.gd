# 缓存低多边形倒角几何体；外接尺寸与规则中的方格一致。
extends RefCounted

static var _cache: Dictionary = {}

static func mesh(size: Vector3, bevel: float) -> ArrayMesh:
	var key := "%s:%s" % [size, bevel]
	if _cache.has(key):
		return _cache[key]
	var h := size * 0.5
	var b: float = minf(bevel, minf(h.x, minf(h.y, h.z)) * 0.45)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# 六个面。
	for axis in range(3):
		for sign_value in [-1.0, 1.0]:
			var normal := Vector3.ZERO
			normal[axis] = sign_value
			var pts: Array[Vector3] = []
			for pair in [Vector2(-1,-1), Vector2(1,-1), Vector2(1,1), Vector2(-1,1)]:
				var p := Vector3.ZERO
				p[axis] = sign_value * h[axis]
				p[(axis + 1) % 3] = pair.x * (h[(axis + 1) % 3] - b)
				p[(axis + 2) % 3] = pair.y * (h[(axis + 2) % 3] - b)
				pts.append(p)
			_face(st, pts, normal)
	# 十二条倒角边。
	for i in range(3):
		for j in range(i + 1, 3):
			var k := 3 - i - j
			for si in [-1.0, 1.0]:
				for sj in [-1.0, 1.0]:
					var n := Vector3.ZERO
					n[i] = si
					n[j] = sj
					var pts: Array[Vector3] = []
					for pair in [Vector2(0,-1), Vector2(1,-1), Vector2(1,1), Vector2(0,1)]:
						var p := Vector3.ZERO
						p[i] = si * (h[i] - b * pair.x)
						p[j] = sj * (h[j] - b * (1.0 - pair.x))
						p[k] = pair.y * (h[k] - b)
						pts.append(p)
					_face(st, pts, n.normalized())
	# 八个角。
	for sx in [-1.0, 1.0]:
		for sy in [-1.0, 1.0]:
			for sz in [-1.0, 1.0]:
				var n := Vector3(sx,sy,sz)
				var pts: Array[Vector3] = []
				for axis in range(3):
					var p := h - Vector3.ONE * b
					p[axis] = h[axis]
					pts.append(p * n)
				_face(st, pts, n.normalized())
	var result := st.commit()
	_cache[key] = result
	return result

static func _face(st: SurfaceTool, pts: Array[Vector3], normal: Vector3) -> void:
	for i in range(1, pts.size() - 1):
		var tri := [pts[0], pts[i], pts[i+1]]
		if (tri[1] - tri[0]).cross(tri[2] - tri[0]).dot(normal) > 0.0:
			tri = [pts[0], pts[i+1], pts[i]]
		for p in tri:
			st.set_normal(normal)
			st.set_uv(Vector2(0.5,0.5))
			st.add_vertex(p)
