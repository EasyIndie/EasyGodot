# gesture.gd — 滑动手势的解算逻辑（**纯逻辑**：不碰节点、不碰相机、不碰引擎）。
#
# 为什么单独抽一层：
#   手势的正确性全在"角度边界"上 —— 哪个角度算 +x、哪个算 -z、含糊的时候听谁的。
#   这种东西靠手在手机上试是试不出来的（试三个角度都"还行"，第四个角度就翻车）。
#   抽成纯函数后可以把 0°~359° 逐个喂进去断言，边界才真的被钉住。
#
# ── 这一版修掉的三个真问题（都来自真机反馈）────────────────────────────
#
# ① 方向判错：「角度稍有偏差就滚错方向」
#    根因：等距视角下四个网格方向在屏幕上成对角分布，相邻两向相隔约 127°，
#    而**屏幕正上/正下正好是两个方向的分界线**（数学上的平局点）。手指偏几度
#    分数就翻转。玩家想"往远处滚"时滑的就是近似竖直，于是被随机判成左上或右上。
#    解法：把滑动**解到棋盘坐标系**（解 2×2 方程，得到"沿棋盘两轴各走了几格"），
#    再在**歧义带**里改用粘滞规则：优先保持上一次的方向；两个候选里若有掉头，
#    选另一个（含糊的手势绝不会是想掉头）。
#
# ② 不跟手：原来只在**抬手**时判一次
#    解法：拖动过程中就判（见 gesture_tracker.gd），滑过阈值立刻出方向；
#    出完方向把锚点前移，于是一次长拖能连着滚好几格（像摇杆一样）。
#
# ③ 想清楚再滑就失效：超过 SWIPE_MAX_TIME 的滑动被整条丢弃
#    解法：取消时间限制。慢滑也是滑，只是玩家在思考。
#
# 另外：阈值按**格子屏宽**缩放（clamp 到合理像素区间），4K 平板和 5 寸手机手感一致。
extends RefCounted

const AMBIG := 0.35          # 歧义带：两轴强度差 < 35% 视为"分不出来"（听粘滞规则）
const STEP_RATIO := 1.05     # 一次移动要滑过 ≈1 格屏宽（含余量）
const STEP_MIN := 22.0       # 阈值下限（像素）：太小会被手指抖动触发
const STEP_MAX := 64.0       # 阈值上限（像素）：太大在平板上会滑不动
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


# 滑动 → 网格方向。prev = 上一次**真正发出**的方向，只在歧义带里起作用。
static func resolve(delta: Vector2, screen_dirs: Dictionary, prev: Vector3i = Vector3i.ZERO) -> Vector3i:
	if delta.length() < 0.0001:
		return Vector3i.ZERO
	var ab: Vector2 = grid_components(delta, screen_dirs)
	var ax: float = absf(ab.x)
	var az: float = absf(ab.y)
	if ax < 0.000001 and az < 0.000001:
		return Vector3i.ZERO
	var nx: Vector3i = Vector3i(signi(int(signf(ab.x))), 0, 0) if ax > 0.000001 else Vector3i.ZERO
	var nz: Vector3i = Vector3i(0, 0, signi(int(signf(ab.y)))) if az > 0.000001 else Vector3i.ZERO
	if nz == Vector3i.ZERO:
		return nx
	if nx == Vector3i.ZERO:
		return nz
	if ax > az * (1.0 + AMBIG) or az > ax * (1.0 + AMBIG):
		return nx if ax > az else nz         # 够明确：谁强听谁的
	# ── 歧义带（屏幕正上/正下附近）：听粘滞规则 ──
	if prev == nx or prev == nz:
		return prev                          # 与上次同向 → 保持（手指抖不会翻）
	if nx == -prev:
		return nz                            # 一个候选是掉头 → 选另一个
	if nz == -prev:
		return nx
	return nx if ax >= az else nz            # 没有历史：取强度大的（平局取 x，结果稳定）


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
