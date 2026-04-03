local M = {}

local max_context_radius = 4
local search_band_radii = { 5, 15, 40 }

---@param text string?
---@return string
local function trim(text)
  text = text or ""
  return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

---@param text string?
---@return string
local function normalize_text(text)
  return trim((text or ""):gsub("%s+", " "))
end

---@param lines string[]
---@param line integer
---@return string
local function line_at(lines, line)
  return lines[line] or ""
end

---@param lines string[]
---@param start_line integer
---@param end_line integer
---@return string[]
local function lines_in_range(lines, start_line, end_line)
  local selected_lines = {}
  for line = start_line, end_line do
    if line >= 1 and line <= #lines then
      selected_lines[#selected_lines + 1] = lines[line]
    end
  end
  return selected_lines
end

---@param lines string[]
---@return string[]
local function normalized_lines(lines)
  local normalized = {}
  for _, value in ipairs(lines) do
    normalized[#normalized + 1] = normalize_text(value)
  end
  return normalized
end

---@param anchor LineAnchor
---@param lines string[]
---@param line integer
---@return integer
local function context_score(anchor, lines, line)
  local score = 0

  for index, value in ipairs(anchor.normalized_before_context) do
    local candidate_line = line - (#anchor.normalized_before_context - index + 1)
    if normalize_text(line_at(lines, candidate_line)) == value then
      local distance = #anchor.normalized_before_context - index + 1
      score = score + math.max(1, max_context_radius - distance + 1)
    end
  end

  for index, value in ipairs(anchor.normalized_after_context) do
    local candidate_line = line + index
    if normalize_text(line_at(lines, candidate_line)) == value then
      score = score + math.max(1, max_context_radius - index + 1)
    end
  end

  return score
end

---@param center_line integer
---@param min_distance integer
---@param max_distance integer
---@param line_count integer
---@return integer[]
local function band_lines(center_line, min_distance, max_distance, line_count)
  local matches = {}
  for line = 1, line_count do
    local distance = math.abs(line - center_line)
    if distance >= min_distance and distance <= max_distance then
      matches[#matches + 1] = line
    end
  end
  return matches
end

---@param lines string[]
---@param target string
---@param candidates integer[]
---@return integer[]
local function candidate_lines(lines, target, candidates)
  local matches = {}
  for _, line in ipairs(candidates) do
    if normalize_text(line_at(lines, line)) == target then
      matches[#matches + 1] = line
    end
  end
  return matches
end

---@param anchor LineAnchor
---@param lines string[]
---@param matches integer[]
---@return integer|nil
local function select_candidate(anchor, lines, matches)
  if #matches == 0 then
    return nil
  end

  if #matches == 1 then
    return matches[1]
  end

  local best_line
  local best_score = -1

  for _, line in ipairs(matches) do
    local score = context_score(anchor, lines, line)
    if score > best_score then
      best_line = line
      best_score = score
    end
  end

  if best_score <= 0 then
    return nil
  end

  local nearest_line = best_line
  local nearest_distance = math.abs(best_line - anchor.line_number)
  local duplicate_nearest = false

  for _, line in ipairs(matches) do
    if context_score(anchor, lines, line) == best_score then
      local distance = math.abs(line - anchor.line_number)
      if distance < nearest_distance then
        nearest_line = line
        nearest_distance = distance
        duplicate_nearest = false
      elseif distance == nearest_distance and line ~= nearest_line then
        duplicate_nearest = true
      end
    end
  end

  if duplicate_nearest then
    return nil
  end

  return nearest_line
end

---@class LineAnchor
---@field line_number integer
---@field line_text string
---@field normalized_line_text string
---@field normalized_before_context string[]
---@field normalized_after_context string[]

---@param lines string[]
---@param line_number integer
---@return LineAnchor
function M.capture(lines, line_number)
  local before = lines_in_range(lines, line_number - max_context_radius, line_number - 1)
  local after = lines_in_range(lines, line_number + 1, line_number + max_context_radius)
  local line_text = line_at(lines, line_number)

  return {
    line_number = line_number,
    line_text = line_text,
    normalized_line_text = normalize_text(line_text),
    normalized_before_context = normalized_lines(before),
    normalized_after_context = normalized_lines(after),
  }
end

---@param anchor LineAnchor
---@param lines string[]
---@return integer|nil
function M.resolve(anchor, lines)
  local line_count = math.max(#lines, 1)
  local stored_line = math.min(anchor.line_number, line_count)
  local target = anchor.normalized_line_text

  if target == "" then
    return stored_line
  end

  if normalize_text(line_at(lines, stored_line)) == target then
    return stored_line
  end

  local previous_radius = 0
  for _, radius in ipairs(search_band_radii) do
    local band = band_lines(stored_line, previous_radius + 1, radius, line_count)
    local matches = candidate_lines(lines, target, band)
    local resolved = select_candidate(anchor, lines, matches)
    if resolved then
      return resolved
    end
    previous_radius = radius
  end

  local all_lines = band_lines(stored_line, 0, line_count, line_count)
  local resolved = select_candidate(anchor, lines, candidate_lines(lines, target, all_lines))
  if resolved then
    return resolved
  end

  previous_radius = -1
  for _, radius in ipairs(search_band_radii) do
    local band = band_lines(stored_line, previous_radius + 1, radius, line_count)
    resolved = select_candidate(anchor, lines, band)
    if resolved then
      return resolved
    end
    previous_radius = radius
  end

  return select_candidate(anchor, lines, all_lines)
end

return M
