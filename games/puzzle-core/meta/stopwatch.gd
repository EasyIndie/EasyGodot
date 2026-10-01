# stopwatch.gd — 秒表（累计计时，可暂停）。
#
# 为什么单独做一个类，而不是在 main.gd 里写 `_elapsed += delta`：
#   1) **可暂停**才是重点：玩家的「最快时间」不能把看选关界面、看回放、
#      切后台接电话的时间算进去（那等于惩罚玩家，记录也就失去意义）。
#      暂停必须靠「起止时刻 + 累计量」做，不能靠每帧加 delta（会漂移、且漏帧就少算）。
#   2) **可注入时钟**，测试才能确定性地验证（真实时间会让测试变得不稳定）。
#   3) 与引擎解耦：不依赖 Node / 场景，可以 headless 单测，第二个游戏也能直接用。
extends RefCounted

var _accum_ms: int = 0        # 已经累计的毫秒（不含当前这一段）
var _started_ms: int = -1     # 当前这一段的起点；-1 = 停表
var _now_fn: Callable = Callable()


func _init(now_fn: Callable = Callable()) -> void:
	# now_fn 传入时用于测试（返回毫秒）；不传就用引擎时间
	_now_fn = now_fn


func _now() -> int:
	if _now_fn.is_valid():
		return int(_now_fn.call())
	return Time.get_ticks_msec()


func start() -> void:
	# 已经在走 → 无操作（重复 start 不能把已累计的时间丢掉）
	if _started_ms < 0:
		_started_ms = _now()


func stop() -> void:
	if _started_ms >= 0:
		_accum_ms += _now() - _started_ms
		_started_ms = -1


func reset() -> void:
	# 归零并保持「当前是否在走」的状态不变：重开关卡时表继续走
	_accum_ms = 0
	if _started_ms >= 0:
		_started_ms = _now()


func is_running() -> bool:
	return _started_ms >= 0


func elapsed_ms() -> int:
	# 走着的表要把当前这段算进去，否则 UI 上会看到秒针「冻结」
	if _started_ms < 0:
		return _accum_ms
	return _accum_ms + (_now() - _started_ms)


func set_running(on: bool) -> void:
	# 幂等开关：状态没变就什么都不做（每帧调用是安全的）
	if on:
		start()
	else:
		stop()
