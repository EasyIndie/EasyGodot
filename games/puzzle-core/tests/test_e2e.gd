# test_e2e.gd — 视觉层 + 集成 E2E 测试（headless）。
# 验证：Game 节点加载关卡/渲染/应用解路径达胜，输入映射，主场景实例化。
extends SceneTree

const Game = preload("res://scenes/game.gd")
const Solver = preload("res://solver/solver.gd")
const Moves = preload("res://core/moves.gd")
const Loader = preload("res://core/level_loader.gd")
const Fixtures = preload("res://tests/fixtures.gd")
const Progress = preload("res://meta/progress.gd")

var checks: int = 0
var failures: int = 0


func _init() -> void:
	_run()


func _run() -> void:
	_test_game_direct()
	_test_cube_level()
	_test_fall()
	_test_void_fall()
	_test_input_mapping()
	_test_all_levels_render()
	await _test_scene()
	await _test_level_select()
	await _test_replay_playback()
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
	check(game.board_root != null and game.board_root.get_child_count() == tiles, "棋盘应只渲染实心瓦片（空洞留空）")
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


func _test_cube_level() -> void:
	# Cube（单格形状）应能端到端跑通：加载 → 渲染 1 格 → 沿解走 → 获胜
	var game = Game.new()
	game.animate = false
	root.add_child(game)
	check(game.load_dict(Loader.load_dict(Fixtures.cube_level())), "cube 夹具应加载成功")
	check(game.state.shape.id == "cube", "形状应为 cube")
	check(game.state.world_cells().size() == 1, "cube 应只占 1 格")
	check(game.block.get_child_count() == 1, "cube 应只渲染 1 个单元")
	var tiles: int = game.board.grid_x * game.board.grid_z - game.board.holes.size()
	check(game.board_root.get_child_count() == tiles, "cube 关卡的棋盘渲染应正确")

	var sol: Dictionary = Solver.new(game.board, game.state).solve()
	check(sol["solvable"], "cube 夹具应可解")
	for label in sol["solution"]:
		check(game.try_move(Moves.direction_from_label(label)), "cube 移动应成功: " + str(label))
	check(game.is_won(), "cube 走到目标应获胜")

	# cube 越界翻滚应触发坠落（与 domino 共用同一套「无地面」判定）
	game.load_dict(Loader.load_dict(Fixtures.cube_level()))
	check(game.try_move(Vector3i(-1, 0, 0)), "cube 越界翻滚应被接受（触发坠落）")
	check(game.is_lost(), "cube 越界后应坠落失败")
	game.free()


func _test_all_levels_render() -> void:
	# 内容完整性：levels/ 下每一关都应能被视觉层加载并正确渲染（含 cube 关）
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
		check(game.board_root.get_child_count() == tiles, "棋盘渲染应正确: " + p)
		shapes[game.state.shape.id] = true
		game.free()

	check(shapes.has("domino"), "关卡集应包含 domino 关")
	check(shapes.has("cube"), "关卡集应包含 cube 关")


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
	check(shapes.has("cube"), "元数据应包含 cube 关")

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
