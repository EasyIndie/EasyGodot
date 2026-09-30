# generate_levels.gd — 关卡生成 CLI（headless）。
# 用法:
#   gf-run.sh -p games/puzzle-core res://tools/generate_levels.gd --count 20 --difficulty medium --seed 42
# 参数（均经 -- 传入，用 OS.get_cmdline_user_args() 读取）:
#   --count N        目标数量（默认 20）
#   --difficulty D   easy|medium|hard|expert|any（默认 any）
#   --grid WxZ       棋盘尺寸（默认 5x5）
#   --holes P        洞密度百分比 0-100（默认 15）
#   --min-moves N    最少步数（过滤平凡关卡，默认 1）
#   --shape S        形状 domino|cube（默认 domino）
#   --seed S         随机种子（默认 42，可复现）
#   --out DIR        输出目录（默认 res://levels/generated）
extends SceneTree

const Generator = preload("res://tools/level_generator.gd")


func _init() -> void:
	var args: Dictionary = _parse_args(OS.get_cmdline_user_args())
	var gen = Generator.new()
	var res: Dictionary = gen.generate(
		args["seed"], args["grid_x"], args["grid_z"], args["hole_density"],
		args["difficulty"], args["count"], args["min_moves"], args["shape"]
	)

	# 写出保留的关卡
	var out_dir: String = args["out"]
	var written: int = 0
	if res["levels"].size() > 0:
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out_dir))
		for lv in res["levels"]:
			var path: String = out_dir + "/" + lv["id"] + ".json"
			var f := FileAccess.open(path, FileAccess.WRITE)
			if f != null:
				f.store_string(JSON.stringify(lv, "\t"))
				f.close()
				written += 1

	var summary: Dictionary = {
		"target": {"count": args["count"], "difficulty": args["difficulty"], "seed": args["seed"], "shape": args["shape"]},
		"stats": res["stats"],
		"written": written,
		"levels": res["details"],
	}
	var failed: bool = res["levels"].size() < args["count"]
	print(JSON.stringify({"summary": summary}))
	quit(1 if failed else 0)


func _parse_args(args: Array) -> Dictionary:
	var o := {
		"count": 20, "difficulty": "any", "grid_x": 5, "grid_z": 5,
		"hole_density": 0.15, "min_moves": 1, "seed": 42, "out": "res://levels/generated",
		"shape": "domino",
	}
	var i := 0
	while i < args.size():
		var k: String = str(args[i])
		if i + 1 >= args.size():
			break
		var v: String = str(args[i + 1])
		match k:
			"--count":
				o["count"] = int(v)
			"--difficulty":
				o["difficulty"] = v
			"--grid":
				var parts: PackedStringArray = v.split("x")
				if parts.size() == 2:
					o["grid_x"] = int(parts[0])
					o["grid_z"] = int(parts[1])
			"--holes":
				o["hole_density"] = float(v) / 100.0
			"--min-moves":
				o["min_moves"] = int(v)
			"--shape":
				o["shape"] = v
			"--seed":
				o["seed"] = int(v)
			"--out":
				o["out"] = v
		i += 2
	return o
