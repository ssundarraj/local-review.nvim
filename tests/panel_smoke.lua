-- Toggle boxes across tabs, preserve comments and markers, and safely finish edits.
vim.opt.runtimepath:append(vim.uv.cwd())
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
local config = { storage_dir = root .. "/state" }
local review = require("local_review")
review.setup(config)
local comments = require("local_review.comments")
local ui = require("local_review.ui")
local markers = require("local_review.markers")
local ns = vim.api.nvim_create_namespace("local-review-markers")
local sources = {}
for index = 1, 2 do
  local path = root .. "/example" .. index .. ".lua"
  vim.fn.writefile({ "local a = 1", "local b = 2", "return a + b" }, path)
  if index > 1 then
    vim.cmd.tabnew()
  end
  vim.cmd.edit(path)
  local source = vim.api.nvim_get_current_buf()
  sources[#sources + 1] = source
  assert(comments.set_line_comment(source, 3, "Test the sum.", { start_line = 1, end_line = 3 }))
end

local function check_marks(bufnr, expected_boxes)
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })
  assert(#marks == 3, "all three lines must retain gutter markers")
  local boxes = 0
  for _, mark in ipairs(marks) do
    if mark[4].virt_lines and #mark[4].virt_lines > 0 then
      boxes = boxes + 1
    end
  end
  assert(boxes == expected_boxes, "unexpected number of saved comment boxes")
end

local function check_all(expected_boxes)
  for _, source in ipairs(sources) do
    check_marks(source, expected_boxes)
    assert(#comments.comments_for_buffer(source) == 1, "toggle must preserve comments")
  end
end

-- Default to visible, then hide every buffer including an inactive tab.
check_all(1)
vim.cmd.LocalReviewToggle()
assert(not review.boxes_visible())
check_all(0)

-- Refresh, reconfiguration, and tab navigation must respect session visibility.
review.setup(config)
vim.cmd.tabprevious()
for _, source in ipairs(sources) do
  markers.refresh(source)
end
check_all(0)

-- A hidden comment remains editable, and closing must not reveal saved boxes.
ui.open_current_line()
vim.api.nvim_buf_set_lines(0, 0, -1, false, { " Updated sum review." })
assert(ui.close_active())
check_all(0)
assert(comments.comments_for_buffer(sources[1])[1].body == "Updated sum review.")
vim.cmd.LocalReviewToggle()
check_all(1)

-- Hiding from inside an editor must save its draft and close the float.
ui.open_current_line()
vim.api.nvim_buf_set_lines(0, 0, -1, false, { " Saved before hiding." })
vim.cmd.LocalReviewToggle()
assert(ui.active_source_line(sources[1]) == nil, "toggle must close the editor")
assert(comments.comments_for_buffer(sources[1])[1].body == "Saved before hiding.")
check_all(0)

-- Newly displayed buffers inherit visibility; toggling works from scratch buffers.
vim.cmd.enew()
vim.cmd.LocalReviewToggle()
vim.cmd.buffer(sources[1])
check_all(1)

-- If saving fails, do not discard the draft or change visibility.
ui.open_current_line()
vim.api.nvim_buf_set_lines(0, 0, -1, false, { " Unsaved draft." })
local save = comments.set_line_comment
comments.set_line_comment = function()
  return nil, "Simulated storage failure"
end
local notify = vim.notify
vim.notify = function() end
vim.cmd.LocalReviewToggle()
vim.notify = notify
comments.set_line_comment = save
assert(review.boxes_visible(), "failed save must leave visibility unchanged")
assert(ui.active_source_line(sources[1]) ~= nil, "failed save must keep the editor open")
assert(ui.close_active())
check_all(1)

vim.fn.delete(root, "rf")
print("PASS: global box toggle preserves comments, range markers, visibility, and drafts")
