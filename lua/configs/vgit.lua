local options = {
  keymaps = {
    ["n <C-k>"] = function()
      require("vgit").hunk_up()
    end,
    {
      mode = "n",
      key = "<C-j>",
      handler = "hunk_down",
      desc = "Go down in the direction of the hunk",
    },
    ["n <leader>gs"] = function()
      require("vgit").buffer_hunk_stage()
    end,
    ["n <leader>gr"] = function()
      require("vgit").buffer_hunk_reset()
    end,
    ["n <leader>gp"] = function()
      require("vgit").buffer_hunk_preview()
    end,
    ["n <leader>gb"] = "buffer_blame_preview",
    ["n <leader>gf"] = function()
      require("vgit").buffer_diff_preview()
    end,
    ["n <leader>gh"] = function()
      require("vgit").buffer_history_preview()
    end,
    ["n <leader>gu"] = function()
      require("vgit").buffer_reset()
    end,
    ["n <leader>gd"] = function()
      require("vgit").project_diff_preview()
    end,
  },
}

return options
