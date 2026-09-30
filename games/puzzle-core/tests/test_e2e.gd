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
	await _test_touch_controls()
	await _test_respawn_animation()
	await _test_swipe_hint()
	await _test_touch_safe_area()
	await _test_ending()
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
	check(game.block.get_child_count() == game.state.world_cells().size(), "方块单元数应等于世界单元数")

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
	check(game.block.get_child_count() == 2, "骨牌应渲染 2 个单元")
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
		check(game.block.get_child_count() == game.state.world_cells().size(), "方块单元数应正确: " + p)
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


func _test_touch_controls() -> void:
	# 触屏操作层：滑动方向映射、按钮联动、不与选关/过渡打架
	# 1) 滑动→方向：必须按**屏幕方向**映射（往哪滑、方块就往哪滚）
	#    斜 45° 等距相机：-z 右上、+x 右下、+z 左下、-x 左上
	check(TouchControls.swipe_dir(Vector2(80, -56)) == Vector3i(0, 0, -1), "右上滑应映射 -z")
	check(TouchControls.swipe_dir(Vector2(80, 56)) == Vector3i(1, 0, 0), "右下滑应映射 +x")
	check(TouchControls.swipe_dir(Vector2(-80, 56)) == Vector3i(0, 0, 1), "左下滑应映射 +z")
	check(TouchControls.swipe_dir(Vector2(-80, -56)) == Vector3i(-1, 0, 0), "左上滑应映射 -x")
	check(TouchControls.swipe_dir(Vector2(10, 4)) == Vector3i.ZERO, "过短位移不应算滑动")
	# 旧行为（按网格轴映射）是错的：向上滑曾经会让方块往右上滚
	check(TouchControls.swipe_dir(Vector2(0, -100)) != Vector3i(1, 0, 0),
		"正上方滑动绝不能是「右下」方向（那是旧轴映射的 bug）")

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

	# 出口 1：回到第 1 关（不清进度：记录是玩家的资产）
	scene._on_ending_restart()
	check(not scene.ending.is_open(), "点“再玩一次”应关闭庆祝层")
	check(scene.current_index == 0, "应回到第 1 关")
	check(scene.progress.completed_count() == scene.entries.size(), "再玩一次不应清空进度记录")

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
