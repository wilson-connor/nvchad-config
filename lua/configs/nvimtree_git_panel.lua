local M = {}

local PANEL_FILETYPE = "nvimtree-git-panel"
local PANEL_NAMESPACE = vim.api.nvim_create_namespace("NvimTreeGitPanel")
local PANEL_MODE = {
  GIT = "git",
  PINS = "pins",
}
local PINS_STORAGE_PATH = vim.fn.stdpath("state") .. "/nvimtree-git-panel-pins.json"
local DIFF_WIDTH_STEP = 10
local DIFF_MIN_WIDTH = 20

local state = {
  active = false,
  mode = PANEL_MODE.GIT,
  panel_buf = nil,
  panel_win = nil,
  editor_win = nil,
  diff_left_win = nil,
  diff_right_win = nil,
  diff_left_buf = nil,
  diff_right_buf = nil,
  diff_updating = false,
  diff_pair_autocmd = nil,
  git_change_autocmd = nil,
  current_diff_entry = nil,
  root = nil,
  width = 30,
  entries_by_line = {},
}

local has_devicons, devicons = pcall(require, "nvim-web-devicons")

local STATUS_SYMBOLS = {
  M = "~",
  A = "+",
  D = "-",
  R = ">",
  C = "=",
  U = "!",
  P = "*",
  ["?"] = "+",
}

local STATUS_HIGHLIGHTS = {
  M = "GitSignsChange",
  A = "GitSignsAdd",
  D = "GitSignsDelete",
  R = "GitSignsChange",
  C = "GitSignsChange",
  U = "DiagnosticError",
  P = "NvimTreeGitPanelHint",
  ["?"] = "GitSignsAdd",
}

local pinned = {
  loaded = false,
  by_root = {},
}

local function win_is_valid(winid)
  return winid and winid ~= 0 and vim.api.nvim_win_is_valid(winid)
end

local function is_sidebar_filetype(ft)
  return ft == PANEL_FILETYPE or ft == "NvimTree"
end

local function is_sidebar_buffer(bufnr)
  if not bufnr or bufnr == 0 or not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end
  return is_sidebar_filetype(vim.bo[bufnr].filetype)
end

local function win_in_current_tab(winid)
  if not win_is_valid(winid) then
    return false
  end
  return vim.api.nvim_win_get_tabpage(winid) == vim.api.nvim_get_current_tabpage()
end

local function buf_is_valid(bufnr)
  return bufnr and bufnr ~= 0 and vim.api.nvim_buf_is_valid(bufnr)
end

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "nvim-tree git panel" })
end

local function get_cwd()
  return (vim.uv and vim.uv.cwd()) or vim.loop.cwd() or vim.fn.getcwd()
end

local function normalize_mode(mode)
  return mode == PANEL_MODE.PINS and PANEL_MODE.PINS or PANEL_MODE.GIT
end

local function normalize_path(path)
  if not path or path == "" then
    return ""
  end
  local normalized = path:gsub("\\", "/")
  if normalized == "/" or normalized:match("^%a:/$") then
    return normalized
  end
  return normalized:gsub("/+$", "")
end

local function path_is_absolute(path)
  if not path or path == "" then
    return false
  end
  return path:sub(1, 1) == "/" or path:match("^%a:[/\\]")
end

local function json_decode(raw)
  if vim.json and vim.json.decode then
    return vim.json.decode(raw)
  end
  return vim.fn.json_decode(raw)
end

local function json_encode(value)
  if vim.json and vim.json.encode then
    return vim.json.encode(value)
  end
  return vim.fn.json_encode(value)
end

local function load_pins()
  if pinned.loaded then
    return
  end
  pinned.loaded = true
  pinned.by_root = {}

  if vim.fn.filereadable(PINS_STORAGE_PATH) ~= 1 then
    return
  end

  local raw = table.concat(vim.fn.readfile(PINS_STORAGE_PATH), "\n")
  if raw == "" then
    return
  end

  local ok, decoded = pcall(json_decode, raw)
  if not ok or type(decoded) ~= "table" then
    return
  end

  for root, paths in pairs(decoded) do
    if type(root) == "string" and type(paths) == "table" then
      local normalized_root = normalize_path(root)
      if normalized_root ~= "" then
        pinned.by_root[normalized_root] = {}
        for rel_path, is_on in pairs(paths) do
          if is_on and type(rel_path) == "string" and rel_path ~= "" then
            pinned.by_root[normalized_root][normalize_path(rel_path)] = true
          end
        end
      end
    end
  end
end

local function save_pins()
  local dir = vim.fn.fnamemodify(PINS_STORAGE_PATH, ":h")
  vim.fn.mkdir(dir, "p")
  local ok, payload = pcall(json_encode, pinned.by_root)
  if not ok then
    return false
  end
  return vim.fn.writefile({ payload }, PINS_STORAGE_PATH) == 0
end

local function get_root_pins(root)
  load_pins()
  local normalized_root = normalize_path(root)
  if normalized_root == "" then
    return nil, nil
  end
  pinned.by_root[normalized_root] = pinned.by_root[normalized_root] or {}
  return pinned.by_root[normalized_root], normalized_root
end

local function path_relative_to_root(path, root)
  local abs = normalize_path(vim.fn.fnamemodify(path, ":p"))
  local normalized_root = normalize_path(root)
  if abs == "" or normalized_root == "" then
    return nil
  end
  if abs == normalized_root then
    return "."
  end
  local prefix = normalized_root .. "/"
  if abs:sub(1, #prefix) ~= prefix then
    return nil
  end
  return abs:sub(#prefix + 1)
end

local function get_root_for_file(path)
  local abs = vim.fn.fnamemodify(path, ":p")
  local base_dir = vim.fn.fnamemodify(abs, ":h")
  local output = vim.fn.systemlist({ "git", "-C", base_dir, "rev-parse", "--show-toplevel" })
  if vim.v.shell_error == 0 and output[1] and output[1] ~= "" then
    return normalize_path(output[1])
  end
  return normalize_path(get_cwd())
end

local function set_pin(root, rel_path, should_pin)
  local paths, normalized_root = get_root_pins(root)
  if not paths or not normalized_root then
    return nil
  end

  local normalized_rel = normalize_path(rel_path)
  if normalized_rel == "" or normalized_rel == "." then
    return nil
  end

  if should_pin then
    paths[normalized_rel] = true
  else
    paths[normalized_rel] = nil
  end

  if next(paths) == nil then
    pinned.by_root[normalized_root] = nil
  end

  if not save_pins() then
    notify("Failed to persist pinned files", vim.log.levels.WARN)
  end

  return should_pin
end

local function toggle_pin(root, rel_path)
  local paths = get_root_pins(root)
  if not paths then
    return nil
  end
  local normalized_rel = normalize_path(rel_path)
  if normalized_rel == "" or normalized_rel == "." then
    return nil
  end
  return set_pin(root, normalized_rel, not paths[normalized_rel])
end

local function collect_pinned_entries(root)
  local paths = get_root_pins(root)
  local entries = {}
  if not paths then
    return entries
  end

  for path, is_on in pairs(paths) do
    if is_on and path ~= "" then
      entries[#entries + 1] = {
        section = "pinned",
        status = "P",
        status_text = "PIN",
        path = path,
      }
    end
  end

  table.sort(entries, function(a, b)
    return a.path < b.path
  end)

  return entries
end

local function resolve_entry_path(root, path)
  if path_is_absolute(path) then
    return path
  end
  local normalized_root = normalize_path(root)
  if normalized_root == "" then
    return path
  end
  return normalized_root .. "/" .. path
end

local function prune_tabufline_buffers()
  if type(vim.t.bufs) ~= "table" then
    return
  end

  local kept = {}
  for _, bufnr in ipairs(vim.t.bufs) do
    if buf_is_valid(bufnr) and vim.bo[bufnr].buflisted and not is_sidebar_buffer(bufnr) then
      kept[#kept + 1] = bufnr
    end
  end
  vim.t.bufs = kept
  vim.cmd("redrawtabline")
end

local function ensure_highlights()
  vim.api.nvim_set_hl(0, "NvimTreeGitPanelTitle", { link = "NvimTreeFolderName" })
  vim.api.nvim_set_hl(0, "NvimTreeGitPanelRoot", { link = "NvimTreeRootFolder" })
  vim.api.nvim_set_hl(0, "NvimTreeGitPanelSection", { link = "NvimTreeOpenedFolderName" })
  vim.api.nvim_set_hl(0, "NvimTreeGitPanelHint", { link = "Comment" })
  vim.api.nvim_set_hl(0, "NvimTreeGitPanelPath", { link = "Comment" })
  vim.api.nvim_set_hl(0, "NvimTreeGitPanelPinnedFile", { link = "GitSignsAdd" })
end

local function ensure_diff_syntax_groups()
  local mapping = {
    DiffAdd = "NvimTreeGitDiffAdd",
    DiffChange = "NvimTreeGitDiffChange",
    DiffDelete = "NvimTreeGitDiffDelete",
    DiffText = "NvimTreeGitDiffText",
  }

  for source, target in pairs(mapping) do
    local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = source, link = false })
    if ok and type(hl) == "table" and next(hl) ~= nil then
      local updated = {}
      for key, value in pairs(hl) do
        if key ~= "fg" and key ~= "ctermfg" then
          updated[key] = value
        end
      end
      updated.nocombine = false
      vim.api.nvim_set_hl(0, target, updated)
    end
  end
end

local function apply_diff_winhl(winid)
  if not win_is_valid(winid) then
    return
  end

  ensure_diff_syntax_groups()
  vim.wo[winid].winhl = table.concat({
    "DiffAdd:NvimTreeGitDiffAdd",
    "DiffChange:NvimTreeGitDiffChange",
    "DiffDelete:NvimTreeGitDiffDelete",
    "DiffText:NvimTreeGitDiffText",
  }, ",")
  vim.wo[winid].wrap = true
  vim.wo[winid].linebreak = true
  vim.wo[winid].breakindent = true
end

local function get_default_tree_width()
  local api = require("nvim-tree.api")
  local user_cfg = api.config.user()
  if type(user_cfg) == "table" and type(user_cfg.view) == "table" and type(user_cfg.view.width) == "number" then
    return user_cfg.view.width
  end

  local global_cfg = api.config.global()
  if type(global_cfg) == "table" and type(global_cfg.view) == "table" and type(global_cfg.view.width) == "number" then
    return global_cfg.view.width
  end

  return 40
end

local function calc_width_level(level)
  local n = tonumber(level) or 1
  n = math.max(1, math.min(9, n))
  return get_default_tree_width() + ((n - 1) * 10)
end

local function run_git(root, args)
  local cmd = { "git", "-C", root }
  vim.list_extend(cmd, args)
  local output = vim.fn.systemlist(cmd)
  return vim.v.shell_error == 0, output
end

local function run_git_silent(root, args)
  local cmd = { "git", "-C", root }
  vim.list_extend(cmd, args)
  vim.fn.system(cmd)
  return vim.v.shell_error == 0
end

local function get_git_branch(root)
  local ok, output = run_git(root, { "rev-parse", "--abbrev-ref", "HEAD" })
  if not ok or not output[1] or output[1] == "" then
    return "detached"
  end
  return output[1]
end

local function get_git_root()
  local cwd = (vim.uv and vim.uv.cwd()) or vim.loop.cwd() or vim.fn.getcwd()
  local output = vim.fn.systemlist({ "git", "-C", cwd, "rev-parse", "--show-toplevel" })
  if vim.v.shell_error ~= 0 or not output[1] or output[1] == "" then
    return nil
  end
  return output[1]
end

local function get_git_root_for_path(path)
  local abs = vim.fn.fnamemodify(path, ":p")
  local base_dir = vim.fn.fnamemodify(abs, ":h")
  local output = vim.fn.systemlist({ "git", "-C", base_dir, "rev-parse", "--show-toplevel" })
  if vim.v.shell_error ~= 0 or not output[1] or output[1] == "" then
    return nil
  end
  return normalize_path(output[1])
end

local function parse_name_status(lines, section)
  local entries = {}
  local by_path = {}

  for _, line in ipairs(lines) do
    if line ~= "" then
      local parts = vim.split(line, "\t", { plain = true })
      local status_text = parts[1] or "M"
      local status = status_text:sub(1, 1)
      local path
      local old_path

      if status == "R" or status == "C" then
        old_path = parts[2]
        path = parts[3]
      else
        path = parts[2]
      end

      if path and path ~= "" then
        local entry = {
          section = section,
          status = status,
          status_text = status_text,
          path = path,
          old_path = old_path,
        }
        entries[#entries + 1] = entry
        by_path[path] = entry
      end
    end
  end

  return entries, by_path
end

local function truncate_path(path, max_width)
  if max_width <= 0 then
    return ""
  end

  if vim.fn.strdisplaywidth(path) <= max_width then
    return path
  end

  if max_width <= 3 then
    return path:sub(1, max_width)
  end

  local suffix_len = max_width - 3
  return "..." .. path:sub(-suffix_len)
end

local function truncate_right(text, max_width)
  if max_width <= 0 then
    return ""
  end

  if vim.fn.strdisplaywidth(text) <= max_width then
    return text
  end

  if max_width <= 3 then
    return text:sub(1, max_width)
  end

  return text:sub(1, max_width - 3) .. "..."
end

local function split_path(path)
  local dir, file = path:match("^(.*)/(.-)$")
  if not dir then
    return "", path
  end
  return dir, file
end

local function status_symbol(status)
  return STATUS_SYMBOLS[status] or status or "?"
end

local function status_hl(status)
  return STATUS_HIGHLIGHTS[status] or "Normal"
end

local function get_icon_for_path(path)
  if not has_devicons then
    return "f", nil
  end

  local icon, icon_hl = devicons.get_icon(path, nil, { default = true })
  return icon or "f", icon_hl
end

local function push_line(lines, text)
  lines[#lines + 1] = text
  return #lines - 1
end

local function byteidx(text, charidx)
  return vim.str_byteindex(text, charidx)
end

local render_panel

local function current_entry()
  local line = vim.api.nvim_win_get_cursor(0)[1]
  return state.entries_by_line[line], line
end

local function jump_to_entry(path, preferred_section, fallback_line)
  if not (win_is_valid(state.panel_win) and buf_is_valid(state.panel_buf)) then
    return
  end

  local target = fallback_line

  for line, entry in pairs(state.entries_by_line) do
    if entry.path == path and entry.section == preferred_section then
      target = line
      break
    end
  end

  if target == fallback_line then
    for line, entry in pairs(state.entries_by_line) do
      if entry.path == path then
        target = line
        break
      end
    end
  end

  local max_line = vim.api.nvim_buf_line_count(state.panel_buf)
  target = math.max(1, math.min(target, max_line))
  vim.api.nvim_win_set_cursor(state.panel_win, { target, 0 })
end

local function collect_entries(root)
  local ok_staged, staged_raw = run_git(root, { "diff", "--name-status", "--cached" })
  local ok_unstaged, unstaged_raw = run_git(root, { "diff", "--name-status" })
  local ok_untracked, untracked_raw = run_git(root, { "ls-files", "--others", "--exclude-standard" })

  if not ok_staged or not ok_unstaged or not ok_untracked then
    return nil, nil, "failed to query git status"
  end

  local staged = parse_name_status(staged_raw, "staged")
  local unstaged, unstaged_lookup = parse_name_status(unstaged_raw, "unstaged")

  for _, path in ipairs(untracked_raw) do
    if path ~= "" and not unstaged_lookup[path] then
      unstaged[#unstaged + 1] = {
        section = "unstaged",
        status = "?",
        status_text = "??",
        path = path,
      }
    end
  end

  table.sort(staged, function(a, b)
    return a.path < b.path
  end)
  table.sort(unstaged, function(a, b)
    return a.path < b.path
  end)

  return staged, unstaged
end

local function collect_entries_for_path(root, path, section)
  local entries = {}
  if section == "staged" then
    local ok, raw = run_git(root, { "diff", "--name-status", "--cached", "--", path })
    if not ok then
      return nil
    end
    entries = parse_name_status(raw, "staged")
    return entries[1]
  end

  local ok, raw = run_git(root, { "diff", "--name-status", "--", path })
  if not ok then
    return nil
  end
  entries = parse_name_status(raw, "unstaged")
  if entries[1] then
    return entries[1]
  end

  local ok_untracked, raw_untracked = run_git(root, { "ls-files", "--others", "--exclude-standard", "--", path })
  if not ok_untracked then
    return nil
  end
  for _, file in ipairs(raw_untracked) do
    if file == path then
      return {
        section = "unstaged",
        status = "?",
        status_text = "??",
        path = path,
      }
    end
  end

  return nil
end

local function has_unstaged_for_path(path)
  if not state.root or not path or path == "" then
    return false
  end

  local ok, output = run_git(state.root, { "diff", "--name-only", "--", path })
  if not ok then
    return false
  end

  return output[1] ~= nil
end

local function changed_path_matches(path, changed_file)
  if not changed_file or changed_file == "" then
    return true
  end
  if not state.root or not path or path == "" then
    return false
  end

  local changed = normalize_path(changed_file)
  local rel = normalize_path(path)
  local abs = normalize_path(state.root .. "/" .. path)

  if changed == rel or changed == abs then
    return true
  end

  local rel_suffix = "/" .. rel
  if #changed > #rel_suffix and changed:sub(-#rel_suffix) == rel_suffix then
    return true
  end

  return false
end

local function find_entry(entries, path, section)
  for _, entry in ipairs(entries) do
    if entry.path == path and (not section or entry.section == section) then
      return entry
    end
  end
end

local function find_current_diff_entry()
  local current = state.current_diff_entry
  if not current or not state.root then
    return nil
  end

  local staged, unstaged = collect_entries(state.root)
  if not staged then
    return nil
  end

  if current.section == "staged" then
    return find_entry(staged, current.path, "staged")
      or (current.old_path and find_entry(staged, current.old_path, "staged"))
  end

  return find_entry(unstaged, current.path, "unstaged")
    or (current.old_path and find_entry(unstaged, current.old_path, "unstaged"))
end

local function refresh_panel_preserve_selection()
  if not (state.active and win_is_valid(state.panel_win)) then
    return
  end

  local line = vim.api.nvim_win_get_cursor(state.panel_win)[1]
  local entry = state.entries_by_line[line]
  render_panel()

  if entry then
    jump_to_entry(entry.path, entry.section, line)
    return
  end

  local max_line = vim.api.nvim_buf_line_count(state.panel_buf)
  vim.api.nvim_win_set_cursor(state.panel_win, { math.max(1, math.min(line, max_line)), 0 })
end

local function mark_entries_with_pins(entries, root)
  local root_pins = get_root_pins(root)
  if not root_pins then
    return
  end

  for _, entry in ipairs(entries) do
    entry.is_pinned = root_pins[normalize_path(entry.path)] == true
  end
end

local function add_section(lines, line_map, highlights, title, entries, panel_width, opts)
  opts = opts or {}
  local highlight_pinned_name = opts.highlight_pinned_name == true

  local section_line = push_line(lines, string.format(" %s (%d)", title, #entries))
  highlights[#highlights + 1] = {
    group = "NvimTreeGitPanelSection",
    line = section_line,
    start_col = 0,
    end_col = -1,
  }

  if #entries == 0 then
    local empty_line = push_line(lines, "   (none)")
    highlights[#highlights + 1] = {
      group = "NvimTreeGitPanelHint",
      line = empty_line,
      start_col = 0,
      end_col = -1,
    }
    return
  end

  for _, entry in ipairs(entries) do
    local icon, icon_hl = get_icon_for_path(entry.path)
    local symbol = status_symbol(entry.status)
    local prefix = string.format("  %s %s ", symbol, icon)
    local available = math.max(8, panel_width - vim.fn.strdisplaywidth(prefix) - 1)
    local dir_path, file_name = split_path(entry.path)
    local relative_dir = dir_path ~= "" and dir_path or "."
    local display_name = truncate_right(file_name, available)
    local display_dir = ""

    local remaining = available - vim.fn.strdisplaywidth(display_name)
    if remaining >= 4 then
      local dir_width = remaining - 3 -- " (" + ")"
      display_dir = " (" .. truncate_path(relative_dir, dir_width) .. ")"
    end

    local line = prefix .. display_name .. display_dir

    local line_number = push_line(lines, line)
    line_map[line_number + 1] = entry

    local status_idx0 = 2
    highlights[#highlights + 1] = {
      group = status_hl(entry.status),
      line = line_number,
      start_col = byteidx(line, status_idx0),
      end_col = byteidx(line, status_idx0 + 1),
    }

    if icon_hl then
      local icon_idx0 = 4
      highlights[#highlights + 1] = {
        group = icon_hl,
        line = line_number,
        start_col = byteidx(line, icon_idx0),
        end_col = byteidx(line, icon_idx0 + 1),
      }
    end

    local name_start = line:find(display_name, #prefix + 1, true)
    if name_start then
      local name_col_start = name_start - 1
      highlights[#highlights + 1] = {
        group = (highlight_pinned_name and entry.is_pinned) and "NvimTreeGitPanelPinnedFile" or "NvimTreeFileName",
        line = line_number,
        start_col = name_col_start,
        end_col = name_col_start + #display_name,
      }
    end

    if display_dir ~= "" then
      local dir_start = line:find(display_dir, (#prefix + #display_name + 1), true)
      if dir_start then
        local dir_col_start = dir_start - 1
        highlights[#highlights + 1] = {
          group = "NvimTreeGitPanelPath",
          line = line_number,
          start_col = dir_col_start,
          end_col = dir_col_start + #display_dir,
        }
      end
    end

  end
end

local function apply_panel_render(lines, highlights, line_map)
  vim.bo[state.panel_buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.panel_buf, 0, -1, false, lines)
  vim.bo[state.panel_buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(state.panel_buf, PANEL_NAMESPACE, 0, -1)

  for _, hl in ipairs(highlights) do
    vim.api.nvim_buf_add_highlight(state.panel_buf, PANEL_NAMESPACE, hl.group, hl.line, hl.start_col, hl.end_col)
  end

  state.entries_by_line = line_map
end

local function render_git_panel(panel_width)
  local staged, unstaged, err = collect_entries(state.root)
  if not staged then
    notify(err, vim.log.levels.ERROR)
    staged = {}
    unstaged = {}
  end
  mark_entries_with_pins(staged, state.root)
  mark_entries_with_pins(unstaged, state.root)

  local branch = get_git_branch(state.root)
  local lines = {}
  local highlights = {}
  local line_map = {}

  local title_line = push_line(lines, " SOURCE CONTROL  [" .. branch .. "]")
  local root_line = push_line(lines, " " .. vim.fn.fnamemodify(state.root, ":~"))
  push_line(lines, "")
  add_section(lines, line_map, highlights, "Staged", staged, panel_width, { highlight_pinned_name = true })
  push_line(lines, "")
  add_section(lines, line_map, highlights, "Unstaged", unstaged, panel_width, { highlight_pinned_name = true })
  push_line(lines, "")
  local hint_line = push_line(lines, " <CR> diff   p pin   s stage   u unstage   1-9 width   R refresh   gp pins   gs/q tree")

  highlights[#highlights + 1] = {
    group = "NvimTreeGitPanelTitle",
    line = title_line,
    start_col = 0,
    end_col = -1,
  }
  highlights[#highlights + 1] = {
    group = "NvimTreeGitPanelRoot",
    line = root_line,
    start_col = 0,
    end_col = -1,
  }
  highlights[#highlights + 1] = {
    group = "NvimTreeGitPanelHint",
    line = hint_line,
    start_col = 0,
    end_col = -1,
  }

  apply_panel_render(lines, highlights, line_map)
end

local function render_pins_panel(panel_width)
  local pins = collect_pinned_entries(state.root)
  local lines = {}
  local highlights = {}
  local line_map = {}

  local title_line = push_line(lines, " PINNED FILES")
  local root_line = push_line(lines, " " .. vim.fn.fnamemodify(state.root, ":~"))
  push_line(lines, "")
  add_section(lines, line_map, highlights, "Pinned", pins, panel_width)
  push_line(lines, "")
  local hint_line = push_line(lines, " <CR> open   p pin/unpin   1-9 width   R refresh   gs source   gp/q tree")

  highlights[#highlights + 1] = {
    group = "NvimTreeGitPanelTitle",
    line = title_line,
    start_col = 0,
    end_col = -1,
  }
  highlights[#highlights + 1] = {
    group = "NvimTreeGitPanelRoot",
    line = root_line,
    start_col = 0,
    end_col = -1,
  }
  highlights[#highlights + 1] = {
    group = "NvimTreeGitPanelHint",
    line = hint_line,
    start_col = 0,
    end_col = -1,
  }

  apply_panel_render(lines, highlights, line_map)
end

render_panel = function()
  if not buf_is_valid(state.panel_buf) then
    return
  end

  ensure_highlights()
  local panel_width = win_is_valid(state.panel_win) and vim.api.nvim_win_get_width(state.panel_win) or state.width

  if state.mode == PANEL_MODE.PINS then
    render_pins_panel(panel_width)
    return
  end

  render_git_panel(panel_width)
end

local function detect_filetype(path)
  return vim.filetype.match({ filename = path }) or ""
end

local function create_snapshot_buf(name, lines, filetype)
  local bufnr = vim.api.nvim_create_buf(false, true)
  local bo = vim.bo[bufnr]

  bo.buftype = "nofile"
  bo.bufhidden = "wipe"
  bo.swapfile = false
  bo.modifiable = true

  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

  bo.modifiable = false
  bo.readonly = true

  if filetype ~= "" then
    bo.filetype = filetype
  end

  local unique_name = string.format("nvimtree-git://%s/%d", name, vim.loop.hrtime())
  pcall(vim.api.nvim_buf_set_name, bufnr, unique_name)

  return bufnr
end

local function is_snapshot_buf(bufnr)
  if not buf_is_valid(bufnr) then
    return false
  end
  local name = vim.api.nvim_buf_get_name(bufnr)
  return name:sub(1, #"nvimtree-git://") == "nvimtree-git://"
end

local function git_show_lines(root, spec)
  local output = vim.fn.systemlist({ "git", "-C", root, "show", spec })
  if vim.v.shell_error ~= 0 then
    return {}
  end
  return output
end

local function find_editor_win()
  if win_is_valid(state.editor_win) and state.editor_win ~= state.panel_win then
    local preferred_buf = vim.api.nvim_win_get_buf(state.editor_win)
    if vim.bo[preferred_buf].buflisted and not is_sidebar_buffer(preferred_buf) then
      return state.editor_win
    end
  end

  for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if winid ~= state.panel_win then
      local bufnr = vim.api.nvim_win_get_buf(winid)
      if vim.bo[bufnr].buflisted and not is_sidebar_buffer(bufnr) then
        return winid
      end
    end
  end

  for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if winid ~= state.panel_win then
      return winid
    end
  end

  return nil
end

local function cycle_tabufline_from_sidebar(direction)
  local ok, tabufline = pcall(require, "nvchad.tabufline")
  if not ok then
    return
  end

  local target = find_editor_win()
  if not target then
    return
  end

  local current = vim.api.nvim_get_current_win()
  state.editor_win = target
  vim.api.nvim_set_current_win(target)
  if direction == "prev" then
    tabufline.prev()
  else
    tabufline.next()
  end
  state.editor_win = vim.api.nvim_get_current_win()
  if win_is_valid(current) then
    vim.api.nvim_set_current_win(current)
  end
end

local function with_win(winid, fn)
  local current = vim.api.nvim_get_current_win()
  if not win_is_valid(winid) then
    return
  end
  vim.api.nvim_set_current_win(winid)
  fn()
  if win_is_valid(current) then
    vim.api.nvim_set_current_win(current)
  end
end

local function disable_diff(winid)
  with_win(winid, function()
    pcall(vim.cmd, "diffoff")
  end)
end

local function clear_diff_tracking()
  state.diff_left_win = nil
  state.diff_right_win = nil
  state.diff_left_buf = nil
  state.diff_right_buf = nil
  state.current_diff_entry = nil
  state.diff_updating = false
end

local function clear_diff_pair()
  local left_win = state.diff_left_win
  local right_win = state.diff_right_win
  local left_buf = state.diff_left_buf
  local right_buf = state.diff_right_buf

  if win_is_valid(left_win) then
    disable_diff(left_win)
  end
  if win_is_valid(right_win) then
    disable_diff(right_win)
  end

  if win_is_valid(left_win) and vim.api.nvim_win_get_buf(left_win) == left_buf and buf_is_valid(left_buf) then
    if is_snapshot_buf(left_buf) then
      pcall(vim.api.nvim_win_close, left_win, true)
    end
  end
  if win_is_valid(right_win) and vim.api.nvim_win_get_buf(right_win) == right_buf and buf_is_valid(right_buf) then
    if is_snapshot_buf(right_buf) then
      pcall(vim.api.nvim_win_close, right_win, true)
    end
  end

  clear_diff_tracking()
end

local function ensure_diff_pair_autocmd()
  if state.diff_pair_autocmd then
    return
  end

  state.diff_pair_autocmd = vim.api.nvim_create_autocmd({ "BufEnter", "WinClosed", "BufWipeout" }, {
    callback = function()
      if state.diff_updating then
        return
      end

      if not state.diff_left_win or not state.diff_right_win then
        return
      end

      local left_valid = win_is_valid(state.diff_left_win)
      local right_valid = win_is_valid(state.diff_right_win)

      if not left_valid and not right_valid then
        clear_diff_tracking()
        return
      end

      if left_valid and right_valid then
        local left_buf_now = vim.api.nvim_win_get_buf(state.diff_left_win)
        local right_buf_now = vim.api.nvim_win_get_buf(state.diff_right_win)
        if left_buf_now == state.diff_left_buf and right_buf_now == state.diff_right_buf then
          return
        end
      end

      clear_diff_pair()
    end,
  })
end

local function ensure_diff_windows()
  if win_in_current_tab(state.diff_left_win) and win_in_current_tab(state.diff_right_win) then
    if state.diff_left_win ~= state.panel_win and state.diff_right_win ~= state.panel_win then
      return state.diff_left_win, state.diff_right_win
    end
  end

  local base_win = nil
  if win_in_current_tab(state.diff_left_win) and state.diff_left_win ~= state.panel_win then
    base_win = state.diff_left_win
  elseif win_in_current_tab(state.diff_right_win) and state.diff_right_win ~= state.panel_win then
    base_win = state.diff_right_win
  else
    base_win = find_editor_win()
  end

  if not base_win and win_is_valid(state.panel_win) then
    vim.api.nvim_set_current_win(state.panel_win)
    vim.cmd("rightbelow vsplit")
    base_win = vim.api.nvim_get_current_win()
  end

  if not base_win then
    return nil, nil
  end

  local right_win
  with_win(base_win, function()
    vim.cmd("vsplit")
    right_win = vim.api.nvim_get_current_win()
  end)

  state.diff_left_win = base_win
  state.diff_right_win = right_win
  return state.diff_left_win, state.diff_right_win
end

local function clamp_diff_targets(total_width, focus_target, min_width)
  if total_width <= (min_width * 2) then
    local left = math.floor(total_width / 2)
    return left, math.max(1, total_width - left)
  end

  local bounded_focus = math.max(min_width, math.min(total_width - min_width, focus_target))
  return bounded_focus, total_width - bounded_focus
end

local function set_diff_width_level(level)
  if not (win_in_current_tab(state.diff_left_win) and win_in_current_tab(state.diff_right_win)) then
    return
  end

  local focused_win = vim.api.nvim_get_current_win()
  if focused_win ~= state.diff_left_win and focused_win ~= state.diff_right_win then
    return
  end

  local other_win = focused_win == state.diff_left_win and state.diff_right_win or state.diff_left_win
  local focused_width = vim.api.nvim_win_get_width(focused_win)
  local other_width = vim.api.nvim_win_get_width(other_win)
  local total_width = focused_width + other_width

  local n = tonumber(level) or 5
  n = math.max(1, math.min(9, n))

  local offset = (n - 5) * DIFF_WIDTH_STEP
  local base_width = math.floor(total_width / 2)
  local focus_target = base_width + offset
  focus_target, _ = clamp_diff_targets(total_width, focus_target, DIFF_MIN_WIDTH)
  local other_target = total_width - focus_target

  pcall(vim.api.nvim_win_set_width, focused_win, focus_target)
  pcall(vim.api.nvim_win_set_width, other_win, other_target)
end

local function open_entry_diff(entry, opts)
  opts = opts or {}

  local left_win, right_win = ensure_diff_windows()
  if not left_win or not right_win then
    notify("No window available to open diff", vim.log.levels.ERROR)
    return
  end

  ensure_diff_pair_autocmd()
  state.diff_updating = true
  disable_diff(left_win)
  disable_diff(right_win)

  local filetype = detect_filetype(entry.path)
  local left_path = entry.old_path or entry.path
  local left_spec
  local right_spec

  if entry.section == "staged" then
    left_spec = "HEAD:" .. left_path
    right_spec = ":" .. entry.path
  else
    left_spec = ":" .. left_path
  end

  local left_buf = create_snapshot_buf(
    string.format("left/%s/%s", entry.section, left_path),
    git_show_lines(state.root, left_spec),
    filetype
  )

  vim.api.nvim_win_set_buf(left_win, left_buf)
  state.diff_left_buf = left_buf
  local right_buf

  if entry.section == "staged" then
    local worktree_path = state.root .. "/" .. entry.path
    if not has_unstaged_for_path(entry.path) and (vim.fn.filereadable(worktree_path) == 1 or vim.fn.isdirectory(worktree_path) == 1) then
      with_win(right_win, function()
        vim.cmd("edit " .. vim.fn.fnameescape(worktree_path))
      end)
      state.diff_right_buf = vim.api.nvim_win_get_buf(right_win)
    else
      right_buf = create_snapshot_buf(
        string.format("right/index/%s", entry.path),
        git_show_lines(state.root, right_spec),
        filetype
      )
      vim.api.nvim_win_set_buf(right_win, right_buf)
      state.diff_right_buf = right_buf
    end
  else
    local worktree_path = state.root .. "/" .. entry.path
    if vim.fn.filereadable(worktree_path) == 1 or vim.fn.isdirectory(worktree_path) == 1 then
      with_win(right_win, function()
        vim.cmd("edit " .. vim.fn.fnameescape(worktree_path))
      end)
      state.diff_right_buf = vim.api.nvim_win_get_buf(right_win)
    else
      right_buf = create_snapshot_buf(string.format("right/worktree/%s", entry.path), {}, filetype)
      vim.api.nvim_win_set_buf(right_win, right_buf)
      state.diff_right_buf = right_buf
    end
  end

  with_win(left_win, function()
    vim.cmd("diffthis")
  end)
  with_win(right_win, function()
    vim.cmd("diffthis")
  end)
  apply_diff_winhl(left_win)
  apply_diff_winhl(right_win)

  state.diff_left_win = left_win
  state.diff_right_win = right_win
  state.current_diff_entry = {
    path = entry.path,
    section = entry.section,
    old_path = entry.old_path,
  }
  state.editor_win = right_win
  state.diff_updating = false
  if opts.focus ~= false and win_is_valid(right_win) then
    vim.api.nvim_set_current_win(right_win)
  end
end

local function open_entry_file(entry)
  local target_win = find_editor_win()
  if not target_win and win_is_valid(state.panel_win) then
    vim.api.nvim_set_current_win(state.panel_win)
    vim.cmd("rightbelow vsplit")
    target_win = vim.api.nvim_get_current_win()
  end
  if not target_win then
    notify("No window available to open file", vim.log.levels.ERROR)
    return
  end

  local abs_path = resolve_entry_path(state.root, entry.path)
  if vim.fn.filereadable(abs_path) ~= 1 then
    notify("File does not exist: " .. entry.path, vim.log.levels.WARN)
    return
  end

  state.editor_win = target_win
  with_win(target_win, function()
    vim.cmd("edit " .. vim.fn.fnameescape(abs_path))
  end)
end

local function refresh_active_diff(changed_file)
  if not (win_in_current_tab(state.diff_left_win) and win_in_current_tab(state.diff_right_win)) then
    return
  end

  local current = state.current_diff_entry
  if not current then
    return
  end

  if changed_file and not changed_path_matches(current.path, changed_file) then
    if not changed_path_matches(current.old_path, changed_file) then
      return
    end
  end

  local entry = find_current_diff_entry()
  if not entry then
    clear_diff_pair()
    return
  end

  open_entry_diff(entry, { focus = false })
end

local function ensure_git_change_autocmd()
  if state.git_change_autocmd then
    return
  end

  state.git_change_autocmd = vim.api.nvim_create_autocmd("User", {
    pattern = "GitSignsChanged",
    callback = function(args)
      local changed_file = args.data and args.data.file or nil
      M.sync_from_git(changed_file)
    end,
  })
end

local function setup_panel_keymaps(bufnr)
  local function opts(desc)
    return {
      buffer = bufnr,
      desc = desc,
      noremap = true,
      silent = true,
      nowait = true,
    }
  end

  vim.keymap.set("n", "<CR>", M.open_selected_diff, opts("Panel: Open"))
  vim.keymap.set("n", "o", M.open_selected_diff, opts("Panel: Open"))
  vim.keymap.set("n", "p", M.toggle_selected_pin, opts("Panel: Pin/unpin"))
  vim.keymap.set("n", "s", M.stage_selected, opts("Git panel: Stage"))
  vim.keymap.set("n", "u", M.unstage_selected, opts("Git panel: Unstage"))
  for i = 1, 9 do
    local level = i
    vim.keymap.set("n", tostring(level), function()
      M.set_width_level(level)
    end, opts("Git panel: Set width level " .. level))
  end
  vim.keymap.set("n", "R", M.refresh, opts("Panel: Refresh"))
  vim.keymap.set("n", "gs", M.toggle_source_control, opts("Panel: Source control view"))
  vim.keymap.set("n", "gp", M.toggle_pins, opts("Panel: Pinned files view"))
  vim.keymap.set("n", "q", M.back_to_tree, opts("Panel: Back to tree"))
  vim.keymap.set("n", "<Tab>", function()
    M.cycle_tabufline("next")
  end, opts("Git panel: Next buffer"))
  vim.keymap.set("n", "<S-Tab>", function()
    M.cycle_tabufline("prev")
  end, opts("Git panel: Previous buffer"))
end

local function reset_state()
  state.active = false
  state.mode = PANEL_MODE.GIT
  state.panel_buf = nil
  state.panel_win = nil
  state.root = nil
  state.entries_by_line = {}
  clear_diff_tracking()
end

local function resolve_panel_root(mode)
  if mode == PANEL_MODE.PINS then
    return get_git_root() or normalize_path(get_cwd())
  end
  return get_git_root()
end

local function open_panel(mode)
  local api = require("nvim-tree.api")
  mode = normalize_mode(mode)
  local root = resolve_panel_root(mode)
  if not root then
    notify("Current cwd is not in a git repository.", vim.log.levels.WARN)
    return
  end

  ensure_git_change_autocmd()
  state.mode = mode
  state.root = root
  state.width = vim.api.nvim_win_get_width(0)

  api.tree.close()
  state.editor_win = vim.api.nvim_get_current_win()

  vim.cmd("topleft vsplit")
  state.panel_win = vim.api.nvim_get_current_win()
  state.panel_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(state.panel_win, state.panel_buf)
  state.active = true

  if state.width > 0 then
    pcall(vim.api.nvim_win_set_width, state.panel_win, state.width)
  end

  local bo = vim.bo[state.panel_buf]
  bo.buftype = "nofile"
  bo.bufhidden = "wipe"
  bo.buflisted = false
  bo.swapfile = false
  bo.modifiable = false
  bo.filetype = PANEL_FILETYPE

  local wo = vim.wo[state.panel_win]
  wo.number = false
  wo.relativenumber = false
  wo.signcolumn = "no"
  wo.cursorline = true
  wo.wrap = false
  wo.winfixwidth = true
  wo.foldcolumn = "0"
  wo.winhl = table.concat({
    "Normal:NvimTreeNormal",
    "NormalNC:NvimTreeNormalNC",
    "SignColumn:NvimTreeNormal",
    "EndOfBuffer:NvimTreeEndOfBuffer",
    "CursorLine:NvimTreeCursorLine",
  }, ",")

  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = state.panel_buf,
    once = true,
    callback = reset_state,
  })

  prune_tabufline_buffers()
  setup_panel_keymaps(state.panel_buf)
  render_panel()
end

function M.refresh()
  if not state.active then
    return
  end

  if not state.root then
    state.root = resolve_panel_root(state.mode)
  end

  if not state.root then
    notify("Unable to determine panel root.", vim.log.levels.ERROR)
    return
  end

  render_panel()
end

function M.sync_from_git(changed_file)
  refresh_panel_preserve_selection()
  if state.mode == PANEL_MODE.GIT then
    refresh_active_diff(changed_file)
  end
end

function M.open_selected_diff()
  if not state.active then
    return
  end

  local line = vim.api.nvim_win_get_cursor(0)[1]
  local entry = state.entries_by_line[line]
  if not entry then
    return
  end

  if state.mode == PANEL_MODE.PINS then
    open_entry_file(entry)
    return
  end

  open_entry_diff(entry)
end

local function diff_pair_active_for_entry(path, section)
  if not (win_in_current_tab(state.diff_left_win) and win_in_current_tab(state.diff_right_win)) then
    return false
  end

  local current = state.current_diff_entry
  if not current or current.section ~= section then
    return false
  end

  return current.path == path or current.old_path == path
end

local function get_current_file_diff_context()
  local abs_path = vim.api.nvim_buf_get_name(0)
  if abs_path == "" then
    notify("Current buffer has no file path.", vim.log.levels.WARN)
    return nil, nil
  end

  local root = get_git_root_for_path(abs_path)
  if not root then
    notify("Current buffer is not in a git repository.", vim.log.levels.WARN)
    return nil, nil
  end

  local rel_path = path_relative_to_root(abs_path, root)
  if not rel_path or rel_path == "." then
    notify("Current file is outside repository root.", vim.log.levels.WARN)
    return nil, nil
  end

  return root, rel_path
end

local function toggle_current_file_diff(section, missing_msg)
  local root, rel_path = get_current_file_diff_context()
  if not root or not rel_path then
    return
  end

  if diff_pair_active_for_entry(rel_path, section) then
    clear_diff_pair()
    state.root = root
    open_entry_file({ path = rel_path })
    return
  end

  local entry = collect_entries_for_path(root, rel_path, section)
  if not entry then
    notify(missing_msg, vim.log.levels.INFO)
    return
  end

  state.root = root
  state.editor_win = vim.api.nvim_get_current_win()
  open_entry_diff(entry)
end

function M.toggle_current_unstaged_diff()
  toggle_current_file_diff("unstaged", "No unstaged changes for current file.")
end

function M.toggle_current_staged_diff()
  toggle_current_file_diff("staged", "No staged changes for current file.")
end

function M.toggle_selected_pin()
  if not state.active or not state.root then
    return
  end

  local entry, fallback_line = current_entry()
  if not entry or not entry.path then
    return
  end

  local did_pin = toggle_pin(state.root, entry.path)
  if did_pin == nil then
    return
  end

  notify((did_pin and "Pinned " or "Unpinned ") .. entry.path)

  if state.mode == PANEL_MODE.PINS then
    render_panel()
    jump_to_entry(entry.path, "pinned", fallback_line)
  end
end

function M.toggle_current_file_pin()
  local abs_path = vim.api.nvim_buf_get_name(0)
  if abs_path == "" then
    notify("Current buffer has no file path.", vim.log.levels.WARN)
    return
  end

  local root = get_root_for_file(abs_path)
  local rel_path = path_relative_to_root(abs_path, root)
  if not rel_path or rel_path == "." then
    notify("Current file is outside project root.", vim.log.levels.WARN)
    return
  end

  local did_pin = toggle_pin(root, rel_path)
  if did_pin == nil then
    return
  end

  notify((did_pin and "Pinned " or "Unpinned ") .. rel_path)

  if state.active and state.mode == PANEL_MODE.PINS and normalize_path(state.root) == normalize_path(root) then
    refresh_panel_preserve_selection()
  end
end

function M.stage_selected()
  if not state.active or not state.root or state.mode ~= PANEL_MODE.GIT then
    return
  end

  local entry, fallback_line = current_entry()
  if not entry or entry.section ~= "unstaged" then
    return
  end

  local ok = run_git_silent(state.root, { "add", "--", entry.path })
  if not ok then
    notify("Failed to stage " .. entry.path, vim.log.levels.ERROR)
    return
  end

  render_panel()
  jump_to_entry(entry.path, "staged", fallback_line)
  refresh_active_diff(state.root .. "/" .. entry.path)
end

function M.unstage_selected()
  if not state.active or not state.root or state.mode ~= PANEL_MODE.GIT then
    return
  end

  local entry, fallback_line = current_entry()
  if not entry or entry.section ~= "staged" then
    return
  end

  local has_head = run_git_silent(state.root, { "rev-parse", "--verify", "HEAD" })
  local ok
  if has_head then
    ok = run_git_silent(state.root, { "reset", "-q", "HEAD", "--", entry.path })
  else
    ok = run_git_silent(state.root, { "rm", "--cached", "-q", "--", entry.path })
  end

  if not ok then
    notify("Failed to unstage " .. entry.path, vim.log.levels.ERROR)
    return
  end

  render_panel()
  jump_to_entry(entry.path, "unstaged", fallback_line)
  refresh_active_diff(state.root .. "/" .. entry.path)
end

function M.set_width_level(level)
  local target_width = calc_width_level(level)
  state.width = target_width

  if state.active and win_is_valid(state.panel_win) then
    pcall(vim.api.nvim_win_set_width, state.panel_win, target_width)
    render_panel()
    return
  end

  local api = require("nvim-tree.api")
  if api.tree.is_visible() then
    api.tree.resize({ width = target_width })
  end
end

function M.cycle_tabufline(direction)
  cycle_tabufline_from_sidebar(direction)
end

function M.set_active_diff_width_level(level)
  set_diff_width_level(level)
end

function M.prune_tabufline_buffers()
  prune_tabufline_buffers()
end

function M.close_panel()
  if win_is_valid(state.panel_win) then
    pcall(vim.api.nvim_win_close, state.panel_win, true)
  elseif buf_is_valid(state.panel_buf) then
    pcall(vim.api.nvim_buf_delete, state.panel_buf, { force = true })
  end

  reset_state()
end

local function open_tree_with_state_width()
  local api = require("nvim-tree.api")
  api.tree.open({ focus = true })
  if state.width and state.width > 0 then
    api.tree.resize({ width = state.width })
  end
end

function M.back_to_tree()
  if state.active or vim.bo.filetype == PANEL_FILETYPE then
    M.close_panel()
  end
  open_tree_with_state_width()
end

local function switch_mode(mode)
  mode = normalize_mode(mode)
  if not state.active then
    return false
  end
  if state.mode == mode then
    return false
  end

  local root = resolve_panel_root(mode)
  if not root then
    notify("Current cwd is not in a git repository.", vim.log.levels.WARN)
    return true
  end

  state.mode = mode
  state.root = root

  if mode == PANEL_MODE.PINS then
    clear_diff_pair()
  end

  render_panel()
  return true
end

local function toggle_mode(mode)
  local api = require("nvim-tree.api")
  mode = normalize_mode(mode)

  if state.active or vim.bo.filetype == PANEL_FILETYPE then
    if switch_mode(mode) then
      return
    end
    M.close_panel()
    open_tree_with_state_width()
    return
  end

  if not api.tree.is_tree_buf(0) then
    return
  end

  open_panel(mode)
end

function M.toggle_source_control()
  toggle_mode(PANEL_MODE.GIT)
end

function M.toggle_pins()
  toggle_mode(PANEL_MODE.PINS)
end

function M.toggle()
  M.toggle_source_control()
end

return M
