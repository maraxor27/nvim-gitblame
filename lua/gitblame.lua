local M = {}

local CURRENT_WINDOW_ID = 0

M.config = {
  hl_group = "GitBlame",
  date_format = "%Y-%m-%d %H:%M",
  format = " %a | %d | %m (%h)",
  max_msg_len = 50,
  delay_show_commit = 500,
}

local function parse_blame_info(output)
  local lines = {}
  local blame_info = {}

  local count = 0
  local current = 0
  local current_commit = nil

  while true do
    local new_line = string.find(output, "\n", current)

    if not new_line then
      break
    end

    local line = string.sub(output, current, new_line - 1)
    -- print(string.format("line %d: \"%s\"", count, line))
    count = count + 1
    current = new_line + 1

    local commit = string.match(line, "^(%x+) %d+ %d+")
    local line_number = string.match(line, "^%x+ %d+ (%d+)")
    if commit and line_number then
      -- print(string.format("commit: %s @ %s", commit, line_number))

      local existing_commit = blame_info[commit]

      if not existing_commit then
        existing_commit = {}
        existing_commit["hash"] = commit
        blame_info[commit] = existing_commit
      end

      current_commit = existing_commit

      local index = tonumber(line_number)
      if not index then
        error(line_number .. " is not a valid number")
      end

      -- vim.cmd.echo(string.format('"Adding commit %s to %d"', existing_commit.hash, line_number))
      lines[index] = existing_commit

      goto continue
    end

    local author = string.match(line, "^author (.+)")
    if author then
      -- print(string.format("author: \"%s\"", author))
      current_commit["author"] = author
      goto continue
    end

    local author_mail = string.match(line, "^author%-mail %<(.+)%>")
    if author_mail then
      -- print(string.format("author-mail: \"%s\"", author_mail))
      current_commit["author_mail"] = author_mail
      goto continue
    end

    local author_time = string.match(line, "^author%-time (%d+)")
    if author_time then
      local date = os.date(M.config.date_format, tonumber(author_time))
      -- print(string.format("author_time: \"%s\"", date))
      current_commit["author_time"] = date
      goto continue
    end

    local summary = string.match(line, "^summary (.+)")
    if summary then
      -- print(string.format("summary: \"%s\"", summary))
      current_commit["summary"] = summary
      goto continue
    end
    ::continue::
  end
  return lines
end

local function get_blame_info(filepath)
  -- It is important to handle filepath being an empty string, because this case occurs with telescope :(
  if filepath == "" then
    return nil
  end

  local handle = io.popen(string.format("git blame --porcelain %s", filepath))
  if not handle then
    return nil
  end

  local output = handle:read("*a")
  -- vim.cmd.echo(string.format('"output: %s"', output))
  return parse_blame_info(output)
end

M.Cache = {}
local function cache_lookup(filepath, line_number)
  local entry = M.Cache[filepath]
  if not entry then
    -- vim.cmd.echo(string.format('"cache miss: %s:%d"', filepath, line_number))
    entry = get_blame_info(filepath)
    if not entry then
      return nil
    end
    M.Cache[filepath] = entry
  else
    -- vim.cmd.echo(string.format('"cache hit: %s:%d"', filepath, line_number))
  end
  return entry[line_number]
end

local function format_commit(commit)
  if not commit then
    return ""
  end

  local msg = commit.summary or ""
  if #msg > M.config.max_msg_len then
    msg = string.sub(msg, 1, M.config.max_msg_len) .. "..."
  end

  local formatted = M.config.format
  formatted = formatted:gsub("%%a", commit.author or "Unknown")
  formatted = formatted:gsub("%%d", commit.author_time or "")
  formatted = formatted:gsub("%%m", msg)
  formatted = formatted:gsub("%%h", commit.hash and string.sub(commit.hash, 1, 7) or "")
  -- print(formatted)
  return formatted
end

-- Function to get git directory
local function get_git_dir()
  local handle = io.popen("git rev-parse --show-toplevel 2>/dev/null")
  if not handle then
    return nil
  end

  local git_dir = handle:read("*a"):gsub("%s+$", "")
  handle:close()

  if git_dir == "" then
    return nil
  end

  return git_dir
end

-- get_blame_info("~/repos/v8/v8/src/objects/js-array.tq")
--
local ns_id = nil

local function show_commit()
  vim.api.nvim_buf_clear_namespace(0, ns_id, 0, -1)

  -- Get current buffer id
  local buffer_ID = vim.api.nvim_get_current_buf()
  -- Get cursor of current window
  local cursor = vim.api.nvim_win_get_cursor(CURRENT_WINDOW_ID)
  -- cursor = [row, col]
  local line_num = cursor[1]

  local filepath = vim.fn.expand("%:p")
  local commit = cache_lookup(filepath, line_num)
  if not commit then
    -- vim.cmd.echo('"Couldn\'t find commit information"')
    return
  end
  local formatted_text = format_commit(commit)
  -- vim.cmd.echo(string.format('"blame: %s"', formatted_text))

  vim.api.nvim_buf_set_virtual_text(buffer_ID, ns_id, line_num - 1, { { formatted_text, M.config.hl_group } }, {})
end

local auto_timer = nil
local function delay_show_commit()
  if auto_timer then
    vim.loop.timer_stop(auto_timer)
  end

  auto_timer = vim.defer_fn(function()
    show_commit()
    auto_timer = nil
  end, M.config.delay_show_commit)
end

local function clear_commit()
  vim.api.nvim_buf_clear_namespace(0, ns_id, 0, -1)
end

function M.setup(opts)
  -- Merge opts with config
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})

  ns_id = vim.api.nvim_create_namespace("GitBlame")
  if vim.fn.hlexists(M.config.hl_group) == 0 then
    vim.api.nvim_set_hl(0, M.config.hl_group, { fg = "#888888", italic = true })
  end

  -- vim.api.nvim.create_user_command("GitBlameShow", TODO, {})

  local group = vim.api.nvim_create_augroup("GitBlame", { clear = true })

  vim.api.nvim_create_autocmd({ "CursorMoved" }, {
    group = group,
    callback = function()
      -- Clear commit if one exists on another line
      clear_commit()

      -- Start the timer for displaying a commit on the current line
      delay_show_commit()
    end
  })

  vim.api.nvim_create_autocmd({ "InsertEnter", "BufLeave" }, {
    group = group,
    callback = function()
      vim.api.nvim_buf_clear_namespace(0, ns_id, 0, -1)
    end
  })

  vim.api.nvim_create_autocmd({ "BufReadPost" }, {
    group = group,
    callback = function()
      local filepath = vim.fn.expand("%:p")
      -- cache_lookup(filepath, 1)
    end
  })

  vim.api.nvim_create_autocmd({ "BufDelete" }, {
    group = group,
    callback = function()
      local filepath = vim.fn.expand("<afile>:p")
      M.Cache[filepath] = nil
    end
  })
end

return M
