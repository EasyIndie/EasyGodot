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
# ── 一条铁律：**一次手势至多产生一步移动** ──
# 曾经实现成"锚点前移 → 一次长拖连着滚多格"（像摇杆），真机立刻被反馈为
# 「滑一次会滚很多次」：一次 200px 的滑动在小屏手机上会滚 5 格。
# 根因是设计错位：**连滚是动作游戏的手感，解谜游戏里每一步都要想**，
# 多滚一格就是误操作（还会污染步数与回放记录）。
# 真正需要修的"不跟手"是**别等抬手才判定**（见下）和**动画期间别丢输入**
# （见 main.gd 的 _flush_pending_move），不是"一次手势多走几步"。
# 所以：滑过阈值 → 立刻出这一手（不等抬手）→ **本手势作废**，抬手后才能再来一步。
extends RefCounted

const Gesture = preload("res://meta/gesture.gd")

var dirs: Dictionary = {}            # 网格方向 → 屏幕上走一格的向量（像素，不归一化）
var prev: Vector3i = Vector3i.ZERO   # 上一次发出的方向（歧义带里粘滞用）
var anchor: Vector2 = Vector2.ZERO   # 本手势的起点（出方向后不再移动）
var active: bool = false
var fired: bool = false              # 本手势是否已经出过一步（出了就作废）


func _init(screen_dirs: Dictionary = {}) -> void:
	dirs = screen_dirs


func set_dirs(screen_dirs: Dictionary) -> void:
	dirs = screen_dirs


func begin(pos: Vector2) -> void:
	active = true
	fired = false
	anchor = pos


func cancel() -> void:
	active = false


# 手指"指向"哪个方向（还没到阈值也返回）—— 用于给玩家实时反馈与进度显示。
# 已经出过一步的手势不再指向任何方向（指示器随之淡出）。
func peek(pos: Vector2) -> Vector3i:
	if not active or fired:
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


# 处理一个拖动位置：返回本次要执行的移动（ZERO = 不动）。一次手势至多返回一步。
func feed(pos: Vector2) -> Vector3i:
	if not active or fired:
		return Vector3i.ZERO
	var delta: Vector2 = pos - anchor
	var d: Vector3i = Gesture.resolve(delta, dirs, prev)
	if d == Vector3i.ZERO:
		return Vector3i.ZERO
	if Gesture.progress(delta, dirs, d) < Gesture.step_px(dirs, d):
		return Vector3i.ZERO
	fired = true      # 本手势作废：继续拖、来回拖都不会再出第二步
	prev = d
	return d
