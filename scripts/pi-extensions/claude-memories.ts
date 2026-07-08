/**
 * Claude Memories Extension
 *
 * Install: copy (or symlink) this file to ~/.pi/agent/extensions/claude-memories.ts
 * to enable it for all pi sessions.
 *
 * Surfaces Claude Code's per-project memory index (~/.claude/projects/<slug>/memory/MEMORY.md)
 * to pi sessions running in the same project directory, so agent-learned facts,
 * feedback, and project context aren't siloed to one CLI.
 *
 * Read-only: this extension never writes to the Claude memory directory.
 */

import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

/** Claude Code's project slug: cwd with every non-alphanumeric char replaced by "-". */
function claudeProjectSlug(cwd: string): string {
	return cwd.replace(/[^A-Za-z0-9]/g, "-");
}

export default function claudeMemoriesExtension(pi: ExtensionAPI) {
	pi.on("session_start", async (_event, ctx) => {
		const slug = claudeProjectSlug(ctx.cwd);
		const memoryDir = path.join(os.homedir(), ".claude", "projects", slug, "memory");
		const indexPath = path.join(memoryDir, "MEMORY.md");

		if (!fs.existsSync(indexPath)) {
			return;
		}

		let index: string;
		try {
			index = fs.readFileSync(indexPath, "utf-8");
		} catch {
			return;
		}

		if (!index.trim()) {
			return;
		}

		pi.sendMessage(
			{
				customType: "claude-memories",
				content: `Claude Code project memory index (full memory files live in ${memoryDir}; read them with the read tool when a line looks relevant):\n\n${index}`,
				display: false,
			},
			{ deliverAs: "nextTurn" },
		);
	});
}
