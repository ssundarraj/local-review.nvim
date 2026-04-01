local M = {}

local group = "local_review_signs"

local function sign_name()
  return require("local_review").get_opts().sign_name
end

function M.define(opts)
  vim.fn.sign_define(opts.sign_name, {
    text = opts.sign_text,
    texthl = "DiagnosticHint",
    linehl = "",
    numhl = "",
  })
end

function M.refresh(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) or vim.bo[bufnr].buftype ~= "" then
    return
  end

  vim.fn.sign_unplace(group, { buffer = bufnr })

  local comments = require("local_review.comments").comments_for_buffer(bufnr)
  for index, comment in ipairs(comments) do
    vim.fn.sign_place(0, group, sign_name(), bufnr, {
      lnum = comment.line,
      priority = 10 + index,
    })
  end
end

return M
