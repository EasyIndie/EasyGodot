# test_gesture.gd — 滑动手势解算 + 拖动状态机（headless）。
#
# 为什么值得单独一套测试：真机反馈的三个问题（滚错方向 / 不跟手 / 慢滑失效）
# 全都发生在"边界"上，靠手感试是试不出来的。这里把 360° 逐个角度喂进去，
# 把边界钉死；再喂坐标序列验证"什么时候算一次移动"。
extends SceneTree

const Gesture = preload("res://meta/gesture.gd")
const Tracker = preload("res://meta/gesture_tracker.gd")

# 与游戏里一致：屏幕上走一格对应的向量（未归一化，长度 = 格子屏宽）。
# 取 40px 一格：斜 45° 等距下 +x = 右下、-z = 右上、+z = 左下、-x = 左上。
const CELL := 40.0
var DIRS: Dictionary = {}

var checks: int = 0
var failures: int = 0


func _init() -> void:
	var ex := Vector2(0.8165, 0.5774) * CELL
	var ez := Vector2(-0.8165, 0.5774) * CELL
	DIRS = {
		Vector3i(1, 0, 0): ex,
		Vector3i(-1, 0, 0): -ex,
		Vector3i(0, 0, 1): ez,
		Vector3i(0, 0, -1): -ez,
	}
	_test_axis_decoding()
	_test_angle_sweep()
	_test_ambiguous_stickiness()
	_test_threshold_scaling()
	_test_tracker_basics()
	_test_tracker_chain()
	_test_slow_drag_still_works()
	_test_reversal_needs_full_step()
	_test_rotated_camera()
	_test_degenerate_input()
	var result: Dictionary = {
		"suite": "test_gesture", "checks": checks, "failures": failures,
		"status": "ok" if failures == 0 else "fail",
	}
	print(JSON.stringify(result))
	quit(0 if failures == 0 else 1)


func check(cond: bool, msg: String) -> void:
	checks += 1
	if not cond:
		failures += 1
		printerr("FAIL: " + msg)


func _polar(deg: float, r: float) -> Vector2:
	var a := deg_to_rad(deg)
	return Vector2(cos(a), sin(a)) * r


func _test_axis_decoding() -> void:
	# 解方程得到的是"沿棋盘两轴各走了几格"：滑一格 +x 必须得到 (1, 0)
	var eq: Vector2 = Gesture.grid_components(Vector2(0.8165, 0.5774) * CELL, DIRS)
	check(absf(eq.x - CELL / CELL) < 0.01 and absf(eq.y) < 0.01, "右下划一格应解出 (1, 0)，实际 %s" % str(eq))
	var ez: Vector2 = Gesture.grid_components(Vector2(-0.8165, 0.5774) * CELL, DIRS)
	check(absf(ez.x) < 0.01 and absf(ez.y - 1.0) < 0.01, "左下划一格应解出 (0, 1)，实际 %s" % str(ez))
	# 反向
	check(Gesture.resolve(Vector2(-0.8165, -0.5774), DIRS) == Vector3i(-1, 0, 0), "左上应解出 -x")
	check(Gesture.resolve(Vector2(0.8165, -0.5774), DIRS) == Vector3i(0, 0, -1), "右上应解出 -z")


func _test_angle_sweep() -> void:
	# 全场扫描：给出一个方向，只要它离某个网格方向在 ±20° 以内，
	# **必须**解成那个方向（这正是"角度不太一致"的场景）。
	# 相邻两个网格方向相隔约 127°，所以 ±20° 的扇区互不重叠，期望值唯一。
	var expect := {
		-35.26: Vector3i(0, 0, -1),    # 右上
		35.26: Vector3i(1, 0, 0),      # 右下
		144.74: Vector3i(0, 0, 1),     # 左下
		-144.74: Vector3i(-1, 0, 0),   # 左上
	}
	var bad := 0
	var worst := ""
	for base in expect.keys():
		for off in [-20.0, -14.0, -9.0, -5.0, -2.0, 0.0, 2.0, 5.0, 9.0, 14.0, 20.0]:
			var d: Vector3i = Gesture.resolve(_polar(float(base) + off, 60.0), DIRS, Vector3i.ZERO)
			if d != expect[base]:
				bad += 1
				if worst == "":
					worst = "%.2f° 偏 %.1f° → %s（期望 %s）" % [base, off, str(d), str(expect[base])]
	check(bad == 0, "四个主方向 ±20° 内必须稳定解成该方向，有 %d 个角度判错：%s" % [bad, worst])
	# 1° 步进全扫一圈：不允许出现"抖动跳变"（相邻 1° 之间解出两个完全相反的方向）
	var flips := 0
	var prev: Vector3i = Gesture.resolve(_polar(0.0, 60.0), DIRS, Vector3i.ZERO)
	for deg in range(1, 360):
		var d: Vector3i = Gesture.resolve(_polar(float(deg), 60.0), DIRS, Vector3i.ZERO)
		if d != prev and d == -prev and d != Vector3i.ZERO:
			flips += 1
		prev = d
	check(flips == 0, "绕一圈不该出现相邻 1° 直接掉头的情况（实际 %d 处）" % flips)


func _test_ambiguous_stickiness() -> void:
	# 屏幕正上方 = 两个方向（-x 与 -z）的数学平局点 —— 玩家想"往远处滚"时
	# 滑的就是这个角度，上一版会随机翻向。粘滞规则必须让它不翻。
	var up := Vector2(0.0, -60.0)
	check(Gesture.resolve(up, DIRS, Vector3i(0, 0, -1)) == Vector3i(0, 0, -1), "含糊的竖直上滑应保持上次的 -z")
	check(Gesture.resolve(up, DIRS, Vector3i(-1, 0, 0)) == Vector3i(-1, 0, 0), "含糊的竖直上滑应保持上次的 -x")
	# 关键回归：上一次是 +x（往右下），此时竖直上滑的候选是 -x/-z —— 一个都不该选 -x
	#（含糊的手势绝不是"掉头"的意思）
	var d: Vector3i = Gesture.resolve(up, DIRS, Vector3i(1, 0, 0))
	check(d == Vector3i(0, 0, -1), "上次 +x 时竖直上滑不该掉头成 -x（实际 %s）" % str(d))
	# 正下方同理（候选 +x / +z）
	var down := Vector2(0.0, 60.0)
	check(Gesture.resolve(down, DIRS, Vector3i(-1, 0, 0)) == Vector3i(0, 0, 1),
		"上次 -x 时竖直下滑不该掉头成 +x")
	# 没有历史时也要稳定（同一输入永远同一结果）
	var a: Vector3i = Gesture.resolve(up, DIRS, Vector3i.ZERO)
	var b: Vector3i = Gesture.resolve(up, DIRS, Vector3i.ZERO)
	check(a == b and a != Vector3i.ZERO, "无历史时含糊手势也要稳定且有解")
	# 明显偏向时不该被粘滞规则带跑（玩家明确要转弯）
	check(Gesture.resolve(_polar(-60.0, 60.0), DIRS, Vector3i(1, 0, 0)) == Vector3i(0, 0, -1),
		"明确指向 -z 的滑动必须按玩家意图（粘滞不能压过明确意图）")


func _test_threshold_scaling() -> void:
	# 阈值随格子屏宽缩放，并 clamp 在合理区间 —— 大屏不能轻轻一碰就滚
	var small: float = Gesture.step_px(DIRS, Vector3i(1, 0, 0))
	check(small >= Gesture.STEP_MIN and small <= Gesture.STEP_MAX, "阈值应在 [%.0f, %.0f] 内" % [Gesture.STEP_MIN, Gesture.STEP_MAX])
	check(absf(small - CELL * Gesture.STEP_RATIO) < 0.01, "阈值应 ≈ 格子屏宽 × %.2f" % Gesture.STEP_RATIO)
	var big: Dictionary = {
		Vector3i(1, 0, 0): Vector2(200.0, 141.0), Vector3i(0, 0, 1): Vector2(-200.0, 141.0),
	}
	check(Gesture.step_px(big, Vector3i(1, 0, 0)) == Gesture.STEP_MAX, "超大格子应被 clamp 到上限")
	var tiny: Dictionary = {
		Vector3i(1, 0, 0): Vector2(8.0, 5.6), Vector3i(0, 0, 1): Vector2(-8.0, 5.6),
	}
	check(Gesture.step_px(tiny, Vector3i(1, 0, 0)) == Gesture.STEP_MIN, "极小格子应被 clamp 到下限")
	check(Gesture.step_px({}, Vector3i(1, 0, 0)) == Gesture.STEP_DEFAULT, "没有相机信息时应退回默认阈值")


func _test_tracker_basics() -> void:
	var t = Tracker.new(DIRS)
	check(not t.active, "初始应为未激活")
	check(t.feed(Vector2(100, 100)) == Vector3i.ZERO, "没按下时喂位置不该产生移动")
	t.begin(Vector2(100.0, 100.0))
	check(t.active, "begin 后应激活")
	# 抖动：小于阈值不该触发
	check(t.feed(Vector2(104.0, 100.0)) == Vector3i.ZERO, "轻微抖动不该触发移动")
	# 足够远：右下方向滑一格 → +x
	var d: Vector3i = t.feed(Vector2(100.0 + 0.8165 * CELL * 1.3, 100.0 + 0.5774 * CELL * 1.3))
	check(d == Vector3i(1, 0, 0), "滑满一格应触发 +x（实际 %s）" % str(d))
	t.cancel()
	check(not t.active, "cancel 后应停止跟踪")


func _test_tracker_chain() -> void:
	# 一次长拖连滚多格：这是"跟手"的核心
	var t = Tracker.new(DIRS)
	var step := Vector2(0.8165, 0.5774) * CELL * 1.2   # 阈值是 1.05 格，滑"刚好一格"不该触发
	t.begin(Vector2.ZERO)
	var got: Array = []
	for i in range(1, 5):
		var d: Vector3i = t.feed(step * float(i))
		if d != Vector3i.ZERO:
			got.append(d)
	check(got.size() == 4, "连续滑四格应触发四次，实际 %d 次" % got.size())
	for d in got:
		check(d == Vector3i(1, 0, 0), "连滚的每一步都应是 +x")
	# 中途换向：先 +x 一格，再往 -z 滑一格
	var t2 = Tracker.new(DIRS)
	t2.begin(Vector2.ZERO)
	t2.feed(step)
	var d2: Vector3i = t2.feed(step + Vector2(0.8165, -0.5774) * CELL * 1.6)
	check(d2 == Vector3i(0, 0, -1), "换向滑一格应触发 -z（实际 %s）" % str(d2))


func _test_slow_drag_still_works() -> void:
	# 回归：以前有 0.9 秒上限，慢慢滑（想清楚再动手）会被整条丢弃
	var t = Tracker.new(DIRS)
	t.begin(Vector2.ZERO)
	# 分成很多个小步、慢慢挪（模拟 3 秒的慢速拖动）
	var got: Vector3i = Vector3i.ZERO
	var total := 0.0
	while total < CELL * 2.0 and got == Vector3i.ZERO:
		total += 2.0   # 每次只挪 2px：慢，但没有时间上限，最终仍要触发
		got = t.feed(Vector2(0.8165, 0.5774) * total)
	check(got == Vector3i(1, 0, 0), "慢速拖动（无时间上限）也必须能触发移动")


func _test_reversal_needs_full_step() -> void:
	# 出方向后锚点前移，所以掉头要重新滑满一格 —— 手指回抖不会来回滚
	var t = Tracker.new(DIRS)
	var step := Vector2(0.8165, 0.5774) * CELL * 1.2
	t.begin(Vector2.ZERO)
	check(t.feed(step) == Vector3i(1, 0, 0), "先向右下滚一格")
	check(t.feed(step * 0.6) == Vector3i.ZERO, "刚出方向就回抖不该立刻反向")
	var back: Vector3i = t.feed(step * 0.6 - step * 1.3)
	check(back == Vector3i(-1, 0, 0), "回滑满一格才应反向（实际 %s）" % str(back))


func _test_rotated_camera() -> void:
	# 相机整体转 90°（屏幕方向互换）仍要解对 —— 说明解算是"跟着相机"而不是写死的
	var rotated: Dictionary = {
		Vector3i(1, 0, 0): Vector2(0.8165, -0.5774) * CELL,   # +x 变成右上
		Vector3i(-1, 0, 0): Vector2(-0.8165, 0.5774) * CELL,
		Vector3i(0, 0, 1): Vector2(0.8165, 0.5774) * CELL,    # +z 变成右下
		Vector3i(0, 0, -1): Vector2(-0.8165, -0.5774) * CELL,
	}
	check(Gesture.resolve(Vector2(0.8165, -0.5774), rotated) == Vector3i(1, 0, 0), "相机转 90° 后右上应解出 +x")
	check(Gesture.resolve(Vector2(0.8165, 0.5774), rotated) == Vector3i(0, 0, 1), "相机转 90° 后右下应解出 +z")


func _test_degenerate_input() -> void:
	# 退化输入不能崩、不能返回垃圾方向
	check(Gesture.resolve(Vector2.ZERO, DIRS) == Vector3i.ZERO, "零位移应返回无方向")
	check(Gesture.resolve(Vector2(10, 0), {}) == Vector3i.ZERO, "没有相机方向信息时应返回无方向")
	var flat: Dictionary = {   # 两轴在屏幕上重合（相机压平）：应判定为"无法判断"而不是乱猜
		Vector3i(1, 0, 0): Vector2(1.0, 0.0), Vector3i(0, 0, 1): Vector2(2.0, 0.0),
	}
	check(Gesture.resolve(Vector2(5, 5), flat) == Vector3i.ZERO, "退化相机应返回无方向")
	# 只注入了 +x 一个方向时，反向要能靠取负得到
	var half: Dictionary = {Vector3i(0, 0, 1): Vector2(-0.8165, 0.5774) * CELL}
	check(Gesture.dir_of(half, Vector3i(0, 0, -1)).length() > 0.1, "只注入一个轴时应能推出反向")
