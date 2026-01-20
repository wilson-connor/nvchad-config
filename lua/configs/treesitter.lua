pcall(function()
  dofile(vim.g.base46_cache .. "syntax")
  dofile(vim.g.base46_cache .. "treesitter")
end)

return {
  auto_install = true,
  sync_install = true,
  ensure_installed = { "lua", "luadoc", "printf", "vim", "vimdoc", "javascript", "typescript", "tsx" },
}
