# test_mobile.gd — 移动端发布就绪度守卫（headless）。
#
# 为什么需要它：**商店要求不是“写一次就完了”，而是每次构建都得满足**。
#   · Google Play 只接受 AAB（新应用）、要 512×512 图标与 1024×500 特色图
#   · Apple 需要 bundle id、App Store 分发方式、1024 图标
#   · 两端必须用**同一个包名**（改包名 = 换一个 App，已上架就来不及了）
# 这些配置全是纯文本，很容易在重构/加平台时被改坏，而且坏了要等到上架审核才被发现。
# 所以这里把它们当成断言来守。
extends SceneTree


func _init() -> void:
	_run()


func _run() -> void:
	_test_project_settings()
	_test_icon_assets()
	_test_export_presets()
	_report_and_quit()


var checks: int = 0
var failures: int = 0


func check(cond: bool, msg: String) -> void:
	checks += 1
	if not cond:
		failures += 1
		push_error("FAIL: " + msg)


func _report_and_quit() -> void:
	var result: Dictionary = {
		"suite": "test_mobile",
		"checks": checks,
		"failures": failures,
		"status": "ok" if failures == 0 else "fail",
	}
	print(JSON.stringify(result))
	quit(0 if failures == 0 else 1)


# ── 1. 工程设置 ─────────────────────────────────────────

func _test_project_settings() -> void:
	# 图标：Android/iOS 的启动器图标都由这一个文件派生
	check(str(ProjectSettings.get_setting("application/config/icon", "")) == "res://icon.png",
		"config/icon 应指向 res://icon.png（Android/iOS 启动器图标来源）")

	# 返回键：默认 true 会直接退出游戏 → 移动端玩家会当成闪退
	check(ProjectSettings.get_setting("application/config/quit_on_go_back", true) == false,
		"config/quit_on_go_back 必须为 false，返回键交给我们处理")

	# 方向：6 = SENSOR（横竖屏都允许）。本作 UI 是分辨率无关的，已做双向适配。
	check(int(ProjectSettings.get_setting("display/window/handheld/orientation", 0)) == 6,
		"handheld/orientation 应为 6（传感器/横竖屏都支持）")

	# 商店要展示版本号与名称
	check(str(ProjectSettings.get_setting("application/config/version", "")) != "",
		"config/version 不能为空（商店与 AAB 版本号要用）")
	check(str(ProjectSettings.get_setting("application/config/name", "")) != "",
		"config/name 不能为空（Android 启动器名称的兜底值）")


# ── 2. 图标与商店素材 ───────────────────────────────────

func _test_icon_assets() -> void:
	var icon := _load_image("res://icon.png")
	check(icon != null, "icon.png 应存在且可解码")
	if icon != null:
		check(icon.get_width() == icon.get_height(), "应用图标应为正方形")
		check(icon.get_width() >= 1024, "应用图标边长应 ≥1024（Apple 要求 1024；Android 会自行降采样）")
		# 图标不能是纯色（那说明绘制脚本挂了，生成了一张空图）
		check(_distinct_colors(icon) > 50, "应用图标应包含足够多的颜色（不是空图/纯色图）")

	# Google Play 商店页图标：必须正好 512×512
	var store := _load_image("res://store_icon_512.png")
	check(store != null, "store_icon_512.png 应存在")
	if store != null:
		check(store.get_width() == 512 and store.get_height() == 512,
			"商店图标必须是 512×512（Play 要求），实际 %d×%d" % [store.get_width(), store.get_height()])

	# Google Play 特色图片：必须正好 1024×500
	var feat := _load_image("res://store_feature_1024x500.png")
	check(feat != null, "store_feature_1024x500.png 应存在")
	if feat != null:
		check(feat.get_width() == 1024 and feat.get_height() == 500,
			"特色图必须是 1024×500（Play 要求），实际 %d×%d" % [feat.get_width(), feat.get_height()])


func _load_image(path: String) -> Image:
	if not ResourceLoader.exists(path):
		return null
	var tex := load(path)
	if tex is Texture2D:
		return (tex as Texture2D).get_image()
	if tex is Image:
		return tex
	return null


func _distinct_colors(img: Image) -> int:
	var seen: Dictionary = {}
	# 采样，避免逐像素太慢
	var step: int = maxi(1, img.get_width() / 64)
	for y in range(0, img.get_height(), step):
		for x in range(0, img.get_width(), step):
			seen[img.get_pixel(x, y).to_rgba32()] = true
			if seen.size() > 200:
				return seen.size()
	return seen.size()


# ── 3. 导出预设（商店格式与包名）─────────────────────────

func _test_export_presets() -> void:
	var cfg := ConfigFile.new()
	var err := cfg.load("res://export_presets.cfg")
	check(err == OK, "export_presets.cfg 应可解析")
	if err != OK:
		return

	var by_name: Dictionary = {}
	var idx := 0
	while cfg.has_section("preset.%d" % idx):
		var sec := "preset.%d" % idx
		by_name[str(cfg.get_value(sec, "name", ""))] = sec
		# 每个预设都必须排除测试/工具与**商店素材**（素材不该进玩家的 pck）
		# exclude_filter 是**预设级**的键（在 [preset.N] 里，不在 [preset.N.options]）
		var ex := str(cfg.get_value(sec, "exclude_filter", ""))
		check(ex.contains("tests/*") and ex.contains("tools/*"),
			"预设「%s」应排除 tests/tools" % str(cfg.get_value(sec, "name", "")))
		check(ex.contains("store_"), "预设「%s」应排除 store_* 商店素材（别打进包）" % str(cfg.get_value(sec, "name", "")))
		idx += 1

	check(by_name.has("Android (AAB)"), "应有 Android (AAB) 预设（Play 只收 AAB）")
	check(by_name.has("Android (APK)"), "应有 Android (APK) 预设（本机试玩用）")
	check(by_name.has("iOS"), "应有 iOS 预设")

	var aab_sec: String = str(by_name.get("Android (AAB)", ""))
	if aab_sec != "":
		var o := aab_sec + ".options"
		check(str(cfg.get_value(aab_sec, "platform", "")) == "Android", "AAB 预设的 platform 应为 Android")
		check(int(cfg.get_value(o, "gradle_build/export_format", -1)) == 1, "AAB 预设导出格式应为 AAB（1）")
		check(bool(cfg.get_value(o, "gradle_build/use_gradle_build", false)) == true,
			"AAB 导出必须启用 Gradle 构建（否则 Play 不认）")
		check(str(cfg.get_value(aab_sec, "export_path", "")).ends_with(".aab"), "AAB 预设的导出路径应以 .aab 结尾")
		check(bool(cfg.get_value(o, "screen/immersive_mode", false)) == true,
			"Android 应开启沉浸模式（隐藏系统栏，全屏游戏）")
		check(bool(cfg.get_value(o, "package/signed", false)) == true, "Android 导出必须签名")
		var pkg := str(cfg.get_value(o, "package/unique_name", ""))
		check(pkg != "" and not pkg.begins_with("com.example"), "包名必须是真的（不能留 com.example）: " + pkg)
		check(pkg.split(".").size() >= 2, "包名应形如 com.xxx.yyy: " + pkg)

		# iOS 与 Android 必须同一个包名：改包名等于换一个 App，上架后再改就晚了
		var ios_sec: String = str(by_name.get("iOS", ""))
		if ios_sec != "":
			var b: String = str(cfg.get_value(ios_sec + ".options", "application/bundle_identifier", ""))
			check(b == pkg, "iOS bundle id 应与 Android 包名一致（都表示同一个产品）: %s vs %s" % [b, pkg])
			check(int(cfg.get_value(ios_sec + ".options", "application/export_method_release", -1)) == 0,
				"iOS 发布应使用 App Store 分发方式（0）")

	var apk_sec: String = str(by_name.get("Android (APK)", ""))
	if apk_sec != "":
		check(int(cfg.get_value(apk_sec + ".options", "gradle_build/export_format", -1)) == 0,
			"APK 预设有导出格式应为 APK（0）")
		check(str(cfg.get_value(apk_sec, "export_path", "")).ends_with(".apk"), "APK 预设路径应以 .apk 结尾")

	# 桌面/网页预设不能被这次改动弄坏
	check(by_name.has("Web") and by_name.has("Linux") and by_name.has("Windows"),
		"Web/Linux/Windows 预设应保留")
