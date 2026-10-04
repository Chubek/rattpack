if vim.g.loaded_ratt_languages then
  return
end
vim.g.loaded_ratt_languages = true
if vim.fn.has('nvim-0.8') == 1 then
  local ratt = require('ratt')
  if not ratt.configured then
    ratt.setup()
  end
end
