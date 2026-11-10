local util = Fyler.import('fyler.util')

local M = {}

local ns = vim.api.nvim_create_namespace('FylerSearch')

--- One-row prompt over the top of the finder window. The tree narrows to the
--- fuzzy matches as the text changes.
---@param finder fyler.Finder
function M.open(finder)
  if not util.window_is_valid(finder.win_id) then return end

  local cfg = finder.opts.search
  local buf_id = vim.api.nvim_create_buf(false, true)
  vim.bo[buf_id].bufhidden = 'wipe'
  vim.bo[buf_id].filetype = 'fyler_search'
  vim.api.nvim_buf_set_lines(buf_id, 0, -1, false, { finder.query })
  vim.api.nvim_buf_set_extmark(buf_id, ns, 0, 0, {
    virt_text = { { cfg.prompt, 'FylerSearchPrompt' } },
    virt_text_pos = 'inline',
    right_gravity = false,
  })

  -- Placed by screen position, which lands on the window's winbar when it has
  -- one, rather than on the first entry.
  local row, col = unpack(vim.fn.win_screenpos(finder.win_id))
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

  local function query() return vim.api.nvim_buf_get_lines(buf_id, 0, 1, false)[1] or '' end

  local function move(keys)
    return function()
      if not util.window_is_valid(finder.win_id) then return end
      vim.api.nvim_win_call(finder.win_id, function() vim.cmd.normal({ args = { keys }, bang = true }) end)
    end
  end

  -- Open the file under the tree's cursor and drop the search; on anything
  -- else keep the matches and hand focus to the tree.
  local function accept()
    timer:stop()
    if query() ~= finder.query then finder:set_query(query()) end
    local entry = Fyler.import('fyler.finder').parse_cursor_line(finder)
    close()
    if not entry or entry.type == 'directory' then return end

    local mapping = (finder.opts.mappings.n or {})['<CR>']
    finder:select(mapping and mapping.args or {})
    finder:set_query('')
    finder:follow({ target_path = entry.path })
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
  map('<C-n>', move('j'))
  map('<Down>', move('j'))
  map('<C-p>', move('k'))
  map('<Up>', move('k'))

  vim.api.nvim_create_autocmd({ 'TextChangedI', 'TextChanged' }, {
    buffer = buf_id,
    callback = function()
      timer:stop()
      timer:start(cfg.debounce_ms, 0, function()
        vim.schedule(function()
          if not closed then finder:set_query(query()) end
        end)
      end)
    end,
  })

  vim.api.nvim_create_autocmd('WinLeave', { buffer = buf_id, once = true, callback = vim.schedule_wrap(close) })
end

return M
