extends SceneTree
const I18n = preload("res://meta/i18n.gd")
const Progress = preload("res://meta/progress.gd")
const Bevel = preload("res://meta/beveled_box.gd")
const VisualTheme = preload("res://meta/visual_theme.gd")
var checks := 0
var failures := 0
func _init() -> void:
	call_deferred("_run")
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error(message)
func _run() -> void:
	check(I18n.resolve("zh-Hant-TW") == "zh", "中文系统语言")
	check(I18n.resolve("en_US") == "en", "英文系统语言")
	check(I18n.resolve("fr-FR") == "en", "未支持语言回退英文")
	check(I18n.valid_preference("invalid") == "system", "无效偏好回退系统")
	var catalog: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://i18n/en.json"))
	var placeholders := RegEx.new()
	placeholders.compile("%[-+0-9.]*[dfs]")
	for source in catalog:
		var a: Array = []
		var b: Array = []
		for match_value in placeholders.search_all(source):
			a.append(match_value.get_string())
		for match_value in placeholders.search_all(str(catalog[source])):
			b.append(match_value.get_string())
		check(a == b, "译文占位符匹配: " + source)
	var save_path := "user://test_i18n_theme.json"
	DirAccess.remove_absolute(ProjectSettings.globalize_path(save_path))
	var progress = Progress.new(save_path)
	check(progress.language_preference() == "system", "新存档跟随系统")
	progress.set_language_preference("en")
	progress.set_visual_theme("candy")
	progress.record_win("level_01", ["+x"], 1234)
	progress.reset_campaign()
	var restored = Progress.new(save_path)
	check(restored.language_preference() == "en" and restored.visual_theme() == "candy", "偏好持久化并在重玩后保留")
	check(restored.best_moves("level_01") == 1, "主题偏好不影响记录")
	for size in [Vector3.ONE, Vector3(0.94,0.2,0.94)]:
		var mesh: ArrayMesh = Bevel.mesh(size, 0.025)
		check(mesh.get_aabb().size.is_equal_approx(size), "倒角不改变方格尺寸")
		check(mesh.get_aabb().position.is_equal_approx(-size * 0.5), "倒角中心保持原点")
		check(mesh == Bevel.mesh(size, 0.025), "几何体缓存复用")
		var arrays := mesh.surface_get_arrays(0)
		check(arrays[Mesh.ARRAY_VERTEX].size() == 132, "单方块仅44个三角形")
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		for i in range(0, vertices.size(), 3):
			check((vertices[i+1]-vertices[i]).cross(vertices[i+2]-vertices[i]).dot(normals[i]) < 0, "可见面顺时针绕序")
	ProjectSettings.set_setting("puzzle/progress_path", save_path)
	ProjectSettings.set_setting("puzzle/system_locale_override", "en-GB")
	root.size = Vector2i(360,800)
	var scene = load("res://scenes/main.tscn").instantiate()
	root.add_child(scene)
	await process_frame
	scene.game.snap_spawn()
	var state: Array = scene.game.state.world_cells().duplicate()
	var count: int = scene.game.move_count
	for id in VisualTheme.IDS:
		scene._apply_visual_theme(id)
		check(scene.game.theme_id == id, "主题应用")
		var recipe: Dictionary = VisualTheme.palette(id)
		check(scene.get_node("WorldEnvironment").environment.background_color == recipe["bg_mid"], "低画质背景同步主题")
		check(is_equal_approx(scene.light.light_energy, recipe["energy"]), "主题光照同步")
		check(scene.game._block_mat.get_shader_parameter("surface_roughness") == recipe["block_roughness"], "切换主题同步材质质感")
		check(scene.left_panel.get_theme_stylebox("panel").bg_color == recipe["panel"], "HUD同步主题")
		check(scene.game.state.world_cells() == state and scene.game.move_count == count, "换主题保留当前方块和步数")
	check(scene.level_label.text.begins_with("Level"), "英文HUD")
	scene._touch_active = true
	scene._apply_touch_visibility()
	scene._open_level_select()
	await process_frame
	check(scene.level_select._title.text == "Choose a level", "英文选关")
	scene.level_select._theme_choices["abyss"].pressed.emit()
	await process_frame
	check(not scene.level_select.is_open() and scene.progress.visual_theme() == "abyss", "主题卡片直接选择并返回游戏")
	check(scene.game.state.world_cells() == state, "主题卡片切换保留棋盘状态")
	scene._open_level_select()
	await process_frame
	check(scene.touch_controls._action_buttons[0].text == "Retry", "英文触屏按钮")
	# en -> zh -> system。跟随英文系统，继续保持当前谜题。
	scene._on_language_requested()
	await process_frame
	check(scene.level_label.text.begins_with("第"), "立即切换中文")
	scene._on_language_requested()
	await process_frame
	check(I18n.language == "en", "重新跟随系统")
	check(scene.game.state.world_cells() == state and scene.game.move_count == count, "换语言不重启关卡")
	check(scene.level_select._privacy.title == "Privacy policy", "隐私弹窗翻译")
	scene.level_select.close()
	scene.touch_controls.set_replay_available(true)
	scene.touch_controls.set_replay_playing(true)
	scene.touch_controls._apply_layout()
	await process_frame
	check(scene.touch_controls._actions.get_rect().end.x <= 360, "英文回放按钮留在手机屏幕内")
	check(not scene.touch_controls._hint.get_rect().intersects(scene.touch_controls._actions.get_rect()), "英文提示不与按钮重叠")
	var message: String = scene._win_text({"move_count":123,"time_ms":654321,"first_clear":false,"improved":true,"prev_best":999})
	scene.win_label.text = message
	scene.win_label.visible = true
	scene._refresh_bands()
	await process_frame
	check(scene.win_label.get_minimum_size().x <= 360, "英文长通关文本不撑开手机屏幕")
	scene.queue_free()
	await process_frame
	DirAccess.remove_absolute(ProjectSettings.globalize_path(save_path))
	I18n.configure("zh")
	print(JSON.stringify({"checks":checks,"failures":failures,"status":"ok" if failures == 0 else "fail"}))
	quit(0 if failures == 0 else 1)
