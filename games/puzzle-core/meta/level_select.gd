# level_select.gd — 关卡选择界面（CanvasLayer 覆盖层，纯代码构建）。
#
# 与规则层/内容来源解耦：只接收「关卡元数据数组 + Progress」，不自己读目录，
# 换游戏或换关卡来源都不用改这里。
#
# 卡片状态：
#   锁定   → 前序关卡未通关（disabled，键盘导航会自动跳过）
#   本轮已通关 → 显示玩家最佳步数（亮）
#   历史通关过 → 同样显示最佳步数（暗）：记录还在，只是本轮没重打
#   可挑战 → 显示参考（最优）步数
extends CanvasLayer

const I18n = preload("res://meta/i18n.gd")

const Leaderboard = preload("res://meta/leaderboard.gd")
const UiLayout = preload("res://meta/ui_layout.gd")
const Shapes = preload("res://core/shapes.gd")

signal level_chosen(index: int)
signal theme_requested
signal language_requested
signal closed
signal reset_requested
signal ghost_toggled(on: bool)
signal pad_toggled(on: bool)
signal share_requested(index: int)
signal celebration_requested   # 「回顾通关」：全部通关后想再看一次庆祝动画

const COLS := 5
const CARD := Vector2(112.0, 86.0)
const CARD_BG := Color(0.10, 0.13, 0.20, 0.92)
const CARD_BG_LOCKED := Color(0.08, 0.09, 0.13, 0.75)
const CARD_BG_HOVER := Color(0.17, 0.22, 0.34, 0.96)
const EDGE := Color(1.0, 1.0, 1.0, 0.10)
const EDGE_HI := Color(0.55, 0.75, 1.0, 0.85)
const FG := Color(0.88, 0.91, 0.98)
const FG_DIM := Color(0.44, 0.47, 0.57)
const FG_DONE := Color(0.42, 0.88, 0.60)
const FG_OPT := Color(0.62, 0.70, 0.86)
const FG_EVER := Color(0.34, 0.58, 0.44)   # 历史通关过但本轮未通关（暗一档）

var _progress = null          # meta/progress.gd 实例
var _entries: Array = []      # 关卡元数据（open_with 传入）
var _keys: Array = []         # 关卡 key（与 entries 顺序一致）
var _cards: Array = []
var _card_parts: Array = []   # 与 _cards 同序：{num, shape, status} 三个标签（供缩放字号）
var _grid: GridContainer
var _title: Label
var _subtitle: Label
var _detail: Label
# 安全区域（刘海 / 灵动岛 / 底部手势条）：由 main.gd 注入，_apply_layout 负责避让
var _insets: Dictionary = {"left": 0.0, "top": 0.0, "right": 0.0, "bottom": 0.0}
var _margin: MarginContainer = null
var _hint: Label
var _reset_btn: Button
var _ghost_btn: Button
var _theme_btn: Button
var _language_btn: Button
var _pad_btn: Button
var _share_btn: Button
var _ghost_on: bool = false
var _pad_on: bool = false
var _back_btn: Button
var _celebrate_btn: Button
var touch_mode: bool = false   # 由 main 设置：触屏下提示文案与按钮尺寸要适配
var _confirm_reset: bool = false
var _confirm_timer: float = 0.0
var _current: int = 0
var _content: VBoxContainer
var _center: CenterContainer
var _privacy: AcceptDialog
var _scroll_touch: int = -1
var _scroll_mouse := false
var _scroll_start := Vector2.ZERO
var _scroll_origin := 0
var _scroll_dragged := false
var _scroll_button: Button = null
var _seen_touch := false
var _scroll: ScrollContainer


func _ready() -> void:
	layer = 20  # 盖在 HUD / 过渡层之上
	visible = false
	set_process_input(false)

	var shade := ColorRect.new()
	shade.color = Color(0.03, 0.04, 0.08, 0.95)
	shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	shade.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(shade)

	# 外层 MarginContainer 负责避开安全区，内层 CenterContainer 负责居中 ——
	# 分两层是因为「居中」和「留边」是两个正交的约束，混在一起会互相打架。
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_margin = margin
	add_child(margin)

	var scroll := ScrollContainer.new()
	_scroll = scroll
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.follow_focus = true
	margin.add_child(scroll)
	var center := CenterContainer.new()
	_center = center
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	center.size_flags_vertical = Control.SIZE_EXPAND_FILL
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	scroll.add_child(center)

	var box := VBoxContainer.new()
	_content = box
	box.add_theme_constant_override("separation", 10)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.add_child(box)

	var title := Label.new()
	title.text = I18n.t("选择关卡")
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 30)
	title.add_theme_color_override("font_color", Color(0.94, 0.96, 1.0))
	box.add_child(title)
	_title = title

	_subtitle = Label.new()
	_subtitle.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_subtitle.add_theme_font_size_override("font_size", 16)
	_subtitle.add_theme_color_override("font_color", FG_OPT)
	box.add_child(_subtitle)

	_grid = GridContainer.new()
	_grid.columns = COLS
	_grid.add_theme_constant_override("h_separation", 8)
	_grid.add_theme_constant_override("v_separation", 8)
	box.add_child(_grid)

	_detail = Label.new()
	_detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_detail.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_detail.add_theme_font_size_override("font_size", 14)
	_detail.add_theme_color_override("font_color", FG_OPT)
	box.add_child(_detail)

	_hint = Label.new()
	_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint.add_theme_font_size_override("font_size", 14)
	_hint.add_theme_color_override("font_color", FG_DIM)
	box.add_child(_hint)

	# 底部按钮行。
	# **必须有可点的「返回」**：桌面靠 Esc，但触屏没有键盘，
	# 之前只能进不能出，整个选关页面就变成了死胡同。
	var row := HFlowContainer.new()
	row.alignment = FlowContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("h_separation", 12)
	row.add_theme_constant_override("v_separation", 8)
	box.add_child(row)

	_back_btn = Button.new()
	_back_btn.text = I18n.t("返回游戏")
	_back_btn.focus_mode = Control.FOCUS_NONE
	_back_btn.add_theme_color_override("font_color", FG)
	_back_btn.add_theme_color_override("font_hover_color", Color(1, 1, 1))
	_back_btn.add_theme_stylebox_override("normal", _sb(CARD_BG_HOVER, EDGE_HI, 1))
	_back_btn.add_theme_stylebox_override("hover", _sb(CARD_BG_HOVER, EDGE_HI, 2))
	_back_btn.add_theme_stylebox_override("pressed", _sb(CARD_BG_HOVER, EDGE_HI, 2))
	_back_btn.pressed.connect(func() -> void: close())
	row.add_child(_back_btn)

	# 「回顾通关」：只在全部通关后出现。庆祝动画不该是一次性的，
	# 但也不该强行弹给玩家（那会变成“每次通关都被恭喜”）。
	_celebrate_btn = Button.new()
	_celebrate_btn.text = I18n.t("回顾通关")
	_celebrate_btn.visible = false
	_celebrate_btn.focus_mode = Control.FOCUS_NONE
	_celebrate_btn.add_theme_color_override("font_color", Color(0.82, 0.92, 1.0))
	_celebrate_btn.add_theme_color_override("font_hover_color", Color(1, 1, 1))
	_celebrate_btn.add_theme_stylebox_override("normal", _sb(CARD_BG, EDGE, 1))
	_celebrate_btn.add_theme_stylebox_override("hover", _sb(CARD_BG_HOVER, EDGE_HI, 1))
	_celebrate_btn.pressed.connect(func() -> void: celebration_requested.emit())
	row.add_child(_celebrate_btn)

	_share_btn = Button.new()
	_share_btn.text = I18n.t("分享本关")
	_share_btn.flat = true
	_share_btn.focus_mode = Control.FOCUS_NONE
	_share_btn.add_theme_font_size_override("font_size", 14)
	_share_btn.add_theme_color_override("font_color", FG_DIM)
	_share_btn.add_theme_color_override("font_hover_color", Color(0.72, 1.0, 0.86))
	_share_btn.pressed.connect(func() -> void: share_requested.emit(_current))
	row.add_child(_share_btn)

	_ghost_btn = Button.new()
	_ghost_btn.text = I18n.t("影子: 关")
	_ghost_btn.flat = true
	_ghost_btn.focus_mode = Control.FOCUS_NONE
	_ghost_btn.add_theme_font_size_override("font_size", 14)
	_ghost_btn.add_theme_color_override("font_color", FG_DIM)
	_ghost_btn.add_theme_color_override("font_hover_color", Color(0.72, 0.90, 1.0))
	_ghost_btn.pressed.connect(_on_ghost_pressed)
	row.add_child(_ghost_btn)

	# 方向键开关：手势是主要输入，方向键是"备选操作方式"。
	# 放在选关界面而不是游戏画面里 —— 游戏画面上的每一样东西都必须是常用的。
	_pad_btn = Button.new()
	_pad_btn.text = I18n.t("方向键: 关")
	_pad_btn.flat = true
	_pad_btn.focus_mode = Control.FOCUS_NONE
	_pad_btn.add_theme_font_size_override("font_size", 14)
	_pad_btn.add_theme_color_override("font_color", FG_DIM)
	_pad_btn.add_theme_color_override("font_hover_color", Color(0.72, 0.90, 1.0))
	_pad_btn.pressed.connect(_on_pad_pressed)
	row.add_child(_pad_btn)

	_reset_btn = Button.new()
	_reset_btn.text = I18n.t("重置进度")
	_reset_btn.flat = true
	_reset_btn.focus_mode = Control.FOCUS_NONE
	_reset_btn.add_theme_font_size_override("font_size", 14)
	_reset_btn.add_theme_color_override("font_color", FG_DIM)
	_reset_btn.add_theme_color_override("font_hover_color", Color(1.0, 0.55, 0.55))
	_reset_btn.pressed.connect(_on_reset_pressed)
	row.add_child(_reset_btn)

	_theme_btn = Button.new()
	_theme_btn.custom_minimum_size.y = 44.0
	_theme_btn.pressed.connect(func() -> void: theme_requested.emit())
	box.add_child(_theme_btn)
	_language_btn = Button.new()
	_language_btn.custom_minimum_size.y = 44.0
	_language_btn.pressed.connect(func() -> void: language_requested.emit())
	box.add_child(_language_btn)

	var privacy_btn := Button.new()
	privacy_btn.text = I18n.t("隐私政策")
	privacy_btn.flat = true
	privacy_btn.custom_minimum_size.y = 44.0
	privacy_btn.pressed.connect(func() -> void: _privacy.popup_centered_clamped(Vector2i(340, 330), 0.85))
	box.add_child(privacy_btn)
	_privacy = AcceptDialog.new()
	_privacy.title = I18n.t("隐私政策")
	_privacy.dialog_autowrap = true
	_privacy.dialog_text = I18n.t("本机保存进度、成绩、回放和偏好；游戏不上传记录。\n\n无账号、广告或追踪 SDK。\n\n可重置进度删除记录。分享由你主动发送。\n\n完整政策、Web 访问日志说明与支持见在线页面。")
	_privacy.get_label().autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	_privacy.get_ok_button().text = I18n.t("关闭")
	_privacy.add_button(I18n.t("在线政策"), false, "policy")
	_privacy.custom_action.connect(func(action: String) -> void:
		if action == "policy":
			OS.shell_open("https://easyindie.github.io/EasyGodot/privacy.html"))
	add_child(_privacy)

	get_viewport().size_changed.connect(_apply_layout)


# ── 对外 ───────────────────────────────────────────────

func open_with(entries: Array, p_progress, p_current: int = 0) -> void:
	_theme_btn.text = I18n.t("主题：%s") % preload("res://meta/visual_theme.gd").title(p_progress.visual_theme())
	_language_btn.text = I18n.t("语言：%s") % I18n.preference_title(p_progress.language_preference())
	_progress = p_progress
	_current = clampi(p_current, 0, maxi(entries.size() - 1, 0))
	_keys.clear()
	for e in entries:
		_keys.append(str(e["key"]))
	# 「回顾通关」只在全部通关后出现（庆祝动画不该是一次性的，但也不该强行弹给玩家）
	if _celebrate_btn != null:
		_celebrate_btn.visible = entries.size() > 0 and p_progress != null \
			and p_progress.completed_count() >= entries.size()
	if p_progress != null:
		set_ghost_state(p_progress.ghost_enabled())
		set_pad_state(p_progress.pad_enabled())

	for c in _cards:
		_grid.remove_child(c)
		c.free()   # 立即释放：避免连续 open_with 时旧卡片残留一帧
	_cards.clear()
	_card_parts.clear()
	_entries = entries
	for i in range(entries.size()):
		var card := _make_card(entries[i], i)
		_grid.add_child(card)
		_cards.append(card)

	# 汇总文案的「本轮 / 曾经」口径统一在 Leaderboard.summary_text 里处理（只留一处真相）
	_subtitle.text = Leaderboard.summary_text(Leaderboard.summary(_progress, entries))
	_apply_layout()
	_show_detail(_current)
	_set_confirm(false)
	visible = true
	set_process_input(true)
	if _cards.size() > 0:
		_cards[clampi(_current, 0, _cards.size() - 1)].grab_focus()
	if _current == 0:
		_scroll.set_deferred("scroll_vertical", 0)


func close() -> void:
	if not visible:
		return
	visible = false
	set_process_input(false)
	_cancel_scroll_drag()
	_set_confirm(false)
	closed.emit()


func is_open() -> bool:
	return visible


# 测试用只读接口（不暴露内部结构）
func card_count() -> int:
	return _cards.size()


func card_enabled(index: int) -> bool:
	if index < 0 or index >= _cards.size():
		return false
	return not _cards[index].disabled


# ── 卡片 ───────────────────────────────────────────────

func _make_card(entry: Dictionary, index: int) -> Button:
	var key: String = str(entry["key"])
	var unlocked: bool = _progress.is_unlocked(index, _keys)
	var done: bool = _progress.is_completed(key)
	var ever: bool = _progress.has_ever_cleared(key)
	var best: int = _progress.best_moves(key)
	var optimal: int = int(entry.get("optimal", -1))

	var b := Button.new()
	b.custom_minimum_size = CARD
	b.focus_mode = Control.FOCUS_ALL if unlocked else Control.FOCUS_NONE
	b.disabled = not unlocked
	b.add_theme_stylebox_override("normal", _sb(CARD_BG, EDGE, 1))
	b.add_theme_stylebox_override("hover", _sb(CARD_BG_HOVER, EDGE_HI, 1))
	b.add_theme_stylebox_override("pressed", _sb(CARD_BG_HOVER, EDGE_HI, 2))
	b.add_theme_stylebox_override("focus", _sb(Color(0, 0, 0, 0), EDGE_HI, 2))
	b.add_theme_stylebox_override("disabled", _sb(CARD_BG_LOCKED, EDGE, 1))
	b.pressed.connect(_on_card_pressed.bind(index))
	# 焦点/悬停时在底部显示该关详情（含本机榜）
	b.focus_entered.connect(_show_detail.bind(index))
	b.mouse_entered.connect(_show_detail.bind(index))

	var col := VBoxContainer.new()
	col.set_anchors_preset(Control.PRESET_FULL_RECT)
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_theme_constant_override("separation", 1)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	b.add_child(col)

	var num := Label.new()
	num.text = "%02d" % (index + 1)
	num.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	num.add_theme_font_size_override("font_size", 23)
	num.add_theme_color_override("font_color", FG if unlocked else FG_DIM)
	num.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(num)

	var shape := Label.new()
	# 形状名统一走注册表，这里不再有任何 if id == ...（加形状只需改 core/shapes.gd）
	shape.text = str(entry.get("title", Shapes.display_name(str(entry.get("shape", "domino")))))
	shape.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	shape.max_lines_visible = 2
	shape.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	shape.add_theme_font_size_override("font_size", 11)
	shape.add_theme_color_override("font_color", FG_DIM)
	shape.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(shape)

	var status := Label.new()
	status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	status.add_theme_font_size_override("font_size", 12)
	if not unlocked:
		status.text = I18n.t("锁定")
		status.add_theme_color_override("font_color", FG_DIM)
	elif done:
		status.text = I18n.t("最佳 %d") % best
		status.add_theme_color_override("font_color", FG_DONE)
	elif ever:
		# 历史通关过、本轮还没重打：记录照旧展示，但颜色暗一档表示“本轮未通关”。
		# （「再玩一遍」清的是本轮进度而不是记录，卡片上必须看得出来）
		status.text = I18n.t("最佳 %d") % best
		status.add_theme_color_override("font_color", FG_EVER)
	elif optimal > 0:
		status.text = I18n.t("参考 %d") % optimal
		status.add_theme_color_override("font_color", FG_OPT)
	else:
		status.text = I18n.t("未通关")
		status.add_theme_color_override("font_color", FG_OPT)
	status.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(status)
	_card_parts.append({"num": num, "shape": shape, "status": status})
	return b


func set_safe_insets(insets: Dictionary) -> void:
	# 由 main.gd 注入；选关界面同样必须避开刘海/底部手势条
	_insets = insets
	_apply_layout()


func safe_insets() -> Dictionary:
	return _insets.duplicate()


func _apply_layout() -> void:
	_cancel_scroll_drag()
	# 按视口自适应：列数随宽度降级、卡片与字号按可用宽度反算（窄屏/竖屏不溢出）
	var vp: Vector2 = get_viewport().get_visible_rect().size
	# 避开安全区：把 inset 转成内容边距，而不是把控件硬挪（否则会与居中布局打架）
	if _margin != null:
		_margin.add_theme_constant_override("margin_left", int(float(_insets.get("left", 0.0))) + 12)
		_margin.add_theme_constant_override("margin_right", int(float(_insets.get("right", 0.0))) + 12)
		_margin.add_theme_constant_override("margin_top", int(float(_insets.get("top", 0.0))) + 12)
		_margin.add_theme_constant_override("margin_bottom", int(float(_insets.get("bottom", 0.0))) + 12)
	var available: Vector2 = vp - Vector2(float(_insets.get("left", 0.0)) + float(_insets.get("right", 0.0)) + 24.0,
		float(_insets.get("top", 0.0)) + float(_insets.get("bottom", 0.0)) + 24.0)
	_content.custom_minimum_size.x = minf(maxf(available.x * 0.94, 0.0), 608.0)
	_center.custom_minimum_size.x = maxf(available.x, 0.0)
	var g: Dictionary = UiLayout.level_grid(available, maxi(_entries.size(), 1))
	_grid.columns = int(g["columns"])
	var card: Vector2 = g["card"]
	for i in range(_cards.size()):
		_cards[i].custom_minimum_size = card
		var p: Dictionary = _card_parts[i]
		p["num"].add_theme_font_size_override("font_size", int(card.x * 0.205))
		p["shape"].add_theme_font_size_override("font_size", int(card.x * 0.100))
		p["status"].add_theme_font_size_override("font_size", int(card.x * 0.108))
	var k: float = clampf(vp.x / 1280.0, 0.62, 1.0)
	_title.add_theme_font_size_override("font_size", int(30.0 * k))
	_subtitle.add_theme_font_size_override("font_size", int(16.0 * k))
	_detail.add_theme_font_size_override("font_size", int(14.0 * k))
	_hint.add_theme_font_size_override("font_size", int(14.0 * k))
	# 提示文案：触屏上没有键盘，不能写 Esc / Enter
	if touch_mode:
		_hint.text = I18n.t("点按卡片开始　·　底部「返回游戏」关闭")
	else:
		_hint.text = I18n.t("← → ↑ ↓ 选择     Enter / 点击 开始     Esc 返回")
	# 按钮：触屏要够大好点（高度按视口自适应，并留出最小可点面积）
	var btn_h: float = clampf(vp.y * 0.055, 44.0 if touch_mode else 34.0, 52.0)
	for button in [_share_btn, _ghost_btn, _pad_btn]:
		button.custom_minimum_size.y = btn_h
	_back_btn.custom_minimum_size = Vector2(btn_h * 3.4, btn_h)
	_back_btn.add_theme_font_size_override("font_size", int(btn_h * 0.42))
	_celebrate_btn.custom_minimum_size = Vector2(btn_h * 2.9, btn_h)
	_celebrate_btn.add_theme_font_size_override("font_size", int(btn_h * 0.38))
	_reset_btn.custom_minimum_size = Vector2(btn_h * 2.6, btn_h)
	_reset_btn.add_theme_font_size_override("font_size", int(btn_h * 0.38))


func back_button() -> Button:
	# 供测试验证「可点返回」确实接线（触屏没有 Esc，这是唯一出口）
	return _back_btn


func celebrate_button() -> Button:
	# 供测试验证「回顾通关」的可见性与接线
	return _celebrate_btn


func hint_text() -> String:
	return _hint.text


func _show_detail(index: int) -> void:
	if _progress == null:
		return
	_detail.text = Leaderboard.detail_text(_entries, _progress, index)


func _sb(bg: Color, border: Color, bw: int) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.set_corner_radius_all(12)
	s.set_border_width_all(bw)
	s.border_color = border
	s.content_margin_left = 4.0
	s.content_margin_right = 4.0
	s.content_margin_top = 4.0
	s.content_margin_bottom = 4.0
	return s


func _on_card_pressed(index: int) -> void:
	if index < 0 or index >= _keys.size():
		return
	if not _progress.is_unlocked(index, _keys):
		return
	level_chosen.emit(index)


# ── 输入 / 重置确认 ────────────────────────────────────

func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE:
			close()
			get_viewport().set_input_as_handled()


func share_button_text() -> String:
	return _share_btn.text if _share_btn != null else ""


func set_share_button_text(t: String) -> void:
	# 复制成功后按钮自己说一声（否则玩家不知道点没点成功）
	if _share_btn != null:
		_share_btn.text = t


func share_button() -> Button:
	return _share_btn


func ghost_button_text() -> String:
	# 「上次的走法」= 把自己的最佳记录当影子滚一遍（记忆辅助，不是比赛）
	return I18n.t("影子: ") + (I18n.t("开") if _ghost_on else I18n.t("关"))


func set_ghost_state(on: bool) -> void:
	_ghost_on = on
	if _ghost_btn != null:
		_ghost_btn.text = ghost_button_text()


func pad_button_text() -> String:
	# 与影子同款：文字直接说清当前状态（"开/关"比一个开关图标更不容易误读）
	return I18n.t("方向键: ") + (I18n.t("开") if _pad_on else I18n.t("关"))


func set_pad_state(on: bool) -> void:
	_pad_on = on
	if _pad_btn != null:
		_pad_btn.text = pad_button_text()


func _on_pad_pressed() -> void:
	_pad_on = not _pad_on
	set_pad_state(_pad_on)
	pad_toggled.emit(_pad_on)


func _on_ghost_pressed() -> void:
	_ghost_on = not _ghost_on
	set_ghost_state(_ghost_on)
	ghost_toggled.emit(_ghost_on)


func _on_reset_pressed() -> void:
	if not _confirm_reset:
		_set_confirm(true)
		return
	_set_confirm(false)
	reset_requested.emit()


func _set_confirm(on: bool) -> void:
	_confirm_reset = on
	_reset_btn.text = I18n.t("再点一次确认重置!") if on else I18n.t("重置进度")


func _process(delta: float) -> void:
	# 确认状态 3 秒后自动取消，避免误触
	if _confirm_reset:
		_confirm_timer += delta
		if _confirm_timer > 3.0:
			_confirm_timer = 0.0
			_set_confirm(false)
	elif _confirm_timer != 0.0:
		_confirm_timer = 0.0


# 卡片按钮会消费 GUI 输入，因此在按钮之前接住拖动；短点按才交给原按钮动作。
# 滚轮和右侧滚动条继续由 ScrollContainer 原生处理。
func _input(event: InputEvent) -> void:
	if not visible or (_privacy != null and _privacy.visible):
		_cancel_scroll_drag()
		return
	if event is InputEventScreenTouch:
		_seen_touch = true
		if event.pressed:
			if _scroll_touch == -1 and _begin_scroll_drag(event.position):
				_scroll_touch = event.index
				get_viewport().set_input_as_handled()
		elif event.index == _scroll_touch:
			_end_scroll_drag(event.position, not event.canceled)
			get_viewport().set_input_as_handled()
		if _scroll_touch != -1:
			get_viewport().set_input_as_handled()
	elif event is InputEventScreenDrag:
		if event.index == _scroll_touch:
			_move_scroll_drag(event.position)
		if _scroll_touch != -1:
			get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if _seen_touch:
			var bar := _scroll.get_v_scroll_bar()
			if bar.visible and bar.get_global_rect().has_point(event.position):
				return
			get_viewport().set_input_as_handled()
			return
		if event.pressed:
			_scroll_mouse = _begin_scroll_drag(event.position)
			if _scroll_mouse:
				get_viewport().set_input_as_handled()
		elif _scroll_mouse:
			_end_scroll_drag(event.position)
			get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion and _scroll_mouse:
		_move_scroll_drag(event.position)
		get_viewport().set_input_as_handled()


func _begin_scroll_drag(pos: Vector2) -> bool:
	if not _scroll.get_global_rect().has_point(pos):
		return false
	var bar := _scroll.get_v_scroll_bar()
	if bar.visible and bar.get_global_rect().has_point(pos):
		return false
	_scroll_start = pos
	_scroll_origin = _scroll.scroll_vertical
	_scroll_dragged = false
	_scroll_button = null
	for node in _content.find_children("*", "Button", true, false):
		if node.is_visible_in_tree() and not node.disabled and node.get_global_rect().has_point(pos):
			_scroll_button = node
			node.set_pressed_no_signal(true)
			break
	return true


func _move_scroll_drag(pos: Vector2) -> void:
	if not _scroll_dragged and pos.distance_to(_scroll_start) >= 10.0:
		_scroll_dragged = true
		if is_instance_valid(_scroll_button):
			_scroll_button.set_pressed_no_signal(false)
	if _scroll_dragged:
		_scroll.scroll_vertical = _scroll_origin - int(pos.y - _scroll_start.y)


func _end_scroll_drag(pos: Vector2, allow_tap: bool = true) -> void:
	_move_scroll_drag(pos)
	var button := _scroll_button
	var tapped: bool = allow_tap and not _scroll_dragged and is_instance_valid(button) \
		and button.get_global_rect().has_point(pos)
	_cancel_scroll_drag()
	if tapped:
		button.pressed.emit()


func _cancel_scroll_drag() -> void:
	if is_instance_valid(_scroll_button):
		_scroll_button.set_pressed_no_signal(false)
	_scroll_button = null
	_scroll_touch = -1
	_scroll_mouse = false
	_scroll_dragged = false
