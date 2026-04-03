require("busted.runner")()

package.path = table.concat({
  "./lua/?.lua",
  "./lua/?/init.lua",
  package.path,
}, ";")

local positioning = require("local_review.positioning")

---@param text string
---@return string
local function trim(text)
  return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

---@param text string
---@return string[]
local function split_lines(text)
  if text == "" then
    return {}
  end

  local lines = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do
    lines[#lines + 1] = line
  end
  return lines
end

---@param path string
---@return string
local function read_fixture(path)
  local file = assert(io.open(path, "r"))
  local content = assert(file:read("*a"))
  file:close()
  return content
end

---@param fixture_text string
---@return table<string, string>
local function parse_fixture(fixture_text)
  local sections = {}
  local current_name
  local current_lines = {}

  local function flush()
    if current_name then
      sections[current_name] = table.concat(current_lines, "\n")
    end
  end

  for line in (fixture_text .. "\n"):gmatch("(.-)\n") do
    local section_name = line:match("^%-%-%-%s+([%w_]+)$")
    if section_name then
      flush()
      current_name = section_name
      current_lines = {}
    else
      current_lines[#current_lines + 1] = line
    end
  end

  flush()
  return sections
end

---@param text string
---@return integer|nil
local function parse_optional_integer(text)
  local trimmed = trim(text)
  if trimmed == "nil" then
    return nil
  end

  local value = tonumber(trimmed)
  if not value then
    error(string.format("invalid integer value: %q", text))
  end

  return value
end

---@param text string
---@return { before_line: integer, resolved_after_line: integer|nil }
local function parse_assertions(text)
  local assertions = {}

  for _, line in ipairs(split_lines(text)) do
    if line ~= "" then
      local key, value = line:match("^([%w_]+):%s*(.-)%s*$")
      if not key then
        error(string.format("invalid assertion line: %q", line))
      end
      assertions[key] = value
    end
  end

  return {
    before_line = assert(tonumber(assertions.before_line), "missing before_line"),
    resolved_after_line = parse_optional_integer(assertions.resolved_after_line or ""),
  }
end

---@return string[]
local function fixture_paths()
  local process = assert(io.popen("find tests/fixtures -type f -name '*.fixture' | sort", "r"))
  local output = assert(process:read("*a"))
  process:close()

  local paths = {}
  for _, path in ipairs(split_lines(trim(output))) do
    if path ~= "" then
      paths[#paths + 1] = path
    end
  end

  return paths
end

---@param path string
---@return string
local function basename(path)
  return path:match("([^/]+)$") or path
end

---@param fixture_path string
local function run_fixture(fixture_path)
  local fixture = parse_fixture(read_fixture(fixture_path))
  local assertions = parse_assertions(fixture.assertions or "")
  local before_lines = split_lines(fixture.file_before or "")
  local after_lines = split_lines(fixture.file_after or "")

  local anchor = positioning.capture(before_lines, assertions.before_line)
  local resolved_line = positioning.resolve(anchor, after_lines)

  assert.are.equal(
    assertions.resolved_after_line,
    resolved_line,
    string.format("resolved line mismatch for fixture %s", basename(fixture_path))
  )
end

describe("local_review.positioning fixtures", function()
  local paths = fixture_paths()

  it("finds fixture files", function()
    assert.is_true(#paths > 0)
  end)

  for _, path in ipairs(paths) do
    it(string.format("passes %s", basename(path)), function()
      run_fixture(path)
    end)
  end
end)
