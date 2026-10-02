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
# 超采样倍数：等轴测全是长斜边，直接按目标尺寸画会一整排锯齿
const SUPERSAMPLE := 3
# ── Web 页面用（跟着游戏一起发布）──────────────────────
const OUT_FAVICON := "res://web/favicon.png"                 # 浏览器标签页图标（小尺寸专用构图）
const OUT_APPLE_TOUCH := "res://web/apple-touch-icon.png"    # iOS 主屏图标（180×180）
const OUT_SPLASH := "res://web/splash.png"                   # 启动画面（**透明底**，底色交给平台）

const FILL_ICON := 0.72    # 图标内容占画布短边的比例（留系统圆角遮罩的安全边）
const FILL_FEATURE := 0.88


func _init() -> void:
	_run()


func _ensure_dir(path: String) -> void:
	# 输出目录不存在时 Godot 存不了图（"Can't save PNG at path"），
	# 而新建目录（如 res://web/）在干净克隆里必然不存在 —— 工具自己负责建。
	var d: String = path.get_base_dir()
	if d != "":
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(d))


func _run() -> void:
	var ok := true
	ok = await _render(1024, 1024, "icon", OUT_ICON) and ok
	ok = await _render(512, 512, "icon", OUT_STORE_ICON) and ok
	ok = await _render(1024, 500, "feature", OUT_FEATURE) and ok
	# 电视 banner：Play 的 TV 商店页要求 320×180（等比缩小同一构图，小尺寸下依然认得出）
	ok = await _render(320, 180, "feature", OUT_TV_BANNER) and ok
	# Web：启动画面（透明底标记）+ 专用小图标。
	# 启动画面刻意用**透明底**：底色由网页 CSS 与 boot_splash/bg_color 提供，
	# 这样任何屏幕比例（object-fit: contain）都不会出现突兀的色块边框。
	ok = await _render(512, 512, "mark", OUT_SPLASH) and ok
	# 注意：视口有最小尺寸，实际会输出 64×64（报告以真实产物为准，见下方 report）
	ok = await _render(64, 64, "mark_tight", OUT_FAVICON) and ok
	ok = await _render(180, 180, "icon", OUT_APPLE_TOUCH) and ok
	var report: Dictionary = {}
	# 结构化输出必须**如实**列出所有产物（少写一个，下游就会以为它不存在）
	for p in [OUT_ICON, OUT_STORE_ICON, OUT_FEATURE, OUT_TV_BANNER, OUT_SPLASH, OUT_FAVICON, OUT_APPLE_TOUCH]:
		var img := Image.load_from_file(ProjectSettings.globalize_path(p))
		report[p.get_file()] = [img.get_width(), img.get_height()] if img != null else []
	print(JSON.stringify({"status": "ok" if ok else "fail", "assets": report}))
	quit(0 if ok else 1)


func _render(w: int, h: int, kind: String, out_path: String) -> bool:
	_ensure_dir(out_path)
	# 用 SubViewport 而不是根视口渲染，原因有二：
	#   1) 超采样不受窗口尺寸限制（根视口会被窗口大小夹住，想放大也放不了）
	#   2) transparent_bg 是**真**透明，不用去改全局清屏色（改全局容易漏恢复）
	# 超采样再缩回来，斜边才不会有锯齿 —— 直接按目标尺寸画，等轴测的长斜边
	# 在网页上会被放大到 300px，一排锯齿非常显眼（真实反馈：图示"很粗糙"）。
	var vp := SubViewport.new()
	vp.size = Vector2i(w * SUPERSAMPLE, h * SUPERSAMPLE)
	vp.transparent_bg = true
	vp.disable_3d = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(vp)
	var painter := Painter.new()
	painter.kind = kind
	painter.fill_ratio = FILL_FEATURE
	if kind == "icon" or kind == "mark":
		painter.fill_ratio = FILL_ICON
	elif kind == "mark_tight":
		painter.fill_ratio = 0.94   # 小图标要更满：留白多等于看不见
	vp.add_child(painter)
	painter.size = Vector2(vp.size)
	painter.position = Vector2.ZERO
	await process_frame
	await process_frame
	var tex := vp.get_texture()
	if tex == null:
		push_error("make_store_assets: 拿不到 viewport 纹理（需要可渲染环境）")
		vp.queue_free()
		return false
	var img: Image = tex.get_image()
	# 缩回目标尺寸：LANCZOS 边缘平滑且不发糊（比近邻/双线性都干净）
	img.convert(Image.FORMAT_RGBA8)
	img.resize(w, h, Image.INTERPOLATE_LANCZOS)
	var err := img.save_png(ProjectSettings.globalize_path(out_path))
	vp.queue_free()
	await process_frame
	if err != OK:
		push_error("make_store_assets: 写不出 " + out_path)
		return false
	print("  已生成 %s  %d×%d" % [out_path, img.get_width(), img.get_height()])
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
		if kind != "mark" and kind != "mark_tight":
			_draw_backdrop(vp)
		# mark / mark_tight 是"透明底"构图：底色由平台提供（网页 CSS / boot_splash bg_color）
		var shapes: Array = []
		match kind:
			"feature":
				shapes = _feature_shapes()
			"mark", "icon":
				shapes = _mark_shapes(false)
			_:
				shapes = _mark_shapes(true)   # favicon：小尺寸，去掉光晕
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

	# 品牌标记：立着的骨牌 + 旁边的目标格。
	#
	# 这一版把上一版的三个毛病一起改掉：
	#   · 生硬的灰椭圆影子 → 多层低透明度椭圆叠出的接触阴影（Canvas 没有模糊，只能这么叠）
	#   · "挖空"的菱形光圈（位置还偏在格子左上角）→ 居中的靶心：内嵌菱形描边 + 中心亮点
	#   · 描边过黑（darkened 0.66）在小尺寸下糊成一团 → 同色系描边 + 三个面拉开明度
	# small = favicon 用：去掉光晕（小尺寸下只会变成一坨糊斑）。
	func _mark_shapes(small: bool) -> Array:
		var out: Array = []
		var goal_c := _cell_center(1, 0)
		if not small:
			out.append_array(_glow(goal_c, 0.95, Game.COLOR_GOAL))
		out.append_array(_soft_shadow(_cell_center(0, 0), Vector2(0.62, 0.30)))
		out.append_array(_tile_at(1, 0, Game.COLOR_GOAL, false))
		out.append_array(_goal_frame(goal_c, small))
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
		out.append_array(_soft_shadow(Vector2(0.5, 1.25), Vector2(1.5, 0.52)))
		for gx in range(6):
			for gz in range(4):
				if holes.has("%d,%d" % [gx, gz]):
					continue
				var at := Vector2(float(gx - gz), float(gx + gz) * 0.5)
				if gx == goal.x and gz == goal.y:
					out.append_array(_glow(_cell_center(gx, gz), 0.85, Game.COLOR_GOAL))
					out.append_array(_tile_at(gx, gz, Game.COLOR_GOAL, false))
					out.append_array(_goal_frame(_cell_center(gx, gz), false))
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

	# 格 (gx,gz) 的地面菱形中心（单位空间）。
	# 注意 _tile_at 的原点是菱形**上角**，中心要再往下半格 —— 上一版的
	# 光圈就是错把原点当中心，整体偏在格子左上角。
	func _cell_center(gx: int, gz: int) -> Vector2:
		return Vector2(float(gx - gz), float(gx + gz) * 0.5 + 0.5)

	# 目标格的靶心：内嵌菱形描边 + 中心亮点。
	# 比"挖空"的环更清楚：小到 16px 也认得出是个"目标"。
	func _goal_frame(center: Vector2, small: bool) -> Array:
		var col: Color = Game.COLOR_GOAL_RING.lightened(0.18)
		var rw := 0.56
		var rh := 0.28
		var ring := PackedVector2Array([
			center + Vector2(0.0, -rh), center + Vector2(rw, 0.0),
			center + Vector2(0.0, rh), center + Vector2(-rw, 0.0)])
		var dot := 0.15 if small else 0.19
		var core := PackedVector2Array([
			center + Vector2(0.0, -dot), center + Vector2(dot * 2.0, 0.0),
			center + Vector2(0.0, dot), center + Vector2(-dot * 2.0, 0.0)])
		return [
			{"pts": ring, "fill": col, "line": col, "only_line": true, "lw": OUTLINE * 1.25},
			{"pts": core, "fill": col},
		]

	# 椭圆（低透明度填充），阴影与光晕都由它叠出来
	func _ellipse(center: Vector2, r: Vector2, col: Color) -> Dictionary:
		var pts := PackedVector2Array()
		var n := 64
		for i in range(n):
			var a := TAU * float(i) / float(n)
			pts.append(center + Vector2(cos(a) * r.x, sin(a) * r.y))
		return {"pts": pts, "fill": col}

	# 接触阴影：多层椭圆叠出模糊感（越外越淡越大）。
	# 上一版是一块单层 0.38 不透明度的扁椭圆 —— 在深色页面上就是一块灰饼。
	func _soft_shadow(center: Vector2, r: Vector2) -> Array:
		var out: Array = []
		var layers := 7
		for i in range(layers, 0, -1):
			var t := float(i) / float(layers)          # 1 = 最外层
			var a: float = 0.085 * pow(1.0 - t, 1.8) + 0.012
			out.append(_ellipse(center, r * (0.70 + 0.60 * t), Color(0.02, 0.03, 0.07, a)))
		return out

	# 目标格光晕：同心椭圆叠出柔和辉光（与游戏里目标格的光效同色系）
	func _glow(center: Vector2, r: float, col: Color) -> Array:
		var out: Array = []
		var layers := 9
		for i in range(layers, 0, -1):
			var t := float(i) / float(layers)
			out.append(_ellipse(center,
				Vector2(r * (0.55 + 0.75 * t), r * (0.26 + 0.38 * t)),
				Color(col.r, col.g, col.b, 0.045 * (1.0 - t) + 0.007)))
		return out


	# 立方体：底面在 center（单位空间），向上叠 y_off 格。顶面亮 / +x 面中 / +z 面暗
	func _cube(center: Vector2, y_off: float) -> Array:
		var y0 := y_off
		var y1 := y_off + 1.0
		var c: Color = Game.COLOR_BLOCK
		# 描边是**同色系**的深色，不用近黑：近黑描边在小尺寸下会把三个面糊成一团
		var e: Color = c.darkened(0.52)
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
			{"pts": fz, "fill": c.darkened(0.38), "line": e, "lw": OUTLINE},
			{"pts": fx, "fill": c.darkened(0.14), "line": e, "lw": OUTLINE},
			{"pts": top, "fill": c.lightened(0.32), "line": e, "lw": OUTLINE},
		]


