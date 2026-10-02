# mech_state.gd — 机关状态（值对象，与引擎解耦）。
#
# 为什么必须单独存在：加了机关之后，**同一组占用单元 + 不同的机关状态 = 两个不同的世界**。
# 求解器如果把这两者当成同一个状态，就会给出「不存在的解」（这是本次改造最容易做错的一处）。
# 所以状态键 = 方块占用单元 + 机关状态。
#
# 值语义：任何修改都返回**新对象**（with_* / duplicate），绝不原地改 ——
# BFS 里同一个 MechState 会被多条路径共享，就地修改会互相污染。
extends RefCounted

var flags: Dictionary = {}    # {机关 id: bool}  开关/桥的开合、闸门的状态


func _init(p_flags: Dictionary = {}) -> void:
	flags = p_flags.duplicate()


func duplicate():
	return get_script().new(flags)


func flag(id: String) -> bool:
	return bool(flags.get(id, false))


func with_flag(id: String, on: bool):
	var n = duplicate()
	n.flags[id] = on
	return n


func is_empty() -> bool:
	return flags.is_empty()


func key() -> String:
	# 规范键：**排序**后拼接，保证同一状态只有一个键（字典遍历顺序不可依赖）
	var ks: Array = flags.keys()
	ks.sort()
	var s := ""
	for k in ks:
		s += "%s=%d;" % [k, 1 if bool(flags[k]) else 0]
	return s
