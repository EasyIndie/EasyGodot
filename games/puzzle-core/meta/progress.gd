# progress.gd — 玩家进度持久化：已完成 / 最佳步数 / 最佳回放。
#
# 与规则层解耦：只认「关卡 key」字符串（约定 = 关卡文件名去扩展名，例如 "level_01"），
# 不依赖 Board / State / 场景，可在 headless 下单测。
# 存档路径可注入 → 测试写临时文件，不污染 user://progress.json。
#
# 这一层同时是 Replay 与「排行榜基础」的数据底座：
#   - 每关保留一份**最佳步数的回放**（moves 为方向标签序列，可重放）
#   - completed / best_moves 用于顺序解锁与进度展示
extends RefCounted

const DEFAULT_PATH := "user://progress.json"
const FORMAT := 1
const MAX_RUNS := 5   # 每关保留的本机榜条数

var path: String = DEFAULT_PATH
var _completed: Dictionary = {}   # {key: true}
var _best: Dictionary = {}        # {key: int}  最佳步数
var _replays: Dictionary = {}     # {key: {moves: Array[String], move_count: int, at: int}}
var _runs: Dictionary = {}        # {key: [{moves: int, at: int}, ...]} 按步数升序，本机榜


func _init(p_path: String = DEFAULT_PATH) -> void:
	path = p_path
	_read()


# ── 读取 / 写出 ─────────────────────────────────────────

func _read() -> void:
	_completed.clear()
	_best.clear()
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
	for k in d.get("completed", {}):
		_completed[str(k)] = true
	for k in d.get("best_moves", {}):
		_best[str(k)] = int(d["best_moves"][k])
	for k in d.get("replays", {}):
		var r = d["replays"][k]
		if r is Dictionary and (r.get("moves") is Array):
			var mv: Array = r["moves"]
			_replays[str(k)] = {
				"moves": mv,
				"move_count": int(r.get("move_count", mv.size())),
				"at": int(r.get("at", 0)),
			}
	for k in d.get("runs", {}):
		var arr = d["runs"][k]
		if arr is Array:
			var rs: Array = []
			for r in arr:
				if r is Dictionary:
					rs.append({"moves": int(r.get("moves", 0)), "at": int(r.get("at", 0))})
			_runs[str(k)] = rs
	# 兼容旧存档：只有最佳步数、没有本机榜时补一条，保证榜单不为空
	for k in _best.keys():
		if not _runs.has(k):
			_runs[k] = [{"moves": int(_best[k]), "at": 0}]


func save() -> bool:
	var dir := path.get_base_dir()
	if dir != "":
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify({
		"format": FORMAT,
		"completed": _completed,
		"best_moves": _best,
		"replays": _replays,
		"runs": _runs,
	}, "\t"))
	f.close()
	return true


# ── 查询 ───────────────────────────────────────────────

func is_completed(key: String) -> bool:
	return _completed.has(key)


func completed_count() -> int:
	return _completed.size()


func best_moves(key: String) -> int:
	return int(_best.get(key, -1))


func has_replay(key: String) -> bool:
	var r: Dictionary = _replays.get(key, {})
	return not r.is_empty() and not (r.get("moves", []) as Array).is_empty()


func replay(key: String) -> Dictionary:
	return _replays.get(key, {})


func runs(key: String) -> Array:
	# 本机榜（按步数升序，最多 MAX_RUNS 条）
	return _runs.get(key, [])


func is_unlocked(index: int, keys: Array) -> bool:
	# 顺序解锁：第 1 关常开；第 N 关需第 N-1 关已通关
	if index <= 0:
		return true
	if index >= keys.size():
		return false
	return _completed.has(str(keys[index - 1]))


# ── 写入 ───────────────────────────────────────────────

func record_win(key: String, moves: Array) -> Dictionary:
	# 记录一次通关；仅当首次或步数更少时覆盖「最佳回放」
	var first: bool = not _completed.has(key)
	var prev: int = int(_best.get(key, -1))
	var now: int = moves.size()
	var at: int = int(Time.get_unix_time_from_system())
	_completed[key] = true

	# 本机榜：每局都进榜，按步数升序，只保留前 MAX_RUNS 条
	var rs: Array = (_runs.get(key, []) as Array).duplicate()
	rs.append({"moves": now, "at": at})
	rs.sort_custom(func(a, b) -> bool: return int(a["moves"]) < int(b["moves"]))
	if rs.size() > MAX_RUNS:
		rs.resize(MAX_RUNS)
	_runs[key] = rs

	var improved: bool = prev < 0 or now < prev
	if improved:
		_best[key] = now
		_replays[key] = {
			"moves": moves.duplicate(),
			"move_count": now,
			"at": at,
		}
	save()
	return {"first_clear": first, "improved": improved, "prev_best": prev, "move_count": now}


func reset() -> void:
	_completed.clear()
	_best.clear()
	_replays.clear()
	_runs.clear()
	save()
