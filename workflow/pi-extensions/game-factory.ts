/**
 * game-factory.ts — Pi 扩展：Game Factory 的调试斜杠命令。
 *
 * 命令（精简为日常调试所需）：
 *   /serve [game] [port]   启动/重启 Web 预览服务（后台 + 禁用缓存）
 *   /stop                  停止 Web 预览服务
 *   /shot  [game] [level]  关卡截图（需要显示环境）
 *   /test  [game]          运行该游戏的全部测试
 *   /games                 列出 games/ 下发现的游戏
 *
 * 复用与扩展：命令不绑定任何具体游戏，按以下顺序自动确定「当前游戏」：
 *   1) 命令里显式给出的 <game>
 *   2) 当前工作目录所在的 games/<name>/
 *   3) 若 games/ 下只有一个游戏，就用它
 * 新增游戏只需在 games/<name>/ 放好 project.godot / tests / export_presets.cfg，
 * 这些命令立即生效，无需改动本扩展。
 *
 * 安装：把本文件复制到 pi 扩展目录，然后 /reload
 *   Windows: C:\Users\<你>\.pi\agent\extensions\
 *   WSL/Linux: ~/.pi/agent/extensions/
 */
import { existsSync, readdirSync } from "node:fs";
import { dirname, join, resolve, sep } from "node:path";
import type { ExtensionAPI, ExtensionCommandContext } from "@earendil-works/pi-coding-agent";

/** 从 ctx.cwd 向上查找仓库根（含 workflow/scripts/gf-test.sh）。 */
function findRepoRoot(start: string): string | null {
	let dir = start || ".";
	for (let i = 0; i < 12; i++) {
		try {
			if (existsSync(join(dir, "workflow", "scripts", "gf-test.sh"))) return dir;
		} catch {
			/* ignore */
		}
		const parent = dirname(dir);
		if (!parent || parent === dir) break;
		dir = parent;
	}
	return null;
}

/** 把 Windows 路径转成 shell(/mnt) 路径；已是 POSIX 路径则原样返回。 */
function toShPath(p: string): string {
	const m = /^([A-Za-z]):[\\/](.*)$/.exec(p);
	if (m) return "/mnt/" + m[1].toLowerCase() + "/" + m[2].replace(/\\/g, "/");
	return p.replace(/\\/g, "/");
}

/** 列出 games/ 下所有游戏（含 project.godot 的目录）。 */
function listGames(root: string): string[] {
	const dir = join(root, "games");
	if (!existsSync(dir)) return [];
	try {
		return readdirSync(dir, { withFileTypes: true })
			.filter((e) => e.isDirectory() && existsSync(join(dir, e.name, "project.godot")))
			.map((e) => e.name)
			.sort();
	} catch {
		return [];
	}
}

/** 自动判定当前游戏：cwd 落在某个 games/<name>/ 下则用它，否则唯一游戏则用它。 */
function detectGame(root: string, cwd: string): string | null {
	const games = listGames(root);
	const rootAbs = resolve(root);
	const cwdAbs = resolve(cwd || root);
	for (const g of games) {
		const gp = resolve(join(rootAbs, "games", g));
		if (cwdAbs === gp || cwdAbs.startsWith(gp + sep)) return g;
	}
	return games.length === 1 ? games[0] : null;
}

export default function gameFactory(pi: ExtensionAPI) {
	let repoRoot = findRepoRoot(process.cwd());
	pi.on("session_start", (_event, ctx) => {
		repoRoot = findRepoRoot(ctx.cwd);
	});

	function gameCompletions(prefix: string) {
		const games = repoRoot ? listGames(repoRoot) : [];
		const f = games.filter((g) => g.startsWith(prefix));
		return f.length ? f.map((v) => ({ value: v, label: v })) : null;
	}

	async function sh(ctx: ExtensionCommandContext, commandLine: string, timeoutMs = 300000) {
		const root = findRepoRoot(ctx.cwd);
		if (!root) {
			const msg = "未找到 Game Factory 仓库（需要 workflow/scripts/gf-test.sh）。请在仓库目录内使用。";
			ctx.ui.notify("❌ " + msg, "error");
			return { stdout: "", stderr: msg, code: 127, killed: false };
		}
		return pi.exec("bash", ["-c", "cd '" + toShPath(root) + "' && " + commandLine], { timeout: timeoutMs });
	}

	/** 解析游戏参数：显式 <game> → cwd 所在游戏 → 唯一游戏；失败则提示可用列表。 */
	function pickGame(ctx: ExtensionCommandContext, arg: string): string | null {
		const root = findRepoRoot(ctx.cwd);
		if (!root) {
			ctx.ui.notify("❌ 未找到 Game Factory 仓库。", "error");
			return null;
		}
		const games = listGames(root);
		if (arg && games.includes(arg)) return arg;
		const auto = detectGame(root, ctx.cwd);
		if (auto) return auto;
		ctx.ui.notify(
			"❌ 无法确定游戏。可用: " + (games.join(", ") || "(未发现)") + "\n用法: /serve <game> [port]",
			"error",
		);
		return null;
	}

	function report(ctx: ExtensionCommandContext, title: string, res: { stdout: string; stderr: string; code: number }) {
		const ok = res.code === 0;
		let text = (res.stdout || "").trim() || (res.stderr || "").trim();
		const lines = text.split("\n");
		if (lines.length > 20) text = lines.slice(-20).join("\n");
		if (text.length > 1600) text = text.slice(-1600);
		ctx.ui.notify((ok ? "✅ " : "❌ ") + title + "  (exit " + res.code + ")\n" + text, ok ? "info" : "error");
	}

	// ── /serve：启动或重启预览服务 ──────────────────────────────
	pi.registerCommand("serve", {
		description: "启动/重启当前游戏的 Web 预览服务（后台 + 禁用缓存）",
		getArgumentCompletions: (prefix) => gameCompletions(prefix),
		handler: async (args, ctx) => {
			const parts = (args || "").trim().split(/\s+/).filter(Boolean);
			let game = "";
			let port = "";
			for (const p of parts) {
				if (/^\d+$/.test(p) && !port) port = p;
				else if (!game) game = p;
			}
			const picked = pickGame(ctx, game);
			if (!picked) return;
			port = port || "8000";
			await sh(ctx, "pkill -f serve_nocache 2>/dev/null; sleep 1; true", 20000);
			const res = await sh(
				ctx,
				"nohup ./workflow/scripts/gf-serve.sh games/" +
					picked +
					" " +
					port +
					" > /tmp/gf-serve.log 2>&1 & sleep 2; tail -n 5 /tmp/gf-serve.log",
				30000,
			);
			ctx.ui.setStatus("serve", "▶ " + picked + " :" + port);
			ctx.ui.notify(
				"✅ 预览已启动：" + picked + "\nhttp://localhost:" + port + "\n\n" + (res.stdout || "").trim(),
				"info",
			);
		},
	});

	// ── /stop：停止预览服务 ────────────────────────────────────
	pi.registerCommand("stop", {
		description: "停止 Web 预览服务",
		handler: async (_args, ctx) => {
			const res = await sh(
				ctx,
				"pkill -f serve_nocache 2>/dev/null; sleep 0.5; ss -ltn 2>/dev/null | grep -q ':8000' && echo '8000 仍在监听' || echo '已停止'",
				20000,
			);
			ctx.ui.setStatus("serve", undefined);
			report(ctx, "stop", res);
		},
	});

	// ── /shot：关卡截图 ────────────────────────────────────────
	pi.registerCommand("shot", {
		description: "关卡截图（需要显示环境，如 WSLg）",
		getArgumentCompletions: (prefix) => gameCompletions(prefix),
		handler: async (args, ctx) => {
			const root = findRepoRoot(ctx.cwd);
			const games = root ? listGames(root) : [];
			let game = "";
			let level = "";
			for (const p of (args || "").trim().split(/\s+/).filter(Boolean)) {
				if (!game && games.includes(p)) game = p;
				else level = p;
			}
			const picked = pickGame(ctx, game);
			if (!picked) return;
			level = level || "res://levels/level_01.json";
			report(
				ctx,
				"shot (" + picked + ")",
				await sh(ctx, "./workflow/scripts/gf-shot.sh games/" + picked + " " + level, 120000),
			);
		},
	});

	// ── /test：运行测试 ────────────────────────────────────────
	pi.registerCommand("test", {
		description: "运行当前游戏的全部测试",
		getArgumentCompletions: (prefix) => gameCompletions(prefix),
		handler: async (args, ctx) => {
			const picked = pickGame(ctx, (args || "").trim());
			if (!picked) return;
			ctx.ui.notify("⏳ 运行 " + picked + " 测试中…", "info");
			report(ctx, "test (" + picked + ")", await sh(ctx, "./workflow/scripts/gf-test.sh games/" + picked));
		},
	});

	// ── /games：列出游戏 ───────────────────────────────────────
	pi.registerCommand("games", {
		description: "列出 games/ 下发现的游戏",
		handler: async (_args, ctx) => {
			const root = findRepoRoot(ctx.cwd);
			if (!root) {
				ctx.ui.notify("❌ 未找到 Game Factory 仓库。", "error");
				return;
			}
			const games = listGames(root);
			const active = detectGame(root, ctx.cwd);
			const body = games.length
				? games.map((g) => (g === active ? "▶ " : "   ") + g).join("\n") +
					"\n\n（▶ = 当前；切换：/serve <game> 或 /test <game>）"
				: "games/ 下未发现游戏";
			ctx.ui.notify(body, "info");
		},
	});
}
