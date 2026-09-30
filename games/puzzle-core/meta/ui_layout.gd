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


static func best_dir(swipe: Vector2, screen_dirs: Dictionary) -> Vector3i:
	# 把滑动方向映射到**屏幕上最接近**的网格方向（与相机取景一致）。
	# 完全竖直/水平的滑动会落在两个方向的正中间（平局），此时按字典插入顺序取第一个，
	# 保证同一手势结果稳定；玩家只要斜一点滑就能精确指向。
	if swipe.length() < 0.0001:
		return Vector3i.ZERO
	var s: Vector2 = swipe.normalized()
	var best: Vector3i = Vector3i.ZERO
	var best_score: float = -2.0
	for d in screen_dirs.keys():
		var v: Vector2 = screen_dirs[d]
		if v.length() < 0.0001:
			continue
		var score: float = s.dot(v.normalized())
		if score > best_score + 0.000001:
			best_score = score
			best = d
	return best


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
