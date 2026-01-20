local nvlsp = require "nvchad.configs.lspconfig"

nvlsp.defaults()

local servers = {
  "cssls",
  "html",
  "eslint",
  "ts_ls",
}

-- lsps with default config
for _, lsp in ipairs(servers) do
  vim.lsp.config(lsp, {
    on_attach = nvlsp.on_attach,
    on_init = nvlsp.on_init,
    capabilities = nvlsp.capabilities,
  })
end

vim.lsp.enable(servers)
-- read :h vim.lsp.config for changing options of lsp servers
