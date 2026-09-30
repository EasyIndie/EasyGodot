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
	_test_cube_rolls()
	_test_cube_orientation_descriptors()
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


func _test_cube_rolls() -> void:
	var cu = _make_state("cube", 0, [0, 0, 0])
	_eq_cells(_apply_roll(cu, Vector3i(1, 0, 0)), _cells([[1, 0, 0]]), "cube +x")
	_eq_cells(_apply_roll(cu, Vector3i(-1, 0, 0)), _cells([[-1, 0, 0]]), "cube -x")
	_eq_cells(_apply_roll(cu, Vector3i(0, 0, 1)), _cells([[0, 0, 1]]), "cube +z")
	_eq_cells(_apply_roll(cu, Vector3i(0, 0, -1)), _cells([[0, 0, -1]]), "cube -z")


func _test_cube_orientation_descriptors() -> void:
	# cube 是单格形状：所有语义方向描述符都应解析到 identity(0)，而不是报错
	var cu = Shapes.get_shape("cube")
	for desc in ["standing", "lying_x", "lying_z"]:
		check(Shapes.resolve_orientation(cu, desc) == 0, "cube 的 %s 应解析为 0" % desc)
	check(Shapes.resolve_orientation(cu, 7) == 7, "整数方向应原样返回")

	# 加载器应接受带语义描述符的 cube 关卡（此前会报 bad_orientation）
	var lv: Dictionary = Loader.load_dict({
		"id": "cube_lv", "grid": {"x": 4, "z": 4}, "holes": [], "goal": [[3, 3]],
		"start": {"shape": "cube", "orientation": "standing", "position": [0, 0, 0]},
	})
	check(not lv.has("error"), "cube 关卡应能加载: " + str(lv))
	if not lv.has("error"):
		_eq_cells(lv["start"].world_cells(), _cells([[0, 0, 0]]), "cube 起点应只占 1 格")

	# 多格形状仍应真区分方向（不能因单格特判而误伤）
	var d = Shapes.get_shape("domino")
	check(Shapes.resolve_orientation(d, "standing") != Shapes.resolve_orientation(d, "lying_x"), "domino 的竖立与横躺应是不同方向")
	check(Shapes.resolve_orientation(d, "nonsense") == -1, "domino 的非法描述符仍应报错")


func _test_reversibility() -> void:
	# 翻滚可逆：d 再 -d 应回到相同世界单元
	var dirs: Array = [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)]
	var starts: Array = [
		_make_state("domino", "standing", [2, 0, 2]),
		_make_state("domino", "lying_x", [2, 0, 2]),
		_make_state("domino", "lying_z", [2, 0, 2]),
		_make_state("cube", 0, [3, 0, 3]),
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
