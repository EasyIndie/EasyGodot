# gesture_tracker.gd — 拖动过程的状态机（把"手指轨迹"变成"一串移动"）。
#
# 与 gesture.gd 分开是刻意的：解算规则是纯函数（可以逐个角度断言），
# 而"什么时候算一次移动"是有状态的（锚点、粘滞方向、连滚）。
# 两层分开后，测试可以只喂坐标序列，不需要任何节点/输入事件。
#
# 用法：
#   var t = Tracker.new(screen_dirs)
#   t.begin(pos)             # 手指按下
#   t.feed(pos) -> Vector3i  # 每个拖动事件；返回要执行的移动（ZERO = 还不到时候）
#   t.cancel()               # 抬手
#
# **出方向后锚点前移到当前位置** —— 这是"跟手"的来源：一次长拖可以连着滚多格。
# 也正因为锚点前移，掉头必须重新滑满一格，手指抖动不会来回滚。
extends RefCounted

const Gesture = preload("res://meta/gesture.gd")

var dirs: Dictionary = {}            # 网格方向 → 屏幕上走一格的向量（像素，不归一化）
var prev: Vector3i = Vector3i.ZERO   # 上一次发出的方向（歧义带里粘滞用）
var anchor: Vector2 = Vector2.ZERO   # 当前位置基准（每次出方向后前移）
var active: bool = false


func _init(screen_dirs: Dictionary = {}) -> void:
	dirs = screen_dirs


func set_dirs(screen_dirs: Dictionary) -> void:
	dirs = screen_dirs


func begin(pos: Vector2) -> void:
	active = true
	anchor = pos


func cancel() -> void:
	active = false


# 手指"指向"哪个方向（还没到阈值也返回）—— 用于给玩家实时反馈与进度显示。
func peek(pos: Vector2) -> Vector3i:
	if not active:
		return Vector3i.ZERO
	return Gesture.resolve(pos - anchor, dirs, prev)


# 距离触发还差多少（0~1）—— 用于画进度环。
func ratio(pos: Vector2) -> float:
	if not active:
		return 0.0
	var d: Vector3i = peek(pos)
	if d == Vector3i.ZERO:
		return 0.0
	var need: float = Gesture.step_px(dirs, d)
	if need <= 0.0:
		return 1.0
	return clampf(Gesture.progress(pos - anchor, dirs, d) / need, 0.0, 1.0)


# 处理一个拖动位置：返回本次要执行的移动（ZERO = 不动）。
func feed(pos: Vector2) -> Vector3i:
	if not active:
		return Vector3i.ZERO
	var delta: Vector2 = pos - anchor
	var d: Vector3i = Gesture.resolve(delta, dirs, prev)
	if d == Vector3i.ZERO:
		return Vector3i.ZERO
	if Gesture.progress(delta, dirs, d) < Gesture.step_px(dirs, d):
		return Vector3i.ZERO
	anchor = pos      # 连滚：锚点前移
	prev = d
	return d
