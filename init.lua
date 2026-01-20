vim.g.base46_cache = vim.fn.stdpath "data" .. "/base46/"
vim.g.mapleader = " "
vim.opt.guicursor = "n-v-c-i:block"
vim.g.loaded_netrw = 1
vim.g.loaded_netrwPlugin = 1

require "configs.lazy"

-- load theme
dofile(vim.g.base46_cache .. "defaults")
dofile(vim.g.base46_cache .. "statusline")

require "options"
require "autocmds"

vim.schedule(function()
  require "mappings"
end)
