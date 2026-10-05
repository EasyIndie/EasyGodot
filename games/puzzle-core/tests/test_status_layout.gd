# 通关文本在手机安全区内完整显示，不得以单行最小宽度撑开窗口。
extends SceneTree

var checks := 0
var failures := 0

func _init() -> void:
	ProjectSettings.set_setting("puzzle/system_locale_override", "zh")
	call_deferred("_run")

func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error(message)

func _run() -> void:
	var save_path := "user://test_status_layout.json"
	ProjectSettings.set_setting("puzzle/progress_path", save_path)
	root.size = Vector2i(360, 800)
	var scene = load("res://scenes/main.tscn").instantiate()
	root.add_child(scene)
	await process_frame
	scene._touch_active = true
	scene._query_string = "?touch=1"
	scene._apply_touch_visibility()
	scene._do_load(1)
	scene.game.won_flag = true
	var results := [
		{"move_count": 3, "time_ms": 12800, "first_clear": true, "improved": false},
		{"move_count": 123, "time_ms": 654321, "first_clear": false, "improved": true, "prev_best": 999},
		{"move_count": 3, "time_ms": 12800, "first_clear": false, "improved": false, "time_improved": true, "prev_best_time": 654321},
	]
	for viewport in [Vector2i(240, 457), Vector2i(280, 520), Vector2i(320, 568), Vector2i(360, 800), Vector2i(390, 844), Vector2i(844, 390), Vector2i(1280, 720)]:
		root.size = viewport
		await process_frame
		scene._safe_insets = {"left": 12.0, "right": 12.0, "top": 24.0, "bottom": 20.0}
		for result in results:
			scene.win_label.text = scene._win_text(result)
			scene.win_label.visible = true
			scene._refresh_bands()
			await process_frame
			await process_frame
			var rect: Rect2 = scene.win_label.get_global_rect()
			check(rect.position.x >= 12.0 and rect.end.x <= viewport.x - 12.0, "通关文字应留在横向安全区内：%s" % str(viewport))
			check(rect.position.y >= 24.0 and rect.end.y <= viewport.y - 20.0, "通关文字应完整显示：%s" % str(viewport))
			check(scene.win_label.size.y >= scene.win_label.get_minimum_size().y, "提示高度应容纳全部换行")
			check(scene.win_label.get_visible_line_count() == scene.win_label.get_line_count(), "不能裁掉通关文字行")
			check(scene.win_label.text.contains("用时"), "完整保留成绩内容")
	# 手势提示在有/无回放按钮时均不得与动作按钮相交。
	for viewport in [Vector2i(240, 457), Vector2i(280, 520), Vector2i(320, 568), Vector2i(360, 800), Vector2i(390, 844), Vector2i(844, 390)]:
		root.size = viewport
		await process_frame
		for replay in [false, true]:
			scene.touch_controls.set_replay_available(replay)
			scene.touch_controls._apply_layout()
			await process_frame
			var controls = scene.touch_controls
			check(not controls._hint.get_global_rect().intersects(controls._actions.get_global_rect()), "手势提示不能与按钮重叠：%s" % str(viewport))
	# Use a short phone viewport so the 20-card page actually overflows and exercises drag scrolling.
	root.size = Vector2i(360, 457)
	await process_frame
	scene.progress.record_win("level_01", ["backward", "backward"])
	scene._open_level_select()
	var menu = scene.level_select
	menu._scroll.scroll_vertical = 0
	await process_frame
	var start: Vector2 = menu._cards[0].get_global_rect().get_center()
	var press := InputEventScreenTouch.new()
	press.index = 4
	press.pressed = true
	press.position = start
	menu._input(press)
	var other := InputEventScreenTouch.new()
	other.index = 9
	other.pressed = true
	other.position = start
	menu._input(other)
	other.pressed = false
	menu._input(other)
	check(menu._scroll_touch == 4, "第二根手指不能结束选关滚动")
	var drag := InputEventScreenDrag.new()
	drag.index = 4
	drag.position = start - Vector2(0, 400)
	menu._input(drag)
	check(menu._scroll.scroll_vertical > 0, "从关卡按钮上滑动也能滚动页面")
	press.pressed = false
	press.position = drag.position
	menu._input(press)
	check(menu.is_open(), "拖动抬手不能误触关卡按钮")
	check(scene.current_index == 1, "选关滚动不能切关或穿透棋盘")
	# 到达底部后短点按原按钮仍能正常执行。
	await process_frame
	press.pressed = true
	press.position = menu.back_button().get_global_rect().get_center()
	menu._input(press)
	press.pressed = false
	menu._input(press)
	check(not menu.is_open(), "滚动后的返回游戏按钮仍能点按")
	# 覆盖 2/3/4/5 列及断点两侧，检查实际容器排版而非只验证计算值。
	menu.open_with(scene.entries, scene.progress, scene.current_index)
	for width in [240, 390, 723, 724, 800, 923, 924, 1280]:
		root.size = Vector2i(width, 800)
		await process_frame
		menu._apply_layout()
		for frame in range(4):
			await process_frame
		var columns: int = menu._grid.columns
		var first: Rect2 = menu._cards[0].get_global_rect()
		var last: Rect2 = menu._cards[columns - 1].get_global_rect()
		var grid: Rect2 = menu._grid.get_global_rect()
		check(absf(first.position.x - grid.position.x) <= 1.0, "首列与网格左侧齐边：%d" % width)
		check(absf(last.end.x - grid.end.x) <= 1.0, "末列占满网格右侧：%d列/%dpx" % [columns, width])
		check(grid.end.x <= width, "网格不溢出屏幕：%d" % width)
		for col in range(columns):
			check(absf(menu._cards[col].size.x - first.size.x) <= 1.0, "各列均分可用宽度")
	scene.free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(save_path))
	print(JSON.stringify({"suite": "test_status_layout", "checks": checks, "failures": failures, "status": "ok" if failures == 0 else "fail"}))
	quit(0 if failures == 0 else 1)
