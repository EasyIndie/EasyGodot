# level_generator.gd — 关卡生成器（可复用的核心逻辑，CLI 之外可被测试/其他工具调用）。
# 流程：随机生成候选关卡 → 走质检门（合法性/可解性/难度）→ 按条件筛选。
# 这是「AI 游戏工厂」的内容生产闭环：生成 → 质检 → 筛选。
extends RefCounted

const Validate = preload("res://solver/validate.gd")

var rng: RandomNumberGenerator = RandomNumberGenerator.new()


func generate(seed: int, grid_x: int, grid_z: int, hole_density: float,
		difficulty: String, count: int, min_moves: int, shape_id: String = "domino",
		mechanic: String = "") -> Dictionary:
	rng.seed = seed
	var levels: Array = []
	var details: Array = []
	var stats: Dictionary = {
		"attempts": 0, "invalid": 0, "unsolvable": 0,
		"trivial": 0, "wrong_difficulty": 0, "kept": 0,
	}
	var max_attempts: int = count * 100
	var seq: int = 0

	while levels.size() < count and stats["attempts"] < max_attempts:
		stats["attempts"] += 1
		var data: Dictionary = _generate_one(grid_x, grid_z, hole_density, shape_id, mechanic)
		data["id"] = "gen_%d_%03d" % [seed, seq]

		var r: Dictionary = Validate.validate_dict(data)
		match str(r["status"]):
			"invalid":
				stats["invalid"] += 1
				continue
			"unsolvable":
				stats["unsolvable"] += 1
				continue
			_:
				pass

		if int(r["optimal_moves"]) < min_moves:
			stats["trivial"] += 1
			continue
		if difficulty != "any" and r["difficulty"] != difficulty:
			stats["wrong_difficulty"] += 1
			continue

		levels.append(data)
		details.append({"id": data["id"], "difficulty": r["difficulty"], "optimal_moves": r["optimal_moves"]})
		stats["kept"] += 1
		seq += 1

	return {"levels": levels, "details": details, "stats": stats}


func _generate_one(grid_x: int, grid_z: int, hole_density: float, shape_id: String = "domino",
		mechanic: String = "") -> Dictionary:
	var holes_v: Array = []  # Array[Vector2i]
	for x in range(grid_x):
		for z in range(grid_z):
			if rng.randf() < hole_density:
				holes_v.append(Vector2i(x, z))

	var start_v: Vector2i = _random_solid(grid_x, grid_z, holes_v, [])
	# 单格形状（cube）所有姿态等价；domino 随机取一种起始姿态（竖立/沿 X 横躺/沿 Z 横躺）
	var orientation: String = "standing"
	if shape_id != "cube":
		var orientations: Array = ["standing", "lying_x", "lying_z"]
		orientation = orientations[rng.randi_range(0, 2)]
	var goal_v: Vector2i = _random_solid(grid_x, grid_z, holes_v, [start_v])

	var holes_arr: Array = []
	for h in holes_v:
		holes_arr.append([h.x, h.y])

	var out: Dictionary = {
		"grid": {"x": grid_x, "z": grid_z},
		"holes": holes_arr,
		"goal": [[goal_v.x, goal_v.y]],
		"start": {"shape": shape_id, "orientation": orientation, "position": [start_v.x, 0, start_v.y]},
	}
	if mechanic != "":
		out["mechanic"] = mechanic
	return out


func _random_solid(grid_x: int, grid_z: int, holes: Array, exclude: Array) -> Vector2i:
	for _i in range(2000):
		var v := Vector2i(rng.randi_range(0, grid_x - 1), rng.randi_range(0, grid_z - 1))
		if holes.has(v):
			continue
		if exclude.has(v):
			continue
		return v
	return Vector2i(0, 0)  # 理论上不会到达（除非棋盘几乎全洞）
