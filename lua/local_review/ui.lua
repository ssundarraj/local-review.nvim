local M = {}

local comments = require("local_review.comments")

local namespace = vim.api.nvim_create_namespace("local-review-ui")
local placeholder_namespace = vim.api.nvim_create_namespace("local-review-ui-placeholder")
local placeholder_text = "Write a review comment..."

local state = {
  editor_bufnr = nil,
  editor_winid = nil,
  source_bufnr = nil,
  source_winid = nil,
  source_line = nil,
  source_line_start = nil,
  pending_range = nil,
  anchor_row = nil,
  extmark_id = nil,
  initial_body = "",
  reserved_height = 0,
  closing = false,
}

local function is_valid_buffer(bufnr)
  return bufnr ~= nil and vim.api.nvim_buf_is_valid(bufnr)
end

local function is_valid_window(winid)
  return winid ~= nil and vim.api.nvim_win_is_valid(winid)
end

local function is_open()
  return is_valid_buffer(state.editor_bufnr) and is_valid_window(state.editor_winid)
end

local function body_lines(body)
  local text = body or ""
  if text == "" then
    return { "" }
  end
  return vim.split(text, "\n", { plain = true })
end

local function editor_buffer_name(source_bufnr, start_line, end_line)
  local source_name = vim.api.nvim_buf_get_name(source_bufnr)
  if source_name == "" then
    source_name = string.format("buffer-%d", source_bufnr)
  end

  if end_line > start_line then
    return string.format("local-review://comment/%s:%d-%d", source_name, start_line, end_line)
  end
  return string.format("local-review://comment/%s:%d", source_name, start_line)
end

local function strip_editor_padding(line)
  return line:gsub("^ ", "", 1)
end

local function current_body()
  if not is_valid_buffer(state.editor_bufnr) then
    return ""
  end

  local lines = vim.api.nvim_buf_get_lines(state.editor_bufnr, 0, -1, false)
  local stripped = {}
  for _, line in ipairs(lines) do
    stripped[#stripped + 1] = strip_editor_padding(line)
  end
  return vim.trim(table.concat(stripped, "\n"))
end

local function pad_editor_lines(lines)
  local padded = {}
  for _, line in ipairs(lines) do
    if line ~= "" and not line:match("^ ") then
      padded[#padded + 1] = " " .. line
    else
      padded[#padded + 1] = line
    end
  end
  return padded
end

local function is_dirty()
  return current_body() ~= vim.trim(state.initial_body or "")
end

local function update_placeholder(bufnr)
  if not is_valid_buffer(bufnr) then
    return
  end

  vim.api.nvim_buf_clear_namespace(bufnr, placeholder_namespace, 0, -1)

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local has_content = vim.trim(table.concat(lines, "\n")) ~= ""
  if has_content then
    return
  end

  local first = lines[1] or ""
  local col = first:match("^%s*$") and vim.fn.strchars(first) or 0

  vim.api.nvim_buf_set_extmark(bufnr, placeholder_namespace, 0, col, {
    virt_text = { { placeholder_text, "Comment" } },
    virt_text_pos = "overlay",
    hl_mode = "combine",
  })
end

local function clear_inline_space()
  if is_valid_buffer(state.source_bufnr) and state.extmark_id ~= nil then
    pcall(vim.api.nvim_buf_del_extmark, state.source_bufnr, namespace, state.extmark_id)
  end
  state.extmark_id = nil
end

local function cleanup()
  clear_inline_space()
  state.editor_bufnr = nil
  state.editor_winid = nil
  state.source_bufnr = nil
  state.source_winid = nil
  state.source_line = nil
  state.source_line_start = nil
  state.anchor_row = nil
  state.initial_body = ""
  state.reserved_height = 0
  state.closing = false
end

local function close_window()
  if is_valid_window(state.editor_winid) then
    pcall(vim.api.nvim_win_close, state.editor_winid, true)
  end
  cleanup()
end

local function persist(opts)
  if state.source_bufnr == nil or state.source_line == nil then
    return true
  end

  local notify_result = not (opts and opts.silent)
  local result, err = comments.set_line_comment(state.source_bufnr, state.source_line, current_body(), {
    start_line = state.source_line_start or state.source_line,
    end_line = state.source_line,
  })
  if not result then
    vim.notify(err or "Failed to save the review comment.", vim.log.levels.ERROR)
    return false
  end

  if notify_result and result == "created" then
    vim.notify("Review comment added.", vim.log.levels.INFO)
  elseif notify_result and result == "updated" then
    vim.notify("Review comment updated.", vim.log.levels.INFO)
  elseif notify_result and result == "deleted" then
    vim.notify("Review comment deleted.", vim.log.levels.INFO)
  end

  state.initial_body = current_body()
  if is_valid_buffer(state.editor_bufnr) then
    vim.bo[state.editor_bufnr].modified = false
  end
  return true
end

function M.close_active()
  if not is_open() then
    cleanup()
    return true
  end

  if is_dirty() and not persist({ silent = true }) then
    return false
  end

  state.closing = true
  local source_bufnr = state.source_bufnr
  close_window()
  require("local_review.markers").refresh(source_bufnr)
  return true
end

function M.save_active()
  if not is_open() then
    return
  end

  persist()
end

local function text_column_offset(winid)
  return vim.fn.getwininfo(winid)[1].textoff
end

--- Height of the editable content: lines up to the last non-blank line,
--- keeping at least the line the cursor is on so the box never hides it.
local function content_height(lines)
  local last_non_blank = 1
  for index, line in ipairs(lines) do
    if line:match("%S") then
      last_non_blank = index
    end
  end

  local cursor_line = 1
  if is_valid_window(state.editor_winid) then
    cursor_line = vim.api.nvim_win_get_cursor(state.editor_winid)[1]
  end
  return math.max(1, last_non_blank, cursor_line)
end

-- The persisted comment box (markers.lua) draws its border inside the
-- virtual lines, so its total width is the available text width. The editor
-- float draws its border around the text area, so the text area must be 2
-- cells narrower for both boxes to have the same footprint.
local border_width = 2

local function inline_dimensions(lines, source_winid, anchor_row)
  local win_width = vim.api.nvim_win_get_width(source_winid)
  local text_offset = text_column_offset(source_winid)
  local width = math.max(1, win_width - text_offset - border_width)

  local row = anchor_row or (vim.fn.winline() + 1)
  local available_height = math.max(6, vim.api.nvim_win_get_height(source_winid) - row - 1)
  local height = math.min(math.max(1, content_height(lines)), available_height)

  return {
    width = width,
    height = height,
  }
end

local function reserve_inline_space(bufnr, line, height)
  local virt_lines = {}
  for _ = 1, height do
    virt_lines[#virt_lines + 1] = { { " ", "Normal" } }
  end

  state.extmark_id = vim.api.nvim_buf_set_extmark(bufnr, namespace, line - 1, 0, {
    virt_lines = virt_lines,
    virt_lines_leftcol = true,
    hl_mode = "combine",
  })
  state.reserved_height = height
end

local function inline_column(source_winid)
  return text_column_offset(source_winid)
end

--- Row of the global tabline, which window-position APIs do not account for.
local function tabline_height()
  local showtabline = vim.o.showtabline
  if showtabline == 2 or (showtabline == 1 and #vim.api.nvim_list_tabpages() > 1) then
    return 1
  end
  return 0
end

--- A winbar occupies one row at the top of the window's grid area.
local function winbar_height(winid)
  return vim.wo[winid].winbar ~= "" and 1 or 0
end

--- Position the editor float and correct for environment-specific drift.
--- Some setups (custom statuscolumns, experimental UIs) render a float a few
--- cells away from its configured position; compare the rendered position
--- against the intended one and compensate once.
---
--- Coordinate spaces: nvim_win_get_position() returns the source window's
--- 0-based origin relative to the first window row (it ignores the tabline),
--- while win_screenpos() returns the float's 1-based position on the
--- absolute screen grid (tabline included).
local function place_editor(winid, cfg)
  vim.api.nvim_win_set_config(winid, cfg)

  if not is_valid_window(state.source_winid) or not is_valid_window(winid) then
    return
  end

  local ok, source_origin = pcall(vim.api.nvim_win_get_position, state.source_winid)
  if not ok then
    return
  end

  local actual_pos = vim.fn.win_screenpos(winid)
  if actual_pos[1] == 0 then
    return
  end

  local drift_row = (source_origin[1] + tabline_height() + winbar_height(state.source_winid) + 1 + cfg.row)
    - actual_pos[1]
  local drift_col = (source_origin[2] + 1 + cfg.col) - actual_pos[2]
  if drift_row ~= 0 or drift_col ~= 0 then
    vim.api.nvim_win_set_config(
      winid,
      vim.tbl_extend("force", cfg, { row = cfg.row + drift_row, col = cfg.col + drift_col })
    )
  end
end

local function update_layout()
  if not is_open() or not is_valid_window(state.source_winid) or state.source_line == nil then
    return
  end

  local size = inline_dimensions(
    vim.api.nvim_buf_get_lines(state.editor_bufnr, 0, -1, false),
    state.source_winid,
    state.anchor_row
  )
  local reserved_height = size.height + 2

  clear_inline_space()
  reserve_inline_space(state.source_bufnr, state.source_line, reserved_height)

  place_editor(state.editor_winid, {
    relative = "win",
    win = state.source_winid,
    row = state.anchor_row or vim.fn.winline(),
    col = inline_column(state.source_winid),
    width = size.width,
    height = size.height,
  })
end

local function set_editor_keymaps(bufnr)
  local function map(modes, lhs, rhs, desc)
    if lhs == nil or lhs == "" then
      return
    end

    vim.keymap.set(modes, lhs, rhs, { buffer = bufnr, silent = true, nowait = true, desc = desc })
  end

  local opts = require("local_review").get_opts()
  for _, keymap in ipairs(opts.comment_close_keys or {}) do
    map(keymap.modes, keymap.key, function()
      M.close_active()
    end, "Local Review: Close")
  end

  -- The box's left padding is a real space in the buffer. Swallow <BS>/<Del>
  -- when they would delete it so the padding (and the placeholder position)
  -- stays put.
  local function padded_delete(key, deletes_first_char)
    return function()
      local col = vim.api.nvim_win_get_cursor(0)[2]
      local first = vim.api.nvim_get_current_line():sub(1, 1)
      if first == " " and deletes_first_char(col) then
        return ""
      end
      return key
    end
  end

  vim.keymap.set(
    "i",
    "<BS>",
    padded_delete("<BS>", function(col)
      return col == 1
    end),
    { buffer = bufnr, expr = true, desc = "Local Review: Backspace" }
  )
  vim.keymap.set(
    "i",
    "<Del>",
    padded_delete("<Del>", function(col)
      return col == 0
    end),
    { buffer = bufnr, expr = true, desc = "Local Review: Delete" }
  )

  -- Keep the cursor out of the left padding cell.
  vim.keymap.set("i", "<Left>", function()
    return vim.api.nvim_win_get_cursor(0)[2] <= 1 and "" or "<Left>"
  end, { buffer = bufnr, expr = true, desc = "Local Review: Left" })

  -- <CR> accepts the comment; <S-CR> inserts a newline.
  vim.keymap.set({ "n", "i" }, "<CR>", function()
    if M.close_active() then
      vim.cmd("stopinsert")
    end
  end, { buffer = bufnr, silent = true, desc = "Local Review: Accept" })
  vim.keymap.set("i", "<S-CR>", function()
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, true, true), "ni", false)
    return ""
  end, { buffer = bufnr, expr = true, desc = "Local Review: Newline" })
end

local function attach_editor_autocmds(bufnr, winid)
  local group = vim.api.nvim_create_augroup("local-review-inline-" .. bufnr, { clear = true })

  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "InsertLeave", "BufEnter" }, {
    group = group,
    buffer = bufnr,
    callback = function()
      update_placeholder(bufnr)
      update_layout()
    end,
  })

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    group = group,
    buffer = bufnr,
    callback = function()
      persist()
      update_placeholder(bufnr)
      update_layout()
    end,
  })

  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    callback = function(event)
      if tonumber(event.match) ~= winid then
        return
      end

      if state.closing then
        cleanup()
        return
      end

      vim.schedule(function()
        M.close_active()
      end)
    end,
  })

  vim.api.nvim_create_autocmd("WinLeave", {
    group = group,
    callback = function()
      if not is_valid_window(winid) or vim.api.nvim_get_current_win() ~= winid or state.closing then
        return
      end

      vim.schedule(function()
        M.close_active()
      end)
    end,
  })
end

function M.set_pending_range(start_line, end_line)
  state.pending_range = { start_line, end_line }
end

function M.open_current_line(range)
  if not M.close_active() then
    return
  end

  local source_bufnr = vim.api.nvim_get_current_buf()
  local source_winid = vim.api.nvim_get_current_win()

  local selected = range or state.pending_range
  state.pending_range = nil

  local cursor_line = vim.api.nvim_win_get_cursor(source_winid)[1]
  local start_line, end_line = cursor_line, cursor_line
  if selected then
    start_line = math.min(selected[1], selected[2])
    end_line = math.max(selected[1], selected[2])
  end

  local line_state = comments.get_line_state(source_bufnr, start_line)
  if not line_state then
    return
  end

  -- Editing an existing comment always covers its full stored range.
  if line_state.comment then
    start_line = line_state.comment.anchor.line_number
    end_line = math.max(start_line, line_state.comment.line_end or start_line)
  end

  -- Anchor the editor below the last line of the range, where the persisted
  -- comment box will be drawn once the editor closes.
  local max_line = math.max(vim.api.nvim_buf_line_count(source_bufnr), 1)
  end_line = math.max(1, math.min(end_line, max_line))
  start_line = math.max(1, math.min(start_line, end_line))
  vim.api.nvim_win_set_cursor(source_winid, { end_line, 0 })

  local source_line = end_line
  local lines = body_lines(line_state.comment and line_state.comment.body or "")
  local title = " Review Comment "
  if end_line > start_line then
    title = string.format(" Review Comment %d-%d ", start_line, end_line)
  end
  if line_state.comment and line_state.comment.stale then
    title = title:gsub(" $", " [stale] ")
  end
  local size = inline_dimensions(lines, source_winid, state.anchor_row)
  local bufnr = vim.api.nvim_create_buf(false, true)

  vim.bo[bufnr].buftype = "acwrite"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].modifiable = true
  vim.bo[bufnr].filetype = "markdown"
  vim.api.nvim_buf_set_name(bufnr, editor_buffer_name(source_bufnr, start_line, end_line))

  if #lines == 1 and lines[1] == "" then
    lines[1] = " "
  end
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, pad_editor_lines(lines))

  state.editor_bufnr = bufnr
  state.source_bufnr = source_bufnr
  state.source_winid = source_winid
  state.source_line = source_line
  state.source_line_start = start_line
  state.anchor_row = vim.fn.winline()
  state.initial_body = table.concat(lines, "\n")
  state.reserved_height = 0
  state.closing = false

  size = inline_dimensions(lines, source_winid, state.anchor_row)
  reserve_inline_space(source_bufnr, source_line, size.height + 2)

  local winid = vim.api.nvim_open_win(bufnr, true, {
    relative = "win",
    win = source_winid,
    row = state.anchor_row,
    col = inline_column(source_winid),
    width = size.width,
    height = size.height,
    style = "minimal",
    border = { "┌", "─", "┐", "│", "┘", "─", "└", "│" },
    title = title,
    title_pos = "left",
    noautocmd = true,
  })

  state.editor_winid = winid
  place_editor(winid, vim.api.nvim_win_get_config(winid))

  -- Hide the persisted box for the line being edited; it is drawn again by
  -- the refresh in M.close_active().
  require("local_review.markers").refresh(source_bufnr)

  vim.wo[winid].wrap = true
  vim.wo[winid].linebreak = true
  vim.wo[winid].number = false
  vim.wo[winid].relativenumber = false
  vim.wo[winid].signcolumn = "no"
  vim.wo[winid].winhighlight = "Normal:NormalFloat,FloatBorder:FloatBorder,FloatTitle:LocalReviewEditorTitle"
  vim.bo[bufnr].autoindent = true

  set_editor_keymaps(bufnr)
  attach_editor_autocmds(bufnr, winid)
  update_placeholder(bufnr)
  if line_state.comment and line_state.comment.stale then
    vim.notify("This review comment is stale and may no longer point at the original code.", vim.log.levels.WARN)
  end

  vim.schedule(function()
    if is_open() then
      update_layout()
    end
  end)

  vim.cmd("startinsert!")
end

function M.active_source_line(bufnr)
  if is_open() and state.source_bufnr == bufnr then
    return state.source_line
  end
  return nil
end

return M
