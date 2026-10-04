# 为首发终章寻找两种机关都影响解法的候选；只写候选，不覆盖正式关卡。
extends SceneTree

const Loader = preload("res://core/level_loader.gd")
const Solver = preload("res://solver/solver.gd")


func solve(data: Dictionary) -> Dictionary:
	var lv: Dictionary = Loader.load_dict(data)
	if not lv["board"].supports(lv["start"].world_cells()):
		return {"solvable": false, "optimal_moves": -1}
	return Solver.new(lv["board"], lv["start"]).solve()


func _init() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261004
	var reports: Array = []
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://levels/generated/finale"))
	for number in [19, 20]:
		var path: String = "res://levels/level_%02d.json" % number
		var base: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
		# 支持对已经选好的正式终章重新调优，避免重复追加同一传送门。
		base["mechanisms"] = base["mechanisms"].filter(func(m): return m["kind"] != "portal")
		var solids: Array = []
		for x in range(int(base["grid"]["x"])):
			for z in range(int(base["grid"]["z"])):
				if not base["holes"].has([x, z]):
					solids.append([x, z])
		var picked: Dictionary = {}
		var target: int = number - 2
		for attempt in range(8000):
			var cand: Dictionary = base.duplicate(true)
			var a: Array = solids[rng.randi_range(0, solids.size() - 1)]
			var b: Array = solids[rng.randi_range(0, solids.size() - 1)]
			if a == b or absi(int(a[0]) - int(b[0])) + absi(int(a[1]) - int(b[1])) < 4:
				continue
			# 两端都在同一岛上，避免传送门绕过本来需要推理的桥。
			if (int(a[0]) < 4) != (int(b[0]) < 4):
				continue
			cand["goal"] = [solids[rng.randi_range(0, solids.size() - 1)]]
			if attempt >= 2500:
				var start: Array = solids[rng.randi_range(0, solids.size() - 1)]
				cand["start"]["position"] = [start[0], 0, start[1]]
			cand["mechanisms"].append({"id": "p1", "kind": "portal", "links": [a, b]})
			var result: Dictionary = solve(cand)
			if not result["solvable"] or int(result["optimal_moves"]) != target:
				continue
			var no_portal: Dictionary = cand.duplicate(true)
			no_portal["mechanisms"].pop_back()
			var plain: Dictionary = solve(no_portal)
			if plain["solvable"] and int(plain["optimal_moves"]) <= target:
				continue
			var no_bridge: Dictionary = cand.duplicate(true)
			no_bridge["mechanisms"] = [cand["mechanisms"].back()]
			var isolated: Dictionary = solve(no_bridge)
			if isolated["solvable"]:
				continue
			cand["optimal_moves"] = target
			cand["difficulty"] = "expert"
			picked = cand
			reports.append({"level": number, "attempt": attempt, "moves": target,
				"without_portal": plain["optimal_moves"], "without_bridge": "unsolvable"})
			break
		if picked.is_empty():
			print(JSON.stringify({"status": "fail", "level": number, "reason": "no_candidate"}))
			quit(1)
			return
		var f := FileAccess.open("res://levels/generated/finale/level_%02d.json" % number, FileAccess.WRITE)
		f.store_string(JSON.stringify(picked, "\t"))
		f.close()
	print(JSON.stringify({"status": "ok", "candidates": reports}))
	quit(0)
