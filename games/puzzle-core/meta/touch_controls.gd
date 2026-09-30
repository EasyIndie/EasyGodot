# touch_controls.gd — 触屏操作层：方向键（D-pad）+ 动作按钮 + 滑动手势。
#
# 只在触屏设备显示（`main.gd` 用 DisplayServer.is_touchscreen_available() 判定，
# 也可用 `?touch=1` / `?touch=0` 强制，桌面调试可按 T 切换）。
#
# **方向映射与键盘完全一致**（→=+x、←=-x、↓=+z、↑=-z），也等于网格轴方向。
# 因为相机是斜 45° 等距视角，方块在屏幕上表现为斜向移动 —— 这是既定的取景约定，
# 一套心智模型同时适用于键盘和触屏，不搞两套。
extends CanvasLayer

signal direction(d: Vector3i)
signal restart_pressed
signal select_pressed
signal replay_pressed

const LAYOUT = preload("res://meta/ui_layout.gd")

const SWIPE_MIN := 26.0        # 最小滑动距离（缓冲区像素）
const SWIPE_MAX_TIME := 0.9    # 超过此时长不算滑动
const SWIPE_COOLDOWN := 0.12   # 触屏会再模拟一次鼠标事件，用冷却去重

# 斜 45° 等距相机下，方块只能沿四个网格方向滚，它们在屏幕上成对角分布，
# 所以 D-pad 直接**摆在对角位置、用对角箭头**：按钮位置 / 箭头 / 方块去向三者一致。
const GLYPH := {
	Vector3i(0, 0, -1): "↗",
	Vector3i(1, 0, 0): "↘",
	Vector3i(0, 0, 1): "↙",
	Vector3i(-1, 0, 0): "↖",
}

var _pad: GridContainer
var _actions: VBoxContainer
var _dir_buttons: Array = []
var _action_buttons: Array = []
var _unit: float = 64.0
var _screen_dirs: Dictionary = {}   # 由 main.gd 用相机 unproject 现算后注入
var _tracking: bool = false
var _start_pos: Vector2 = Vector2.ZERO
var _start_time: float = 0.0
var _cooldown: float = 0.0


func _ready() -> void:
	layer = 5  # 在 HUD(0) 之上、换关过渡层(10) 之下
	visible = false

	var root := Control.new()
	root.name = "TouchRoot"
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	_pad = GridContainer.new()
	_pad.columns = 3
	_pad.add_theme_constant_override("h_separation", 6)
	_pad.add_theme_constant_override("v_separation", 6)
	_pad.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_pad)

	# 3×3：把四个方向放在**四角**（＝屏幕上的四个对角），中心与四边留空
	var cells: Array = [
		Vector3i(-1, 0, 0), null, Vector3i(0, 0, -1),
		null, null, null,
		Vector3i(0, 0, 1), null, Vector3i(1, 0, 0),
	]
	for c in cells:
		if c == null:
			var sp := Control.new()
			sp.mouse_filter = Control.MOUSE_FILTER_IGNORE
			_pad.add_child(sp)
		else:
			var b := _make_button(str(GLYPH[c]))
			var d: Vector3i = c
			b.pressed.connect(func() -> void: direction.emit(d))
			_pad.add_child(b)
			_dir_buttons.append(b)

	_actions = VBoxContainer.new()
	_actions.add_theme_constant_override("separation", 8)
	_actions.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_actions)
	for spec in [["重开", "restart_pressed"], ["选关", "select_pressed"], ["回放", "replay_pressed"]]:
		var b := _make_button(str(spec[0]))
		var sig: String = str(spec[1])
		b.pressed.connect(func() -> void: emit_signal(sig))
		_actions.add_child(b)
		_action_buttons.append(b)

	get_viewport().size_changed.connect(_apply_layout)
	_apply_layout()


# ── 对外 ───────────────────────────────────────────────

func set_shown(on: bool) -> void:
	visible = on
	if on:
		_apply_layout()


func is_shown() -> bool:
	return visible


func bottom_inset() -> float:
	# 底部被控件占用的高度（供 HUD 提示文字避让）
	return _unit * 3.0 + _unit * 0.68


func set_screen_dirs(dirs: Dictionary) -> void:
	# 注入「每个网格方向在屏幕上的方向」——由相机决定，换取景自动跟随
	_screen_dirs = dirs


# ── 布局 ───────────────────────────────────────────────

func _apply_layout() -> void:
	var vp: Vector2 = get_viewport().get_visible_rect().size
	_unit = LAYOUT.touch_unit(vp)
	var margin: float = _unit * 0.34
	var pad: float = _unit * 3.0

	_pad.position = Vector2(margin, vp.y - pad - margin)
	_pad.size = Vector2(pad, pad)
	for b in _dir_buttons:
		b.custom_minimum_size = Vector2(_unit, _unit)
		b.add_theme_font_size_override("font_size", int(_unit * 0.46))

	var bw: float = _unit * 1.60
	var bh: float = _unit * 0.72
	var sep: float = 8.0
	for b in _action_buttons:
		b.custom_minimum_size = Vector2(bw, bh)
		b.add_theme_font_size_override("font_size", int(_unit * 0.31))
	_actions.size = Vector2(bw, bh * float(_action_buttons.size()) + sep * float(maxi(_action_buttons.size() - 1, 0)))
	_actions.position = Vector2(vp.x - bw - margin, vp.y - _actions.size.y - margin)


func _make_button(text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE  # 触屏不需要键盘焦点
	b.mouse_filter = Control.MOUSE_FILTER_STOP
	b.add_theme_color_override("font_color", Color(0.90, 0.94, 1.0))
	b.add_theme_color_override("font_hover_color", Color(1, 1, 1))
	b.add_theme_color_override("font_pressed_color", Color(1, 1, 1))
	b.add_theme_stylebox_override("normal", _sb(Color(0.09, 0.12, 0.20, 0.62), Color(1, 1, 1, 0.14)))
	b.add_theme_stylebox_override("hover", _sb(Color(0.14, 0.19, 0.30, 0.72), Color(0.55, 0.75, 1.0, 0.60)))
	b.add_theme_stylebox_override("pressed", _sb(Color(0.22, 0.34, 0.55, 0.88), Color(0.55, 0.75, 1.0, 0.90)))
	return b


func _sb(bg: Color, border: Color) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.set_corner_radius_all(14)
	s.set_border_width_all(1)
	s.border_color = border
	return s


# ── 滑动手势 ───────────────────────────────────────────

func _process(delta: float) -> void:
	if _cooldown > 0.0:
		_cooldown -= delta


static func swipe_dir(delta: Vector2, screen_dirs: Dictionary = {}) -> Vector3i:
	# 滑动方向 → 网格方向：**按屏幕上最接近的方向**映射（而不是按网格轴），
	# 这样「往哪滑，方块就往哪滚」。触碰阈值以下的位移不算滑动。
	if delta.length() < SWIPE_MIN:
		return Vector3i.ZERO
	var dirs: Dictionary = screen_dirs if not screen_dirs.is_empty() else LAYOUT.DEFAULT_SCREEN_DIRS
	return LAYOUT.best_dir(delta, dirs)


func _input(event: InputEvent) -> void:
	if not visible:
		return
	var pos := Vector2.ZERO
	var pressed := false
	if event is InputEventScreenTouch:
		pos = event.position
		pressed = event.pressed
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		pos = event.position
		pressed = event.pressed
	else:
		return
	if pressed:
		_tracking = true
		_start_pos = pos
		_start_time = Time.get_ticks_msec() / 1000.0
	else:
		_finish(pos)


func _finish(pos: Vector2) -> void:
	if not _tracking:
		return
	_tracking = false
	if _cooldown > 0.0:
		return  # 触屏→鼠标的重复投递
	if Time.get_ticks_msec() / 1000.0 - _start_time > SWIPE_MAX_TIME:
		return
	var d: Vector3i = swipe_dir(pos - _start_pos, _screen_dirs)
	if d != Vector3i.ZERO:
		_cooldown = SWIPE_COOLDOWN
		direction.emit(d)
