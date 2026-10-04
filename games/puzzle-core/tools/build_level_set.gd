# build_level_set.gd — 按「难度曲线」生成并归档正式关卡集 levels/level_NN.json。
#
# 这是「AI 游戏工厂」的内容生产闭环在正式内容上的落地：
#   曲线规格 → 逐关生成（可复现种子）→ 质检门 → 写入 levels/ → 终检（含曲线单调校验）
#
# 用法:
#   gf-run.sh -p games/puzzle-core res://tools/build_level_set.gd
#   gf-run.sh -p games/puzzle-core res://tools/build_level_set.gd --seed 42 --out res://levels/generated/candidates
# 参数（经 -- 传入，用 OS.get_cmdline_user_args() 读取）:
#   --seed S   基准种子（默认 2027，可复现）
#   --out DIR  输出目录（默认候选目录；正式首发关卡需经过试玩精选）
# 输出: 单行 JSON（逐关报告 + 汇总）；任一关未达规格 / 曲线不单调则退出码非 0。
extends SceneTree

const Generator = preload("res://tools/level_generator.gd")
const Validate = preload("res://solver/validate.gd")
const Loader = preload("res://core/level_loader.gd")
const Board = preload("res://core/board.gd")
const Core = preload("res://core/puzzle_core.gd")
const Moves = preload("res://core/moves.gd")
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

# ── 机关章节（用户 2026-10 决定：机关**混合进 20 关**，不另开一章）──────────
#   13–15 关：传送门（姿态约束入门）
#   16–18 关：开关 + 桥（顺序推理：先开路才能过）
#   19–20 关：两者混用
# 关键：机关位置**不是设计出来的，是扫出来的**（手推几何极易写出"不可解"或"机关是装饰品"
# 的关卡，本轮手推的候选全被自动化工具否掉）。扫描的准入条件只有两条：
#   ① 质检通过且**机关承重**（去掉机关后不可解 / 更慢 —— 见 solver/validate.gd）
#   ② 步数落在该关的目标附近（不破坏难度曲线）
const MECH_FROM_INDEX: int = 13
const MECH_TRIES: int = 26        # 每关尝试的机关位置数上限（决定生成耗时）
const MECH_BASE_SLACK: int = 3    # 普通机关关：基础盘面比目标多这么多步（机关会把它缩短回来）
const MECH_TRENCH_SLACK: int = 6  # 切沟关：沟会削掉一整列盘面，所以要多留几步
const MECH_TRENCH_TRIES: int = 900 # 切沟候选的尝试上限（切沟搜索空间更大）

# 「命中」容差：实际步数偏离搜索目标不超过这么多就算命中
const MOVE_TOLERANCE: int = 2
# 曲线单调校验容差：步数曲线允许的极小回落（盘面面积不允许回落）
const CURVE_TOLERANCE: int = 2


var reports: Array = []
# 生成器的搜索可见性：每个候选为什么被否掉（没有这个，失败原因全靠猜）
var _reject: Dictionary = {}


func _rej(reason: String) -> void:
	_reject[reason] = int(_reject.get(reason, 0)) + 1


func _init() -> void:
	var args: Dictionary = _parse_args(OS.get_cmdline_user_args())
	var out_dir: String = args["out"]
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out_dir))

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
			"mech": str(picked.get("mech", "")),
			"essential": bool(picked.get("essential", false)),
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
		"rejects": _reject,
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
	# 机关关：基础盘面按「目标 + 余量」生成 —— 挂上机关后最优解会缩短，
	# 直接按目标生成的话，一挂机关就掉到曲线下面去了（实测第 13 关掉到 7 步）。
	var best := {}
	var best_score: float = INF
	for attempt in range(SEED_TRIES):
		var seed: int = base_seed + idx * 1000 + attempt
		# 机关关的基础盘面要按「目标 + 余量」生成：机关会让最优解变短，直接按目标生成的话
		# 一挂机关就掉到曲线下面（实测第 13 关掉到 7 步）。而**切沟**会削掉一整列盘面，
		# 削多少取决于盘面本身，所以对半交替两种余量，否则一部分关卡会"切完太短/太长"
		# 被整批否掉（第 14/16/19 关就是这样掉出去的）。
		var want_gen: int = want
		if idx >= MECH_FROM_INDEX:
			want_gen = want + (MECH_TRENCH_SLACK if attempt % 2 == 0 else MECH_BASE_SLACK)
		var gen_spec: Dictionary = spec
		if want_gen != want:
			gen_spec = spec.duplicate()
			gen_spec["min_moves"] = want_gen
		var r: Dictionary = _gen_one(gen_spec, spec["difficulty"], seed)
		if r.is_empty():
			r = _gen_one(gen_spec, "any", seed)
		if r.is_empty():
			continue
		var om: int = int(r["detail"]["optimal_moves"])
		# 打分：达到目标就给差距本身；没达到目标额外罚 0.5（尽量别低于目标）
		var score: float = float(om - want) if om >= want else float(want - om) + 0.5
		# 机关关（13 关起）：base 候选必须能挂上一组**承重**的机关才算数
		if idx >= MECH_FROM_INDEX:
			# 优先"切沟 → 多块棋盘"（机关必需）；找不到再退回普通机关（捷径型）
			var with_mech: Dictionary = _attach_trench_mechanism(r["level"], idx, want, seed)
			var trench_ok: bool = not with_mech.is_empty()
			if with_mech.is_empty():
				with_mech = _attach_mechanism(r["level"], idx, want, seed)
			if with_mech.is_empty():
				continue
			r = {
				"level": with_mech["level"],
				"detail": with_mech["detail"],
				"mech": with_mech["desc"],
				"essential": trench_ok,
			}
		if score < best_score:
			best = r
			best_score = score
	if best.is_empty():
		return {}
	best["met"] = best_score <= float(MOVE_TOLERANCE)
	return best


func _mech_plan(idx: int) -> Array:
	# 该关允许出现的机关种类（越靠后越多）
	if idx < MECH_FROM_INDEX:
		return []
	if idx <= 15:
		return ["portal"]
	if idx <= 18:
		# 桥要优先尝试：它是"顺序推理"的主力，但可用的承重位置比传送门少
		return ["bridge", "bridge", "bridge", "portal"]
	return ["bridge", "bridge", "portal"]


func _hole_cells(lv: Dictionary) -> Array:
	var out: Array = []
	for h in lv.get("holes", []):
		out.append(Vector2i(int(h[0]), int(h[1])))
	return out


func _solid_cells(lv: Dictionary) -> Array:
	var g: Dictionary = lv.get("grid", {"x": 8, "z": 8})
	var holes: Dictionary = {}
	for h in _hole_cells(lv):
		holes[h] = true
	var out: Array = []
	for x in range(int(g["x"])):
		for z in range(int(g["z"])):
			if not holes.has(Vector2i(x, z)):
				out.append(Vector2i(x, z))
	return out


func _trench_holes(lv: Dictionary, cx: int, thick: int) -> Array:
	# 把整列 x∈[cx, cx+thick) 挖成沟（"切出一块新棋盘"）。
	# **沟必须是完整的**：桥格也要留在空洞里 —— 桥是"补地类"机关（架在空洞上才叫桥）。
	# 曾经在这里把桥格留成实心，结果：对照盘（去掉机关）仍然能从桥格走过去，
	# 于是"去掉机关也不可解"永远不成立、桥被误判成装饰品（5000+ 次 rejected 里的绝大多数）。
	var g: Dictionary = lv.get("grid", {"x": 8, "z": 8})
	var holes: Array = []
	for h in lv.get("holes", []):
		holes.append(Vector2i(int(h[0]), int(h[1])))
	for x in range(cx, cx + thick):
		for z in range(int(g["z"])):
			var c := Vector2i(x, z)
			if not holes.has(c):
				holes.append(c)
	# **必须转回 [[x,z], ...]**：Vector2i 被 JSON.stringify 会变成字符串 "(7, 3)"，
	# 而加载器会把 int("(")=0 静默读成错坐标 —— 关卡文件看着"有洞"，实际全是坏的。
	var out: Array = []
	for h in holes:
		out.append([h.x, h.y])
	return out


func _attach_trench_mechanism(lv: Dictionary, idx: int, want: int, seed: int) -> Dictionary:
	# **切沟 → 多块棋盘**：把盘面用一条完整的沟切成两块，机关是唯一的通路。
	# 为什么值得这么做：
	#   1) 视觉上真的变成"两块地方"（现在只是"矩形挖洞"，看不出是两块棋盘）；
	#   2) 机关从"捷径"升级为**必需**：去掉机关后**不可解**（承重的最强形式）。
	# 沟必须是**完整一列**，否则方块能绕过去（手推几何时踩过这个坑）。
	var kinds: Array = _mech_plan(idx)
	if kinds.is_empty():
		return {}
	var g: Dictionary = lv.get("grid", {"x": 8, "z": 8})
	var gx: int = int(g["x"])
	var gz: int = int(g["z"])
	var start: Array = lv["start"]["position"]
	var goals: Array = lv.get("goal", [])
	if goals.is_empty():
		return {}
	var goal: Array = goals[0]
	var rng := RandomNumberGenerator.new()
	rng.seed = seed + 77
	var best := {}
	var best_score: float = INF
	var tries: int = 0
	for thick in [1, 2]:
		for cx in range(2, gx - 2 - thick):
			# 起点与终点必须在沟的两侧（否则不用过沟，机关就成了摆设）
			# 起点与终点都必须在沟**外面**（曾经只比较"哪一侧"，于是起点落在沟里的
			# 候选也被当成合法 → 质检报 "start not on solid ground"，白跑几百次求解）
			if _in_trench(int(start[0]), cx, thick) or _in_trench(int(goal[0]), cx, thick):
				continue
			var s_left: bool = int(start[0]) < cx
			var g_left: bool = int(goal[0]) < cx
			if s_left == g_left:
				continue
			# 落脚点预筛：随机关卡的空洞会把沟两侧打碎，绝大多数桥位置其实"没地方站"。
			# 跨沟需要「起点侧站在沟边 + 落点侧有地」同时成立：
			#   站在 (cx-1, z0) 向 +x 翻滚 → 占地 (cx..cx+thick-1) 与 (cx+thick, z0)
			# 先按这个筛掉不可能的行，命中率会高一个量级（实测：不筛几乎全是不可解）。
			var orig_solid: Dictionary = {}
			for c in _solid_cells(lv):
				orig_solid[c] = true
			for z0 in range(1, gz - 1):
				# 沟不能挖到终点格上
				if int(goal[1]) == z0 and int(goal[0]) >= cx and int(goal[0]) < cx + thick:
					continue
				if not orig_solid.has(Vector2i(cx - 1, z0)):
					continue
				if not orig_solid.has(Vector2i(cx + thick, z0)):
					continue
				for kind in kinds:
					tries += 1
					if tries > MECH_TRENCH_TRIES:
						break
					var defs: Array = []
					var desc: String = ""
					if kind == "bridge":
						# 桥横跨沟（1 格厚 → 可以只 1 格；2 格厚 → 必须两格都架）
						var tiles: Array = []
						for x in range(cx, cx + thick):
							tiles.append([x, z0])
						var sw: Array = _pick_switch_cell(lv, cx, thick, z0, s_left, rng)
						if sw.is_empty():
							continue
						defs = [
							{"id": "sw1", "kind": "switch", "tiles": [sw],
								"target": "br1", "mode": "latch"},
							{"id": "br1", "kind": "bridge", "tiles": tiles},
						]
						desc = "切沟 x=%d(厚%d) + 开关%s→桥%s" % [cx, thick, str(sw), str(tiles)]
					elif kind == "portal":
						# 传送门横跨沟：两侧各一格
						var a: Vector2i = Vector2i(cx - 1, z0)
						var b: Vector2i = Vector2i(cx + thick, z0)
						defs = [{"id": "p1", "kind": "portal", "links": [[a.x, a.y], [b.x, b.y]]}]
						desc = "切沟 x=%d(厚%d) + 传送门 %s↔%s" % [cx, thick, str(a), str(b)]
					else:
						continue
					var cand: Dictionary = lv.duplicate(true)
					cand["holes"] = _trench_holes(lv, cx, thick)
					cand["mechanisms"] = defs
					var rep: Dictionary = Validate.validate_dict(cand)
					if str(rep["status"]) != "valid":
						# 带上第一条错误：否则"invalid"是个没有信息量的黑洞（5000+ 次全靠猜）
						var errs: Array = rep.get("errors", [])
						_rej("%s:invalid[%s]" % [kind, str(errs[0]) if errs.size() > 0 else "?"])
						continue
					var warns: String = str(rep.get("warnings", []))
					if warns.contains("decorative"):
						_rej("%s:decorative" % kind)
						continue
					if warns.contains("hurt"):
						_rej("%s:hurt" % kind)
						continue
					# **必需**判据：去掉机关后必须不可解（比赛"捷径"更强的承重）
					if not _is_essential(cand):
						_rej("%s:not_essential" % kind)
						continue
					var om: int = int(rep["optimal_moves"])
					if om < want - MOVE_TOLERANCE:
						_rej("%s:too_short(%d<%d)" % [kind, om, want])
						continue
					# 桥天生比传送门多花 1~2 步（要先站到沟边、再滚过去），
					# 用同一个上限会把桥候选全部筛掉；放宽上限，最终由曲线校验兜底。
					var hi: int = want + (4 if kind == "bridge" else MOVE_TOLERANCE)
					if om > hi:
						_rej("%s:too_long(%d>%d)" % [kind, om, hi])
						continue
					# **桥优先**：它是"顺序推理"的主力（先按开关才能过），
					# 而传送门只是姿态约束、且位置多得多 —— 按分数比的话桥永远会被挤掉
					# （实测：不加这一条，8 个机关关全是传送门，桥一个都进不来）。
					if kind == "bridge":
						return {"level": cand, "desc": desc, "detail": rep, "essential": true}
					var score: float = absf(float(om - want))
					if score < best_score:
						best = {"level": cand, "desc": desc, "detail": rep, "essential": true}
						best_score = score
					if best_score <= 0.0:
						return best
				if tries > MECH_TRENCH_TRIES:
					break
			if tries > MECH_TRENCH_TRIES:
				break
		if tries > MECH_TRENCH_TRIES:
			break
	return best


func _in_trench(x: int, cx: int, thick: int) -> bool:
	return x >= cx and x < cx + thick


func _reachable_cells(lv: Dictionary) -> Dictionary:
	# 用求解器同一套规则做 BFS，收集"方块真的能占到"的格子。
	# 为什么必须这么做：开关放在随机实心格上，有很大概率落在一块**走不到的孤岛**里
	# （随机关卡 20% 空洞），于是桥永远打不开、整关不可解 —— 本轮 2700+ 次失败的主因。
	var loaded: Dictionary = Loader.load_dict(lv)
	if loaded.has("error"):
		return {}
	var core = Core.new(loaded["board"], loaded["start"])
	var seen: Dictionary = {}
	var out: Dictionary = {}
	var q: Array = [loaded["start"]]
	seen[loaded["start"].canonical_key()] = true
	while q.size() > 0:
		var st = q.pop_front()
		for c in st.world_cells():
			out[Vector2i(c.x, c.z)] = true
		for d in Moves.DIRS:
			var step = Core.apply_step(loaded["board"], st, null, d)
			if step == null or bool(step["fall"]):
				continue
			var k: String = step["state"].canonical_key()
			if seen.has(k):
				continue
			seen[k] = true
			q.append(step["state"])
	return out


func _pick_switch_cell(lv: Dictionary, cx: int, thick: int, z0: int, start_left: bool, rng) -> Array:
	# 开关放哪里，几乎是"桥能不能用"的全部：
	#   ① **必须在起点那一侧**（先按开关才能过沟）；
	#   ② **必须在切沟之后依然可达**（用切沟后的空洞算可达性 —— 不切沟算的话，
	#      有些格子是靠沟里的路才连上的，切完就成孤岛 → 桥永远打不开）；
	#   ③ **尽量贴着沟**（开关离沟越远，关卡被拉得越长，难度就跑出目标区间了）。
	var carved: Dictionary = lv.duplicate(true)
	# _trench_holes 现在直接返回 [[x,z], ...]（JSON 形式），不要再按 Vector2i 取 .x/.y。
	# 这里曾经残留旧写法：格式改了之后它每轮都报错返回，于是**桥候选一次都没被验证**
	# ——表现为"拒绝统计里完全没有 bridge"，看着像"桥都被否了"，其实是根本没跑。
	carved["holes"] = _trench_holes(lv, cx, thick)
	carved["mechanisms"] = []
	var reachable: Dictionary = _reachable_cells(carved)
	if reachable.is_empty():
		return []
	var goals: Array = lv.get("goal", [])
	var near: Array = []      # 贴着沟（距离 ≤ 2）
	var far: Array = []       # 其它可达格（兜底）
	for c in _solid_cells(lv):
		if not reachable.has(c):
			continue
		if start_left and c.x >= cx:
			continue
		if not start_left and c.x < cx + thick:
			continue
		var on_goal := false
		for gg in goals:
			if int(gg[0]) == c.x and int(gg[1]) == c.y:
				on_goal = true
		if on_goal:
			continue
		var dist: int = absi(c.x - (cx - 1)) if start_left else absi(c.x - (cx + thick))
		if dist <= 2 and absi(c.y - z0) <= 2:
			near.append(c)
		else:
			far.append(c)
	var pool: Array = near if near.size() > 0 else far
	if pool.is_empty():
		return []
	# **确定性取最近的**（不再随机）：离沟越远，绕路越长、越容易把关卡拉出目标区间。
	# 本轮的实验很明确：开关正好贴在沟边时，切沟+桥 100% 可解且承重；
	# 随机挑开关时，同一批沟位置大量变成"不可解"（绕路/孤岛）。
	var best: Vector2i = pool[0]
	var best_d: int = 1 << 30
	for c in pool:
		var dx: int = absi(c.x - (cx - 1)) if start_left else absi(c.x - (cx + thick))
		var d: int = dx * 10 + absi(c.y - z0)
		if d < best_d:
			best_d = d
			best = c
	return [best.x, best.y]


func _is_essential(lv: Dictionary) -> bool:
	# 「必需」= 去掉机关后**不可解**（比"去掉后要多走几步"更强的承重形式）
	var bare = Board.new(str(lv.get("id", "")), int(lv["grid"]["x"]), int(lv["grid"]["z"]), [], [],
		[])
	var hs: Array = []
	for h in lv.get("holes", []):
		hs.append(Vector2i(int(h[0]), int(h[1])))
	var gs: Array = []
	for gg in lv.get("goal", []):
		gs.append(Vector2i(int(gg[0]), int(gg[1])))
	bare.holes = hs
	bare.goal = gs
	var loaded: Dictionary = Loader.load_dict(lv)
	if loaded.has("error"):
		return false
	var sol: Dictionary = Solver.new(bare, loaded["start"]).solve()
	return not bool(sol["solvable"])


func _attach_mechanism(lv: Dictionary, idx: int, want: int, seed: int) -> Dictionary:
	# 为这一关找一组**承重**的机关位置。返回 {"level": 带机关的关卡, "desc": 说明} 或 {}。
	var kinds: Array = _mech_plan(idx)
	if kinds.is_empty():
		return {}
	var holes: Array = _hole_cells(lv)
	var solids: Array = _solid_cells(lv)
	if holes.is_empty() or solids.size() < 4:
		return {}
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	# 候选位置：桥要架在**空洞**上（它存在的意义就是补地）；开关/传送门放在实心格上
	var solid_set: Dictionary = {}
	for c in solids:
		solid_set[c] = true
	var bridge_cands: Array = []
	for h in holes:
		# 只考虑"周围实心格较多"的空洞：填上它才可能真正连出一条路。
		# 一个孤零零的空洞填上通常改变不了任何东西（质检会判成装饰品）。
		var nb: int = 0
		for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			if solid_set.has(h + d):
				nb += 1
		if nb < 3:
			continue
		bridge_cands.append([h])
		for d in [Vector2i(1, 0), Vector2i(0, 1)]:
			if solid_set.has(h + d):
				bridge_cands.append([h, h + d])
	var best := {}
	var best_score: float = INF
	var tries: int = 0
	for _t in range(MECH_TRIES):
		if tries >= MECH_TRIES:
			break
		tries += 1
		var kind: String = kinds[tries % kinds.size()]
		var defs: Array = []
		var desc: String = ""
		if kind == "portal" and solids.size() >= 6:
			var a: Vector2i = solids[rng.randi_range(0, solids.size() - 1)]
			var b: Vector2i = solids[rng.randi_range(0, solids.size() - 1)]
			if a == b or (absi(a.x - b.x) + absi(a.y - b.y)) < 4:
				continue
			defs = [{"id": "p1", "kind": "portal", "links": [[a.x, a.y], [b.x, b.y]]}]
			desc = "传送门 %s↔%s" % [str(a), str(b)]
		elif kind == "bridge" and not bridge_cands.is_empty():
			var tiles: Array = bridge_cands[rng.randi_range(0, bridge_cands.size() - 1)]
			# 桥格必须在棋盘内，且桥不能把整条孔洞填平（否则等于没洞）
			var ok_tiles := true
			var tarr: Array = []
			for t in tiles:
				if t.x < 0 or t.y < 0:
					ok_tiles = false
				else:
					tarr.append([t.x, t.y])
			if not ok_tiles:
				continue
			var sw: Vector2i = solids[rng.randi_range(0, solids.size() - 1)]
			defs = [
				{"id": "sw1", "kind": "switch", "tiles": [[sw.x, sw.y]], "target": "br1", "mode": "latch"},
				{"id": "br1", "kind": "bridge", "tiles": tarr},
			]
			desc = "开关 %s → 桥 %s" % [str(sw), str(tarr)]
		else:
			continue
		var cand: Dictionary = lv.duplicate(true)
		cand["mechanisms"] = defs
		var rep: Dictionary = Validate.validate_dict(cand)
		if str(rep["status"]) != "valid":
			continue
		var warns: String = str(rep.get("warnings", []))
		if warns.contains("decorative") or warns.contains("hurt"):
			continue          # 机关不承重 → 直接丢弃（这就是"好不好玩"的自动过滤器）
		var om: int = int(rep["optimal_moves"])
		# 机关会**缩短**最优解（它就是条捷径），所以这里要求"不能比目标更简单"：
		# 只允许略短 1 步，长则按 MOVE_TOLERANCE 容差。
		if om < want - 1 or om > want + MOVE_TOLERANCE:
			continue
		var score: float = absf(float(om - want))
		if score < best_score:
			best = {"level": cand, "desc": desc, "detail": rep, "om": om}
			best_score = score
		if best_score <= 0.0:
			break
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
	var o := {"seed": 2027, "out": "res://levels/generated/candidates"}
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
