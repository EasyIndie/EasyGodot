# level_select.gd — 关卡选择界面（CanvasLayer 覆盖层，纯代码构建）。
#
# 与规则层/内容来源解耦：只接收「关卡元数据数组 + Progress」，不自己读目录，
# 换游戏或换关卡来源都不用改这里。
#
# 卡片状态：
#   锁定   → 前序关卡未通关（disabled，键盘导航会自动跳过）
#   已通关 → 显示玩家最佳步数
#   可挑战 → 显示参考（最优）步数
extends CanvasLayer

const Leaderboard = preload("res://meta/leaderboard.gd")

signal level_chosen(index: int)
signal closed
signal reset_requested

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

var _progress = null          # meta/progress.gd 实例
var _entries: Array = []      # 关卡元数据（open_with 传入）
var _keys: Array = []         # 关卡 key（与 entries 顺序一致）
var _cards: Array = []
var _grid: GridContainer
var _subtitle: Label
var _detail: Label
var _hint: Label
var _reset_btn: Button
var _confirm_reset: bool = false
var _confirm_timer: float = 0.0
var _current: int = 0


func _ready() -> void:
	layer = 20  # 盖在 HUD / 过渡层之上
	visible = false

	var shade := ColorRect.new()
	shade.color = Color(0.03, 0.04, 0.08, 0.95)
	shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	shade.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(shade)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.add_child(box)

	var title := Label.new()
	title.text = "选择关卡"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 30)
	title.add_theme_color_override("font_color", Color(0.94, 0.96, 1.0))
	box.add_child(title)

	_subtitle = Label.new()
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
	_detail.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_detail.add_theme_font_size_override("font_size", 14)
	_detail.add_theme_color_override("font_color", FG_OPT)
	box.add_child(_detail)

	_hint = Label.new()
	_hint.text = "← → ↑ ↓ 选择     Enter / 点击 开始     Esc 返回"
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint.add_theme_font_size_override("font_size", 14)
	_hint.add_theme_color_override("font_color", FG_DIM)
	box.add_child(_hint)

	_reset_btn = Button.new()
	_reset_btn.text = "重置进度"
	_reset_btn.flat = true
	_reset_btn.focus_mode = Control.FOCUS_NONE
	_reset_btn.add_theme_font_size_override("font_size", 13)
	_reset_btn.add_theme_color_override("font_color", FG_DIM)
	_reset_btn.add_theme_color_override("font_hover_color", Color(1.0, 0.55, 0.55))
	_reset_btn.pressed.connect(_on_reset_pressed)
	box.add_child(_reset_btn)


# ── 对外 ───────────────────────────────────────────────

func open_with(entries: Array, p_progress, p_current: int = 0) -> void:
	_progress = p_progress
	_current = clampi(p_current, 0, maxi(entries.size() - 1, 0))
	_keys.clear()
	for e in entries:
		_keys.append(str(e["key"]))

	for c in _cards:
		_grid.remove_child(c)
		c.free()   # 立即释放：避免连续 open_with 时旧卡片残留一帧
	_cards.clear()
	_entries = entries
	for i in range(entries.size()):
		var card := _make_card(entries[i], i)
		_grid.add_child(card)
		_cards.append(card)

	_subtitle.text = Leaderboard.summary_text(Leaderboard.summary(_progress, entries))
	_show_detail(_current)
	_set_confirm(false)
	visible = true
	if _cards.size() > 0:
		_cards[clampi(_current, 0, _cards.size() - 1)].grab_focus()


func close() -> void:
	if not visible:
		return
	visible = false
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
	shape.text = "方块" if str(entry.get("shape", "")) == "cube" else "骨牌"
	shape.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	shape.add_theme_font_size_override("font_size", 11)
	shape.add_theme_color_override("font_color", FG_DIM)
	shape.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(shape)

	var status := Label.new()
	status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	status.add_theme_font_size_override("font_size", 12)
	if not unlocked:
		status.text = "锁定"
		status.add_theme_color_override("font_color", FG_DIM)
	elif done:
		status.text = "最佳 %d" % best
		status.add_theme_color_override("font_color", FG_DONE)
	elif optimal > 0:
		status.text = "参考 %d" % optimal
		status.add_theme_color_override("font_color", FG_OPT)
	else:
		status.text = "未通关"
		status.add_theme_color_override("font_color", FG_OPT)
	status.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(status)
	return b


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


func _on_reset_pressed() -> void:
	if not _confirm_reset:
		_set_confirm(true)
		return
	_set_confirm(false)
	reset_requested.emit()


func _set_confirm(on: bool) -> void:
	_confirm_reset = on
	_reset_btn.text = "再点一次确认重置!" if on else "重置进度"


func _process(delta: float) -> void:
	# 确认状态 3 秒后自动取消，避免误触
	if _confirm_reset:
		_confirm_timer += delta
		if _confirm_timer > 3.0:
			_confirm_timer = 0.0
			_set_confirm(false)
	elif _confirm_timer != 0.0:
		_confirm_timer = 0.0
