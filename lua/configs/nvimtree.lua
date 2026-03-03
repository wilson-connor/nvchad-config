dofile(vim.g.base46_cache .. "nvimtree")

local function on_attach(bufnr)
  local api = require "nvim-tree.api"
  local git_panel = require "configs.nvimtree_git_panel"

  api.map.on_attach.default(bufnr)
  vim.bo[bufnr].buflisted = false
  git_panel.prune_tabufline_buffers()

  local function opts(desc)
    return {
      buffer = bufnr,
      desc = desc,
      noremap = true,
      silent = true,
      nowait = true,
    }
  end

  for i = 1, 9 do
    local level = i
    vim.keymap.set("n", tostring(level), function()
      git_panel.set_width_level(level)
    end, opts("nvim-tree: Set width level " .. level))
  end

  vim.keymap.set("n", "gs", function()
    git_panel.toggle_source_control()
  end, opts("nvim-tree: Toggle source control panel"))

  vim.keymap.set("n", "gp", function()
    git_panel.toggle_pins()
  end, opts("nvim-tree: Toggle pinned files panel"))

  vim.keymap.set("n", "<Tab>", function()
    git_panel.cycle_tabufline("next")
  end, opts("nvim-tree: Next buffer"))

  vim.keymap.set("n", "<S-Tab>", function()
    git_panel.cycle_tabufline("prev")
  end, opts("nvim-tree: Previous buffer"))
end

return {
  filters = { dotfiles = false },
  disable_netrw = true,
  hijack_cursor = true,
  sync_root_with_cwd = true,
  on_attach = on_attach,
  update_focused_file = {
    enable = true,
    update_root = false,
  },
  view = {
    width = 40,
    preserve_window_proportions = true,
  },
  renderer = {
    root_folder_label = false,
    highlight_git = true,
    indent_markers = { enable = true },
    icons = {
      glyphs = {
        default = "󰈚",
        folder = {
          default = "",
          empty = "",
          empty_open = "",
          open = "",
          symlink = "",
        },
        git = { unmerged = "" },
      },
    },
  },
}
