local M = {}

---@class LocalReviewComment
---@field id string
---@field repo_root string
---@field absolute_path string
---@field relative_path string
---@field body string
---@field created_at string
---@field updated_at string
---@field source_kind string
---@field source_meta table
---@field stale boolean
---@field anchor LineAnchor

local context = require("local_review.context")
local positioning = require("local_review.positioning")
local storage = require("local_review.storage")

local state = {
  file_fingerprints = {},
}

local function now()
  return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

local function hrtime()
  ---@diagnostic disable-next-line: undefined-field
  return vim.uv.hrtime()
end

---@param bufnr integer
---@return string[]
local function buffer_lines(bufnr)
  return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

---@param comment LocalReviewComment
---@param lines string[]
---@param line integer
local function apply_anchor(comment, lines, line)
  comment.anchor = positioning.capture(lines, line)
  comment.stale = false
end

---@param comment LocalReviewComment
local function ensure_comment_defaults(comment)
  if comment.id == "" then
    comment.id = tostring(hrtime())
  end
  if comment.stale == nil then
    comment.stale = false
  end
end

local function loaded_repo()
  local repo, err = storage.for_current_repo()
  if not repo then
    vim.notify(err or "Failed to load repository state.", vim.log.levels.WARN)
    return nil
  end
  return repo
end

local function current_line()
  return vim.api.nvim_win_get_cursor(0)[1]
end

local function refresh_repo_buffers(repo_root)
  local markers = require("local_review.markers")
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].buftype == "" then
      local path = vim.api.nvim_buf_get_name(bufnr)
      if path ~= "" then
        local root = context.repo_root(path)
        if root == repo_root then
          markers.refresh(bufnr)
        end
      end
    end
  end
end

local function persist_repo_state(repo_root, data)
  local ok, err = storage.save_repo(repo_root, data)
  if not ok then
    return nil, err
  end

  refresh_repo_buffers(repo_root)
  return true
end

local function comment_sorter(a, b)
  if a.relative_path ~= b.relative_path then
    return a.relative_path < b.relative_path
  end
  if a.anchor.line_number ~= b.anchor.line_number then
    return a.anchor.line_number < b.anchor.line_number
  end
  return (a.created_at or "") < (b.created_at or "")
end

---@param lines string[]
---@return string
local function buffer_fingerprint(lines)
  return vim.fn.sha256(table.concat(lines, "\n"))
end

---@param comment LocalReviewComment
---@param lines string[]
---@return boolean
local function reconcile_comment(comment, lines)
  ensure_comment_defaults(comment)

  local resolved = positioning.resolve(comment.anchor, lines)
  if not resolved then
    if not comment.stale then
      comment.stale = true
      return true
    end
    return false
  end

  if comment.anchor.line_number == resolved and not comment.stale then
    apply_anchor(comment, lines, resolved)
    return false
  end

  local moved = comment.anchor.line_number ~= resolved or comment.stale
  apply_anchor(comment, lines, resolved)
  return moved
end

local function clamp_line(line, lines)
  local max_line = math.max(#lines, 1)
  return math.max(1, math.min(line, max_line))
end

local function find_comment_at_line(comments, relative_path, line)
  for _, comment in ipairs(comments) do
    ensure_comment_defaults(comment)
    if comment.relative_path == relative_path and comment.anchor.line_number == line then
      return comment
    end
  end
  return nil
end

local function find_comment_entry_at_line(comments, relative_path, line)
  for index, comment in ipairs(comments) do
    ensure_comment_defaults(comment)
    if comment.relative_path == relative_path and comment.anchor.line_number == line then
      return comment, index
    end
  end
  return nil, nil
end

local function reconcile_buffer_state(bufnr, repo_state, ctx)
  local lines = buffer_lines(bufnr)
  local fingerprint = buffer_fingerprint(lines)
  local previous = state.file_fingerprints[ctx.absolute_path]
  local comments = repo_state.data.comments

  if previous == fingerprint then
    return repo_state
  end

  local changed = false
  for _, comment in ipairs(comments) do
    if comment.relative_path == ctx.relative_path then
      comment.absolute_path = ctx.absolute_path
      comment.repo_root = ctx.repo_root
      if reconcile_comment(comment, lines) then
        changed = true
      end
    end
  end

  if changed then
    local ok, err = storage.save_repo(ctx.repo_root, repo_state.data)
    if not ok then
      vim.notify(err or "Failed to save repository state.", vim.log.levels.ERROR)
    end
  end

  state.file_fingerprints[ctx.absolute_path] = fingerprint
  return repo_state
end

local function repo_state_for_buffer(bufnr)
  local ctx, err = context.comment_context(bufnr)
  if not ctx then
    return nil, err
  end

  local repo_state = {
    repo_root = ctx.repo_root,
    data = storage.load_repo(ctx.repo_root),
  }

  reconcile_buffer_state(bufnr or 0, repo_state, ctx)
  return {
    ctx = ctx,
    repo_state = repo_state,
  }
end

---@return LocalReviewComment, boolean
local function upsert_comment(repo_state, ctx, line, body)
  local comments = repo_state.data.comments
  local existing = find_comment_at_line(comments, ctx.relative_path, line)

  local timestamp = now()
  local lines = buffer_lines(ctx.bufnr)
  local resolved_line = clamp_line(line, lines)
  if existing then
    existing.body = body
    existing.updated_at = timestamp
    existing.absolute_path = ctx.absolute_path
    existing.repo_root = ctx.repo_root
    apply_anchor(existing, lines, resolved_line)
    return existing, true
  end

  local filetype = vim.bo[ctx.bufnr].filetype or ""
  local source_kind = filetype:match("^Diffview") and "diffview" or "buffer"
  local comment = {
    id = tostring(hrtime()),
    repo_root = ctx.repo_root,
    absolute_path = ctx.absolute_path,
    relative_path = ctx.relative_path,
    body = body,
    created_at = timestamp,
    updated_at = timestamp,
    source_kind = source_kind,
    source_meta = {},
    stale = false,
  }

  apply_anchor(comment, lines, resolved_line)
  table.insert(comments, comment)
  return comment, false
end

local function find_current_comment()
  local resolved, err = repo_state_for_buffer(0)
  if not resolved then
    vim.notify(err or "Failed to find the current review comment.", vim.log.levels.WARN)
    return nil
  end

  local line = current_line()
  local comment, index = find_comment_entry_at_line(resolved.repo_state.data.comments, resolved.ctx.relative_path, line)
  return {
    ---@type LocalReviewComment?
    comment = comment,
    index = index,
    ctx = resolved.ctx,
    repo_state = resolved.repo_state,
  }
end

local function find_line_comment(bufnr, line)
  local resolved, err = repo_state_for_buffer(bufnr)
  if not resolved then
    return nil, err
  end

  local comment, index = find_comment_entry_at_line(resolved.repo_state.data.comments, resolved.ctx.relative_path, line)
  return {
    ---@type LocalReviewComment?
    comment = comment,
    index = index,
    ctx = resolved.ctx,
    repo_state = resolved.repo_state,
  }
end

function M.status_label(comment)
  if comment and comment.stale then
    return "stale"
  end
  return nil
end

function M.list_repo_comments(repo_root)
  local data = storage.load_repo(repo_root)
  for _, comment in ipairs(data.comments) do
    ensure_comment_defaults(comment)
  end
  table.sort(data.comments, comment_sorter)
  return data.comments
end

function M.comments_for_buffer(bufnr)
  local resolved, err = repo_state_for_buffer(bufnr or 0)
  if not resolved then
    vim.notify(err or "Failed to load comments for the current buffer.", vim.log.levels.WARN)
    return {}
  end

  local comments = M.list_repo_comments(resolved.ctx.repo_root)
  local matches = {}
  for _, comment in ipairs(comments) do
    if comment.relative_path == resolved.ctx.relative_path then
      table.insert(matches, comment)
    end
  end
  return matches
end

function M.get_line_state(bufnr, line)
  local result, err = find_line_comment(bufnr or 0, line)
  if not result then
    vim.notify(err or "Failed to find a review comment for the current line.", vim.log.levels.WARN)
    return nil
  end

  return result
end

function M.upsert_line_comment(line_state, body)
  local trimmed = vim.trim(body or "")
  if trimmed == "" then
    return nil, "Comment cannot be empty."
  end

  local _, updated = upsert_comment(
    line_state.repo_state,
    line_state.ctx,
    line_state.comment and line_state.comment.anchor.line_number or current_line(),
    trimmed
  )
  local ok, err = persist_repo_state(line_state.ctx.repo_root, line_state.repo_state.data)
  if not ok then
    return nil, err
  end
  return updated and "updated" or "created"
end

function M.set_line_comment(bufnr, line, body)
  local line_state = M.get_line_state(bufnr, line)
  if not line_state then
    return nil, "Unable to resolve comment target."
  end

  local trimmed = vim.trim(body or "")
  if trimmed == "" then
    if line_state.index ~= nil then
      table.remove(line_state.repo_state.data.comments, line_state.index)
      local ok, err = persist_repo_state(line_state.ctx.repo_root, line_state.repo_state.data)
      if not ok then
        return nil, err
      end
      return "deleted"
    end

    return "noop"
  end

  local _, updated = upsert_comment(line_state.repo_state, line_state.ctx, line, trimmed)
  local ok, err = persist_repo_state(line_state.ctx.repo_root, line_state.repo_state.data)
  if not ok then
    return nil, err
  end
  return updated and "updated" or "created"
end

function M.delete_line_comment(bufnr, line)
  local line_state = M.get_line_state(bufnr, line)
  if not line_state then
    return nil, "Unable to resolve comment target."
  end

  if line_state.index == nil then
    return "missing"
  end

  table.remove(line_state.repo_state.data.comments, line_state.index)
  local ok, err = persist_repo_state(line_state.ctx.repo_root, line_state.repo_state.data)
  if not ok then
    return nil, err
  end
  return "deleted"
end

function M.prompt_for_current_line()
  local result = find_current_comment()
  if not result then
    return
  end

  local line = current_line()
  local prompt = result.comment and "Edit review comment" or "Add review comment"
  local default = result.comment and result.comment.body or ""

  vim.ui.input({
    prompt = string.format("%s (%s:%d): ", prompt, result.ctx.relative_path, line),
    default = default,
  }, function(input)
    if input == nil then
      return
    end

    local trimmed = vim.trim(input)
    if trimmed == "" then
      vim.notify("Comment cannot be empty.", vim.log.levels.WARN)
      return
    end

    local _, updated = upsert_comment(result.repo_state, result.ctx, line, trimmed)
    local ok, err = persist_repo_state(result.ctx.repo_root, result.repo_state.data)
    if not ok then
      vim.notify(err or "Failed to save the review comment.", vim.log.levels.ERROR)
      return
    end
    vim.notify(updated and "Review comment updated." or "Review comment added.", vim.log.levels.INFO)
  end)
end

function M.delete_current_line()
  local result = find_current_comment()
  if not result then
    return
  end

  if result.index == nil then
    vim.notify("No review comment on the current line.", vim.log.levels.INFO)
    return
  end

  table.remove(result.repo_state.data.comments, result.index)
  local ok, err = persist_repo_state(result.ctx.repo_root, result.repo_state.data)
  if not ok then
    vim.notify(err or "Failed to delete the review comment.", vim.log.levels.ERROR)
    return
  end
  vim.notify("Review comment deleted.", vim.log.levels.INFO)
end

function M.jump(direction)
  local comments = M.comments_for_buffer(0)
  if #comments == 0 then
    vim.notify("No review comments in the current buffer.", vim.log.levels.INFO)
    return
  end

  local line = current_line()
  table.sort(comments, function(a, b)
    return a.anchor.line_number < b.anchor.line_number
  end)

  local target
  if direction > 0 then
    for _, comment in ipairs(comments) do
      if comment.anchor.line_number > line then
        target = comment
        break
      end
    end
    target = target or comments[1]
  else
    for index = #comments, 1, -1 do
      if comments[index].anchor.line_number < line then
        target = comments[index]
        break
      end
    end
    target = target or comments[#comments]
  end

  local max_line = math.max(vim.api.nvim_buf_line_count(0), 1)
  local target_line = math.max(1, math.min(target.anchor.line_number, max_line))
  vim.api.nvim_win_set_cursor(0, { target_line, 0 })
  if target.stale then
    vim.notify("Jumped to a stale review comment.", vim.log.levels.WARN)
  end
end

function M.clear_repo()
  local repo_state = loaded_repo()
  if not repo_state then
    return
  end

  repo_state.data.comments = {}
  local deleted = storage.delete_repo(repo_state.repo_root)
  if not deleted then
    local ok, err = persist_repo_state(repo_state.repo_root, repo_state.data)
    if not ok then
      vim.notify(err or "Failed to clear review comments for the current repo.", vim.log.levels.ERROR)
      return
    end
  else
    refresh_repo_buffers(repo_state.repo_root)
  end
  vim.notify("Cleared review comments for current repo.", vim.log.levels.INFO)
end

return M
