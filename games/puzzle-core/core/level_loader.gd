# level_loader.gd — 从 JSON 加载关卡，产出 {board, start}。
# 关卡 JSON 结构（见 levels/level_01.json）：
#   {
#     "id": "level_01",
#     "grid": {"x": 8, "z": 8},
#     "holes": [[x,z], ...],
#     "goal":  [[x,z], ...],
#     "mechanisms": [{"id":"sw1","kind":"switch","tiles":[[x,z]],"target":"br1"}, ...]  ← 可选
#     "start": {"shape": "domino", "orientation": "standing"|int, "position": [x,y,z]},
#     "optimal_moves": 7, "difficulty": "medium"   ← 由 build_level_set 写入的缓存元数据
#   }
extends RefCounted

const Board = preload("res://core/board.gd")
const State = preload("res://core/puzzle_state.gd")
const Shapes = preload("res://core/shapes.gd")
const Mechanisms = preload("res://core/mechanisms.gd")


static func load_file(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {"error": "cannot_open", "path": path}
	var text := f.get_as_text()
	f.close()
	var json := JSON.new()
	if json.parse(text) != OK:
		return {"error": "bad_json", "line": json.get_error_line(), "message": json.get_error_message()}
	return load_dict(json.data)


static func _to_cell(raw) -> Variant:
	# 接受 Vector2i 或 [x, z]（长度 ≥ 2 的数组）；其它一律返回 null（由调用方报错）
	if raw is Vector2i:
		return raw
	if raw is Array and raw.size() >= 2:
		var x = raw[0]
		var z = raw[1]
		if (x is int or x is float) and (z is int or z is float):
			return Vector2i(int(x), int(z))
		return null
	return null


static func load_dict(data: Dictionary) -> Dictionary:
	if not data.has("start"):
		return {"error": "missing_start"}
	var shape = Shapes.get_shape(str(data["start"].get("shape", "")))
	if shape == null:
		return {"error": "unknown_shape", "shape": data["start"].get("shape")}

	var orientation: int = Shapes.resolve_orientation(shape, data["start"].get("orientation", 0))
	if orientation < 0:
		return {"error": "bad_orientation", "orientation": data["start"].get("orientation")}

	var pos_arr: Array = data["start"].get("position", [0, 0, 0])
	var position := Vector3i(int(pos_arr[0]), int(pos_arr[1]), int(pos_arr[2]))

	# 坐标一律接受 [x,z]（JSON）或 Vector2i（内存里构造的关卡）。
	# **别的形状一律报错**：这里曾经对字符串 "(7, 3)" 也照读不误 ——
	# int("(") = 0，于是"沟"被静默读成完全不同的坐标，关卡看着有洞、实际是坏的
	# （生成器把 Vector2i 直接 JSON 化就会产生这种文件）。静默错误最危险，必须响亮失败。
	var holes: Array = []
	for h in data.get("holes", []):
		var v: Variant = _to_cell(h)
		if v == null:
			return {"error": "bad_hole", "value": str(h)}
		holes.append(v)
	var goal: Array = []
	for g in data.get("goal", []):
		var v2: Variant = _to_cell(g)
		if v2 == null:
			return {"error": "bad_goal", "value": str(g)}
		goal.append(v2)

	var grid: Dictionary = data.get("grid", {"x": 8, "z": 8})
	# 机关是**可选**字段：老关卡一个字节都不用改（20 关的曲线与存档键因此不受影响）
	var mechs: Array = Mechanisms.parse(data.get("mechanisms", []))
	var board = Board.new(str(data.get("id", "")), int(grid.get("x", 8)), int(grid.get("z", 8)),
		holes, goal, mechs)

	return {"board": board, "start": State.new(shape, orientation, position)}
