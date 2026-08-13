local M = {}

local context = require("local_review.context")
local comments = require("local_review.comments")
local export_indent_width = 3
local export_indent = string.rep(" ", export_indent_width)

local function display_path(root_path, kind, absolute_path)
  if kind == "file" then
    return absolute_path
  end

  return context.relative_path(root_path, absolute_path) or absolute_path
end

local function export_lines(path)
  local path_comments, root_path, path_kind = comments.list_comments_in_path(path)
  if not path_comments then
    return nil, root_path or "Failed to resolve export path."
  end

  if #path_comments == 0 then
    return {
      "No review comments found for the selected path.",
    }, nil, 0
  end

  local lines = {
    "Please address the following feedback",
    "",
  }

  for index, comment in ipairs(path_comments) do
    local stale_suffix = comment.stale and " [stale]" or ""
    local line_ref = tostring(comment.anchor.line_number)
    if (comment.line_end or comment.anchor.line_number) > comment.anchor.line_number then
      line_ref = string.format("%d-%d", comment.anchor.line_number, comment.line_end)
    end
    lines[#lines + 1] = string.format(
      "%d. %s:%s%s",
      index,
      display_path(root_path, path_kind, comment.absolute_path),
      line_ref,
      stale_suffix
    )
    lines[#lines + 1] = export_indent .. comment.body:gsub("\n", "\n" .. export_indent)
    lines[#lines + 1] = ""
  end

  return lines, nil, #path_comments
end

function M.path_export_text(path)
  local lines, err, comment_count = export_lines(path)
  if not lines then
    return nil, err
  end

  return table.concat(lines, "\n"), nil, comment_count
end

function M.open_export(path, opts)
  local export_path = path
  if export_path == nil or export_path == "" then
    export_path = context.default_export_root()
  end

  local text, err, comment_count = M.path_export_text(export_path)
  if not text then
    vim.notify(err or "Failed to export review comments.", vim.log.levels.WARN)
    return
  end

  if #vim.api.nvim_list_uis() == 0 then
    -- Headless runs (e.g. skills) still need stdout output.
    io.write(text .. "\n")
  else
    local copied = false
    for _, reg in ipairs({ "+", "*" }) do
      local ok = pcall(vim.fn.setreg, reg, text)
      if ok then
        copied = true
      end
    end

    if copied then
      vim.notify(
        string.format("Copied %d review comment(s) to the system clipboard.", comment_count),
        vim.log.levels.INFO
      )
    else
      vim.notify("Failed to copy review comments to the system clipboard.", vim.log.levels.ERROR)
    end
  end

  if opts and opts.clear_after_export and comment_count > 0 then
    comments.clear_path(export_path, { silent = true })
  end
end

function M.open_export_preserve(path)
  M.open_export(path)
end

return M
