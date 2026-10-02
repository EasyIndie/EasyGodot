# mechanisms.gd — 机关的数据表 + 纯规则（不依赖 Board/State 的具体实现，只按字段读写）。
#
# 设计原则与 shapes.gd 一致：**机关是数据，不是代码**。
# 每种机关用 kind + 参数描述，规则层按 kind 分支；新增一种机关只动这一个文件，
# 不需要到求解器/渲染/生成器里到处写 if。
#
# 支持的 kind（见 workflow/docs/10-level-mechanics.md）：
#   switch  : 开关。方块占地覆盖它即触发，控制某个 bridge/gate 的开合
#   bridge  : 桥。开 = 实心可站；关 = 空洞（但有「幽灵框」提示将来会有路）
#   gate    : 闸门。开 = 变成空洞（封路）；关 = 实心。与 bridge 相反，同一个机制两种参数
#   portal  : 传送门。进入其中一格 → 出现在配对格，姿态不变（姿态约束）
#
# 曾经实现过 fragile（碎裂砖：离开即碎 → 单向路径），**已整体删除**。
# 理由（不是"没时间做"，而是它过不了本项目的硬规则）：把碎裂砖换成普通实心格后，
# 最优解**一模一样** —— 最优玩家本来就不会走回头路，所以它只是惩罚乱走，
# 不制造任何必须推理的约束。详见 workflow/docs/10-level-mechanics.md §7.4。
extends RefCounted

const MechState = preload("res://core/mech_state.gd")

const KINDS: Array = ["switch", "bridge", "gate", "portal"]

# 需要「先用开关打开才能站」的 kind（初始关闭）
const CLOSED_BY_DEFAULT: Array = ["bridge"]
# 需要「先用开关关上才能站」的 kind（初始开启 = 实心）
const OPEN_BY_DEFAULT: Array = ["gate"]


static func parse(raw_list) -> Array:
	# 从关卡 JSON 解析机关定义。**宽容**：不认识的 kind / 缺字段就跳过（不让坏关卡崩游戏），
	# 但把问题收集在 defs 里，交给 validate 去报错。
	var out: Array = []
	for raw in raw_list:
		if not (raw is Dictionary):
			continue
		var kind: String = str(raw.get("kind", ""))
		if not KINDS.has(kind):
			continue
		var def: Dictionary = {
			"id": str(raw.get("id", "")),
			"kind": kind,
			"tiles": _tiles(raw.get("tiles", [])),
			"target": str(raw.get("target", "")),   # switch → 被控制的 bridge/gate 的 id
			"mode": str(raw.get("mode", "toggle")),  # switch: toggle（每次翻转）| latch（只开不关）
			"links": _links(raw.get("links", [])),   # portal: 配对格（按顺序循环）
		}
		out.append(def)
	return out


static func _tiles(arr) -> Array:
	var out: Array = []
	for t in arr:
		if t is Array and t.size() >= 2:
			out.append(Vector2i(int(t[0]), int(t[1])))
	return out


static func _links(arr) -> Array:
	# portal 的配对格：支持 [[x,z], [x,z]] 或 [[x,z],[x,z],[x,z]]（多格循环）
	var out: Array = []
	for t in arr:
		if t is Array and t.size() >= 2:
			out.append(Vector2i(int(t[0]), int(t[1])))
	return out


static func find(defs: Array, id: String) -> Dictionary:
	for d in defs:
		if str(d["id"]) == id:
			return d
	return {}


static func tiles_of(defs: Array, kind: String) -> Array:
	var out: Array = []
	for d in defs:
		if str(d["kind"]) == kind:
			out.append_array(d["tiles"])
	return out


# ── 规则 ─────────────────────────────────────────────

static func _on_tile(defs: Array, cell) -> Array:
	# 该格上挂着哪些机关（同一格可以挂多个，例如某块瓦片上既有开关又有桥）
	var out: Array = []
	for d in defs:
		var kind: String = str(d["kind"])
		var pool: Array = d["tiles"] if kind != "portal" else d["links"]
		for t in pool:
			if t == Vector2i(cell.x, cell.z):
				out.append(d)
				break
	return out


static func is_solid(board, defs: Array, mech, cell) -> bool:
	# 「这一格现在有没有地面」的**唯一**判定（机关版）。
	#
	# 判定顺序不是随意的，这里踩过一次真 bug：
	#   **补地类机关（bridge）必须早于「静态空洞」判定** ——
	#   桥的全部意义就是"架在空洞上补出一条路"，先判空洞就直接返回 false，
	#   于是桥永远不可能存在（表现为：机关明明开着，方块就是过不去，且毫无报错）。
	# 顺序：界内 → 补地类（桥）→ 静态空洞 → 拆地类（闸门）→ 默认有地。
	if not board.is_inside(cell):
		return false
	for d in _on_tile(defs, cell):
		var kind: String = str(d["kind"])
		if kind == "bridge":
			# 桥：开 = 可站（哪怕下面是空洞）；关 = 空洞
			return _is_open(defs, mech, str(d["id"]))
	if board.is_void(cell):
		return false
	for d in _on_tile(defs, cell):
		if str(d["kind"]) == "gate":
			# 闸门：关 = 实心可站；开 = 空洞（封路）
			return not _is_open(defs, mech, str(d["id"]))
	return true


static func _is_open(defs: Array, mech, id: String) -> bool:
	if mech == null:
		return false
	return mech.flag(id)


static func supports(board, defs: Array, mech, world_cells: Array) -> bool:
	for c in world_cells:
		if not is_solid(board, defs, mech, c):
			return false
	return true


static func on_enter(board, defs: Array, mech, world_cells: Array):
	# 方块落到 world_cells 之后发生的机关效果，返回新的 MechState（**不原地修改**）。
	# 效果：踩到开关 → 翻转 / 锁定它控制的目标
	var cur = mech
	if cur == null:
		cur = MechState.new()

	# ① 开关
	# **必须按「占地」而不是按「占用单元」遍历**：竖立的骨牌占两个单元但只占一格，
	# 按单元遍历会让同一格开关被触发两次（翻转开关 = 转回原状，玩家会觉得开关坏了）。
	for v2 in footprint_of(world_cells):
		var cell := Vector3i(v2.x, 0, v2.y)
		for d in _on_tile(defs, cell):
			if str(d["kind"]) != "switch":
				continue
			var target: String = str(d["target"])
			var mode: String = str(d["mode"])
			if mode == "latch":
				# 只开不关：踩过就永久生效（玩家的推理更简单，用作教学关）
				cur = cur.with_flag(target, true)
			else:
				# toggle：每次压上翻转一次。同一格「离开再回来」会翻第二次 ——
				# 这是刻意的：玩家必须记住自己按过几次（这也是这个机制的推理点之一）。
				cur = cur.with_flag(target, not cur.flag(target))

	return cur


static func teleport(board, defs: Array, state, mech) -> Dictionary:
	# 传送：若方块当前占到了某一格传送门 → 把它送到配对的下一格。
	# 返回 {"state": 新状态, "moved": bool}；姿态不变（这正是它的推理点）。
	# 规则细节：只认「占地格」里**第一个**命中的传送门（避免顺序歧义）；
	# 落点如果站不住（对面是空洞 / 关着的桥）→ 视为坠落（交给调用方判 fall）。
	for cell in state.world_cells():
		for d in defs:
			if str(d["kind"]) != "portal":
				continue
			var links: Array = d["links"]
			var idx: int = links.find(Vector2i(cell.x, cell.z))
			if idx < 0 or links.size() < 2:
				continue
			var dst: Vector2i = links[(idx + 1) % links.size()]
			var delta := Vector3i(dst.x - cell.x, 0, dst.y - cell.z)
			# 占地整体平移同样的偏移（姿态不变），这样"从哪个格子进"都能自洽
			return {"state": state.get_script().new(state.shape, state.orientation, state.position + delta),
				"moved": true}
	return {"state": state, "moved": false}


static func is_goal(board, defs: Array, mech, world_cells: Array) -> bool:
	# 胜负判定与棋盘层一致（机关的动态性不影响目标集合的口径）
	return board.is_goal(world_cells)


static func footprint_of(world_cells: Array) -> Array:
	# 占地（去重的 Array[Vector2i]）。机关判定必须用它 —— 竖立方块占两单元但只占一格。
	var seen: Dictionary = {}
	var out: Array = []
	for c in world_cells:
		var k := Vector2i(c.x, c.z)
		if seen.has(k):
			continue
		seen[k] = true
		out.append(k)
	return out


static func roles_of(defs: Array) -> Dictionary:
	# {"x,z": kind}，供渲染层查每一格是什么机关（同格多机关时取**更“拦路”的那个**）
	var out: Dictionary = {}
	var priority: Array = ["bridge", "gate", "portal", "switch"]
	for d in defs:
		var kind: String = str(d["kind"])
		var pool: Array = d["tiles"] if kind != "portal" else d["links"]
		for t in pool:
			var k: String = "%d,%d" % [t.x, t.y]
			if not out.has(k):
				out[k] = kind
			elif priority.find(kind) < priority.find(str(out[k])):
				out[k] = kind
	return out


static func count_controllable(defs: Array) -> int:
	# 受开关控制的机关数量（质检与生成器用来判断"机关是不是承重的"）
	var n: int = 0
	for d in defs:
		if str(d["kind"]) == "switch":
			n += 1
	return n
