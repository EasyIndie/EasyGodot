# ui_layout.gd — 布局与取景的**纯函数**（不依赖场景树，可 headless 单测）。
#
# 抽出来的原因：这些数值同时被相机取景、触屏控件、选关界面使用，
# 且必须在完全不同的屏幕比例下成立（桌面 16:9、手机竖屏约 9:19.5、平板 4:3）。
# 与其在各处散落魔数，不如集中成可验证的纯函数。
extends RefCounted

# 等距投影下，棋盘在屏幕上的外接尺寸 ≈ 格数 × 该系数。
# 该值由「原来在 16:9 下调好的取景」反推得到（保证桌面观感不变）。
const BOARD_FIT := 1.88
# 取景余量
const FIT_MARGIN := 1.06


static func camera_distance(board_size: float, aspect: float, fov_deg: float) -> float:
	# 让棋盘在**横竖两个方向都装得下**：竖屏时横向可视范围更窄，相机必须往后拉，
	# 否则手机竖屏会把棋盘左右两侧切掉。
	var half: float = deg_to_rad(fov_deg) * 0.5
	var extent: float = board_size * BOARD_FIT
	var d_v: float = (extent * 0.5) / tan(half)
	var d_h: float = (extent * 0.5) / (tan(half) * maxf(aspect, 0.2))
	return maxf(d_v, d_h) * FIT_MARGIN


static func touch_unit(viewport: Vector2) -> float:
	# 触屏控件基准尺寸（缓冲区像素）：取短边比例。
	# 横屏时短边就是高度，用同样系数会吃掉半个屏幕，所以取更小的系数。
	var short_side: float = minf(viewport.x, viewport.y)
	var k: float = 0.13 if viewport.x > viewport.y else 0.16
	return clampf(short_side * k, 48.0, 132.0)


static func level_grid(viewport: Vector2, count: int) -> Dictionary:
	# 选关网格：列数随宽度降级，卡片尺寸按可用宽度反算，保证窄屏不溢出。
	var cols: int = 5
	if viewport.x < 700.0:
		cols = 3
	elif viewport.x < 900.0:
		cols = 4
	cols = mini(cols, maxi(count, 1))
	var gap: float = 8.0
	var avail: float = viewport.x * 0.90 - gap * float(cols - 1)
	var card_w: float = clampf(avail / float(cols), 76.0, 118.0)
	return {"columns": cols, "card": Vector2(card_w, card_w * 0.77), "gap": gap}


# 斜 45° 等距相机下，四个网格方向在**屏幕上**的单位方向（x 向右、y 向下）。
# 列一下就很清楚：-z 是右上、+x 是右下、+z 是左下、-x 是左上。
# 触屏是**指向性输入**，必须按这个来映射，否则「向上滑」会让方块往右上滚。
# （真正的值会由 main.gd 用相机 unproject 现算后覆盖，这里只是默认值/测试基准）
const DEFAULT_SCREEN_DIRS := {
	Vector3i(1, 0, 0): Vector2(0.8165, 0.5774),
	Vector3i(-1, 0, 0): Vector2(-0.8165, -0.5774),
	Vector3i(0, 0, 1): Vector2(-0.8165, 0.5774),
	Vector3i(0, 0, -1): Vector2(0.8165, -0.5774),
}


# 方向解算（滑动 → 网格方向）已统一到 meta/gesture.gd：
# 那里是"解到棋盘坐标系 + 歧义粘滞"，比这里"取屏幕上最近的方向"更能容错。
# 两处各留一份实现迟早会走偏，所以这里不再保留副本。
# DEFAULT_SCREEN_DIRS 仅作手势层在相机就绪前的兜底。


# ── 安全区域（刘海 / 灵动岛 / 底部手势条）────────────────────────────────
# 约定：inset = **每边被系统 UI 遮挡的像素数**。
#   Web 端从 CSS env(safe-area-inset-*) 读（见 workflow/web/head_include.html），
#   原生平台从 DisplayServer.get_display_safe_area() 换算。
# 这里只做纯逻辑：解析 + 夹取。夹取很重要——脏数据（比如某平台返回了半个屏幕）
# 会把整个 UI 挤到角落里，而这在真机上极难复现。
const SAFE_MAX_RATIO := 0.12        # 单边最多吃掉对应边长的 12%
const SAFE_PAIR_MAX_RATIO := 0.5    # 左右（或上下）加起来不能超过一半


static func parse_insets(text: String) -> Dictionary:
	# 把平台给的 JSON 文本转成 insets；任何异常都退化成「没有安全区」，
	# 宁可少避让，也不能因为解析失败让 UI 消失。
	var out := {"left": 0.0, "top": 0.0, "right": 0.0, "bottom": 0.0}
	var j := JSON.new()
	if j.parse(text) != OK or not (j.data is Dictionary):
		return out
	var d: Dictionary = j.data
	for k in out.keys():
		out[k] = maxf(float(d.get(k, 0.0)), 0.0)
	return out


static func safe_insets(viewport: Vector2, raw: Dictionary) -> Dictionary:
	var out := {"left": 0.0, "top": 0.0, "right": 0.0, "bottom": 0.0}
	for k in out.keys():
		var v: float = maxf(float(raw.get(k, 0.0)), 0.0)
		var dim: float = viewport.x if (k == "left" or k == "right") else viewport.y
		out[k] = clampf(v, 0.0, maxf(dim, 1.0) * SAFE_MAX_RATIO)
	# 成对夹取：无论 insets 多离谱，都必须给内容留出至少一半空间
	for axis in ["h", "v"]:
		var a: String = "left" if axis == "h" else "top"
		var b: String = "right" if axis == "h" else "bottom"
		var limit: float = maxf(viewport.x if axis == "h" else viewport.y, 1.0) * SAFE_PAIR_MAX_RATIO
		var total: float = out[a] + out[b]
		if total > limit and total > 0.0:
			var s: float = limit / total
			out[a] = float(out[a]) * s
			out[b] = float(out[b]) * s
	return out


static func insets_equal(a: Dictionary, b: Dictionary) -> bool:
	# 用于「只在真正变化时才重排 UI」，避免每帧重算布局
	for k in ["left", "top", "right", "bottom"]:
		if absf(float(a.get(k, 0.0)) - float(b.get(k, 0.0))) > 0.5:
			return false
	return true


# ── 电视（Android TV / Google TV / 电视盒子）────────────────────────
#
# 判定「像电视」的依据不是平台名，而是**这台设备没有触摸屏但确实是移动平台**：
#   手机/平板 = mobile + 有触摸屏
#   电视/盒子 = mobile + 没有触摸屏（遥控器/手柄输入）
# 这样不需要任何「是不是 TV」的专用 API（Godot 也没提供），
# 而且在「安卓平板外接手柄」这类边缘情况下的表现也是合理的（不显示触屏层）。
const TV_MIN_RATIO := 0.05           # 电视过扫描：内容至少留出短边的 5%
const TV_SCALE_1080 := 1.15          # 1080p 电视：UI 略微放大
const TV_SCALE_UHD := 1.45           # 4K 电视：像素密度更高，按键/字号必须更大才不会“看着累”


static func is_tv_like(is_mobile: bool, has_touchscreen: bool) -> bool:
	return is_mobile and not has_touchscreen


static func tv_min_margin(viewport: Vector2) -> float:
	# 电视会裁掉四周约 5%（过扫描）。系统安全区在电视上通常报 0，
	# 所以要我们自己兜一个下限，否则贴边的 HUD 会被电视物理裁掉。
	return maxf(minf(viewport.x, viewport.y) * TV_MIN_RATIO, 0.0)


static func apply_tv_floor(insets: Dictionary, viewport: Vector2) -> Dictionary:
	# 把电视最小边距并进现有的安全区结果（取两者较大值，不叠加）
	var m: float = tv_min_margin(viewport)
	var out: Dictionary = insets.duplicate()
	for k in ["left", "top", "right", "bottom"]:
		out[k] = maxf(float(out.get(k, 0.0)), m)
	return out


static func tv_ui_scale(short_side: float) -> float:
	# 10 尺 UI：电视的观看距离是手机的十倍，UI 不能只按像素等比，
	# 否则 4K 电视上「一个字占屏 1%」等于看不清。按短边分档放大。
	if short_side >= 1800.0:
		return TV_SCALE_UHD
	if short_side >= 900.0:
		return TV_SCALE_1080
	return 1.0
