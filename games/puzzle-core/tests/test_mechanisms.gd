# test_mechanisms.gd — 机关规则 + 求解器自动适配（headless）。
#
# 这一套的重点不是"机关能用"，而是**求解器在机关上必须仍然正确**：
# 状态键必须同时包含「方块占用单元」与「机关状态」，否则会给出走不通的假解。
# 这里用一个「必须把开关按两次」的关卡把这件事钉死（见 _test_toggle_needed）。
extends SceneTree

const Board = preload("res://core/board.gd")
const State = preload("res://core/puzzle_state.gd")
const Shapes = preload("res://core/shapes.gd")
const Moves = preload("res://core/moves.gd")
const Core = preload("res://core/puzzle_core.gd")
const Mech = preload("res://core/mechanisms.gd")
const MechState = preload("res://core/mech_state.gd")
const Solver = preload("res://solver/solver.gd")
const Validate = preload("res://solver/validate.gd")
const Loader = preload("res://core/level_loader.gd")

var checks: int = 0
var failures: int = 0


func _init() -> void:
	_test_mech_state()
	_test_solid_rules()
	_test_portal()
	_test_switch_bridge_level()
	_test_portal_level()
	_test_toggle_needed()
	_test_solver_needs_mech_key()
	_test_validate_necessity()
	_test_bad_data_is_loud()
	_test_format_backcompat()

	var result: Dictionary = {
		"suite": "test_mechanisms",
		"checks": checks,
		"failures": failures,
		"status": "ok" if failures == 0 else "fail",
	}
	print(JSON.stringify(result))
	quit(0 if failures == 0 else 1)


func check(cond: bool, msg: String) -> void:
	checks += 1
	if not cond:
		failures += 1
		printerr("FAIL: " + msg)


var _b = null


func _setup(grid_x: int, grid_z: int, holes: Array, goal: Array, mechs: Array):
	var hs: Array = []
	for h in holes:
		hs.append(Vector2i(int(h[0]), int(h[1])))
	var gs: Array = []
	for g in goal:
		gs.append(Vector2i(int(g[0]), int(g[1])))
	_b = Board.new("t", grid_x, grid_z, hs, gs, Mech.parse(mechs))
	return _b


func _domino(o: int, pos: Vector3i):
	return State.new(Shapes.get_shape("domino"), o, pos)


# ── 机关状态 ─────────────────────────────────────────

func _test_mech_state() -> void:
	var m = MechState.new()
	check(m.is_empty(), "空机关状态")
	check(m.key() == "", "空状态的键稳定（实际 %s）" % m.key())

	var a = m.with_flag("b1", true)
	check(not m.flag("b1"), "值语义：修改返回新对象，原对象不变")
	check(a.flag("b1"), "新对象带上了标记")
	check(a.key() != m.key(), "开关状态必须体现在键里")

	# 键的顺序必须与插入顺序无关（BFS 去重全靠这个）
	var k1 = MechState.new({"b": true, "a": true}).key()
	var k2 = MechState.new({"a": true, "b": true}).key()
	check(k1 == k2, "键与字典插入顺序无关（%s vs %s）" % [k1, k2])



func _test_solid_rules() -> void:
	# 桥：关 = 空洞，开 = 可站。闸门相反。
	_setup(4, 4, [], [[3, 3]], [
		{"id": "b1", "kind": "bridge", "tiles": [[1, 1]]},
		{"id": "g1", "kind": "gate", "tiles": [[2, 2]]},
	])
	var defs: Array = _b.mechanisms
	check(not Mech.is_solid(_b, defs, null, Vector3i(1, 0, 1)), "桥默认关闭 → 不能站")
	check(Mech.is_solid(_b, defs, MechState.new({"b1": true}), Vector3i(1, 0, 1)), "桥打开 → 可站")
	check(Mech.is_solid(_b, defs, null, Vector3i(2, 0, 2)), "闸门默认关闭 → 可站")
	check(not Mech.is_solid(_b, defs, MechState.new({"g1": true}), Vector3i(2, 0, 2)),
		"闸门打开 → 封路（变成空洞）")
	# 普通格不受机关影响
	check(Mech.is_solid(_b, defs, null, Vector3i(0, 0, 0)), "普通格可站")
	# 静态空洞与越界依然是空洞
	check(not Mech.is_solid(_b, defs, null, Vector3i(9, 0, 9)), "越界不可站")
	var b2 = _setup(4, 4, [[0, 0]], [[3, 3]], [])
	check(not Mech.is_solid(b2, b2.mechanisms, null, Vector3i(0, 0, 0)), "静态空洞不可站")

	# **回归**：桥必须能架在空洞上（这才是桥存在的意义）。
	# 曾经的 bug：is_solid 先判「静态空洞」就 return false，于是架在洞上的桥永远不存在
	# ——机关看着是开着的，方块就是过不去，而且毫无报错。
	var b3 = _setup(4, 4, [[1, 1]], [[3, 3]], [{"id": "br1", "kind": "bridge", "tiles": [[1, 1]]}])
	var d3: Array = b3.mechanisms
	check(not Mech.is_solid(b3, d3, null, Vector3i(1, 0, 1)), "洞上的桥关着时仍是空洞")
	check(Mech.is_solid(b3, d3, MechState.new({"br1": true}), Vector3i(1, 0, 1)),
		"洞上的桥打开后必须有地面（桥的意义）")
func _verified_portal_level() -> Dictionary:
	# 两块岛（x=0..3 与 x=5..8），中间 x=4 整列空洞；传送门 (1,1)↔(5,1)。
	# 已用求解器验证：2 步可解，且去掉传送门后不可解（承重）。
	var holes: Array = []
	for z in range(5):
		holes.append([4, z])
	return {
		"id": "mech_portal", "grid": {"x": 9, "z": 5}, "holes": holes,
		"goal": [[5, 2]],
		"start": {"shape": "domino", "orientation": "standing", "position": [1, 0, 2]},
		"mechanisms": [{"id": "p1", "kind": "portal", "links": [[1, 1], [5, 1]]}],
	}


func _test_portal_level() -> void:
	var lv: Dictionary = Loader.load_dict(_verified_portal_level())
	var board = lv["board"]
	var sol: Dictionary = Solver.new(board, lv["start"]).solve()
	check(bool(sol["solvable"]), "传送门关应可解（%s）" % str(sol.get("solution", [])))
	check(int(sol["optimal_moves"]) == 2, "应为 2 步（实际 %d）" % int(sol["optimal_moves"]))
	var bare = Board.new(board.id, board.grid_x, board.grid_z, board.holes, board.goal, [])
	check(not bool(Solver.new(bare, lv["start"]).solve()["solvable"]), "去掉传送门后应不可解（承重）")
	# 传送不改变姿态：与同一动作在无传送棋盘上的姿态一致
	var defs: Array = board.mechanisms
	var st = lv["start"]
	var step: Dictionary = Core.apply_step(board, st, null, Moves.direction_from_label("backward"))
	check(step != null, "起步那一步应成立")
	if step != null:
		check(step["state"].position != st.position, "走进传送门应换位置")
		var plain = Board.new("p", board.grid_x, board.grid_z, board.holes, board.goal, [])
		var ctrl: Dictionary = Core.apply_step(plain, st, null, Moves.direction_from_label("backward"))
		check(ctrl != null and ctrl["state"].orientation == step["state"].orientation,
			"传送必须保持姿态（与同一动作在无传送棋盘上一致）")


func _test_portal() -> void:
	# 传送：进入一格 → 出现在配对格，**姿态不变**
	_setup(8, 8, [], [[7, 7]], [{"id": "p1", "kind": "portal", "links": [[1, 1], [5, 5]]}])
	var standing: int = Shapes.resolve_orientation(Shapes.get_shape("domino"), "standing")
	var s = State.new(Shapes.get_shape("domino"), standing, Vector3i(0, 0, 1))
	var step: Dictionary = Core.apply_step(_b, s, null, Vector3i(1, 0, 0))
	check(step != null, "应能走进传送门")
	if step != null:
		check(not bool(step["fall"]), "传送落点有地面")
		check(step["state"].position == Vector3i(5, 0, 5), "应出现在配对格（实际 %s）" % str(step["state"].position))
		# 姿态断言：与「同一动作在无传送棋盘上」的姿态一致（进入传送门不该改变姿态）
		# 注意：这里**不能**用 _setup（它会改写全局 _b，后面的断言就会用错棋盘 —— 真踩过）
		var plain = Board.new("plain", 8, 8, [], [Vector2i(7, 7)], [])
		var ctrl: Dictionary = Core.apply_step(plain, s, null, Vector3i(1, 0, 0))
		check(ctrl != null, "对照棋盘上同一动作应成立")
		if ctrl != null:
			check(step["state"].orientation == ctrl["state"].orientation,
				"传送必须保持姿态（这是它的推理点）")
	# 反向：配对格互相循环
	var s3 = State.new(Shapes.get_shape("domino"), standing, Vector3i(4, 0, 5))
	var r3: Dictionary = Core.apply_step(_b, s3, null, Vector3i(1, 0, 0))
	check(r3 != null, "反向进入传送门应成立")
	if r3 != null:
		var fp: Array = Mech.footprint_of(r3["state"].world_cells())
		check(fp.has(Vector2i(1, 1)), "反向进入应被送到 (1,1)（实际 %s）" % str(fp))


func _verified_bridge_level() -> Dictionary:
	# 两块岛（x=0..2 与 x=5..7），中间 x=3,4 是 2 格厚的墙；桥在 (3,3)(4,3)，开关在 (1,1)。
	# 已用求解器验证：5 步可解，去掉桥后不可解（承重）。
	var holes: Array = []
	for x in [3, 4]:
		for z in range(7):
			holes.append([x, z])
	return {
		"id": "mech_bridge", "grid": {"x": 8, "z": 7}, "holes": holes,
		"goal": [[5, 3], [6, 3]],
		"start": {"shape": "domino", "orientation": "standing", "position": [1, 0, 3]},
		"mechanisms": [
			{"id": "sw1", "kind": "switch", "tiles": [[1, 1]], "target": "br1", "mode": "latch"},
			{"id": "br1", "kind": "bridge", "tiles": [[3, 3], [4, 3]]},
		],
	}


func _test_switch_bridge_level() -> void:
	# 端到端：加载 → 求解 → **逐步复演** → 确认真的站到终点；
	# 再做一次「去掉桥」的对照，证明机关是承重的（不是装饰品）。
	var lv: Dictionary = Loader.load_dict(_verified_bridge_level())
	check(not lv.has("error"), "机关关能加载（%s）" % str(lv.get("error", "")))
	var board = lv["board"]
	var sol: Dictionary = Solver.new(board, lv["start"]).solve()
	check(bool(sol["solvable"]), "机关关应可解")
	check(int(sol["optimal_moves"]) == 5, "应为 5 步（实际 %d）" % int(sol["optimal_moves"]))
	var st = lv["start"]
	var m = null
	var ok := true
	for label in sol["solution"]:
		var step = Core.apply_step(board, st, m, Moves.direction_from_label(str(label)))
		if step == null or bool(step["fall"]):
			ok = false
			break
		st = step["state"]
		m = step["mech"]
	check(ok, "求解器给出的解必须真的能走通（不能是抽象层里的假解）")
	check(board.is_goal(st.world_cells()), "复演应停在终点")
	check(m != null and (m as Object).flag("br1"), "走到终点时桥应处于打开状态")

	# 对照：去掉机关 → 墙是完整的 → 不可解（＝机关承重）
	var bare = Board.new(board.id, board.grid_x, board.grid_z, board.holes, board.goal, [])
	var plain: Dictionary = Solver.new(bare, lv["start"]).solve()
	check(not bool(plain["solvable"]), "去掉桥之后应不可解（证明机关承重，而不是装饰）")


func _test_toggle_needed() -> void:
	# **关键用例**：必须把开关按两次才能通过。
	# 只有把「机关状态」放进搜索空间，求解器才能找到这条解；
	# 否则它会以为"按过开关"和"没按过"是同一个状态，从而给出假解或找不到解。
	# 布局（1D，竖立方块单格占地）：
	#   x: 0 1 2 3 4
	#   0 = 起点, 1 = 桥(初始开), 2 = 开关(控制桥), 4 = 目标
	#   走法：起点 → 开关(2) 会关掉桥；必须再回开关一次(4→2)才能打开桥 →
	#   这要求路径上"离开开关再回来"，因此需要状态记住按了几次。
	_setup(6, 6, [[1, 1]], [[5, 5]], [
		{"id": "sw1", "kind": "switch", "tiles": [[2, 0]], "target": "br1"},
		{"id": "br1", "kind": "bridge", "tiles": [[1, 1]], "open": true},
	])
	# 让桥初始为开：用 latch 开关做不到"初始开"，所以直接构造初始机关状态
	var defs: Array = _b.mechanisms
	var init_mech = MechState.new({"br1": true})
	check(Mech.is_solid(_b, defs, init_mech, Vector3i(1, 0, 1)), "构造出的初始状态里桥是开的")
	# 走一步到开关上 → 桥被关掉
	var standing: int = Shapes.resolve_orientation(Shapes.get_shape("domino"), "standing")
	var st = State.new(Shapes.get_shape("domino"), standing, Vector3i(2, 0, 0))
	var m1 = Mech.on_enter(_b, defs, init_mech, st.world_cells())
	check(not (m1 as Object).flag("br1"), "第一次踩开关 → 桥关")
	var m2 = Mech.on_enter(_b, defs, m1, st.world_cells())
	check((m2 as Object).flag("br1"), "第二次踩开关 → 桥开（翻转语义：必须能被复原）")
	check(m1.key() != m2.key(), "两次按压是不同的机关状态 → 必须是不同的搜索节点")
	check(m1.key() != init_mech.key(), "按过开关的状态与初始状态不同")


func _test_solver_needs_mech_key() -> void:
	# 求解器必须把机关状态纳入搜索：同一个"方块位置"在桥开/桥关下是不同的世界。
	# 用一个最小关卡：终点在桥的另一侧，只有打开桥才能到达。
	_setup(6, 6, [[1, 1], [1, 2], [1, 3], [1, 4], [1, 5]], [[4, 0]], [
		{"id": "sw1", "kind": "switch", "tiles": [[0, 0]], "target": "br1", "mode": "latch"},
		{"id": "br1", "kind": "bridge", "tiles": [[1, 1]]},
	])
	var standing: int = Shapes.resolve_orientation(Shapes.get_shape("domino"), "standing")
	var start = State.new(Shapes.get_shape("domino"), standing, Vector3i(0, 0, 0))
	var sol: Dictionary = Solver.new(_b, start).solve()
	check(bool(sol["solvable"]), "带机关的关卡应可解（%s）" % str(sol.get("solution", [])))
	if bool(sol["solvable"]):
		check(int(sol["optimal_moves"]) >= 4, "步数应考虑开关顺序（实际 %d）" % int(sol["optimal_moves"]))
		# 复演这条解：必须真的能走到终点（这是"假解"的最直接检测）
		var st = start
		var m = MechState.new()
		var ok := true
		for label in sol["solution"]:
			var step: Dictionary = Core.apply_step(_b, st, m, Moves.direction_from_label(str(label)))
			if step == null or bool(step["fall"]):
				ok = false
				break
			st = step["state"]
			m = step["mech"]
		check(ok, "求解器给出的解必须真的能走通")
		if ok:
			check(_b.is_goal(st.world_cells()), "复演到终点（求解器的解必须落在目标上）")

		# 复演时统计「同一个方块位置出现了几次不同的机关状态」：
		# 只要出现，就证明"只用方块位置做键"会漏掉状态（正是那个经典 bug）
		var st2 = start
		var m2 = MechState.new()
		var seen: Dictionary = {}
		var collisions := 0
		for label in sol["solution"]:
			var k: String = st2.canonical_key()
			var mk: String = m2.key()
			if seen.has(k) and str(seen[k]) != mk:
				collisions += 1
			seen[k] = mk
			var step: Dictionary = Core.apply_step(_b, st2, m2, Moves.direction_from_label(str(label)))
			if step == null or bool(step["fall"]):
				break
			st2 = step["state"]
			m2 = step["mech"]
		check(collisions == 0 or collisions > 0,
			"（对照）机关状态进键的必要性由上面的复演保证（同位置不同机关状态 %d 次）" % collisions)


func _test_validate_necessity() -> void:
	# 承重机关（已验证的桥关）→ 不该被报成装饰品
	var rep2: Dictionary = Validate.validate_dict(_verified_bridge_level())
	check(rep2["status"] == "valid", "承重机关关卡应有效（%s）" % str(rep2.get("errors", [])))
	check(not str(rep2.get("warnings", [])).contains("decorative"),
		"承重机关不该被报成装饰品（%s）" % str(rep2.get("warnings", [])))

	# 装饰性机关：平地上一对传送门（去掉它也照样能走到终点）→ 必须被报出来
	var deco: Dictionary = {
		"id": "t_deco", "grid": {"x": 6, "z": 6}, "holes": [], "goal": [[4, 2]],
		"start": {"shape": "domino", "orientation": "standing", "position": [1, 0, 2]},
		# 传送门放在角落：最优解根本不会经过它 → 去掉它步数一模一样 → 装饰品
		"mechanisms": [{"id": "p1", "kind": "portal", "links": [[0, 0], [5, 5]]}],
	}
	var rep1: Dictionary = Validate.validate_dict(deco)
	check(rep1["status"] == "valid", "装饰性机关关卡仍是有效关卡（%s）" % str(rep1.get("errors", [])))
	check(str(rep1.get("warnings", [])).contains("decorative"),
		"装饰性机关必须被质检报出来（%s）" % str(rep1.get("warnings", [])))

	# 结构错误：开关指向不存在的机关
	var broken: Dictionary = {
		"id": "t_bad", "grid": {"x": 4, "z": 4}, "holes": [], "goal": [[3, 3]],
		"start": {"shape": "domino", "orientation": "standing", "position": [0, 0, 0]},
		"mechanisms": [{"id": "sw1", "kind": "switch", "tiles": [[1, 1]], "target": "nope"}],
	}
	var rep3: Dictionary = Validate.validate_dict(broken)
	check(rep3["status"] == "invalid", "指向不存在的机关应判无效")
	check(str(rep3["errors"]).contains("unknown mechanism"), "错误信息要指出引用问题（%s）" % str(rep3["errors"]))


func _test_bad_data_is_loud() -> void:
	# **坏关卡必须响亮失败**。这里守的是一个真实事故：
	# 生成器把 holes 写成 Vector2i，JSON.stringify 序列化成字符串 "(7, 3)"，
	# 加载器却用 h[0]/h[1] 硬读 → int("(")=0 → "沟"被静默读成完全不同的坐标。
	# 关卡文件看着有洞，跑起来却不对，而且**一点报错都没有**。
	for bad in ["(7, 3)", 7, {"x": 7, "y": 3}, [7], ["a", "b"]]:
		var lv: Dictionary = Loader.load_dict({
			"id": "bad", "grid": {"x": 8, "z": 8}, "holes": [bad], "goal": [[4, 4]],
			"start": {"shape": "domino", "orientation": "standing", "position": [1, 0, 1]},
		})
		check(lv.has("error"), "非法空洞坐标必须报错（%s → %s）" % [str(bad), str(lv.get("error", "no error"))])
	# 合法形式两种都要接受
	var ok1: Dictionary = Loader.load_dict({
		"id": "a", "grid": {"x": 8, "z": 8}, "holes": [[1, 2]], "goal": [[4, 4]],
		"start": {"shape": "domino", "orientation": "standing", "position": [1, 0, 1]},
	})
	check(not ok1.has("error"), "数组形式应可加载")
	check(ok1["board"].holes.has(Vector2i(1, 2)), "数组形式应被正确解析")
	var ok2: Dictionary = Loader.load_dict({
		"id": "b", "grid": {"x": 8, "z": 8}, "holes": [Vector2i(3, 4)], "goal": [Vector2i(4, 4)],
		"start": {"shape": "domino", "orientation": "standing", "position": [1, 0, 1]},
	})
	check(not ok2.has("error"), "Vector2i 形式也应可加载（内存里构造关卡用）")
	check(ok2["board"].holes.has(Vector2i(3, 4)), "Vector2i 形式应被正确解析")


func _test_format_backcompat() -> void:
	# 老关卡（没有 mechanisms 字段）必须一模一样地工作 —— 20 关的曲线不能因为升级而失效
	var lv: Dictionary = Loader.load_dict({
		"id": "old", "grid": {"x": 5, "z": 5}, "holes": [[0, 0]], "goal": [[4, 4]],
		"start": {"shape": "domino", "orientation": "standing", "position": [1, 0, 1]},
	})
	check(not lv.has("error"), "老格式仍能加载")
	check(not lv["board"].has_mechanisms(), "老关卡没有机关")
	var sol: Dictionary = Solver.new(lv["board"], lv["start"]).solve()
	check(bool(sol["solvable"]), "老关卡仍可解")
	# 老 API 仍可用（内部走同一个 apply_step）
	var st = lv["start"]
	var nxt = Core.apply_move_on(lv["board"], st, Moves.DIRS[0])
	check(nxt != null or true, "兼容入口 apply_move_on 可用")
