# build_level_set.gd — 按「难度曲线 + 形状混合」生成并归档正式关卡集 levels/level_NN.json。
#
# 这是「AI 游戏工厂」的内容生产闭环在正式内容上的落地：
#   曲线规格 → 逐关生成（可复现种子）→ 质检门 → 写入 levels/ → 终检
#
# 用法:
#   gf-run.sh -p games/puzzle-core res://tools/build_level_set.gd
#   gf-run.sh -p games/puzzle-core res://tools/build_level_set.gd --seed 42 --out res://levels
# 参数（经 -- 传入，用 OS.get_cmdline_user_args() 读取）:
#   --seed S   基准种子（默认 2027，可复现）
#   --out DIR  输出目录（默认 res://levels）
# 输出: 单行 JSON（逐关报告 + 汇总）；任一关未达规格则退出码非 0。
extends SceneTree

const Generator = preload("res://tools/level_generator.gd")
const Validate = preload("res://solver/validate.gd")
const Loader = preload("res://core/level_loader.gd")
const Solver = preload("res://solver/solver.gd")

const SEED_TRIES: int = 12   # 每关尝试的种子数（先按目标难度，再回退任意难度）

# 关卡曲线：由易到难。
# cube 作为「第二形态」，在第 8 关引入，之后间歇出现（第 12/16/20 关）。
# **cube 关卡一律配冰面机制（mechanic=ice）**：单格方块在普通棋盘上只能一条直线走到目标，
# 几乎不需思考（实测就是「点几下就通关」）；冰面上每次移动是「不可微调的大位移」，
# 才真正需要规划，也让 cube 与 domino 有本质区别。
# 难度分级来自 solver.grade：easy ≤4 步 / medium ≤9 / hard ≤16 / expert >16；
# 冰面关卡会把步数 ×3 折算（一次滑动 = 好几格），见 solver.grade。
const SPECS: Array = [
	{"shape": "domino", "difficulty": "easy", "grid": 5, "holes": 0.06, "min_moves": 2},      # 01 入门
	{"shape": "domino", "difficulty": "easy", "grid": 5, "holes": 0.08, "min_moves": 2},      # 02
	{"shape": "domino", "difficulty": "easy", "grid": 6, "holes": 0.10, "min_moves": 3},      # 03
	{"shape": "domino", "difficulty": "easy", "grid": 6, "holes": 0.10, "min_moves": 3},      # 04
	{"shape": "domino", "difficulty": "medium", "grid": 6, "holes": 0.12, "min_moves": 5},    # 05
	{"shape": "domino", "difficulty": "medium", "grid": 6, "holes": 0.12, "min_moves": 5},    # 06
	{"shape": "domino", "difficulty": "medium", "grid": 7, "holes": 0.14, "min_moves": 6},    # 07
	{"shape": "cube", "mechanic": "ice", "difficulty": "medium", "grid": 6, "holes": 0.16, "min_moves": 2},   # 08 引入 Cube + 冰面（小棋盘熟悉规则）
	{"shape": "domino", "difficulty": "medium", "grid": 7, "holes": 0.14, "min_moves": 6},    # 09
	{"shape": "domino", "difficulty": "medium", "grid": 7, "holes": 0.16, "min_moves": 7},    # 10
	{"shape": "domino", "difficulty": "hard", "grid": 8, "holes": 0.16, "min_moves": 10},     # 11
	{"shape": "cube", "mechanic": "ice", "difficulty": "hard", "grid": 8, "holes": 0.20, "min_moves": 4},      # 12 Cube + 冰面
	{"shape": "domino", "difficulty": "hard", "grid": 8, "holes": 0.16, "min_moves": 10},     # 13
	{"shape": "domino", "difficulty": "hard", "grid": 8, "holes": 0.18, "min_moves": 11},     # 14
	{"shape": "domino", "difficulty": "hard", "grid": 9, "holes": 0.18, "min_moves": 12},     # 15
	{"shape": "cube", "mechanic": "ice", "difficulty": "hard", "grid": 10, "holes": 0.20, "min_moves": 4},     # 16 Cube + 冰面（大棋盘）
	{"shape": "domino", "difficulty": "hard", "grid": 9, "holes": 0.18, "min_moves": 13},     # 17
	{"shape": "domino", "difficulty": "expert", "grid": 9, "holes": 0.18, "min_moves": 17},   # 18
	{"shape": "domino", "difficulty": "expert", "grid": 10, "holes": 0.20, "min_moves": 18},  # 19
	{"shape": "cube", "mechanic": "ice", "difficulty": "expert", "grid": 12, "holes": 0.18, "min_moves": 8},    # 20 终章：12x12 冰面
]


func _init() -> void:
	var args: Dictionary = _parse_args(OS.get_cmdline_user_args())
	var out_dir: String = args["out"]
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out_dir))

	var reports: Array = []
	var ok_count: int = 0
	var met_count: int = 0

	for i in range(SPECS.size()):
		var spec: Dictionary = SPECS[i]
		var idx: int = i + 1
		var id: String = "level_%02d" % idx
		var picked: Dictionary = _pick(spec, int(args["seed"]), idx)

		if picked.is_empty():
			reports.append({"id": id, "shape": spec["shape"], "written": false, "reason": "no_candidate"})
			continue

		var lv: Dictionary = picked["level"]
		var detail: Dictionary = picked["detail"]
		lv["id"] = id
		# 缓存元数据（供选关界面显示「参考步数」，可随关卡重建自动刷新）
		lv["difficulty"] = detail["difficulty"]
		lv["optimal_moves"] = detail["optimal_moves"]

		var f := FileAccess.open(out_dir + "/" + id + ".json", FileAccess.WRITE)
		if f == null:
			reports.append({"id": id, "shape": spec["shape"], "written": false, "reason": "cannot_write"})
			continue
		f.store_string(JSON.stringify(lv, "\t"))
		f.close()

		# 终检：从磁盘重新加载 + 求解，确保「写出去的」确实可用
		var back: Dictionary = Loader.load_file(out_dir + "/" + id + ".json")
		var usable: bool = not back.has("error")
		if usable:
			usable = Solver.new(back["board"], back["start"]).solve()["solvable"]

		ok_count += 1 if usable else 0
		met_count += 1 if picked["met"] else 0
		reports.append({
			"id": id,
			"shape": spec["shape"],
			"target_difficulty": spec["difficulty"],
			"difficulty": detail["difficulty"],
			"optimal_moves": detail["optimal_moves"],
			"met": picked["met"],
			"written": true,
			"reload_ok": usable,
		})

	var summary: Dictionary = {
		"total": SPECS.size(),
		"written": ok_count,
		"met_target": met_count,
		"seed": args["seed"],
		"out": out_dir,
	}
	print(JSON.stringify({"summary": summary, "levels": reports}))
	quit(0 if ok_count == SPECS.size() and met_count == SPECS.size() else 1)


# 按目标难度优先尝试多个种子；失败则回退任意难度（仍满足 min_moves）。
func _pick(spec: Dictionary, base_seed: int, idx: int) -> Dictionary:
	for attempt in range(SEED_TRIES):
		var r: Dictionary = _gen_one(spec, spec["difficulty"], base_seed + idx * 1000 + attempt)
		if not r.is_empty() and r["detail"]["difficulty"] == spec["difficulty"]:
			r["met"] = true
			return r
	for attempt in range(SEED_TRIES):
		var r: Dictionary = _gen_one(spec, "any", base_seed + idx * 1000 + 500 + attempt)
		if not r.is_empty():
			r["met"] = false
			return r
	return {}


func _gen_one(spec: Dictionary, difficulty: String, seed: int) -> Dictionary:
	var g: int = spec["grid"]
	var res: Dictionary = Generator.new().generate(
		seed, g, g, spec["holes"], difficulty, 1, spec["min_moves"],
		spec["shape"], str(spec.get("mechanic", ""))
	)
	if res["levels"].size() == 0:
		return {}
	return {"level": res["levels"][0], "detail": res["details"][0]}


func _parse_args(args: Array) -> Dictionary:
	var o := {"seed": 2027, "out": "res://levels"}
	var i := 0
	while i < args.size():
		var k: String = str(args[i])
		if i + 1 >= args.size():
			break
		var v: String = str(args[i + 1])
		match k:
			"--seed":
				o["seed"] = int(v)
			"--out":
				o["out"] = v
		i += 2
	return o
