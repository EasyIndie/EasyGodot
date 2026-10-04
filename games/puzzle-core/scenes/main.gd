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
const Share = preload("res://meta/share.gd")
const Campaign = preload("res://meta/campaign.gd")

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
var _challenge: Dictionary = {} # 好友挑战（{"level": n, "moves": m}）；空 = 普通启动
var challenge_label: Label
var last_share_text: String = ""   # 最近一次交给平台（剪贴板）的分享内容（测试接缝）
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
# 动画期间的输入缓冲（"最后一次"方向）：滚动动画约 0.3 秒，这期间玩家的输入
# 会被 try_move 直接丢掉 —— 真机反馈就是"不跟手"。这里记住最后一次方向，
# 动画一结束立刻执行；只保留最后一次（不是队列），避免动画后突然连滚好几格。
var _pending_move: Vector3i = Vector3i.ZERO
var _pending_at: int = 0
# 缓冲的过期时间只当"安全网"用：必须长于所有动画（入场下落动画就有 1 秒多，
# 太短会在动画结束时把玩家的输入当过期丢掉 —— 那正是"不跟手"的另一种表现）。
# 真正的失效由"状态变了就清空"负责（换关 / 打开界面）。
const PENDING_TTL_MS := 1500
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
var lesson_label: Label
var _lesson_left: float = 0.0
var _level_epoch: int = 0  # 作废旧关卡仍在等待的通关协程
var best_label: Label
var _hud_narrow: bool = false
var left_panel: PanelContainer
var right_panel: PanelContainer
var backdrop: MeshInstance3D = null

# 存档路径覆盖（测试用；空 = 用默认 user://progress.json）
const PROGRESS_PATH_SETTING := "puzzle/progress_path"
# 面板宽度按"最少信息"定：左边只有「第 N 关」，右边是步数/计时/最佳（一行）。
# 通关进度、总成绩这些**元信息**不在游戏画面里 —— 它们在选关界面，
# 那里才是"看进度、挑关卡"的地方；游戏画面上多一行字就少一分棋盘的呼吸空间。
# 紧凑化：面板高度按"实际内容行数"给，不再统一 72 的宽松值。
# 左边只有「第 N 关」一行；右边两行（当前：步数 + 计时 ／ 记录：最佳 + 最快）。
# 少掉的每一像素都还给棋盘。
const LEFT_PANEL_W := 100.0
const RIGHT_PANEL_W := 148.0
const LEFT_PANEL_H := 40.0
const RIGHT_PANEL_H := 60.0
# 没有记录时右面板只有一行（步数 + 计时），高度随之收一半。
# 面板**按内容长高**是刻意的：信息在真正存在的时候才占位置。
const RIGHT_PANEL_H_ONE_LINE := 40.0
const HUD_MARGIN := 14.0

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
	_apply_tv_ui_scale()
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
	_setup_challenge()
	# 挑战模式直接载入指定关卡（收到链接的人不该被迫先通关前面 11 关）
	_load_level(int(_challenge.get("level", 1)) - 1 if challenge_active() else progress.resume_index(_level_keys()), false)
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
	if _lesson_left > 0.0 and _clock_should_run():
		_lesson_left = maxf(0.0, _lesson_left - delta)
		if _lesson_left == 0.0:
			_refresh_bands()
	_refresh_clock()
	_update_clock_label()
	_flush_pending_move()
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
	if transitioning or game == null:
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
	_apply_tv_ui_scale()
	_update_safe_area()
	_refresh_bands()
	_frame_camera()


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


func _on_pad_toggled(on: bool) -> void:
	# 方向键开关（选关界面里的那个）：偏好记在进度里，当帧生效
	if progress != null:
		progress.set_pad_enabled(on)
	if touch_controls != null:
		touch_controls.set_pad_enabled(on)
		_refresh_bands()


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


func challenge_source() -> String:
	# 挑战参数从哪来：Web 用地址栏查询串；原生包没有 URL，用环境变量
	# （GF_CHALLENGE="level=12&moves=9"）—— 与查询串**同一套语法**，共用同一个解析器，
	# 排障与截图测试也因此能在桌面上复现挑战模式。
	if _query_string != "":
		return _query_string
	return OS.get_environment("GF_CHALLENGE")


func challenge_active() -> bool:
	return not _challenge.is_empty()


func _setup_challenge() -> void:
	var raw: String = challenge_source()
	if raw == "":
		return
	var c: Dictionary = Share.parse_challenge(raw, levels.size())
	if c.is_empty():
		# 链接坏掉/被改坏时安静地按普通启动处理（绝不弹错、绝不进入半开状态）
		return
	_challenge = c


func _share_current(index: int) -> String:
	# 关号对外从 1 开始；base 用当前 Web 地址（原生包内没有地址 → share.gd 落回公网版）
	var base: String = ""
	if OS.has_feature("web"):
		base = str(JavaScriptBridge.eval("window.location.href.split('?')[0]", true))
	var key: String = _level_key(index)
	var moves: int = progress.best_moves(key)
	var time_ms: int = progress.best_time(key)
	var url: String = Share.challenge_url(base, index + 1, moves)
	return Share.share_text(index + 1, moves, time_ms, url)


func _on_share_requested(index: int) -> void:
	var text: String = _share_current(index)
	last_share_text = text
	DisplayServer.clipboard_set(text)
	if level_select != null:
		level_select.set_share_button_text("已复制链接")
		# 两秒后恢复按钮文案（否则「已复制」会一直挂着，看起来像坏了）
		var tw := create_tween()
		tw.tween_interval(2.0)
		tw.tween_callback(func() -> void:
			if level_select != null:
				level_select.set_share_button_text("分享本关"))


func _finish_challenge(res: Dictionary) -> void:
	# 挑战模式通关：**不自动换关**（挑战是独立体验，玩家可能只是想试试这一关），
	# 只报出对照结果 + 明确的下一步
	var target: int = int(_challenge.get("moves", -1))
	win_label.text = Share.result_line(int(res["move_count"]), int(res.get("time_ms", -1)), target) \
		+ "　·　R 重玩 / L 选关"


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
	# Web 的画布保留高清像素，UI 则按 CSS 像素布局，避免 Retina 下字号/热区减半。
	# TV 使用真实窗口尺寸分档，避免缩放后的 viewport 反复切换档位。
	var win := get_window()
	if win == null:
		return
	var want: float = UiLayout.tv_ui_scale(minf(win.size.x, win.size.y)) if _is_tv_like() else 1.0
	if OS.has_feature("web"):
		var ratio = JavaScriptBridge.eval("(function(){var c=document.getElementById('canvas');var r=c.getBoundingClientRect();return r.width>0?c.width/r.width:1;})()", true)
		if ratio is float or ratio is int:
			want = UiLayout.web_ui_scale(float(ratio))
	if not is_equal_approx(win.content_scale_factor, want):
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
	if not UiLayout.insets_equal(ins, _safe_insets):
		_safe_insets = ins
		if touch_controls != null:
			touch_controls.set_safe_insets(ins)
		if level_select != null:
			level_select.set_safe_insets(ins)
		if ending != null:
			ending.set_safe_insets(ins)
	# HUD 布局**每次都要重算**，不能挂在"安全区变了"的分支里：
	# 它的输入不只是安全区，还有视口尺寸。早先的写法在"没有安全区的设备"
	#（桌面、多数 Android）上会一路提前 return —— 面板永远停在创建时写死的偏移，
	# **改了布局却不生效**（真实踩过：紧凑化改了半天，实测面板尺寸一点没变）。
	_apply_hud_insets()


func _apply_hud_insets() -> void:
	# HUD 两块面板必须整体避开安全区（否则横屏 iPhone 上左上角的关卡面板会被灵动岛切掉），
	# 并且**必须能在窄屏上共存**：手机竖屏只有 ~390px 宽，
	# 按固定 236+196 的尺寸摆会直接互相压住（截图里「已通关 20 / 20」压到了步数上）。
	if left_panel == null or right_panel == null:
		return
	var vp: Vector2 = get_viewport().get_visible_rect().size
	var sl: float = float(_safe_insets.get("left", 0.0)) + HUD_MARGIN
	var sr: float = float(_safe_insets.get("right", 0.0)) + HUD_MARGIN
	var st: float = float(_safe_insets.get("top", 0.0)) + HUD_MARGIN
	# 可用宽度按比例分给两块面板：左边拿大头（关卡文字更长），右边保证最小可读宽度
	var avail: float = maxf(vp.x - sl - sr, 120.0)
	var gap: float = 12.0
	var lw: float = clampf(minf(LEFT_PANEL_W, (avail - gap) * 0.45), 96.0, LEFT_PANEL_W)
	var rw: float = clampf(minf(RIGHT_PANEL_W, avail - gap - lw), 96.0, RIGHT_PANEL_W)
	var narrow: bool = vp.x < 620.0
	# 窄屏同时缩小字号 + 缩短文案（宁可信息少一点，也不要溢出错行）
	level_label.add_theme_font_size_override("font_size", 15 if narrow else 16)
	moves_label.add_theme_font_size_override("font_size", 18 if narrow else 19)
	time_label.add_theme_font_size_override("font_size", 14 if narrow else 15)
	best_label.add_theme_font_size_override("font_size", 10 if narrow else 11)
	_hud_narrow = narrow
	left_panel.offset_left = sl
	left_panel.offset_right = sl + lw
	left_panel.offset_top = st
	left_panel.offset_bottom = st + LEFT_PANEL_H
	right_panel.offset_left = -sr - rw
	right_panel.offset_right = -sr
	right_panel.offset_top = st
	right_panel.offset_bottom = st + RIGHT_PANEL_H
	_update_hud()


func _setup_touch_controls() -> void:
	touch_controls = TouchControls.new()
	touch_controls.name = "TouchControls"
	add_child(touch_controls)
	touch_controls.direction.connect(_on_touch_direction)
	touch_controls.restart_pressed.connect(_on_touch_restart)
	touch_controls.select_pressed.connect(_open_level_select)
	touch_controls.replay_pressed.connect(_on_touch_replay)
	# 方向键是玩家偏好（默认关）：启动时就按他的选择摆好
	touch_controls.set_pad_enabled(progress != null and progress.pad_enabled())
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


func _can_move() -> bool:
	# 现在能不能走一步：换关过渡 / 回放 / 选关界面 / 庆祝界面都不行。
	# 集中成一个函数，是因为"能不能动"的判据被三处用到（键盘、触屏、缓冲冲刷），
	# 分散写迟早漏掉一处（缓冲的输入就会在界面关掉后突然执行）。
	if transitioning or _replaying:
		return false
	if level_select != null and level_select.is_open():
		return false
	if ending != null and ending.is_open():
		return false
	return true


func _clear_pending_move() -> void:
	# 局面要变了（换关、开界面）：缓冲区里的方向不再对应当前棋盘，必须丢掉，
	# 否则界面一关就会突然滚一下（缓冲最典型的 bug）
	_pending_move = Vector3i.ZERO


func _flush_pending_move() -> void:
	# 动画结束后执行缓冲的那个方向。超过 PENDING_TTL_MS 视为过期（切过后台等），
	# 直接丢弃 —— 宁可少走一步，也不要在玩家已经做别的事时突然滚一下。
	if _pending_move == Vector3i.ZERO:
		return
	if not _can_move() or game == null:
		if Time.get_ticks_msec() - _pending_at > PENDING_TTL_MS:
			_pending_move = Vector3i.ZERO
		return
	if game.animating:
		# 入场下落是纯观赏动画（1 秒多）：玩家的意图优先，直接补到终态立刻执行，
		# 否则每次进关卡的第一下都会慢半拍。滚动动画照旧等它演完。
		if not game.snap_spawn():
			if Time.get_ticks_msec() - _pending_at > PENDING_TTL_MS:
				_pending_move = Vector3i.ZERO
			return
	var d: Vector3i = _pending_move
	_pending_move = Vector3i.ZERO
	_do_move(d)


func _on_touch_direction(d: Vector3i) -> void:
	# 触屏滑动/方向键与键盘走同一条路径，但要避开选关、过渡、回放、庆祝界面
	if not _can_move():
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
	if lesson_label != null:
		lesson_label.offset_left = sl + 16.0
		lesson_label.offset_right = -(sr + 16.0)
		lesson_label.offset_top = st + 82.0
		lesson_label.offset_bottom = st + 138.0
		lesson_label.add_theme_font_size_override("font_size", 16)
		if touch_on and vp.x > vp.y:
			# 横屏棋盘靠近顶部；教学放在底部动作区上方的一行空隙。
			lesson_label.offset_top = vp.y - touch_controls.bottom_inset() - 22.0
			lesson_label.offset_bottom = lesson_label.offset_top + 22.0
			lesson_label.add_theme_font_size_override("font_size", 14)
		lesson_label.visible = _lesson_left > 0.0 and not lesson_label.text.is_empty() \
			and not (win_label.visible or fail_label.visible or replay_label.visible or challenge_active())
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
	if touch_on:
		# 触屏：静态帮助文案整条撤掉（见上）。状态提示仍由 _refresh_bands 定位。
		help_label.text = ""
		help_label.visible = false
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
		# 触屏**不再常驻任何操作文案**：
		#   · 按钮上已经写着「重开 / 选关 / 回放」，再列一遍是重复（真机反馈：屏幕太满）
		#   · 滑动手势由第一次进关卡的手势提示负责教，学会就收起
		# 这条带子从此只承担**状态变化**（坠落 / 通关 / 回放 / 挑战）——
		# 也就是玩家真的需要被告知的那一刻。
		base = ""
		help_label.text = base
		help_label.visible = false
		return
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
		e["title"] = Campaign.title(index)
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
	_level_epoch += 1
	current_index = clampi(index, 0, levels.size() - 1)
	var ok: bool = game.load_level(levels[current_index])
	if ok:
		if not challenge_active():
			progress.set_current_level(_level_key(current_index))
		lesson_label.text = lesson_text()
		_lesson_left = 8.0
		_run_moves.clear()
		_pending_move = Vector3i.ZERO
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


func lesson_text() -> String:
	# 短暂、按关卡出现的规则提示；已通关的关卡不重复教学。
	if progress.has_ever_cleared(_level_key(current_index)):
		return ""
	var kinds: Array = []
	for d in game.board.mechanisms:
		if not kinds.has(str(d["kind"])):
			kinds.append(str(d["kind"]))
	if kinds.has("portal"):
		if kinds.has("bridge"):
			return "先开桥，再利用传送门调整路线。传送后姿态不变。"
		return "传送门保持方块姿态，先想好出口怎么走。"
	if kinds.has("gate"):
		return "踩开关会改变道路；留意哪些格子消失了。"
	if kinds.has("bridge"):
		return "踩开关打开桥，再翻滚到另一边。"
	if current_index <= 1:
		return "竖立在发光目标格上即可通关；平躺不算。"
	return ""


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
	level_select.pad_toggled.connect(_on_pad_toggled)
	level_select.share_requested.connect(_on_share_requested)


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
	_clear_pending_move()
	# 防御性判断：庆祝层只在**真的全部通关**时出现，
	# 免得将来某个调用点漏判就把庆祝动画提前放出来（那样通关成就就贬值了）
	if ending == null or not _all_completed():
		return
	_hide_hud(true)          # 内部会一并隐藏触屏控件
	ending.open_with(entries, progress)


func _open_level_select() -> void:
	_clear_pending_move()
	# 失败后也能换关；通关后打开菜单则停止自动换关。
	if transitioning or _replaying:
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
	# 选关界面里可能刚「重置进度」过 —— 关掉时必须重算 HUD，
	# 否则左上角还挂着重置前的「已通关 x / M」（真实反馈：重置完仍显示已通关）
	_update_hud()


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
	var won_epoch: int = _level_epoch
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
	if challenge_active():
		# 挑战模式：立刻给出与对方的对照（不要等灯光脉冲演完才显示，那是普通模式的节奏），
		# 并且**不自动换关** —— 收到链接的人可能只想试这一关
		_finish_challenge(res)
	win_label.visible = true
	_refresh_bands()
	# 通关反馈：灯光脉冲一下（方块保持原位、不变色），随后自然滚动换关
	await _win_beat()
	if won_epoch != _level_epoch or transitioning or levels.is_empty() or not game.is_won():
		return
	if level_select != null and level_select.is_open():
		return
	if challenge_active():
		# 挑战模式：到此为止（文案已在上面当场给过）
		_refresh_bands()
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
	# 游戏画面上只留「第 N 关」。
	# 通关进度（已通关 x/20、进度条、本轮/历史口径）全部搬到选关界面：
	#   · 它不影响当前这一局怎么玩，却占了左上角一整块
	#   · 口径还很绕（本轮 vs 曾经通关），放在需要读的地方（选关）才讲得清
	level_label.text = "第 %d 关" % [current_index + 1]
	if challenge_label != null:
		challenge_label.visible = challenge_active()
		if challenge_active():
			challenge_label.text = Share.challenge_line(int(_challenge["level"]), int(_challenge.get("moves", -1)))
	# 「回放」按钮只在本关**确实有回放记录**时出现（没有记录就不留死按钮）
	if touch_controls != null:
		touch_controls.set_replay_available(progress.has_replay(_level_key(current_index)))
	moves_label.text = "步数 %d" % game.move_count
	_update_clock_label(true)

	# 第二行：本机记录（最佳步数 / 最快时间）。
	# **「参考」（本关最少几步）不在这里** —— 它是"关卡信息"，不是"这一局的记录"，
	# 放在选关界面的卡片与详情里（那里才是挑关卡、看目标的地方）。
	# 游戏画面上只保留"你正在打的这一局"和"你自己的记录"。
	var key: String = _level_key(current_index)
	var best: int = progress.best_moves(key)
	var optimal: int = -1
	if current_index >= 0 and current_index < entries.size():
		optimal = int(entries[current_index].get("optimal", -1))
	var lines: Array = []
	if best > 0:
		var step_txt: String = "最佳 %d" % best
		if optimal > 0 and best == optimal:
			step_txt += "（已最优）"      # 打到理论最少步时的即时褒奖
		lines.append(step_txt)
	var bt: int = progress.best_time(key)
	if bt >= 0:
		lines.append("最快 %s" % Leaderboard.format_clock(bt))
	# 没有记录时**整行不显示**（连占位都不要）：面板高度随之收成一行。
	# 有记录时它才长出来 —— 信息在真正存在的时候才出现。
	best_label.text = "　·　".join(lines)
	best_label.visible = lines.size() > 0
	if right_panel != null:
		# 面板高度**跟着内容走**：没有记录就只占一行。
		# 这里直接改 offset（不能回头调 _apply_hud_insets：它末尾会调用 _update_hud，
		# 会绕成无限递归）；只在值真的不同才写，避免每帧把布局标脏。
		var want_bottom: float = right_panel.offset_top + \
			(RIGHT_PANEL_H if best_label.visible else RIGHT_PANEL_H_ONE_LINE)
		if not is_equal_approx(right_panel.offset_bottom, want_bottom):
			right_panel.offset_bottom = want_bottom


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
	if game.animating:
		# 动画进行中不丢输入：记下最后一次方向，动画结束立刻补上（见 _flush_pending_move）
		_pending_move = d
		_pending_at = Time.get_ticks_msec()
		return false
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
			# **不归一化**：长度就是"走一格在屏幕上的像素数"，手势阈值按它缩放，
			# 所以 5 寸手机和 12 寸平板上"滑一格"的手感一致（大屏不会轻轻一碰就滚）。
			dirs[d] = v
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
	left.offset_left = HUD_MARGIN
	left.offset_top = HUD_MARGIN
	left.offset_right = HUD_MARGIN + LEFT_PANEL_W
	left.offset_bottom = HUD_MARGIN + LEFT_PANEL_H
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 9)
	level_label = Label.new()
	level_label.add_theme_font_size_override("font_size", 21)
	level_label.add_theme_color_override("font_color", Color(0.92, 0.95, 1.0))
	col.add_child(level_label)
	# 好友挑战的目标（只在挑战模式出现；它不是「持续状态」，是启动参数带来的上下文）
	challenge_label = Label.new()
	challenge_label.add_theme_font_size_override("font_size", 14)
	challenge_label.add_theme_color_override("font_color", Color(0.55, 1.0, 0.78))
	challenge_label.visible = false
	col.add_child(challenge_label)
	left.add_child(col)

	# ── 右上：步数 ──────────────────────────────────
	var right := _make_panel(hud)
	right_panel = right
	right.anchor_left = 1.0
	right.anchor_right = 1.0
	right.offset_left = -(HUD_MARGIN + RIGHT_PANEL_W)
	right.offset_right = -HUD_MARGIN
	right.offset_top = HUD_MARGIN
	right.offset_bottom = HUD_MARGIN + RIGHT_PANEL_H
	# 两行，按**语义**分行：
	#   第 1 行 = 这一局正在累积的数字（步数 + 计时）—— HBox 放同一行，省一行高度
	#   第 2 行 = 本机的记录（最佳步数 / 最快时间）—— 刷分目标，颜色压暗
	# 早先是三行各占一行，"当前"和"记录"混在一起，还要更多高度。
	var rcol := VBoxContainer.new()
	rcol.add_theme_constant_override("separation", 2)
	var rrow := HBoxContainer.new()
	rrow.add_theme_constant_override("separation", 8)
	rrow.alignment = BoxContainer.ALIGNMENT_CENTER
	moves_label = Label.new()
	moves_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	moves_label.add_theme_font_size_override("font_size", 20)
	moves_label.add_theme_color_override("font_color", Color(0.92, 0.95, 1.0))
	rrow.add_child(moves_label)
	time_label = Label.new()
	time_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	time_label.add_theme_font_size_override("font_size", 15)
	time_label.add_theme_color_override("font_color", Color(0.72, 0.82, 0.98))
	time_label.text = Leaderboard.format_clock(0)
	rrow.add_child(time_label)
	rcol.add_child(rrow)
	best_label = Label.new()
	best_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	best_label.add_theme_font_size_override("font_size", 11)
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
	lesson_label = _make_status(hud, 16, Color(0.72, 0.86, 1.0))
	lesson_label.anchor_right = 1.0
	lesson_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lesson_label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	lesson_label.visible = false
	_fade_help_later()


func _make_panel(parent: Node) -> PanelContainer:
	# 圆角半透明面板：让 HUD 在 3D 背景上依然清晰、且有质感
	var pc := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.07, 0.09, 0.15, 0.55)
	sb.set_corner_radius_all(14)
	# 内边距直接决定面板的最小高度（PanelContainer 不会被 offset 压到比内容还小），
	# 所以"紧凑"要在这里改：12 → 7，四周留白从"宽裕"变"刚好"。
	sb.content_margin_left = 14.0
	sb.content_margin_right = 14.0
	sb.content_margin_top = 6.0
	sb.content_margin_bottom = 6.0
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
