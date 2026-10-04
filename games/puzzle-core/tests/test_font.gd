# test_font.gd — 字体子集守卫（headless）。
#
# 背景：为控制下载体积与运行时内存（iOS Safari 对单标签页内存极敏感），
# 内置字体是**按项目实际用字裁剪过的子集**（16.4MB -> ~330KB）。
# 风险：若新增文案用到子集外的字，会静默显示成「豆腐块」。
# 本测试遍历会渲染 UI 文本的源码，确保每个字符都有字形。
extends SceneTree

const FONT_PATH := "res://fonts/NotoSansSC-Regular.otf"
const MAX_FONT_BYTES := 1_000_000   # 子集应远小于此；超过说明又被换回完整字体

var checks: int = 0
var failures: int = 0


func _init() -> void:
	_test_size()
	_test_glyph_coverage()
	_report()


func check(cond: bool, msg: String) -> void:
	checks += 1
	if not cond:
		failures += 1
		push_error("FAIL: " + msg)


func _report() -> void:
	print(JSON.stringify({
		"suite": "test_font",
		"checks": checks,
		"failures": failures,
		"status": "ok" if failures == 0 else "fail",
	}))
	quit(0 if failures == 0 else 1)


func _test_size() -> void:
	var f := FileAccess.open(FONT_PATH, FileAccess.READ)
	check(f != null, "内置字体应存在: " + FONT_PATH)
	if f == null:
		return
	var size: int = f.get_length()
	f.close()
	check(size <= MAX_FONT_BYTES,
		"字体应为子集（<= %d 字节），实际 %d 字节；重新运行 workflow/scripts/gf-font-subset.sh" % [MAX_FONT_BYTES, size])


func _collect(text: String, into: Dictionary) -> void:
	for i in range(text.length()):
		var c := text.unicode_at(i)
		if c > 0x1F:   # 跳过控制字符
			into[c] = true


# 只取字符串字面量：**注释与标识符永远不会被渲染**，不该逼迫字体去包含
# 它们里面的生僻符号（例如注释里的 ∘、—— 未必存在于 Noto Sans SC）。
const STRING_RE := "\"[^\"\n]*\"|'[^'\n]*'"


func _collect_strings(text: String, into: Dictionary) -> void:
	var re := RegEx.new()
	re.compile(STRING_RE)
	for m in re.search_all(text):
		_collect(m.get_string(), into)


func _read(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var t := f.get_as_text()
	f.close()
	return t


func _test_glyph_coverage() -> void:
	var font: Font = load(FONT_PATH)
	check(font != null, "字体应能作为 Font 资源加载")
	if font == null:
		return

	var chars: Dictionary = {}
	# 只扫描**会渲染成文字**的来源，必须与 workflow/scripts/gf-font-subset.sh 的
	# UI_SOURCES 一致。solver/tools/tests 是 headless 层，不会渲染文字，
	# 其字符串里的符号（如 ∘、✓）也未必在 Noto Sans SC 里，强行要求会误报。
	# core/ **必须**包含：它不画界面，但会提供显示用文案（如 shapes.gd 的形状名）。
	# 真实踩过：把形状名从 meta/ 搬进 core/ 后扫描范围没跟上 → 卡片上变豆腐块。
	for d in ["res://scenes", "res://meta", "res://core", "res://i18n"]:
		var dir := DirAccess.open(d)
		if dir == null:
			continue
		dir.list_dir_begin()
		var name := dir.get_next()
		while name != "":
			if name.ends_with(".gd") or name.ends_with(".tscn") or name.ends_with(".json"):
				_collect_strings(_read(d + "/" + name), chars)
			name = dir.get_next()
		dir.list_dir_end()
	_collect_strings(_read("res://project.godot"), chars)
	# 关卡 JSON 目前无文案，但一旦加上就应被覆盖，故一并扫描
	var lv_dir := DirAccess.open("res://levels")
	if lv_dir != null:
		lv_dir.list_dir_begin()
		var lf := lv_dir.get_next()
		while lf != "":
			if lf.ends_with(".json"):
				_collect(_read("res://levels/" + lf), chars)
			lf = lv_dir.get_next()
		lv_dir.list_dir_end()

	check(chars.size() > 100, "应扫描到足够多的字符（got %d）" % chars.size())

	var missing: Array = []
	for c in chars.keys():
		if not font.has_char(c):
			missing.append("%s(U+%04X)" % [char(c), c])
	check(missing.is_empty(),
		"以下字符在内置字体子集中缺字形，请重新运行 workflow/scripts/gf-font-subset.sh: " + ", ".join(missing))
	print("  扫描字符数: %d，缺字形: %d" % [chars.size(), missing.size()])
