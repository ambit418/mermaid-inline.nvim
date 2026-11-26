local M = {}

local config = {
  cmd = { "mmdflux" },
  timeout_ms = 5000,
  conceal = true,
}

local ns = vim.api.nvim_create_namespace("mermaid-inline")
local ns_conceal = vim.api.nvim_create_namespace("mermaid-inline-conceal")
local ns_diag = vim.api.nvim_create_namespace("mermaid-inline-diagnostic")

-- mermaid source -> { lines = {...} } | { err = "...", line = n }
local cache = {}
-- buf -> { gen, blocks, tick, transient, revealed, edit_seq }
local state = {}
local warned_missing = false

local redraw_delay_ms = 150

local query = nil

local function find_blocks(buf)
  local ok, parser = pcall(vim.treesitter.get_parser, buf, "markdown")
  if not ok or not parser then
    return {}
  end
  query = query or vim.treesitter.query.parse("markdown", [[
    (fenced_code_block (info_string (language) @lang)) @block
  ]])

  local blocks = {}
  local tree = parser:parse()[1]
  for _, match in query:iter_matches(tree:root(), buf, 0, -1) do
    local lang_node, block_node
    for id, nodes in pairs(match) do
      if query.captures[id] == "lang" then
        lang_node = nodes[1]
      else
        block_node = nodes[1]
      end
    end

    if lang_node and vim.treesitter.get_node_text(lang_node, buf) == "mermaid" then
      local delims = {}
      for child in block_node:iter_children() do
        if child:type() == "fenced_code_block_delimiter" then
          table.insert(delims, (child:range()))
        end
      end
      -- Skip unclosed blocks; they are still being edited
      if #delims == 2 then
        local start_row, end_row = delims[1], delims[2]
        local lines = vim.api.nvim_buf_get_lines(buf, start_row + 1, end_row, false)
        -- virt_lines below the last buffer line cannot be scrolled into view, so attach below the line before the block
        local below_prev = start_row > 0
        table.insert(blocks, {
          start_row = start_row,
          end_row = end_row,
          below_prev = below_prev,
          anchor_row = below_prev and start_row - 1 or start_row,
          source = table.concat(lines, "\n"),
        })
      end
    end
  end
  return blocks
end

local function parse_result(res)
  if res.code == 0 then
    local out = (res.stdout or ""):gsub("%s+$", "")
    return { lines = vim.split(out, "\n") }
  end
  if res.signal ~= 0 then
    return { err = ("timed out after %dms"):format(config.timeout_ms), transient = true }
  end
  local stderr = res.stderr or ""
  local msg = stderr:match("Error: ([^\n]+)") or vim.trim(stderr)
  return { err = msg, line = tonumber(msg:match("line (%d+)")) }
end

-- Row positions go stale once the buffer is edited, so rescan before using them. Returns true if rescanned
local function refresh_blocks(buf, st)
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  if st.tick == tick then
    return false
  end
  st.blocks = find_blocks(buf)
  st.tick = tick
  return true
end

local function result_for(st, block)
  return cache[block.source] or st.transient[block.source]
end

local function text_width(buf)
  local win = vim.fn.bufwinid(buf)
  if win == -1 then
    return nil
  end
  local info = vim.fn.getwininfo(win)[1]
  return info.width - info.textoff
end

local function truncate(line, max)
  local out, width = {}, 0
  for _, ch in ipairs(vim.fn.split(line, "\\zs")) do
    local w = vim.fn.strdisplaywidth(ch)
    if width + w > max then
      break
    end
    table.insert(out, ch)
    width = width + w
  end
  return table.concat(out)
end

local function max_width(lines)
  local max = 0
  for _, l in ipairs(lines) do
    max = math.max(max, vim.fn.strdisplaywidth(l))
  end
  return max
end

local function block_at(st, row)
  for i, b in ipairs(st.blocks) do
    if row >= b.start_row and row <= b.end_row then
      return i
    end
  end
end

local draw

local function update_conceal(buf, force)
  local st = state[buf]
  if not st then
    return
  end
  if refresh_blocks(buf, st) then
    -- Diagrams must move along with the blocks; draw() calls back here afterwards
    draw(buf)
    return
  end

  local cur = -1
  if buf == vim.api.nvim_get_current_buf() then
    cur = vim.api.nvim_win_get_cursor(0)[1] - 1
  end
  local revealed = block_at(st, cur) or 0
  if not force and revealed == st.revealed then
    return
  end
  st.revealed = revealed

  vim.api.nvim_buf_clear_namespace(buf, ns_conceal, 0, -1)
  if not config.conceal then
    return
  end

  for i, b in ipairs(st.blocks) do
    local r = result_for(st, b)
    -- Keep failed blocks visible so their diagnostics can be seen
    if i ~= revealed and r and r.lines then
      -- When the diagram is attached above the opening fence, concealing that fence would hide the diagram too
      local first = b.below_prev and b.start_row or b.start_row + 1
      for row = first, b.end_row do
        vim.api.nvim_buf_set_extmark(buf, ns_conceal, row, 0, { conceal_lines = "" })
      end
    end
  end
end

function draw(buf)
  local st = state[buf]
  if not st or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  refresh_blocks(buf, st)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)

  local avail = text_width(buf)
  local diags = {}

  for _, b in ipairs(st.blocks) do
    local r = result_for(st, b)
    if r and r.lines then
      local width = max_width(r.lines)
      local too_wide = avail and width > avail

      local virt = {}
      if too_wide then
        local hint = ("⇲ width %d > %d: :MermaidInlineOpen to view all"):format(width, avail)
        table.insert(virt, { { hint, "MermaidInlineHint" } })
      end
      for _, l in ipairs(r.lines) do
        if too_wide and vim.fn.strdisplaywidth(l) > avail then
          l = truncate(l, avail - 1) .. "…"
        end
        table.insert(virt, { { l, "MermaidInline" } })
      end

      vim.api.nvim_buf_set_extmark(buf, ns, b.anchor_row, 0, {
        virt_lines = virt,
        virt_lines_above = not b.below_prev,
      })
    elseif r and r.err then
      table.insert(diags, {
        lnum = r.line and b.start_row + r.line or b.start_row,
        col = 0,
        severity = vim.diagnostic.severity.ERROR,
        source = "mermaid-inline",
        message = r.err,
      })
    end
  end

  vim.diagnostic.set(ns_diag, buf, diags)
  update_conceal(buf, true)
end

function M.render(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  if vim.fn.executable(config.cmd[1]) == 0 then
    if not warned_missing then
      warned_missing = true
      vim.notify(("mermaid-inline: `%s` not found in PATH"):format(config.cmd[1]), vim.log.levels.WARN)
    end
    return
  end

  local st = state[buf] or { gen = 0 }
  state[buf] = st
  st.gen = st.gen + 1
  st.tick = nil
  refresh_blocks(buf, st)
  st.transient = {}
  local gen = st.gen

  for _, b in ipairs(st.blocks) do
    if not cache[b.source] then
      vim.system(config.cmd, { stdin = b.source, text = true, timeout = config.timeout_ms }, function(res)
        vim.schedule(function()
          local r = parse_result(res)
          if r.transient then
            st.transient[b.source] = r
          else
            cache[b.source] = r
          end
          -- Drop stale results if a newer render started meanwhile
          if state[buf] == st and st.gen == gen then
            draw(buf)
          end
        end)
      end)
    end
  end

  draw(buf)
end

function M.open()
  local buf = vim.api.nvim_get_current_buf()
  local st = state[buf]
  if st then
    refresh_blocks(buf, st)
  end
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  local lines
  for _, b in ipairs(st and st.blocks or {}) do
    if (row >= b.start_row and row <= b.end_row) or row == b.anchor_row then
      local r = result_for(st, b)
      lines = r and r.lines
      break
    end
  end
  if not lines then
    vim.notify("mermaid-inline: no rendered diagram at cursor", vim.log.levels.INFO)
    return
  end

  local fbuf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(fbuf, 0, -1, false, lines)
  vim.bo[fbuf].modifiable = false
  vim.bo[fbuf].bufhidden = "wipe"

  local width = math.min(max_width(lines), vim.o.columns - 4)
  local height = math.min(#lines, vim.o.lines - 4)
  local win = vim.api.nvim_open_win(fbuf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
  })
  vim.wo[win].wrap = false
  vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = fbuf, nowait = true })
end

function M.setup(opts)
  config = vim.tbl_deep_extend("force", config, opts or {})

  vim.api.nvim_set_hl(0, "MermaidInline", { default = true, link = "Normal" })
  vim.api.nvim_set_hl(0, "MermaidInlineHint", { default = true, link = "Comment" })

  local group = vim.api.nvim_create_augroup("mermaid-inline", { clear = true })

  vim.api.nvim_create_autocmd({ "BufWinEnter", "BufWritePost" }, {
    group = group,
    callback = function(args)
      if vim.bo[args.buf].filetype == "markdown" then
        M.render(args.buf)
      end
    end,
  })

  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    group = group,
    callback = function(args)
      update_conceal(args.buf)
    end,
  })

  -- While editing, only move diagrams with their blocks using cached results; the renderer runs on save
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = group,
    callback = function(args)
      local st = state[args.buf]
      if not st then
        return
      end
      st.edit_seq = (st.edit_seq or 0) + 1
      local seq = st.edit_seq
      vim.defer_fn(function()
        if state[args.buf] == st and st.edit_seq == seq then
          draw(args.buf)
        end
      end, redraw_delay_ms)
    end,
  })

  -- On resize, only redo truncation; no need to rerun the renderer
  vim.api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
    group = group,
    callback = function()
      for buf in pairs(state) do
        draw(buf)
      end
    end,
  })

  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    callback = function(args)
      state[args.buf] = nil
    end,
  })

  vim.api.nvim_create_user_command("MermaidInlineRender", function()
    M.render()
  end, {})
  vim.api.nvim_create_user_command("MermaidInlineOpen", M.open, {})

  -- With lazy.nvim ft-loading, BufWinEnter for the first buffer fires before setup
  local buf = vim.api.nvim_get_current_buf()
  if vim.bo[buf].filetype == "markdown" then
    M.render(buf)
  end
end

return M
