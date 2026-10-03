# touch_controls.gd — 触屏操作层：方向键（D-pad）+ 动作按钮 + 滑动手势 + 手势提示。
#
# 只在触屏设备显示（`main.gd` 用 DisplayServer.is_touchscreen_available() 判定，
# 也可用 `?touch=1` / `?touch=0` 强制，桌面调试可按 T 切换）。
#
# 设计原则（几条都是踩过坑之后定下来的）：
#
#  1) **滑动按屏幕方向映射**，不是网格轴方向。
#     相机是斜 45° 等距视角，四个网格方向在屏幕上成对角分布：
#        -z = 右上   +x = 右下   +z = 左下   -x = 左上
#     所以「往哪滑，方块就往哪滚」。早期按网格轴映射的结果是：
#     手指往上滑，方块往右上滚 —— 玩家立刻会觉得“不听话”。
#
#  1b) 方向解算与"什么时候算一次移动"分别放在 meta/gesture.gd 与
#      meta/gesture_tracker.gd 里（纯逻辑、可逐个角度断言）。这里只负责
#      把输入事件喂进去、把结果转成信号，并做视觉反馈。
#
#  2) **默认不显示 D-pad**：手势才是主要输入，屏幕上少一块按钮，棋盘就多一块。
#     方向键是"备选操作方式"，在选关界面里可以打开（记在进度里，开一次就一直有）。
#     打开时它摆在四角、用对角箭头（↖↗↙↘），
#     让「按钮位置 / 箭头方向 / 方块去向」三者一致。
#
#  3) 每个功能都必须有**可点的入口**。（选关界面曾经只能靠 Esc 关闭，
#     手机上进去就出不来。）
#
#  4) 所有控件都要避开**安全区域**（刘海 / 灵动岛 / 底部手势条），
#     否则 iPhone 横屏时按钮会被灵动岛切掉、底部按钮会被手势条压住。
#
#  5) 触屏是“指向性”输入但**看不见规则**，所以第一次进关卡要给一次
#     手势方向提示（对角线），并随第一次成功移动自动收起。
#
#  6) **不做拖动指示器**。曾经在手指旁画过一个"当前指向的箭头"，
#     真机反馈是"多余"：方块本身就是最直接的反馈 —— 滑对了它立刻滚，
#     滑错了它不动，玩家不需要再看一个小箭头。屏幕上的每一样东西都要挣得它的位置。
#     （方向键打开时命中会闪一下，那是按钮自身的反馈，不占额外空间。）
#
#  7) **一次手势至多一步移动**（滑过阈值立刻判定，不等抬手；判定后本手势作废）。
#     曾经做成"像摇杆一样连滚"，真机反馈是「滑一次会滚很多次」——
#     对解谜游戏来说多滚一格就是误操作，所以这条铁律写死在 gesture_tracker 里。
#     真正修"不跟手"靠的是：不等抬手就判定 + 动画期间不丢输入（main.gd 的缓冲）。
extends CanvasLayer

signal direction(d: Vector3i)
signal restart_pressed
signal select_pressed
signal replay_pressed

const LAYOUT = preload("res://meta/ui_layout.gd")

const Gesture = preload("res://meta/gesture.gd")
const GestureTracker = preload("res://meta/gesture_tracker.gd")

const TAP_SLOP := 12.0         # 小于此位移算"点按"（事件留给按钮），超过才算拖动
const FLASH_TIME := 0.16       # 方向键命中反馈的闪烁时长
# 注意：这里**没有**滑动时间上限。早期有（超过 0.9 秒的滑动整条丢弃），
# 结果是"想清楚再滑"完全没反应 —— 慢滑也是滑。

# 斜 45° 等距相机下，方块只能沿四个网格方向滚，它们在屏幕上成对角分布，
# 所以 D-pad 直接**摆在对角位置、用对角箭头**：按钮位置 / 箭头 / 方块去向三者一致。
const GLYPH := {
	Vector3i(0, 0, -1): "↗",
	Vector3i(1, 0, 0): "↘",
	Vector3i(0, 0, 1): "↙",
	Vector3i(-1, 0, 0): "↖",
}

# 动作按钮：**纯文字**。
# 为什么不用图标字形：内置的 Noto Sans SC 子集几乎没有符号字形
# （↺ ☰ ▶ 全都缺），一旦缺字形就会渲染成豆腐块——字体守卫测试会直接拦下来。
# 与其为了图标再挂一套符号字体，不如把字写清楚；回放中的状态用**颜色**表达
# （见 set_replay_playing），这比换一个模糊的小图标更好认。
const ACTION_RESTART := "重开"
const ACTION_SELECT := "选关"
const ACTION_REPLAY := "回放"
const ACTION_STOP := "停止回放"

const HINT_TEXT := "滑动屏幕即可移动　↖ ↗ ↙ ↘"
const HINT_TIME := 6.0   # 提示自动收起时间（秒）

var _root: Control
var _pad: GridContainer
var _actions: HBoxContainer
var _hint: PanelContainer
var _hint_label: Label
var _dir_buttons: Array = []
var _action_buttons: Array = []
var _replay_button: Button = null
var _unit: float = 64.0
var _screen_dirs: Dictionary = {}   # 由 main.gd 用相机 unproject 现算后注入
var _insets: Dictionary = {"left": 0.0, "top": 0.0, "right": 0.0, "bottom": 0.0}
var _tracker = null            # GestureTracker：拖动 → 移动序列
var _has_touch: bool = false   # 见过真触摸后就不再理会鼠标（触摸会再模拟一次鼠标）
var _drag_begin: Vector2 = Vector2.ZERO
var _drag_moved: bool = false  # 已超出"点按"范围 → 事件不再交给按钮
var _drag_pos: Vector2 = Vector2.ZERO   # 最近一次拖动位置（反馈/查询用）
var _btn_dirs: Array = []      # 与 _dir_buttons 一一对应的方向
var _flash: Dictionary = {}    # 方向 → 剩余闪烁时长
var _pad_enabled: bool = false # D-pad 默认关闭（手势优先；可在选关界面开启）
var _replay_available: bool = false   # 本关有回放记录时才显示「回放」
var _hint_done: bool = false
var _hint_timer: float = 0.0
var _replay_playing: bool = false


func _ready() -> void:
	layer = 5  # 在 HUD(0) 之上、换关过渡层(10) 之下
	visible = false

	_root = Control.new()
	_root.name = "TouchRoot"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	_pad = GridContainer.new()
	_pad.columns = 3
	_pad.add_theme_constant_override("h_separation", 6)
	_pad.add_theme_constant_override("v_separation", 6)
	_pad.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_pad)

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
			# 走 _emit_dir 而不是直接 emit：这样点方向键也会更新粘滞方向、闪一下，
			# 与滑动走完全同一条路径（同一个动作只有一套实现）
			b.pressed.connect(func() -> void: _emit_dir(d))
			_pad.add_child(b)
			_dir_buttons.append(b)
			_btn_dirs.append(d)

	# 动作按钮：**一排小胶囊**，只放当前真正用得上的那几个。
	# 竖排三大块会占掉右下角一整片（在竖屏手机上横扫棋盘）；一行只占一条边。
	_actions = HBoxContainer.new()
	_actions.add_theme_constant_override("separation", 8)
	_actions.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_actions)
	var specs: Array = [
		[ACTION_RESTART, "restart_pressed"],
		[ACTION_SELECT, "select_pressed"],
		[ACTION_REPLAY, "replay_pressed"],
	]

	for spec in specs:
		var b := _make_button(str(spec[0]))
		var sig: String = str(spec[1])
		b.pressed.connect(func() -> void: emit_signal(sig))
		_actions.add_child(b)
		_action_buttons.append(b)
		# 「回放」只在本关**确实有回放记录**时才出现：没有记录就没有按钮，
		# 界面上不留一个永远点不动的死按钮。
		if str(spec[0]) == ACTION_REPLAY:
			_replay_button = b
			b.visible = false

	# 手势提示：一条会自己收起的窄条。触屏玩家不知道“对角线滑动”这套规则，
	# 光有 D-pad 也说明不了「滑动方向 = 方块去向」。

	_hint = PanelContainer.new()
	_hint.visible = false
	_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var hsb := StyleBoxFlat.new()
	hsb.bg_color = Color(0.07, 0.10, 0.17, 0.80)
	hsb.set_corner_radius_all(14)
	hsb.set_border_width_all(1)
	hsb.border_color = Color(1, 1, 1, 0.10)
	hsb.content_margin_left = 14.0
	hsb.content_margin_right = 14.0
	hsb.content_margin_top = 7.0
	hsb.content_margin_bottom = 7.0
	_hint.add_theme_stylebox_override("panel", hsb)
	_hint_label = Label.new()
	_hint_label.text = HINT_TEXT
	_hint_label.add_theme_color_override("font_color", Color(0.86, 0.92, 1.0))
	_hint.add_child(_hint_label)
	_root.add_child(_hint)

	get_viewport().size_changed.connect(_apply_layout)
	_apply_layout()


# ── 对外 ───────────────────────────────────────────────

func set_shown(on: bool) -> void:
	visible = on
	if on:
		_apply_layout()


func is_shown() -> bool:
	return visible


func set_safe_insets(insets: Dictionary) -> void:
	# 由 main.gd 注入（Web 读 CSS env()，原生平台读 DisplayServer）
	_insets = insets
	_apply_layout()


func safe_insets() -> Dictionary:
	return _insets.duplicate()


func bottom_inset() -> float:
	# 底部被控件（含安全区）占用的高度，供 HUD 提示带避让。
	# 数字键与动作胶囊并排，所以取两者更高的那个（不是相加）。
	var pad: float = _unit * 3.0 if _pad_enabled else 0.0
	var bh: float = clampf(_unit * 0.62, 44.0, 58.0)
	return maxf(pad, bh) + float(_insets.get("bottom", 0.0)) + 18.0


func set_screen_dirs(dirs: Dictionary) -> void:
	# 注入「每个网格方向在屏幕上走一格的向量」——由相机决定，换取景自动跟随。
	# **不归一化**：长度就是格子屏宽，手势阈值按它缩放（大屏小屏手感才一致）。
	_screen_dirs = dirs
	if _tracker != null:
		_tracker.set_dirs(dirs)


# 供测试/上层查询：当前手指指向的方向（没到阈值也返回）
func drag_dir() -> Vector3i:
	# 注意要喂**最近一次拖动位置**而不是起点：起点算出来的差值永远是 0
	#（这个错会让拖动指示永远不亮，而方向其实是对的 —— 只有截图才能看出来）
	if _tracker == null:
		return Vector3i.ZERO
	return _tracker.prev if not _tracker.active else _tracker.peek(_drag_pos)


func screen_dirs() -> Dictionary:
	return _screen_dirs


# 拖动进度（0~1，距触发还差多少）——画反馈用
func drag_ratio(pos: Vector2) -> float:
	if _tracker == null:
		return 0.0
	return _tracker.ratio(pos)


func set_replay_playing(playing: bool) -> void:
	# 回放中同一个按钮兼作「停止」：触屏没有 Esc，否则玩家只能干等回放放完。
	# 状态同时用**文字**和**颜色**表达：文字说清楚会发生什么，
	# 颜色让它在余光里也能被注意到（视线通常在棋盘上）。
	_replay_playing = playing
	if _action_buttons.size() >= 3:
		var b: Button = _action_buttons[2]
		b.text = ACTION_STOP if playing else ACTION_REPLAY
		if playing:
			b.add_theme_stylebox_override("normal", _sb(Color(0.42, 0.16, 0.18, 0.80), Color(1.0, 0.55, 0.55, 0.65)))
			b.add_theme_stylebox_override("hover", _sb(Color(0.55, 0.22, 0.24, 0.90), Color(1.0, 0.65, 0.65, 0.85)))
		else:
			b.add_theme_stylebox_override("normal", _sb(Color(0.09, 0.12, 0.20, 0.62), Color(1, 1, 1, 0.14)))
			b.add_theme_stylebox_override("hover", _sb(Color(0.14, 0.19, 0.30, 0.72), Color(0.55, 0.75, 1.0, 0.60)))


func is_replay_playing() -> bool:
	return _replay_playing


func set_pad_enabled(on: bool) -> void:
	# 方向键是"备选操作方式"：默认关，玩家在选关界面里开（选择会被记住）
	_pad_enabled = on
	_apply_layout()


func pad_enabled() -> bool:
	return _pad_enabled


func pad_visible() -> bool:
	return _pad != null and _pad.visible


func set_replay_available(on: bool) -> void:
	# 本关有没有回放记录 → 决定「回放」按钮出不出现
	if _replay_button == null:
		return
	_replay_available = on
	_replay_button.visible = on
	_apply_layout()


func replay_available() -> bool:
	return _replay_available


func show_swipe_hint() -> void:
	# 每次进入关卡给一次提示，但**每局游戏只给一次**：
	# 反复弹提示会变成噪音，玩家学会之后就不需要了。
	if _hint_done:
		return
	_hint.visible = true
	_hint.modulate.a = 0.0
	var tw := create_tween()
	tw.tween_property(_hint, "modulate:a", 1.0, 0.35)
	_hint_timer = HINT_TIME
	_apply_layout()


func dismiss_swipe_hint() -> void:
	# 玩家第一次成功移动后立即收起（比等到超时更贴合“学会了”这个时刻）
	if _hint_done or _hint == null:
		return
	_hint_done = true
	_hint_timer = 0.0
	var tw := create_tween()
	tw.tween_property(_hint, "modulate:a", 0.0, 0.4)
	tw.finished.connect(func() -> void: _hint.visible = false)


func hint_visible() -> bool:
	# 以 visible 为准（淡入过程中也算“正在显示”），而不是用 alpha 判断：
	# 刚调用 show_swipe_hint() 的这一帧 alpha 还是 0，用 alpha 判定会得到“没显示”。
	return _hint != null and _hint.visible


func hint_text() -> String:
	return _hint_label.text if _hint_label != null else ""


func layout_info() -> Dictionary:
	# 供测试断言：控件是否都落在屏幕（含安全区）之内
	return {
		"unit": _unit,
		"pad": {"pos": _pad.position, "size": _pad.size},
		"actions": {"pos": _actions.position, "size": _actions.size},
		"hint": {"pos": _hint.position, "size": _hint.size},
		"insets": _insets.duplicate(),
		# 供测试断言"界面上到底有几样东西"：多加一个控件就该有人问为什么
		"ui_children": ui_child_names(),
		"pad_visible": pad_visible(),
		"replay_visible": _replay_button != null and _replay_button.visible,
	}


func ui_child_names() -> Array:
	# 触屏层的全部界面元素（**就这几样**：方向键盘、动作胶囊、手势提示）。
	# 这条不变量是有意的：屏幕上每多一样东西，棋盘就少一点呼吸空间。
	var out: Array = []
	if _root == null:
		return out
	for c in _root.get_children():
		out.append(str(c.name))
	out.sort()
	return out


# ── 布局 ───────────────────────────────────────────────

func _apply_layout() -> void:
	if _pad == null:
		return
	var vp: Vector2 = get_viewport().get_visible_rect().size
	_unit = LAYOUT.touch_unit(vp)
	var margin: float = _unit * 0.24
	var pad: float = _unit * 3.0
	var sl: float = float(_insets.get("left", 0.0))
	var sr: float = float(_insets.get("right", 0.0))
	var sb: float = float(_insets.get("bottom", 0.0))
	var st: float = float(_insets.get("top", 0.0))

	# 左下：D-pad（默认隐藏；打开时仍是菱形四角的对角箭头）
	_pad.visible = _pad_enabled
	_pad.position = Vector2(sl + margin, vp.y - sb - pad - margin)
	_pad.size = Vector2(pad, pad)
	for b in _dir_buttons:
		b.custom_minimum_size = Vector2(_unit, _unit)
		b.add_theme_font_size_override("font_size", int(_unit * 0.46))

	# 右下：一排小胶囊（选关 / 重开 / 有回放时的回放）。
	# 每个按钮的高度就是"拇指落点"，所以下限钉在 44（约 44pt），上限别太大。
	var visible_actions: Array = []
	for b in _action_buttons:
		if b.visible:
			visible_actions.append(b)
	var bh: float = clampf(_unit * 0.62, 44.0, 58.0)
	var bw: float = bh * 1.45
	var sep: float = maxf(_unit * 0.16, 8.0)
	for b in _action_buttons:
		b.custom_minimum_size = Vector2(bw, bh)
		b.add_theme_font_size_override("font_size", int(bh * 0.36))
	var n: int = maxi(visible_actions.size(), 1)
	var aw: float = bw * float(n) + sep * float(n - 1)
	# 一行放不下（极窄屏 + 三个按钮）→ 按总宽缩字号与按钮宽，绝不换行堆高
	var avail_w: float = vp.x - sl - sr - margin * 2.0
	if aw > avail_w and aw > 1.0:
		var k: float = avail_w / aw
		bw = maxf(bw * k, 40.0)
		bh = maxf(bh * k, 40.0)
		aw = bw * float(n) + sep * float(n - 1)
		for b in _action_buttons:
			b.custom_minimum_size = Vector2(bw, bh)
			b.add_theme_font_size_override("font_size", int(maxf(bh * 0.36, 11.0)))
	_actions.size = Vector2(aw, bh)
	_actions.position = Vector2(vp.x - sr - margin - aw, vp.y - sb - margin - bh)

	# 手势提示：**左对齐在 D-pad 正上方**。
	# 早先横屏时把它水平居中，结果正好落在棋盘中央，把棋盘和目标格都盖住了 ——
	# 提示应该贴着它要解释的那个控件，而不是抢画面中心。
	#
	# 窄屏适配用「缩字号」而不是「换行」：换行会让提示条变成两行高，
	# 在小屏上又会去挤棋盘；缩字号则始终是一行，位置稳定、可预测。
	var max_w: float = maxf(vp.x - sl - sr - margin * 2.0, 120.0)
	var fs: float = clampf(_unit * 0.23, 12.0, 18.0)
	_hint_label.add_theme_font_size_override("font_size", int(fs))
	var hs: Vector2 = _hint.get_combined_minimum_size()
	if hs.x > max_w and hs.x > 1.0:
		fs = maxf(fs * (max_w / hs.x), 10.0)
		_hint_label.add_theme_font_size_override("font_size", int(fs))
		hs = _hint.get_combined_minimum_size()
	_hint.size = Vector2(minf(hs.x, max_w), hs.y)
	# 提示条：贴着左下角（方向键那个位置）。方向键开着时抬到它上方。
	# 为什么不做水平居中：横屏时正中就是棋盘，提示会把棋盘和目标格都盖住。
	var above: float = (pad + margin + 10.0) if _pad_enabled else 0.0
	var hint_y: float = vp.y - sb - margin - above - hs.y
	_hint.position = Vector2(sl + margin, maxf(hint_y, st + 8.0))


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
	if _hint_timer > 0.0:
		_hint_timer -= delta
		if _hint_timer <= 0.0:
			dismiss_swipe_hint()
	_update_flash(delta)


# ── 拖动（唯一的入口：手指按下 → 拖动 → 抬手）──────────
#
# 对外暴露成三个方法而不是只吃输入事件，有两个好处：
#   1) 测试可以直接喂坐标序列，不用构造 InputEvent（手势的边界靠断言钉住）
#   2) 以后要加"屏幕任意处拖动"之外的入口（比如手柄触摸板）不用改这里

func drag_begin(pos: Vector2) -> void:
	if _tracker == null:
		# 相机还没把方向注入进来时（例如刚进对局的第一帧）退回默认值，
		# 否则那一瞬间的滑动会静默失效 —— 玩家只会觉得"有时不灵"。
		_tracker = GestureTracker.new(_screen_dirs if not _screen_dirs.is_empty() else LAYOUT.DEFAULT_SCREEN_DIRS)
	_tracker.begin(pos)
	_drag_begin = pos
	_drag_pos = pos
	_drag_moved = false


# 返回本次是否触发了一次移动（并已通过 direction 信号发出）
func drag_move(pos: Vector2) -> bool:
	if _tracker == null or not _tracker.active:
		return false
	if not _drag_moved and pos.distance_to(_drag_begin) > TAP_SLOP:
		_drag_moved = true
	if _drag_moved:
		# 拖动不再算"点按"：吃掉事件，免得同一根手指又把下面的方向键按下去。
		# 这里在 _input 阶段（早于 GUI 处理），所以按钮收不到后续事件。
		var vp := get_viewport()
		if vp != null:
			vp.set_input_as_handled()
	_drag_pos = pos
	var d: Vector3i = _tracker.feed(pos)
	if d != Vector3i.ZERO:
		_emit_dir(d)
		return true
	return false


func drag_end() -> void:
	if _tracker != null:
		_tracker.cancel()



func _emit_dir(d: Vector3i) -> void:
	# 所有方向输入的唯一出口：滑动与方向键都从这里走
	if d == Vector3i.ZERO:
		return
	if _tracker != null:
		_tracker.prev = d     # 粘滞方向跟着玩家最后一次意图走
	_flash[d] = FLASH_TIME
	direction.emit(d)


func _input(event: InputEvent) -> void:
	if not visible:
		return
	# 触摸设备会把触摸再模拟成鼠标事件；一旦见过真触摸就完全忽略鼠标，
	# 否则一次滑动会被解算两遍（方块会莫名滚两格）。
	if event is InputEventScreenTouch:
		_has_touch = true
		if event.pressed:
			if _tracker != null and _tracker.active:
				return                 # 只认第一根手指：多指不会打乱锚点
			drag_begin(event.position)
		else:
			drag_end()
		return
	if event is InputEventScreenDrag:
		_has_touch = true
		drag_move(event.position)
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if _has_touch:
			return
		if event.pressed:
			drag_begin(event.position)
		else:
			drag_end()
		return
	if event is InputEventMouseMotion and not _has_touch:
		if event.button_mask & MOUSE_BUTTON_MASK_LEFT:
			drag_move(event.position)


# ── 视觉反馈 ───────────────────────────────────────────

func _update_flash(delta: float) -> void:
	if _flash.is_empty():
		return
	# 先老化再应用：闪烁只影响颜色，不改变按钮的可用状态
	for d in _flash.keys():
		var left: float = float(_flash[d]) - delta
		if left <= 0.0:
			_flash.erase(d)
		else:
			_flash[d] = left
	for i in range(_dir_buttons.size()):
		var b: Button = _dir_buttons[i]
		var on: bool = _flash.has(_btn_dirs[i])
		b.modulate = Color(1.10, 1.16, 1.28) if on else Color.WHITE
