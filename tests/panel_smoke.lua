-- Closing the editor should leave range markers, with saved boxes opt-in.
vim.opt.runtimepath:append(vim.uv.cwd())
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
local path = root .. "/example.lua"
vim.fn.writefile({ "local a = 1", "local b = 2", "return a + b" }, path)
local config = { storage_dir = root .. "/state" }
require("local_review").setup(config)
vim.cmd.edit(path)
local source = vim.api.nvim_get_current_buf()
local comments = require("local_review.comments")
local ui = require("local_review.ui")
local markers = require("local_review.markers")
local ns = vim.api.nvim_create_namespace("local-review-markers")
local function check_marks(expected_boxes)
  local marks = vim.api.nvim_buf_get_extmarks(source, ns, 0, -1, { details = true })
  assert(#marks == 3, "all three lines must retain gutter markers")
  local boxes = 0
  for _, mark in ipairs(marks) do
    if mark[4].virt_lines and #mark[4].virt_lines > 0 then
      boxes = boxes + 1
    end
  end
  assert(boxes == expected_boxes, "unexpected number of persistent comment boxes")
end

ui.open_current_line({ 1, 3 })
vim.api.nvim_buf_set_lines(0, 0, -1, false, { " Test the sum." })
assert(ui.close_active())
assert(#vim.api.nvim_list_wins() == 1, "editor float must close")
check_marks(0)
assert(comments.comments_for_buffer(source)[1].body == "Test the sum.")

-- A later buffer refresh must not bring the boxes back.
markers.refresh(source)
check_marks(0)
ui.open_current_line()
assert(#vim.api.nvim_list_wins() == 2, "saved comment must remain editable")
assert(ui.close_active())
check_marks(0)

-- Preserve the branch's persistent-box behavior when explicitly requested.
config.show_comment_boxes = true
require("local_review").setup(config)
markers.refresh(source)
check_marks(1)
ui.open_current_line()
check_marks(0)
assert(ui.close_active())
check_marks(1)

vim.fn.delete(root, "rf")
print("PASS: editor closes, comments survive, range markers remain, saved boxes are opt-in")
