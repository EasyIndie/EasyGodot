# main.gd — 主场景：摄像机 + 光照 + 环境 + Game + HUD + 关卡管理 + 选关 + 回放 + 输入桥接。
extends Node3D

const Game = preload("res://scenes/game.gd")
const Moves = preload("res://core/moves.gd")
const Progress = preload("res://meta/progress.gd")
const LevelSelect = preload("res://meta/level_select.gd")
const TouchControls = preload("res://meta/touch_controls.gd")
const UiLayout = preload("res://meta/ui_layout.gd")
const RenderQuality = preload("res://meta/render_quality.gd")
const Ending = preload("res://meta/ending.gd")
const Leaderboard = preload("res://meta/leaderboard.gd")
const Stopwatch = preload("res://meta/stopwatch.gd")

var game: Node3D = null
var cam: Camera3D = null
var light: DirectionalLight3D = null
var levels: Array = []          # 关卡路径列表（res://...）
var entries: Array = []         # 关卡元数据（与 levels 同序）：{key, path, shape, optimal, difficulty}
var current_index: int = -1
var progress = null             # 玩家进度（已完成 / 最佳步数 / 最佳回放）
var clock = null                # 秒表：最快时间记录（起停规则见 _clock_should_run）
var _app_paused: bool = false   # 切后台 / 失焦：计时与画质采样都要停
var _clock_shown: int = -1      # HUD 上已经画出的计时（只在真正变化时改文本）
var level_select = null         # 选关界面
var _run_moves: Array = []      # 本局已走的方向标签序列（用于 Replay）
const REPLAY_BEAT := 0.34   # 回放每步之间的停顿（让回放看起来像“一个人在玩”）
var _replaying: bool = false
var replay_label: Label
var hud_layer: CanvasLayer
# ?lite=1：低端 GPU / 排障开关——关阴影与渐变幕布、停逐帧材质更新
var lite_mode: bool = false
# 触屏操作层（仅在触屏设备显示；可用 ?touch=1 / ?touch=0 强制，桌面可按 T 切换）
var touch_controls = null
var _touch_active: bool = false
var _query_string: String = ""
# 通关庆祝层（全部 20 关通关后出现）
var ending = null
# 安全区域（刘海 / 灵动岛 / 底部手势条）每边被遮挡的像素数
var _safe_insets: Dictionary = {"left": 0.0, "top": 0.0, "right": 0.0, "bottom": 0.0}
# 自适应画质档位（见 meta/render_quality.gd）
var _quality_tier: int = 3
var _q_accum: float = 0.0
var _q_frames: int = 0
var _q_elapsed: float = 0.0

# HUD 节点
var level_label: Label
var moves_label: Label
var time_label: Label
var win_label: Label
var fail_label: Label
var help_label: Label
var best_label: Label
var progress_bar: ProgressBar
var _hud_narrow: bool = false
var left_panel: PanelContainer
var right_panel: PanelContainer
var backdrop: MeshInstance3D = null

# 存档路径覆盖（测试用；空 = 用默认 user://progress.json）
const PROGRESS_PATH_SETTING := "puzzle/progress_path"
const LEFT_PANEL_W := 236.0
const RIGHT_PANEL_W := 196.0

const LIGHT_ENERGY := 1.15  # 主光基础亮度

# 关卡切换过渡（棋盘下沉 + 暗幕，衔接自然）
const FADE_TIME := 0.4      # 暗幕淡入/淡出时长（秒）
const SLIDE_IN := 4.0       # 过渡时棋盘升降的位移
var fade: ColorRect
var transition_label: Label
var transitioning: bool = false


func _ready() -> void:
	if OS.has_feature("web"):
		_query_string = str(JavaScriptBridge.eval("window.location.search", true))
	lite_mode = _query_flag("lite")
	# 画质档位：默认按设备类别起步，?tier=0..3 可强制（排障用）
	var tier_arg: String = _query_value("tier", "")
	if tier_arg == "":
		_quality_tier = RenderQuality.initial_tier(_touch_wanted_early(), lite_mode)
	else:
		_quality_tier = clampi(int(float(tier_arg)), 0, RenderQuality.TIERS - 1)
	_setup_camera()
	_setup_light()
	_setup_environment()
	_setup_backdrop()
	_setup_hud()
	_setup_transition()
	_setup_touch_controls()
	_setup_ending()
	progress = Progress.new(_progress_path())
	levels = _scan_levels()
	_setup_level_select()
	game = Game.new()
	game.low_effects = lite_mode
	game.name = "Game"
	add_child(game)
	game.moved.connect(_on_moved)
	game.won.connect(_on_won)
	game.fell.connect(_on_fell)
	clock = Stopwatch.new()
	_load_level(0, false)
	_apply_tv_ui_scale()
	# 移动端的「返回」：根窗口发 go_back_requested（Android 返回键 / iOS 边缘返回手势）。
	# 必须在 project.godot 里把 application/config/quit_on_go_back 设为 false，
	# 否则引擎会直接退出（表现就是「按一下返回 = 闪退」）。
	get_tree().root.go_back_requested.connect(_on_back_requested)
	_apply_render_quality()
	_update_safe_area()
	_refresh_bands()
	if not get_viewport().size_changed.is_connected(_on_viewport_resized):
		get_viewport().size_changed.connect(_on_viewport_resized)


func _progress_path() -> String:
	# 存档路径可被项目设置覆盖：集成测试会把它指到临时文件。
	# 为什么需要这个口子：测试曾经直接写真实的 user://progress.json，
	# 于是「全新进度」的断言在第二次运行时就不成立了（上次跑测留下的记录还在）。
	# 测试污染玩家存档本身就是 bug，顺手在这里堵掉。
	var p: String = str(ProjectSettings.get_setting(PROGRESS_PATH_SETTING, ""))
	return p if p != "" else Progress.DEFAULT_PATH


func _query_flag(name: String) -> bool:
	# 读取 URL 查询参数（仅 Web 有效），用于低端 GPU / 触屏等开关
	return _query_string.contains(name + "=1")


func _query_value(name: String, fallback: String) -> String:
	# 读取形如 ?name=value 的数值型查询参数
	var m := RegEx.new()
	m.compile("[?&]" + name + "=([0-9.]+)")
	var r := m.search(_query_string)
	return r.get_string(1) if r != null else fallback


func _touch_wanted_early() -> bool:
	# _ready 早期就要决定画质档位，此时 touch_controls 还没建好，
	# 所以这里单独判定一次（与 _touch_wanted() 同一套规则）
	if _query_string.contains("touch=1"):
		return true
	if _query_string.contains("touch=0"):
		return false
	return DisplayServer.is_touchscreen_available()


# ── 画质（自适应）───────────────────────────────────────────

func _apply_render_quality() -> void:
	# 把档位落到具体渲染设置上。改档只在**真正变化**时发生，
	# 所以玩家看到的是「一开始就清晰」，而不是画质来回闪。
	var vp := get_viewport()
	if vp != null:
		vp.msaa_3d = RenderQuality.msaa(_quality_tier)
	if light != null:
		light.shadow_enabled = RenderQuality.shadows(_quality_tier)
	if backdrop != null:
		backdrop.visible = RenderQuality.backdrop(_quality_tier)
	if game != null:
		game.low_effects = not RenderQuality.glow(_quality_tier)
		game.set_quality_tier(_quality_tier)


func _process(delta: float) -> void:
	_refresh_clock()
	_update_clock_label()
	# 自适应画质：按实测帧时间升降档（带滞回，避免抖动）
	_q_accum += delta
	_q_frames += 1
	_q_elapsed += delta
	if _q_elapsed < RenderQuality.SAMPLE_SEC or _q_frames < 10:
		return
	var avg_ms: float = _q_accum / float(_q_frames) * 1000.0
	var next: int = RenderQuality.next_tier(_quality_tier, avg_ms, _q_elapsed)
	_q_accum = 0.0
	_q_frames = 0
	_q_elapsed = 0.0
	if next != _quality_tier:
		_quality_tier = next
		_apply_render_quality()


func primary_action() -> String:
	# 遥控器只有一个「确认」键（Enter / 空格 / 手柄 A 都是它的上报形式），
	# 它必须**上下文相关**，否则电视玩家掉下去就卡死了：
	#   回放中 → 停止回放；已坠落 → 重开；已通关 → 下一关；其余 → 什么都不做
	# 「其余不做」是刻意的：对局中按确认就弹选关会让键盘玩家觉得很意外，
	# 而选关本来就有专门入口（L / 返回键 / 屏幕按钮）。
	if _replaying:
		return "stop_replay"
	if game == null or transitioning:
		return "ignore"
	if game.is_lost():
		return "restart"
	if game.is_won():
		return "next_level"
	return "ignore"


func _on_primary_action() -> void:
	match primary_action():
		"stop_replay":
			_replaying = false
			if touch_controls != null:
				touch_controls.set_replay_playing(false)
			_reset_to_start()
		"restart":
			_restart()
		"next_level":
			_next_level()


func back_action() -> String:
	# 「返回」该做什么 —— **纯判断**，不产生副作用。
	# 拆出来是为了能测：其中一个分支会退出游戏，测不了就会变成“没人敢碰”的死代码。
	# 层级（顺序很重要）：
	#   庆祝层 → 选关 → 回放 → 对局中（打开选关）→ 在选关里（退出游戏）
	# 玩家因此永远不会因为误触返回而丢掉当前局面；要退出得先回主页再按一次。
	if ending != null and ending.is_open():
		return "close_ending"
	if level_select != null and level_select.is_open():
		# 选关界面相当于本作的「主页」（进度、最佳、回放都在这里），在主页按返回才是退出
		return "quit"
	if _replaying:
		return "stop_replay"
	if transitioning or game == null or game.is_won() or game.is_lost():
		return "ignore"
	return "open_select"


func _on_back_requested() -> void:
	match back_action():
		"close_ending":
			ending.close()
		"quit":
			get_tree().quit()
		"stop_replay":
			_replaying = false
			if touch_controls != null:
				touch_controls.set_replay_playing(false)
			_reset_to_start()
		"open_select":
			_open_level_select()


func _notification(what: int) -> void:
	# 切到后台 / 被系统打断（来电、切应用）：
	# 自适应画质是按**帧时间平均值**升降档的，切后台回来第一帧的 delta 可能是几百毫秒，
	# 不清零就会把画质档位一次打到底（弱机型尤其明显）。
	match what:
		NOTIFICATION_APPLICATION_PAUSED, NOTIFICATION_APPLICATION_FOCUS_OUT:
			# 切后台要停表：接个电话回来发现「最快时间」多了三分钟，玩家会认为记录是假的
			_app_paused = true
			_refresh_clock()
			_reset_quality_sampling()
		NOTIFICATION_APPLICATION_RESUMED, NOTIFICATION_APPLICATION_FOCUS_IN:
			_app_paused = false
			_refresh_clock()
			_reset_quality_sampling()


func _reset_quality_sampling() -> void:
	_q_accum = 0.0
	_q_frames = 0
	_q_elapsed = 0.0


# ── 安全区域 ──────────────────────────────────────────────

func _on_viewport_resized() -> void:
	_update_safe_area()
	_apply_tv_ui_scale()
	_refresh_bands()


func _clock_should_run() -> bool:
	# 计时的起停规则集中在**一个函数**里（而不是各处零散 start/stop）：
	# 只要漏了一条分支，玩家的「最快时间」就被污染了，而这种错误手动测试几乎发现不了。
	# 任何打断「专注解题」的状态都必须停表：载入过渡 / 回放 / 选关 / 庆祝 / 切后台 / 已坠落 / 已通关
	if clock == null or game == null:
		return false
	if transitioning or _replaying or _app_paused:
		return false
	if game.is_lost() or game.is_won():
		return false
	if level_select != null and level_select.is_open():
		return false
	if ending != null and ending.is_open():
		return false
	return true


func _refresh_clock() -> void:
	# 幂等 → 可以放心每帧调用（状态没变时是空操作）
	if clock != null:
		clock.set_running(_clock_should_run())


func _reset_clock() -> void:
	if clock != null:
		clock.reset()
	_clock_shown = -1


func _update_clock_label(force: bool = false) -> void:
	# 只在**显示的百分秒位真的变了**时才写文本：每帧 set_text 会白白触发布局重排
	if time_label == null or clock == null:
		return
	var ms: int = clock.elapsed_ms()
	var tick: int = ms / 100
	if not force and tick == _clock_shown:
		return
	_clock_shown = tick
	time_label.text = Leaderboard.format_clock(ms)


func _apply_ghost_setting(on: bool) -> void:
	# 一处改状态的**唯一**入口：游戏层结构 + 存档偏好 + 界面按钮显示，三者始终一致
	progress.set_ghost_enabled(on)
	game.set_ghost_enabled(on)
	if level_select != null:
		level_select.set_ghost_state(on)
	if on:
		_play_ghost_for_current()


func _toggle_ghost() -> void:
	_apply_ghost_setting(not progress.ghost_enabled())


func _on_ghost_toggled(on: bool) -> void:
	_apply_ghost_setting(on)


func _play_ghost_for_current() -> void:
	# 没有任何记录时什么都不做（新关卡没有“上次的走法”）
	if game == null or not progress.ghost_enabled():
		game.set_ghost_enabled(false)
		return
	var key: String = _level_key(current_index)
	if key == "" or not progress.has_replay(key):
		game.set_ghost_enabled(false)
		return
	game.set_ghost_enabled(true)
	# 先等玩家方块的入场下落演完：两个方块同时翻滚，屏幕上是看不出谁是谁的
	await _wait_for_anim()
	# 等待期间可能已经换关了 —— 那就交给那一次调用（避免两次播放叠在一起）
	if _level_key(current_index) != key:
		return
	game.play_ghost(progress.replay(key).get("moves", []))


func _is_tv_like() -> bool:
	# 「移动平台 + 没有触摸屏」= 电视 / 电视盒子（见 ui_layout.is_tv_like 的说明）
	#
	# GF_FORCE_TV=1/0 是**排障与预览开关**：桌面二进制的 OS.has_feature("mobile") 永远为假，
	# 所以想在显示器上预览电视布局（10 尺字号、5% 过扫描边距）或为它写截图测试，
	# 必须有个显式覆盖。默认不设置 = 按真实环境判断。
	var forced: String = OS.get_environment("GF_FORCE_TV")
	if forced == "1":
		return true
	if forced == "0":
		return false
	return UiLayout.is_tv_like(OS.has_feature("mobile"), DisplayServer.is_touchscreen_available())


func _apply_tv_ui_scale() -> void:
	# 10 尺 UI：电视要隔三米看，同样的像素尺寸在 4K 电视上小得看不清。
	# 用 Window.content_scale_factor 整体放大 UI（3D 仍按原生分辨率渲染，棋盘不变形），
	# 于是 HUD / 选关 / 庆祝层一起变大，不用一处一处改字号。
	var vp: Vector2 = get_viewport().get_visible_rect().size
	var want: float = UiLayout.tv_ui_scale(minf(vp.x, vp.y)) if _is_tv_like() else 1.0
	var win := get_window()
	if win != null and not is_equal_approx(win.content_scale_factor, want):
		win.content_scale_factor = want


func _update_safe_area() -> void:
	# 各平台把「每边被系统 UI 遮挡多少像素」告诉我们，这里只负责换算 + 夹取。
	# Web 读 CSS env(safe-area-inset-*)，原生平台读 DisplayServer 的可用区域。
	var vp_size: Vector2 = get_viewport().get_visible_rect().size
	var raw: Dictionary = {}
	if OS.has_feature("web"):
		raw = UiLayout.parse_insets(str(JavaScriptBridge.eval("window.gfSafeInsets()", true)))
	else:
		var area: Rect2i = DisplayServer.get_display_safe_area()
		var win: Vector2i = DisplayServer.window_get_size()
		if win.x > 0 and win.y > 0 and area.size.x > 0:
			var sc := Vector2(vp_size) / Vector2(win)
			raw = {
				"left": float(area.position.x) * sc.x,
				"top": float(area.position.y) * sc.y,
				"right": float(maxi(win.x - area.position.x - area.size.x, 0)) * sc.x,
				"bottom": float(maxi(win.y - area.position.y - area.size.y, 0)) * sc.y,
			}
	var ins: Dictionary = UiLayout.safe_insets(vp_size, raw)
	# 电视会裁掉四周约 5%（过扫描），而系统安全区在电视上通常报 0 → 兜一个下限
	if _is_tv_like():
		ins = UiLayout.apply_tv_floor(ins, vp_size)
	if UiLayout.insets_equal(ins, _safe_insets):
		return
	_safe_insets = ins
	if touch_controls != null:
		touch_controls.set_safe_insets(ins)
	if level_select != null:
		level_select.set_safe_insets(ins)
	if ending != null:
		ending.set_safe_insets(ins)
	_apply_hud_insets()


func _apply_hud_insets() -> void:
	# HUD 两块面板必须整体避开安全区（否则横屏 iPhone 上左上角的关卡面板会被灵动岛切掉），
	# 并且**必须能在窄屏上共存**：手机竖屏只有 ~390px 宽，
	# 按固定 236+196 的尺寸摆会直接互相压住（截图里「已通关 20 / 20」压到了步数上）。
	if left_panel == null or right_panel == null:
		return
	var vp: Vector2 = get_viewport().get_visible_rect().size
	var sl: float = float(_safe_insets.get("left", 0.0)) + 22.0
	var sr: float = float(_safe_insets.get("right", 0.0)) + 22.0
	var st: float = float(_safe_insets.get("top", 0.0)) + 20.0
	# 可用宽度按比例分给两块面板：左边拿大头（关卡文字更长），右边保证最小可读宽度
	var avail: float = maxf(vp.x - sl - sr, 120.0)
	var gap: float = 12.0
	var lw: float = clampf(minf(LEFT_PANEL_W, (avail - gap) * 0.56), 120.0, LEFT_PANEL_W)
	var rw: float = clampf(minf(RIGHT_PANEL_W, avail - gap - lw), 92.0, RIGHT_PANEL_W)
	var narrow: bool = vp.x < 620.0
	# 窄屏同时缩小字号 + 缩短文案（宁可信息少一点，也不要溢出错行）
	level_label.add_theme_font_size_override("font_size", 16 if narrow else 21)
	moves_label.add_theme_font_size_override("font_size", 16 if narrow else 21)
	best_label.add_theme_font_size_override("font_size", 11 if narrow else 13)
	_hud_narrow = narrow
	left_panel.offset_left = sl
	left_panel.offset_right = sl + lw
	left_panel.offset_top = st
	left_panel.offset_bottom = st + 78.0
	right_panel.offset_left = -sr - rw
	right_panel.offset_right = -sr
	right_panel.offset_top = st
	right_panel.offset_bottom = st + 78.0
	_update_hud()


func _setup_touch_controls() -> void:
	touch_controls = TouchControls.new()
	touch_controls.name = "TouchControls"
	add_child(touch_controls)
	touch_controls.direction.connect(_on_touch_direction)
	touch_controls.restart_pressed.connect(_on_touch_restart)
	touch_controls.select_pressed.connect(_open_level_select)
	touch_controls.replay_pressed.connect(_on_touch_replay)
	_touch_active = _touch_wanted()
	_apply_touch_visibility()


func _touch_wanted() -> bool:
	# 触屏设备才显示操作层；?touch=1 / ?touch=0 可强制（便于在桌面调试触屏 UI）
	if _query_string.contains("touch=1"):
		return true
	if _query_string.contains("touch=0"):
		return false
	return DisplayServer.is_touchscreen_available()


func _apply_touch_visibility() -> void:
	if touch_controls == null:
		return
	var hud_hidden: bool = hud_layer != null and not hud_layer.visible
	touch_controls.set_shown(_touch_active and not hud_hidden)
	_refresh_bands()


func _on_touch_direction(d: Vector3i) -> void:
	# 触屏滑动/方向键与键盘走同一条路径，但要避开选关、过渡、回放、庆祝界面
	if transitioning or _replaying:
		return
	if level_select != null and level_select.is_open():
		return
	if ending != null and ending.is_open():
		return
	var ok: bool = _do_move(d)
	# 玩家真的动了一次方块 → 手势提示的使命完成
	if ok and touch_controls != null:
		touch_controls.dismiss_swipe_hint()


func _refresh_bands() -> void:
	# 统一安排「提示带」：
	#   桌面   -> 底部（棋盘下方，原本帮助文字的位置）
	#   触屏   -> **一律顶部**（HUD 面板下方）
	# 触屏为什么不分横竖屏：横屏时方向键+动作按钮会占掉底部约 40% 高度，
	# 若把提示带放在控件上方，它就正好落在屏幕垂直中央 —— 压住棋盘正中，
	# 玩家看不到自己刚做了什么（这正是提示带最不该出现的位置）。
	# 一律避开安全区域（刘海/灵动岛/底部手势条）；任何朝向下都不压棋盘、不被系统 UI 遮住。
	if help_label == null:
		return
	var vp: Vector2 = get_viewport().get_visible_rect().size
	var touch_on: bool = touch_controls != null and touch_controls.is_shown()
	var at_top: bool = touch_on
	var sl: float = float(_safe_insets.get("left", 0.0))
	var sr: float = float(_safe_insets.get("right", 0.0))
	var st: float = float(_safe_insets.get("top", 0.0))
	var sb: float = float(_safe_insets.get("bottom", 0.0))
	var band_h: float = 46.0
	var y: float
	if at_top:
		y = st + 82.0            # 让开 HUD 面板
	else:
		var occupied: float = sb
		if touch_on:
			# 底部控件（含其自身的安全区占位）之上
			occupied = maxf(occupied, touch_controls.bottom_inset())
		y = vp.y - occupied - 10.0
	for l in [help_label, win_label, fail_label, replay_label]:
		if l == null:
			continue
		l.anchor_left = 0.0
		l.anchor_right = 1.0
		l.offset_left = sl + 12.0
		l.offset_right = -(sr + 12.0)
		l.anchor_top = 0.0 if at_top else 1.0
		l.anchor_bottom = l.anchor_top
		# 注意：底部锚点下的 offset 是**相对屏幕底边**的偏移（负值向上）。
		# 早先把屏幕绝对坐标直接写进 offset 直接把提示带到屏幕外了（top=1040 / vp=720）。
		if at_top:
			l.offset_top = y
			l.offset_bottom = y + band_h
		else:
			l.offset_top = y - band_h - vp.y
			l.offset_bottom = y - vp.y
	var base: String
	if touch_on:
		# 与「手势提示」分工：这里说按钮，提示条说滑动手势（早期两条文案说的是同一件事，
		# 屏幕上却出现两行几乎一样的字）。
		# 窄屏只留最要紧的一条（坠落规则）——按钮本身已经写着字，不需要再列一遍。
		if vp.x < 620.0:
			base = "掉出棋盘或落入空洞会坠落"
		else:
			base = "掉出棋盘或落入空洞会坠落　·　右下：重开 / 选关 / 回放"
	elif _is_tv_like():
		# 电视遥控器上没有 R / L / V，写了等于没写 —— 只提示真正可用的键
		base = "遥控器方向键移动　·　确认重开或继续　·　返回选关　·　掉出棋盘或落入空洞会坠落"
	else:
		base = "方向键 / WASD 移动     R 重开     L 选关     V 看最佳回放     G 影子     ·     掉出棋盘或落入空洞会坠落"
	help_label.text = base
	# 同一条带只显示优先级最高的一条
	help_label.visible = not (win_label.visible or fail_label.visible or replay_label.visible)


func _scan_levels() -> Array:
	# 自动扫描 levels/ 下所有 .json，排序后作为关卡列表；同时读取关卡元数据
	var out: Array = []
	var dir := DirAccess.open("res://levels")
	if dir != null:
		dir.list_dir_begin()
		var f: String = dir.get_next()
		while f != "":
			if f.ends_with(".json"):
				out.append("res://levels/" + f)
			f = dir.get_next()
		dir.list_dir_end()
	out.sort()
	entries.clear()
	for i in range(out.size()):
		entries.append(_entry_for(i, out[i]))
	return out


func _entry_for(index: int, path: String) -> Dictionary:
	# 关卡 key 约定 = 文件名去扩展名（与存档键一致，且无需完整加载关卡）
	var e: Dictionary = {
		"index": index, "path": path, "key": path.get_file().get_basename(),
		"shape": "domino", "optimal": -1, "difficulty": "",
	}
	var d: Dictionary = _read_json(path)
	if not d.is_empty():
		e["shape"] = str(d.get("start", {}).get("shape", "domino"))
		e["optimal"] = int(d.get("optimal_moves", -1))
		e["difficulty"] = str(d.get("difficulty", ""))
	return e


func _read_json(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var txt := f.get_as_text()
	f.close()
	var j := JSON.new()
	if j.parse(txt) != OK or not (j.data is Dictionary):
		return {}
	return j.data


func _level_key(index: int) -> String:
	if index < 0 or index >= entries.size():
		return ""
	return str(entries[index]["key"])


func _level_keys() -> Array:
	var out: Array = []
	for e in entries:
		out.append(str(e["key"]))
	return out


func _load_level(index: int, animated: bool = true) -> void:
	if levels.is_empty():
		return
	if animated:
		_transition_to(index)
	else:
		_do_load(index)


func _do_load(index: int) -> void:
	# 计时归零的唯一位置：重开、换关、回放复位全都走 _do_load（单一真相）
	_reset_clock()
	current_index = clampi(index, 0, levels.size() - 1)
	var ok: bool = game.load_level(levels[current_index])
	if ok:
		_run_moves.clear()
		win_label.visible = false
		fail_label.visible = false
		replay_label.visible = false
		_frame_camera()
		_update_hud()
		_refresh_bands()
		# 触屏玩家看不到键盘提示，进关卡时给一次对角线滑动提示（每局只给一次）
		if touch_controls != null and touch_controls.is_shown():
			touch_controls.show_swipe_hint()
		# 「影子」：开了就自动把自己的最佳走法滚一遍（换关、重开都会重播一次）
		_play_ghost_for_current()


## 换关：棋盘下沉 + 暗幕淡入（“关卡合拢”）→ 暗幕下换关 → 新棋盘降入 + 淡出
func _transition_to(index: int) -> void:
	if transitioning or levels.is_empty():
		return
	if level_select != null and level_select.is_open():
		return
	index = clampi(index, 0, levels.size() - 1)
	transitioning = true
	win_label.visible = false
	fail_label.visible = false
	transition_label.modulate.a = 0.0
	transition_label.text = ""
	# 1) 棋盘下沉 + 暗幕淡入
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(fade, "color:a", 1.0, FADE_TIME).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	_slide_scene(tw, -SLIDE_IN)
	await tw.finished
	# 2) 暗幕遮挡下完成换关
	_do_load(index)
	_set_scene_offset(SLIDE_IN)
	transition_label.text = "关卡 %d / %d" % [index + 1, levels.size()]
	transition_label.modulate.a = 1.0
	await get_tree().create_timer(0.3).timeout
	# 3) 新棋盘降入 + 暗幕淡出
	var tw2 := create_tween()
	tw2.set_parallel(true)
	tw2.tween_property(fade, "color:a", 0.0, FADE_TIME + 0.12).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw2.tween_property(transition_label, "modulate:a", 0.0, FADE_TIME + 0.12)
	_slide_scene(tw2, 0.0)
	await tw2.finished
	transition_label.text = ""
	transitioning = false


func _set_scene_offset(y: float) -> void:
	if game == null:
		return
	if game.board_root != null:
		game.board_root.position.y = y
	if game.block != null:
		game.block.position.y = y


func _slide_scene(tw: Tween, target_y: float) -> void:
	# 把「棋盘 + 方块」的升降排到指定 tween 上
	for node in [game.board_root, game.block]:
		if node != null:
			tw.tween_property(node, "position:y", target_y, FADE_TIME) \
				.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN_OUT)


func _setup_transition() -> void:
	var layer := CanvasLayer.new()
	layer.name = "Transition"
	layer.layer = 10  # 盖在 HUD 之上
	add_child(layer)
	fade = ColorRect.new()
	fade.color = Color(0.04, 0.05, 0.09, 0.0)
	fade.set_anchors_preset(Control.PRESET_FULL_RECT)
	fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(fade)
	transition_label = Label.new()
	transition_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	transition_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	transition_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	transition_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	transition_label.modulate = Color(1, 1, 1, 0)
	transition_label.add_theme_font_size_override("font_size", 40)
	transition_label.add_theme_color_override("font_color", Color(0.92, 0.95, 1.0))
	layer.add_child(transition_label)


# ── 选关 / 进度 ─────────────────────────────────────────

func _setup_level_select() -> void:
	level_select = LevelSelect.new()
	level_select.name = "LevelSelect"
	add_child(level_select)
	level_select.level_chosen.connect(_on_level_chosen)
	level_select.closed.connect(_on_level_select_closed)
	level_select.reset_requested.connect(_on_progress_reset)
	level_select.celebration_requested.connect(_on_celebration_requested)
	level_select.ghost_toggled.connect(_on_ghost_toggled)


func _setup_ending() -> void:
	ending = Ending.new()
	ending.name = "Ending"
	add_child(ending)
	ending.restart_requested.connect(_on_ending_restart)
	ending.select_requested.connect(_on_ending_select)
	ending.closed.connect(_on_ending_closed)


func _on_ending_restart() -> void:
	# 「再玩一遍」= 开始新一轮：**清本轮通关进度**，但
	#   · 不动 best / replays / runs（玩家的记录是资产）
	#   · 不动 _ever（已解锁关卡不重锁，否则等于惩罚玩家重玩）
	# 不清本轮进度的话，第二轮打完不会再触发庆祝 —— 玩家一辈子只能被恭喜一次。
	ending.close()
	progress.reset_campaign()
	_do_load(0)
	_update_hud()
	_refresh_bands()


func _on_ending_select() -> void:
	ending.close()
	_open_level_select()


func _on_ending_closed() -> void:
	_hide_hud(false)


func _all_completed() -> bool:
	if levels.is_empty() or progress == null:
		return false
	for k in _level_keys():
		if not progress.is_completed(str(k)):
			return false
	return true


func _show_ending() -> void:
	# 防御性判断：庆祝层只在**真的全部通关**时出现，
	# 免得将来某个调用点漏判就把庆祝动画提前放出来（那样通关成就就贬值了）
	if ending == null or not _all_completed():
		return
	_hide_hud(true)          # 内部会一并隐藏触屏控件
	ending.open_with(entries, progress)


func _open_level_select() -> void:
	# 通关/坠落动画期间不要弹选关（否则会和自动换关过渡打架）
	if transitioning or _replaying or game.is_won() or game.is_lost():
		return
	if levels.is_empty():
		return
	_hide_hud(true)
	level_select.touch_mode = _touch_active
	level_select.set_safe_insets(_safe_insets)
	level_select.open_with(entries, progress, current_index)
	# 停表必须放在**界面真正打开之后**：判据是 level_select.is_open()，
	# 放在 open_with 之前的话判据还是假，等于没停（这里踩过一次）
	_refresh_clock()


func _on_touch_restart() -> void:
	# 回放中按钮语义变为「停止回放」——回放可能是被误触的，必须能中止
	if _replaying:
		_replaying = false
		touch_controls.set_replay_playing(false)
		return
	_restart()


func _on_touch_replay() -> void:
	# 触屏没有 Esc：同一个按钮兼作「播放 / 停止」
	if _replaying:
		_replaying = false
		touch_controls.set_replay_playing(false)
		return
	_play_replay()


func _hide_hud(hidden: bool) -> void:
	if hud_layer != null:
		hud_layer.visible = not hidden
	_apply_touch_visibility()


func _on_level_select_closed() -> void:
	_hide_hud(false)


func _on_level_chosen(index: int) -> void:
	level_select.close()   # 会触发 closed → 恢复 HUD
	_load_level(index, true)


func _on_celebration_requested() -> void:
	# 「回顾通关」：庆祝动画本身不该一次性的，但也不该强行弹给玩家 ——
	# 想看就点，不想看就继续玩。
	level_select.close()
	_show_ending()


func _on_progress_reset() -> void:
	progress.reset()
	level_select.open_with(entries, progress, current_index)


# ── 回放（最佳记录重演）──────────────────────────────────

func _play_replay() -> void:
	if _replaying or transitioning or levels.is_empty():
		return
	var rep: Dictionary = progress.replay(_level_key(current_index))
	if rep.is_empty() or (rep["moves"] as Array).is_empty():
		return
	_replaying = true
	if touch_controls != null:
		touch_controls.set_replay_playing(true)
	# 回放开始也走「复位到起点」的入场动画，而不是瞬间把方块挪回去
	_reset_to_start()
	var moves: Array = rep["moves"]
	await _wait_for_anim()

	for i in range(moves.size()):
		if not _replaying:
			break
		replay_label.text = "回放　%d / %d" % [i + 1, moves.size()]
		replay_label.visible = true
		_refresh_bands()
		# 与手动操作完全同源的动画（含等它演完）
		var ok: bool = await _do_move_animated(Moves.direction_from_label(str(moves[i])))
		if not ok:
			break
		if game.is_won() or game.is_lost():
			break
		# 步与步之间的停顿：回放的动画必须和手动操作一样，但**节奏**必须像人。
		# 早期只停 0.05s（每秒滚近 5 步），而翻滚缓动是 t*t（动作集中在最后 ~80ms），
		# 连续播放在眼里就是「没有动画、一下一下地跳」。
		await get_tree().create_timer(REPLAY_BEAT).timeout

	replay_label.text = "回放结束"
	await get_tree().create_timer(0.7).timeout
	_replaying = false
	if touch_controls != null:
		touch_controls.set_replay_playing(false)
	_reset_to_start()   # 复位，方便玩家接着挑战


func _reset_to_start() -> void:
	# 复位到本关起点的**唯一**实现：换关 + 入场下落动画（绝不瞬移）。
	# R 重开、回放开始、回放结束都走它，「方块怎么重新出现」在所有场景下必须一致。
	# （早期这里只在触屏下播入场动画，桌面直接瞬移 —— 同一个动作两套表现，正是要避免的）
	# _do_load 与 play_spawn 在同一帧内完成，所以不会先闪一下再落下。
	if game == null or levels.is_empty():
		return
	_do_load(current_index)
	game.play_spawn()
	_refresh_bands()


func _restart() -> void:
	# 重开也走动画：坠落之后如果“啪”一下复位，玩家会以为自己误触了什么。
	_reset_to_start()


func _next_level() -> void:
	_load_level((current_index + 1) % levels.size(), true)


func _prev_level() -> void:
	_load_level((current_index - 1 + levels.size()) % levels.size(), true)


func _on_moved() -> void:
	_update_hud()


func _on_won() -> void:
	_update_hud()
	# 回放中到达终点：只提示，不记录进度、不自动换关
	if _replaying:
		replay_label.text = "回放到达终点　·　%d 步" % game.move_count
		replay_label.visible = true
		_refresh_bands()
		await _win_beat()
		return
	# 关键：庆祝动画的判据是「**这一局刚好补完了最后一关**」这个状态跃迁，
	# 而不是「当前已全部通关」。后者是个持久状态 —— 全部通关之后再随便打通一关
	# （比如回头刷第 1 关）都会被再恭喜一次（真实 bug）。
	# 所以必须在 record_win **之前**快照。
	# 先在**通关这一刻**停表再取值：靠 _process 的兜底刷新会晚一帧（最多 16ms），
	# 而记录是毫秒级的，不该被渲染节奏影响。
	_refresh_clock()
	var was_all_done: bool = _all_completed()
	var res: Dictionary = progress.record_win(_level_key(current_index), _run_moves, clock.elapsed_ms())
	_update_hud()
	win_label.text = _win_text(res)
	win_label.visible = true
	_refresh_bands()
	# 通关反馈：灯光脉冲一下（方块保持原位、不变色），随后自然滚动换关
	await _win_beat()
	if transitioning or levels.is_empty():
		return
	# 刚刚补完最后一关：给一个明确的“旅程结束”，而不是默默滚回第 1 关（那看起来像 bug）。
	# 已经全部通关过的玩家再通关，就按普通换关处理（想再看一次可以去选关界面点「回顾通关」）。
	if not was_all_done and _all_completed():
		_show_ending()
		return
	_transition_to((current_index + 1) % levels.size())


func _win_text(res: Dictionary) -> String:
	# 步数纪录与时间纪录可以各自独立地被打破（见 progress.gd 顶部的说明）
	var base := "通关! 步数: %d" % int(res["move_count"])
	var t: int = int(res.get("time_ms", -1))
	if t >= 0:
		base += "　·　用时 %s" % Leaderboard.format_time(t)
	if bool(res["first_clear"]):
		return base + "　·　首次通关"
	if bool(res["improved"]):
		return base + "　·　步数新纪录!（原 %d）" % int(res["prev_best"])
	if bool(res.get("time_improved", false)):
		return base + "　·　时间新纪录!（原 %s）" % Leaderboard.format_time(int(res.get("prev_best_time", -1)))
	return base


func _win_beat() -> void:
	var tw := create_tween()
	tw.tween_property(light, "light_energy", LIGHT_ENERGY * 2.8, 0.22) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_property(light, "light_energy", LIGHT_ENERGY, 0.4) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	await tw.finished
	await get_tree().create_timer(0.08).timeout


func _on_fell() -> void:
	_refresh_clock()   # 坠落即停表（等下一帧兜底会多算一帧）
	_update_hud()
	if _replaying:
		fail_label.text = "回放异常结束　（Esc 退出）"
		fail_label.visible = true
		_refresh_bands()
		return
	# 触屏上没有 R 键，提示必须指向屏幕上那个按钮（只说“重开”等于没说）
	if touch_controls != null and touch_controls.is_shown():
		fail_label.text = "坠落！方块掉出了棋盘　·　点右下「重开」"
	elif _is_tv_like():
		# 遥控器上没有 R 键，照抄桌面文案等于告诉玩家一个不存在的键
		fail_label.text = "坠落！方块掉出了棋盘　（按确认键重开）"
	else:
		fail_label.text = "坠落！方块掉出了棋盘　（按 R 重开）"
	fail_label.visible = true
	_refresh_bands()


func _update_hud() -> void:
	if levels.is_empty():
		return
	var done: int = progress.completed_count() if progress != null else 0
	if _hud_narrow:
		level_label.text = "第 %d 关　%d/%d" % [current_index + 1, done, levels.size()]
	else:
		# 重玩一轮时改成「本轮」：否则刚「再玩一遍」会看到已通关从 20 掉到 0，
		# 像是进度被删了（其实只是本轮重新计，记录与解锁都还在）
		var tag: String = "本轮" if progress.replay_round() else "已通关"
		level_label.text = "第 %d 关　·　%s %d / %d" % [current_index + 1, tag, done, levels.size()]
	progress_bar.max_value = float(levels.size())
	# 进度条表示**整体通关进度**，而不是“当前第几关”：
	# 跳到第 18 关时看到 18/20 会让人误以为快通关了，实际上只通了 3 关。
	progress_bar.value = float(done)
	moves_label.text = "步数  %d" % game.move_count
	_update_clock_label(true)

	# 最佳 / 参考步数：给「刷分」提供明确目标
	var key: String = _level_key(current_index)
	var best: int = progress.best_moves(key)
	var optimal: int = -1
	if current_index >= 0 and current_index < entries.size():
		optimal = int(entries[current_index].get("optimal", -1))
	# 面板宽度只有 196px：三条记录挤在一行会被直接裁掉（实测「已最…」少半截），
	# 所以拆成两行短文本 —— 竖向空间是富余的，横向才是瓶颈。
	var lines: Array = []
	var step_parts: Array = []
	if best > 0:
		step_parts.append("最佳 %d" % best)
		if optimal > 0 and best == optimal:
			step_parts.append("已最优")
	elif optimal > 0:
		step_parts.append("参考 %d" % optimal)
	if step_parts.size() > 0:
		lines.append("　·　".join(step_parts))
	var bt: int = progress.best_time(key)
	if bt >= 0:
		lines.append("最快 %s" % Leaderboard.format_clock(bt))
	best_label.text = "\n".join(lines) if lines.size() > 0 else "　"


func _wait_for_anim() -> void:
	# 等待当前动画收尾的**唯一**原语。手动单步与回放共用：
	# 任何一方自己写「不等动画就下一步」都会表现为瞬移/无动画。
	while game != null and game.animating:
		await get_tree().process_frame


func _do_move_animated(d: Vector3i) -> bool:
	# 回放用的「走一步并等它演完」——内部就是 _do_move + _wait_for_anim，
	# 所以动画与手动操作**逐帧同源**，不存在“回放版动画”。
	await _wait_for_anim()
	if not _do_move(d):
		return false
	await _wait_for_anim()
	return true


func _do_move(d: Vector3i) -> bool:
	# 统一入口：记录本局移动（用于 Replay）后再交给 Game。
	# 返回是否真的走成了（手势提示要靠它判断“玩家学会了”）。
	if game.try_move(d):
		_run_moves.append(Moves.direction_label(d))
		return true
	return false


func _unhandled_input(event: InputEvent) -> void:
	if game == null or transitioning:
		return
	# 选关界面打开时，输入交给它自己处理
	if level_select != null and level_select.is_open():
		return
	if event is InputEventKey and event.pressed and not event.echo:
		# 回放中只允许退出
		if _replaying:
			if event.keycode == KEY_ESCAPE:
				_replaying = false
			return
		match event.keycode:
			KEY_R:
				_restart()
				return
			KEY_L, KEY_ESCAPE:
				_open_level_select()
				return
			KEY_V:
				_play_replay()
				return
			KEY_G:
				# 「影子」开关（等价于选关界面里的按钮）
				_toggle_ghost()
				return
			KEY_T:
				# 桌面调试：手动开关触屏操作层
				if touch_controls != null:
					_touch_active = not touch_controls.is_shown()
					_apply_touch_visibility()
					_refresh_bands()
				return
			KEY_N:
				_next_level()
				return
			KEY_P:
				_prev_level()
				return
		# 确认键：Enter / 小键盘 Enter / 空格。电视遥控器的 OK 键也被 Godot 映射成
		# KEY_ENTER，所以这一条同时覆盖「遥控器确认」与「键盘回车」。
		if event.keycode in [KEY_ENTER, KEY_KP_ENTER, KEY_SPACE]:
			_on_primary_action()
			return
		# 数字键 1-9：跳到已解锁的关卡
		var num_keys: Array = [KEY_1, KEY_2, KEY_3, KEY_4, KEY_5, KEY_6, KEY_7, KEY_8, KEY_9]
		var idx: int = num_keys.find(event.keycode)
		if idx >= 0:
			if progress.is_unlocked(idx, _level_keys()):
				_do_load(idx)
			return
	elif event is InputEventJoypadButton and event.pressed:
		# 手柄 / 部分电视遥控器的确认键（A 或 Start）
		if event.button_index in [JOY_BUTTON_A, JOY_BUTTON_START]:
			_on_primary_action()
			return
	var d: Vector3i = game.event_to_dir(event)
	if d != Vector3i.ZERO:
		_do_move(d)


func _frame_camera() -> void:
	# 参考经典 Bloxorz 的斜 45° 等距视角：棋盘呈菱形，方块与终点在屏幕上天然错开，
	# 因此竖起的方块不会直接遮住后方目标格（无需额外标记）。
	if cam == null or game == null or game.board == null:
		return
	var cx: float = float(game.board.grid_x) / 2.0
	var cz: float = float(game.board.grid_z) / 2.0
	var s: float = float(max(game.board.grid_x, game.board.grid_z))
	var az: float = deg_to_rad(45.0)
	# 距离按视口宽高比自适应：手机竖屏时横向可视范围更窄，
	# 必须把相机往后拉，否则棋盘左右两侧会被切掉（见 ui_layout.camera_distance）
	var vp: Vector2 = get_viewport().get_visible_rect().size
	var aspect: float = vp.x / maxf(vp.y, 1.0)
	var dist: float = UiLayout.camera_distance(s, aspect, cam.fov)
	var dir := Vector3(sin(az), 1.0, cos(az)).normalized()
	cam.position = Vector3(cx, 0.0, cz) + dir * dist
	cam.look_at(Vector3(cx, 0.0, cz))
	_update_touch_screen_dirs()


func _update_touch_screen_dirs() -> void:
	# 触屏滑动要「往哪滑、方块就往哪滚」，就必须知道每个网格方向在屏幕上的方向。
	# 这完全由相机决定（斜 45° 等距下它们成对角分布），所以现算而不是写死，
	# 以后换相机/换取景也不用改映射。
	if touch_controls == null or cam == null or game == null or game.board == null:
		return
	var center := Vector3(float(game.board.grid_x) * 0.5, 0.0, float(game.board.grid_z) * 0.5)
	var origin: Vector2 = cam.unproject_position(center)
	var dirs: Dictionary = {}
	for d in Moves.DIRS:
		var v: Vector2 = cam.unproject_position(center + Vector3(d)) - origin
		if v.length() > 0.0001:
			dirs[d] = v.normalized()
	if dirs.size() == Moves.DIRS.size():
		touch_controls.set_screen_dirs(dirs)


func _setup_camera() -> void:
	cam = Camera3D.new()
	cam.name = "Camera3D"
	cam.fov = 55.0
	add_child(cam)


func _setup_light() -> void:
	light = DirectionalLight3D.new()
	light.name = "DirectionalLight3D"
	light.rotation_degrees = Vector3(-52.0, -38.0, 0.0)
	light.light_energy = LIGHT_ENERGY * 1.15
	light.light_color = Color(1.0, 0.96, 0.90)  # 略暖，画面不生硬
	light.shadow_enabled = RenderQuality.shadows(_quality_tier)  # 由自适应画质控制
	light.directional_shadow_max_distance = 40.0
	add_child(light)


func _setup_environment() -> void:
	# 渐变天空（比纯色背景更自然、更耐看）+ 柔和环境光
	var env := WorldEnvironment.new()
	env.name = "WorldEnvironment"
	var e := Environment.new()
	# gl_compatibility 下真实天空不渲染，背景用“渐变幕布”实现（见 _setup_backdrop）
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.10, 0.13, 0.21)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.44, 0.49, 0.62)
	e.ambient_light_energy = 0.65   # 压低环境光 → 方块在瓦片上的阴影更明显
	env.environment = e
	add_child(env)


func _setup_backdrop() -> void:
	# 挂在相机前的渐变幕布（充当天空）：比纯色背景自然得多，且全渲染后端可用。
	# 说明：gl_compatibility 下 Environment.BG_SKY / ProceduralSkyMaterial 不渲染，
	# 所以用一个对着相机的 quad + 渐变着色器来充当天空。
	# 是否显示由自适应画质档位决定（见 _apply_render_quality）。
	var sh := Shader.new()
	sh.code = """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never;
uniform vec3 top_color : source_color = vec3(0.085, 0.11, 0.20);
uniform vec3 mid_color : source_color = vec3(0.19, 0.25, 0.40);
uniform vec3 bottom_color : source_color = vec3(0.06, 0.08, 0.13);
void fragment() {
	vec3 c = UV.y < 0.62
		? mix(top_color, mid_color, UV.y / 0.62)
		: mix(mid_color, bottom_color, (UV.y - 0.62) / 0.38);
	// 径向暗角：视线自然聚焦到画面中心（棋盘），边缘不抢戏
	float v = distance(UV, vec2(0.5)) * 1.35;
	c *= mix(1.0, 0.78, smoothstep(0.45, 1.05, v));
	ALBEDO = c;
}
"""
	var mat := ShaderMaterial.new()
	mat.shader = sh
	var quad := QuadMesh.new()
	quad.size = Vector2(600.0, 600.0)
	var mi := MeshInstance3D.new()
	mi.name = "Backdrop"
	mi.mesh = quad
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.visible = RenderQuality.backdrop(_quality_tier)
	cam.add_child(mi)
	mi.position = Vector3(0.0, 0.0, -300.0)
	backdrop = mi


func _setup_hud() -> void:
	var hud := CanvasLayer.new()
	hud.name = "HUD"
	add_child(hud)
	hud_layer = hud

	# ── 左上：关卡 + 进度条 ────────────────────────────
	var left := _make_panel(hud)
	left_panel = left
	left.anchor_left = 0.0
	left.anchor_top = 0.0
	left.offset_left = 22.0
	left.offset_top = 20.0
	left.offset_right = 22.0 + LEFT_PANEL_W
	left.offset_bottom = 20.0 + 78.0
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 9)
	level_label = Label.new()
	level_label.add_theme_font_size_override("font_size", 21)
	level_label.add_theme_color_override("font_color", Color(0.92, 0.95, 1.0))
	col.add_child(level_label)
	progress_bar = ProgressBar.new()
	progress_bar.custom_minimum_size = Vector2(0, 8)
	progress_bar.show_percentage = false
	progress_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var sb_bg := StyleBoxFlat.new()
	sb_bg.bg_color = Color(1, 1, 1, 0.14)
	sb_bg.set_corner_radius_all(4)
	var sb_fill := StyleBoxFlat.new()
	sb_fill.bg_color = Color(0.36, 0.86, 0.58)
	sb_fill.set_corner_radius_all(4)
	progress_bar.add_theme_stylebox_override("background", sb_bg)
	progress_bar.add_theme_stylebox_override("fill", sb_fill)
	col.add_child(progress_bar)
	left.add_child(col)

	# ── 右上：步数 ──────────────────────────────────
	var right := _make_panel(hud)
	right_panel = right
	right.anchor_left = 1.0
	right.anchor_right = 1.0
	right.offset_left = -22.0 - RIGHT_PANEL_W
	right.offset_right = -22.0
	right.offset_top = 20.0
	right.offset_bottom = 20.0 + 78.0
	var rcol := VBoxContainer.new()
	rcol.add_theme_constant_override("separation", 3)
	moves_label = Label.new()
	moves_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	moves_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	moves_label.add_theme_font_size_override("font_size", 21)
	moves_label.add_theme_color_override("font_color", Color(0.92, 0.95, 1.0))
	rcol.add_child(moves_label)
	time_label = Label.new()
	time_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	time_label.add_theme_font_size_override("font_size", 15)
	time_label.add_theme_color_override("font_color", Color(0.72, 0.82, 0.98))
	time_label.text = Leaderboard.format_clock(0)
	rcol.add_child(time_label)
	best_label = Label.new()
	best_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	best_label.add_theme_font_size_override("font_size", 13)
	best_label.add_theme_color_override("font_color", Color(0.62, 0.70, 0.86))
	best_label.text = "　"
	rcol.add_child(best_label)
	right.add_child(rcol)

	# ── 状态提示（通关 / 坠落 / 回放）──────────────────
	# 刻意**不放屏幕正中**：正中会压住棋盘，玩家看不到自己刚做了什么。
	# 它们与操作提示共用一条「提示带」，位置由 _refresh_bands() 统一决定，
	# 且同一时刻只显示优先级最高的那条（否则会互相压字）。
	win_label = _make_status(hud, 28, Color(0.42, 1.0, 0.62))
	fail_label = _make_status(hud, 24, Color(1.0, 0.52, 0.52))
	replay_label = _make_status(hud, 18, Color(0.62, 0.80, 1.0))

	# ── 操作提示（一段时间后自动变淡，减少长期干扰）──────────
	help_label = _make_status(hud, 15, Color(0.80, 0.85, 0.95))
	_fade_help_later()


func _make_panel(parent: Node) -> PanelContainer:
	# 圆角半透明面板：让 HUD 在 3D 背景上依然清晰、且有质感
	var pc := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.07, 0.09, 0.15, 0.55)
	sb.set_corner_radius_all(14)
	sb.content_margin_left = 18.0
	sb.content_margin_right = 18.0
	sb.content_margin_top = 12.0
	sb.content_margin_bottom = 12.0
	sb.border_color = Color(1.0, 1.0, 1.0, 0.07)
	sb.set_border_width_all(1)
	pc.add_theme_stylebox_override("panel", sb)
	parent.add_child(pc)
	return pc


func _fade_help_later() -> void:
	# 操作提示常驻会干扰长时间游玩：一段时间后自动变淡（仍可读）
	var t := get_tree().create_timer(9.0)
	t.timeout.connect(func() -> void:
		var tw := create_tween()
		tw.tween_property(help_label, "modulate:a", 0.3, 1.2))


func _make_status(hud: CanvasLayer, size: int, color: Color) -> Label:
	# 提示带里的一条文字。位置不在这里定，由 _refresh_bands() 统一安排，
	# 避开「各处硬写 y 偏移、改一个地方就要满处找」的维护问题。
	var l := Label.new()
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	# 轻微阴影：提示带落在 3D 背景/棋盘上也要清楚
	l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.7))
	l.add_theme_constant_override("shadow_offset_x", 0)
	l.add_theme_constant_override("shadow_offset_y", 1)
	l.visible = false
	hud.add_child(l)
	return l
