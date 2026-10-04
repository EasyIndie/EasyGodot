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
	_test_one_move_per_gesture()
	_test_slow_drag_still_works()
	_test_second_gesture_fires_again()
	_test_no_flip_within_gesture()
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
	# 每一条屏幕分界线都拒绝猜测，无论上一手是什么方向。
	for prev in [Vector3i.ZERO, Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)]:
		for angle in [0.0, 90.0, 180.0, 270.0]:
			for off in [-5.0, 0.0, 5.0]:
				check(Gesture.resolve(_polar(angle + off, 80.0), DIRS, prev) == Vector3i.ZERO,
					"分界线附近不依靠历史猜方向")
	check(Gesture.resolve(_polar(-60.0, 60.0), DIRS, Vector3i(1, 0, 0)) == Vector3i(0, 0, -1), "明确转向应立即识别")
	var t = Tracker.new(DIRS)
	t.begin(Vector2.ZERO)
	check(t.feed(Vector2(0, -80)) == Vector3i.ZERO, "足够长但模糊的滑动也不误触")
	check(t.feed(Vector2(55, -95)) == Vector3i(0, 0, -1), "模糊滑动修正为右上后无需重按即可移动")
	t.begin(Vector2.ZERO)
	check(t.feed(Vector2(0, 60)) == Vector3i.ZERO, "长位移处于分界线时不提前触发")
	check(t.feed(Vector2(25, 50)) == Vector3i.ZERO, "已达到距离阈值但运动折返时不提前确认")
	check(t.feed(Vector2(40, 60)) == Vector3i(1, 0, 0), "累计位移与当前运动一致后触发右下")
	# 两轴长度不等时也应按屏幕角度，不能被短轴放大后的系数带偏。
	var skew = DIRS.duplicate()
	skew[Vector3i(1, 0, 0)] *= 4.0
	skew[Vector3i(-1, 0, 0)] *= 4.0
	check(Gesture.resolve(_polar(35.26, 80), skew) == Vector3i(1, 0, 0), "不同投影长度不改变指向")
	check(Gesture.resolve(_polar(35.26, 80), DIRS, Vector3i(-1, 0, 0)) == Vector3i(1, 0, 0), "明确反向允许掉头")
	t.begin(Vector2.ZERO)
	t.set_dirs(DIRS)
	check(t.feed(Vector2(80, 60)) == Vector3i.ZERO, "重新取景取消旧手势")


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


func _test_one_move_per_gesture() -> void:
	# ── 铁律：一次手势至多一步 ──
	# 真机反馈：「滑一次会滚很多次」——上一版做成"锚点前移 → 像摇杆一样连滚"，
	# 一次 200px 的滑动在小屏手机上会滚 5 格。对解谜游戏来说多滚一格就是误操作。
	# 这里把规则钉死：**同一个手势里，无论继续拖多远、来回拖几次，都只出第一步**。
	var step := Vector2(0.8165, 0.5774) * CELL
	# 1) 一次长拖（4 格屏宽）只出一步
	var t = Tracker.new(DIRS)
	t.begin(Vector2.ZERO)
	var got: Array = []
	for i in range(1, 9):
		var d: Vector3i = t.feed(step * float(i) * 0.5)
		if d != Vector3i.ZERO:
			got.append(d)
	check(got.size() == 1, "一次长拖只能出一步，实际 %d 步 %s" % [got.size(), str(got)])
	check(got.size() == 1 and got[0] == Vector3i(1, 0, 0), "那一步应是 +x")
	# 2) 出过一步之后：来回拖、换方向拖，都不许再出
	check(t.feed(step * 4.0) == Vector3i.ZERO, "出过一步后继续同向拖不该再出")
	check(t.feed(Vector2(-step.x * 6.0, -step.y * 6.0)) == Vector3i.ZERO, "出过一步后来回拖也不该再出")
	check(t.feed(Vector2(0.8165, -0.5774) * CELL * 3.0) == Vector3i.ZERO, "出过一步后换方向拖也不该再出")
	check(t.peek(step * 4.0) == Vector3i.ZERO, "出过一步的手势不该再指向任何方向（指示器要淡出）")


func _test_second_gesture_fires_again() -> void:
	# 抬手后再滑 = 新手势，必须能再出一步（否则就"滑不动"了）
	var step := Vector2(0.8165, 0.5774) * CELL
	var t = Tracker.new(DIRS)
	var got: Array = []
	for k in range(3):
		t.begin(Vector2(float(k) * 10.0, 0.0))
		var d: Vector3i = t.feed(Vector2(float(k) * 10.0, 0.0) + step * 1.2)
		if d != Vector3i.ZERO:
			got.append(d)
		t.cancel()
	check(got.size() == 3, "三次独立手势应各出一步，实际 %d 步" % got.size())
	for d in got:
		check(d == Vector3i(1, 0, 0), "每一步都应是 +x")


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


func _test_no_flip_within_gesture() -> void:
	# 出过一步之后手指回抖：不许反向滚动（一步手势就是一步，回抖不该再触发）
	var step := Vector2(0.8165, 0.5774) * CELL
	var t = Tracker.new(DIRS)
	t.begin(Vector2.ZERO)
	check(t.feed(step * 1.2) == Vector3i(1, 0, 0), "先向右下滚一格")
	check(t.feed(step * 0.3) == Vector3i.ZERO, "回抖不该再出步")
	check(t.feed(-step * 2.0) == Vector3i.ZERO, "反向拖到底也不该再出步")


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
