if vim.g.loaded_local_review == 1 then
  return
end

vim.g.loaded_local_review = 1

require("local_review").setup()
