# level_loader.gd — 从 JSON 加载关卡，产出 {board, start}。
# 关卡 JSON 结构（见 levels/level_01.json）：
#   {
#     "id": "level_01",
#     "grid": {"x": 8, "z": 8},
#     "holes": [[x,z], ...],
#     "goal":  [[x,z], ...],
#     "start": {"shape": "domino", "orientation": "standing"|int, "position": [x,y,z]}
#   }
extends RefCounted

const Board = preload("res://core/board.gd")
const State = preload("res://core/puzzle_state.gd")
const Shapes = preload("res://core/shapes.gd")


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

	var holes: Array = []
	for h in data.get("holes", []):
		holes.append(Vector2i(int(h[0]), int(h[1])))
	var goal: Array = []
	for g in data.get("goal", []):
		goal.append(Vector2i(int(g[0]), int(g[1])))

	var grid: Dictionary = data.get("grid", {"x": 8, "z": 8})
	var board = Board.new(str(data.get("id", "")), int(grid.get("x", 8)), int(grid.get("z", 8)), holes, goal)

	# 机关（可选）：目前支持 ice（冰面打滑）
	var mech: Dictionary = {}
	var mech_id: String = str(data.get("mechanic", ""))
	if mech_id == "ice":
		# 冰面要求单格形状：多格形状“滑动”的语义不成立（比如骨牌打滑该怎算？）
		if shape.cells.size() != 1:
			return {"error": "mechanic_needs_single_cell", "mechanic": mech_id, "shape": shape.id}
		mech = {"move": "ice"}
	elif mech_id != "":
		return {"error": "unknown_mechanic", "mechanic": mech_id}

	var start = State.new(shape, orientation, position, mech)

	return {"board": board, "start": start}
