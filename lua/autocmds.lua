local autocmd = vim.api.nvim_create_autocmd

local function preserve_diff_syntax()
  local groups = { "DiffAdd", "DiffChange", "DiffDelete", "DiffText" }

  for _, group in ipairs(groups) do
    local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = group, link = false })
    if ok and type(hl) == "table" and next(hl) ~= nil then
      local updated = {}
      for key, value in pairs(hl) do
        if key ~= "fg" and key ~= "ctermfg" then
          updated[key] = value
        end
      end
      updated.nocombine = false
      vim.api.nvim_set_hl(0, group, updated)
    end
  end
end

-- user event that loads after UIEnter + only if file buf is there
autocmd({ "UIEnter", "BufReadPost", "BufNewFile" }, {
  group = vim.api.nvim_create_augroup("NvFilePost", { clear = true }),
  callback = function(args)
    local file = vim.api.nvim_buf_get_name(args.buf)
    local buftype = vim.api.nvim_get_option_value("buftype", { buf = args.buf })

    if not vim.g.ui_entered and args.event == "UIEnter" then
      vim.g.ui_entered = true
    end

    if file ~= "" and buftype ~= "nofile" and vim.g.ui_entered then
      vim.api.nvim_exec_autocmds("User", { pattern = "FilePost", modeline = false })
      vim.api.nvim_del_augroup_by_name "NvFilePost"

      vim.schedule(function()
        vim.api.nvim_exec_autocmds("FileType", {})

        if vim.g.editorconfig then
          require("editorconfig").config(args.buf)
        end
      end)
    end
  end,
})

vim.api.nvim_create_autocmd("FileType", {
  pattern = "*",
  callback = function()
    pcall(vim.treesitter.start)
  end,
})

local create_cmd = vim.api.nvim_create_user_command

create_cmd("TSInstallAll", function()
  local spec = require("lazy.core.config").plugins["nvim-treesitter"]
  local opts = type(spec.opts) == "table" and spec.opts or {}
  require("nvim-treesitter").install(opts.ensure_installed)
end, {})

vim.api.nvim_create_autocmd("BufWritePre", {
  pattern = "*",
  callback = function(args)
    require("conform").format { bufnr = args.buf }
  end,
})

vim.api.nvim_create_autocmd("VimEnter", {
  group = vim.api.nvim_create_augroup("NvimTreeOnDirectory", { clear = true }),
  callback = function()
    if vim.fn.argc() ~= 1 then
      return
    end

    local arg = vim.fn.argv(0)
    if not arg or arg == "" then
      return
    end

    local path = vim.fn.fnamemodify(arg, ":p")
    if vim.fn.isdirectory(path) ~= 1 then
      return
    end

    vim.api.nvim_set_current_dir(path)
    vim.schedule(function()
      vim.cmd("silent! NvimTreeFocus")
    end)
  end,
})

vim.api.nvim_create_autocmd({ "VimEnter", "ColorScheme" }, {
  group = vim.api.nvim_create_augroup("DiffSyntaxPreserve", { clear = true }),
  callback = preserve_diff_syntax,
})

-- require("custom.project_diagnostics").setup()
