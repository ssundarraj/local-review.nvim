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
    }
  end

  local lines = {
    "Please address the following feedback",
    "",
  }

  for index, comment in ipairs(path_comments) do
    local stale_suffix = comment.stale and " [stale]" or ""
    lines[#lines + 1] = string.format(
      "%d. %s:%d%s",
      index,
      display_path(root_path, path_kind, comment.absolute_path),
      comment.anchor.line_number,
      stale_suffix
    )
    lines[#lines + 1] = export_indent .. comment.body:gsub("\n", "\n" .. export_indent)
    lines[#lines + 1] = ""
  end

  return lines
end

function M.path_export_text(path)
  local lines, err = export_lines(path)
  if not lines then
    return nil, err
  end

  return table.concat(lines, "\n")
end

function M.open_export(path)
  local export_path = path
  if export_path == nil or export_path == "" then
    export_path = context.default_export_root()
  end

  local text, err = M.path_export_text(export_path)
  if not text then
    vim.notify(err or "Failed to export review comments.", vim.log.levels.WARN)
    return
  end

  io.write(text .. "\n")
end

return M
