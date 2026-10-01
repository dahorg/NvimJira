-- Minimal conversion between Atlassian Document Format (Jira Cloud API v3)
-- and markdown-ish plain text.

local M = {}

local render

local function blocks(node, sep)
  local out = {}
  for _, child in ipairs(node.content or {}) do
    local s = render(child)
    if s ~= "" then
      out[#out + 1] = s
    end
  end
  return table.concat(out, sep)
end

local function prefix_lines(s, prefix)
  local lines = vim.split(s, "\n", { plain = true })
  for i, l in ipairs(lines) do
    lines[i] = prefix .. l
  end
  return table.concat(lines, "\n")
end

local function list(node, ordered)
  local items = {}
  for i, item in ipairs(node.content or {}) do
    local marker = ordered and (i .. ". ") or "- "
    local lines = vim.split(blocks(item, "\n"), "\n", { plain = true })
    lines[1] = marker .. lines[1]
    for j = 2, #lines do
      lines[j] = string.rep(" ", #marker) .. lines[j]
    end
    items[#items + 1] = table.concat(lines, "\n")
  end
  return table.concat(items, "\n")
end

local function text_node(node)
  local s = node.text or ""
  for _, m in ipairs(node.marks or {}) do
    if m.type == "code" then
      s = "`" .. s .. "`"
    elseif m.type == "strong" then
      s = "**" .. s .. "**"
    elseif m.type == "em" then
      s = "_" .. s .. "_"
    elseif m.type == "strike" then
      s = "~~" .. s .. "~~"
    elseif m.type == "link" and m.attrs and m.attrs.href and m.attrs.href ~= s then
      s = "[" .. s .. "](" .. m.attrs.href .. ")"
    end
  end
  return s
end

render = function(node)
  local t = node.type
  local attrs = node.attrs or {}
  if t == "text" then
    return text_node(node)
  elseif t == "hardBreak" then
    return "\n"
  elseif t == "mention" then
    return "@" .. (attrs.text or ""):gsub("^@", "")
  elseif t == "emoji" then
    return attrs.text or attrs.shortName or ""
  elseif t == "inlineCard" or t == "blockCard" or t == "embedCard" then
    return attrs.url or ""
  elseif t == "date" then
    local ts = tonumber(attrs.timestamp)
    return ts and os.date("%Y-%m-%d", math.floor(ts / 1000)) or ""
  elseif t == "status" then
    return "[" .. (attrs.text or "") .. "]"
  elseif t == "paragraph" then
    return blocks(node, "")
  elseif t == "heading" then
    return string.rep("#", attrs.level or 1) .. " " .. blocks(node, "")
  elseif t == "codeBlock" then
    return "```" .. (attrs.language or "") .. "\n" .. blocks(node, "") .. "\n```"
  elseif t == "blockquote" or t == "panel" then
    return prefix_lines(blocks(node, "\n\n"), "> ")
  elseif t == "rule" then
    return "---"
  elseif t == "bulletList" then
    return list(node, false)
  elseif t == "orderedList" then
    return list(node, true)
  elseif t == "table" then
    local rows = {}
    for _, row in ipairs(node.content or {}) do
      local cells = {}
      for _, cell in ipairs(row.content or {}) do
        cells[#cells + 1] = blocks(cell, " ")
      end
      rows[#rows + 1] = "| " .. table.concat(cells, " | ") .. " |"
    end
    return table.concat(rows, "\n")
  elseif t == "mediaSingle" or t == "mediaGroup" or t == "mediaInline" or t == "media" then
    return "[attachment]"
  elseif node.content then
    return blocks(node, "\n\n")
  end
  return node.text or ""
end

--- ADF document -> text
function M.to_text(doc)
  if type(doc) ~= "table" then
    return doc and tostring(doc) or ""
  end
  return render(doc)
end

-- Inline markdown -> ADF text nodes: `code`, **bold**, [text](url), bare URLs.
local function inline(s)
  local out = {}
  local function push(text, marks)
    if text ~= "" then
      out[#out + 1] = { type = "text", text = text, marks = marks }
    end
  end
  local pos = 1
  while pos <= #s do
    local candidates = {
      { s:find("`([^`]+)`", pos) },
      { s:find("%*%*(.-)%*%*", pos) },
      { s:find("%[([^%]]+)%]%((https?://[^%)%s]+)%)", pos) },
      { s:find("(https?://[^%s%)]+)", pos) },
    }
    local kinds = { "code", "strong", "link", "url" }
    local best, kind
    for i, m in ipairs(candidates) do
      if m[1] and (not best or m[1] < best[1]) then
        best, kind = m, kinds[i]
      end
    end
    if not best then
      push(s:sub(pos))
      break
    end
    push(s:sub(pos, best[1] - 1))
    if kind == "code" then
      push(best[3], { { type = "code" } })
    elseif kind == "strong" then
      push(best[3], { { type = "strong" } })
    elseif kind == "link" then
      push(best[3], { { type = "link", attrs = { href = best[4] } } })
    else
      push(best[3], { { type = "link", attrs = { href = best[3] } } })
    end
    pos = best[2] + 1
  end
  return out
end

local function list_block(lines, i, pattern, list_type)
  local items = {}
  while i <= #lines and lines[i]:match(pattern) do
    local text = lines[i]:gsub(pattern, "", 1)
    items[#items + 1] = {
      type = "listItem",
      content = { { type = "paragraph", content = inline(text) } },
    }
    i = i + 1
  end
  return { type = list_type, content = items }, i
end

--- Text (light markdown) -> ADF document
function M.from_text(text)
  local lines = vim.split((text or ""):gsub("\r", ""), "\n", { plain = true })
  local content, para = {}, {}

  local function flush()
    if #para == 0 then
      return
    end
    local nodes = {}
    for k, l in ipairs(para) do
      if k > 1 then
        nodes[#nodes + 1] = { type = "hardBreak" }
      end
      vim.list_extend(nodes, inline(l))
    end
    content[#content + 1] = { type = "paragraph", content = nodes }
    para = {}
  end

  local i = 1
  while i <= #lines do
    local line = lines[i]
    local fence = line:match("^```(.*)$")
    if fence then
      flush()
      local code = {}
      i = i + 1
      while i <= #lines and not lines[i]:match("^```%s*$") do
        code[#code + 1] = lines[i]
        i = i + 1
      end
      local node = { type = "codeBlock", content = {} }
      if #code > 0 then
        node.content = { { type = "text", text = table.concat(code, "\n") } }
      end
      if vim.trim(fence) ~= "" then
        node.attrs = { language = vim.trim(fence) }
      end
      content[#content + 1] = node
      i = i + 1
    elseif line:match("^#+%s") then
      flush()
      local hashes, rest = line:match("^(#+)%s+(.*)$")
      content[#content + 1] = {
        type = "heading",
        attrs = { level = math.min(#hashes, 6) },
        content = inline(rest),
      }
      i = i + 1
    elseif line:match("^%-%-%-+%s*$") then
      flush()
      content[#content + 1] = { type = "rule" }
      i = i + 1
    elseif line:match("^%s*[-*]%s+") then
      flush()
      content[#content + 1], i = list_block(lines, i, "^%s*[-*]%s+", "bulletList")
    elseif line:match("^%s*%d+[.)]%s+") then
      flush()
      content[#content + 1], i = list_block(lines, i, "^%s*%d+[.)]%s+", "orderedList")
    elseif line:match("^%s*$") then
      flush()
      i = i + 1
    else
      para[#para + 1] = line
      i = i + 1
    end
  end
  flush()
  return { type = "doc", version = 1, content = content }
end

return M
