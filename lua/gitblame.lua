local M = {}

local CURRENT_WINDOW_ID = 0

M.config = {
  hl_group = "GitBlame",
  date_format = "%Y-%m-%d %H:%M",
  format = " %a | %d | %m (%h)",
  max_msg_len = 50,
  delay_show_commit = 500,
  enabled = true, -- Enable/disable the plugin
}

local function has_git_repo()
  local current_dir = vim.fn.getcwd()
  local git_dir = vim.fn.finddir(".git", current_dir .. "/../.git")
  return git_dir ~= ""
end

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
    count = count + 1
    current = new_line + 1

    local commit = string.match(line, "^(%x+) %d+ %d+")
    local line_number = string.match(line, "^%x+ %d+ (%d+)")
    if commit and line_number then
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

      lines[index] = existing_commit

      goto continue
    end

    local author = string.match(line, "^author (.+)")
    if author then
      current_commit["author"] = author
      goto continue
    end

    local author_mail = string.match(line, "^author%-mail %<(.+)%>")
    if author_mail then
      current_commit["author_mail"] = author_mail
      goto continue
    end

    local author_time = string.match(line, "^author%-time (%d+)")
    if author_time then
      local date = os.date(M.config.date_format, tonumber(author_time))
      current_commit["author_time"] = date
      goto continue
    end

    local summary = string.match(line, "^summary (.+)")
    if summary then
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

  local gitblame_cache_entry = M.GitBlameCache[filepath]
  if gitblame_cache_entry == "in-progress" then
    return "processing"
  elseif gitblame_cache_entry ~= nil then
    return parse_blame_info(gitblame_cache_entry)
  end

  M.GitBlameCache[filepath] = "in-progress"
  -- Use vim.system (async) instead of io.popen for better handling
  vim.system(
    {"git", "blame", "--porcelain", filepath },
    { text = true },
    function (result)
      -- Return on non zero return codes (failure)
      if result.code ~= 0 then
        print("git blame failure: " .. (result.stderr or "unknown issue"))
        return
      end
      M.GitBlameCache[filepath] = result.stdout
      vim.schedule(function()
        vim.cmd("GitBlameClear")
        vim.cmd("GitBlameShow")
      end)
    end
  )

  return "processing"
end

M.GitBlameCache = {}
M.Cache = {}
local function cache_lookup(filepath, line_number)
  local entry = M.Cache[filepath]
  if not entry then
    entry = get_blame_info(filepath)
    if not entry then
      return nil
    elseif entry == "processing" then
      return "..."
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
  return formatted
end

local ns_id = nil

local function show_commit()
  vim.api.nvim_buf_clear_namespace(0, ns_id, 0, -1)

  -- Get cursor of current window
  local cursor = vim.api.nvim_win_get_cursor(CURRENT_WINDOW_ID)
  -- cursor = [row, col]
  local line_num = cursor[1]

  local filepath = vim.fn.expand("%:p")
  local commit = cache_lookup(filepath, line_num)

  local formatted_text
  if not commit then
    return
  elseif commit == "..." then
    formatted_text = commit
  else
    formatted_text = format_commit(commit)
  end
  vim.cmd("GitBlameWrite " .. formatted_text)
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

local function longest_line(lines)
  local longest = ""
  for _, line in ipairs(lines) do
    if #line > #longest then
      longest = line
    end
  end
  return longest
end

local function open_floating_window(lines, opts)
  opts = opts or {}

  local buf = vim.api.nvim_create_buf(false, true) -- scratch buffer
  vim.bo[buf].filetype = "gitshow"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  -- local width = opts.width or math.floor(vim.o.columns * 0.6)
  -- local height = opts.height or math.floor(vim.o.lines * 0.6)

  local width = #longest_line(lines)
  local height = #lines

  local win = vim.api.nvim_open_win(buf, false, {
    relative = "cursor",
    width = width,
    height = height,
    row = 1,
    col = 1,
    style = "minimal",
    focusable = false,
  })

  return buf, win
end

local floating_window = nil

local function make_gitblame_floating_window()
  -- Get cursor of current window
  local cursor = vim.api.nvim_win_get_cursor(CURRENT_WINDOW_ID)
  -- cursor = [row, col]
  local line_num = cursor[1]

  local filepath = vim.fn.expand("%:p")
  local commit = cache_lookup(filepath, line_num)

  if commit == "..." or commit == nil then
    print("No git blame information available for this line")
    return
  end

  vim.system(
    {"git", "show", "-s", "--format=full", commit.hash },
    { text = true},
    function(result)
      if result.code ~= 0 then
        print("git show failure: " .. (result.stderr or "unknown issue"))
        return
      end
      vim.schedule(function()
        local opts = { plain = true }
        local lines = vim.split(result.stdout, "\n", opts)
        _, floating_window =open_floating_window(lines, opts)
      end)
  end)
end

function M.setup(opts)
  -- Merge opts with config
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})

  ns_id = vim.api.nvim_create_namespace("GitBlame")
  if vim.fn.hlexists(M.config.hl_group) == 0 then
    vim.api.nvim_set_hl(0, M.config.hl_group, { fg = "#888888", italic = true })
  end

  -- Only enable autocmds if plugin is enabled and we're in a git repo
  local should_enable = M.config.enabled and has_git_repo()

  if not should_enable then
    return
  end

  local group = vim.api.nvim_create_augroup("GitBlame", { clear = true })

  vim.api.nvim_create_autocmd({ "CursorMoved" }, {
    group = group,
    callback = function()
      -- Clear commit if one exists on another line
      clear_commit()

      -- Start the timer for displaying a commit on the current line
      delay_show_commit()

      if floating_window ~= nil and vim.api.nvim_win_is_valid(floating_window) then
        vim.api.nvim_win_close(floating_window, true)
      end
    end
  })

  vim.api.nvim_create_autocmd({ "InsertEnter", "BufLeave" }, {
    group = group,
    callback = function()
      clear_commit()
    end
  })

  vim.api.nvim_create_autocmd({ "BufDelete" }, {
    group = group,
    callback = function()
      local filepath = vim.fn.expand("<afile>:p")
      M.Cache[filepath] = nil
    end
  })

  vim.api.nvim_create_user_command("GitBlameWrite", function(event)
    local buffer = event.args
    -- Get current buffer id 
    local buffer_ID = vim.api.nvim_get_current_buf()
    -- Get cursor of current window
    local cursor = vim.api.nvim_win_get_cursor(CURRENT_WINDOW_ID)
    -- cursor = [row, col]
    local line_num = cursor[1]

    vim.api.nvim_buf_set_extmark(buffer_ID, ns_id, line_num - 1, 0,
      { virt_text = { { buffer } },
      virt_text_pos = "eol",
    })
  end, {
    nargs = 1
  })

  vim.api.nvim_create_user_command("GitBlameShow", function()
    show_commit()
  end, {
    nargs = 0
  })

  vim.api.nvim_create_user_command("GitBlameOpenFloatingWindow", function()
    make_gitblame_floating_window()
  end, {
    nargs = 0
  })

  vim.api.nvim_create_user_command("GitBlameClear", function()
    clear_commit()
  end,{
    nargs = 0
  })

  -- Command to toggle plugin on/off
  vim.api.nvim_create_user_command("GitBlameToggle", function()
    M.config.enabled = not M.config.enabled
    vim.notify(
      ("Plugin %s (enabled: %s)"):format(
        M.config.enabled and "ENABLED" or "DISABLED",
        tostring(M.config.enabled)
      ),
      vim.log.levels.INFO
    )
  end, {
    nargs = 0
  })
end

return M
