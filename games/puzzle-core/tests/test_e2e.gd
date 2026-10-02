# test_e2e.gd — 视觉层 + 集成 E2E 测试（headless）。
# 验证：Game 节点加载关卡/渲染/应用解路径达胜，输入映射，主场景实例化。
extends SceneTree

const Game = preload("res://scenes/game.gd")
const Solver = preload("res://solver/solver.gd")
const Moves = preload("res://core/moves.gd")
const Loader = preload("res://core/level_loader.gd")
const Fixtures = preload("res://tests/fixtures.gd")
const Progress = preload("res://meta/progress.gd")
const TouchControls = preload("res://meta/touch_controls.gd")
const UiLayout = preload("res://meta/ui_layout.gd")
const Leaderboard = preload("res://meta/leaderboard.gd")
const Share = preload("res://meta/share.gd")

var checks: int = 0
var failures: int = 0

# 整套 e2e 使用的临时存档（不写玩家的 user://progress.json）
const SUITE_SAVE := "user://test_e2e_progress.json"


func _init() -> void:
	_run()


func _run() -> void:
	# 所有基于场景的测试共用一个**临时存档**。
	# 为什么必须隔离：这些测试会真的 record_win，早先直接写 user://progress.json，
	# 于是第二次运行时“全新进度”的前提就不成立了（上一次跑测的通关记录还在）——
	# 测试污染玩家存档本身就是 bug。
	_remove_tmp(SUITE_SAVE)
	ProjectSettings.set_setting("puzzle/progress_path", SUITE_SAVE)
	_test_game_direct()
	_test_tiny_level()
	_test_fall()
	_test_void_fall()
	_test_input_mapping()
	_test_all_levels_render()
	await _test_scene()
	await _test_level_select()
	await _test_replay_playback()
	await _test_replay_animation()
	await _test_input_buffering()
	_test_touch_controls()
	await _test_move_animation_geometry()
	await _test_respawn_animation()
	await _test_swipe_hint()
	await _test_touch_safe_area()
	await _test_ending()
	await _test_mobile_back()
	await _test_tv_input()
	await _test_clock()
	await _test_ghost()
	await _test_challenge()
	await _test_mechanism_render()
	ProjectSettings.set_setting("puzzle/progress_path", "")
	_remove_tmp(SUITE_SAVE)
	_report_and_quit()


func check(cond: bool, msg: String) -> void:
	checks += 1
	if not cond:
		failures += 1
		push_error("FAIL: " + msg)


func _report_and_quit() -> void:
	var result: Dictionary = {
		"suite": "test_e2e",
		"checks": checks,
		"failures": failures,
		"status": "ok" if failures == 0 else "fail",
	}
	print(JSON.stringify(result))
	quit(0 if failures == 0 else 1)


# ---- 测试组 ----

func _test_game_direct() -> void:
	var game = Game.new()
	game.animate = false   # 测试关闭动画，同步驱动
	root.add_child(game)

	var ok: bool = game.load_dict(Loader.load_dict(Fixtures.level_8moves()))
	check(ok, "夹具应加载成功")
	check(game.level_id == "fixture_8moves", "level_id 应为 fixture_8moves")
	var tiles: int = game.board.grid_x * game.board.grid_z - game.board.holes.size()
	check(game.board_root != null and game.tile_count() == tiles, "棋盘应只渲染实心瓦片（空洞留空）")
	check(game.block_mesh_count() == game.state.world_cells().size(), "方块单元数应等于世界单元数")

	# 用求解器的解驱动游戏，验证视觉层与 core 协同
	var sol: Dictionary = Solver.new(game.board, game.state).solve()
	check(sol["solvable"], "level_01 应可解")
	var steps: int = 0
	for label in sol["solution"]:
		var d: Vector3i = Moves.direction_from_label(label)
		check(game.try_move(d), "解中的移动应成功: " + str(label))
		steps += 1
	check(game.is_won(), "应用完整解后应获胜")
	check(steps == sol["optimal_moves"], "步数应等于最优步数: " + str(steps))
	check(game.move_count == sol["optimal_moves"], "move_count 应等于最优步数")

	# 胜利后不应再移动
	var before: int = game.state.world_cells().size()
	game.try_move(Vector3i(1, 0, 0))
	check(game.state.world_cells().size() == before, "获胜后不应再移动")

	game.free()


func _test_tiny_level() -> void:
	# 最小关卡应能端到端跑通：加载 → 渲染 → 沿解走 → 获胜。
	# 这里刻意用**独立的夹具**（3x3 无洞）而不是 levels/ 里的真实关卡，
	# 这样玩家可见的关卡内容怎么调整都不会让这条测试变红。
	var game = Game.new()
	game.animate = false
	root.add_child(game)
	check(game.load_dict(Loader.load_dict(Fixtures.tiny_level())), "tiny 夹具应加载成功")
	check(game.state.shape.id == "domino", "形状应为 domino")
	check(game.state.world_cells().size() == 2, "竖立骨牌应占 2 格")
	check(game.block_mesh_count() == 2, "骨牌应渲染 2 个单元")
	var tiles: int = game.board.grid_x * game.board.grid_z - game.board.holes.size()
	check(game.tile_count() == tiles, "棋盘渲染应正确")

	var sol: Dictionary = Solver.new(game.board, game.state).solve()
	check(sol["solvable"], "tiny 夹具应可解")
	for label in sol["solution"]:
		check(game.try_move(Moves.direction_from_label(label)), "移动应成功: " + str(label))
	check(game.is_won(), "走到目标应获胜")

	# 越界翻滚应触发坠落（「无地面」判定）
	game.load_dict(Loader.load_dict(Fixtures.tiny_level()))
	check(game.try_move(Vector3i(-1, 0, 0)), "越界翻滚应被接受（触发坠落）")
	check(game.is_lost(), "越界后应坠落失败")
	game.free()


func _test_all_levels_render() -> void:
	# 内容完整性：levels/ 下每一关都应能被视觉层加载并正确渲染
	var dir := DirAccess.open("res://levels")
	var paths: Array = []
	if dir != null:
		dir.list_dir_begin()
		var f: String = dir.get_next()
		while f != "":
			if f.ends_with(".json"):
				paths.append("res://levels/" + f)
			f = dir.get_next()
		dir.list_dir_end()
	paths.sort()

	check(paths.size() >= 20, "关卡集应至少 20 关，got=" + str(paths.size()))
	var shapes: Dictionary = {}
	for p in paths:
		var lv: Dictionary = Loader.load_file(p)
		check(not lv.has("error"), "关卡应能加载: " + p + " " + str(lv.get("error", "")))
		if lv.has("error"):
			continue
		var game = Game.new()
		game.animate = false
		root.add_child(game)
		check(game.load_dict(lv), "视觉层应能加载: " + p)
		check(game.block_mesh_count() == game.state.world_cells().size(), "方块单元数应正确: " + p)
		var tiles: int = game.board.grid_x * game.board.grid_z - game.board.holes.size()
		check(game.tile_count() == tiles, "棋盘渲染应正确: " + p)
		shapes[game.state.shape.id] = true
		game.free()

	check(shapes.has("domino"), "关卡集应包含 domino 关")
	# cube 已整体移除（见 test_core 的说明）：关卡集不应再出现其他形状
	check(shapes.size() == 1, "关卡集应只有一种形状，got=" + str(shapes.keys()))


func _test_fall() -> void:
	var game = Game.new()
	game.animate = false
	root.add_child(game)
	game.load_dict(Loader.load_dict(Fixtures.level_8moves()))

	# roll_delta 应暴露 pivot（动画用）
	var r: Dictionary = Moves.roll_delta(game.state.shape, game.state.orientation, Vector3i(0, 0, -1))
	check(r.has("pivot"), "roll_delta 应返回 pivot")

	# 从起点向 -z 翻滚会掉出棋盘（z=-1）→ 坠落失败
	check(game.try_move(Vector3i(0, 0, -1)), "越界翻滚应被接受（触发坠落）")
	check(game.is_lost(), "越界后应处于坠落/失败状态")
	check(not game.is_won(), "坠落不应判为通关")
	check(game.move_count == 0, "坠落步不计入步数")
	check(not game.try_move(Vector3i(0, 0, 1)), "坠落失败后不应再移动")

	# 重开后应恢复
	game.load_dict(Loader.load_dict(Fixtures.level_8moves()))
	check(not game.is_lost(), "重开后应清除失败状态")
	check(game.move_count == 0, "重开后步数应归零")
	game.free()


func _test_void_fall() -> void:
	# 机关扩展点：实心格动态变空洞 → 踩空坠落（判定始终基于“脚下有无地面”）
	var game = Game.new()
	game.animate = false
	root.add_child(game)
	game.load_dict(Loader.load_dict(Fixtures.level_8moves()))
	check(not game.check_fall(), "有地面时不应坠落")
	var cell: Vector3i = game.state.world_cells()[0]
	check(game.board.is_solid(cell), "起点格应为实心")
	game.board.set_void(Vector2i(cell.x, cell.z), true)
	check(not game.board.is_solid(cell), "set_void 应把实心格变为空洞")
	check(game.board.is_hole(cell), "is_hole 应兼容空洞语义")
	check(game.check_fall(), "脚下变空洞后应触发踩空坠落")
	check(game.is_lost(), "踩空坠落应判失败")
	game.load_dict(Loader.load_dict(Fixtures.level_8moves()))
	check(not game.is_lost(), "重开后应清除失败状态")
	game.free()


func _test_input_mapping() -> void:
	var game = Game.new()
	var e := InputEventKey.new()
	e.pressed = true
	e.keycode = KEY_RIGHT
	check(game.event_to_dir(e) == Vector3i(1, 0, 0), "右键 → +x")
	e.keycode = KEY_LEFT
	check(game.event_to_dir(e) == Vector3i(-1, 0, 0), "左键 → -x")
	e.keycode = KEY_W
	check(game.event_to_dir(e) == Vector3i(0, 0, -1), "W → 屏幕上移(-z)")
	e.keycode = KEY_S
	check(game.event_to_dir(e) == Vector3i(0, 0, 1), "S → 屏幕下移(+z)")
	# 释放事件不应触发移动
	e.pressed = false
	check(game.event_to_dir(e) == Vector3i.ZERO, "释放按键不应产生方向")
	game.free()


func _test_scene() -> void:
	var scene = load("res://scenes/main.tscn").instantiate()
	root.add_child(scene)
	await process_frame
	check(scene.game != null, "主场景应创建 game 节点")
	if scene.game != null:
		check(scene.game.level_id == "level_01", "主场景默认加载 level_01")
		check(scene.game.board_root != null, "主场景应构建棋盘")
		check(scene.game.block != null, "主场景应构建方块")
	scene.free()


func _remove_tmp(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _first_safe_dir(g) -> Vector3i:
	# 找"落点全部实心"的方向（不会坠落）——用它验证缓冲，免得测成坠落动画
	for d in [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)]:
		if bool(g._plan_move(d)["supported"]):
			return d
	return Vector3i.ZERO


func _test_input_buffering() -> void:
	# 动画期间的输入不能被丢掉 —— 这是真机反馈"不跟手"的根因之一
	#（滚动动画期间 try_move 直接 return false，输入静默消失）。
	# 这里模拟"动画还没演完，玩家又滑了一下"：那一步必须在动画结束后执行。
	var scene = load("res://scenes/main.tscn").instantiate()
	root.size = Vector2i(1280, 720)
	root.add_child(scene)
	await process_frame
	await create_timer(1.8).timeout            # 等入场下落动画结束（入场期间输入走缓冲）
	check(not scene.game.animating, "入场动画应已结束")
	var d1: Vector3i = _first_safe_dir(scene.game)
	check(d1 != Vector3i.ZERO, "第 1 关应至少有一个方向可走")
	check(scene._do_move(d1), "第一步应走成")
	await process_frame
	check(scene.game.animating, "第一步应进入滚动动画")
	var during: int = scene.game.move_count
	scene._do_move(_first_safe_dir(scene.game))   # 动画期间再输入
	check(scene._pending_move != Vector3i.ZERO, "动画期间的输入应被缓冲，而不是丢掉")
	await create_timer(1.4).timeout
	check(scene.game.move_count == during + 1,
		"动画结束后缓冲的那一步必须真的执行（步数 %d → %d）" % [during, scene.game.move_count])
	# 换关必须清空缓冲：否则界面一关会突然滚一下
	scene._do_load(0)
	check(scene._pending_move == Vector3i.ZERO, "换关后缓冲必须清空")
	scene.queue_free()
	await process_frame


func _touch_dirs() -> Dictionary:
	# 与游戏一致：屏幕上"走一格"的向量（40px 一格，斜 45° 等距）
	var ex := Vector2(0.8165, 0.5774) * 40.0
	var ez := Vector2(-0.8165, 0.5774) * 40.0
	return {
		Vector3i(1, 0, 0): ex, Vector3i(-1, 0, 0): -ex,
		Vector3i(0, 0, 1): ez, Vector3i(0, 0, -1): -ez,
	}


func _test_touch_controls() -> void:
	# 触屏操作层：滑动方向映射、按钮联动、不与选关/过渡打架
	# 1) 方向解算本身的边界（角度容错 / 歧义粘滞 / 阈值缩放）由
	#    tests/test_gesture.gd 逐个角度断言；这里只验**接线**：
	#    拖动经过操作层，真的发出 direction 信号，且方向正确。
	var probe := TouchControls.new()
	root.add_child(probe)
	probe.set_screen_dirs(_touch_dirs())
	var got: Array = []
	probe.direction.connect(func(d: Vector3i) -> void: got.append(d))
	probe.drag_begin(Vector2(400.0, 300.0))
	probe.drag_move(Vector2(452.0, 337.0))   # 右下 ≈1.3 格
	probe.drag_end()
	check(got == [Vector3i(1, 0, 0)], "触屏层应把右下拖动转成 +x（实际 %s）" % str(got))
	# 轻微移动 = 点按：不该触发移动（否则想按按钮的手会被判成滑动）
	var got2: Array = []
	probe.direction.connect(func(d: Vector3i) -> void: got2.append(d))
	probe.drag_begin(Vector2(100.0, 100.0))
	probe.drag_move(Vector2(104.0, 102.0))
	probe.drag_end()
	check(got2.is_empty(), "轻微移动不该触发移动（那是点按）")
	probe.queue_free()

	var scene = load("res://scenes/main.tscn").instantiate()
	# 显式设定视口尺寸：headless 下默认窗口尺寸不可靠（get_visible_rect 可能为 0，
	# 会让「顶部/底部提示带」的判定错位）
	root.size = Vector2i(1280, 720)
	root.add_child(scene)
	await process_frame
	check(scene.touch_controls != null, "主场景应创建触屏操作层")

	# 2) 默认（headless 无触屏）不显示；强制打开后可见
	scene._touch_active = false
	scene._apply_touch_visibility()
	check(not scene.touch_controls.is_shown(), "默认不应显示触屏控件")
	scene._touch_active = true
	scene._apply_touch_visibility()
	check(scene.touch_controls.is_shown(), "?touch=1 / 触屏设备应显示控件")
	check(scene.touch_controls.bottom_inset() > 0.0, "应报告底部占位高度（供提示文案避让）")

	# 2b) 相机应把「每个网格方向的屏幕方向」注入给操作层（换取景自动跟随）
	var dirs: Dictionary = scene.touch_controls._screen_dirs
	check(dirs.size() == 4, "应从相机注入 4 个方向，got=%d" % dirs.size())
	if dirs.size() == 4:
		var dz: Vector2 = dirs[Vector3i(0, 0, -1)]
		var dx: Vector2 = dirs[Vector3i(1, 0, 0)]
		check(dz.x > 0.0 and dz.y < 0.0, "-z 在屏幕上应是右上（got=%s）" % str(dz))
		check(dx.x > 0.0 and dx.y > 0.0, "+x 在屏幕上应是右下（got=%s）" % str(dx))
		# 注入的实际方向也应与默认基准一致，否则两份映射会不一致
		for d in dirs.keys():
			check(dirs[d].dot(UiLayout.DEFAULT_SCREEN_DIRS[d]) > 0.99,
				"相机实测的 %s 屏幕方向应与默认基准一致" % str(d))

	# 2c) 状态提示不得落在屏幕垂直中部（会遮挡棋盘，玩家看不到自己刚做了什么）
	scene.fail_label.text = "坠落！方块掉出了棋盘"
	scene.fail_label.visible = true
	scene._refresh_bands()
	await process_frame
	var vp_h: float = scene.get_viewport().get_visible_rect().size.y
	check(vp_h > 100.0, "测试视口高度应有效，got=%.0f" % vp_h)
	var band_mid: float = scene.fail_label.position.y + scene.fail_label.size.y * 0.5
	check(absf(band_mid - vp_h * 0.5) > vp_h * 0.25,
		"坠落提示不应在屏幕垂直中部（mid=%.0f vp=%.0f）" % [band_mid, vp_h])
	var band_bottom: float = scene.fail_label.position.y + scene.fail_label.size.y
	check(scene.fail_label.position.y >= -1.0 and band_bottom <= vp_h + 1.0,
		"坠落提示应完整落在屏幕内（top=%.0f bottom=%.0f vp=%.0f）" % [scene.fail_label.position.y, band_bottom, vp_h])
	check(not scene.help_label.visible, "有状态提示时操作提示应让位（同一条带不压字）")
	scene.fail_label.visible = false
	scene._refresh_bands()
	check(scene.help_label.visible, "状态提示收起后操作提示应回来")

	# 3) 方向信号应真的驱动方块。
	# 合法方向从**当前局面**现算，而不是写死 +x：写死会让测试依赖关卡具体内容，
	# 关卡曲线一调整（本题正在做的事）测试就会无辜变红。
	scene._load_level(0, false)
	var legal: Array = scene.game.core.legal_moves()
	check(legal.size() > 0, "第 1 关起点应至少有一个合法方向")
	if legal.size() > 0:
		var before: int = scene.game.move_count
		scene._on_touch_direction(legal[0])
		check(scene.game.move_count == before + 1, "触屏方向应驱动一次移动")

	# 4) 选关界面打开时，触屏方向不得穿透到棋盘
	scene._open_level_select()
	check(scene.level_select.is_open(), "选关界面应已打开")
	var mid: int = scene.game.move_count
	scene._on_touch_direction(Vector3i(1, 0, 0))
	check(scene.game.move_count == mid, "选关打开时触屏方向应被拦下")
	scene.level_select.close()

	# 5) 选关打开时应连带隐藏触屏控件，关闭后恢复
	scene._open_level_select()
	check(not scene.touch_controls.is_shown(), "选关打开时应隐藏触屏控件")
	scene.level_select.close()
	check(scene.touch_controls.is_shown(), "选关关闭后应恢复触屏控件")

	# 6) 触屏下的按钮语义：回放中再点「回放」应停止；点「重开」也应停止回放
	scene.progress.record_win(str(scene.entries[0]["key"]), ["right"])
	scene._play_replay()
	check(scene._replaying, "应进入回放状态")
	scene._on_touch_replay()
	check(not scene._replaying, "回放中再点「回放」应停止（触屏没有 Esc）")

	scene.free()


func _test_level_select() -> void:
	# 选关界面：卡片数 / 顺序解锁 / 开关
	var tmp := "user://test_e2e_select.json"
	_remove_tmp(tmp)
	var scene = load("res://scenes/main.tscn").instantiate()
	root.add_child(scene)
	await process_frame

	check(scene.level_select != null, "主场景应创建选关界面")
	check(scene.entries.size() == scene.levels.size(), "关卡元数据应与关卡列表同长")
	check(scene.entries.size() >= 20, "关卡集应至少 20 关")

	# 元数据在扫描阶段就已读出形状（供卡片显示），且包含两种形状
	var shapes: Dictionary = {}
	for e in scene.entries:
		shapes[str(e["shape"])] = true
	check(shapes.has("domino"), "元数据应包含 domino 关")
	check(shapes.size() == 1, "元数据应只有一种形状，got=" + str(shapes.keys()))

	var fresh = Progress.new(tmp)
	scene.level_select.open_with(scene.entries, fresh, 0)
	check(scene.level_select.is_open(), "open_with 后界面应可见")
	check(scene.level_select.card_count() == scene.entries.size(), "卡片数应等于关卡数")
	check(scene.level_select.card_enabled(0), "全新进度下第 1 关应可点")
	check(not scene.level_select.card_enabled(1), "全新进度下第 2 关应锁定")
	scene.level_select.close()
	check(not scene.level_select.is_open(), "close 后界面应不可见")

	# 顺序解锁：通关第 1 关后才开放第 2 关
	fresh.record_win(str(scene.entries[0]["key"]), ["right"])
	scene.level_select.open_with(scene.entries, fresh, 1)
	check(scene.level_select.card_enabled(1), "通关前一关后第 2 关应解锁")
	check(not scene.level_select.card_enabled(2), "第 3 关仍应锁定")
	scene.level_select.close()

	# 移动端没有 Esc —— 选关必须能点「返回」退出，否则进来就出不去
	check(scene.level_select.back_button() != null, "选关界面应有可点的返回按钮")
	scene.level_select.touch_mode = true
	scene.level_select.open_with(scene.entries, fresh, 0)
	check(scene.level_select.is_open(), "应已打开")
	scene.level_select.back_button().pressed.emit()
	check(not scene.level_select.is_open(), "点「返回」应关闭选关界面（触屏唯一出口）")
	# 触屏下提示文案不得再提键盘按键
	scene.level_select.open_with(scene.entries, fresh, 0)
	check(not scene.level_select.hint_text().contains("Esc"),
		"触屏提示不应写 Esc（got='%s'）" % scene.level_select.hint_text())
	scene.level_select.close()
	scene.level_select.touch_mode = false

	scene.free()
	_remove_tmp(tmp)


func _test_replay_playback() -> void:
	# 回放：拿求解器的解当作「玩家最佳记录」，验证重演与收尾复位
	var tmp := "user://test_e2e_replay.json"
	_remove_tmp(tmp)
	var scene = load("res://scenes/main.tscn").instantiate()
	root.add_child(scene)
	await process_frame
	scene.game.animate = false          # 同步驱动，测试更快且确定
	scene.progress = Progress.new(tmp)

	var key: String = str(scene.entries[0]["key"])
	check(not scene.progress.has_replay(key), "初始不应有回放")
	scene._play_replay()                # 无记录时应安全地什么都不做
	check(not scene._replaying, "无回放时不应进入回放状态")

	var sol: Dictionary = Solver.new(scene.game.board, scene.game.state).solve()
	check(sol["solvable"], "第一关应可解")
	scene.progress.record_win(key, sol["solution"])
	check(scene.progress.has_replay(key), "记录后应有回放")

	await scene._play_replay()
	check(not scene._replaying, "回放结束后应退出回放状态")
	check(not scene.win_label.visible, "回放结束后应收起提示")
	check(not scene.game.is_won(), "回放结束后应复位（不处于通关态）")
	check(scene.game.move_count == 0, "回放结束后步数应归零")

	await create_timer(0.8).timeout   # 等灯光脉冲收尾，避免中途释放节点
	scene.free()
	_remove_tmp(tmp)


func _test_replay_animation() -> void:
	# 真实反馈：“回放时方块移动没有动画，移动很快，不太自然”。
	# 根因不是“回放有另一套动画”，而是回放**自己写了一套节奏**：
	#   · 步与步之间只停 0.05s（每秒滚近 5 步）
	#   · 翻滚缓动是 t*t（动作集中在最后 ~80ms）
	# 于是连播在眼里就是“没有动画，一下一下地跳”。
	# 现在回放与手动操作共用 _do_move + _wait_for_anim，步间给人类节奏（REPLAY_BEAT），
	# 起止复位也改用带入场动画的 _reset_to_start（不再瞬移）。
	# 这条测试必须跑在 animate=true 下 —— 原来的回放测试是同步驱动的，所以根本测不到动画。
	var tmp := "user://test_e2e_replay_anim.json"
	_remove_tmp(tmp)
	var scene = load("res://scenes/main.tscn").instantiate()
	root.size = Vector2i(1280, 720)
	root.add_child(scene)
	await process_frame
	check(scene.game.animate, "回放动画必须在开启动画的场景下验证")
	scene.progress = Progress.new(tmp)

	var key: String = str(scene.entries[0]["key"])
	var sol: Dictionary = Solver.new(scene.game.board, scene.game.state).solve()
	check(sol["solvable"], "第一关应可解")
	var solution: Array = sol["solution"]
	check(solution.size() >= 2, "本关解应至少 2 步（否则测不出步间节奏）")
	scene.progress.record_win(key, solution)

	# 逐帧采样：方块质心（含翻滚中的 rig）、是否在动画中、步数、真实时间
	var samples: Array = []
	var t0: int = Time.get_ticks_msec()
	scene._play_replay()
	while scene._replaying and Time.get_ticks_msec() - t0 < 9000:
		await process_frame
		var cs: Array = scene.game.block_mesh_centers()
		var c := Vector3.INF
		if not cs.is_empty():
			c = Vector3.ZERO
			for q in cs:
				c += q
			c /= float(cs.size())
		samples.append({
			"p": c,
			"anim": scene.game.animating,
			"moves": scene.game.move_count,
			"t": Time.get_ticks_msec(),
		})
	check(samples.size() > 5, "应采到足够多的帧（实际 %d）" % samples.size())

	# ① 回放起始必须用入场动画复位，而不是瞬间把方块挪回起点
	var lifted := false
	for s in samples:
		if int(s["moves"]) == 0 and (s["p"] as Vector3).y > 1.0 and (s["p"] as Vector3).y < 900.0:
			lifted = true
	check(lifted, "回放开始应播入场下落动画，而不是瞬移复位")

	# ② 每一步都必须真的在演动画：过程中必须出现“质心不在半整数格点上”的帧
	#    （静止时质心恒为 k*0.5；只有真的在旋转才会离开格点）
	var total_moves: int = solution.size()
	var animated_moves: int = 0
	for m in range(1, total_moves + 1):
		var off_grid := false
		var anim_frames: int = 0
		for s in samples:
			if int(s["moves"]) != m:
				continue
			if bool(s["anim"]):
				anim_frames += 1
			if _off_grid(s["p"]):
				off_grid = true
		if off_grid and anim_frames > 0:
			animated_moves += 1
	check(animated_moves == total_moves,
		"回放每一步都要有翻滚动画（%d/%d 步有动画）" % [animated_moves, total_moves])

	# ③ 步之间必须有可读的节奏：原地 0.05s 的间隔会让回放看起来像瞬移
	var first_t: Dictionary = {}
	for s in samples:
		var m: int = int(s["moves"])
		if m > 0 and not first_t.has(m):
			first_t[m] = int(s["t"])
	var min_gap: int = 1 << 30
	for m in range(1, total_moves):
		if first_t.has(m) and first_t.has(m + 1):
			min_gap = mini(min_gap, int(first_t[m + 1]) - int(first_t[m]))
	if total_moves >= 2:
		check(min_gap >= 320,
			"回放步间隔应接近「动画 + 人类停顿」（实测 %dms，旧实现只有 ~210ms）" % min_gap)

	# ④ 回放中不允许瞬移：位移速度不能超过翻滚动画本身能达到的上限
	#    （t*t 缓动末速 ~2/T，绕半径 ~1.12 的支点 → 约 14 格/秒；瞬移会远远超过）
	# 采样时刻是**毫秒量化**的（Time.get_ticks_msec），所以两帧的实测 dt 可能比真实
	# 帧时长小一点；headless 下帧率不受限、连续几帧落在同一毫秒里是常态。
	# 因此 dt 取「实测值」与「一个 60fps 帧」的较大者作为下限 —— 这只把噪声挡掉：
	# 真实故障（把整段翻滚错位一格以上，实测能有 8 格/帧）依然会被判失败。
	var prev = null
	var fast_frames: int = 0
	var worst_ratio: float = 0.0
	var worst_dist: float = 0.0
	for s in samples:
		var p: Vector3 = s["p"]
		if p == Vector3.INF:
			prev = null
			continue
		if prev != null and int(s["moves"]) >= 1:
			var dt: float = maxf(float(int(s["t"]) - int(prev["t"])), 1000.0 / 60.0) / 1000.0
			var dist: float = p.distance_to(prev["p"])
			if dist > 14.0 * dt + 0.10:
				fast_frames += 1
			var ratio: float = dist / dt
			if ratio > worst_ratio:
				worst_ratio = ratio
				worst_dist = dist
		prev = s
	check(fast_frames == 0,
		"回放中不应出现瞬移帧（%d 帧超速，最差 %.2f 格/帧 ≈ %.1f 格/秒）"
			% [fast_frames, worst_dist, worst_ratio])

	# ⑤ 收尾复位后应回到起点、步数归零（与手动重开一致）
	var guard: int = 0
	while scene.game.animating and guard < 600:
		await process_frame
		guard += 1
	check(scene.game.move_count == 0, "回放结束后步数应归零")
	check(not scene.game.is_won(), "回放结束后应复位（不处于通关态）")

	await create_timer(0.4).timeout
	scene.free()
	_remove_tmp(tmp)


func _off_grid(p: Vector3) -> bool:
	# 静止时方块质心恒为 0.5 的整数倍；只有真的在旋转时才会离开格点。
	for v in [p.x, p.y, p.z]:
		if absf(v - roundf(v * 2.0) * 0.5) > 0.03:
			return true
	return false


func _test_mobile_back() -> void:
	# 移动端的「返回」（Android 返回键 / iOS 边缘返回手势）= 往上退一层，不是退出游戏。
	# 注意：这个决策里有一个分支会 get_tree().quit()（在选关界面按返回 = 退出）。
	# 所以断言的是 **决策函数 back_action()** 而不是直接发信号 ——
	# 否则跑到那一支就会把测试进程一起退掉（这类“没人敢碰”的分支最容易腐坏）。
	var tmp := "user://test_e2e_back.json"
	_remove_tmp(tmp)
	var scene = load("res://scenes/main.tscn").instantiate()
	root.size = Vector2i(1280, 720)
	root.add_child(scene)
	await process_frame
	scene.game.animate = false

	# 对局中 → 打开选关
	check(scene.back_action() == "open_select", "对局中按返回应打开选关界面")
	scene._on_back_requested()
	await create_timer(0.25).timeout
	check(scene.level_select.is_open(), "按返回后选关界面应打开")
	check(scene.back_action() == "quit", "在选关界面（主页）按返回才是退出游戏")

	# 回放中 → 停止回放（而不是退出、也不是弹选关）
	scene.level_select.close()
	await create_timer(0.25).timeout
	var key: String = str(scene.entries[0]["key"])
	var sol: Dictionary = Solver.new(scene.game.board, scene.game.state).solve()
	scene.progress.record_win(key, sol["solution"])
	await scene._play_replay()
	check(not scene._replaying, "回放应已结束")

	# 庆祝层 → 先关庆祝层（再按一次才回到选关）
	scene._show_ending()
	check(scene.ending.is_open(), "庆祝层应已打开")
	check(scene.back_action() == "close_ending", "庆祝层打开时按返回应先关庆祝层")
	scene._on_back_requested()
	check(not scene.ending.is_open(), "按返回后庆祝层应关闭")

	# 信号确实接到了决策函数上（不是只写了个函数没人调）
	check(scene.get_tree().root.go_back_requested.is_connected(scene._on_back_requested),
		"根窗口的 go_back_requested 应连到 _on_back_requested")

	await create_timer(0.25).timeout
	scene.free()
	_remove_tmp(tmp)


func _test_mechanism_render() -> void:
	# 机关必须**看得见**，否则等于没做：桥关着时要有"幽灵框"提示，踩开关后要变成实心。
	# 这里刻意**不依赖某一关的具体解法**（关卡集会随曲线重生成）：
	# 用求解器解出来、逐步复演，检查机关外观是否跟着状态变化。
	var tmp := "user://test_e2e_mech.json"
	DirAccess.remove_absolute(ProjectSettings.globalize_path(tmp))
	ProjectSettings.set_setting("puzzle/progress_path", tmp)
	var game = Game.new()
	game.animate = false
	root.add_child(game)
	# 找一关带桥的机关关（level_18 是"开关 + 桥"）
	var lv: Dictionary = Loader.load_file("res://levels/level_18.json")
	check(not lv.has("error"), "机关关应能加载")
	check(game.load_dict(lv), "机关关应能载入视觉层")

	# 静态地形数不变（机关"补地"不算地形）
	var tiles: int = game.board.grid_x * game.board.grid_z - game.board.holes.size()
	check(game.tile_count() == tiles, "机关关的静态地形瓦片数应正确（%d vs %d）" % [game.tile_count(), tiles])

	var bridge: Dictionary = {}
	for d in game.board.mechanisms:
		if str(d["kind"]) == "bridge":
			bridge = d
	check(not bridge.is_empty(), "level_18 应有桥")
	if bridge.is_empty():
		game.free()
		return
	var first: Vector2i = bridge["tiles"][0]
	var key := "%d,%d" % [first.x, first.y]
	check(game.bridge_ghost_count() == bridge["tiles"].size(),
		"桥关闭时应为每个桥格画幽灵框（%d vs %d）" % [game.bridge_ghost_count(), bridge["tiles"].size()])
	var visible_when_closed := false
	for m in game._mech_tiles.get(key, []):
		if (m as MeshInstance3D).visible:
			visible_when_closed = true
	check(not visible_when_closed, "桥关着时不该出现实心瓦片（只有幽灵框）")

	# 沿最优解复演：桥一旦打开，瓦片必须立刻变实心、幽灵框收起
	var sol: Dictionary = Solver.new(game.board, game.state).solve()
	check(bool(sol["solvable"]), "机关关应可解")
	var opened := false
	for label in sol.get("solution", []):
		game.try_move(Moves.direction_from_label(str(label)))
		if game.mech != null and game.mech.flag(str(bridge["id"])):
			opened = true
			break
	check(opened, "最优解里应该会打开桥（否则机关是装饰品）")
	var visible_when_open := true
	for m in game._mech_tiles.get(key, []):
		if (m as MeshInstance3D).visible == false:
			visible_when_open = false
	check(visible_when_open, "桥打开后桥格应显示实心瓦片")
	var ghost_hidden := true
	for k in game._bridge_ghosts.keys():
		if (game._bridge_ghosts[k] as MeshInstance3D).visible:
			ghost_hidden = false
	check(ghost_hidden, "桥打开后幽灵框应隐藏（真瓦片已经在那个位置了）")

	game.free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(tmp))


func _test_challenge() -> void:
	# 好友挑战：从链接（Web 查询串 / 原生环境变量，同一套语法）直接进入某一关，
	# 通关后**不自动换关**，并给出与对方成绩的对照。
	var tmp := "user://test_e2e_challenge.json"
	DirAccess.remove_absolute(ProjectSettings.globalize_path(tmp))
	ProjectSettings.set_setting("puzzle/progress_path", tmp)
	OS.set_environment("GF_CHALLENGE", "level=7&moves=5")

	var scene = load("res://scenes/main.tscn").instantiate()
	root.size = Vector2i(1280, 720)
	root.add_child(scene)
	await process_frame
	await create_timer(0.1).timeout
	scene.game.animate = false

	# ① 直接打开第 7 关（而不是第 1 关）
	check(scene.challenge_active(), "带挑战参数的启动应进入挑战模式")
	check(scene.current_index == 6, "应直接载入第 7 关（实际下标 %d）" % scene.current_index)
	check(int(scene._challenge["moves"]) == 5, "应记住对方的目标步数")
	check(scene.challenge_label.visible, "应显示挑战目标行")
	check(scene.challenge_label.text.contains("第 7 关") and scene.challenge_label.text.contains("5 步"),
		"挑战行要写清关号与目标（实际：%s）" % scene.challenge_label.text)

	# ② 分享：链接能被自己解析回来，并且真的进了剪贴板
	var text: String = scene._share_current(6)
	check(text.contains("level=7"), "分享文本应带关号链接（实际：%s）" % text)
	var parsed: Dictionary = Share.parse_challenge(text, scene.levels.size())
	check(int(parsed.get("level", 0)) == 7, "分享出去的链接必须能被解析回第 7 关")
	scene._on_share_requested(6)
	# 剪贴板本身要平台支持（headless 下没有），所以断言我们**交给平台的内容**
	# ——这也是这个接缝存在的理由：能测的是「我们递出去了什么」
	check(scene.last_share_text.contains("level=7"),
		"点击分享应把带链接的文案交给平台（实际：%s）" % scene.last_share_text.left(40))
	check(scene.level_select.share_button_text() == "已复制链接", "复制后按钮要给出反馈")

	# ③ 通关：不自动换关 + 给出对照
	var sol: Dictionary = Solver.new(scene.game.board, scene.game.state).solve()
	check(bool(sol["solvable"]), "第 7 关应有解")
	scene._run_moves.clear()
	for d in sol["solution"]:
		scene._run_moves.append(str(d))
	scene.game.move_count = sol["solution"].size()
	scene.game.won_flag = true
	scene._on_won()
	await create_timer(0.6).timeout
	check(scene.current_index == 6, "挑战模式通关后不应自动换关（实际下标 %d）" % scene.current_index)
	check(scene.win_label.text.contains("挑战完成"), "挑战完成文案（实际：%s）" % scene.win_label.text)
	check(scene.win_label.text.contains("步"), "挑战完成文案要报出步数")
	check(scene.progress.best_moves("level_07") > 0 or scene.progress.has_ever_cleared("level_07"),
		"挑战通关也是一次通关，应被记录")

	scene.free()
	OS.set_environment("GF_CHALLENGE", "")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(tmp))

	# ④ 坏链接不能把游戏带进半开状态：安静地按普通启动处理
	OS.set_environment("GF_CHALLENGE", "level=999&moves=abc")
	var s2 = load("res://scenes/main.tscn").instantiate()
	root.add_child(s2)
	await process_frame
	await create_timer(0.05).timeout
	check(not s2.challenge_active(), "坏链接不应进入挑战模式")
	check(s2.current_index == 0, "坏链接应从第 1 关正常开始")
	s2.free()
	OS.set_environment("GF_CHALLENGE", "")


func _test_ghost() -> void:
	# 「影子」= 把自己的最佳走法当幽灵滚一遍。两条硬约束：
	#   ① **绝不许碰玩家的任何状态**（走错一步就是「我在下棋，棋盘自己动了」）
	#   ② 运动必须与玩家方块**同一套模型**（否则会出现两种翻滚表现 —— 这个项目的旧坑）
	var tmp := "user://test_e2e_ghost.json"
	DirAccess.remove_absolute(ProjectSettings.globalize_path(tmp))
	var scene = load("res://scenes/main.tscn").instantiate()
	root.size = Vector2i(1280, 720)
	root.add_child(scene)
	await process_frame
	await create_timer(0.1).timeout
	scene.game.animate = true

	# 先解出第 1 关的解法（用它当“最佳记录”）
	var sol: Dictionary = Solver.new(scene.game.board, scene.game.state).solve()
	check(bool(sol["solvable"]), "第 1 关应有解")
	# 回放数据本身就是方向标签数组（solver 的 solution 与 progress 里存的 moves 同一格式），
	# 所以不需要任何转换 —— 影子直接吃「最佳记录」的原样数据
	var labels: Array = sol["solution"]

	# 影子结构：开关、半透明、不投影
	scene.game.set_ghost_enabled(true)
	check(scene.game.ghost_visible(), "开启后影子应可见")
	check(scene.game.ghost_mesh_count() == scene.game.state.world_cells().size(),
		"影子单元数应与该关起点形状一致（实际 %d）" % scene.game.ghost_mesh_count())
	var translucent := true
	var casting := false
	for c in scene.game._ghost.get_children():
		var mi := c as MeshInstance3D
		if mi.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
			casting = true
		var bm := (mi.mesh as BoxMesh)
		if bm != null and (bm.material as StandardMaterial3D) != null:
			if (bm.material as StandardMaterial3D).albedo_color.a > 0.7:
				translucent = false
	check(translucent, "影子必须是半透明的（否则会被当成实体方块）")
	check(not casting, "影子不投影（影子不该在地面上再投一层影子）")

	# 先等玩家自己的入场下落演完再采样：否则会把「玩家入场动画」误判成影子的干扰
	while scene.game.animating:
		await process_frame
	# 播放：逐帧记录「玩家方块 / 影子」的位置，验证两者互不干扰
	var player_before: Vector3 = _centroid(scene.game.block_mesh_centers())
	var state_before: Array = scene.game.state.world_cells()
	var moves_before: int = scene.game.move_count
	var player_pts: Array = []
	var ghost_pts: Array = []
	var ghost_moves: Array = []
	var ghost_off_grid := 0
	scene.game.play_ghost(labels)
	while scene.game.ghost_busy():
		player_pts.append(_centroid(scene.game.block_mesh_centers()))
		var g: Vector3 = scene.game.ghost_center()
		if g != Vector3.INF:
			ghost_pts.append(g)
			ghost_moves.append(scene.game.ghost_move_index())
			if _off_grid(g):
				ghost_off_grid += 1
		await process_frame
	await create_timer(0.1).timeout

	# ① 玩家状态完全没被碰过
	check(_centroid(scene.game.block_mesh_centers()).distance_to(player_before) < 0.01, "影子播放期间玩家方块不能动")
	check(scene.game.state.world_cells() == state_before, "影子播放期间玩家状态不能变")
	check(scene.game.move_count == moves_before, "影子播放期间玩家步数不能变")
	check(not scene.game.won_flag and not scene.game.lost_flag, "影子播放不能触发通关/坠落")
	var moved_player := false
	for p in player_pts:
		if (p as Vector3).distance_to(player_before) > 0.01:
			moved_player = true
	check(not moved_player, "影子播放期间玩家方块逐帧都不得移动")

	# ② 影子真的在滚（过程中离开格点 = 真旋转，而不是瞬移）
	check(ghost_off_grid > 0, "影子必须有「离开格点」的中间帧（否则是瞬移）")
	check(ghost_pts.size() > 3, "应采到影子移动的多个帧")

	# ③ 与玩家方块同一套运动模型：逐帧位移不能超过翻滚速度上限
	# 「有没有真在演动画」的判据：
	#   ① 每一步都必须出现「质心离开半整数格点」的帧（只有真旋转才会离格，瞬移不会）
	#   ② 相邻两帧的位移不能超过「单次翻滚的弦长」（瞬移/错位会远远超过）
	#
	# 为什么不按 dt 算速度：headless/WSL 下会出现很长的帧（实测有过 1.8 秒的单帧），
	# 而这一帧里引擎给 tween 的 delta 与 Time.get_ticks_msec() 的差值会对不上
	# —— 速度断言因此会随机假失败。按「步」分组则完全不受帧长影响。
	var per_move: Dictionary = {}
	for i in range(ghost_pts.size()):
		var mi: int = int(ghost_moves[i])
		if not per_move.has(mi):
			per_move[mi] = false
		if _off_grid(ghost_pts[i]):
			per_move[mi] = true
	var silent: Array = []
	for mi in per_move.keys():
		if mi >= 1 and not bool(per_move[mi]):
			silent.append(mi)
	check(silent.is_empty(),
		"影子每一步都要有翻滚中间帧（这些步没有：%s）" % str(silent))

	# 注：这里刻意**不**断言"相邻帧位移" —— headless/WSL 下会出现很长的帧
	# （实测有过 1.8 秒单帧），长帧里一整次翻滚会在同一帧内走完，于是"每帧位移上限"
	# 这种断言会随机假失败，而它抓不住的东西（真瞬移）由上面「每一步都要有离格中间帧」
	# 覆盖得更好：瞬移不产生离格帧，这条断言才是可靠的判据。

	# ⑤ 关掉后不可见；换关后自动回到起点
	scene.game.set_ghost_enabled(false)
	check(not scene.game.ghost_visible(), "关闭后影子应不可见")
	scene.game.set_ghost_enabled(true)
	check(scene.game.ghost_at_goal() == false, "重新开启应复位到起点（而不是停在终点）")

	scene.free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(tmp))


func _test_clock() -> void:
	# 「最快时间」必须只统计**玩家真正在解题**的时间。这里逐条验证起停规则：
	# 手动测试根本发现不了「看选关界面时表还在走」这类问题，但玩家的记录会被污染。
	var tmp := "user://test_e2e_clock.json"
	DirAccess.remove_absolute(ProjectSettings.globalize_path(tmp))
	ProjectSettings.set_setting("puzzle/progress_path", tmp)
	var scene = load("res://scenes/main.tscn").instantiate()
	root.size = Vector2i(1280, 720)
	root.add_child(scene)
	await process_frame
	await create_timer(0.1).timeout
	scene.game.animate = false

	# ① 正常对局：表在走，且 HUD 上真的在显示
	check(scene.clock != null and scene.clock.is_running(), "载入完成后计时应在走")
	var t0: int = scene.clock.elapsed_ms()
	await create_timer(0.25).timeout
	check(scene.clock.elapsed_ms() > t0, "对局中计时应增长")
	check(scene.time_label.text != "", "HUD 上应显示计时")
	check(scene.time_label.text.contains(":"), "计时用 m:ss.d 形式（宽度稳定不跳动）")
	# HUD 的计时是**按 0.1 秒节流**更新的（每帧 set_text 会白白触发布局重排），
	# 所以比较时要按同一个精度截断，否则读到「刚跨过 0.1 秒」的那一帧就会假失败。
	check(scene.time_label.text == Leaderboard.format_clock((scene.clock.elapsed_ms() / 100) * 100),
		"HUD 计时文本应与秒表的 0.1 秒节流值一致")

	# ② 选关界面打开：停表（否则玩家可以开着界面慢慢想）
	scene._open_level_select()
	check(not scene.clock.is_running(), "选关界面打开的那一刻就应停表（不等下一帧）")
	await create_timer(0.25).timeout
	var mid: int = scene.clock.elapsed_ms()
	await create_timer(0.2).timeout
	check(scene.clock.elapsed_ms() == mid, "停在选关界面期间时间不应增长")
	scene.level_select.close()
	await create_timer(0.15).timeout
	check(scene.clock.is_running(), "回到游戏后应继续计时")

	# ③ 坠落：停表（玩家这时只能重开，不该继续累计）
	scene.game.lost_flag = true
	await create_timer(0.05).timeout
	check(not scene.clock.is_running(), "坠落时应停表")
	var lost_at: int = scene.clock.elapsed_ms()
	await create_timer(0.2).timeout
	check(scene.clock.elapsed_ms() == lost_at, "坠落之后不应继续累计（玩家这时只能重开）")
	scene.game.lost_flag = false

	# ④ 切后台 / 失焦：停表 —— 手机上来个电话不能算进成绩
	scene._notification(Node.NOTIFICATION_APPLICATION_PAUSED)
	check(not scene.clock.is_running(), "切后台应立刻停表")
	await create_timer(0.2).timeout
	var bg: int = scene.clock.elapsed_ms()
	await create_timer(0.2).timeout
	check(scene.clock.elapsed_ms() == bg, "切后台期间不应累计（来电不能算进成绩）")
	scene._notification(Node.NOTIFICATION_APPLICATION_RESUMED)
	await create_timer(0.05).timeout
	check(scene.clock.is_running(), "回到前台应继续计时")

	# ⑤ 重开：计时归零重新开始（而不是接着上一局的秒数继续跑）
	scene._restart()
	check(scene.clock.elapsed_ms() < 50, "重开应立刻把计时归零")
	await create_timer(0.4).timeout
	check(scene.clock.is_running(), "重开后计时应重新开始")
	check(scene.clock.elapsed_ms() >= 300 and scene.clock.elapsed_ms() < 1200,
		"重开后从零重新计（而不是接着上一局的秒数继续跑）")

	# ⑥ 通关：记录本局用时（放在最后：通关会触发自动换关过渡，会把状态搅浑）
	scene._do_move(Vector3i(1, 0, 0))
	scene._do_move(Vector3i(1, 0, 0))
	await create_timer(0.1).timeout
	var won_time: int = scene.clock.elapsed_ms()
	check(won_time > 0, "通关时应该已累计了一段用时")
	scene.game.won_flag = true
	scene._on_won()
	await create_timer(0.6).timeout
	var key: String = scene._level_key(scene.current_index)
	check(scene.progress.best_time(key) == won_time or scene.progress.best_time(key) > 0,
		"通关应把本局用时写进记录")
	check(not scene.clock.is_running(), "通关后应停表")
	check(scene.win_label.text.contains("用时"), "通关文案要报出用时")
	scene.game.won_flag = false
	await create_timer(1.4).timeout   # 等自动换关过渡走完再释放场景

	# ⑥ 重开：计时归零重新开始（而不是接着上一局的秒数继续跑）
	scene._restart()
	check(scene.clock.elapsed_ms() < 50, "重开应立刻把计时归零")
	await create_timer(0.4).timeout
	check(scene.clock.is_running(), "重开后计时应重新开始")
	check(scene.clock.elapsed_ms() >= 300 and scene.clock.elapsed_ms() < 1200,
		"重开后从零重新计（而不是接着上一局的秒数继续跑）")

	scene.free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(tmp))


func _test_tv_input() -> void:
	# 电视遥控器 / 手柄：三条输入通道都要能移动，且「确认键」必须能在坠落/通关时救场
	# （只有键盘有 R 键，遥控器上没有 —— 不处理的话电视玩家掉下去就卡死了）
	var tmp := "user://test_e2e_tv.json"
	_remove_tmp(tmp)
	var scene = load("res://scenes/main.tscn").instantiate()
	root.size = Vector2i(1920, 1080)   # 电视常见分辨率
	root.add_child(scene)
	await process_frame
	scene.game.animate = false

	# ① 遥控器方向键（Android TV 上报为按键）
	check(scene.game.event_to_dir(_key(KEY_RIGHT)) == Vector3i(1, 0, 0), "遥控器右键应向右")
	check(scene.game.event_to_dir(_key(KEY_UP)) == Vector3i(0, 0, -1), "遥控器上键应向上")

	# ② 手柄 D-pad（部分遥控器/蓝牙手柄上报为按钮）
	check(scene.game.event_to_dir(_pad(JOY_BUTTON_DPAD_LEFT)) == Vector3i(-1, 0, 0), "手柄十字键左应向左")
	check(scene.game.event_to_dir(_pad(JOY_BUTTON_DPAD_DOWN)) == Vector3i(0, 0, 1), "手柄十字键下应向下")
	check(scene.game.event_to_dir(_pad(JOY_BUTTON_A)) == Vector3i.ZERO, "手柄 A 键不是方向")

	# ③ 左摇杆：只在**越过阈值那一刻**产生一次移动（按住不放不能连走好几格）
	check(scene.game.event_to_dir(_axis(JOY_AXIS_LEFT_X, 0.9)) == Vector3i(1, 0, 0), "推摇杆应产生一次移动")
	check(scene.game.event_to_dir(_axis(JOY_AXIS_LEFT_X, 0.95)) == Vector3i.ZERO,
		"摇杆按着不放不应继续触发（边沿触发）")
	check(scene.game.event_to_dir(_axis(JOY_AXIS_LEFT_X, 0.0)) == Vector3i.ZERO, "回中不产生移动")
	check(scene.game.event_to_dir(_axis(JOY_AXIS_LEFT_Y, -0.8)) == Vector3i(0, 0, -1), "摇杆向上推")
	scene.game.event_to_dir(_axis(JOY_AXIS_LEFT_Y, 0.0))

	# ④ 确认键的上下文职责（这是电视能玩下去的关键）
	check(scene.primary_action() == "ignore", "正常对局中按确认不应有任何副作用")
	scene.game.lost_flag = true
	check(scene.primary_action() == "restart", "坠落时按确认应重开（遥控器上没有 R 键）")
	scene.game.lost_flag = false
	scene.game.won_flag = true
	check(scene.primary_action() == "next_level", "通关时按确认应进入下一关")
	scene.game.won_flag = false

	# ⑤ 庆祝层的按钮必须可聚焦 —— 否则电视上按什么都没反应（原来写的是 FOCUS_NONE）
	for e in scene.entries:
		scene.progress.record_win(str(e["key"]), ["right"])
	scene._show_ending()
	var focusable := true
	for b in scene.ending._buttons.get_children():
		if (b as Button).focus_mode == Control.FOCUS_NONE:
			focusable = false
	check(focusable, "庆祝层的按钮必须可聚焦（电视/手柄只能靠焦点导航）")
	var focused: Control = scene.get_viewport().gui_get_focus_owner()
	check(focused != null, "打开庆祝层应把初始焦点给到按钮（遥控器立刻可用）")
	scene.ending.close()
	await create_timer(0.3).timeout
	scene.free()
	_remove_tmp(tmp)


func _key(code: int) -> InputEventKey:
	var e := InputEventKey.new()
	e.keycode = code
	e.pressed = true
	return e


func _pad(btn: int) -> InputEventJoypadButton:
	var e := InputEventJoypadButton.new()
	e.button_index = btn
	e.pressed = true
	return e


func _axis(ax: int, v: float) -> InputEventJoypadMotion:
	var e := InputEventJoypadMotion.new()
	e.axis = ax
	e.axis_value = v
	return e


func _test_respawn_animation() -> void:
	# 坠落后重开必须有动画：直接“啪”一下复位会让玩家以为自己误触了什么。
	var tmp := "user://test_e2e_respawn.json"
	_remove_tmp(tmp)
	var scene = load("res://scenes/main.tscn").instantiate()
	root.size = Vector2i(1280, 720)
	root.add_child(scene)
	await process_frame
	scene.touch_controls.set_shown(true)
	check(scene.game.animate, "交互场景应开启动画")

	# 先让它掉下去
	var legal: Array = scene.game.core.legal_moves()
	check(legal.size() > 0, "第 1 关应有合法方向")
	var fell: bool = false
	for d in [Vector3i(-1, 0, 0), Vector3i(1, 0, 0), Vector3i(0, 0, -1), Vector3i(0, 0, 1)]:
		# 找一个会掉出去的方向
		if not scene.game.board.supports(scene.game.state.cells_at(
				scene.game._plan_move(d)["orientation"], scene.game._plan_move(d)["position"])):
			scene.game.animate = false
			scene.game.try_move(d)
			scene.game.animate = true
			fell = scene.game.is_lost()
			break
	if fell:
		check(scene.game.is_lost(), "该方向应导致坠落")
		scene._on_touch_restart()
		check(scene.game.animating, "重开应播放落体动画（animating 应为真）")
		check(scene.game.block.position.y > 1.0, "重生时方块应从上方落下")
		# 等动画结束，方块应精确落回起点
		var guard: int = 0
		while scene.game.animating and guard < 240:
			await process_frame
			guard += 1
		check(not scene.game.animating, "落体动画应结束")
		check(absf(scene.game.block.position.y) < 0.01, "落体结束后方块应归位")
		check(not scene.game.is_lost(), "重开后应回到未失败状态")
	await create_timer(0.3).timeout
	scene.free()
	_remove_tmp(tmp)


func _test_swipe_hint() -> void:
	# 触屏玩家看不见键盘提示，所以第一次进关卡要给一次“对角线滑动”提示，
	# 并在玩家真的动了一次方块之后收起（比等超时更贴合“学会了”这个时刻）。
	var scene = load("res://scenes/main.tscn").instantiate()
	root.size = Vector2i(1280, 720)
	root.add_child(scene)
	await process_frame
	scene.touch_controls.set_shown(true)
	scene.touch_controls.show_swipe_hint()
	check(scene.touch_controls.hint_visible(), "首次进关卡应显示滑动手势提示")
	check(scene.touch_controls.hint_text().contains("↖"), "提示里应画出对角线方向")
	check(not scene.touch_controls.hint_text().contains("Esc"), "触屏提示不应出现键盘按键名")

	var legal: Array = scene.game.core.legal_moves()
	if legal.size() > 0:
		scene._on_touch_direction(legal[0])
		await create_timer(0.5).timeout
		check(not scene.touch_controls.hint_visible(), "第一次成功移动后提示应收起")
		# 再次调用不应重新弹出（每局只提示一次，反复提示会变成噪音）
		scene.touch_controls.show_swipe_hint()
		check(not scene.touch_controls.hint_visible(), "同一局内不应重复提示")
	await create_timer(0.3).timeout
	scene.free()


func _test_touch_safe_area() -> void:
	# 全部触屏控件都必须落在安全区域之内，否则 iPhone 横屏时
	# 左上按钮会被灵动岛切掉、右下按钮会被底部手势条压住。
	var scene = load("res://scenes/main.tscn").instantiate()
	root.size = Vector2i(844, 390)      # 典型手机横屏（CSS px）
	root.add_child(scene)
	await process_frame
	scene.touch_controls.set_shown(true)
	var ins := {"left": 47.0, "top": 0.0, "right": 47.0, "bottom": 21.0}
	scene.touch_controls.set_safe_insets(ins)
	var info: Dictionary = scene.touch_controls.layout_info()
	var vp: Vector2 = scene.get_viewport().get_visible_rect().size
	var min_x: float = float(ins["left"])
	var max_x: float = vp.x - float(ins["right"])
	var min_y: float = float(ins["top"])
	var max_y: float = vp.y - float(ins["bottom"])
	for name in ["pad", "actions", "hint"]:
		var r: Dictionary = info[name]
		var pos: Vector2 = r["pos"]
		var size: Vector2 = r["size"]
		check(pos.x >= min_x - 1.0 and pos.x + size.x <= max_x + 1.0,
			"%s 应在左右安全区内（x=%.0f w=%.0f 区间=[%.0f,%.0f]）" % [name, pos.x, size.x, min_x, max_x])
		check(pos.y >= min_y - 1.0 and pos.y + size.y <= max_y + 1.0,
			"%s 应在上下安全区内（y=%.0f h=%.0f 区间=[%.0f,%.0f]）" % [name, pos.y, size.y, min_y, max_y])
	# 两个操作区不应互相重叠（D-pad 与动作按钮各占一角）
	var pad: Dictionary = info["pad"]
	var act: Dictionary = info["actions"]
	var pad_r := Rect2(pad["pos"], pad["size"])
	var act_r := Rect2(act["pos"], act["size"])
	check(not pad_r.intersects(act_r), "方向键与动作按钮不应重叠")
	# 底部占位应把安全区算进去（HUD 提示带靠它避让）
	scene.touch_controls.set_safe_insets({"left": 0.0, "top": 0.0, "right": 0.0, "bottom": 60.0})
	check(scene.touch_controls.bottom_inset() >= 60.0, "底部占位应包含安全区高度")
	# 回放中按钮语义应切换成「停止」（触屏没有 Esc）
	scene.touch_controls.set_replay_playing(true)
	check(scene.touch_controls.is_replay_playing(), "回放状态应可切换")
	scene.touch_controls.set_replay_playing(false)
	check(not scene.touch_controls.is_replay_playing(), "回放状态应可恢复")
	scene.free()


func _test_ending() -> void:
	# 全部通关后必须有明确的“旅程结束”（庆祝动画 + 统计 + 出口）。
	# 早期行为是默默滚回第 1 关 —— 玩家会以为游戏出 bug 了。
	var tmp := "user://test_e2e_ending.json"
	_remove_tmp(tmp)
	var scene = load("res://scenes/main.tscn").instantiate()
	root.size = Vector2i(1280, 720)
	root.add_child(scene)
	await process_frame
	check(scene.ending != null, "主场景应创建通关庆祝层")
	check(not scene.ending.is_open(), "初始不应显示庆祝层")

	# 尚未全部通关时不应弹出
	check(not scene._all_completed(), "全新进度不应判定为全部通关")
	scene._show_ending()
	check(not scene.ending.is_open(), "未全部通关时不应弹出庆祝层")

	# 标记全部通关
	var p = scene.progress
	for e in scene.entries:
		var opt: int = maxi(int(e.get("optimal", 1)), 1)
		var moves: Array = []
		for _i in range(opt):
			moves.append("right")
		p.record_win(str(e["key"]), moves)
	check(scene._all_completed(), "全部通关后应判定为完成")
	scene._show_ending()
	check(scene.ending.is_open(), "全部通关后应弹出庆祝层")
	check(scene.ending.title_text().contains("通关"), "庆祝标题应明确“通关”")
	check(scene.ending.subtitle_text().contains("%d / %d" % [scene.entries.size(), scene.entries.size()]),
		"副标题应显示 20 / 20 关")
	var stats: String = scene.ending.stats_text()
	check(stats.contains("总步数"), "统计应含总步数")
	check(stats.contains("达最优"), "统计应含最优关数")
	check(scene.ending.button_count() == 2, "庆祝层应有两个明确出口（再玩一次 / 回到选关）")
	await create_timer(0.4).timeout
	check(scene.ending.confetti_count() > 0, "庆祝时应撒花（有动画）")
	check(not scene.hud_layer.visible, "庆祝层打开时 HUD 应让位")
	check(not scene.touch_controls.is_shown(), "庆祝层打开时触屏控件应让位")

	# **回归测试**：庆祝动画的判据必须是「这一局刚好补完最后一关」这个**跃迁**，
	# 而不是「当前已全部通关」这个**持久状态**。
	# 后者会让全部通关之后的每一次通关都被再恭喜一次（真实 bug：回头刷第 1 关也恭喜）。
	scene.ending.close()
	scene._do_load(0)
	scene._run_moves = ["right"]
	await scene._on_won()
	check(not scene.ending.is_open(), "全部通关后再打通单关不应重复弹出庆祝动画")
	check(scene.transitioning or scene.current_index != 0, "应走普通换关流程")
	await create_timer(1.6).timeout

	# 但庆祝动画不该是一次性的：选关界面提供「回顾通关」入口，
	# 而且在**没有**全部通关时不可见（否则又是一次“随时都能被恭喜”）。
	scene.level_select.open_with(scene.entries, scene.progress, 0)
	check(scene.level_select.celebrate_button() != null, "选关界面应有「回顾通关」按钮")
	check(scene.level_select.celebrate_button().visible, "全部通关后「回顾通关」应可见")
	scene.level_select.celebrate_button().pressed.emit()
	check(scene.ending.is_open(), "点「回顾通关」应重新打开庆祝层")
	scene.ending.close()
	await create_timer(0.2).timeout
	var fresh2 = Progress.new(tmp + ".fresh")
	fresh2.reset()
	scene.level_select.open_with(scene.entries, fresh2, 0)
	check(not scene.level_select.celebrate_button().visible, "未全部通关时「回顾通关」不应可见")
	scene.level_select.close()
	await create_timer(0.2).timeout
	_remove_tmp(tmp + ".fresh")

	# 出口 1：「再玩一遍」= 开始新一轮。
	# 语义必须是「清本轮通关进度，但绝不动玩家的记录、也绝不重锁关卡」：
	#   · 不清本轮进度 → 第二轮打完不会再有庆祝，玩家一辈子只能被恭喜一次
	#   · 清掉记录/重锁关卡 → 等于惩罚玩家重玩
	var bests: Array = []
	for e in scene.entries:
		bests.append(scene.progress.best_moves(str(e["key"])))
	scene._on_ending_restart()
	check(not scene.ending.is_open(), "点“再玩一遍”应关闭庆祝层")
	check(scene.current_index == 0, "应从第 1 关重新开始")
	check(scene.progress.completed_count() == 0, "再玩一遍应清空**本轮**通关进度")
	check(scene.progress.ever_count() == scene.entries.size(), "历史通关记录应保留（记录是玩家的资产）")
	var kept_best := true
	for i in range(scene.entries.size()):
		if scene.progress.best_moves(str(scene.entries[i]["key"])) != int(bests[i]):
			kept_best = false
	check(kept_best, "再玩一遍不应动最佳步数记录")
	check(scene.progress.has_replay("level_01"), "再玩一遍不应删掉最佳回放")
	# 关卡不能因为“再玩一遍”而被重新锁上（否则玩家想直接重玩后面某关就做不到了）
	var all_unlocked := true
	for i in range(scene.entries.size()):
		if not scene.progress.is_unlocked(i, scene._level_keys()):
			all_unlocked = false
	check(all_unlocked, "再玩一遍后所有曾解锁的关卡应保持解锁")
	check(scene.progress.replay_round(), "重玩一轮期间应能识别出“本轮”状态")
	# 而且第二轮必须能再次迎来庆祝：重新补满 20/20 时应当触发
	scene.ending.close()
	await create_timer(0.2).timeout
	var back_to_full := true
	for e in scene.entries:
		scene.progress.record_win(str(e["key"]), ["right"])
		if not scene.progress.is_completed(str(e["key"])):
			back_to_full = false
	check(back_to_full and scene._all_completed(), "第二轮应能重新补满全部通关")
	check(not scene.progress.replay_round(), "补满后不应还处于“本轮未完成”状态")

	# 出口 2：回到选关
	scene._show_ending()
	scene._on_ending_select()
	check(not scene.ending.is_open(), "点“回到选关”应关闭庆祝层")
	check(scene.level_select.is_open(), "应打开选关界面")
	scene.level_select.close()
	await create_timer(0.3).timeout

	# 庆祝层也要避开安全区（横屏刘海机型上卡片不能被切掉）
	var ins := {"left": 47.0, "top": 0.0, "right": 47.0, "bottom": 21.0}
	scene.ending.set_safe_insets(ins)
	scene._show_ending()
	var r: Rect2 = scene.ending.card_rect()
	check(r.position.x >= float(ins["left"]) - 1.0, "庆祝卡片应避开左安全区")
	check(r.position.x + r.size.x <= 1280.0 - float(ins["right"]) + 1.0, "庆祝卡片应避开右安全区")
	check(r.position.y + r.size.y <= 720.0 - float(ins["bottom"]) + 1.0, "庆祝卡片应避开下安全区")
	scene.ending.close()
	await create_timer(0.3).timeout
	scene.free()
	_remove_tmp(tmp)


func _test_move_animation_geometry() -> void:
	# 回归测试：**状态对、但画出来的方块错位**。
	# 真实 bug：落地挤压缩放的是 block 节点，而它的子网格用的是世界格坐标 ——
	# 缩放父节点会把子节点的位置一起缩放，于是方块每走一步都朝世界原点窜一下。
	# 这类问题纯逻辑测试完全测不到，必须断言「渲染出来的位置」。
	var scene = load("res://scenes/main.tscn").instantiate()
	root.size = Vector2i(960, 540)
	root.add_child(scene)
	await process_frame
	# 用一盘大关卡：离原点越远，缩放导致的位移越明显
	scene._load_level(9, false)
	await process_frame
	check(scene.game.animate, "交互场景应开启动画")

	# 1) 静止时：渲染位置必须与状态单元一一对应
	_eq_centers(scene.game.block_mesh_centers(), scene.game.state.world_cells(), "静止时渲染位置应与状态一致")

	# 2) 移动过程中：**不允许出现任何挤压**（方块是刚体，每步都果冻一下像渲染故障），
	#    并且**每一帧**方块都必须待在棋盘附近。
	#    这条中间帧不变式是关键：真实 bug 是「动画期间整块被平移（甚至闪到世界原点），
	#    但落点因为重建而显示正常」—— 只查开始/结束位置完全测不出来。
	var d: Vector3i = scene.game.core.legal_moves()[0]
	var c0: Vector3 = _centroid(scene.game.block_mesh_centers())
	var step: Dictionary = scene.game._plan_move(d)
	var c1: Vector3 = _centroid(_as_centers(step["to_cells"]))
	scene.game.try_move(d)
	var scaled_during := false
	var stray_frames: int = 0
	var guard: int = 0
	while scene.game.animating and guard < 400:
		if scene.game._block_pivot.scale.distance_to(Vector3.ONE) > 0.001:
			scaled_during = true
		var c: Vector3 = _centroid(scene.game.block_mesh_centers())
		if _dist_to_segment(c, c0, c1) > 1.0:
			stray_frames += 1
		await process_frame
		guard += 1
	check(not scene.game.animating, "翻滚动画应结束")
	check(not scaled_during, "普通移动过程中不应有挤压缩放（只允许重生落地那一次）")
	check(stray_frames == 0,
		"动画每一帧方块都应贴着起点→终点这条弧线（有 %d 帧跑偏）" % stray_frames)

	# 3) 移动结束后：渲染位置仍必须与状态一一对应（缩放不能残留、不能平移）
	_eq_centers(scene.game.block_mesh_centers(), scene.game.state.world_cells(), "移动后渲染位置应与状态一致")
	check(scene.game.block.scale.distance_to(Vector3.ONE) < 0.001, "移动后 block 不应残留缩放")
	check(scene.game._block_pivot.scale.distance_to(Vector3.ONE) < 0.001, "移动后 pivot 不应残留缩放")

	# 4) 连续走多步，误差不允许累积。
	# 注意：随便走会掉下去或提前到终点（那时方块已被销毁/已复位），
	# 这两种情况都不是本测试要查的，遇到就停。
	var alive: bool = true
	for _i in range(3):
		if scene.game.is_lost() or scene.game.is_won():
			alive = false
			break
		var legal: Array = scene.game.core.legal_moves()
		if legal.is_empty():
			break
		scene.game.try_move(legal[0])
		guard = 0
		while scene.game.animating and guard < 400:
			await process_frame
			guard += 1
	if alive and not scene.game.is_lost() and not scene.game.is_won():
		_eq_centers(scene.game.block_mesh_centers(), scene.game.state.world_cells(),
			"连续移动后渲染位置应与状态一致")
	await create_timer(0.2).timeout
	scene.free()


func _centroid(pts: Array) -> Vector3:
	var c := Vector3.ZERO
	for p in pts:
		c += p
	return c / float(maxi(pts.size(), 1))


func _as_centers(cells: Array) -> Array:
	var out: Array = []
	for c in cells:
		out.append(Vector3(float(c.x), float(c.y) + 0.5, float(c.z)))
	return out


func _dist_to_segment(p: Vector3, a: Vector3, b: Vector3) -> float:
	# 点到线段距离：翻滚时质心只会在起点→终点之间划一段小弧（半径 ~1.1 的 90° 弧），
	# 所以“偏离这条线段超过 1.0”就意味着整块被平移走了（例如闪到世界原点）。
	var ab: Vector3 = b - a
	var denom: float = ab.length_squared()
	if denom < 0.000001:
		return p.distance_to(a)
	var t: float = clampf((p - a).dot(ab) / denom, 0.0, 1.0)
	return p.distance_to(a + ab * t)


func _eq_centers(got: Array, cells: Array, msg: String) -> void:
	# 把状态单元换算成「单元中心」再逐项比对（渲染把方块抬高 0.5 贴地）
	var want: Array = []
	for c in cells:
		want.append(Vector3(float(c.x), float(c.y) + 0.5, float(c.z)))
	want.sort_custom(func(a, b) -> bool:
		if a.x != b.x: return a.x < b.x
		if a.z != b.z: return a.z < b.z
		return a.y < b.y)
	check(got.size() == want.size(), "%s（数量 %d vs %d）" % [msg, got.size(), want.size()])
	if got.size() != want.size():
		return
	for i in range(want.size()):
		check(got[i].distance_to(want[i]) < 0.02,
			"%s（第 %d 项 %.2f,%.2f,%.2f vs %.2f,%.2f,%.2f）" % [msg, i,
				got[i].x, got[i].y, got[i].z, want[i].x, want[i].y, want[i].z])
