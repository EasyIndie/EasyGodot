# progress.gd — 玩家进度持久化：已完成 / 最佳步数 / 最佳回放。
#
# 与规则层解耦：只认「关卡 key」字符串（约定 = 关卡文件名去扩展名，例如 "level_01"），
# 不依赖 Board / State / 场景，可在 headless 下单测。
# 存档路径可注入 → 测试写临时文件，不污染 user://progress.json。
#
# 两套「通关」概念必须分开（这是一个真实设计坑）：
#   _completed → **本轮**通关进度：顺序解锁、进度展示、通关庆祝的判据
#   _ever      → **曾经**通关过：只用于解锁与「最佳记录」展示，只增不减
# 分开的原因：「再玩一遍」要能把本轮进度清零（否则第二轮打完也没有庆祝，
# 玩家永远只能被恭喜一次），但绝不能因此没收玩家的记录，也不能把已解锁的关卡重新锁上
# —— 那等于惩罚玩家重玩。
#
# 这一层同时是 Replay 与「排行榜基础」的数据底座：
# 「最佳步数」与「最快时间」是两个**互相独立**的记录：步数最少的解法不一定是最快的
# （慢慢想、反复试错往往步数更少但更慢），所以回放跟步数记录走，时间记录单独存。
#
#   - 每关保留一份**最佳步数的回放**（moves 为方向标签序列，可重放）
#   - completed / best_moves 用于顺序解锁与进度展示
extends RefCounted

const DEFAULT_PATH := "user://progress.json"
const FORMAT := 1
const MAX_RUNS := 5   # 每关保留的本机榜条数

var path: String = DEFAULT_PATH
var _completed: Dictionary = {}   # {key: true} 本轮通关进度
var _ever: Dictionary = {}        # {key: true} 曾经通关（解锁 + 记录展示，只增不减）
var _best: Dictionary = {}        # {key: int}  最佳步数
var _best_time: Dictionary = {}   # {key: int}  最快用时（毫秒）
var _replays: Dictionary = {}     # {key: {moves: Array[String], move_count: int, at: int}}
var _runs: Dictionary = {}        # {key: [{moves: int, at: int}, ...]} 按步数升序，本机榜
var _ghost: bool = false          # 偏好：是否显示「上次的走法」影子（默认关，避免剧透）
# 偏好：是否在屏幕上显示方向键。默认**关** —— 手势是主要输入，
# 少一块按钮，棋盘就多一块（真机反馈：屏幕上的按钮太多太抢）。
var _pad: bool = false
var _current_level: String = ""  # 普通模式最近玩的关卡；好友挑战不覆盖它


func _init(p_path: String = DEFAULT_PATH) -> void:
	path = p_path
	_read()


# ── 读取 / 写出 ─────────────────────────────────────────

func _read() -> void:
	_completed.clear()
	_ever.clear()
	_best.clear()
	_best_time.clear()
	_replays.clear()
	_runs.clear()
	if not FileAccess.file_exists(path):
		return
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return
	var txt := f.get_as_text()
	f.close()
	var j := JSON.new()
	if j.parse(txt) != OK:
		return  # 存档损坏 → 视为全新进度（不阻断游戏）
	var d = j.data
	if not (d is Dictionary):
		return
	for k in _map(d, "completed"):
		_completed[str(k)] = true
	for k in _map(d, "cleared_ever"):
		_ever[str(k)] = true
	for k in _map(d, "best_moves"):
		if _valid_record(d["best_moves"][k]):
			_best[str(k)] = int(d["best_moves"][k])
	for k in _map(d, "best_times"):
		if _valid_record(d["best_times"][k]):
			_best_time[str(k)] = int(d["best_times"][k])
	for k in _map(d, "replays"):
		var r = d["replays"][k]
		if r is Dictionary and (r.get("moves") is Array):
			var mv: Array = r["moves"]
			_replays[str(k)] = {
				"moves": mv,
				"move_count": int(r.get("move_count", mv.size())),
				"at": int(r.get("at", 0)),
			}
	_ghost = bool(d.get("ghost", false))
	_pad = bool(d.get("pad", false))
	_current_level = str(d.get("current_level", ""))
	for k in _map(d, "runs"):
		var arr = d["runs"][k]
		if arr is Array:
			var rs: Array = []
			for r in arr:
				if r is Dictionary:
					# time_ms 缺省 -1 = 该局没有计时（旧存档 / 未启用计时的调用）
					rs.append({
						"moves": int(r.get("moves", 0)),
						"at": int(r.get("at", 0)),
						"time_ms": int(r.get("time_ms", -1)),
					})
			_runs[str(k)] = rs
	# 兼容旧存档：老格式没有 cleared_ever → 用 completed 回填（老存档的 completed 就是历史）
	if _ever.is_empty():
		for k in _completed.keys():
			_ever[k] = true
	# 兼容旧存档：只有最佳步数、没有本机榜时补一条，保证榜单不为空
	for k in _best.keys():
		if not _runs.has(k):
			_runs[k] = [{
				"moves": int(_best[k]),
				"at": 0,
				"time_ms": int(_best_time.get(k, -1)),
			}]


static func _map(data: Dictionary, key: String) -> Dictionary:
	var value = data.get(key, {})
	return value if value is Dictionary else {}


static func _valid_record(value) -> bool:
	return (value is int or value is float) and is_finite(float(value)) and float(value) >= 0.0


func save() -> bool:
	var dir := path.get_base_dir()
	if dir != "":
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	# 先写临时文件，再替换正式存档；写入被打断时保留上一次完整进度。
	var pending: String = path + ".tmp"
	var f := FileAccess.open(pending, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify({
		"format": FORMAT,
		"completed": _completed,
		"cleared_ever": _ever,
		"best_moves": _best,
		"best_times": _best_time,
		"replays": _replays,
		"runs": _runs,
		"ghost": _ghost,
		"pad": _pad,
		"current_level": _current_level,
	}, "\t"))
	f.flush()
	var write_error: Error = f.get_error()
	f.close()
	if write_error != OK:
		return false
	return DirAccess.rename_absolute(ProjectSettings.globalize_path(pending), ProjectSettings.globalize_path(path)) == OK


# ── 查询 ───────────────────────────────────────────────

func is_completed(key: String) -> bool:
	# 本轮是否已通关
	return _completed.has(key)


func has_ever_cleared(key: String) -> bool:
	# 历史上是否通关过（记录展示 / 解锁依据）
	return _ever.has(key)


func ever_count() -> int:
	return _ever.size()


func replay_round() -> bool:
	# 是否处在「重玩一轮」中：已经通关过全部，但本轮进度还没补满
	return _ever.size() > _completed.size()


func completed_count() -> int:
	return _completed.size()


func best_moves(key: String) -> int:
	return int(_best.get(key, -1))


func best_time(key: String) -> int:
	# 最快用时（毫秒）；-1 = 还没有计时记录
	return int(_best_time.get(key, -1))


func best_time_count() -> int:
	return _best_time.size()


func has_replay(key: String) -> bool:
	var r: Dictionary = _replays.get(key, {})
	return not r.is_empty() and not (r.get("moves", []) as Array).is_empty()


func replay(key: String) -> Dictionary:
	return _replays.get(key, {})


func runs(key: String) -> Array:
	# 本机榜（按步数升序，最多 MAX_RUNS 条）
	return _runs.get(key, [])


func ghost_enabled() -> bool:
	return _ghost


func set_ghost_enabled(on: bool) -> void:
	# 玩家偏好，和记录一起存在进度文件里（下次启动仍然是他的选择）
	_ghost = on
	save()


func pad_enabled() -> bool:
	return _pad


func set_pad_enabled(on: bool) -> void:
	# 与影子一样：是玩家偏好，和记录一起存进进度文件
	_pad = on
	save()


func is_unlocked(index: int, keys: Array) -> bool:
	# 顺序解锁：第 1 关常开；第 N 关需第 N-1 关已通关
	if index <= 0:
		return true
	if index >= keys.size():
		return false
	# 解锁依据是「曾经通关」：一旦解锁就永远解锁，
	# 「再玩一遍」清空本轮进度时不能把关卡重新锁上（那等于惩罚玩家重玩）
	return _ever.has(str(keys[index - 1]))


func set_current_level(key: String) -> void:
	if _current_level == key:
		return
	_current_level = key
	save()


func resume_index(keys: Array) -> int:
	# 未完成的一关优先续玩；旧存档没有游玩位置时续到第一关未完成关卡。
	# 所有关卡已完成时保留最近选择，方便继续挑战自己的纪录。
	var last: int = keys.find(_current_level)
	if last >= 0 and is_unlocked(last, keys) and not is_completed(str(keys[last])):
		return last
	for i in range(keys.size()):
		if is_unlocked(i, keys) and not is_completed(str(keys[i])):
			return i
	return last if last >= 0 and is_unlocked(last, keys) else 0


# ── 写入 ───────────────────────────────────────────────

func record_win(key: String, moves: Array, time_ms: int = -1) -> Dictionary:
	# 记录一次通关。time_ms < 0 表示这一局没有计时（旧调用），此时不碰时间记录。
	var first: bool = not _completed.has(key)
	var prev: int = int(_best.get(key, -1))
	var prev_time: int = int(_best_time.get(key, -1))
	var now: int = moves.size()
	var at: int = int(Time.get_unix_time_from_system())
	_completed[key] = true
	_ever[key] = true

	# 本机榜：每局都进榜，按步数升序，只保留前 MAX_RUNS 条
	var rs: Array = (_runs.get(key, []) as Array).duplicate()
	rs.append({"moves": now, "at": at, "time_ms": time_ms})
	rs.sort_custom(func(a, b) -> bool: return int(a["moves"]) < int(b["moves"]))
	if rs.size() > MAX_RUNS:
		rs.resize(MAX_RUNS)
	_runs[key] = rs

	var improved: bool = prev < 0 or now < prev
	var time_improved: bool = time_ms >= 0 and (prev_time < 0 or time_ms < prev_time)
	if time_improved:
		_best_time[key] = time_ms
	if improved:
		_best[key] = now
		_replays[key] = {
			"moves": moves.duplicate(),
			"move_count": now,
			"at": at,
		}
	save()
	return {
		"first_clear": first,
		"improved": improved,
		"prev_best": prev,
		"move_count": now,
		"time_ms": time_ms,
		"time_improved": time_improved,
		"prev_best_time": prev_time,
	}


func reset_campaign() -> void:
	# 「再玩一遍」：只清本轮通关进度。
	# 保留 best / replays / runs（玩家的记录是资产）与 _ever（已解锁关卡不重锁）。
	_completed.clear()
	_current_level = ""
	save()


func reset() -> void:
	# 「重置进度」：彻底清空（记录 + 解锁 + 本轮进度）
	_completed.clear()
	_ever.clear()
	_best.clear()
	_best_time.clear()
	_replays.clear()
	_runs.clear()
	_ghost = false
	_pad = false
	_current_level = ""
	save()
