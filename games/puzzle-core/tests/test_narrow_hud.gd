extends SceneTree
const I18n = preload("res://meta/i18n.gd")
var checks := 0
var failures := 0
func _init() -> void:
	call_deferred("_run")
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error(message)
func inside(control: Control, width: float, context: String) -> void:
	if not control.is_visible_in_tree():
		return
	var rect := control.get_global_rect()
	check(rect.position.x >= -0.5 and rect.end.x <= width + 0.5, context + " " + str(rect))
func _run() -> void:
	var save_path := "user://test_narrow_hud.json"
	DirAccess.remove_absolute(ProjectSettings.globalize_path(save_path))
	ProjectSettings.set_setting("puzzle/progress_path", save_path)
	ProjectSettings.set_setting("puzzle/system_locale_override", "zh")
	var scene = load("res://scenes/main.tscn").instantiate()
	root.add_child(scene)
	await process_frame
	scene._touch_active = true
	scene._apply_touch_visibility()
	for language in ["zh", "en"]:
		I18n.configure(language)
		scene._refresh_language()
		await process_frame
		for size in [Vector2i(240,457), Vector2i(280,520), Vector2i(320,568), Vector2i(390,844)]:
			root.size = size
			await process_frame
			scene._safe_insets = {"left":12.0,"right":12.0,"top":24.0,"bottom":20.0}
			scene._apply_hud_insets()
			for recorded in [false, true]:
				if recorded:
					var moves: Array = []
					moves.resize(123)
					scene.progress.record_win("level_01", moves, 999999)
				scene.game.move_count = 123
				scene._update_hud()
				for _i in range(4):
					await process_frame
				var context := "%s %s" % [language, size]
				for control in [scene.left_panel, scene.right_panel, scene.level_label, scene.moves_label, scene.time_label, scene.best_label]:
					inside(control, size.x, context)
				check(not scene.left_panel.get_global_rect().intersects(scene.right_panel.get_global_rect()), "HUD 面板不重叠 " + context)
				scene.progress.reset()
			scene.win_label.text = scene._win_text({"move_count":123,"time_ms":999999,"first_clear":false,"improved":true,"prev_best":999})
			scene.win_label.visible = true
			scene._refresh_bands()
			for _i in range(4):
				await process_frame
			inside(scene.win_label, size.x, "通关 " + language + str(size))
			check(scene.win_label.get_global_rect().end.y <= size.y - 20, "通关文字留在纵向安全区")
			check(scene.win_label.get_visible_line_count() == scene.win_label.get_line_count(), "通关文字完整显示")
			scene.win_label.visible = false
			scene.touch_controls.set_replay_available(true)
			scene.touch_controls.set_replay_playing(true)
			for _i in range(4):
				await process_frame
			inside(scene.touch_controls._actions, size.x, "回放动作区")
			for button in scene.touch_controls._action_buttons:
				inside(button, size.x, "回放按钮 " + language + str(size))
			scene.touch_controls.set_replay_playing(false)
			scene._challenge = {"level":1, "moves":999}
			scene._update_hud()
			for _i in range(4):
				await process_frame
			inside(scene.challenge_label, size.x, "好友挑战 " + language + str(size))
			scene._challenge = {}
			scene._update_hud()
			scene._open_level_select()
			for _i in range(4):
				await process_frame
			var menu = scene.level_select
			for control in [menu._content, menu._title, menu._subtitle, menu._theme_btn, menu._language_btn, menu._detail, menu._hint, menu._back_btn]:
				inside(control, size.x, "选关 " + language + str(size))
			menu.close()
	scene.queue_free()
	await process_frame
	DirAccess.remove_absolute(ProjectSettings.globalize_path(save_path))
	I18n.configure("zh")
	print(JSON.stringify({"checks":checks,"failures":failures,"status":"ok" if failures == 0 else "fail"}))
	quit(0 if failures == 0 else 1)
