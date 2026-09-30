# build_level_set.gd — 按「难度曲线」生成并归档正式关卡集 levels/level_NN.json。
#
# 这是「AI 游戏工厂」的内容生产闭环在正式内容上的落地：
#   曲线规格 → 逐关生成（可复现种子）→ 质检门 → 写入 levels/ → 终检（含曲线单调校验）
#
# 用法:
#   gf-run.sh -p games/puzzle-core res://tools/build_level_set.gd
#   gf-run.sh -p games/puzzle-core res://tools/build_level_set.gd --seed 42 --out res://levels
# 参数（经 -- 传入，用 OS.get_cmdline_user_args() 读取）:
#   --seed S   基准种子（默认 2027，可复现）
#   --out DIR  输出目录（默认 res://levels）
# 输出: 单行 JSON（逐关报告 + 汇总）；任一关未达规格 / 曲线不单调则退出码非 0。
extends SceneTree

const Generator = preload("res://tools/level_generator.gd")
const Validate = preload("res://solver/validate.gd")
const Loader = preload("res://core/level_loader.gd")
const Solver = preload("res://solver/solver.gd")

const SEED_TRIES: int = 16   # 每关尝试的种子数

# ── 关卡曲线：平滑爬坡 ────────────────────────────────────
# 全部使用同一种形状（domino 骨牌）：难度应该来自**关卡设计**，
# 而不是换个奇怪形状重新学一套手感。
#
# 关键实测结论（用 tools 里的校准脚本可复现）：
#   骨牌类谜题的**最优步数几乎不随盘面变大而增长**——5x5 的中位数 5 步，
#   11x10 的中位数也只有 8 步。原因很直白：起点和目标都是随机撒的，
#   随机两点之间本来就短；洞越多反而越“堵”，解可能更短。
#   所以「第 20 关必须最少 20 步」这种规划既做不到、也没必要。
#
# 于是难度爬坡改用玩家真正感受得到的两个旋钮（完全可控、严格递增）：
#   grid_x * grid_z（盘面面积）与 holes（空洞密度）—— 这就是“地图难度”。
#   min_moves 只作为**搜索目标**（取最接近目标的候选），不作为硬门槛。
# 生成完成后统一校验曲线单调性（步数容许极小回落，盘面面积不允许回落）。
#
# difficulty 标签 = solver.grade 对 min_moves 的判定
# （easy ≤4 / medium ≤9 / hard ≤16 / expert >16）。
const SPECS: Array = [
	{"grid_x": 5, "grid_z": 5, "holes": 0.04, "min_moves": 2, "difficulty": "easy"},      # 01 入门：几乎没有洞
	{"grid_x": 5, "grid_z": 5, "holes": 0.06, "min_moves": 3, "difficulty": "easy"},      # 02
	{"grid_x": 6, "grid_z": 5, "holes": 0.08, "min_moves": 4, "difficulty": "easy"},      # 03 出现非方形盘面
	{"grid_x": 6, "grid_z": 6, "holes": 0.10, "min_moves": 5, "difficulty": "medium"},    # 04 进阶
	{"grid_x": 7, "grid_z": 6, "holes": 0.12, "min_moves": 5, "difficulty": "medium"},    # 05
	{"grid_x": 7, "grid_z": 7, "holes": 0.12, "min_moves": 6, "difficulty": "medium"},    # 06
	{"grid_x": 8, "grid_z": 7, "holes": 0.14, "min_moves": 6, "difficulty": "medium"},    # 07
	{"grid_x": 8, "grid_z": 8, "holes": 0.14, "min_moves": 7, "difficulty": "medium"},    # 08
	{"grid_x": 9, "grid_z": 8, "holes": 0.16, "min_moves": 7, "difficulty": "medium"},    # 09
	{"grid_x": 9, "grid_z": 9, "holes": 0.16, "min_moves": 8, "difficulty": "medium"},    # 10 困难
	{"grid_x": 10, "grid_z": 9, "holes": 0.18, "min_moves": 8, "difficulty": "medium"},   # 11
	{"grid_x": 10, "grid_z": 10, "holes": 0.18, "min_moves": 9, "difficulty": "medium"},  # 12
	{"grid_x": 11, "grid_z": 10, "holes": 0.19, "min_moves": 9, "difficulty": "medium"},  # 13
	{"grid_x": 11, "grid_z": 11, "holes": 0.20, "min_moves": 10, "difficulty": "hard"},   # 14
	{"grid_x": 12, "grid_z": 11, "holes": 0.20, "min_moves": 10, "difficulty": "hard"},   # 15
	{"grid_x": 12, "grid_z": 12, "holes": 0.21, "min_moves": 11, "difficulty": "hard"},   # 16
	{"grid_x": 12, "grid_z": 12, "holes": 0.22, "min_moves": 12, "difficulty": "hard"},   # 17
	{"grid_x": 12, "grid_z": 12, "holes": 0.23, "min_moves": 13, "difficulty": "hard"},   # 18 专家
	{"grid_x": 12, "grid_z": 12, "holes": 0.24, "min_moves": 14, "difficulty": "hard"},   # 19
	{"grid_x": 12, "grid_z": 12, "holes": 0.25, "min_moves": 15, "difficulty": "hard"},   # 20 终章：最密空洞
]

# 「命中」容差：实际步数偏离搜索目标不超过这么多就算命中
const MOVE_TOLERANCE: int = 2
# 曲线单调校验容差：步数曲线允许的极小回落（盘面面积不允许回落）
const CURVE_TOLERANCE: int = 2


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
			reports.append({"id": id, "written": false, "reason": "no_candidate"})
			continue

		var lv: Dictionary = picked["level"]
		var detail: Dictionary = picked["detail"]
		lv["id"] = id
		# 缓存元数据（供选关界面显示「参考步数」，随关卡重建自动刷新）
		lv["difficulty"] = detail["difficulty"]
		lv["optimal_moves"] = detail["optimal_moves"]

		var f := FileAccess.open(out_dir + "/" + id + ".json", FileAccess.WRITE)
		if f == null:
			reports.append({"id": id, "written": false, "reason": "cannot_write"})
			continue
		f.store_string(JSON.stringify(lv, "\t"))
		f.close()

		# 终检 1：从磁盘重新加载 + 求解，确保「写出去的」确实可用
		var back: Dictionary = Loader.load_file(out_dir + "/" + id + ".json")
		var usable: bool = not back.has("error")
		if usable:
			usable = Solver.new(back["board"], back["start"]).solve()["solvable"]

		ok_count += 1 if usable else 0
		met_count += 1 if picked["met"] else 0
		reports.append({
			"id": id,
			"target_difficulty": spec["difficulty"],
			"difficulty": detail["difficulty"],
			"optimal_moves": detail["optimal_moves"],
			"grid": "%dx%d" % [int(spec["grid_x"]), int(spec["grid_z"])],
			"area": int(spec["grid_x"]) * int(spec["grid_z"]),
			"holes": float(spec["holes"]),
			"min_moves": int(spec["min_moves"]),
			"met": picked["met"],
			"written": true,
			"reload_ok": usable,
		})

	# 终检 2：曲线单调性。规格表只能保证「意图」递增，保证不了「结果」递增，
	# 所以这里对真实产物再查一遍——把“难度平滑爬坡”变成一条**被校验的性质**。
	var curve: Dictionary = _check_curve(reports)
	var summary: Dictionary = {
		"total": SPECS.size(),
		"written": ok_count,
		"met_target": met_count,
		"curve_ok": curve["ok"],
		"curve_issues": curve["issues"],
		"seed": args["seed"],
		"out": out_dir,
	}
	print(JSON.stringify({"summary": summary, "levels": reports}))
	var good: bool = ok_count == SPECS.size() and met_count == SPECS.size() and curve["ok"]
	quit(0 if good else 1)


# 曲线单调校验：盘面面积必须严格递增；步数允许小幅回落（CURVE_TOLERANCE）。
func _check_curve(reports: Array) -> Dictionary:
	var issues: Array = []
	var prev_area: int = 0
	var prev_moves: int = 0
	for rep in reports:
		if not bool(rep.get("written", false)):
			issues.append("%s 未生成" % rep["id"])
			continue
		var area: int = int(rep["area"])
		var moves: int = int(rep["optimal_moves"])
		if area < prev_area:
			issues.append("%s 盘面面积回落（%d -> %d）" % [rep["id"], prev_area, area])
		if moves < prev_moves - CURVE_TOLERANCE:
			issues.append("%s 步数明显回落（%d -> %d）" % [rep["id"], prev_moves, moves])
		prev_area = maxi(prev_area, area)
		prev_moves = maxi(prev_moves - CURVE_TOLERANCE, moves)
	return {"ok": issues.is_empty(), "issues": issues}


# 在多个种子里挑选候选：取「最接近搜索目标」的那个（优先不低于目标）。
# 注意这里**不把上一关的结果当成下一关的门槛**——早期版本这么做，
# 超额命中的结果会变成下一关的下限，误差逐关累积（第 20 关曾要求 30+ 步而生成不出来）。
func _pick(spec: Dictionary, base_seed: int, idx: int) -> Dictionary:
	var want: int = int(spec["min_moves"])
	var best := {}
	var best_score: float = INF
	for attempt in range(SEED_TRIES):
		var seed: int = base_seed + idx * 1000 + attempt
		var r: Dictionary = _gen_one(spec, spec["difficulty"], seed)
		if r.is_empty():
			r = _gen_one(spec, "any", seed)
		if r.is_empty():
			continue
		var om: int = int(r["detail"]["optimal_moves"])
		# 打分：达到目标就给差距本身；没达到目标额外罚 0.5（尽量别低于目标）
		var score: float = float(om - want) if om >= want else float(want - om) + 0.5
		if score < best_score:
			best = r
			best_score = score
	if best.is_empty():
		return {}
	best["met"] = best_score <= float(MOVE_TOLERANCE)
	return best


func _gen_one(spec: Dictionary, difficulty: String, seed: int) -> Dictionary:
	var res: Dictionary = Generator.new().generate(
		seed, int(spec["grid_x"]), int(spec["grid_z"]), float(spec["holes"]),
		difficulty, 1, int(spec["min_moves"])
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
