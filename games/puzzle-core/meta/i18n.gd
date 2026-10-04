# 中文源文本作为稳定消息键；增加 i18n/<locale>.json 即可扩展语言。
extends RefCounted

static var language := "zh"
static var catalogs: Dictionary = {}

static func supported() -> Array:
	var result: Array = ["zh"]
	var dir := DirAccess.open("res://i18n")
	if dir != null:
		for file in dir.get_files():
			if file.ends_with(".json"):
				result.append(file.get_basename())
	result.sort()
	return result

static func resolve(locale: String) -> String:
	var normalized := locale.replace("-", "_").to_lower()
	if supported().has(normalized):
		return normalized
	var base := normalized.get_slice("_", 0)
	return base if supported().has(base) else "en"

static func system_locale() -> String:
	var override := str(ProjectSettings.get_setting("puzzle/system_locale_override", ""))
	if override != "":
		return override
	if OS.has_feature("web"):
		return str(JavaScriptBridge.eval("navigator.language || 'en'", true))
	return OS.get_locale()

static func valid_preference(value: String) -> String:
	return value if value == "system" or supported().has(value) else "system"

static func configure(preference: String) -> void:
	language = resolve(system_locale() if valid_preference(preference) == "system" else preference)
	TranslationServer.set_locale(language)
	if OS.has_feature("web"):
		JavaScriptBridge.eval("try { localStorage.setItem('gf-language', %s); } catch (_) {} document.documentElement.lang = %s;" % [JSON.stringify(preference), JSON.stringify(language)], true)

static func t(source: String) -> String:
	if language == "zh":
		return source
	if not catalogs.has(language):
		var parsed = JSON.parse_string(FileAccess.get_file_as_string("res://i18n/%s.json" % language))
		catalogs[language] = parsed if parsed is Dictionary else {}
	# 新语种缺译时优先回退英文，再回退中文，不显示内部消息键。
	if (catalogs[language] as Dictionary).has(source):
		return str(catalogs[language][source])
	if language != "en":
		if not catalogs.has("en"):
			catalogs["en"] = JSON.parse_string(FileAccess.get_file_as_string("res://i18n/en.json"))
		return str(catalogs["en"].get(source, source))
	return source

static func preference_title(value: String) -> String:
	return t("跟随系统") if value == "system" else ("简体中文" if value == "zh" else "English" if value == "en" else value)

static func next_preference(value: String) -> String:
	var options: Array = ["system"] + supported()
	return options[(options.find(valid_preference(value)) + 1) % options.size()]
