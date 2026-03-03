dofile(vim.g.base46_cache .. "git")

local function visual_range()
  local l1 = vim.fn.line "."
  local l2 = vim.fn.line "v"
  if l1 > l2 then
    l1, l2 = l2, l1
  end
  return { l1, l2 }
end

local function has_signs_in_range(bufnr, group, first, last)
  local placed = vim.fn.sign_getplaced(bufnr, { group = group })[1]
  if not placed or not placed.signs then
    return false
  end

  for _, sign in ipairs(placed.signs) do
    if sign.lnum >= first and sign.lnum <= last then
      return true
    end
  end

  return false
end

return {
  signs = {
    delete = { text = "󰍵" },
    changedelete = { text = "󱕖" },
  },
  on_attach = function(bufnr)
    local gs = require "gitsigns"

    local function sync_git_panel()
      vim.defer_fn(function()
        pcall(function()
          require("configs.nvimtree_git_panel").sync_from_git(vim.api.nvim_buf_get_name(bufnr))
        end)
      end, 120)
    end

    local function map(mode, lhs, rhs, desc)
      vim.keymap.set(mode, lhs, rhs, {
        buffer = bufnr,
        desc = desc,
        noremap = true,
        silent = true,
      })
    end

    map("n", "s", function()
      local line = vim.fn.line "."
      local has_unstaged = has_signs_in_range(bufnr, "gitsigns_signs_", line, line)
      if not has_unstaged then
        vim.notify("No unstaged hunk at cursor.", vim.log.levels.WARN, { title = "gitsigns" })
        return
      end
      gs.stage_hunk()
      sync_git_panel()
    end, "gitsigns: Stage hunk")

    map("n", "u", function()
      local line = vim.fn.line "."
      local has_staged = has_signs_in_range(bufnr, "gitsigns_signs_staged", line, line)
      if not has_staged then
        vim.notify("No staged hunk at cursor.", vim.log.levels.WARN, { title = "gitsigns" })
        return
      end

      local has_unstaged = has_signs_in_range(bufnr, "gitsigns_signs_", line, line)
      if has_unstaged then
        vim.notify(
          "Cursor line has staged and unstaged hunks. Move to a staged-only hunk to unstage.",
          vim.log.levels.WARN,
          { title = "gitsigns" }
        )
        return
      end

      -- gitsigns stage_hunk() on a staged hunk inverts it, effectively unstaging it.
      gs.stage_hunk()
      sync_git_panel()
    end, "gitsigns: Unstage hunk")

    map("x", "s", function()
      local range = visual_range()
      if not has_signs_in_range(bufnr, "gitsigns_signs_", range[1], range[2]) then
        vim.notify("No unstaged hunk in selection.", vim.log.levels.WARN, { title = "gitsigns" })
        return
      end
      gs.stage_hunk(range)
      sync_git_panel()
    end, "gitsigns: Stage selected lines")

    map("x", "u", function()
      local range = visual_range()
      local has_staged = has_signs_in_range(bufnr, "gitsigns_signs_staged", range[1], range[2])
      if not has_staged then
        vim.notify("No staged hunk in selection.", vim.log.levels.WARN, { title = "gitsigns" })
        return
      end

      local has_unstaged = has_signs_in_range(bufnr, "gitsigns_signs_", range[1], range[2])
      if has_unstaged then
        vim.notify(
          "Selection has staged and unstaged hunks. Narrow the selection to staged lines only.",
          vim.log.levels.WARN,
          { title = "gitsigns" }
        )
        return
      end

      -- gitsigns stage_hunk() on a staged hunk inverts it, effectively unstaging it.
      gs.stage_hunk(range)
      sync_git_panel()
    end, "gitsigns: Unstage selected lines")
  end,
}
