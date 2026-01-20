function setup()
  local harpoon = require "harpoon"
  -- REQUIRED
  harpoon:setup()
  -- REQUIRED

  vim.keymap.set("n", "<leader>a", function()
    harpoon:list():add()
  end, { desc = "Harpoon - Add to List" })

  vim.keymap.set("n", "<C-e>", function()
    harpoon.ui:toggle_quick_menu(harpoon:list())
  end, { desc = "Harpoon - Toggle Quick Menu" })

  vim.keymap.set("n", "<C-h>", function()
    harpoon:list():select(1)
  end, { desc = "Harpoon - Select 1" })

  vim.keymap.set("n", "<C-t>", function()
    harpoon:list():select(2)
  end, { desc = "Harpoon - Select 2" })

  vim.keymap.set("n", "<C-n>", function()
    harpoon:list():select(3)
  end, { desc = "Harpoon - Select 3" })

  vim.keymap.set("n", "<C-s>", function()
    harpoon:list():select(4)
  end, { desc = "Harpoon - Select 4" })

  -- Toggle previous & next buffers stored within Harpoon list
  vim.keymap.set("n", "<C-S-P>", function()
    harpoon:list():prev()
  end, { desc = "Harpoon - Toggle Prev Buffer" })

  vim.keymap.set("n", "<C-S-N>", function()
    harpoon:list():next()
  end, { desc = "Harpoon - Toggle Next Buffer" })
end

local M = {}
M.setup = setup

return M
