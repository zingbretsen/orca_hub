
We should have a way to audit memory files from the agents. Claude stores its memories in ~/.claude/projects/<formatted-directory-name-with-all-hyphens>/memory/*md, which a MEMORY.md file that links out to other specific files in that directory.

I'm trying to understand where codex stores its memories. I think it might just put them directly in a local AGENTS.md file?

And maybe we can configure our ~/.pi to also load memories from the claude dir?
