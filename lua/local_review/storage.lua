local M = {}

local function opts()
  return require("local_review").get_opts()
end

local function ensure_dir(path)
  vim.fn.mkdir(path, "p")
end

local function scope_key(scope_root)
  return vim.fn.sha256(scope_root)
end

local function load_json(path)
  if vim.fn.filereadable(path) == 0 then
    return { comments = {} }
  end

  local lines = vim.fn.readfile(path)
  local ok, decoded = pcall(vim.json.decode, table.concat(lines, "\n"))
  if not ok or type(decoded) ~= "table" then
    return { comments = {} }
  end

  decoded.comments = type(decoded.comments) == "table" and decoded.comments or {}
  return decoded
end

function M.scope_file(scope_root)
  local base = opts().storage_dir
  return string.format("%s/%s.json", base, scope_key(scope_root))
end

function M.load_scope(scope_root)
  return load_json(M.scope_file(scope_root))
end

function M.save_scope(scope_root, data)
  local path = M.scope_file(scope_root)
  data.scope_root = scope_root
  ensure_dir(vim.fn.fnamemodify(path, ":h"))
  if vim.fn.writefile({ vim.json.encode(data) }, path) ~= 0 then
    return nil, string.format("Failed to save review comments to %s.", path)
  end

  return true
end

function M.delete_scope(scope_root)
  local path = M.scope_file(scope_root)
  if vim.fn.filereadable(path) == 1 then
    return vim.fn.delete(path) == 0
  end

  return true
end

function M.list_scopes()
  local base = opts().storage_dir
  ensure_dir(base)

  local paths = vim.fn.glob(vim.fs.joinpath(base, "*.json"), false, true)
  local scopes = {}
  for _, path in ipairs(paths) do
    local data = load_json(path)
    local scope_root = data.scope_root
    if type(scope_root) == "string" and scope_root ~= "" then
      table.insert(scopes, {
        scope_root = scope_root,
        path = path,
        data = data,
      })
    end
  end

  return scopes
end

return M
