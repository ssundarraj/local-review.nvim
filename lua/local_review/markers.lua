local M = {}

local namespace = vim.api.nvim_create_namespace("local-review-markers")

local function marker_opts()
  return require("local_review").get_opts()
end

local function buffer_winid(bufnr)
  for _, winid in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_buf(winid) == bufnr then
      return winid
    end
  end
  return nil
end

local function box_width(bufnr)
  local winid = buffer_winid(bufnr)
  if not winid then
    return nil
  end

  local win_width = vim.api.nvim_win_get_width(winid)
  local textoff = vim.fn.getwininfo(winid)[1].textoff
  return math.max(8, win_width - textoff)
end

local function wrap_line(text, width)
  if width <= 0 then
    return {}
  end

  local lines = {}
  while text ~= "" do
    local part = vim.fn.strcharpart(text, 0, width)
    if part == "" then
      part = text
    end
    lines[#lines + 1] = part
    text = vim.fn.strcharpart(text, vim.fn.strchars(part), 2147483647)
  end
  return lines
end

local function wrapped_body_lines(body, text_width)
  local result = {}
  for _, line in ipairs(vim.split(body or "", "\n", { plain = true })) do
    if line == "" then
      result[#result + 1] = ""
    else
      for _, wrapped in ipairs(wrap_line(line, text_width)) do
        result[#result + 1] = wrapped
      end
    end
  end
  return result
end

local function pad(text, width)
  local pad_len = math.max(0, width - vim.fn.strdisplaywidth(text))
  return text .. string.rep(" ", pad_len)
end

local function border_top(title, width)
  if #title + 4 > width then
    title = ""
  end
  local fill = width - 2 - #title
  return "┌" .. title .. string.rep("─", fill) .. "┐"
end

local function border_bottom(width)
  return "└" .. string.rep("─", width - 2) .. "┘"
end

local function body_virt_line(text, width)
  local inner = width - 4
  local padded = pad(text, inner)
  return {
    { "│ ", "FloatBorder" },
    { padded, "NormalFloat" },
    { " │", "FloatBorder" },
  }
end

local function comment_virt_lines(comment, width)
  if width < 8 then
    return {}
  end

  local inner = width - 4
  local first = comment.anchor.line_number
  local last = math.max(first, comment.line_end or first)
  local range = last > first and string.format(" %d-%d", first, last) or ""
  local stale = comment.stale and " [stale]" or ""
  local title = string.format(" Review Comment%s%s ", range, stale)
  local top = border_top(title, width)
  local bottom = border_bottom(width)

  local virt_lines = {}
  virt_lines[#virt_lines + 1] = { { top, "FloatBorder" } }
  for _, line in ipairs(wrapped_body_lines(comment.body, inner)) do
    virt_lines[#virt_lines + 1] = body_virt_line(line, width)
  end
  virt_lines[#virt_lines + 1] = { { bottom, "FloatBorder" } }

  return virt_lines
end

function M.refresh(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) or vim.bo[bufnr].buftype ~= "" then
    return
  end

  vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)

  local comments = require("local_review.comments").comments_for_buffer(bufnr, { silent = true })
  local ui = require("local_review.ui")
  local opts = marker_opts()
  local max_line = math.max(vim.api.nvim_buf_line_count(bufnr), 1)
  local active_line = ui.active_source_line(bufnr)
  local width = box_width(bufnr)

  for index, comment in ipairs(comments) do
    local first = math.max(1, math.min(comment.anchor.line_number, max_line))
    local last = math.max(first, math.min(comment.line_end or comment.anchor.line_number, max_line))
    local active = active_line ~= nil and active_line >= first and active_line <= last

    -- Git-style gutter bar on every commented line; the comment box is drawn
    -- below the last line of the range.
    for line = first, last do
      local mark = {
        sign_text = opts.marker_text,
        sign_hl_group = opts.marker_hl,
        priority = 10 + index,
      }
      if line == last and not active and width then
        mark.virt_lines = comment_virt_lines(comment, width)
        mark.virt_lines_leftcol = false
        mark.hl_mode = "combine"
      end
      vim.api.nvim_buf_set_extmark(bufnr, namespace, line - 1, 0, mark)
    end
  end
end

return M
