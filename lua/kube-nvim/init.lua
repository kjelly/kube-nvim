local Job = require 'plenary.job'

local function split(data, sep)
  local parts = vim.split(data, sep, {trimempty = true})
  parts = vim.tbl_filter(function(l)
    if #l == 0 then return false end
    return true
  end, parts)
  return parts
end

local function join(tbl, sep)
  local ret = ''
  for _, v in pairs(tbl) do ret = ret .. v .. sep end
  return string.sub(ret, 1, #ret - #sep)
end

local function formatKube(kind, json)
  local output = ''
  if kind == 'pods' then
    output = string.format('%s %s %s %s', json.metadata.name,
                           json.metadata.namespace, json.spec.nodeName,
                           json.status.phase)
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
  local args = {}
  for _, v in pairs(vim.split(line, ' ', {trimempty = true})) do
    if v:sub(1, 1) == '@' then
      kind[#kind + 1] = v:sub(2, #v)
    elseif v:sub(1, 1) == '&' then
      and_filter[#and_filter + 1] = v:sub(2, #v)
    elseif v:sub(1, 1) == '#' then
      or_filter[#or_filter + 1] = v:sub(2, #v)
    elseif v:sub(1, 5) == 'kind:' then
      kind[#kind + 1] = v:sub(6, #v)
    elseif v:sub(1, 8) == 'include:' then
      kind[#and_filter + 1] = v:sub(9, #v)
    elseif v:sub(1, 8) == 'exclude:' then
      kind[#or_filter + 1] = v:sub(9, #v)
    elseif v:sub(1, 2) == '--' then
      args[#args + 1] = v
    end

  end
  print(vim.inspect(args))
  return {kind = kind, filter = and_filter, args = args}
end

local function KubeList(line, opts)
  vim.cmd('set filetype=kubelist')
  if opts == nil then opts = {update_buffer = true, wide = true} end
  if line == nil then line = vim.api.nvim_get_current_line() end
  local tmp = parseLine(line)
  local kinds = tmp.kind
  if kinds == nil or #kinds == 0 then return end
  local buf_handle = vim.api.nvim_win_get_buf(0)
  local buf_var = vim.b[buf_handle]
  buf_var['kube-line'] = line
  buf_var['args'] = tmp.args
  if buf_var.rev == nil then buf_var.rev = {nontmpty = true} end
  if buf_var['job'] == nil then buf_var['job'] = {count = 0} end
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
    local args = {'get', kind, '-A'}
    if opts.wide then
      table.insert(args, '-o')
      table.insert(args, 'wide')
    end
    vim.list_extend(args, tmp.args)
    print(vim.inspect(args))
    Job:new({
      command = 'kubectl',
      args = args,
      on_exit = function(j, return_val)
        vim.defer_fn(function()
          if return_val ~= 0 then
            vim.fn.appendbufline(buf_handle, '$', j:result())
            vim.fn.appendbufline(buf_handle, '$', j:stderr_result())
            return
          end
          local data = j:result()
          local lines = {kind}
          buf_var[kind] = split(data[1], ' ')
          for index, v in pairs(data) do
            if index == 1 then
              lines[#lines + 1] = v
            else
              local matched = true
              for _, vv in pairs(tmp.filter) do
                if v:find(vv) == nil then matched = false end
              end
              if matched then lines[#lines + 1] = kind .. ' ' .. v end
            end
          end
          if #lines > 2 then
            lines[#lines + 1] = ""
            if opts.update_buffer == true then
              vim.api.nvim_buf_set_lines(buf_handle, -1, -1, false, lines)
            end
          end
          buf_var.job.count = buf_var.job.count - 1
        end, 100)
      end,
    }):start()
  end
  vim.wait(100)
end

local function parse_line_get_resource(line)
  local parts = split(line, ' ')
  local kind = parts[1]
  local namespace = ''
  local name = ''

  local buf_handle = vim.api.nvim_win_get_buf(0)
  local buf_var = vim.b[buf_handle]
  local no_namespace = true
  if buf_var[kind] == nil then
    no_namespace = #vim.tbl_filter(function(item)
      return kind:find(item) ~= nil
    end, {'node'}) > 0
  else
    no_namespace = not vim.tbl_contains(buf_var[kind], 'NAMESPACE')
  end

  if no_namespace then
    namespace = ''
    name = parts[2]
  else
    namespace = parts[2]
    name = parts[3]
  end
  return name, kind, namespace

end

local function kubeAction(action, template)
  local current_line = vim.api.nvim_get_current_line()
  local name, kind, namespace = parse_line_get_resource(current_line)
  if template == nil then
    template = 'kubectl '
    if namespace == '' then
      template = template .. '%s %s/%s'
    else
      template = template .. '%s -n %s %s/%s'
    end
  end

  if vim.b.args ~= nil then
    template = template:gsub("kubectl", "kubectl " .. join(vim.b.args, ' '))
  end

  if namespace == '' then
    vim.cmd("terminal " .. string.format(template, action, kind, name))
  else
    vim.cmd("terminal " ..
                string.format(template, action, namespace, kind, name))
  end
end

local function KubeRefresh()
  local line = vim.b['kube-line']
  if line == nil then return end
  KubeList(line)
end

local function KubeAutoRefreshLoop()
  if vim.b.auto == true then
    KubeRefresh()
    vim.defer_fn(KubeAutoRefreshLoop, 5000)
  end
end

local function KubeAutoRefreshToggle()
  if vim.b.auto == true then
    vim.b.auto = false
  else
    vim.b.auto = true
    KubeAutoRefreshLoop()
  end
end

M = {
  kubeList = KubeList,
  kubeDescribe = function() kubeAction('describe') end,
  kubeLogs = function() kubeAction('logs') end,
  kubeEdit = function() kubeAction('edit') end,
  kubeExec = function() kubeAction('exec', 'kubectl %s -it -n %s %s/%s -- sh') end,
  kubeRefresh = function() KubeRefresh() end,
  kubeRefreshToggle = function() KubeAutoRefreshToggle() end,
  kubeAction = kubeAction,
  join = join,
  setup = function(opts)
    vim.api
        .nvim_create_user_command("KubeList", function() M.kubeList() end, {})
    vim.api.nvim_create_user_command("KubeDescribe",
                                     function() M.kubeDescribe() end, {})
    vim.api
        .nvim_create_user_command("KubeLogs", function() M.kubeLogs() end, {})
    vim.api
        .nvim_create_user_command("KubeEdit", function() M.kubeEdit() end, {})
    vim.api
        .nvim_create_user_command("KubeExec", function() M.kubeExec() end, {})
    vim.api.nvim_create_user_command("KubeRefresh",
                                     function() M.kubeRefresh() end, {})
    vim.api.nvim_create_user_command("KubeRefreshToggle",
                                     function() M.kubeRefreshToggle() end, {})
  end,
}
return M
