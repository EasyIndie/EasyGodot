# test_stopwatch.gd — 秒表（headless）。
# 用注入的假时钟驱动，所以断言是**确定性**的（用真实时间会让测试变得不稳定）。
extends SceneTree

const Stopwatch = preload("res://meta/stopwatch.gd")

var checks: int = 0
var failures: int = 0
var _now: int = 1000


func _init() -> void:
	_test_basic()
	_test_pause_accumulates()
	_test_idempotent()
	_test_reset_keeps_running()
	_test_no_drift()

	var result: Dictionary = {
		"suite": "test_stopwatch",
		"checks": checks,
		"failures": failures,
		"status": "ok" if failures == 0 else "fail",
	}
	print(JSON.stringify(result))
	quit(0 if failures == 0 else 1)


func check(cond: bool, msg: String) -> void:
	checks += 1
	if not cond:
		failures += 1
		printerr("FAIL: " + msg)


func _fake_now() -> int:
	return _now


func _new() -> RefCounted:
	# 注入假时钟：Callable(self, "_fake_now")
	return Stopwatch.new(Callable(self, "_fake_now"))


func _test_basic() -> void:
	_now = 1000
	var sw = _new()
	check(sw.elapsed_ms() == 0, "未开始时应为 0")
	check(not sw.is_running(), "未开始时应为停止状态")
	sw.start()
	check(sw.is_running(), "start 后应在走")
	_now = 3500
	check(sw.elapsed_ms() == 2500, "走着的表要把当前这段算进去（UI 上的秒针不能冻结）")
	sw.stop()
	check(not sw.is_running(), "stop 后应停止")
	_now = 99000
	check(sw.elapsed_ms() == 2500, "停止后时间不再增长")


func _test_pause_accumulates() -> void:
	# 暂停必须是「累计」而不是「丢掉」：这是「最快时间」能不能信的核心
	_now = 0
	var sw = _new()
	sw.start()
	_now = 4000
	sw.stop()
	_now = 50000
	sw.start()
	_now = 56000
	sw.stop()
	check(sw.elapsed_ms() == 10000, "两段 4s + 6s = 10s（中间的 46s 暂停不算）")
	# 反复起停也不能丢
	_now = 60000
	sw.start()
	_now = 61000
	sw.stop()
	check(sw.elapsed_ms() == 11000, "继续累计而不是从零开始")


func _test_idempotent() -> void:
	# 幂等很重要：_refresh_clock() 每帧都会被调用，重复 start 不能把累计时间清零
	_now = 0
	var sw = _new()
	sw.start()
	_now = 5000
	sw.start()
	sw.start()
	_now = 7000
	check(sw.elapsed_ms() == 7000, "重复 start 不应重置起点（否则每帧调用会把计时清零）")
	sw.stop()
	sw.stop()
	sw.set_running(false)
	_now = 8000
	check(sw.elapsed_ms() == 7000, "重复 stop 不应重复累计")
	sw.set_running(true)
	_now = 9000
	check(sw.elapsed_ms() == 8000, "set_running(true) 等价于 start")


func _test_reset_keeps_running() -> void:
	# 重开关卡：归零，但表要保持原有的走/停状态（重开后应该立刻重新计时）
	_now = 0
	var sw = _new()
	sw.start()
	_now = 9000
	sw.reset()
	check(sw.elapsed_ms() == 0, "reset 后归零")
	check(sw.is_running(), "reset 不应改变「在走」的状态")
	_now = 11000
	check(sw.elapsed_ms() == 2000, "归零后继续从新起点累计")

	# 停着的表 reset 后仍然是停的
	var sw2 = _new()
	sw2.reset()
	check(not sw2.is_running(), "停着的表 reset 后仍应停止")
	check(sw2.elapsed_ms() == 0, "停着的表 reset 后归零")


func _test_no_drift() -> void:
	# 用「起止时刻 + 累计」而不是「每帧加 delta」的原因：漏帧/卡顿不能少算时间。
	# 这里模拟一次长时间卡顿（只调用一次 elapsed_ms）也必须精确。
	_now = 0
	var sw = _new()
	sw.start()
	_now = 123456
	check(sw.elapsed_ms() == 123456, "长时间卡顿后依然精确（不依赖每帧调用）")
	sw.stop()
	_now = 200000
	sw.start()
	_now = 200001
	check(sw.elapsed_ms() == 123457, "卡顿段时间已冻结，恢复后只加 1ms")
