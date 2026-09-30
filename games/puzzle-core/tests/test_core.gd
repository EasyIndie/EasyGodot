# test_core.gd — Puzzle Core 单元/状态测试（headless 运行）。
# 运行方式: workflow/scripts/gf-run.sh -p games/puzzle-core res://tests/test_core.gd
# 约定: stdout 输出单行 JSON，失败退出码非 0。
extends SceneTree

const Rot = preload("res://core/rotations.gd")
const Util = preload("res://core/util.gd")
const Shape = preload("res://core/shape.gd")
const Shapes = preload("res://core/shapes.gd")
const State = preload("res://core/puzzle_state.gd")
const Moves = preload("res://core/moves.gd")
const Board = preload("res://core/board.gd")
const Core = preload("res://core/puzzle_core.gd")
const Loader = preload("res://core/level_loader.gd")

var checks: int = 0
var failures: int = 0


func _init() -> void:
	_test_rotations()
	_test_shape_normalization()
	_test_domino_rolls()
	_test_shape_registry()
	_test_reversibility()
	_test_board_and_goal()
	_test_level_loader()

	var result: Dictionary = {
		"suite": "test_core",
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
		push_error("FAIL: " + msg)


# ---- 辅助 ----

func _cells(xyzs: Array) -> Array:
	var out: Array = []
	for a in xyzs:
		out.append(Vector3i(int(a[0]), int(a[1]), int(a[2])))
	return out


func _keys(ws: Array) -> Array:
	var out: Array = []
	for c in ws:
		out.append(Vector3i(c.x, c.y, c.z))
	return Util.sort_cells(out)


func _eq_cells(actual: Array, expected: Array, msg: String) -> void:
	check(_keys(actual) == _keys(expected), msg + "  got=" + str(_keys(actual)) + " want=" + str(_keys(expected)))


func _apply_roll(state, d: Vector3i) -> Array:
	var r: Dictionary = Moves.roll_delta(state.shape, state.orientation, d)
	var new_pos: Vector3i = state.position + r["delta"]
	return state.cells_at(r["orientation"], new_pos)


func _make_state(shape_id: String, orientation, pos: Array) -> State:
	var shape = Shapes.get_shape(shape_id)
	var orient: int = Shapes.resolve_orientation(shape, orientation)
	return State.new(shape, orient, Vector3i(int(pos[0]), int(pos[1]), int(pos[2])))


# ---- 测试组 ----

func _test_rotations() -> void:
	var oris: Array = Rot.all_orientations()
	check(oris.size() == 24, "应恰好有 24 个方向")

	# 每个方向都应保定向（det=+1）且作用在向量上保持整数
	for m in oris:
		var det: int = Rot.dot(Rot.cross(m[0], m[1]), m[2])
		check(det == 1, "方向矩阵行列式应为 +1")

	# 单位矩阵应用不改变向量
	check(Rot.apply(Rot.identity(), Vector3i(3, -2, 5)) == Vector3i(3, -2, 5), "单位矩阵作用不变")

	# 组合：先逆再正 = 单位
	var qz: Array = Rot.quarter_turn(Rot.EZ)
	check(Rot.index_of(Rot.compose(Rot.inverse(qz), qz)) == Rot.index_of(Rot.identity()), "QZ^-1 ∘ QZ = I")


func _test_shape_normalization() -> void:
	var s = Shape.new("t", [Vector3i(2, 1, 3), Vector3i(3, 1, 3)])
	check(s.cells == [Vector3i(0, 0, 0), Vector3i(1, 0, 0)], "Shape 局部坐标应规范化到原点")

	var d = Shapes.get_shape("domino")
	check(d.cells == [Vector3i(0, 0, 0), Vector3i(1, 0, 0)], "domino 默认沿 X 横躺")

	var standing_orient: int = Shapes.resolve_orientation(d, "standing")
	check(standing_orient >= 0, "应能解析 standing 方向")
	check(d.oriented_cells(standing_orient) == _cells([[0, 0, 0], [0, 1, 0]]), "standing 方向单元应为竖向")


func _test_domino_rolls() -> void:
	# 竖立：滚 → 横躺（前移，覆盖 p+d 与 p+2d）
	var st = _make_state("domino", "standing", [0, 0, 0])
	_eq_cells(_apply_roll(st, Vector3i(1, 0, 0)), _cells([[1, 0, 0], [2, 0, 0]]), "standing +x")
	_eq_cells(_apply_roll(st, Vector3i(-1, 0, 0)), _cells([[-2, 0, 0], [-1, 0, 0]]), "standing -x")
	_eq_cells(_apply_roll(st, Vector3i(0, 0, 1)), _cells([[0, 0, 1], [0, 0, 2]]), "standing +z")
	_eq_cells(_apply_roll(st, Vector3i(0, 0, -1)), _cells([[0, 0, -2], [0, 0, -1]]), "standing -z")

	# 沿 X 横躺：沿长轴滚 → 竖立（前移 2 格）；垂直滚 → 侧移 1 格仍横躺
	var lx = _make_state("domino", "lying_x", [0, 0, 0])
	_eq_cells(_apply_roll(lx, Vector3i(1, 0, 0)), _cells([[2, 0, 0], [2, 1, 0]]), "lying_x +x（竖立）")
	_eq_cells(_apply_roll(lx, Vector3i(-1, 0, 0)), _cells([[-1, 0, 0], [-1, 1, 0]]), "lying_x -x（竖立）")
	_eq_cells(_apply_roll(lx, Vector3i(0, 0, 1)), _cells([[0, 0, 1], [1, 0, 1]]), "lying_x +z（侧移）")
	_eq_cells(_apply_roll(lx, Vector3i(0, 0, -1)), _cells([[0, 0, -1], [1, 0, -1]]), "lying_x -z（侧移）")

	# 沿 Z 横躺
	var lz = _make_state("domino", "lying_z", [0, 0, 0])
	_eq_cells(_apply_roll(lz, Vector3i(0, 0, 1)), _cells([[0, 0, 2], [0, 1, 2]]), "lying_z +z（竖立）")
	_eq_cells(_apply_roll(lz, Vector3i(0, 0, -1)), _cells([[0, 0, -1], [0, 1, -1]]), "lying_z -z（竖立）")
	_eq_cells(_apply_roll(lz, Vector3i(1, 0, 0)), _cells([[1, 0, 0], [1, 0, 1]]), "lying_z +x（侧移）")
	_eq_cells(_apply_roll(lz, Vector3i(-1, 0, 0)), _cells([[-1, 0, 0], [-1, 0, 1]]), "lying_z -x（侧移）")


func _test_shape_registry() -> void:
	# 形状是**数据登记**出来的（shapes.gd 的 REGISTRY / ORIENTATIONS），
	# 所以这里既验证“能用的形状确实能用”，也验证“删掉的形状确实不存在”。
	#
	# 历史：cube 曾经注册过，但单格方块在平面棋盘上没有姿态约束，
	# 只能一条直线走到目标，玩起来“点几下就通关”（后来的冰面补丁更糟：一滑就坠落）。
	# 最终整个移除，并留下这条断言——防止它（或任何死形状）被悄悄加回来。
	check(Shapes.get_shape("cube") == null, "已移除的 cube 形状不应存在")
	check(Shapes.get_shape("nonsense") == null, "未知形状应返回 null")
	check(Shapes.ids().has("domino"), "domino 应已注册")
	check(Shapes.display_name("domino") != "", "形状应有玩家可见名字")
	check(Shapes.display_name("nonsense") == "nonsense", "未知形状的名字应原样回退")

	# 语义化方向：三个方向必须**互不相同**（曾经对单格形状做特判，全部折叠成 0，
	# 那种特判很危险——一旦有新形状依赖它就会悄悄错掉）
	var d = Shapes.get_shape("domino")
	var ox: int = Shapes.resolve_orientation(d, "lying_x")
	var oz: int = Shapes.resolve_orientation(d, "lying_z")
	var st: int = Shapes.resolve_orientation(d, "standing")
	check(ox >= 0 and oz >= 0 and st >= 0, "三个语义方向都应能解析")
	check(ox != oz and ox != st and oz != st, "横躺 X / 横躺 Z / 竖立应是不同方向")
	check(Shapes.resolve_orientation(d, 7) == 7, "整数方向应原样返回")
	check(Shapes.resolve_orientation(d, "nonsense") == -1, "非法描述符应返回 -1")
	check(Shapes.orientation_names("domino").size() == 3, "方向表应有 3 个名字")
	check(Shapes.orientation_names("nonsense").is_empty(), "未知形状没有方向名")

	# 方向描述符解析出来的索引，必须真的对应那组单元
	var st_cells: Array = d.oriented_cells(st)
	check(st_cells.has(Vector3i(0, 1, 0)), "竖立方向应含竖直方向的第二格")

	# 加载器对未知形状 / 非法方向都要报错，而不是静默兜底
	check(str(Loader.load_dict({
		"grid": {"x": 4, "z": 4}, "goal": [[3, 3]],
		"start": {"shape": "cube", "orientation": "standing", "position": [0, 0, 0]},
	}).get("error", "")) == "unknown_shape", "未知形状应报 unknown_shape")
	check(str(Loader.load_dict({
		"grid": {"x": 4, "z": 4}, "goal": [[3, 3]],
		"start": {"shape": "domino", "orientation": "nonsense", "position": [0, 0, 0]},
	}).get("error", "")) == "bad_orientation", "非法方向应报 bad_orientation")

	# 状态不该再带机关字段（机制已整体移除，不留死字段）
	var s = State.new(d, ox, Vector3i(0, 0, 0))
	check(s.to_dict().keys().size() == 3, "状态只应有 shape/orientation/position 三个字段")
	check(not s.to_dict().has("mechanism"), "状态不应残留 mechanism 字段")


func _test_reversibility() -> void:
	# 翻滚可逆：d 再 -d 应回到相同世界单元
	var dirs: Array = [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)]
	var starts: Array = [
		_make_state("domino", "standing", [2, 0, 2]),
		_make_state("domino", "lying_x", [2, 0, 2]),
		_make_state("domino", "lying_z", [2, 0, 2]),
	]
	for s in starts:
		for d in dirs:
			var after: Array = _apply_roll(s, d)
			# 构造翻滚后的状态，再滚 -d
			var r: Dictionary = Moves.roll_delta(s.shape, s.orientation, d)
			var s2 = State.new(s.shape, r["orientation"], s.position + r["delta"])
			var back: Array = _apply_roll(s2, -d)
			_eq_cells(back, s.world_cells(), "可逆性 %s %s" % [s.shape.id, str(d)])


func _test_board_and_goal() -> void:
	var b = Board.new("t", 4, 4, [Vector2i(1, 1)], [Vector2i(3, 3)])
	check(b.is_solid(Vector3i(0, 0, 0)), "棋盘内非洞应为实心")
	check(not b.is_solid(Vector3i(1, 0, 1)), "洞应为非实心（注意 Vector3i 是 x,y,z）")
	check(not b.is_solid(Vector3i(-1, 0, 0)), "棋盘外应为非实心")
	check(not b.is_solid(Vector3i(0, 0, 4)), "棋盘外 z 超界应为非实心")

	# 竖立在目标格 (3,3) 应获胜
	var goal_state = State.new(Shapes.get_shape("domino"), Shapes.resolve_orientation(Shapes.get_shape("domino"), "standing"), Vector3i(3, 0, 3))
	check(b.is_goal(goal_state.world_cells()), "竖立在目标格应获胜")

	# 横躺覆盖目标格不应获胜（占地 2 格）
	var lying_state = State.new(Shapes.get_shape("domino"), 0, Vector3i(3, 0, 3))
	check(not b.is_goal(lying_state.world_cells()), "横躺覆盖目标格不应获胜")


func _test_level_loader() -> void:
	# 从内联字典加载
	var data: Dictionary = {
		"id": "lv", "grid": {"x": 6, "z": 6},
		"holes": [[2, 2]], "goal": [[5, 5]],
		"start": {"shape": "domino", "orientation": "standing", "position": [0, 0, 0]},
	}
	var lv: Dictionary = Loader.load_dict(data)
	check(not lv.has("error"), "内联关卡应能正常加载")
	check(lv["board"].grid_x == 6, "棋盘尺寸应正确")
	_eq_cells(lv["start"].world_cells(), _cells([[0, 0, 0], [0, 1, 0]]), "起点应竖立")

	# 从文件加载示例关卡
	var lv2: Dictionary = Loader.load_file("res://levels/level_01.json")
	check(not lv2.has("error"), "level_01.json 应能加载: " + str(lv2))
	check(lv2["board"].id == "level_01", "关卡 id 应正确")
	check(lv2["start"].world_cells().size() == 2, "domino 起点应占 2 个单元")

	# 非法形状应报错
	var bad: Dictionary = {"start": {"shape": "nope", "orientation": 0, "position": [0, 0, 0]}}
	check(Loader.load_dict(bad).has("error"), "未知形状应报错")
