# gesture.gd — 滑动手势的解算逻辑（**纯逻辑**：不碰节点、不碰相机、不碰引擎）。
#
# 为什么单独抽一层：
#   手势的正确性全在"角度边界"上 —— 哪个角度算 +x、哪个算 -z、含糊的时候听谁的。
#   这种东西靠手在手机上试是试不出来的（试三个角度都"还行"，第四个角度就翻车）。
#   抽成纯函数后可以把 0°~359° 逐个喂进去断言，边界才真的被钉住。
#
# 按投影后的四条屏幕方向比较角度，不让格子长度或上一手影响玩家的新意图。
# 两个方向过于接近时返回 ZERO，等待更明确的轨迹；一次手势仍只产生一步。
extends RefCounted

const ANGLE_MARGIN := 16.0   # 最接近的两个方向至少相差 16°，边界两侧各留约 8° 纠正带
const MAX_ANGLE := 60.0
const STEP_RATIO := 0.75
const STEP_MIN := 26.0       # 阈值下限（像素）：太小会被手指抖动触发
const STEP_MAX := 56.0       # 阈值上限（像素）：太大在平板上会滑不动
const STEP_DEFAULT := 40.0   # 拿不到格子屏宽时的兜底

const AXIS_X := Vector3i(1, 0, 0)
const AXIS_Z := Vector3i(0, 0, 1)


# 取某方向在屏幕上的向量（不归一化：长度 = 走一格在屏幕上的像素数）。
static func dir_of(screen_dirs: Dictionary, d: Vector3i) -> Vector2:
	if d == Vector3i.ZERO or screen_dirs.is_empty():
		return Vector2.ZERO
	if screen_dirs.has(d):
		return screen_dirs[d]
	var opposite := Vector3i(-d.x, -d.y, -d.z)
	if screen_dirs.has(opposite):
		return -Vector2(screen_dirs[opposite])
	return Vector2.ZERO


# 把"沿棋盘两轴各走了几格"(a, b) 解出来：delta = a·ex + b·ez。
#
# 必须**解方程**而不是点积：等距视角下 ex 与 ez 夹角约 127°（不垂直），
# 用 delta·ex 当"沿 x 走了多少"会系统性高估，45° 附近还会判歪。
static func grid_components(delta: Vector2, screen_dirs: Dictionary) -> Vector2:
	var ex: Vector2 = dir_of(screen_dirs, AXIS_X)
	var ez: Vector2 = dir_of(screen_dirs, AXIS_Z)
	var det: float = ex.x * ez.y - ex.y * ez.x
	if absf(det) < 0.000001:
		return Vector2.ZERO      # 两轴在屏幕上重合（相机正好压平）→ 无法判断
	# Cramer 法则：a 用 delta 替换第 1 列、b 替换第 2 列。
	# 注意 b 的分子是 ex.x·dy − dx·ex.y（不是 dx·ez.y）——
	# 默认相机下 ex.y == ez.y，写错也看不出来，只有"相机转过角度"的用例能暴露。
	return Vector2(
		(delta.x * ez.y - delta.y * ez.x) / det,
		(ex.x * delta.y - delta.x * ex.y) / det)


# prev 保留参数以兼容调用方；新手势绝不根据历史方向猜测。
static func resolve(delta: Vector2, screen_dirs: Dictionary, _prev: Vector3i = Vector3i.ZERO) -> Vector3i:
	if not delta.is_finite() or delta.length() < 0.0001:
		return Vector3i.ZERO
	var ex: Vector2 = dir_of(screen_dirs, AXIS_X)
	var ez: Vector2 = dir_of(screen_dirs, AXIS_Z)
	if ex.length() < 0.0001 or ez.length() < 0.0001 or absf(ex.normalized().cross(ez.normalized())) < 0.05:
		return Vector3i.ZERO
	var best: float = INF
	var second: float = INF
	var picked := Vector3i.ZERO
	for d in [AXIS_X, -AXIS_X, AXIS_Z, -AXIS_Z]:
		var angle: float = absf(rad_to_deg(delta.angle_to(dir_of(screen_dirs, d))))
		if angle < best:
			second = best
			best = angle
			picked = d
		elif angle < second:
			second = angle
	if best > MAX_ANGLE or second - best < ANGLE_MARGIN:
		return Vector3i.ZERO
	return picked


# 这次移动需要的滑动距离（像素）：按格子屏宽缩放并 clamp。
static func step_px(screen_dirs: Dictionary, d: Vector3i) -> float:
	var cell: float = dir_of(screen_dirs, d).length()
	if cell < 0.0001:
		return STEP_DEFAULT
	return clampf(cell * STEP_RATIO, STEP_MIN, STEP_MAX)


# 已滑动位移里"朝方向 d 走了多少"（投影到该方向的单位向量上）。
# 不在该方向上的位移不计数 —— 否则斜着划过去会误触发。
static func progress(delta: Vector2, screen_dirs: Dictionary, d: Vector3i) -> float:
	var v: Vector2 = dir_of(screen_dirs, d)
	if v.length() < 0.0001:
		return 0.0
	return delta.dot(v.normalized())
