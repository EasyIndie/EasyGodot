# screenshot.gd — 渲染一帧并保存 PNG，用于视觉验证 / 回归（对应五层测试的 Visual Test）。
# 需要显示环境（非 headless）。用法（经 gf-shot.sh 调用）：
#   godot --path <project> --resolution 960x600 -s res://tools/screenshot.gd -- <level> <out_png>
extends SceneTree


func _init() -> void:
	_run()


func _run() -> void:
	var args: Array = OS.get_cmdline_user_args()
	var level: String = str(args[0]) if args.size() > 0 else "res://levels/level_01.json"
	var out: String = str(args[1]) if args.size() > 1 else "res://_shot.png"
	var save_path := "user://screenshot_progress.json"
	DirAccess.remove_absolute(ProjectSettings.globalize_path(save_path))
	ProjectSettings.set_setting("puzzle/progress_path", save_path)
	ProjectSettings.set_setting("puzzle/system_locale_override", "en" if args.has("--en") else "zh")

	var scene = load("res://scenes/main.tscn").instantiate()
	root.add_child(scene)
	await process_frame
	if args.has("--touch"):
		scene._query_string = "?touch=1"
		scene._touch_active = true
		scene._apply_touch_visibility()
	# 加载指定关卡并重新取景
	# 走 main 的索引加载，HUD 才能显示正确的关卡号/进度；找不到才退回直载
	var idx: int = scene.levels.find(level)
	if idx >= 0:
		scene._load_level(idx, false)
	else:
		scene.game.load_level(level)
	for arg in args:
		if str(arg).begins_with("--theme="):
			scene._apply_visual_theme(str(arg).trim_prefix("--theme="))
	scene._frame_camera()
	if args.has("--win"):
		scene.game.won_flag = true
		scene.win_label.text = scene._win_text({"move_count": 3, "time_ms": 12800, "first_clear": true, "improved": false})
		scene.win_label.visible = true
		scene._refresh_bands()
	if args.has("--menu"):
		scene._open_level_select()
	for _i in range(12):
		await process_frame

	var img: Image = root.get_texture().get_image()
	var err: int = img.save_png(out)
	print(JSON.stringify({
		"status": "ok" if err == OK else "fail",
		"level": level,
		"out": out,
		"size": [img.get_width(), img.get_height()],
	}))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(save_path))
	quit(0 if err == OK else 1)
