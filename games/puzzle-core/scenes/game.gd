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
# 棋盘两色 + 目标色 + 方块色。数值刻意压得比“纯色块”灰一点、暗一点，
# 这样顶面提亮/边缘压暗（见下面的着色器）才有空间做出层次。
const COLOR_TILE_A := Color(0.38, 0.46, 0.66)   # 棋盘格（浅）
const COLOR_TILE_B := Color(0.31, 0.39, 0.58)   # 棋盘格（深）
const COLOR_GOAL := Color(0.16, 0.80, 0.52)     # 目标格（会呼吸发光）
const COLOR_BLOCK := Color(1.00, 0.60, 0.22)    # 方块（暖橙）
const COLOR_GOAL_RING := Color(0.35, 1.00, 0.70) # 目标“光圈”（嵌在瓦片表面）

# 落地回弹的挤压幅度：很小的数值就有明显的“重量感”，是性价比最高的一档手感反馈
const LAND_SQUASH := 0.16
const SPAWN_HEIGHT := 7.0      # 重开时方块落下的起始高度
const SPAWN_TIME := 0.5        # 落下时长

var core = null          # puzzle_core 实例
var board = null         # Board 实例
var state = null         # PuzzleState 实例
var level_id: String = ""
var block: Node3D = null
var board_root: Node3D = null
var tiles: Array = []        # 全部实心瓦片
var goal_tiles: Array = []   # 目标格（呼吸发光）
var goal_rings: Array = []   # 目标光圈（随棋盘一起升降/旋转）
var _tile_mat_a: ShaderMaterial = null
var _tile_mat_b: ShaderMaterial = null
var _tile_mat_goal: ShaderMaterial = null
var _block_mat: ShaderMaterial = null
var _glow_t: float = 0.0
var _win_flash: float = 0.0
var _quality_tier: int = 3
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
	_win_flash = 0.0
	block = null
	_free_all_children()
	_build_board()
	_build_block()
	_position_block()
	return true


func _plan_move(d: Vector3i) -> Dictionary:
	# 单步移动的完整几何信息（纯计算，不改状态）。
	# roll_delta 的 pivot 用「单元中心在整数格」的坐标；渲染把方块抬高 0.5 贴地，
	# 所以此处要 +0.5，支点才是方块真正的底棱。
	var r: Dictionary = Moves.roll_delta(state.shape, state.orientation, d)
	var next_pos: Vector3i = state.position + r["delta"]
	var to_cells: Array = state.cells_at(r["orientation"], next_pos)
	return {
		"orientation": r["orientation"],
		"position": next_pos,
		"pivot": Vector3(state.position) + r["pivot"] + Vector3(0.0, 0.5, 0.0),
		"from_cells": state.world_cells(),
		"to_cells": to_cells,
		"supported": board.supports(to_cells),
	}


func try_move(d: Vector3i) -> bool:
	if won_flag or lost_flag or animating:
		return false
	var st: Dictionary = _plan_move(d)
	# 落点是否全部实心；否则坠落（棋盘边缘与空洞都是「失去支撑」，效果一致）
	var supported: bool = bool(st["supported"])
	if supported:
		state = State.new(state.shape, int(st["orientation"]), st["position"])
		move_count += 1
	if animate:
		_start_roll(d, st)
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

func _start_roll(d: Vector3i, st: Dictionary) -> void:
	# 绕「前下边」翻滚 90°。
	# 用「刚体」节点承载方块：单元位置改为相对质心，于是「绕支点旋转 + 整块平移」
	# 可以用同一个四元数统一表达（对任意形状都成立）：
	#   new_q = R · q，  new_pos = P + R · (pos − P)
	animating = true
	var supported: bool = bool(st["supported"])
	var cs: Vector3 = _cells_center(st["from_cells"])
	var rig := Node3D.new()
	rig.name = "RollRig"
	add_child(rig)
	for cube in block.get_children().duplicate():
		block.remove_child(cube)
		rig.add_child(cube)
		cube.position -= cs

	var m: Array = Moves.roll_rotation(d)
	var q_step: Quaternion = Basis(Vector3(m[0]), Vector3(m[1]), Vector3(m[2])).get_rotation_quaternion()
	var pv: Vector3 = st["pivot"]
	_tween = create_tween()
	_tween.tween_method(
		func(t: float) -> void:
			var q: Quaternion = Quaternion.IDENTITY.slerp(q_step, t * t)  # 角速度递增，模拟重力力矩
			rig.quaternion = q
			rig.position = pv + q * (cs - pv),
		0.0, 1.0, ROLL_TIME)
	if not supported:
		var to_cells: Array = st["to_cells"]
		_append_fall(rig, _cells_center(to_cells), to_cells, q_step, q_step.get_axis(), FALL_EXTRA_SPIN)
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
	play_land_squash()
	moved.emit()
	if board.is_goal(state.world_cells()):
		won_flag = true
		_win_flash = 1.0   # 通关闪光（方块不位移、不变色）
		won.emit()


func _kill_tween() -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = null


# ── 渲染 ────────────────────────────────────────────────

func _build_board() -> void:
	tiles.clear()
	goal_tiles.clear()
	goal_rings.clear()
	_tile_mat_a = _make_tile_material(COLOR_TILE_A)
	_tile_mat_b = _make_tile_material(COLOR_TILE_B)
	_tile_mat_goal = _make_tile_material(COLOR_GOAL, 0.55)
	board_root = Node3D.new()
	board_root.name = "Board"
	add_child(board_root)
	for x in range(board.grid_x):
		for z in range(board.grid_z):
			var v2 := Vector2i(x, z)
			if board.is_void(Vector3i(x, 0, z)):
				# 空洞 = 地面缺失：直接不画地面（透出背景），就是一块“空的洞”
				continue
			var is_goal: bool = board.goal.has(v2)
			var mat: ShaderMaterial = _tile_mat_goal if is_goal else (
				_tile_mat_a if (x + z) % 2 == 0 else _tile_mat_b)
			var m := _make_box(Vector3(0.94, 0.2, 0.94), mat)
			m.position = Vector3(float(x), -0.1, float(z))
			# 瓦片不投影，但接收方块的影子 → 立体感
			m.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			board_root.add_child(m)
			tiles.append(m)
			if is_goal:
				goal_tiles.append(m)
				board_root.add_child(_make_goal_ring(Vector3(float(x), 0.0, float(z))))


func _make_tile_material(base: Color, glow: float = 0.0) -> ShaderMaterial:
	# 瓦片着色器：**低多边形也能有体积感**的关键
	#   1) 顶面提亮、侧面压暗（用世界法线的 y 分量判断“是不是顶面”）
	#   2) 靠近面边缘轻微压暗 —— 用 UV 到边界的距离模拟倒角，比加几何体便宜得多
	#   3) glow 给目标格做呼吸发光
	var sh := Shader.new()
	sh.code = """
shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;
uniform vec3 base_color : source_color = vec3(0.38, 0.46, 0.66);
uniform float top_boost = 0.18;
uniform float edge_dark = 0.26;
uniform float glow : hint_range(0.0, 2.0) = 0.0;
void fragment() {
	vec3 wn = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	float up = clamp(wn.y, 0.0, 1.0);
	vec3 c = base_color * mix(1.0 - edge_dark, 1.0 + top_boost, up);
	vec2 e = min(UV, vec2(1.0) - UV);
	float rim = smoothstep(0.0, 0.09, min(e.x, e.y));
	c *= mix(0.82, 1.0, rim);
	ALBEDO = c;
	ROUGHNESS = 0.70;
	METALLIC = 0.0;
	EMISSION = base_color * glow;
}
"""
	var mat := ShaderMaterial.new()
	mat.shader = sh
	mat.set_shader_parameter("base_color", base)
	mat.set_shader_parameter("glow", glow)
	return mat


func _make_goal_ring(pos: Vector3) -> MeshInstance3D:
	# 目标标记：嵌在瓦片表面的一圈荧光（比“整格变绿”更清楚，也不会被方块完全盖住）
	var t := TorusMesh.new()
	t.inner_radius = 0.26
	t.outer_radius = 0.38
	t.rings = 24
	t.ring_segments = 6
	var sh := Shader.new()
	sh.code = """
shader_type spatial;
render_mode unshaded, cull_disabled;
uniform vec3 ring_color : source_color = vec3(0.35, 1.0, 0.70);
uniform float energy = 1.0;
void fragment() {
	ALBEDO = ring_color * energy;
	EMISSION = ring_color * energy;
}
"""
	var mat := ShaderMaterial.new()
	mat.shader = sh
	mat.set_shader_parameter("ring_color", COLOR_GOAL_RING)
	mat.set_shader_parameter("energy", 1.0)
	var mi := MeshInstance3D.new()
	mi.name = "GoalRing"
	mi.mesh = t
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.position = pos
	mi.rotation_degrees = Vector3(90.0, 0.0, 0.0)   # 平铺在瓦片上
	goal_rings.append(mi)
	return mi


func _build_block() -> void:
	block = Node3D.new()
	block.name = "Block"
	add_child(block)
	_block_mat = _make_block_material(COLOR_BLOCK)


func _make_block_material(base: Color) -> ShaderMaterial:
	# 方块着色器：顶面更亮 + 菲涅尔微亮边缘（让轮廓从背景里“跳”出来）
	# + flash 通道（通关时闪一下，取代早期“把方块变绿/抬高”的糟糕做法）
	var sh := Shader.new()
	sh.code = """
shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;
uniform vec3 base_color : source_color = vec3(1.0, 0.6, 0.22);
uniform float flash = 0.0;
void fragment() {
	vec3 wn = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	float up = clamp(wn.y, 0.0, 1.0);
	vec3 c = base_color * mix(0.88, 1.12, up);
	float fres = pow(1.0 - clamp(dot(normalize(NORMAL), VIEW), 0.0, 1.0), 2.5);
	c += vec3(0.34, 0.40, 0.52) * fres * 0.28;
	ALBEDO = c;
	ROUGHNESS = 0.55;
	METALLIC = 0.0;
	EMISSION = (base_color * 0.8 + vec3(0.5)) * flash;
}
"""
	var mat := ShaderMaterial.new()
	mat.shader = sh
	mat.set_shader_parameter("base_color", base)
	mat.set_shader_parameter("flash", 0.0)
	return mat


func _position_block() -> void:
	# 通用 PolyCube 渲染：每个世界单元画一个 1x1x1 立方体（对任意形状/方向都成立）
	_free_children(block)
	for cell in state.world_cells():
		var m := _make_box(Vector3(1.0, 1.0, 1.0), _block_mat)
		m.position = Vector3(float(cell.x), float(cell.y) + 0.5, float(cell.z))
		block.add_child(m)


func _make_box(size: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	box.material = mat
	mi.mesh = box
	return mi


func _process(delta: float) -> void:
	# 目标格「呼吸」发光：既吸引注意，也让画面久看不呆板
	if low_effects or goal_tiles.is_empty():
		return
	_glow_t += delta
	var pulse: float = 0.5 + 0.42 * sin(_glow_t * 2.0)
	if _tile_mat_goal != null:
		_tile_mat_goal.set_shader_parameter("glow", 0.35 + 0.5 * pulse)
	for r in goal_rings:
		if not is_instance_valid(r):
			continue
		var m: ShaderMaterial = r.material_override
		if m != null:
			m.set_shader_parameter("energy", 0.85 + 0.9 * pulse)
		# 缓慢自转 + 轻微起伏：静止画面上的一点“活气”
		r.rotation.y = _glow_t * 0.6
		r.position.y = 0.012 + 0.02 * sin(_glow_t * 1.6)
	# 通关闪光：方块本体不变色、不位移，只是亮一下（替代早期“变绿/抬高”的做法）
	if _win_flash > 0.0:
		_win_flash = maxf(_win_flash - delta * 2.2, 0.0)
		if _block_mat != null:
			_block_mat.set_shader_parameter("flash", _win_flash)


func tile_count() -> int:
	# 实心瓦片数量。刻意用显式数组而不是「数 board_root 的子节点」：
	#   * 棋盘台上还会挂目标光圈等物体
	#   * Godot 会给同名兄弟节点自动改名（Tile → @MeshInstance3D@3），按名字数不可靠
	return tiles.size()


func goal_ring_count() -> int:
	return goal_rings.size()


func set_quality_tier(tier: int) -> void:
	# 由 main.gd 的自适应画质控制器调用（见 meta/render_quality.gd）
	_quality_tier = tier


func play_spawn() -> void:
	# 重生入位：方块从上方落下并回弹 + 落地挤压。
	# 坠落之后如果直接“啪”一下复位，玩家会怀疑自己是不是点错了按钮；
	# 落体动画把“方块重新回到了起点”这件事讲清楚，也顺手把节奏感给了回来。
	if block == null or not animate or state == null:
		return
	animating = true
	block.position.y = SPAWN_HEIGHT
	var tw := create_tween()
	tw.tween_property(block, "position:y", 0.0, SPAWN_TIME) \
		.set_trans(Tween.TRANS_BOUNCE).set_ease(Tween.EASE_OUT)
	tw.parallel().tween_method(_squash_curve, 0.0, 1.0, SPAWN_TIME + 0.18)
	tw.finished.connect(func() -> void:
		block.scale = Vector3.ONE
		animating = false)


func play_land_squash() -> void:
	# 每次落地的极小挤压：几乎零成本，但方块立刻“有重量”了
	if block == null or not animate:
		return
	var tw := create_tween()
	tw.tween_method(_squash_curve, 0.0, 1.0, 0.22)


func _squash_curve(u: float) -> void:
	# u=0 开始、u=1 结束：先压扁再弹回（sin 一整个周期，前半压后半弹）
	if block == null:
		return
	var k: float = sin(u * PI) * LAND_SQUASH
	block.scale = Vector3(1.0 + k * 0.5, 1.0 - k, 1.0 + k * 0.5)


func _free_children(node: Node) -> void:
	for c in node.get_children():
		node.remove_child(c)
		c.free()


func _free_all_children() -> void:
	for c in get_children():
		remove_child(c)
		c.free()
