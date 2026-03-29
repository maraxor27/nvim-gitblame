# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Gitblame Extension Overview

`gitblame.lua` is a Neovim extension that displays git blame annotations on hover. It shows who wrote each line of code, when, and with what commit message.

## Architecture

### Main Module (`lua/gitblame.lua`)
- **Exports**: `M.setup(opts)` - main setup function
- **Namespace ID**: Stored for virtual text operations
- **Buffer Cache**: Per-file cache keyed by filepath (cleared on BufDelete)

### Key Data Structures
```lua
M.config = {  -- Configuration table
  hl_group = "GitBlame",
  date_format = "%Y-%m-%d %H:%M",
  format = " %a | %d | %m (%h)",
  max_msg_len = 50,
  delay_show_commit = 500,
}

M.Cache = {}  -- filepath -> table of commit info keyed by line number
```

### Git Blame Parsing (`parse_blame_info`)
Parses `git blame --porcelain` output line-by-line, extracting:
- Commit hash (first line per code line)
- Line number in file
- Author name (`author <name>`)
- Author email (`author-mail <email>`)
- Timestamp (`author-time <seconds>`)
- Summary message (`summary <message>`)

Stores data in nested structure: `lines[line_num] = { hash, author, author_time, summary }`

### Virtual Text Display (`show_commit`)
- Gets current buffer and cursor position via API
- Calls `cache_lookup(filepath, line_num)` to get commit info
- Calls `format_commit()` to apply configured format string
- Renders as virtual text in namespace `GitBlame`

## Autocmds Setup

| Trigger | Behavior |
|---------|----------|
| `CursorMoved` | Clear previous line's display; start 500ms timer for current line |
| `InsertEnter`, `BufLeave` | Clear all virtual text (no hover in insert mode) |
| `BufReadPost` | Loaded file (currently unused - cache_lookup not called) |
| `BufDelete` | Remove from cache to save memory |

## Format String Substitutions
```lua
format = " %a | %d | %m (%h)"
-- %a -> author name
-- %d -> date (from date_format: "%Y-%m-%d %H:%M")
-- %m -> commit summary (truncated to max_msg_len)
-- %h -> first 7 chars of commit hash
```

## Usage

Add to Neovim `init.lua`:
```lua
require("gitblame").setup({
  hl_group = "GitBlame",          -- Highlight group name
  date_format = "%Y-%m-%d %H:%M", -- Timestamp format for author-time
  format = " %a | %d | %m (%h)",  -- Display format string
  max_msg_len = 50,                -- Truncate commit messages
  delay_show_commit = 500,         -- ms delay before showing commit info
})
```

## Recent Changes (Git History)
- `23ae2a3`: Fixed telescope integration (handles empty filepath in get_blame_info)
- `f5f2e21`: Restructured for lazy.nvim compatibility
- `87158c9`: Hooked into CursorMove with delay

## Common Development Tasks

### Running Tests
`nvim -E 'set runtimepath+=./' --headless -c "source lua/gitblame.lua" -c "qa"`

### Testing in Neovim
```lua
-- Add to init.lua
vim.cmd([[ packadd nvim-web-devicons ]])  -- or similar for hl_group testing
require("gitblame").setup()
```

### Adding New Features
1. Update `M.config` defaults if adding new options
2. Create namespace (`nvim_create_namespace`) before use
3. Define highlight group with `nvim_set_hl` (0 = global scope)
4. Use `nvim_buf_set_virtual_text` for hover display
5. Clean up virtual text on leave/insert modes

### Cache Management Notes
- Cache is keyed by filepath (`vim.fn.expand("%:p")`)
- Clear cache on BufDelete to prevent memory leaks
- Handle empty filepath (telescope edge case) with early return

## Highlight Groups
Created automatically via `nvim_set_hl`:
```lua
vim.api.nvim_set_hl(0, M.config.hl_group, { fg = "#888888", italic = true })
```
