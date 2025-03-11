local M = {}

local uv = vim.uv

--- @class pack.Package
--- @field [1] string?
--- @field name string?
--- @field as string?
--- @field branch string?
--- @field dir string?
--- @field status pack.Status?
--- @field hash string?
--- @field pin boolean?
--- @field opt boolean?
--- @field build string? | function?
--- @field url string?

--- @enum pack.Status
M.status = {
  INSTALLED = 0,
  CLONED = 1,
  UPDATED = 2,
  REMOVED = 3,
  TO_INSTALL = 4,
  TO_MOVE = 5,
  TO_RECLONE = 6,
}

--- @private
--- Table of pgks loaded from the lockfile
--- @type pack.Package[]
local Lock = {}

--- @private
--- Table of pkgs loaded from the user configuration
--- @type pack.Package[]
local Packages = {}

--- @private
--- @type table<string, string>
local Path = {
  lock = vim.fs.joinpath(vim.fn.stdpath('state'), 'pack-lock.json'),
  log = vim.fs.joinpath(vim.fn.stdpath('log'), 'pack.log'),
  pack = vim.fs.joinpath(vim.fn.stdpath('data'), 'site', 'pack', 'packs'),
}

--- @class pack.Opts
---
--- (default: `false`)
--- @field opt boolean
---
--- (default: `https://github.com/%s.git`)
--- @field url_format string
---
--- (default: `{ "--depth=1", "--recurse-submodules", "--shallow-submodules", "--no-single-branch" }`)
--- @field clone_args string[]
---
--- (default: `{ "--tags", "--force", "--recurse-submodules", "--update-shallow" }`)
--- @field pull_args string[]
local Config = {
  -- Using '--tags --force' means conflicting tags will be synced with remote
  clone_args = { '--depth=1', '--recurse-submodules', '--shallow-submodules', '--no-single-branch' },
  opt = false,
  pull_args = { '--tags', '--force', '--recurse-submodules', '--update-shallow' },
  url_format = 'https://github.com/%s.git',
}

--- @enum Messages
local Messages = {
  install = { ok = 'Installed', err = 'Failed to install' },
  update = { ok = 'Updated', err = 'Failed to update', nop = '(up-to-date)' },
  remove = { ok = 'Removed', err = 'Failed to remove' },
  build = { ok = 'Built', err = 'Failed to build' },
}

--- @enum Filter
local Filter = {
  installed = function(p) return p.status ~= M.status.REMOVED and p.status ~= M.status.TO_INSTALL end,
  not_removed = function(p) return p.status ~= M.status.REMOVED end,
  removed = function(p) return p.status == M.status.REMOVED end,
  to_install = function(p) return p.status == M.status.TO_INSTALL end,
  to_update = function(p)
    return p.status ~= M.status.REMOVED and p.status ~= M.status.TO_INSTALL and not p.pin
  end,
  to_move = function(p) return p.status == M.status.TO_MOVE end,
  to_reclone = function(p) return p.status == M.status.TO_RECLONE end,
}

--- @param path string
--- @param flags uv.fs_open.flags
--- @param data string
local function file_write(path, flags, data)
  local err_msg = "Failed to %s '" .. path .. "'"
  local file = assert(uv.fs_open(path, flags, 0x1A4), err_msg:format('open'))
  assert(uv.fs_write(file, data), err_msg:format('write'))
  assert(uv.fs_close(file), err_msg:format('close'))
end

--- @param path string
--- @return string
local function file_read(path)
  local err_msg = "Failed to %s '" .. path .. "'"
  local file = assert(uv.fs_open(path, 'r', 0x1A4), err_msg:format('open'))
  local stat = assert(uv.fs_stat(path), err_msg:format('get stats for'))
  local data = assert(uv.fs_read(file, stat.size, 0), err_msg:format('read'))
  assert(uv.fs_close(file), err_msg:format('close'))
  return data
end

--- @return pack.Package
local function find_unlisted()
  local unlisted = {}
  for _, packdir in ipairs { 'start', 'opt' } do
    local path = vim.fs.joinpath(Path.pack, packdir)
    for name, type in vim.fs.dir(path) do
      if type == 'directory' and name ~= 'paq-nvim' then
        local dir = vim.fs.joinpath(path, name)
        local pkg = Packages[name]
        if not pkg or pkg.dir ~= dir then
          table.insert(unlisted, { name = name, dir = dir })
        end
      end
    end
  end
  return unlisted
end

--- @param dir string
--- @return string
local function get_git_hash(dir)
  local first_line = function(path)
    local data = file_read(path)
    return vim.split(data, '\n')[1]
  end
  local head_ref = first_line(vim.fs.joinpath(dir, '.git', 'HEAD'))
  return head_ref and first_line(vim.fs.joinpath(dir, '.git', head_ref:sub(6, -1)))
end

--- @param path string string to remove
--- @return boolean
local function rmdir(path)
  local ok = pcall(vim.fs.rm, path, { recursive = true })
  return ok
end

--- @param pkg pack.Package
--- @param prev_hash string
--- @param cur_hash string
local function log_update_changes(pkg, prev_hash, cur_hash)
  vim.system(
    { 'git', 'log', '--pretty=format:* %s', ('%s..%s'):format(prev_hash, cur_hash) },
    { cwd = pkg.dir, text = true },
    function(obj)
      if obj.code ~= 0 then
        local msg = ('\nFailed to execute git log into %q (code %d):\n%s\n'):format(
          pkg.dir,
          obj.code,
          obj.stderr
        )
        file_write(Path.log, 'a+', msg)
        return
      end
      local output = ('\n%s updated:\n%s\n'):format(pkg.name, obj.stdout)
      file_write(Path.log, 'a+', output)
    end
  )
end

--- @param name string
--- @param msg_op Messages
--- @param result string
--- @param n integer?
--- @param total integer?
local function report(name, msg_op, result, n, total)
  local count = n and (' [%d/%d]'):format(n, total) or ''
  vim.notify(
    ('Pack:%s %s %s'):format(count, msg_op[result], name),
    result == 'err' and vim.log.levels.ERROR or vim.log.levels.INFO
  )
end

--- Object to track result of operations (installs, updates, etc.)
--- @param total integer
--- @param callback function
--- @return function
local function new_counter(total, callback)
  local c = { ok = 0, err = 0, nop = 0 }
  return vim.schedule_wrap(function(name, msg_op, result)
    if c.ok + c.err + c.nop < total then
      c[result] = c[result] + 1
      if result ~= 'nop' then
        report(name, msg_op, result, c.ok + c.nop, total)
      end
    end

    if c.ok + c.err + c.nop == total then
      callback(c.ok, c.err, c.nop)
    end
  end)
end

local function lock_write()
  -- remove run key since can have a function in it, and
  -- json.encode doesn't support functions
  local pkgs = vim.deepcopy(Packages)
  for p, _ in pairs(pkgs) do
    pkgs[p].build = nil
  end
  local ok, result = pcall(vim.json.encode, pkgs)
  if not ok then
    error(result)
  end
  -- Ignore if fail
  pcall(file_write, Path.lock, 'w', result)
  Lock = Packages
end

local function lock_load()
  local exists, data = pcall(file_read, Path.lock)
  if exists then
    local ok, result = pcall(vim.json.decode, data)
    if ok then
      Lock = not vim.tbl_isempty(result) and result or Packages
      -- Repopulate 'build' key so 'vim.deep_equal' works
      for name, pkg in pairs(result) do
        pkg.build = Packages[name] and Packages[name].build or nil
      end
    end
  else
    lock_write()
    Lock = Packages
  end
end

--- @param pkg pack.Package
--- @param counter function
--- @param build_queue table
local function clone(pkg, counter, build_queue)
  local args = vim.list_extend({ 'git', 'clone', pkg.url }, Config.clone_args)
  if pkg.branch then
    vim.list_extend(args, { '-b', pkg.branch })
  end
  table.insert(args, pkg.dir)
  vim.system(args, {}, function(obj)
    local ok = obj.code == 0
    if ok then
      pkg.status = M.status.CLONED
      lock_write()
      if pkg.build then
        table.insert(build_queue, pkg)
      end
    end
    counter(pkg.name, Messages.install, ok and 'ok' or 'err')
  end)
end

--- @param pkg pack.Package
--- @param counter function
--- @param build_queue table
local function pull(pkg, counter, build_queue)
  local prev_hash = Lock[pkg.name] and Lock[pkg.name].hash or pkg.hash
  vim.system(vim.list_extend({ 'git', 'pull' }, Config.pull_args), { cwd = pkg.dir }, function(obj)
    if obj.code ~= 0 then
      counter(pkg.name, Messages.update, 'err')
      local errmsg = ('\nFailed to update %s:\n%s\n'):format(pkg.name, obj.stderr)
      file_write(Path.log, 'a+', errmsg)
      return
    end
    local cur_hash = get_git_hash(pkg.dir)
    -- It can happen that the user has deleted manually a directory.
    -- Thus the pkg.hash is left blank and we need to update it.
    if cur_hash == prev_hash or prev_hash == '' then
      pkg.hash = cur_hash
      counter(pkg.name, Messages.update, 'nop')
      return
    end
    log_update_changes(pkg, prev_hash or '', cur_hash)
    pkg.status, pkg.hash = M.status.UPDATED, cur_hash
    lock_write()
    counter(pkg.name, Messages.update, 'ok')
    if pkg.build then
      table.insert(build_queue, pkg)
    end
  end)
end

--- @param pkg pack.Package
--- @param counter function
--- @param build_queue table
local function clone_or_pull(pkg, counter, build_queue)
  if Filter.to_update(pkg) then
    pull(pkg, counter, build_queue)
  elseif Filter.to_install(pkg) then
    clone(pkg, counter, build_queue)
  end
end

--- Move package to wanted location.
--- @param src pack.Package
--- @param dst pack.Package
local function move(src, dst)
  local ok = uv.fs_rename(src.dir, dst.dir)
  if ok then
    dst.status = M.status.INSTALLED
    lock_write()
  end
end

--- @param pkg pack.Package
local function run_build(pkg)
  local t = type(pkg.build)
  if t == 'function' then
    ---@diagnostic disable-next-line: param-type-mismatch
    local ok = pcall(pkg.build)
    report(pkg.name, Messages.build, ok and 'ok' or 'err')
  elseif t == 'string' and pkg.build:sub(1, 1) == ':' then
    ---@diagnostic disable-next-line: param-type-mismatch
    local ok = pcall(vim.cmd, pkg.build)
    report(pkg.name, Messages.build, ok and 'ok' or 'err')
  elseif t == 'string' then
    local args = {}
    for word in pkg.build:gmatch('%S+') do
      table.insert(args, word)
    end
    vim.system(
      args,
      { cwd = pkg.dir },
      vim.schedule_wrap(
        function(obj) report(pkg.name, Messages.build, obj.code == 0 and 'ok' or 'err') end
      )
    )
  end
end

---@param pkg pack.Package
local function reclone(pkg, _, build_queue)
  local ok = rmdir(pkg.dir)
  if not ok then
    return
  end
  local args = vim.list_extend({ 'git', 'clone', pkg.url }, Config.clone_args)
  if pkg.branch then
    vim.list_extend(args, { '-b', pkg.branch })
  end
  table.insert(args, pkg.dir)
  vim.system(args, {}, function(obj)
    if obj.code == 0 then
      pkg.status = M.status.INSTALLED
      pkg.hash = get_git_hash(pkg.dir)
      lock_write()
      if pkg.build then
        table.insert(build_queue, pkg)
      end
    end
  end)
end

local function resolve(pkg, counter, build_queue)
  if Filter.to_move(pkg) then
    move(pkg, Packages[pkg.name])
  elseif Filter.to_reclone(pkg) then
    reclone(Packages[pkg.name], counter, build_queue)
  end
end

---@param pkg pack.Package
local function register(pkg)
  if type(pkg) == 'string' then
    ---@diagnostic disable-next-line: missing-fields
    pkg = { pkg }
  end

  local url = pkg.url
    or (pkg[1]:match('^https?://') and pkg[1]) -- [1] is a URL
    or string.format(Config.url_format, pkg[1]) -- [1] is a repository name

  local name = pkg.as or url:gsub('%.git$', ''):match('/([%w-_.]+)$') -- Infer name from `url`
  if not name then
    return vim.notify(' Paq: Failed to parse ' .. vim.inspect(pkg), vim.log.levels.ERROR)
  end
  local opt = pkg.opt or Config.opt and pkg.opt == nil
  local dir = vim.fs.joinpath(Path.pack, (opt and 'opt' or 'start'), name)
  local ok, hash = pcall(get_git_hash, dir)
  hash = ok and hash or ''

  Packages[name] = {
    name = name,
    branch = pkg.branch,
    dir = dir,
    status = uv.fs_stat(dir) and M.status.INSTALLED or M.status.TO_INSTALL,
    hash = hash,
    pin = pkg.pin,
    build = pkg.build,
    url = url,
  }
end

---@param pkg pack.Package
---@param counter function
local function remove(pkg, counter)
  local ok = rmdir(pkg.dir)
  counter(pkg.name, Messages.remove, ok and 'ok' or 'err')
  if not ok then
    return
  end
  Packages[pkg.name] = { name = pkg.name, status = M.status.REMOVED }
  lock_write()
end

---@alias Operation
---| '"install"'
---| '"update"'
---| '"remove"'
---| '"build"'
---| '"resolve"'
---| '"sync"'

---Boilerplate around operations (autocmds, counter initialization, etc.)
---@param op Operation
---@param fn function
---@param pkgs pack.Package[]
---@param silent boolean?
local function exe_op(op, fn, pkgs, silent)
  if vim.tbl_isempty(pkgs) then
    if not silent then
      vim.notify('Pack: Nothing to ' .. op)
    end

    vim.api.nvim_exec_autocmds('User', {
      pattern = 'PackDone' .. op:gsub('^%l', string.upper),
    })
    return
  end

  local build_queue = {}

  local function after(ok, err, nop)
    local summary = 'Pack: %s complete. %d ok; %d errors;' .. (nop > 0 and ' %d no-ops' or '')
    vim.notify(string.format(summary, op, ok, err, nop))
    vim.cmd('packloadall! | silent! helptags ALL')
    if #build_queue ~= 0 then
      exe_op('build', run_build, build_queue)
    end

    vim.api.nvim_exec_autocmds('User', {
      pattern = 'PackDone' .. op:gsub('^%l', string.upper),
    })

    -- This makes the logfile reload if there were changes while the job was running
    vim.cmd('silent! checktime ' .. vim.fn.fnameescape(Path.log))
  end

  local counter = new_counter(#pkgs, after)

  for _, pkg in ipairs(pkgs) do
    fn(pkg, counter, build_queue)
  end
end

local function calculate_diffs()
  local diffs = {}
  for name, lock_pkg in pairs(Lock) do
    local pack_pkg = Packages[name]
    if pack_pkg and Filter.not_removed(lock_pkg) and not vim.deep_equal(lock_pkg, pack_pkg) then
      for k, v in pairs {
        dir = M.status.TO_MOVE,
        branch = M.status.TO_RECLONE,
        url = M.status.TO_RECLONE,
      } do
        if lock_pkg[k] ~= pack_pkg[k] then
          lock_pkg.status = v
          table.insert(diffs, lock_pkg)
        end
      end
    end
  end
  return diffs
end

---@param opts pack.Opts? When omitted or `nil`, retrieve the current
---       configuration. Otherwise, a configuration table (see |pack.Opts|).
---@return pack.Opts? : Current pack config if {opts} is omitted.
function M.config(opts)
  vim.validate('opts', opts, 'table', true)

  if not opts then
    return vim.deepcopy(Config, true)
  end

  for k, v in pairs(opts) do
    Config[k] = v
  end
end

--- @param pkgs pack.Package[]
function M.register(pkgs)
  vim.validate('pkgs', pkgs, 'table', true)
  Package = {}
  vim.tbl_map(register, pkgs)
  lock_load()
  exe_op('resolve', resolve, calculate_diffs(), true)
end

function M.install() exe_op('install', clone, vim.tbl_filter(Filter.to_install, Packages)) end
function M.update() exe_op('update', pull, vim.tbl_filter(Filter.to_update, Packages)) end
function M.clean() exe_op('remove', remove, find_unlisted()) end

function M.sync()
  M.clean()
  exe_op('sync', clone_or_pull, vim.tbl_filter(Filter.not_removed, Packages))
end

---Queries paq's packages storage with predefined
---filters by passing one of the following strings:
--- - "installed"
--- - "to_install"
--- - "to_update"
---@param filter string
function M.query(filter)
  vim.validate('filter', filter, { 'function', 'string' }, true)

  if type(filter) == 'string' then
    local f = Filter[filter]
    if not f then
      error(string.format('No filter with name: %q', filter))
    end

    return vim.deepcopy(vim.tbl_filter(f, Packages), true)
  end

  return vim.deepcopy(vim.tbl_filter(filter, Packages), true)
end

for cmd_name, fn in pairs {
  PackClean = M.clean,
  PackInstall = M.install,
  PackSync = M.sync,
  PackUpdate = M.update,
} do
  vim.api.nvim_create_user_command(cmd_name, fn, { bar = true })
end

do
  vim.api.nvim_create_user_command('PackBuild', function(a) run_build(Packages[a.args]) end, {
    bar = true,
    nargs = 1,
    complete = function()
      return vim
        .iter(Packages)
        :map(function(name, pkg) return pkg.build and name or nil end)
        :totable()
    end,
  })

  vim.api.nvim_create_user_command('PackList', function()
    local installed = vim.tbl_filter(Filter.installed, Lock)
    local removed = vim.tbl_filter(Filter.removed, Lock)
    local sort_by_name = function(t)
      table.sort(t, function(a, b) return a.name < b.name end)
    end
    sort_by_name(installed)
    sort_by_name(removed)
    local markers = { '+', '*' }
    for header, pkgs in pairs {
      ['Installed packages:'] = installed,
      ['Recently removed:'] = removed,
    } do
      if #pkgs ~= 0 then
        print(header)
        for _, pkg in ipairs(pkgs) do
          print(' ', markers[pkg.status] or ' ', pkg.name)
        end
      end
    end
  end, { bar = true })

  vim.api.nvim_create_user_command('PackLogOpen', function()
    vim.cmd.split(vim.fn.fnameescape(Path.log))
    vim.cmd('silent! normal! Gzz')
  end, { bar = true })

  vim.api.nvim_create_user_command('PackLogClean', function()
    if pcall(vim.fs.rm, Path.log) then
      vim.notify('Pack: log file deleted')
    else
      vim.notify('Pack: error while deleting log file', vim.log.levels.ERROR)
    end
  end, { bar = true })
end

return M
