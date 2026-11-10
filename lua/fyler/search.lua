local util = Fyler.import('fyler.util')

local M = {}

local ns = vim.api.nvim_create_namespace('FylerSearch')

--- One-row prompt over the top or the bottom of the finder window. The tree narrows to the
--- fuzzy matches as the text changes.
---@param finder fyler.Finder
function M.open(finder)
  if not util.window_is_valid(finder.win_id) then return end

  local cfg = finder.opts.search
  local buf_id = vim.api.nvim_create_buf(false, true)
  vim.bo[buf_id].bufhidden = 'wipe'
  vim.bo[buf_id].filetype = 'fyler_search'
  -- Completion plugins (blink.cmp, nvim-cmp) read this to stay out of a buffer.
  vim.b[buf_id].completion = false
  vim.api.nvim_buf_set_lines(buf_id, 0, -1, false, { finder.query })

  local function query() return vim.api.nvim_buf_get_lines(buf_id, 0, 1, false)[1] or '' end

  -- The prompt, then a hint of what is searched while the line is empty, or
  -- the number of matches at the right edge once it is not.
  local function decorate()
    if not vim.api.nvim_buf_is_valid(buf_id) then return end
    vim.api.nvim_buf_clear_namespace(buf_id, ns, 0, -1)
    vim.api.nvim_buf_set_extmark(buf_id, ns, 0, 0, {
      virt_text = { { cfg.prompt, 'FylerSearchPrompt' } },
      virt_text_pos = 'inline',
      right_gravity = false,
    })
    if query() == '' then
      local status = finder:status()
      local scope = status.view == 'files' and 'files' or status.titles[status.view]:lower()
      vim.api.nvim_buf_set_extmark(buf_id, ns, 0, 0, {
        virt_text = { { 'Search ' .. scope, 'FylerSearchHint' } },
        virt_text_pos = 'eol',
      })
    elseif query() == finder.query and finder.filter then
      vim.api.nvim_buf_set_extmark(buf_id, ns, 0, 0, {
        virt_text = { { tostring(finder.filter.count) .. ' ', 'FylerSearchCount' } },
        virt_text_pos = 'right_align',
      })
    end
  end
  decorate()

  -- Placed by screen position: the top row is the window's winbar when it
  -- has one, rather than the first entry; the bottom row is its last line.
  local row, col = unpack(vim.fn.win_screenpos(finder.win_id))
  if cfg.position == 'bottom' then
    local info = vim.fn.getwininfo(finder.win_id)[1]
    row = row + info.winbar + info.height - 1
  end
  local win_id = vim.api.nvim_open_win(buf_id, true, {
    relative = 'editor',
    row = row - 1,
    col = col - 1,
    width = vim.api.nvim_win_get_width(finder.win_id),
    height = 1,
    style = 'minimal',
    zindex = 60,
  })
  vim.wo[win_id].winhighlight = 'NormalFloat:FylerSearchInput'
  vim.cmd.startinsert({ bang = true })

  local timer = assert(vim.uv.new_timer())
  local closed = false

  local function close()
    if closed then return end
    closed = true
    timer:stop()
    timer:close()
    vim.cmd.stopinsert()
    pcall(vim.api.nvim_win_close, win_id, true)
    if util.window_is_valid(finder.win_id) then vim.api.nvim_set_current_win(finder.win_id) end
  end

  local function move(step)
    return function() finder:step_file(step) end
  end

  local function open_entry()
    local entry = Fyler.import('fyler.finder').parse_cursor_line(finder)
    close()
    if not entry or entry.type == 'directory' then return end

    local mapping = (finder.opts.mappings.n or {})['<CR>']
    finder:select(mapping and mapping.args or {})
    finder:set_query('')
    finder:follow({ target_path = entry.path })
  end

  -- Open the file under the tree's cursor and drop the search; on anything
  -- else keep the matches and hand focus to the tree.
  local function accept()
    timer:stop()
    if query() == finder.query then return open_entry() end
    -- The matches on screen are for older text: wait for the new ones, and
    -- for the cursor to reach the best of them.
    finder:set_query(
      query(),
      vim.schedule_wrap(function()
        if not closed then open_entry() end
      end)
    )
  end

  local function cancel()
    close()
    finder:set_query('')
  end

  local map = function(lhs, rhs) vim.keymap.set({ 'i', 'n' }, lhs, rhs, { buffer = buf_id, nowait = true }) end
  map('<CR>', accept)
  map('<Tab>', close)
  map('<Esc>', cancel)
  map('<C-c>', cancel)
  map('<C-n>', move(1))
  map('<Down>', move(1))
  map('<C-p>', move(-1))
  map('<Up>', move(-1))

  vim.api.nvim_create_autocmd({ 'TextChangedI', 'TextChanged' }, {
    buffer = buf_id,
    callback = function()
      decorate()
      timer:stop()
      timer:start(cfg.debounce_ms, 0, function()
        vim.schedule(function()
          if not closed then finder:set_query(query(), decorate) end
        end)
      end)
    end,
  })

  vim.api.nvim_create_autocmd('WinLeave', { buffer = buf_id, once = true, callback = vim.schedule_wrap(close) })
end

return M
