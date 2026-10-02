# test_web.gd — 网页侧资产与外壳守卫（headless）。
#
# 守三件"改起来很容易悄悄失效"的事：
#   1) 浏览器标签页/主屏图标、启动画面这些**散文件**真的存在且尺寸正确
#   2) 加载画面用的是我们自己的品牌与配色（默认是 Godot 的 logo + 灰底）
#   3) 导出流水线真的会把散文件拷进站点（只放进 .pck 的话浏览器会 404）
extends SceneTree

const WEB_ASSETS := {
	"res://web/favicon.png": Vector2i(64, 64),
	"res://web/apple-touch-icon.png": Vector2i(180, 180),
	"res://web/splash.png": Vector2i(512, 512),
}

var checks: int = 0
var failures: int = 0


func _init() -> void:
	_test_assets()
	_test_splash_transparent()
	_test_project_settings()
	_test_head_include()
	_test_pipeline()

	var result: Dictionary = {
		"suite": "test_web",
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


func _img(path: String) -> Image:
	if not FileAccess.file_exists(path):
		return null
	return Image.load_from_file(ProjectSettings.globalize_path(path))


func _test_assets() -> void:
	# 用素材工具生成，尺寸必须与测试里写的一致（工具改了构图/尺寸时这里会立刻红）
	for path in WEB_ASSETS.keys():
		var want: Vector2i = WEB_ASSETS[path]
		var img: Image = _img(path)
		check(img != null, "%s 应存在（跑 tools/make_store_assets.gd 生成）" % path)
		if img == null:
			continue
		check(img.get_width() == want.x and img.get_height() == want.y,
			"%s 尺寸应为 %dx%d，实际 %dx%d" % [path, want.x, want.y, img.get_width(), img.get_height()])


func _test_splash_transparent() -> void:
	# 启动画面刻意是**透明底**：底色由网页 CSS / boot_splash/bg_color 提供。
	# 一旦某次生成带上了不透明底色，网页上就会出现一块突兀的方块 —— 所以要断言。
	var img: Image = _img("res://web/splash.png")
	if img == null:
		return
	var corners: Array = [
		Vector2i(0, 0), Vector2i(img.get_width() - 1, 0),
		Vector2i(0, img.get_height() - 1), Vector2i(img.get_width() - 1, img.get_height() - 1),
	]
	var opaque_corners := 0
	for c in corners:
		if img.get_pixelv(c).a > 0.5:
			opaque_corners += 1
	check(opaque_corners == 0, "启动画面四角必须是透明的（实际有 %d 个不透明）" % opaque_corners)
	# 中间必须有内容（防止生成了一张全透明空图）
	var center: Color = img.get_pixelv(Vector2i(img.get_width() / 2, img.get_height() / 2))
	check(center.a > 0.5, "启动画面中心应有内容（不能是空图）")


func _test_project_settings() -> void:
	# 启动画面必须指向我们的标记，而不是引擎默认 logo
	var splash: String = str(ProjectSettings.get_setting("application/boot_splash/image", ""))
	check(splash == "res://web/splash.png", "boot_splash/image 应指向 res://web/splash.png（实际 %s）" % splash)
	check(bool(ProjectSettings.get_setting("application/boot_splash/show_image", false)), "启动画面应显示图片")
	# Godot 4.7 的字段是 stretch_mode，枚举 = Disabled,Keep,Keep Width,Keep Height,Cover,Ignore。
	# 1 = Keep（保持比例、按自身尺寸居中）—— 透明标记要的就是这个；
	# 4/5 会把标记拉开变形，0 则不画。这里钉死"不许变成拉伸档"。
	var mode: int = int(ProjectSettings.get_setting("application/boot_splash/stretch_mode", 1))
	check(mode == 1, "启动画面应保持比例居中（stretch_mode=1 Keep，实际 %d）" % mode)
	# 底色要与网页背景一致，否则加载完成前后会闪一下色差
	var bg: Color = ProjectSettings.get_setting("application/boot_splash/bg_color", Color.BLACK)
	var head: String = _read_abs("workflow/web/head_include.html")
	check(head.contains("background: #0b0f18"), "网页背景色应在 head_include 里定义")
	var page_hex: String = "#%02x%02x%02x" % [int(round(bg.r * 255.0)), int(round(bg.g * 255.0)), int(round(bg.b * 255.0))]
	check(head.contains(page_hex), "启动画面底色 %s 应与网页背景一致（避免加载完成时闪一下）" % page_hex)


func _read(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var f := FileAccess.open(path, FileAccess.READ)
	var t := f.get_as_text()
	f.close()
	return t


func _read_abs(rel: String) -> String:
	# 仓库根 = res:// 的上一级的上一级（games/puzzle-core → games → 仓库根）
	var abs_path: String = ProjectSettings.globalize_path("res://").path_join("../../" + rel)
	if not FileAccess.file_exists(abs_path):
		return ""
	var f := FileAccess.open(abs_path, FileAccess.READ)
	var t := f.get_as_text()
	f.close()
	return t


func _test_head_include() -> void:
	# head_include 是"网页外壳样式"的源文件（gf-web-inject.sh 会把它写进导出预设）
	var head: String = _read_abs("workflow/web/head_include.html")
	check(head != "", "workflow/web/head_include.html 应存在")
	if head == "":
		return
	# 品牌与文案（默认是 Godot logo + 灰底，这里必须是我们自己的）
	check(head.contains("滚方块"), "加载画面应有游戏名")
	check(head.contains("正在加载"), "加载画面应有中文加载提示")
	check(head.contains("#status") and head.contains("#status-progress"), "应覆盖加载层与进度条样式")
	check(head.contains("radial-gradient"), "加载背景应换成我们的渐变（默认是 #242424 灰底）")
	check(head.contains("ff8a3d") or head.contains("ff9a4d"), "进度条应用我们的橙色")
	# 图标（同时有 HTML link 与 JS 兜底改指向）
	check(head.contains("favicon.png"), "应引用自制的 favicon.png")
	check(head.contains("apple-touch-icon.png"), "应引用自制的 apple-touch-icon.png")
	check(head.contains("-gd-engine-icon"), "应把模板生成的图标 link 改指向（双保险）")
	# 既有功能不能被这次改动弄丢（安全区域 + 像素预算 + 诊断）
	check(head.contains("gfSafeInsets"), "安全区域接口不能丢")
	check(head.contains("viewport-fit"), "viewport-fit=cover 补丁不能丢")
	check(head.contains("devicePixelRatio"), "像素比预算不能丢")


func _test_pipeline() -> void:
	# 导出流水线必须真的把散文件拷进站点：只放在 .pck 里浏览器会 404
	var sh: String = _read_abs("workflow/scripts/gf-export.sh")
	check(sh.contains("favicon.png") and sh.contains("apple-touch-icon.png"),
		"gf-export.sh 应把 web/*.png 拷进导出目录")
	# 导出预设里的 head_include 必须与源文件同步（由 gf-web-inject.sh 写入）
	var cfg: String = _read("res://export_presets.cfg")
	check(cfg.contains("正在加载"), "export_presets.cfg 的 head_include 应已注入（跑 gf-web-inject.sh）")
	check(cfg.contains("favicon.png"), "导出产物里的图标引用也应在预设中")
