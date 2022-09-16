local Job = require 'plenary.job'

local function join(tbl, sep)
  local ret = ''
  for _, v in pairs(tbl) do
    ret = ret .. v .. sep
  end
  return string.sub(ret, 1, #ret - #sep)
end

local function formatKube(kind, json)
  local output = ''
  if kind == 'pods' then
    output = string.format('%s %s %s %s', json.metadata.name, json.metadata.namespace, json.spec.nodeName, json.status.phase)
  elseif kind == 'nodes' then
    local reason = ''
    for _, v in pairs(json.status.conditions) do
      reason = string.format('%s %s', reason, v.reason)
    end
    output = string.format('%s %s', json.metadata.name, reason)
  else
    output = string.format('%s %s', json.metadata.name, json.metadata.namespace)
  end

  return output
end

local function parseLine(line)
  local kind = {}
  local and_filter = {}
  local or_filter = {}
  for _, v in pairs(vim.split(line, ' ', {trimempty=true})) do
    if v:sub(1, 1) == '@' then
      kind[#kind+1] = v:sub(2, #v)
    elseif v:sub(1, 1) == '&' then
      and_filter[#and_filter+1] = v:sub(2, #v)
    elseif v:sub(1, 1) == '#' then
      or_filter[#or_filter+1] = v:sub(2, #v)
    end
  end
  return {
      kind = kind,
      filter = and_filter,
  }
end

local function KubeList(line ,opts)
  vim.cmd('set filetype=kubelist')
  if opts == nil then
    opts = {
      update_buffer = true
    }
  end
  if line == nil then
    line = vim.api.nvim_get_current_line()
    print(line)
  end
  local tmp = parseLine(line)
  local kinds = tmp.kind
  if kinds == nil or #kinds == 0 then
    return
  end
  local buf_handle = vim.api.nvim_win_get_buf(0)
  local buf_var = vim.b[buf_handle]
  if buf_var.rev == nil then
    buf_var.rev = { nontmpty = true}
  end
  if buf_var['job'] == nil then
    buf_var['job'] = {count = 0}
  end
  local result = vim.fn.searchpos('--- output ---')
  if opts.update_buffer == true then
    if result[1] ~= 0 then
      vim.defer_fn(function()
        vim.cmd('silent ' .. (result[1]) .. ',$d')
        vim.fn.appendbufline(buf_handle, '$', '--- output ---')
      end, 10)
    else
      vim.fn.appendbufline(buf_handle, '$', '--- output ---')
    end
  end
  for i = 1, #kinds do
    local kind = kinds[i]
    buf_var.job.count = buf_var.job.count + 1
    Job:new({
      command = 'kubectl',
      args = { 'get', kind, '-A', '-o', 'json' },
      env = {},
      on_exit = function(j, return_val)
        vim.defer_fn(function()
          if return_val ~= 0 then
            vim.fn.appendbufline(buf_handle, '$', j:result())
            return
          end
          local data = vim.json.decode(join(j:result(), ''))
          local lines = {kind}
          for _, v in pairs(data.items) do
            line = formatKube(kind, v)
            local matched = true
            for _, vv in pairs(tmp.filter) do
              if line:find(vv) == nil then
                matched = false
              end
            end
            if matched then
              lines[#lines + 1] = line
              buf_var[v.metadata.name] = v
            end
          end
          if opts.update_buffer == true then
            vim.api.nvim_buf_set_lines(buf_handle, -1, -1, false, lines)
          end
          buf_var.job.count = buf_var.job.count - 1
          end, 100)
      end,
    }):start()
  end
  vim.wait(100)
end

local function kubeAction(action, template)
  if template == nil then
    template = 'kubectl %s -n %s %s/%s'
  end
  local current_line = vim.api.nvim_get_current_line()
  local parts = vim.split(current_line, ' ', {trimempty=true})
  local name = parts[1]

  local buf_handle = vim.api.nvim_win_get_buf(0)
  local buf_var = vim.b[buf_handle]
  local json = buf_var[name]
  if json == nil then
    local first_line = vim.api.nvim_buf_get_lines(buf_handle, 0, 1, false)[1]
    KubeList(first_line, {update_buffer=false})
    vim.wait(2000, function()
      if buf_var.job.count == 0 and buf_var[name] ~= nil then
        return true
      end
      return false
    end, 500)
    json = buf_var[name]
  end
  local namespace = json.metadata.namespace
  local kind = json.kind
  vim.cmd("terminal " .. string.format(template, action,namespace, kind, name))
end
M = {
  kubeList = KubeList,
  kubeDescribe = function()kubeAction('describe') end,
  kubeLogs = function()kubeAction('logs') end,
  kubeEdit = function()kubeAction('edit') end,
  kubeExec = function()kubeAction('exec', 'kubectl %s -it -n %s %s/%s -- sh') end,
  kubeAction = kubeAction,
  join = join,
}

return M
