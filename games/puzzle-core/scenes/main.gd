# main.gd — 主场景：摄像机 + 光照 + 环境 + Game + HUD + 关卡管理 + 选关 + 回放 + 输入桥接。
extends Node3D

const Game = preload("res://scenes/game.gd")
const Moves = preload("res://core/moves.gd")
const Progress = preload("res://meta/progress.gd")
const LevelSelect = preload("res://meta/level_select.gd")

var game: Node3D = null
var cam: Camera3D = null
var light: DirectionalLight3D = null
var levels: Array = []          # 关卡路径列表（res://...）
var entries: Array = []         # 关卡元数据（与 levels 同序）：{key, path, shape, optimal, difficulty}
var current_index: int = -1
var progress = null             # 玩家进度（已完成 / 最佳步数 / 最佳回放）
var level_select = null         # 选关界面
var _run_moves: Array = []      # 本局已走的方向标签序列（用于 Replay）
var _replaying: bool = false
var replay_label: Label
var hud_layer: CanvasLayer

# HUD 节点
var level_label: Label
var moves_label: Label
var win_label: Label
var fail_label: Label
var help_label: Label
var best_label: Label
var progress_bar: ProgressBar

const LIGHT_ENERGY := 1.15  # 主光基础亮度

# 关卡切换过渡（棋盘下沉 + 暗幕，衔接自然）
const FADE_TIME := 0.4      # 暗幕淡入/淡出时长（秒）
const SLIDE_IN := 4.0       # 过渡时棋盘升降的位移
var fade: ColorRect
var transition_label: Label
var transitioning: bool = false


func _ready() -> void:
	_setup_camera()
	_setup_light()
	_setup_environment()
	_setup_backdrop()
	_setup_hud()
	_setup_transition()
	progress = Progress.new()
	levels = _scan_levels()
	_setup_level_select()
	game = Game.new()
	game.name = "Game"
	add_child(game)
	game.moved.connect(_on_moved)
	game.won.connect(_on_won)
	game.fell.connect(_on_fell)
	_load_level(0, false)


func _scan_levels() -> Array:
	# 自动扫描 levels/ 下所有 .json，排序后作为关卡列表；同时读取关卡元数据
	var out: Array = []
	var dir := DirAccess.open("res://levels")
	if dir != null:
		dir.list_dir_begin()
		var f: String = dir.get_next()
		while f != "":
			if f.ends_with(".json"):
				out.append("res://levels/" + f)
			f = dir.get_next()
		dir.list_dir_end()
	out.sort()
	entries.clear()
	for i in range(out.size()):
		entries.append(_entry_for(i, out[i]))
	return out


func _entry_for(index: int, path: String) -> Dictionary:
	# 关卡 key 约定 = 文件名去扩展名（与存档键一致，且无需完整加载关卡）
	var e: Dictionary = {
		"index": index, "path": path, "key": path.get_file().get_basename(),
		"shape": "domino", "optimal": -1, "difficulty": "",
	}
	var d: Dictionary = _read_json(path)
	if not d.is_empty():
		e["shape"] = str(d.get("start", {}).get("shape", "domino"))
		e["optimal"] = int(d.get("optimal_moves", -1))
		e["difficulty"] = str(d.get("difficulty", ""))
	return e


func _read_json(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var txt := f.get_as_text()
	f.close()
	var j := JSON.new()
	if j.parse(txt) != OK or not (j.data is Dictionary):
		return {}
	return j.data


func _level_key(index: int) -> String:
	if index < 0 or index >= entries.size():
		return ""
	return str(entries[index]["key"])


func _level_keys() -> Array:
	var out: Array = []
	for e in entries:
		out.append(str(e["key"]))
	return out


func _load_level(index: int, animated: bool = true) -> void:
	if levels.is_empty():
		return
	if animated:
		_transition_to(index)
	else:
		_do_load(index)


func _do_load(index: int) -> void:
	current_index = clampi(index, 0, levels.size() - 1)
	var ok: bool = game.load_level(levels[current_index])
	if ok:
		_run_moves.clear()
		win_label.visible = false
		fail_label.visible = false
		replay_label.visible = false
		_frame_camera()
		_update_hud()


## 换关：棋盘下沉 + 暗幕淡入（“关卡合拢”）→ 暗幕下换关 → 新棋盘降入 + 淡出
func _transition_to(index: int) -> void:
	if transitioning or levels.is_empty():
		return
	if level_select != null and level_select.is_open():
		return
	index = clampi(index, 0, levels.size() - 1)
	transitioning = true
	win_label.visible = false
	fail_label.visible = false
	transition_label.modulate.a = 0.0
	transition_label.text = ""
	# 1) 棋盘下沉 + 暗幕淡入
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(fade, "color:a", 1.0, FADE_TIME).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	_slide_scene(tw, -SLIDE_IN)
	await tw.finished
	# 2) 暗幕遮挡下完成换关
	_do_load(index)
	_set_scene_offset(SLIDE_IN)
	transition_label.text = "关卡 %d / %d" % [index + 1, levels.size()]
	transition_label.modulate.a = 1.0
	await get_tree().create_timer(0.3).timeout
	# 3) 新棋盘降入 + 暗幕淡出
	var tw2 := create_tween()
	tw2.set_parallel(true)
	tw2.tween_property(fade, "color:a", 0.0, FADE_TIME + 0.12).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw2.tween_property(transition_label, "modulate:a", 0.0, FADE_TIME + 0.12)
	_slide_scene(tw2, 0.0)
	await tw2.finished
	transition_label.text = ""
	transitioning = false


func _set_scene_offset(y: float) -> void:
	if game == null:
		return
	if game.board_root != null:
		game.board_root.position.y = y
	if game.block != null:
		game.block.position.y = y


func _slide_scene(tw: Tween, target_y: float) -> void:
	# 把「棋盘 + 方块」的升降排到指定 tween 上
	for node in [game.board_root, game.block]:
		if node != null:
			tw.tween_property(node, "position:y", target_y, FADE_TIME) \
				.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN_OUT)


func _setup_transition() -> void:
	var layer := CanvasLayer.new()
	layer.name = "Transition"
	layer.layer = 10  # 盖在 HUD 之上
	add_child(layer)
	fade = ColorRect.new()
	fade.color = Color(0.04, 0.05, 0.09, 0.0)
	fade.set_anchors_preset(Control.PRESET_FULL_RECT)
	fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(fade)
	transition_label = Label.new()
	transition_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	transition_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	transition_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	transition_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	transition_label.modulate = Color(1, 1, 1, 0)
	transition_label.add_theme_font_size_override("font_size", 40)
	transition_label.add_theme_color_override("font_color", Color(0.92, 0.95, 1.0))
	layer.add_child(transition_label)


# ── 选关 / 进度 ─────────────────────────────────────────

func _setup_level_select() -> void:
	level_select = LevelSelect.new()
	level_select.name = "LevelSelect"
	add_child(level_select)
	level_select.level_chosen.connect(_on_level_chosen)
	level_select.closed.connect(_on_level_select_closed)
	level_select.reset_requested.connect(_on_progress_reset)


func _open_level_select() -> void:
	# 通关/坠落动画期间不要弹选关（否则会和自动换关过渡打架）
	if transitioning or _replaying or game.is_won() or game.is_lost():
		return
	if levels.is_empty():
		return
	_hide_hud(true)
	level_select.open_with(entries, progress, current_index)


func _hide_hud(hidden: bool) -> void:
	if hud_layer != null:
		hud_layer.visible = not hidden


func _on_level_select_closed() -> void:
	_hide_hud(false)


func _on_level_chosen(index: int) -> void:
	level_select.close()   # 会触发 closed → 恢复 HUD
	_load_level(index, true)


func _on_progress_reset() -> void:
	progress.reset()
	level_select.open_with(entries, progress, current_index)


# ── 回放（最佳记录重演）──────────────────────────────────

func _play_replay() -> void:
	if _replaying or transitioning or levels.is_empty():
		return
	var rep: Dictionary = progress.replay(_level_key(current_index))
	if rep.is_empty() or (rep["moves"] as Array).is_empty():
		return
	_replaying = true
	_do_load(current_index)
	var moves: Array = rep["moves"]
	await get_tree().process_frame

	for i in range(moves.size()):
		if not _replaying:
			break
		replay_label.text = "回放　%d / %d　（Esc 退出）" % [i + 1, moves.size()]
		replay_label.visible = true
		game.try_move(Moves.direction_from_label(str(moves[i])))
		while game.animating:
			await get_tree().process_frame
		if game.is_won() or game.is_lost():
			break
		await get_tree().create_timer(0.05).timeout

	replay_label.text = "回放结束"
	await get_tree().create_timer(0.7).timeout
	_replaying = false
	_do_load(current_index)   # 复位，方便玩家接着挑战


func _restart() -> void:
	_load_level(current_index, false)


func _next_level() -> void:
	_load_level((current_index + 1) % levels.size(), true)


func _prev_level() -> void:
	_load_level((current_index - 1 + levels.size()) % levels.size(), true)


func _on_moved() -> void:
	_update_hud()


func _on_won() -> void:
	_update_hud()
	# 回放中到达终点：只提示，不记录进度、不自动换关
	if _replaying:
		win_label.text = "回放到达终点　·　%d 步" % game.move_count
		win_label.visible = true
		await _win_beat()
		return
	var res: Dictionary = progress.record_win(_level_key(current_index), _run_moves)
	_update_hud()
	win_label.text = _win_text(res)
	win_label.visible = true
	# 通关反馈：灯光脉冲一下（方块保持原位、不变色），随后自然滚动换关
	await _win_beat()
	if transitioning or levels.is_empty():
		return
	_transition_to((current_index + 1) % levels.size())


func _win_text(res: Dictionary) -> String:
	var base := "通关! 步数: %d" % int(res["move_count"])
	if bool(res["first_clear"]):
		return base + "　·　首次通关"
	if bool(res["improved"]):
		return base + "　·　新纪录!（原 %d）" % int(res["prev_best"])
	return base


func _win_beat() -> void:
	var tw := create_tween()
	tw.tween_property(light, "light_energy", LIGHT_ENERGY * 2.8, 0.22) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_property(light, "light_energy", LIGHT_ENERGY, 0.4) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	await tw.finished
	await get_tree().create_timer(0.08).timeout


func _on_fell() -> void:
	_update_hud()
	if _replaying:
		fail_label.text = "回放异常结束　（Esc 退出）"
		fail_label.visible = true
		return
	fail_label.text = "坠落! 方块掉出了棋盘   (按 R 重开)"
	fail_label.visible = true


func _update_hud() -> void:
	if levels.is_empty():
		return
	level_label.text = "第 %d 关　·　%d / %d" % [current_index + 1, current_index + 1, levels.size()]
	progress_bar.max_value = float(levels.size())
	progress_bar.value = float(current_index + 1)
	moves_label.text = "步数  %d" % game.move_count

	# 最佳 / 参考步数：给「刷分」提供明确目标
	var key: String = _level_key(current_index)
	var best: int = progress.best_moves(key)
	var optimal: int = -1
	if current_index >= 0 and current_index < entries.size():
		optimal = int(entries[current_index].get("optimal", -1))
	var parts: Array = []
	if best > 0:
		parts.append("最佳 %d" % best)
		if optimal > 0 and best == optimal:
			parts.append("已最优")
	elif optimal > 0:
		parts.append("参考 %d" % optimal)
	best_label.text = "　·　".join(parts) if parts.size() > 0 else "　"


func _do_move(d: Vector3i) -> void:
	# 统一入口：记录本局移动（用于 Replay）后再交给 Game
	if game.try_move(d):
		_run_moves.append(Moves.direction_label(d))


func _unhandled_input(event: InputEvent) -> void:
	if game == null or transitioning:
		return
	# 选关界面打开时，输入交给它自己处理
	if level_select != null and level_select.is_open():
		return
	if event is InputEventKey and event.pressed and not event.echo:
		# 回放中只允许退出
		if _replaying:
			if event.keycode == KEY_ESCAPE:
				_replaying = false
			return
		match event.keycode:
			KEY_R:
				_restart()
				return
			KEY_L, KEY_ESCAPE:
				_open_level_select()
				return
			KEY_V:
				_play_replay()
				return
			KEY_N:
				_next_level()
				return
			KEY_P:
				_prev_level()
				return
		# 数字键 1-9：跳到已解锁的关卡
		var num_keys: Array = [KEY_1, KEY_2, KEY_3, KEY_4, KEY_5, KEY_6, KEY_7, KEY_8, KEY_9]
		var idx: int = num_keys.find(event.keycode)
		if idx >= 0:
			if progress.is_unlocked(idx, _level_keys()):
				_do_load(idx)
			return
	var d: Vector3i = game.event_to_dir(event)
	if d != Vector3i.ZERO:
		_do_move(d)


func _frame_camera() -> void:
	# 参考经典 Bloxorz 的斜 45° 等距视角：棋盘呈菱形，方块与终点在屏幕上天然错开，
	# 因此竖起的方块不会直接遮住后方目标格（无需额外标记）。
	if cam == null or game == null or game.board == null:
		return
	var cx: float = float(game.board.grid_x) / 2.0
	var cz: float = float(game.board.grid_z) / 2.0
	var s: float = float(max(game.board.grid_x, game.board.grid_z))
	var az: float = deg_to_rad(45.0)
	var horiz: float = s * 1.35
	cam.position = Vector3(cx + horiz * sin(az), s * 1.35, cz + horiz * cos(az))
	cam.look_at(Vector3(cx, 0.0, cz))


func _setup_camera() -> void:
	cam = Camera3D.new()
	cam.name = "Camera3D"
	cam.fov = 55.0
	add_child(cam)


func _setup_light() -> void:
	light = DirectionalLight3D.new()
	light.name = "DirectionalLight3D"
	light.rotation_degrees = Vector3(-52.0, -38.0, 0.0)
	light.light_energy = LIGHT_ENERGY * 1.15
	light.light_color = Color(1.0, 0.96, 0.90)  # 略暖，画面不生硬
	light.shadow_enabled = true                 # 方块在瓦片上投影 → 立体感
	light.directional_shadow_max_distance = 40.0
	add_child(light)


func _setup_environment() -> void:
	# 渐变天空（比纯色背景更自然、更耐看）+ 柔和环境光
	var env := WorldEnvironment.new()
	env.name = "WorldEnvironment"
	var e := Environment.new()
	# gl_compatibility 下真实天空不渲染，背景用“渐变幕布”实现（见 _setup_backdrop）
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.10, 0.13, 0.21)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.44, 0.49, 0.62)
	e.ambient_light_energy = 0.65   # 压低环境光 → 方块在瓦片上的阴影更明显
	env.environment = e
	add_child(env)


func _setup_backdrop() -> void:
	# 挂在相机前的渐变幕布（充当天空）：比纯色背景自然得多，且全渲染后端可用
	var sh := Shader.new()
	sh.code = """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never;
uniform vec3 top_color : source_color = vec3(0.085, 0.11, 0.20);
uniform vec3 mid_color : source_color = vec3(0.19, 0.25, 0.40);
uniform vec3 bottom_color : source_color = vec3(0.06, 0.08, 0.13);
void fragment() {
	vec3 c = UV.y < 0.62
		? mix(top_color, mid_color, UV.y / 0.62)
		: mix(mid_color, bottom_color, (UV.y - 0.62) / 0.38);
	ALBEDO = c;
}
"""
	var mat := ShaderMaterial.new()
	mat.shader = sh
	var quad := QuadMesh.new()
	quad.size = Vector2(600.0, 600.0)
	var mi := MeshInstance3D.new()
	mi.name = "Backdrop"
	mi.mesh = quad
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	cam.add_child(mi)
	mi.position = Vector3(0.0, 0.0, -300.0)


func _setup_hud() -> void:
	var hud := CanvasLayer.new()
	hud.name = "HUD"
	add_child(hud)
	hud_layer = hud

	# ── 左上：关卡 + 进度条 ────────────────────────────
	var left := _make_panel(hud)
	left.anchor_left = 0.0
	left.anchor_top = 0.0
	left.offset_left = 22.0
	left.offset_top = 20.0
	left.offset_right = 22.0 + 208.0
	left.offset_bottom = 20.0 + 74.0
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 9)
	level_label = Label.new()
	level_label.add_theme_font_size_override("font_size", 21)
	level_label.add_theme_color_override("font_color", Color(0.92, 0.95, 1.0))
	col.add_child(level_label)
	progress_bar = ProgressBar.new()
	progress_bar.custom_minimum_size = Vector2(0, 8)
	progress_bar.show_percentage = false
	progress_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var sb_bg := StyleBoxFlat.new()
	sb_bg.bg_color = Color(1, 1, 1, 0.14)
	sb_bg.set_corner_radius_all(4)
	var sb_fill := StyleBoxFlat.new()
	sb_fill.bg_color = Color(0.36, 0.86, 0.58)
	sb_fill.set_corner_radius_all(4)
	progress_bar.add_theme_stylebox_override("background", sb_bg)
	progress_bar.add_theme_stylebox_override("fill", sb_fill)
	col.add_child(progress_bar)
	left.add_child(col)

	# ── 右上：步数 ──────────────────────────────────
	var right := _make_panel(hud)
	right.anchor_left = 1.0
	right.anchor_right = 1.0
	right.offset_left = -22.0 - 190.0
	right.offset_right = -22.0
	right.offset_top = 20.0
	right.offset_bottom = 20.0 + 74.0
	var rcol := VBoxContainer.new()
	rcol.add_theme_constant_override("separation", 3)
	moves_label = Label.new()
	moves_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	moves_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	moves_label.add_theme_font_size_override("font_size", 21)
	moves_label.add_theme_color_override("font_color", Color(0.92, 0.95, 1.0))
	rcol.add_child(moves_label)
	best_label = Label.new()
	best_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	best_label.add_theme_font_size_override("font_size", 13)
	best_label.add_theme_color_override("font_color", Color(0.62, 0.70, 0.86))
	best_label.text = "　"
	rcol.add_child(best_label)
	right.add_child(rcol)

	# ── 中央横幅（通关 / 坠落）─────────────────────────
	win_label = _make_banner(hud, -84.0, 42, Color(0.40, 1.0, 0.60))
	fail_label = _make_banner(hud, 84.0, 34, Color(1.0, 0.45, 0.45))

	# ── 底部操作提示（一段时间后自动变淡，减少长期干扰）────
	help_label = Label.new()
	help_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	help_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	help_label.anchor_left = 0.0
	help_label.anchor_right = 1.0
	help_label.anchor_top = 1.0
	help_label.anchor_bottom = 1.0
	help_label.offset_top = -36.0
	help_label.offset_bottom = -12.0
	help_label.add_theme_font_size_override("font_size", 15)
	help_label.add_theme_color_override("font_color", Color(0.80, 0.85, 0.95))
	help_label.text = "方向键 / WASD 移动     R 重开     L 选关     V 看最佳回放     ·     掉出棋盘或落入空洞会坠落"
	hud.add_child(help_label)
	_fade_help_later()

	# ── 回放状态条（顶部，仅在回放时出现）───────────────
	replay_label = _make_banner(hud, -170.0, 20, Color(0.62, 0.80, 1.0))


func _make_panel(parent: Node) -> PanelContainer:
	# 圆角半透明面板：让 HUD 在 3D 背景上依然清晰、且有质感
	var pc := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.07, 0.09, 0.15, 0.55)
	sb.set_corner_radius_all(14)
	sb.content_margin_left = 18.0
	sb.content_margin_right = 18.0
	sb.content_margin_top = 12.0
	sb.content_margin_bottom = 12.0
	sb.border_color = Color(1.0, 1.0, 1.0, 0.07)
	sb.set_border_width_all(1)
	pc.add_theme_stylebox_override("panel", sb)
	parent.add_child(pc)
	return pc


func _fade_help_later() -> void:
	# 操作提示常驻会干扰长时间游玩：一段时间后自动变淡（仍可读）
	var t := get_tree().create_timer(9.0)
	t.timeout.connect(func() -> void:
		var tw := create_tween()
		tw.tween_property(help_label, "modulate:a", 0.3, 1.2))


func _make_banner(hud: CanvasLayer, y_offset: float, size: int, color: Color) -> Label:
	# 屏幕居中提示条（按锚点定位，分辨率无关）
	var l := Label.new()
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.anchor_left = 0.0
	l.anchor_right = 1.0
	l.anchor_top = 0.5
	l.anchor_bottom = 0.5
	l.offset_left = 0.0
	l.offset_right = 0.0
	l.offset_top = y_offset - 44.0
	l.offset_bottom = y_offset + 44.0
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.visible = false
	hud.add_child(l)
	return l
