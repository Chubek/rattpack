local M = { configured = false }
local options = {}
local filetypes = { 'rattscript', 'rattspec', 'rattpkg' }

local function root_directory(buffer)
  local filename = vim.api.nvim_buf_get_name(buffer)
  local directory = filename ~= '' and vim.fn.fnamemodify(filename, ':p:h') or vim.fn.getcwd()
  local fallback = directory
  while true do
    for _, marker in ipairs({ 'Rattspec', 'Rattspec.in', 'Rattpkg', 'Rattpkg.in', '.git' }) do
      if vim.fn.getftype(directory .. '/' .. marker) ~= '' then
        return directory
      end
    end
    local parent = vim.fn.fnamemodify(directory, ':h')
    if parent == directory then
      return fallback
    end
    directory = parent
  end
end

function M.start(buffer)
  buffer = buffer or vim.api.nvim_get_current_buf()
  if vim.fn.has('nvim-0.8') ~= 1 or not options.enabled or not vim.api.nvim_buf_is_valid(buffer)
      or vim.bo[buffer].buftype ~= '' or not vim.tbl_contains(filetypes, vim.bo[buffer].filetype) then
    return
  end
  if vim.fn.executable(options.cmd[1]) ~= 1 then
    return
  end
  return vim.lsp.start({
    name = 'ratt-language-server',
    cmd = options.cmd,
    root_dir = root_directory(buffer),
    on_attach = function(client, attached)
      if vim.bo[attached].omnifunc == 'ratt#Complete' or vim.bo[attached].omnifunc == '' then
        vim.bo[attached].omnifunc = 'v:lua.vim.lsp.omnifunc'
      end
      if options.on_attach then
        options.on_attach(client, attached)
      end
    end,
    capabilities = options.capabilities,
  }, { bufnr = buffer })
end

function M.setup(config)
  M.configured = true
  options = vim.tbl_deep_extend('force', {
    enabled = vim.g.ratt_lsp_enabled ~= 0,
    cmd = vim.g.ratt_lsp_command or { 'ratt-language-server', '--stdio' },
  }, config or {})
  local group = vim.api.nvim_create_augroup('ratt_language_server', { clear = true })
  vim.api.nvim_create_autocmd('FileType', {
    group = group,
    pattern = filetypes,
    callback = function(event) M.start(event.buf) end,
  })
  vim.schedule(function() M.start() end)
end

return M
