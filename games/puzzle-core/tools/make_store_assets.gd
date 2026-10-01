# make_store_assets.gd — 生成商店素材（应用图标 / 商店图标 / 特色图）。
#
# 用法：
#   DISPLAY=:0 workflow/scripts/gf-run.sh -p games/puzzle-core res://tools/make_store_assets.gd
#   （需要能渲染的环境；headless 拿不到 viewport 纹理会报错退出）
#
# 为什么用 2D 矢量绘制，而不是抓 3D 截图：
#   图标要在 **48×48 的桌面快捷方式**上也能认出来。等距投影 + 三个明暗面 + 描边
#   在小尺寸下比真实 3D 渲染干净得多（柔和阴影与高光一缩小就糊成一团）。
#   配色直接取 game.gd 的常量 → 图标与游戏画面是同一套色，改配色这里会一起变。
#
# 构图方式（重要，避免手算坐标踩坑）：
#   形状都在「单位空间」里描述（1 单位 = 1 格），用 _p(x,y,z) 做等距投影。
#   绘制前先求所有点的包围盒，再自动算缩放与居中偏移 →
#   改构图只改形状列表，不用手算像素位置。
#   （早期版本手写绝对像素偏移，结果目标格被画到画布左上角/底边外。）
#
# 产出（工程根目录；store_* 被导出过滤器排除，不进 pck）：
#   icon.png                    1024×1024  → project.godot 的 config/icon，
#                                            同时是 Android / iOS 启动器图标的来源
#   store_icon_512.png           512×512   → Google Play 商店页图标（人工上传）
#   store_feature_1024x500.png  1024×500   → Google Play 特色图片（人工上传）
extends SceneTree

const OUT_ICON := "res://icon.png"
const OUT_STORE_ICON := "res://store_icon_512.png"
const OUT_FEATURE := "res://store_feature_1024x500.png"
const OUT_TV_BANNER := "res://store_tv_banner_320x180.png"

const FILL_ICON := 0.72    # 图标内容占画布短边的比例（留系统圆角遮罩的安全边）
const FILL_FEATURE := 0.88


func _init() -> void:
	_run()


func _run() -> void:
	var ok := true
	ok = await _render(1024, 1024, "icon", OUT_ICON) and ok
	ok = await _render(512, 512, "icon", OUT_STORE_ICON) and ok
	ok = await _render(1024, 500, "feature", OUT_FEATURE) and ok
	# 电视 banner：Play 的 TV 商店页要求 320×180（等比缩小同一构图，小尺寸下依然认得出）
	ok = await _render(320, 180, "feature", OUT_TV_BANNER) and ok
	var report: Dictionary = {}
	for p in [OUT_ICON, OUT_STORE_ICON, OUT_FEATURE, OUT_TV_BANNER]:
		var img := Image.load_from_file(ProjectSettings.globalize_path(p))
		report[p.get_file()] = [img.get_width(), img.get_height()] if img != null else []
	print(JSON.stringify({"status": "ok" if ok else "fail", "assets": report}))
	quit(0 if ok else 1)


func _render(w: int, h: int, kind: String, out_path: String) -> bool:
	root.size = Vector2i(w, h)
	var painter := Painter.new()
	painter.kind = kind
	painter.fill_ratio = FILL_ICON if kind == "icon" else FILL_FEATURE
	root.add_child(painter)
	painter.size = Vector2(float(w), float(h))
	painter.position = Vector2.ZERO
	await process_frame
	await process_frame
	var tex := root.get_texture()
	if tex == null:
		push_error("make_store_assets: 拿不到 viewport 纹理（需要可渲染环境）")
		painter.queue_free()
		return false
	var img: Image = tex.get_image()
	var err := img.save_png(ProjectSettings.globalize_path(out_path))
	if err != OK:
		push_error("make_store_assets: 写不出 " + out_path)
		painter.queue_free()
		return false
	print("  已生成 %s  %d×%d" % [out_path, img.get_width(), img.get_height()])
	painter.queue_free()
	await process_frame
	return true


# ── 等距绘制器 ──────────────────────────────────────────
#
# 投影（2:1 isometric，与游戏 45° 斜视角同构）：
#   单位空间 → ( x − z , (x + z)/2 − y )
# 可见面 = 顶面 + 朝观察者的两侧（+x 与 +z），三面明暗不同即可读成方块。
class Painter extends Control:
	const Game = preload("res://scenes/game.gd")
	const BG_IN := Color(0.106, 0.153, 0.243)   # 中心（与游戏暗角同色系）
	const BG_OUT := Color(0.043, 0.059, 0.094)  # 边缘
	const OUTLINE := 0.026      # 描边宽度（单位空间）

	# 形状：{"pts": PackedVector2Array, "fill": Color, "line": Color, "lw": float, "only_line": bool}
	var kind := "icon"
	var fill_ratio := 0.8

	func _draw() -> void:
		var vp := get_viewport_rect().size
		_draw_backdrop(vp)
		var shapes: Array = _icon_shapes() if kind == "icon" else _feature_shapes()
		# 包围盒 → 自动缩放与居中（改构图不用手算像素）
		var box := _bbox(shapes)
		var u: float = minf(vp.x * fill_ratio / maxf(box.size.x, 0.001),
			vp.y * fill_ratio / maxf(box.size.y, 0.001))
		var base: Vector2 = vp * 0.5 - box.get_center() * u
		for s in shapes:
			_draw_shape(s, base, u)

	func _draw_shape(s: Dictionary, base: Vector2, u: float) -> void:
		var pts := PackedVector2Array()
		for p in s["pts"]:
			pts.append(base + p * u)
		if not bool(s.get("only_line", false)):
			draw_colored_polygon(pts, s["fill"])
		var lw := float(s.get("lw", 0.0))
		if lw > 0.0:
			var closed := PackedVector2Array(pts)
			closed.append(pts[0])
			draw_polyline(closed, s["line"], lw * u, true)

	func _bbox(shapes: Array) -> Rect2:
		var mn := Vector2(INF, INF)
		var mx := Vector2(-INF, -INF)
		for s in shapes:
			for p in s["pts"]:
				mn = mn.min(p)
				mx = mx.max(p)
		return Rect2(mn, mx - mn)

	# 径向渐变：同心圆近似。任意尺寸都平滑，且不需要渐变纹理。
	func _draw_backdrop(vp: Vector2) -> void:
		draw_rect(Rect2(Vector2.ZERO, vp), BG_OUT, true)
		var c := vp * 0.5
		var r_max: float = maxf(vp.x, vp.y) * 0.78
		var steps := 96
		for i in range(steps, 0, -1):
			var t := float(i) / float(steps)
			draw_circle(c, r_max * t, BG_IN.lerp(BG_OUT, t * t))

	# ── 构图 ──

	# 图标：立着的骨牌（2 格高）+ 前左方一格的目标格 + 影子
	func _icon_shapes() -> Array:
		var out: Array = []
		out.append(_shadow(Vector2(0.0, 0.10), Vector2(1.10, 0.50)))
		out.append_array(_tile_at(1, 0, Game.COLOR_GOAL, false))
		out.append_array(_ring(Vector2(1.0, 0.5), 0.52, Game.COLOR_GOAL_RING))
		out.append_array(_cube(Vector2.ZERO, 0.0))
		out.append_array(_cube(Vector2.ZERO, 1.0))
		return out

	# 特色图：6×4 棋盘碎片（含空洞）+ 躺着的骨牌 + 前方目标格。
	# 构图取 2:1 左右的横向比例（1024×500 ≈ 2.05），所以整体能铺满而不留大片空白。
	# 空洞直接**什么都不画** —— 掉下去是本作的核心机制，视觉上必须是“空的”。
	func _feature_shapes() -> Array:
		var out: Array = []
		var holes: Dictionary = {"0,2": true, "3,0": true, "5,2": true, "4,3": true}
		var goal: Vector2i = Vector2i(4, 1)
		var domino: Array = [Vector2(0.0, 1.0), Vector2(1.0, 1.5)]   # 占 (1,1) 与 (2,1) 两格
		out.append(_shadow(Vector2(0.5, 1.25), Vector2(1.5, 0.52)))
		for gx in range(6):
			for gz in range(4):
				if holes.has("%d,%d" % [gx, gz]):
					continue
				var at := Vector2(float(gx - gz), float(gx + gz) * 0.5)
				if gx == goal.x and gz == goal.y:
					out.append_array(_tile_at(gx, gz, Game.COLOR_GOAL, false))
					out.append_array(_ring(at, 0.50, Game.COLOR_GOAL_RING))
				else:
					var col: Color = Game.COLOR_TILE_A if (gx + gz) % 2 == 0 else Game.COLOR_TILE_B
					out.append_array(_tile_at(gx, gz, col))
		for c in domino:                     # 躺着的骨牌 = 同层两格
			out.append_array(_cube(c, 0.0))
		return out

	# ── 形状构造（全部在单位空间）──

	func _p(x: float, y: float, z: float) -> Vector2:
		return Vector2(x - z, (x + z) * 0.5 - y)

	# 世界格 (gx, gz) 的地面菱形。
	# bevel：上两条边加一道亮边，格子之间才有“厚度感/分界”。目标格不加
	# （它内部还要叠光圈，加亮边会显得很杂）。
	func _tile_at(gx: int, gz: int, col: Color, bevel: bool = true) -> Array:
		var o := Vector2(float(gx - gz), float(gx + gz) * 0.5)
		var q := PackedVector2Array([
			o + _p(0, 0, 0), o + _p(1, 0, 0), o + _p(1, 0, 1), o + _p(0, 0, 1)])
		var out: Array = [{"pts": q, "fill": col, "line": col.darkened(0.38), "lw": OUTLINE}]
		if bevel:
			out.append({"pts": PackedVector2Array([q[3], q[0], q[1]]),
				"fill": col, "line": col.lightened(0.30), "only_line": true, "lw": OUTLINE * 0.9})
		return out

	# 目标格里的光圈：内外两个菱形叠出环（不依赖线宽，缩放稳定）
	func _ring(center: Vector2, r: float, col: Color) -> Array:
		var outer := PackedVector2Array([
			center + Vector2(0, 0), center + Vector2(r, r * 0.5),
			center + Vector2(0, r), center + Vector2(-r, r * 0.5)])
		var mid := center + Vector2(0, r * 0.5)   # 菱形质心
		var inner := PackedVector2Array()
		for p in outer:
			inner.append(mid + (p - mid) * 0.56)
		return [
			{"pts": outer, "fill": col},
			{"pts": inner, "fill": Game.COLOR_GOAL.darkened(0.12)},
		]

	# 立方体：底面在 center（单位空间），向上叠 y_off 格。顶面亮 / +x 面中 / +z 面暗
	func _cube(center: Vector2, y_off: float) -> Array:
		var y0 := y_off
		var y1 := y_off + 1.0
		var c: Color = Game.COLOR_BLOCK
		var e: Color = c.darkened(0.66)
		var top := PackedVector2Array([
			center + _p(0, y1, 0), center + _p(1, y1, 0),
			center + _p(1, y1, 1), center + _p(0, y1, 1)])
		var fx := PackedVector2Array([
			center + _p(1, y0, 0), center + _p(1, y0, 1),
			center + _p(1, y1, 1), center + _p(1, y1, 0)])
		var fz := PackedVector2Array([
			center + _p(0, y0, 1), center + _p(1, y0, 1),
			center + _p(1, y1, 1), center + _p(0, y1, 1)])
		return [
			{"pts": fz, "fill": c.darkened(0.44), "line": e, "lw": OUTLINE},
			{"pts": fx, "fill": c.darkened(0.22), "line": e, "lw": OUTLINE},
			{"pts": top, "fill": c.lightened(0.26), "line": e, "lw": OUTLINE},
		]

	# 影子：压扁的椭圆（低透明度）
	func _shadow(center: Vector2, r: Vector2) -> Dictionary:
		var pts := PackedVector2Array()
		var n := 64
		for i in range(n):
			var a := TAU * float(i) / float(n)
			pts.append(center + Vector2(cos(a) * r.x, sin(a) * r.y))
		return {"pts": pts, "fill": Color(0, 0, 0, 0.38)}
