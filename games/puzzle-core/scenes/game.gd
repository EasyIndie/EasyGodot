# game.gd — 视觉层 + 逻辑桥接（Game 节点）。
# 职责：加载关卡、渲染棋盘/方块、把输入转成 core 移动、播放翻滚/坠落动画、检测胜负/坠落。
# 原则：规则判断走 core（roll_delta / supports / is_goal），本层只做「渲染 + 动画 + 桥接」。
#   - 合法移动：方块绕「前下边」翻滚 90° → 播放翻滚动画。
#   - 踩空（越界 或 落在空洞上）：落点没有地面 → 翻滚后继续坠落 → 失败。
#     空洞 = 地面缺失，与越界同构；机关可动态把实心格变空洞（board.set_void），
#     之后调用 check_fall() 即会触发「踩空坠落」。
#   - animate=false 时全部同步执行（供 headless 测试确定性驱动，不依赖帧推进）。
extends Node3D

const VisualTheme = preload("res://meta/visual_theme.gd")
const BeveledBox = preload("res://meta/beveled_box.gd")

var theme_id := "mist"
var _colors: Dictionary = VisualTheme.palette("mist")

const Loader = preload("res://core/level_loader.gd")
const Core = preload("res://core/puzzle_core.gd")
const State = preload("res://core/puzzle_state.gd")
const Mech = preload("res://core/mechanisms.gd")
const MechState = preload("res://core/mech_state.gd")
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
const COLOR_TILE_A := Color("8faec5")   # 棋盘格（浅）
const COLOR_TILE_B := Color("7595b1")   # 棋盘格（深）
const COLOR_GOAL := Color("3da889")     # 目标格（会呼吸发光）
const COLOR_BLOCK := Color("efb853")    # 方块（暖橙）
const COLOR_GOAL_RING := Color("b4ffe3") # 目标“光圈”（嵌在瓦片表面）
# ── 机关配色（机关必须一眼可见，否则等于没做）──────────
const COLOR_SWITCH := Color(1.00, 0.78, 0.30)      # 开关（琥珀）
const COLOR_SWITCH_ON := Color(1.00, 0.95, 0.55)   # 开关被压住（更亮）
const COLOR_BRIDGE_ON := Color(0.30, 0.85, 0.92)   # 桥（开）
const COLOR_PORTAL_A := Color(0.72, 0.45, 1.00)    # 传送门 A（紫）
const COLOR_PORTAL_B := Color(0.35, 0.95, 0.85)    # 传送门 B（青）

# 落地回弹的挤压幅度：很小的数值就有明显的“重量感”，是性价比最高的一档手感反馈
const LAND_SQUASH := 0.16
const GHOST_ALPHA := 0.34   # 幽灵透明度：能看清走法，又不至于被当成实体方块
const SPAWN_HEIGHT := 7.0      # 重开时方块落下的起始高度
const SPAWN_TIME := 0.38       # 落下时长

var core = null          # puzzle_core 实例
var board = null         # Board 实例
var state = null         # PuzzleState 实例
var level_id: String = ""
var block: Node3D = null
var _block_pivot: Node3D = null   # 位于方块质心的支点（挤压绕它做，避免缩放导致平移）
var board_root: Node3D = null
var tiles: Array = []        # 全部实心瓦片
var goal_tiles: Array = []   # 目标格（呼吸发光）
var goal_rings: Array = []   # 目标光圈（随棋盘一起升降/旋转）
var _tile_mat_a: ShaderMaterial = null
var _tile_mat_b: ShaderMaterial = null
var _tile_mat_goal: ShaderMaterial = null
var _tile_mat_switch: ShaderMaterial = null
var _tile_mat_bridge_on: ShaderMaterial = null
var _tile_mat_bridge_off: ShaderMaterial = null
var _tile_mat_portal_a: ShaderMaterial = null
var _tile_mat_portal_b: ShaderMaterial = null
var _tile_mat_bridge_ghost: ShaderMaterial = null
var _block_mat: ShaderMaterial = null
var _glow_t: float = 0.0
var _win_flash: float = 0.0
var _quality_tier: int = 3
var won_flag: bool = false
var lost_flag: bool = false
var animating: bool = false
var animate: bool = true     # false = 同步（测试用）
var _stick_prev: Dictionary = {}   # 左摇杆各轴的上一次取值（边沿触发用）
var mech = null                    # 机关状态（MechState；无机关关卡为 null）
var _mech_tiles: Dictionary = {}   # {"x,z": [MeshInstance3D, ...]} 机关格上的瓦片（用于刷新外观）
var _bridge_ghosts: Dictionary = {} # {"x,z": MeshInstance3D} 桥关闭时的"幽灵框"
var low_effects: bool = false  # 低端 GPU / 排障：停掉逐帧材质更新
# ── 幽灵影子（「上次的走法」）──────────────────────────
# 它**不是**比赛用的对手：解谜游戏的成绩是**步数**，不是时间，而回放里没有记录
# 每一步之间的思考停顿，「跟你自己赛跑」在解谜里既不公平也没意义。
# 它真正解决的问题是：回到一个隔了很久的关卡，想不起来上次怎么走的
# —— 于是它把「上次的走法」连续滚一遍当记忆辅助（opt-in，默认关）。
var _ghost: Node3D = null          # 幽灵根节点（挂在质心的 pivot 上）
var _ghost_state = null            # 幽灵自己的状态（与玩家 state 完全独立）
var _ghost_start: Dictionary = {}  # 本关起点（重播时复位用）
var _player_rig: Node3D = null     # 玩家方块正在翻滚/坠落时承载单元网格的 rig
var _ghost_rig: Node3D = null      # 幽灵自己那份（两者绝不能混在一起，见 _rig_meshes）
var _ghost_epoch: int = 0          # 换关/关闭时自增，用来打断还在跑的播放协程
var _ghost_busy: bool = false
var _ghost_moves: int = 0          # 幽灵已经滚了几步（测试按它给帧分组，见 ghost_move_index）
var move_count: int = 0
var _tween: Tween = null
var _spawn_tween: Tween = null   # 入场下落动画（唯一允许被玩家输入打断的动画）


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
	# 记下本关起点：幽灵重播时要能复位（与玩家 state 各存一份，互不影响）
	_ghost_start = {
		"shape": state.shape,
		"orientation": state.orientation,
		"position": state.position,
	}
	level_id = board.id
	mech = MechState.new()   # 机关状态；无机关关卡就是一个空状态（判定路径完全一致）
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
	refresh_mechanisms()
	return true


func _plan_move(d: Vector3i) -> Dictionary:
	# 单步移动的完整几何信息（纯计算，不改状态）。
	# roll_delta 的 pivot 用「单元中心在整数格」的坐标；渲染把方块抬高 0.5 贴地，
	# 所以此处要 +0.5，支点才是方块真正的底棱。
	# 用机关层的步进结果作为唯一真相（含桥/闸门/传送/碎裂）：
	# 渲染层**不允许**自己再算一遍"能不能站" —— 两处判定迟早会不一致。
	var step = Core.apply_step(board, state, mech, d)
	var r: Dictionary = Moves.roll_delta(state.shape, state.orientation, d)
	if step == null:
		# 走不过去：仍然给一个"落点"用于播坠落动画（与旧行为一致）
		var bad_pos: Vector3i = state.position + r["delta"]
		return {
			"orientation": r["orientation"],
			"position": bad_pos,
			"pivot": Vector3(state.position) + r["pivot"] + Vector3(0.0, 0.5, 0.0),
			"from_cells": state.world_cells(),
			"to_cells": state.cells_at(r["orientation"], bad_pos),
			"supported": false,
			"blocked": true,
		}
	return {
		"orientation": r["orientation"],
		"position": step["state"].position,
		"pivot": Vector3(state.position) + r["pivot"] + Vector3(0.0, 0.5, 0.0),
		"from_cells": state.world_cells(),
		"to_cells": step["state"].world_cells(),
		"supported": not bool(step["fall"]),
		"step": step,
		"blocked": false,
	}


func try_move(d: Vector3i) -> bool:
	if won_flag or lost_flag or animating:
		return false
	var st: Dictionary = _plan_move(d)
	# 落点是否全部实心；否则坠落（棋盘边缘、空洞、以及机关造成的缺口，效果一致）
	var supported: bool = bool(st["supported"])
	if supported:
		var step: Dictionary = st["step"]
		state = step["state"]
		# 机关状态必须跟着方块一起前进（桥开合/碎裂都在这里面）
		mech = step["mech"]
		move_count += 1
		refresh_mechanisms()
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
	# 输入 → 移动方向（与 solver 的 right/left/forward/backward 约定一致）。
	# 三条路都要走通，否则「遥控器/手柄只能看不能玩」：
	#   1) 键盘：桌面与**电视遥控器**（Android TV 的方向键会被系统当按键上报）
	#   2) 手柄按键：部分遥控器/蓝牙手柄把方向键上报成 D-pad 按钮
	#   3) 左摇杆：需要**上升沿**（轴事件每帧都来，按阈值直接触发会连续移动好几步）
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
	elif event is InputEventJoypadButton and event.pressed:
		match event.button_index:
			JOY_BUTTON_DPAD_RIGHT:
				return Vector3i(1, 0, 0)
			JOY_BUTTON_DPAD_LEFT:
				return Vector3i(-1, 0, 0)
			JOY_BUTTON_DPAD_UP:
				return Vector3i(0, 0, -1)
			JOY_BUTTON_DPAD_DOWN:
				return Vector3i(0, 0, 1)
	elif event is InputEventJoypadMotion:
		return _stick_dir(event)
	return Vector3i.ZERO


const STICK_DEADZONE := 0.55   # 摇杆阈值：太低会误触，太高会“推了没反应”


func _stick_dir(event: InputEventJoypadMotion) -> Vector3i:
	# 只在**越过阈值的那一刻**产生一次移动（边沿触发）。
	# 直接按阈值判断的话，摇杆按住期间每帧的轴事件都会触发一次移动 —— 一推走好几格。
	if event.axis != JOY_AXIS_LEFT_X and event.axis != JOY_AXIS_LEFT_Y:
		return Vector3i.ZERO
	var prev: float = _stick_prev.get(event.axis, 0.0)
	_stick_prev[event.axis] = event.axis_value
	var was_on: bool = absf(prev) >= STICK_DEADZONE
	var is_on: bool = absf(event.axis_value) >= STICK_DEADZONE
	if is_on == was_on:
		return Vector3i.ZERO     # 状态没变（含“按住不放”）→ 不产生新移动
	if not is_on:
		return Vector3i.ZERO     # 回到中位
	var sign_now: float = signf(event.axis_value)
	if event.axis == JOY_AXIS_LEFT_X:
		return Vector3i(int(sign_now), 0, 0)
	return Vector3i(0, 0, int(sign_now))


# ── 动画 ────────────────────────────────────────────────

func _start_roll(d: Vector3i, st: Dictionary) -> void:
	# 绕「前下边」翻滚 90°。
	# 用「刚体」节点承载方块：单元位置改为相对质心，于是「绕支点旋转 + 整块平移」
	# 可以用同一个四元数统一表达（对任意形状都成立）：
	#   new_q = R · q，  new_pos = P + R · (pos − P)
	animating = true
	var supported: bool = bool(st["supported"])
	var cs: Vector3 = _cells_center(st["from_cells"])
	# 搬运单元到 rig：rig 的原点**就是质心**（与 _block_pivot 一致），
	# 所以这里**不能**再减一次质心 —— 单元位置本来就是相对质心的。
	# （早期单元位置是绝对格坐标，那时才需要 -= cs；改成 pivot 之后忘了同步这一句，
	#   结果方块在整个翻滚动画里被平移到棋盘外，落点却因为重建而看起来正常。）
	var rig := Node3D.new()
	rig.name = "RollRig"
	_player_rig = rig
	rig.position = cs   # 立刻摆到质心：tween 要下一帧才求值，不预设会闪一帧世界原点
	add_child(rig)
	for cube in _block_meshes().duplicate():
		_block_pivot.remove_child(cube)
		rig.add_child(cube)

	var q_step: Quaternion = _rot_quat(d)
	var pv: Vector3 = st["pivot"]
	_tween = _roll_motion(rig, cs, pv, q_step, ROLL_TIME)
	if not supported:
		var to_cells: Array = st["to_cells"]
		_append_fall(rig, _cells_center(to_cells), to_cells, q_step, q_step.get_axis(), FALL_EXTRA_SPIN)
	_tween.finished.connect(_on_anim_finished.bind(rig, supported))


func _rot_quat(d: Vector3i) -> Quaternion:
	# 一步翻滚对应的 90° 旋转（Moves.roll_rotation 返回的是旋转矩阵的三个**基向量列**，
	# 所以要用 Basis(col_x, col_y, col_z) 这个三参构造）
	var m: Array = Moves.roll_rotation(d)
	return Basis(Vector3(m[0]), Vector3(m[1]), Vector3(m[2])).get_rotation_quaternion()


func _roll_motion(rig: Node3D, cs: Vector3, pivot: Vector3, q_step: Quaternion, dur: float) -> Tween:
	# 「绕前下边翻滚 90°」的**唯一**运动模型：new_q = R·q，new_pos = P + R·(cs − P)。
	# 玩家方块、幽灵影子都走这一个函数 —— 幽灵如果用第二套动画，两者迟早会不一致，
	# 而「同一动作有两种表现」正是这个项目反复踩过的坑。
	# rig 的原点必须是质心（cs），这样「绕支点转」与「整块平移」是同一个四元数。
	var t := create_tween()
	t.tween_method(
		func(u: float) -> void:
			var q: Quaternion = Quaternion.IDENTITY.slerp(q_step, u * u)  # 角速度递增，模拟重力力矩
			rig.quaternion = q
			rig.position = pivot + q * (cs - pivot),
		0.0, 1.0, dur)
	return t


## 机关扩展点：棋盘改变（如 set_void）后调用。方块脚下已无地面 → 触发「踩空坠落」。
func check_fall() -> bool:
	if won_flag or lost_flag or animating:
		return false
	var cells: Array = state.world_cells()
	if Mech.supports(board, board.mechanisms, mech, cells):
		return false
	if not animate:
		lost_flag = true
		fell.emit()
		return true
	animating = true
	var c: Vector3 = _cells_center(cells)
	# 同样用刚体节点承载方块（rig 原点 = 质心，单元位置本来就是相对质心的）
	var rig := Node3D.new()
	rig.name = "FallRig"
	_player_rig = rig
	rig.position = c    # 同上：避免第一帧闪现在世界原点
	add_child(rig)
	for cube in _block_meshes().duplicate():
		_block_pivot.remove_child(cube)
		rig.add_child(cube)
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
	_player_rig = null
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
	# 落上去之后地面可能已被机关撤掉（例如自己把脚下的桥关掉）→ 这一帧还不掉，
	# 等落地动画演完再踩空，玩家才看得懂"是我刚才那一下把自己害了"。
	if not Mech.supports(board, board.mechanisms, mech, state.world_cells()):
		check_fall()
		return
	# 刻意**不在每次移动后做挤压**：方块是刚体几何，每一步都“果冻”一下
	# 读起来像渲染故障而不是重量感（真实反馈：方块移动动画很奇怪）。
	# 挤压只留给「坠落重生落地」那一次 —— 那时它是“冲击”，语义成立。
	moved.emit()
	if board.is_goal(state.world_cells()):
		won_flag = true
		_win_flash = 1.0   # 通关闪光（方块不位移、不变色）
		won.emit()


func _kill_tween() -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = null
	if _spawn_tween != null and _spawn_tween.is_valid():
		_spawn_tween.kill()
	_spawn_tween = null


func snap_spawn() -> bool:
	# 立即结束**入场下落**动画并补到终态，返回是否真的打断了。
	#
	# 为什么需要：入场动画有 1 秒多，如果这段时间玩家的输入只能排队等，
	# 每次进关卡的第一下都会"慢半拍"。入场下落纯粹是观赏性的（方块从上方落下），
	# 逻辑状态（state/board）在 play_spawn 之前就已经确定了，
	# 所以这里只补视觉，不会造成"逻辑与画面不一致"。
	# **只允许打断入场**：滚动动画被打断会让方块停在半路，没法收拾。
	if _spawn_tween == null or not _spawn_tween.is_valid():
		return false
	_spawn_tween.kill()
	_spawn_tween = null
	if block != null:
		block.position.y = 0.0
	if _block_pivot != null:
		_block_pivot.scale = Vector3.ONE
	animating = false
	return true


# ── 渲染 ────────────────────────────────────────────────

func _build_board() -> void:
	tiles.clear()
	goal_tiles.clear()
	goal_rings.clear()
	# 机关查找表也必须清空：它们存的是**节点引用**，而上一次的节点在
	# _free_all_children() 里已经被 free() 掉了。留着就是一堆野引用 ——
	# refresh_mechanisms() 一碰就 "Trying to cast a freed object"，
	# 而且每次重开都会往里累加（2→4→6→8…）。玩家看到的就是「机关关坠落之后
	# 按 R 重开不对/关卡坏了」（真实反馈：第 13 关坠落后无法按 R 重开）。
	# 教训：**持有节点的容器，必须和节点在同一次生命周期里被清空**，
	# 只清一半（tiles/goal_tiles 清了、机关表没清）比不清更难发现。
	_mech_tiles.clear()
	_bridge_ghosts.clear()
	_tile_mat_a = _make_tile_material(_colors["tile_a"])
	_tile_mat_b = _make_tile_material(_colors["tile_b"])
	_tile_mat_goal = _make_tile_material(_colors["goal"], 0.18)
	_tile_mat_switch = _make_tile_material(_colors["switch"], 0.12)
	_tile_mat_bridge_on = _make_tile_material(_colors["bridge"], 0.10)
	_tile_mat_bridge_off = _make_tile_material(Color(_colors["bridge"].r, _colors["bridge"].g, _colors["bridge"].b, 0.35), 0.0)
	_tile_mat_portal_a = _make_tile_material(_colors["portal_a"], 0.35)
	_tile_mat_portal_b = _make_tile_material(_colors["portal_b"], 0.35)
	_tile_mat_bridge_ghost = _make_tile_material(Color(_colors["bridge"].r, _colors["bridge"].g, _colors["bridge"].b, 0.22), 0.0)
	board_root = Node3D.new()
	board_root.name = "Board"
	add_child(board_root)
	var roles: Dictionary = Mech.roles_of(board.mechanisms)
	for x in range(board.grid_x):
		for z in range(board.grid_z):
			var v2 := Vector2i(x, z)
			var role: String = str(roles.get("%d,%d" % [x, z], ""))
			if role == "bridge":
				# 桥：关闭时画一个"幽灵框"——**必须让玩家知道这里将来会有路**，
				# 完全隐藏会让人以为那只是个普通空洞
				var ghost := _make_box(Vector3(0.94, 0.02, 0.94), _tile_mat_bridge_ghost)
				ghost.position = Vector3(float(x), -0.19, float(z))
				ghost.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
				board_root.add_child(ghost)
				_bridge_ghosts["%d,%d" % [x, z]] = ghost
			if board.is_void(Vector3i(x, 0, z)) and role != "bridge":
				# 空洞 = 地面缺失：直接不画地面（透出背景），就是一块“空的洞”。
				# 例外：桥是"补地类"机关，它本身就架在空洞上（见 mechanisms.gd 的说明）。
				continue
			var is_goal: bool = board.goal.has(v2)
			var mat: ShaderMaterial = _tile_mat_goal if is_goal else (
				_tile_mat_a if (x + z) % 2 == 0 else _tile_mat_b)
			match role:
				"switch":
					mat = _tile_mat_switch
				"bridge":
					mat = _tile_mat_bridge_on if _is_bridge_open(x, z) else _tile_mat_bridge_off
				"portal":
					mat = _tile_mat_portal_a if _portal_group(x, z) == 0 else _tile_mat_portal_b
			var m := _make_box(Vector3(0.94, 0.2, 0.94), mat)
			m.position = Vector3(float(x), -0.1, float(z))
			# 瓦片不投影，但接收方块的影子 → 立体感
			m.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			board_root.add_child(m)
			# tiles 只记**静态地形**的瓦片：机关"补出来的地面"（架在空洞上的桥/碎裂砖）
			# 单独放在 _mech_tiles 里 —— 否则 tile_count() 会把它们算进地形，
			# "渲染出来的地面 == 关卡定义的地面" 这条断言就不再成立了。
			if not board.is_void(Vector3i(x, 0, z)):
				tiles.append(m)
			if role != "":
				var key := "%d,%d" % [x, z]
				if not _mech_tiles.has(key):
					_mech_tiles[key] = []
				_mech_tiles[key].append(m)
			if is_goal:
				goal_tiles.append(m)
				board_root.add_child(_make_goal_ring(Vector3(float(x), 0.0, float(z))))


func _is_bridge_open(x: int, z: int) -> bool:
	# 桥的开合状态（渲染用）
	for d in board.mechanisms:
		if str(d["kind"]) != "bridge":
			continue
		for t in d["tiles"]:
			if t.x == x and t.y == z:
				return mech != null and mech.flag(str(d["id"]))
	return false


func _is_switch_on(id: String) -> bool:
	return mech != null and mech.flag(id)


func _portal_group(x: int, z: int) -> int:
	# 同一对传送门用同一个序号 → 同色（配对关系必须能一眼看出来）
	var n: int = 0
	for d in board.mechanisms:
		if str(d["kind"]) != "portal":
			continue
		for t in d["links"]:
			if t.x == x and t.y == z:
				return n
		n += 1
	return 0


func refresh_mechanisms() -> void:
	# 机关外观 = mech 状态的**函数**（不是"播放一次动画就完事"）。
	# 理由与庆祝动画那次踩的坑完全一样：持久状态与一次性动画混在一起一定会错。
	# 换关、开关变化、碎裂之后都调用它。
	if board == null or mech == null:
		return
	for key in _mech_tiles.keys():
		var parts: Array = str(key).split(",")
		var x: int = int(parts[0])
		var z: int = int(parts[1])
		var role: String = str(Mech.roles_of(board.mechanisms).get(key, ""))
		for mi in _mech_tiles[key]:
			# 跳过已释放的节点：刷新外观属于「尽量做对」的事，
			# 单个坏引用不该把整轮刷新打断（那会让新瓦片停在旧外观上，
			# 而玩家看到的是“关卡坏了”）。真正的根因已修（_build_board 清空本表），
			# 这里是第二层防护。
			if not is_instance_valid(mi):
				continue
			var m := mi as MeshInstance3D
			if m == null:
				continue
			match role:
				"switch":
					var on: bool = false
					for d in board.mechanisms:
						if str(d["kind"]) != "switch":
							continue
						for t in d["tiles"]:
							if t.x == x and t.y == z:
								on = _is_switch_on(str(d["target"]))
					m.material_override = _tile_mat_switch
					m.position.y = -0.16 if on else -0.10
				"bridge":
					var open: bool = _is_bridge_open(x, z)
					m.visible = open
					m.material_override = _tile_mat_bridge_on if open else _tile_mat_bridge_off
				"portal":
					m.material_override = _tile_mat_portal_a if _portal_group(x, z) == 0 else _tile_mat_portal_b
	# 桥的幽灵框：桥开着时收起（真瓦片已经在那个位置）
	for key in _bridge_ghosts.keys():
		var parts: Array = str(key).split(",")
		if not is_instance_valid(_bridge_ghosts[key]):
			continue
		var g := _bridge_ghosts[key] as MeshInstance3D
		if g != null:
			g.visible = not _is_bridge_open(int(parts[0]), int(parts[1]))


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
uniform float top_boost = 0.025;
uniform float surface_roughness = 0.75;
uniform float surface_metallic = 0.0;
uniform float edge_dark = 0.12;
uniform float glow : hint_range(0.0, 2.0) = 0.0;
void fragment() {
	vec3 wn = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	float up = clamp(wn.y, 0.0, 1.0);
	vec3 c = base_color * mix(1.0 - edge_dark, 1.0 + top_boost, up);
	vec2 e = min(UV, vec2(1.0) - UV);
	float rim = smoothstep(0.0, 0.09, min(e.x, e.y));
	c *= mix(0.95, 1.0, rim);
	ALBEDO = c;
	ROUGHNESS = surface_roughness;
	METALLIC = surface_metallic;
	EMISSION = base_color * glow;
}
"""
	var mat := ShaderMaterial.new()
	mat.shader = sh
	mat.set_shader_parameter("base_color", base)
	mat.set_shader_parameter("glow", glow * 0.35)
	mat.set_shader_parameter("surface_roughness", _colors["roughness"])
	mat.set_shader_parameter("surface_metallic", _colors["metallic"])
	return mat


func _make_goal_ring(pos: Vector3) -> MeshInstance3D:
	# 目标标记：嵌在瓦片表面的一圈荧光（比“整格变绿”更清楚，也不会被方块完全盖住）
	var t := TorusMesh.new()
	t.inner_radius = 0.29
	t.outer_radius = 0.35
	t.rings = 4
	t.ring_segments = 6
	var sh := Shader.new()
	sh.code = """
shader_type spatial;
render_mode unshaded, cull_disabled;
uniform vec3 ring_color : source_color = vec3(0.35, 1.0, 0.70);
uniform float energy = 1.0;
void fragment() {
	ALBEDO = ring_color * energy;
	EMISSION = vec3(0.0);
}
"""
	var mat := ShaderMaterial.new()
	mat.shader = sh
	mat.set_shader_parameter("ring_color", _colors["ring"])
	mat.set_shader_parameter("energy", 1.0)
	var mi := MeshInstance3D.new()
	mi.name = "GoalRing"
	mi.mesh = t
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.position = pos
	mi.rotation_degrees = Vector3.ZERO   # 平铺在瓦片上
	goal_rings.append(mi)
	return mi


func _build_block() -> void:
	block = Node3D.new()
	block.name = "Block"
	add_child(block)
	# 单元的父节点放在**质心**，而不是世界原点。
	# 这样对 pivot 做 scale（落地挤压）才是「以自身为中心」缩放；
	# 直接缩放 block 会把子节点用世界格坐标写下的位置一起缩放 ——
	# 结果就是方块每走一步都往坐标系深处“窜”一下（格子越远窜得越多）。
	_block_pivot = Node3D.new()
	_block_pivot.name = "BlockPivot"
	block.add_child(_block_pivot)
	_block_mat = _make_block_material(_colors["block"])


func ghost_visible() -> bool:
	return _ghost != null and _ghost.visible


func set_ghost_enabled(on: bool) -> void:
	# 开关幽灵结构（不涉及播放）。关掉时立刻打断正在播放的协程。
	_ghost_epoch += 1
	_ghost_busy = false
	_ghost_rig = null
	if on:
		if _ghost == null:
			_build_ghost()
		_ghost.visible = true
		_reset_ghost()
	elif _ghost != null:
		_ghost.visible = false


func _build_ghost() -> void:
	# 幽灵的渲染刻意与方块**不同**：半透明 + 不投影。
	# 「影子」的语言必须一眼可辨，否则玩家会以为棋盘上多了个实体方块。
	_ghost = Node3D.new()
	_ghost.name = "Ghost"
	add_child(_ghost)


func _ghost_material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	var c: Color = _colors["block"]
	mat.albedo_color = Color(c.r, c.g, c.b, GHOST_ALPHA)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	return mat


func _reset_ghost() -> void:
	# 幽灵回到本关起点姿态（只在有起点信息时）
	if _ghost == null or _ghost_start.is_empty():
		return
	_ghost_state = State.new(_ghost_start["shape"], int(_ghost_start["orientation"]), _ghost_start["position"])
	_ghost_moves = 0
	_position_ghost()


func _position_ghost() -> void:
	# 与 _position_block 同一套「单元相对质心」规则，只是材质不同
	if _ghost == null or _ghost_state == null:
		return
	# 先 remove_child 再 queue_free：queue_free 是**延迟**的，旧网格会在本帧内继续
	# 作为 _ghost 的子节点存在，下一句 get_children() 就会把上一姿态的旧网格也搬进 rig
	# （画面上表现为幽灵身上多出一撮残留方块）。
	for c in _ghost.get_children():
		_ghost.remove_child(c)
		c.queue_free()
	var cells: Array = _ghost_state.world_cells()
	var cs: Vector3 = _cells_center(cells)
	_ghost.position = cs
	var mat: StandardMaterial3D = _ghost_material()
	for cell in cells:
		var m := _make_box(Vector3(1.0, 1.0, 1.0), mat)
		m.position = Vector3(float(cell.x), float(cell.y) + 0.5, float(cell.z)) - cs
		m.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_ghost.add_child(m)


func ghost_mesh_count() -> int:
	return _ghost.get_child_count() if _ghost != null else 0


func ghost_center() -> Vector3:
	# 幽灵**当前画在哪里**的质心（世界坐标）；无幽灵时返回 INF。
	# 翻滚期间承载网格的是 rig（此时 _ghost 自己被隐藏），所以必须优先读 rig ——
	# 只读 _ghost.position 会拿到「上一次落位」的陈旧坐标（第一版就是这么错的，
	# 表现为帧间位移断崖式跳变，看起来像瞬移）。
	if _ghost == null or _ghost_state == null:
		return Vector3.INF
	if _ghost_rig != null:
		return _ghost_rig.position
	return _ghost.position


func ghost_cells() -> Array:
	return _ghost_state.world_cells() if _ghost_state != null else []


func ghost_at_goal() -> bool:
	# 幽灵是否停在目标格上（验证「回放数据确实能解开这一关」）
	if board == null or _ghost_state == null:
		return false
	return board.is_goal(_ghost_state.world_cells())


func ghost_busy() -> bool:
	return _ghost_busy


func ghost_move_index() -> int:
	# 幽灵已推进的步数。测试靠它把逐帧采样**按步分组**，从而断言「每一步都有中间帧」
	# —— 这是「有没有真在演动画」的可靠判据（比按 dt 算速度稳，不受长帧影响）
	return _ghost_moves


func play_ghost(moves: Array) -> void:
	# 把「上次的走法」按固定节奏连续滚一遍（记忆辅助，不是比赛）。
	# 关键约束：**绝不允许碰到玩家的任何状态** —— 它只动自己的 _ghost_state。
	if _ghost == null or moves.is_empty() or _ghost_state == null:
		return
	_ghost_epoch += 1
	var epoch: int = _ghost_epoch
	_ghost_busy = true
	_reset_ghost()
	if not animate:
		# 测试/低开销模式：直接摆到终点，不播动画
		for label in moves:
			_ghost_advance(Moves.direction_from_label(str(label)))
		_position_ghost()
		_ghost_busy = false
		return
	for label in moves:
		if epoch != _ghost_epoch or _ghost == null or _ghost_state == null:
			_ghost_busy = false
			return
		var tw: Tween = _ghost_roll(Moves.direction_from_label(str(label)))
		if tw != null:
			await tw.finished
	_ghost_busy = false


func _ghost_advance(d: Vector3i) -> void:
	# 幽灵的纯状态推进：不碰玩家状态、不碰棋盘、不碰计数
	var r: Dictionary = Moves.roll_delta(_ghost_state.shape, _ghost_state.orientation, d)
	_ghost_state = State.new(_ghost_state.shape, int(r["orientation"]), _ghost_state.position + r["delta"])
	_ghost_moves += 1


func _ghost_roll(d: Vector3i) -> Tween:
	# 幽灵走一步：运动模型与玩家方块**共用** _roll_motion()
	if _ghost == null or _ghost_state == null:
		return null
	var r: Dictionary = Moves.roll_delta(_ghost_state.shape, _ghost_state.orientation, d)
	var from_cells: Array = _ghost_state.world_cells()
	var from_center: Vector3 = _cells_center(from_cells)
	var q_step: Quaternion = _rot_quat(d)
	var pivot: Vector3 = Vector3(_ghost_state.position) + r["pivot"] + Vector3(0.0, 0.5, 0.0)
	_ghost_state = State.new(_ghost_state.shape, int(r["orientation"]), _ghost_state.position + r["delta"])
	_ghost_moves += 1
	# 与玩家方块一样：把单元搬进一个「原点=质心」的 rig，播完再重建
	var rig := Node3D.new()
	rig.name = "GhostRig"
	rig.position = from_center
	add_child(rig)
	_ghost_rig = rig
	for c in _ghost.get_children():
		_ghost.remove_child(c)
		rig.add_child(c)
	_ghost.visible = false
	var tw: Tween = _roll_motion(rig, from_center, pivot, q_step, ROLL_TIME)
	tw.finished.connect(func() -> void:
		_ghost_rig = null
		rig.queue_free()
		if _ghost != null:
			_ghost.visible = true
			_position_ghost())
	return tw


func _block_meshes() -> Array:
	# 承载方块形态的单元网格（挂在质心 pivot 下）
	return _block_pivot.get_children() if _block_pivot != null else []


func _make_block_material(base: Color) -> ShaderMaterial:
	# 方块着色器：顶面更亮 + 菲涅尔微亮边缘（让轮廓从背景里“跳”出来）
	# + flash 通道（通关时闪一下，取代早期“把方块变绿/抬高”的糟糕做法）
	var sh := Shader.new()
	sh.code = """
shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;
uniform vec3 base_color : source_color = vec3(1.0, 0.6, 0.22);
uniform float flash = 0.0;
uniform float surface_roughness = 0.5;
uniform float surface_metallic = 0.1;
void fragment() {
	vec3 wn = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	float up = clamp(wn.y, 0.0, 1.0);
	vec3 c = base_color * mix(0.82, 1.02, up);
	float fres = pow(1.0 - clamp(dot(normalize(NORMAL), VIEW), 0.0, 1.0), 2.5);
	c += vec3(0.34, 0.40, 0.52) * fres * 0.035;
	ALBEDO = c;
	ROUGHNESS = surface_roughness;
	METALLIC = surface_metallic;
	EMISSION = (base_color * 0.8 + vec3(0.5)) * flash;
}
"""
	var mat := ShaderMaterial.new()
	mat.shader = sh
	mat.set_shader_parameter("base_color", base)
	mat.set_shader_parameter("flash", 0.0)
	mat.set_shader_parameter("surface_roughness", _colors["block_roughness"])
	mat.set_shader_parameter("surface_metallic", _colors["block_metallic"])
	return mat


func _position_block() -> void:
	# 通用 PolyCube 渲染：每个世界单元画一个 1x1x1 立方体（对任意形状/方向都成立）。
	# 单元位置**相对质心**，pivot 摆在质心 —— 于是 pivot.scale 等价于绕自身中心的挤压。
	_free_children(_block_pivot)
	var cells: Array = state.world_cells()
	var cs: Vector3 = _cells_center(cells)
	_block_pivot.position = cs
	_block_pivot.scale = Vector3.ONE   # 清掉上一段挤压可能残留的缩放
	for cell in cells:
		var m := _make_box(Vector3(1.0, 1.0, 1.0), _block_mat)
		m.position = Vector3(float(cell.x), float(cell.y) + 0.5, float(cell.z)) - cs
		_block_pivot.add_child(m)


func _make_box(size: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = BeveledBox.mesh(size, 0.055 if size.y >= 0.9 else 0.025)
	mi.material_override = mat
	return mi


func _process(delta: float) -> void:
	# 通关闪光要先处理：它不能因为低画质档位（low_effects）或空目标格而永远不衰减，
	# 否则方块会一直亮着（早期实现把它放在下面的 early-return 之后）。
	if _win_flash > 0.0:
		_win_flash = maxf(_win_flash - delta * 2.2, 0.0)
		if _block_mat != null:
			_block_mat.set_shader_parameter("flash", _win_flash)
	# 目标格「呼吸」发光：既吸引注意，也让画面久看不呆板
	if low_effects or goal_tiles.is_empty():
		return
	_glow_t += delta
	var pulse: float = 0.5 + 0.42 * sin(_glow_t * 2.0)
	if _tile_mat_goal != null:
		_tile_mat_goal.set_shader_parameter("glow", 0.035 + 0.045 * pulse)
	for r in goal_rings:
		if not is_instance_valid(r):
			continue
		var m: ShaderMaterial = r.material_override
		if m != null:
			m.set_shader_parameter("energy", 0.85 + 0.25 * pulse)
		# 缓慢自转 + 轻微起伏：静止画面上的一点“活气”
		r.rotation.y = 0.0
		r.position.y = 0.012 + 0.02 * sin(_glow_t * 1.6)

func block_mesh_count() -> int:
	# 方块渲染出来的单元数（挂在质心 pivot 下，不能直接数 block 的子节点）
	return _block_meshes().size() + _rig_meshes().size()


func block_mesh_centers() -> Array:
	# 方块单元网格的**全局**坐标（供测试断言“渲染出来的位置”与状态一致）。
	# 有了它才能抓住“缩放导致平移”这类只在画面上看得到的 bug：
	# 状态是对的，但画出来的方块偏了，纯逻辑测试完全测不到。
	var out: Array = []
	for m in _block_meshes() + _rig_meshes():
		out.append(m.global_position)
	out.sort_custom(func(a, b) -> bool:
		if a.x != b.x: return a.x < b.x
		if a.z != b.z: return a.z < b.z
		return a.y < b.y)
	return out


func _rig_meshes() -> Array:
	# 正在翻滚/坠落时，玩家方块的单元网格临时挂在 rig 下。
	#
	# 这里**必须**用显式引用，不能用「名字以 Rig 结尾」去 get_children() 里找：
	# 幽灵的节点叫 GhostRig，同样以 Rig 结尾 —— 于是「玩家方块画在哪里」会混进幽灵的
	# 网格，读到的是两者的混合位置。这是真踩过的坑（幽灵动画测试的断言全乱）。
	# 与 tile_count() 的注释同一条教训：Godot 的节点命名/改名不可依赖。
	if not is_instance_valid(_player_rig):
		return []
	return _player_rig.get_children()


func mech_tile_count() -> int:
	# 机关格上的瓦片总数（供测试断言"机关确实被画出来了"）
	var n: int = 0
	for k in _mech_tiles.keys():
		n += (_mech_tiles[k] as Array).size()
	return n


func bridge_ghost_count() -> int:
	return _bridge_ghosts.size()


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
	# 节奏：自由落体 → 触地挤压 → 极小的象征性回弹。
	# 早期用的是 TRANS_BOUNCE，弹得像橡胶球；方块是刚体，下落应该是加速的（重力曲线），
	# 触地后只弹一点点就停 —— 重量感来自“停得住”，而不是“弹得高”。
	var tw := create_tween()
	_spawn_tween = tw
	tw.tween_property(block, "position:y", 0.0, SPAWN_TIME) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tw.tween_method(_squash_curve, 0.0, 1.0, 0.24)                       # 触地这一瞬间
	tw.parallel().tween_property(block, "position:y", 0.10, 0.08).set_trans(Tween.TRANS_SINE)
	tw.tween_property(block, "position:y", 0.0, 0.10).set_trans(Tween.TRANS_SINE)
	tw.finished.connect(func() -> void:
		_spawn_tween = null
		if _block_pivot != null:
			_block_pivot.scale = Vector3.ONE
		animating = false)


func play_land_squash() -> void:
	# 落地挤压。只用于「重生落地」这类真正的冲击时刻（见 _finish_move 的说明），
	# 缩放作用在质心 pivot 上，所以方块不会因为缩放而平移。
	if _block_pivot == null or not animate:
		return
	var tw := create_tween()
	tw.tween_method(_squash_curve, 0.0, 1.0, 0.22)


func _squash_curve(u: float) -> void:
	# u=0 开始、u=1 结束：先压扁再弹回（sin 一整个周期，前半压后半弹）
	if _block_pivot == null:
		return
	var k: float = sin(u * PI) * LAND_SQUASH
	_block_pivot.scale = Vector3(1.0 + k * 0.5, 1.0 - k, 1.0 + k * 0.5)


func _free_children(node: Node) -> void:
	for c in node.get_children():
		node.remove_child(c)
		c.free()


func _free_all_children() -> void:
	for c in get_children():
		remove_child(c)
		c.free()


func set_visual_theme(id: String) -> void:
	theme_id = VisualTheme.valid(id)
	_colors = VisualTheme.palette(theme_id)
	var bindings := [[_tile_mat_a, "tile_a"], [_tile_mat_b, "tile_b"], [_tile_mat_goal, "goal"],
		[_tile_mat_switch, "switch"], [_tile_mat_bridge_on, "bridge"], [_tile_mat_bridge_off, "bridge"],
		[_tile_mat_bridge_ghost, "bridge"], [_tile_mat_portal_a, "portal_a"], [_tile_mat_portal_b, "portal_b"], [_block_mat, "block"]]
	for entry in bindings:
		if entry[0] != null:
			entry[0].set_shader_parameter("base_color", _colors[entry[1]])
			entry[0].set_shader_parameter("surface_roughness", _colors["block_roughness" if entry[1] == "block" else "roughness"])
			entry[0].set_shader_parameter("surface_metallic", _colors["block_metallic" if entry[1] == "block" else "metallic"])
	for ring in goal_rings:
		ring.material_override.set_shader_parameter("ring_color", _colors["ring"])
	for root_node in [_ghost, _ghost_rig]:
		if root_node != null:
			for child in root_node.get_children():
				if child is MeshInstance3D:
					child.material_override = _ghost_material()
