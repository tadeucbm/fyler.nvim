local libpath = Fyler.import('fyler.lib.path')

---@class fyler.View
---@field title string|nil Label shown for the view, defaults to its name
---@field list (fun(finder: fyler.Finder, cb: fun(paths: string[]|nil)))|nil
---  Calls back with the absolute paths the view shows. A view without it
---  shows the whole tree.
---@field events string[]|nil Autocommand events after which the view lists again

local M = {}

---@type table<string, fyler.View>
local registry = {}

---@param name string
---@param view fyler.View
function M.register(name, view)
  registry[name] = view

  local group = vim.api.nvim_create_augroup('FylerView_' .. name, { clear = true })
  if not view.events then return end

  vim.api.nvim_create_autocmd(view.events, {
    group = group,
    desc = ('Refresh the "%s" view'):format(name),
    callback = vim.schedule_wrap(function()
      for _, tab_id in ipairs(vim.api.nvim_list_tabpages()) do
        for _, finder in ipairs(Fyler.import('fyler.finder').instances_list(tab_id)) do
          if finder.view == name then finder:reload() end
        end
      end
    end),
  })
end

---@param name string
---@return fyler.View|nil
function M.get(name) return registry[name] end

---@private
---@param cmd string[]
---@param cb fun(tokens: string[]|nil)
local function run(cmd, cb)
  local ok = pcall(
    vim.system,
    cmd,
    { text = true },
    vim.schedule_wrap(function(result)
      if result.code ~= 0 then return cb(nil) end
      local tokens = vim.split(result.stdout or '', '\0', { plain = true })
      if tokens[#tokens] == '' then table.remove(tokens) end
      cb(tokens)
    end)
  )
  if not ok then vim.schedule(function() cb(nil) end) end
end

---@private
---@param root string
---@param names string[]
---@return string[]
local function join_all(root, names)
  return vim.tbl_map(function(name) return libpath.do_join(root, name) end, names)
end

--- Every file below `root`: what Git tracks or leaves untracked, or what `fd`
--- or `rg` lists outside a repository.
---@param root string
---@param cb fun(paths: string[])
function M.list_files(root, cb)
  local commands = {
    { 'git', '-C', root, 'ls-files', '-co', '--exclude-standard', '-z' },
    { 'fd', '--type', 'f', '--hidden', '--exclude', '.git', '-0', '--base-directory', root },
    { 'rg', '--files', '--hidden', '--glob', '!.git', '-0', root },
  }

  local function try(i)
    if not commands[i] then return cb({}) end
    run(commands[i], function(names)
      if not names then return try(i + 1) end
      -- `rg` prints the paths below the directory it was given.
      cb(i == 3 and vim.tbl_map(libpath.to_normalize, names) or join_all(root, names))
    end)
  end

  try(1)
end

M.register('files', { title = 'Files' })

M.register('changes', {
  title = 'Changes',
  list = function(finder, cb)
    local root = finder.state.pseudo_root_path
    run({ 'git', '-C', root, 'rev-parse', '--show-toplevel' }, function(top)
      if not (top and top[1]) then return cb({}) end
      local toplevel = vim.trim(top[1])
      run({ 'git', '-C', root, 'status', '--porcelain', '-z', '-uall' }, function(tokens)
        local names = {}
        local i = 1
        while tokens and i <= #tokens do
          local xy, name = tokens[i]:sub(1, 2), tokens[i]:sub(4)
          names[#names + 1] = name
          -- A rename or copy is followed by the path it came from.
          if xy:find('[RC]') then i = i + 1 end
          i = i + 1
        end
        cb(join_all(toplevel, names))
      end)
    end)
  end,
})

M.register('buffers', {
  title = 'Buffers',
  events = { 'BufAdd', 'BufDelete' },
  list = function(_, cb)
    local paths = {}
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      local name = vim.api.nvim_buf_get_name(buf)
      if vim.bo[buf].buflisted and vim.bo[buf].buftype == '' and name ~= '' then paths[#paths + 1] = name end
    end
    cb(paths)
  end,
})

return M
