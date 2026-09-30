# ending.gd — 全部通关的庆祝界面（通关动画 + 祝贺 + 统计）。
#
# 为什么单独做一层，而不是在 HUD 上弹一句话：
#   20 关是**一个完整的旅程**，最后一关通关时如果只是照常滚到下一关（第 1 关），
#   玩家会以为游戏出 bug 了。所以要有一个明确的“结束”：
#   奖杯式标题 + 统计 + 撒花 + 明确的两个出口（再玩一次 / 回选关）。
#
# 与规则层解耦：只吃 `entries`（关卡元数据）和 `progress`（进度），
# 不碰 Board / State；因此可以在 headless 下完整单测。
extends CanvasLayer

signal restart_requested      # 回到第 1 关
signal select_requested       # 打开选关
signal closed

const LAYOUT = preload("res://meta/ui_layout.gd")
const Shapes = preload("res://core/shapes.gd")

const CONFETTI := 64          # 撒花片数（2D ColorRect，几乎不吃性能）
const CONFETTI_COLORS: Array = [
	Color(0.42, 0.86, 0.60), Color(1.00, 0.72, 0.30), Color(0.45, 0.72, 1.00),
	Color(1.00, 0.52, 0.62), Color(0.80, 0.62, 1.00), Color(1.00, 1.00, 0.80),
]

var _root: Control
var _dim: ColorRect
var _card: PanelContainer
var _title: Label
var _subtitle: Label
var _stats: VBoxContainer
var _buttons: HBoxContainer
var _confetti_root: Control
var _insets: Dictionary = {"left": 0.0, "top": 0.0, "right": 0.0, "bottom": 0.0}
var _open: bool = false
var _stat_lines: Array = []
var _tween: Tween


func _ready() -> void:
	layer = 25   # 盖在选关(20) 与过渡(10) 之上
	visible = false

	_root = Control.new()
	_root.name = "EndingRoot"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP   # 挡住底下的输入，避免误触棋盘
	add_child(_root)

	_dim = ColorRect.new()
	_dim.color = Color(0.02, 0.03, 0.06, 0.0)
	_dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_dim)

	# 撒花放在卡片**下面**（背景上飘落），再往上才是卡片
	_confetti_root = Control.new()
	_confetti_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_confetti_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.add_child(_confetti_root)

	_card = PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.08, 0.11, 0.18, 0.94)
	sb.set_corner_radius_all(22)
	sb.set_border_width_all(1)
	sb.border_color = Color(0.55, 0.78, 1.0, 0.35)
	sb.content_margin_left = 34.0
	sb.content_margin_right = 34.0
	sb.content_margin_top = 26.0
	sb.content_margin_bottom = 22.0
	_card.add_theme_stylebox_override("panel", sb)
	_card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_card)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 10)
	_card.add_child(col)

	_title = Label.new()
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title.text = "全部通关！"
	_title.add_theme_color_override("font_color", Color(0.98, 0.94, 0.75))
	col.add_child(_title)

	_subtitle = Label.new()
	_subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_subtitle.add_theme_color_override("font_color", Color(0.70, 0.82, 1.0))
	col.add_child(_subtitle)

	var sep := HSeparator.new()
	sep.modulate = Color(1, 1, 1, 0.18)
	col.add_child(sep)

	_stats = VBoxContainer.new()
	_stats.add_theme_constant_override("separation", 4)
	col.add_child(_stats)

	_buttons = HBoxContainer.new()
	_buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	_buttons.add_theme_constant_override("separation", 12)
	_buttons.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(_buttons)

	var again := _make_button("再玩一次")
	again.pressed.connect(func() -> void: restart_requested.emit())
	_buttons.add_child(again)
	var to_select := _make_button("回到选关")
	to_select.pressed.connect(func() -> void: select_requested.emit())
	_buttons.add_child(to_select)

	get_viewport().size_changed.connect(_apply_layout)
	_apply_layout()


# ── 对外 ───────────────────────────────────────────────

func open_with(entries: Array, progress) -> void:
	_open = true
	visible = true
	_subtitle.text = "%d / %d 关　·　恭喜你，滚方块大师" % [entries.size(), entries.size()]
	_build_stats(entries, progress)
	_apply_layout()
	_play_intro()


func close() -> void:
	_open = false
	visible = false
	_clear_confetti()
	if _tween != null and _tween.is_valid():
		_tween.kill()
	closed.emit()


func is_open() -> bool:
	return _open


func set_safe_insets(insets: Dictionary) -> void:
	_insets = insets
	_apply_layout()


func title_text() -> String:
	return _title.text


func subtitle_text() -> String:
	return _subtitle.text


func stat_lines() -> Array:
	return _stat_lines.duplicate()


func button_count() -> int:
	return _buttons.get_child_count()


func card_rect() -> Rect2:
	return Rect2(_card.position, _card.size)


func confetti_count() -> int:
	return _confetti_root.get_child_count()


func stats_text() -> String:
	# 让统计也能被“看见”地断言（人也能一眼读懂）
	var parts: Array = []
	for l in _stat_lines:
		parts.append(str(l))
	return "\n".join(parts)


# ── 内部 ───────────────────────────────────────────────

func _build_stats(entries: Array, progress) -> void:
	_stat_lines.clear()
	for c in _stats.get_children():
		_stats.remove_child(c)
		c.free()
	if progress == null:
		return
	var total: int = entries.size()
	var completed: int = 0
	var total_moves: int = 0
	var optimal_count: int = 0
	var best_sum: int = 0
	var shape_name: String = ""
	for e in entries:
		var key: String = str(e.get("key", ""))
		if not progress.is_completed(key):
			continue
		completed += 1
		var best: int = progress.best_moves(key)
		if best > 0:
			total_moves += best
			best_sum += best
		var opt: int = int(e.get("optimal", -1))
		if opt > 0 and best == opt:
			optimal_count += 1
		if shape_name == "":
			shape_name = Shapes.display_name(str(e.get("shape", "")))

	var rows: Array = [
		["通关", "%d / %d 关" % [completed, total]],
		["总步数", "%d 步" % total_moves],
		["达最优", "%d 关" % optimal_count],
	]
	if completed == total and optimal_count == total:
		rows.append(["评价", "全关最优　·　无可挑剔"])
	elif optimal_count * 2 >= maxi(completed, 1):
		rows.append(["评价", "相当漂亮"])
	else:
		rows.append(["评价", "通关达成"])
	for row in rows:
		_stat_lines.append("%s：%s" % [str(row[0]), str(row[1])])
		var line := Label.new()
		line.text = str(_stat_lines[_stat_lines.size() - 1])
		line.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		line.add_theme_color_override("font_color", Color(0.84, 0.90, 1.0))
		_stats.add_child(line)


func _play_intro() -> void:
	# 进场：暗幕淡入 → 卡片回弹放大 → 撒花
	_dim.color.a = 0.0
	_card.modulate.a = 0.0
	_card.pivot_offset = Vector2.ZERO
	_title.scale = Vector2.ONE
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = create_tween()
	_tween.set_parallel(true)
	_tween.tween_property(_dim, "color:a", 1.0, 0.35)
	_tween.tween_property(_card, "modulate:a", 1.0, 0.3)
	_tween.tween_property(_title, "scale", Vector2.ONE, 0.5).from(Vector2(0.6, 0.6)) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_spawn_confetti()


func _spawn_confetti() -> void:
	_clear_confetti()
	var vp: Vector2 = get_viewport().get_visible_rect().size
	for i in range(CONFETTI):
		var c := ColorRect.new()
		c.color = CONFETTI_COLORS[i % CONFETTI_COLORS.size()]
		var w: float = 5.0 + float(i % 4) * 2.0
		c.size = Vector2(w, w * 1.6)
		c.position = Vector2(
			(vp.x - w) * _hash01(i * 7 + 1),
			-vp.y * 0.25 * _hash01(i * 13 + 3) - 20.0)
		c.mouse_filter = Control.MOUSE_FILTER_IGNORE
		c.modulate.a = 0.0
		_confetti_root.add_child(c)
		var dur: float = 2.2 + 1.8 * _hash01(i * 29 + 5)
		var tw := create_tween()
		tw.set_parallel(true)
		tw.tween_property(c, "modulate:a", 1.0, 0.4)
		tw.tween_property(c, "position:y", vp.y + 30.0, dur) \
			.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
		tw.tween_property(c, "position:x", c.position.x + (_hash01(i * 17 + 9) - 0.5) * 140.0, dur)
		tw.tween_property(c, "rotation", (_hash01(i * 23 + 11) - 0.5) * 12.0, dur)


func _clear_confetti() -> void:
	if _confetti_root == null:
		return
	for c in _confetti_root.get_children():
		_confetti_root.remove_child(c)
		c.free()


func _hash01(n: int) -> float:
	# 确定性伪随机（不用 RandomNumberGenerator：撒花每次都应差不多好看）
	var x: float = sin(float(n) * 12.9898) * 43758.5453
	return x - floor(x)


func _apply_layout() -> void:
	if _card == null:
		return
	var vp: Vector2 = get_viewport().get_visible_rect().size
	var scale: float = clampf(minf(vp.x, vp.y) / 720.0, 0.62, 1.35)
	_title.add_theme_font_size_override("font_size", int(46.0 * scale))
	_subtitle.add_theme_font_size_override("font_size", int(17.0 * scale))
	for l in _stats.get_children():
		if l is Label:
			l.add_theme_font_size_override("font_size", int(16.0 * scale))
	for b in _buttons.get_children():
		if b is Button:
			b.custom_minimum_size = Vector2(150.0 * scale, 46.0 * scale)
			b.add_theme_font_size_override("font_size", int(17.0 * scale))

	var size: Vector2 = _card.get_combined_minimum_size()
	_card.size = size
	var sl: float = float(_insets.get("left", 0.0))
	var sr: float = float(_insets.get("right", 0.0))
	var st: float = float(_insets.get("top", 0.0))
	var sb: float = float(_insets.get("bottom", 0.0))
	var avail: Vector2 = vp - Vector2(sl + sr, st + sb)
	var pos := Vector2(sl, st) + (avail - size) * 0.5
	# 太小的屏幕上，卡片可能比可用区域还高：允许贴顶，但绝不越过安全区
	pos.y = clampf(pos.y, st + 6.0, maxf(st + 6.0, vp.y - sb - size.y - 6.0))
	pos.x = clampf(pos.x, sl + 6.0, maxf(sl + 6.0, vp.x - sr - size.x - 6.0))
	_card.position = pos


func _make_button(text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.mouse_filter = Control.MOUSE_FILTER_STOP
	b.add_theme_color_override("font_color", Color(0.92, 0.96, 1.0))
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color(0.16, 0.24, 0.38, 0.95)
	normal.set_corner_radius_all(12)
	normal.set_border_width_all(1)
	normal.border_color = Color(0.55, 0.78, 1.0, 0.45)
	var hover := normal.duplicate()
	hover.bg_color = Color(0.22, 0.34, 0.52, 1.0)
	var pressed := normal.duplicate()
	pressed.bg_color = Color(0.30, 0.46, 0.68, 1.0)
	b.add_theme_stylebox_override("normal", normal)
	b.add_theme_stylebox_override("hover", hover)
	b.add_theme_stylebox_override("pressed", pressed)
	return b
