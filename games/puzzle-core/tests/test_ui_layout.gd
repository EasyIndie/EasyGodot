# test_ui_layout.gd — 布局/取景纯函数测试（headless）。
#
# 重点是**手机竖屏**这一新场景：取景以前只在 16:9 下调过，
# 竖屏时横向可视范围更窄，不把相机往后拉就会把棋盘左右切掉。
extends SceneTree

const L = preload("res://meta/ui_layout.gd")

const FOV := 55.0

var checks: int = 0
var failures: int = 0


func _init() -> void:
	_test_tv()
	_test_camera_desktop_unchanged()
	_test_camera_portrait()
	_test_camera_always_fits()
	_test_touch_unit()
	_test_level_grid()
	_test_safe_insets()

	print(JSON.stringify({
		"suite": "test_ui_layout",
		"checks": checks,
		"failures": failures,
		"status": "ok" if failures == 0 else "fail",
	}))
	quit(0 if failures == 0 else 1)


func check(cond: bool, msg: String) -> void:
	checks += 1
	if not cond:
		failures += 1
		push_error("FAIL: " + msg)


func _visible_half_width(s: float, aspect: float) -> float:
	# 相机距离对应「横向能看到的半宽」
	return L.camera_distance(s, aspect, FOV) * tan(deg_to_rad(FOV) * 0.5) * aspect


# ---- 测试组 ----

func _test_tv() -> void:
	# 电视判定：移动平台 + 没有触摸屏。
	# 用「有没有触摸屏」而不是平台名，是因为 Godot 没有「是不是 TV」的 API，
	# 而这条规则在「平板外接手柄」这类情况下也不会误判（不显示触屏层是对的）。
	check(L.is_tv_like(true, false), "移动平台且无触摸屏应判定为电视")
	check(not L.is_tv_like(true, true), "手机/平板有触摸屏 → 不是电视")
	check(not L.is_tv_like(false, false), "桌面无触摸屏 → 不是电视（有键盘鼠标）")

	# 过扫描下限：电视会裁掉四周约 5%
	check(is_equal_approx(L.tv_min_margin(Vector2(1920, 1080)), 54.0),
		"1080p 短边 1080 × 5% = 54")
	check(is_equal_approx(L.tv_min_margin(Vector2(3840, 2160)), 108.0), "4K 短边 2160 × 5% = 108")
	var floored: Dictionary = L.apply_tv_floor({"left": 10.0, "top": 0.0, "right": 90.0, "bottom": 0.0},
		Vector2(1920, 1080))
	check(is_equal_approx(float(floored["left"]), 54.0), "小于下限的边距应被抬到 54")
	check(is_equal_approx(float(floored["right"]), 90.0), "已经更大的边距不该被改小")
	check(is_equal_approx(float(floored["bottom"]), 54.0), "为 0 的边距应被抬到下限")

	# 10 尺 UI 缩放：4K 电视不能沿用 1080p 的字号
	check(is_equal_approx(L.tv_ui_scale(2160.0), L.TV_SCALE_UHD), "4K → UHD 档")
	check(is_equal_approx(L.tv_ui_scale(1080.0), L.TV_SCALE_1080), "1080p → 1080 档")
	check(is_equal_approx(L.tv_ui_scale(720.0), 1.0), "小屏不放大（手机用默认档）")
	check(L.tv_ui_scale(2160.0) > L.tv_ui_scale(1080.0), "越大屏放大越多")


func _test_camera_desktop_unchanged() -> void:
	# 16:9 下必须与旧的固定取景（距离 = 格数 × 1.909）几乎一致，保证桌面观感不变
	var s := 6.0
	var legacy: float = s * 1.909
	var now: float = L.camera_distance(s, 16.0 / 9.0, FOV)
	var diff: float = absf(now - legacy) / legacy
	check(diff < 0.03, "16:9 取景应与旧行为一致（差 %.2f%%，now=%.2f legacy=%.2f）" % [diff * 100.0, now, legacy])


func _test_camera_portrait() -> void:
	var s := 6.0
	var wide: float = L.camera_distance(s, 16.0 / 9.0, FOV)
	var square: float = L.camera_distance(s, 1.0, FOV)
	var tall: float = L.camera_distance(s, 9.0 / 19.5, FOV)
	# 比例 >= 1 时由**竖向**决定距离，因此正方形与 16:9 相同；只有竖屏才需要额外拉远
	check(is_equal_approx(square, wide),
		"比例 >= 1 时应由竖向决定，正方形与 16:9 距离相同（square=%.2f wide=%.2f）" % [square, wide])
	check(tall > square, "竖屏应比正方形拉得更远（tall=%.2f square=%.2f）" % [tall, square])
	# 竖屏手机（390×844 ≈ 0.462）
	var phone: float = L.camera_distance(s, 390.0 / 844.0, FOV)
	check(phone > wide * 2.0, "手机竖屏距离应显著大于桌面（phone=%.2f wide=%.2f）" % [phone, wide])


func _test_camera_always_fits() -> void:
	# 任意比例下，棋盘都必须完整落在横向视野里
	var s := 10.0
	var extent: float = s * L.BOARD_FIT
	for aspect in [16.0 / 9.0, 4.0 / 3.0, 1.0, 0.75, 390.0 / 844.0, 9.0 / 19.5]:
		var half_w: float = _visible_half_width(s, aspect)
		check(half_w >= extent * 0.5,
			"比例 %.3f 下横向应装得下棋盘（可见半宽 %.2f >= 需要 %.2f）" % [aspect, half_w, extent * 0.5])


func _test_touch_unit() -> void:
	# 竖屏手机（缓冲区像素：390×844 CSS × 2）
	var portrait := Vector2(780, 1688)
	var up: float = L.touch_unit(portrait)
	check(up >= 48.0 and up <= 132.0, "基准尺寸应夹在区间内，got=%.1f" % up)
	check(up * 3.0 <= portrait.y * 0.40, "竖屏控件高度不应超过视口 40%%（pad=%.0f vp=%.0f）" % [up * 3.0, portrait.y])
	# 横屏手机：控件更不能吃掉半个高度
	var landscape := Vector2(1688, 780)
	var ul: float = L.touch_unit(landscape)
	check(ul * 3.0 <= landscape.y * 0.42, "横屏控件高度不应超过视口 42%%（pad=%.0f vp=%.0f）" % [ul * 3.0, landscape.y])
	check(ul <= up, "横屏基准不应大于竖屏（landscape=%.1f portrait=%.1f）" % [ul, up])
	# 大屏有上限，小屏有下限
	check(L.touch_unit(Vector2(3840, 2160)) <= 132.0, "大屏不应超过上限")
	check(L.touch_unit(Vector2(480, 320)) >= 48.0, "小屏不应低于下限")
	# 可点面积（手机下 1 缓冲像素 = 0.5 CSS px）应远大于 44 CSS px 的最低要求
	check(up * 0.5 > 44.0, "触屏可点面积应足够大，got=%.1f CSS px" % (up * 0.5))




func _test_level_grid() -> void:
	for vp_x in [1280.0, 1000.0, 800.0, 600.0, 390.0]:
		var g: Dictionary = L.level_grid(Vector2(vp_x, 800.0), 20)
		var cols: int = int(g["columns"])
		var card: Vector2 = g["card"]
		var gap: float = float(g["gap"])
		var total: float = card.x * float(cols) + gap * float(cols - 1)
		check(cols >= 3 and cols <= 5, "列数应在 3..5，vp=%.0f got=%d" % [vp_x, cols])
		check(total <= vp_x, "网格总宽不得超出视口（vp=%.0f total=%.1f）" % [vp_x, total])
		check(card.x >= 76.0 and card.x <= 118.0, "卡片宽度应夹在区间内，got=%.1f" % card.x)
		check(card.y < card.x, "卡片应宽大于高，got=%.1f x %.1f" % [card.x, card.y])

	# 窄屏应降列
	check(int(L.level_grid(Vector2(600, 800), 20)["columns"]) == 3, "窄屏应降为 3 列")
	check(int(L.level_grid(Vector2(1280, 720), 20)["columns"]) == 5, "宽屏应为 5 列")
	# 关卡数少于列数时不应留空列
	check(int(L.level_grid(Vector2(1280, 720), 2)["columns"]) == 2, "关卡数少于列数时列数应跟随关卡数")

func _test_safe_insets() -> void:
	# 安全区域（刘海 / 灵动岛 / 底部手势条）只做“清洗 + 夹取”，规则必须可测：
	# 真机上这地方出错的表现是「按钮被切掉」，而且很难复现，所以这里穷举边界。
	var vp := Vector2(390.0, 844.0)   # 常见手机竖屏

	# 1) 解析：正常 JSON
	var d: Dictionary = L.parse_insets('{"top":47,"bottom":34,"left":0,"right":0}')
	check(absf(float(d["top"]) - 47.0) < 0.01, "应解析出 top")
	check(absf(float(d["bottom"]) - 34.0) < 0.01, "应解析出 bottom")
	# 2) 解析：坏数据一律退化成“没有安全区”（宁可少避让，也不能让 UI 消失）
	for bad in ["", "not json", "[]", "null", "{}"]:
		var bd: Dictionary = L.parse_insets(bad)
		check(float(bd["top"]) == 0.0 and float(bd["bottom"]) == 0.0, "坏数据应退化为 0: " + bad)
	# 3) 负值应被夹到 0（某些平台会返回负数）
	var neg: Dictionary = L.parse_insets('{"top":-50,"left":-1}')
	check(float(neg["top"]) == 0.0, "负 inset 应夹到 0")

	# 4) 夹取：单边不超过 12%
	var huge: Dictionary = L.safe_insets(vp, {"top": 5000.0, "bottom": 5000.0, "left": 5000.0, "right": 5000.0})
	check(float(huge["top"]) <= vp.y * L.SAFE_MAX_RATIO + 0.01, "单边 inset 应被夹取")
	# 5) 夹取：左右/上下加起来不能超过一半（否则内容区被挤没）
	check(float(huge["left"]) + float(huge["right"]) <= vp.x * L.SAFE_PAIR_MAX_RATIO + 0.01, "左右合计应被夹取")
	check(float(huge["top"]) + float(huge["bottom"]) <= vp.y * L.SAFE_PAIR_MAX_RATIO + 0.01, "上下合计应被夹取")

	# 6) 正常值应原样通过（夹取只针对离谱数据）
	var ok: Dictionary = L.safe_insets(vp, {"top": 47.0, "bottom": 34.0, "left": 0.0, "right": 0.0})
	check(absf(float(ok["top"]) - 47.0) < 0.01, "正常 inset 不应被改动")
	check(absf(float(ok["bottom"]) - 34.0) < 0.01, "正常 inset 不应被改动")

	# 7) 内容区必须始终为正：任何输入下都要留得下东西
	for raw in [{}, {"top": 1e9}, {"left": 1e9, "right": 1e9}, {"bottom": -1}]:
		var ins: Dictionary = L.safe_insets(vp, raw)
		var w: float = vp.x - float(ins["left"]) - float(ins["right"])
		var h: float = vp.y - float(ins["top"]) - float(ins["bottom"])
		check(w > vp.x * 0.4 and h > vp.y * 0.4, "内容区不应被 inset 挤没: " + str(raw))

	# 8) insets_equal 用于“只在变化时重排”，容差 0.5px
	check(L.insets_equal(ok, ok.duplicate()), "相同 insets 应判等")
	check(L.insets_equal(ok, {"top": 47.2, "bottom": 34.0, "left": 0.0, "right": 0.0}), "亚像素差异应判等")
	check(not L.insets_equal(ok, {"top": 60.0, "bottom": 34.0, "left": 0.0, "right": 0.0}), "明显差异应判不等")
