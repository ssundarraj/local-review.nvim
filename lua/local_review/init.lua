local M = {}

local defaults = {
  marker_text = "▎",
  marker_hl = "LocalReviewMarker",
  storage_dir = vim.fs.joinpath(vim.fn.stdpath("state"), "local-review"),
  keymaps = {},
  comment_close_keys = {
    { modes = { "n" }, key = "q" },
    { modes = { "n", "i" }, key = "<C-c>" },
  },
}

local state = {
  configured = false,
  opts = vim.deepcopy(defaults),
}

local function command(name, rhs, opts)
  vim.api.nvim_create_user_command(name, rhs, opts or {})
end

local function map(mode, lhs, rhs, desc)
  if lhs == nil or lhs == "" then
    return
  end

  vim.keymap.set(mode, lhs, rhs, { desc = desc, silent = true })
end

local function visual_safe_cmd(command_name)
  return function()
    local mode = vim.api.nvim_get_mode().mode
    if mode:match("^[vV\22]") then
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
      if command_name == "LocalReviewComment" then
        require("local_review.ui").set_pending_range(vim.fn.getpos("'<")[2], vim.fn.getpos("'>")[2])
      end
    end
    vim.cmd(command_name)
  end
end

local function refresh_current_buffer(bufnr)
  require("local_review.markers").refresh((bufnr and bufnr ~= 0) and bufnr or vim.api.nvim_get_current_buf())
end

local function list_comments(path)
  local path_comments, err = require("local_review.comments").list_comments_in_path(path ~= "" and path or nil)
  if not path_comments then
    vim.notify(err or "Failed to list review comments.", vim.log.levels.WARN)
    return
  end

  if #path_comments == 0 then
    vim.notify("No review comments found.", vim.log.levels.INFO)
    return
  end

  local items = {}
  for _, comment in ipairs(path_comments) do
    local summary = vim.trim((comment.body or ""):gsub("%s+", " "))
    local start_line = comment.anchor.line_number
    local end_line = comment.line_end
    local range_suffix = ""
    if end_line and end_line ~= start_line then
      range_suffix = string.format(" [lines %d-%d]", start_line, end_line)
    end
    items[#items + 1] = {
      filename = comment.absolute_path,
      lnum = math.max(1, start_line),
      col = 1,
      text = (comment.stale and "[stale] " or "") .. summary .. range_suffix,
    }
  end

  vim.fn.setqflist({}, " ", { title = "Local Review Comments", items = items })
  vim.cmd("copen")
end

function M.setup(opts)
  state.opts = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})

  -- Gutter marker for commented lines. Linked to an info-style group (blue in
  -- most colorschemes); override with :highlight to customize. The group name
  -- doubles as the sign name for statuscolumn plugins.
  vim.api.nvim_set_hl(0, "LocalReviewMarker", { link = "DiagnosticInfo", default = true })

  -- Title of the comment box while creating/editing. Linked to a group that
  -- is orange in most colorschemes; override with :highlight to customize.
  vim.api.nvim_set_hl(0, "LocalReviewEditorTitle", { link = "Number", default = true })

  if not state.configured then
    command("LocalReviewComment", function(command_opts)
      local range
      if command_opts.range and command_opts.range > 0 then
        range = { command_opts.line1, command_opts.line2 }
      end
      require("local_review.ui").open_current_line(range)
    end, { range = true })

    command("LocalReviewDelete", function()
      require("local_review.comments").delete_current_line()
    end, {})

    command("LocalReviewNext", function()
      require("local_review.comments").jump(1)
    end, {})

    command("LocalReviewPrev", function()
      require("local_review.comments").jump(-1)
    end, {})

    command("LocalReviewExport", function(command_opts)
      require("local_review.export").open_export(command_opts.args, { clear_after_export = true })
    end, { nargs = "?" })

    command("LocalReviewExportPreserve", function(command_opts)
      require("local_review.export").open_export_preserve(command_opts.args)
    end, { nargs = "?" })

    command("LocalReviewClear", function(command_opts)
      require("local_review.comments").clear_path(command_opts.args)
    end, { nargs = "?" })

    command("LocalReviewList", function(command_opts)
      list_comments(command_opts.args)
    end, { nargs = "?" })

    vim.api.nvim_create_autocmd({ "BufEnter", "BufReadPost", "BufWritePost", "FileChangedShellPost", "VimResized" }, {
      group = vim.api.nvim_create_augroup("local-review-refresh", { clear = true }),
      callback = function(event)
        refresh_current_buffer(event.buf)
      end,
    })

    state.configured = true
  end

  map({ "n", "x" }, state.opts.keymaps.comment, visual_safe_cmd("LocalReviewComment"), "Local Review: Comment")
  map({ "n", "x" }, state.opts.keymaps.delete, visual_safe_cmd("LocalReviewDelete"), "Local Review: Delete")
  map({ "n", "x" }, state.opts.keymaps.next, visual_safe_cmd("LocalReviewNext"), "Local Review: Next")
  map({ "n", "x" }, state.opts.keymaps.prev, visual_safe_cmd("LocalReviewPrev"), "Local Review: Prev")
  map({ "n", "x" }, state.opts.keymaps.export, visual_safe_cmd("LocalReviewExport"), "Local Review: Export")
  map({ "n", "x" }, state.opts.keymaps.list, visual_safe_cmd("LocalReviewList"), "Local Review: List")
end

function M.get_opts()
  return state.opts
end

return M
