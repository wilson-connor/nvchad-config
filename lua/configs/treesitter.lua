pcall(function()
  dofile(vim.g.base46_cache .. "syntax")
  dofile(vim.g.base46_cache .. "treesitter")
end)

local M = {}

local languages = {
  "lua",
  "luadoc",
  "printf",
  "vim",
  "vimdoc",
  "javascript",
  "typescript",
  "rust",
  "tsx",
  "go",
  "json",
  "prisma",
}

M.setup = function()
  local treesitter = require "nvim-treesitter"
  treesitter.install(languages):wait(300000)

  treesitter.update(languages):wait(300000)
end
return M
