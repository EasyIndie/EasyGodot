# game.gd — 视觉层 + 逻辑桥接（Game 节点）。
# 职责：加载关卡、渲染棋盘/方块、把输入转成 core 移动、播放翻滚/坠落动画、检测胜负/坠落。
# 原则：规则判断走 core（roll_delta / supports / is_goal），本层只做「渲染 + 动画 + 桥接」。
#   - 合法移动：方块绕「前下边」翻滚 90° → 播放翻滚动画。
#   - 踩空（越界 或 落在空洞上）：落点没有地面 → 翻滚后继续坠落 → 失败。
#     空洞 = 地面缺失，与越界同构；机关可动态把实心格变空洞（board.set_void），
#     之后调用 check_fall() 即会触发「踩空坠落」。
#   - animate=false 时全部同步执行（供 headless 测试确定性驱动，不依赖帧推进）。
extends Node3D

const Loader = preload("res://core/level_loader.gd")
const Core = preload("res://core/puzzle_core.gd")
const State = preload("res://core/puzzle_state.gd")
const Moves = preload("res://core/moves.gd")

signal won
signal moved
signal fell

# ── 动画参数 ────────────────────────────────────────────
const ROLL_TIME := 0.16        # 一次翻滚时长（秒）
const TIP_TIME := 0.3          # 倾倒（绕支撑边缘翻转 90°）时长（秒）
const FALL_TIME := 0.9         # 自由落体时长（秒）
const FALL_EXTRA_SPIN := PI    # 坠落时额外翻转（弧度，约半圈）
const FALL_GRAVITY := 30.0     # 重力加速度（世界单位/秒²）

# ── 配色 ────────────────────────────────────────────────
const COLOR_TILE_A := Color(0.35, 0.43, 0.62)   # 棋盘格（浅）
const COLOR_TILE_B := Color(0.30, 0.38, 0.56)   # 棋盘格（深）
const COLOR_GOAL := Color(0.18, 0.78, 0.52)     # 目标格（会发光）
const COLOR_BLOCK := Color(1.00, 0.58, 0.20)    # 方块（暖橙）

var core = null          # puzzle_core 实例
var board = null         # Board 实例
var state = null         # PuzzleState 实例
var level_id: String = ""
var block: Node3D = null
var board_root: Node3D = null
var goal_tiles: Array = []   # 目标格（呼吸发光）
var _glow_t: float = 0.0
var won_flag: bool = false
var lost_flag: bool = false
var animating: bool = false
var animate: bool = true     # false = 同步（测试用）
var low_effects: bool = false  # 低端 GPU / 排障：停掉逐帧材质更新
var move_count: int = 0
var _tween: Tween = null


func load_level(path: String) -> bool:
	var lv: Dictionary = Loader.load_file(path)
	if lv.has("error"):
		push_error("game.load_level: " + str(lv))
		return false
	return load_dict(lv)


func load_dict(lv: Dictionary) -> bool:
	_kill_tween()
	board = lv["board"]
	state = lv["start"]
	level_id = board.id
	core = Core.new(board, state)
	won_flag = false
	lost_flag = false
	animating = false
	move_count = 0
	_free_all_children()
	_build_board()
	_build_block()
	_position_block()
	return true


func try_move(d: Vector3i) -> bool:
	if won_flag or lost_flag or animating:
		return false
	var from_state = state
	var r: Dictionary = Moves.roll_delta(from_state.shape, from_state.orientation, d)
	var new_ori: int = r["orientation"]
	var new_pos: Vector3i = from_state.position + r["delta"]
	var from_cells: Array = from_state.world_cells()
	var to_cells: Array = from_state.cells_at(new_ori, new_pos)
	# 落点是否全部实心；否则坠落（棋盘边缘与黑洞都是「失去支撑」，效果一致）
	var supported: bool = board.supports(to_cells)
	# roll_delta 的 pivot 用「单元中心在整数格」的坐标；渲染把方块抬高 0.5 贴地，
	# 所以此处要 +0.5，支点才是方块真正的底棱。
	var pivot_world: Vector3 = Vector3(from_state.position) + r["pivot"] + Vector3(0.0, 0.5, 0.0)
	if supported:
		state = State.new(from_state.shape, new_ori, new_pos, from_state.mechanism)
		move_count += 1
	if animate:
		_start_roll(d, pivot_world, from_cells, to_cells, supported)
	else:
		_finish_move(supported)
	return true


func is_won() -> bool:
	return won_flag


func is_lost() -> bool:
	return lost_flag


func event_to_dir(event: InputEvent) -> Vector3i:
	# 按键 → 移动方向（与 solver 的 right/left/forward/backward 约定一致）
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_RIGHT, KEY_D:
				return Vector3i(1, 0, 0)
			KEY_LEFT, KEY_A:
				return Vector3i(-1, 0, 0)
			KEY_UP, KEY_W:
				return Vector3i(0, 0, -1)  # 屏幕上移 = 远离摄像机 = -z
			KEY_DOWN, KEY_S:
				return Vector3i(0, 0, 1)   # 屏幕下移 = 靠近摄像机 = +z
	return Vector3i.ZERO


# ── 动画 ────────────────────────────────────────────────

func _start_roll(d: Vector3i, pivot_world: Vector3, from_cells: Array, to_cells: Array, supported: bool) -> void:
	animating = true
	var cs: Vector3 = _cells_center(from_cells)  # 当前质心
	var ct: Vector3 = _cells_center(to_cells)    # 翻滚后的质心
	# 用「刚体」节点承载方块：绕支点 P 旋转时整体位置 = P + R(θ)·(C_s - P)
	# 这样它在翻滚阶段绕前下边转，坠落阶段可以改为绕自身质心转。
	var rig := Node3D.new()
	rig.name = "RollRig"
	add_child(rig)
	for cube in block.get_children().duplicate():
		block.remove_child(cube)
		rig.add_child(cube)
		cube.position -= cs  # 改为「相对质心」，便于后续绕质心旋转

	var m: Array = Moves.roll_rotation(d)
	var q_roll: Quaternion = Basis(Vector3(m[0]), Vector3(m[1]), Vector3(m[2])).get_rotation_quaternion()

	_tween = create_tween()
	# 1) 绕「前下边」翻滚 90°（角速度递增，模拟重力力矩）
	_tween.tween_method(
		func(t: float) -> void:
			var q: Quaternion = Quaternion.IDENTITY.slerp(q_roll, t * t)
			rig.quaternion = q
			rig.position = pivot_world + q * (cs - pivot_world),
		0.0, 1.0, ROLL_TIME)
	if not supported:
		_append_fall(rig, ct, to_cells, q_roll, q_roll.get_axis(), FALL_EXTRA_SPIN)
	_tween.finished.connect(_on_anim_finished.bind(rig, supported))


## 机关扩展点：棋盘改变（如 set_void）后调用。方块脚下已无地面 → 触发「踩空坠落」。
func check_fall() -> bool:
	if won_flag or lost_flag or animating:
		return false
	var cells: Array = state.world_cells()
	if board.supports(cells):
		return false
	if not animate:
		lost_flag = true
		fell.emit()
		return true
	animating = true
	var c: Vector3 = _cells_center(cells)
	# 同样用刚体节点承载方块（单元位置改为相对质心）
	var rig := Node3D.new()
	rig.name = "FallRig"
	add_child(rig)
	for cube in block.get_children().duplicate():
		block.remove_child(cube)
		rig.add_child(cube)
		cube.position -= c
	_tween = create_tween()
	# 原地失去支撑：没有翻滚动作，直接按支撑情况坠落
	_append_fall(rig, c, cells, Quaternion.IDENTITY, Vector3.RIGHT, 0.0)
	_tween.finished.connect(_on_anim_finished.bind(rig, false))
	return true


func _append_fall(rig: Node3D, base_pos: Vector3, cells: Array, q_base: Quaternion, spin_axis: Vector3, spin: float) -> void:
	# 在当前 tween 后追加坠落阶段：
	#   完全无支撑 → 自由落体（+自旋）；部分有支撑 → 先绕支撑边缘倾倒 90°，脱离后再落体
	var solid: Array = []
	for c in cells:
		if board.is_solid(c):
			solid.append(c)
	if solid.is_empty():
		_tween.tween_method(
			func(u: float) -> void:
				rig.quaternion = Quaternion(spin_axis, spin * u * u) * q_base
				var t_sec: float = u * FALL_TIME
				rig.position = base_pos + Vector3(0.0, -0.5 * FALL_GRAVITY * t_sec * t_sec, 0.0),
			0.0, 1.0, FALL_TIME)
		return
	# 部分悬空：绕支撑边缘倾倒
	var tdir: Vector3 = _topple_dir(solid, cells)
	var tip_axis: Vector3 = Vector3.UP.cross(tdir)
	var along_x: bool = absf(tdir.x) > absf(tdir.z)
	var sgn: float = tdir.x if along_x else tdir.z
	var boundary: float = -INF
	for c in solid:
		var coord: float = float(c.x) if along_x else float(c.z)
		boundary = maxf(boundary, coord + 0.5 * sgn)
	var p_tip: Vector3 = base_pos
	if along_x:
		p_tip.x = boundary
	else:
		p_tip.z = boundary
	p_tip.y = base_pos.y - 0.5  # 方块底面
	var total: float = TIP_TIME + FALL_TIME
	_tween.tween_method(
		func(s: float) -> void:
			var t: float = s * total
			var tip: float
			var drop: float
			if t <= TIP_TIME:
				var u: float = t / TIP_TIME
				tip = (PI / 2.0) * u * u
				drop = 0.0
			else:
				var u: float = (t - TIP_TIME) / FALL_TIME
				tip = PI / 2.0 + (PI / 2.0) * u
				drop = 0.5 * FALL_GRAVITY * (u * FALL_TIME) * (u * FALL_TIME)
			var q_tip: Quaternion = Quaternion(tip_axis, tip)
			rig.quaternion = q_tip * q_base
			rig.position = p_tip + q_tip * (base_pos - p_tip) + Vector3(0.0, -drop, 0.0),
		0.0, 1.0, total)


func _on_anim_finished(rig: Node3D, supported: bool) -> void:
	for cube in rig.get_children().duplicate():
		rig.remove_child(cube)
		cube.free()
	remove_child(rig)
	rig.free()
	_tween = null
	animating = false
	_finish_move(supported)


func _cells_center(cells: Array) -> Vector3:
	# 单元立方体（中心在格子上方半格）的质心
	var c := Vector3.ZERO
	for cell in cells:
		c += Vector3(float(cell.x), float(cell.y) + 0.5, float(cell.z))
	return c / float(max(cells.size(), 1))


func _topple_dir(solid: Array, cells: Array) -> Vector3:
	# 从支撑区域指向空洞区域的水平主轴（倾倒方向）
	var sc := Vector3.ZERO
	for c in solid:
		sc += Vector3(float(c.x), 0.0, float(c.z))
	sc /= float(solid.size())
	var vc := Vector3.ZERO
	var n: int = 0
	for c in cells:
		if not board.is_solid(c):
			vc += Vector3(float(c.x), 0.0, float(c.z))
			n += 1
	if n == 0:
		return Vector3(0.0, 0.0, 1.0)
	vc /= float(n)
	var d: Vector3 = vc - sc
	if d.length() < 0.001:
		return Vector3(0.0, 0.0, 1.0)
	if absf(d.x) >= absf(d.z):
		return Vector3(signf(d.x), 0.0, 0.0)
	return Vector3(0.0, 0.0, signf(d.z))


func _finish_move(supported: bool) -> void:
	if not supported:
		# 方块没了；等待重开
		lost_flag = true
		fell.emit()
		return
	_position_block()
	moved.emit()
	if board.is_goal(state.world_cells()):
		won_flag = true
		won.emit()


func _kill_tween() -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = null


# ── 渲染 ────────────────────────────────────────────────

func _build_board() -> void:
	goal_tiles.clear()
	board_root = Node3D.new()
	board_root.name = "Board"
	add_child(board_root)
	for x in range(board.grid_x):
		for z in range(board.grid_z):
			var v2 := Vector2i(x, z)
			if board.is_void(Vector3i(x, 0, z)):
				# 空洞 = 地面缺失：直接不画地面（透出背景），就是一块“空的洞”
				continue
			# 棋盘格：明暗交替，便于判断方格位置
			var color: Color = COLOR_TILE_A if (x + z) % 2 == 0 else COLOR_TILE_B
			var emissive := false
			var is_goal: bool = board.goal.has(v2)
			if is_goal:
				color = COLOR_GOAL
				emissive = true
			var m := _make_box(Vector3(0.94, 0.2, 0.94), color, emissive)
			m.position = Vector3(float(x), -0.1, float(z))
			# 瓦片不投影，但接收方块的影子 → 立体感
			m.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			board_root.add_child(m)
			if is_goal:
				goal_tiles.append(m)


func _build_block() -> void:
	block = Node3D.new()
	block.name = "Block"
	add_child(block)


func _position_block() -> void:
	# 通用 PolyCube 渲染：每个世界单元画一个 1x1x1 立方体（对任意形状/方向都成立）
	_free_children(block)
	for cell in state.world_cells():
		var m := _make_box(Vector3(1.0, 1.0, 1.0), COLOR_BLOCK)
		m.position = Vector3(float(cell.x), float(cell.y) + 0.5, float(cell.z))
		block.add_child(m)


func _make_box(size: Vector3, color: Color, emissive: bool = false) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.85
	if emissive:
		mat.emission_enabled = true
		mat.emission = color
		mat.emission_energy_multiplier = 0.4
	box.material = mat
	mi.mesh = box
	return mi


func _process(delta: float) -> void:
	# 目标格「呼吸」发光：既吸引注意，也让画面久看不呆板
	if low_effects or goal_tiles.is_empty():
		return
	_glow_t += delta
	var glow: float = 0.35 + 0.25 * sin(_glow_t * 2.0)
	for mi in goal_tiles:
		if is_instance_valid(mi) and mi.mesh is BoxMesh:
			var mat: StandardMaterial3D = mi.mesh.material
			if mat != null:
				mat.emission_energy_multiplier = glow


func _free_children(node: Node) -> void:
	for c in node.get_children():
		node.remove_child(c)
		c.free()


func _free_all_children() -> void:
	for c in get_children():
		remove_child(c)
		c.free()
