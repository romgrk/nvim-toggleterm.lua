local api = vim.api
local fn = vim.fn
local colors = require("toggleterm/colors")
-----------------------------------------------------------
-- Export
-----------------------------------------------------------
local M = {
  __set_highlights = colors.set_highlights
}

-----------------------------------------------------------
-- Constants
-----------------------------------------------------------
local default_size = 12
local term_ft = 'toggleterm'

-----------------------------------------------------------
-- State
-----------------------------------------------------------
local terminals = {}

function create_term()
  local no_of_terms = table.getn(terminals)
  local next_num = no_of_terms == 0 and 1 or no_of_terms + 1
  return {
    window = -1,
    job_id = -1,
    bufnr = -1,
    dir = fn.getcwd(),
    number = next_num,
  }
end

--- @param size number
function open_split(size)
  local has_open, win_ids = find_open_windows()
  if has_open then
    -- we need to be in the terminal window most recently opened
    -- in order to split to the right of it
    fn.win_gotoid(win_ids[#win_ids])
    vim.cmd('vsp')
  else
    vim.cmd(size .. 'sp')
    -- move horizontal split to the bottom
    vim.cmd('wincmd J')
  end
end

--- Source: https://teukka.tech/luanvim.html
--- @param definitions table<string,table>
local function create_augroups(definitions)
  for group_name, definition in pairs(definitions) do
    vim.cmd('augroup '..group_name)
    vim.cmd('autocmd!')
    for _,def in pairs(definition) do
      local command = table.concat(vim.tbl_flatten{'autocmd', def}, ' ')
      vim.cmd(command)
    end
    vim.cmd('augroup END')
  end
end

--- @param win_id number
function find_window(win_id)
  return fn.win_gotoid(win_id) > 0
end

--- get existing terminal or create an empty term table
--- @param num number
function find_term(num)
  return terminals[num] or create_term()
end

--- get the toggle term number from
--- the name e.g. term://~/.dotfiles//3371887:/usr/bin/zsh;#toggleterm#1
--- the number in this case is 1
--- @param name string
function get_number_from_name(name)
  local parts = vim.split(name, '#')
  local num = tonumber(parts[#parts])
  return num
end

--- Find the the first open terminal window
--- by iterating all windows and matching the
--- containing buffers filetype with the passed in
--- comparator function or the default which matches
--- the filetype
--- @param comparator function
function find_open_windows(comparator)
  comparator = comparator or function (buf) return vim.bo[buf].filetype == term_ft end
  local wins = api.nvim_list_wins()
  local is_open = false
  local term_wins = {}
  for _, win in pairs(wins) do
      local buf = api.nvim_win_get_buf(win)
      if comparator(buf) then
        is_open = true
        table.insert(term_wins, win)
      end
  end
  return is_open, term_wins
end

--- Add terminal buffer specific options
--- @param num number
--- @param bufnr number
--- @param win_id number
function set_opts(num, bufnr, win_id)
  vim.wo[win_id].winfixheight = true
  vim.bo[bufnr].buflisted = false
  vim.bo[bufnr].filetype = term_ft
  api.nvim_buf_set_var(bufnr, "toggle_number", num)
end

--- @param bufnr number
function setup_buffer_mappings(bufnr)
  local mapping = vim.g.toggleterm_terminal_mapping
  if mapping then
    api.nvim_buf_set_keymap(bufnr,'t', mapping, '<C-\\><C-n>:exe v:count1 . "ToggleTerm"<CR>', {
        silent = true,
        noremap = true,
      })
  end
end

function setup_global_mappings()
  local mapping = vim.g.toggleterm_terminal_mapping
  -- v:count1 defaults the count to 1 but if a count is passed in uses that instead
  -- <c-u> allows passing along the count
  api.nvim_set_keymap('n', mapping, ':<c-u>exe v:count1 . "ToggleTerm"<CR>', {
      silent = true,
      noremap = true,
    })
  api.nvim_set_keymap('i', mapping, '<Esc>:<c-u>exe v:count1 . "ToggleTerm"<CR>', {
      silent = true,
      noremap = true,
    })
end

--- @param bufnr number
function find_windows_by_bufnr(bufnr)
  return fn.win_findbuf(bufnr)
end

--- @param size number
function smart_toggle(_, size)
  local already_open = find_open_windows()
  if not already_open then
    M.open(1, size)
  else
    local target = #terminals
    -- count backwards from the end of the list
    for i = #terminals, 1, -1 do
      local term = terminals[i]
      if not term then
        vim.cmd(string.format(
          'echomsg "Term does not exist %s"',
          vim.inspect(term)
        ))
        break
      end
      local wins = find_windows_by_bufnr(term.bufnr)
      if table.getn(wins) > 0 then
        target = i
        break
      end
    end
    M.close(target)
  end
end

--- @param num number
--- @param size number
function toggle_nth_term(num, size)
  local term = find_term(num)
  if find_window(term.window) then
    M.close(num)
  else
    M.open(num, size)
  end
end

--- FIXME DEV only issue, on reloading/sourcing this file
--- we lose all state and term windows can't be reconciled
--- 1. Find out if the name matches
--- 2. Check if the number is the list of terminals if not add it
--- 3. If it is not the correct type make it so
function reconcile_terminals()
  local has_open, windows = find_open_windows(function (buf)
    return string.match(api.nvim_buf_get_name(buf), term_ft) ~= nil
  end)
  -- print('reconciling: '..vim.inspect(windows))
  if not has_open then return end
  local set = {}
  for _, t in ipairs(terminals) do set[t.window] = true end
  for _, win in pairs(windows) do
      if not set[win] then
        local buf = api.nvim_win_get_buf(win)
        local name = api.nvim_buf_get_name(buf)
        local num = get_number_from_name(name)
        local term = {
          bufnr = fn.bufnr(),
          window = fn.win_getid(),
          job_id = vim.b.terminal_job_id,
          number = num,
          dir = fn.getcwd()
        }
        terminals[num] = term
      end
  end
end


function M.close_last_window()
  local buf = api.nvim_get_current_buf()
  local only_one_window = fn.winnr('$') == 1
  if only_one_window and vim.bo[buf].filetype == term_ft then
    -- Reset the window id so there are no hanging
    -- references to the terminal window
    for _, term in pairs(terminals) do
        if term.bufnr == buf then
            term.window = -1
            break
        end
    end
    -- FIXME switching causes the buffer
    -- switched to to have no highlighting
    -- no idea why
    vim.cmd('keepalt bnext')
  end
end

function M.on_term_open()
  local title = fn.bufname()
  local num = get_number_from_name(title)
  if not terminals[num] then
    local term = create_term()
    term.bufnr = fn.bufnr()
    term.window = fn.win_getid()
    term.job_id = vim.b.terminal_job_id
    terminals[num] = term

    vim.cmd("resize "..default_size)
    set_opts(num, term.bufnr, term.window)
  end
end

--- Remove the in memory reference to the no longer open terminal
--- @param num string
function M.delete(num)
  if terminals[num] then terminals[num] = nil end
end

--- @param num number
--- @param size number
function M.open(num, size)
  vim.validate{num={num, 'number'}, size={size, 'number', true}}

  size = (size and size > 0) and size or default_size
  local term = find_term(num)

  if vim.fn.bufexists(term.bufnr) == 0 then
    open_split(size)
    term.window = fn.win_getid()
    term.bufnr = api.nvim_create_buf(false, false)

    api.nvim_set_current_buf(term.bufnr)
    api.nvim_win_set_buf(term.window, term.bufnr)

    vim.cmd('lcd '.. fn.getcwd())
    local name = vim.o.shell..';#'..term_ft..'#'..num
    term.job_id = fn.termopen(name, { detach = 1 })

    create_augroups({
      ["ToggleTerm"..term.bufnr] = {
        {
          "TermClose",
          string.format("<buffer=%d>", term.bufnr),
          string.format('lua require"toggleterm".delete(%d)', num),
        };
      }
    })
    setup_buffer_mappings(term.bufnr)
    terminals[num] = term
  else
    open_split(size)
    vim.cmd('resize '.. size)
    vim.cmd('keepalt buffer '..term.bufnr)
    vim.wo.winfixheight = true
    term.window = fn.win_getid()
  end
end

--- @param cmd string
--- @param num number
--- @param size number
function M.exec(cmd, num, size)
  vim.validate{
    cmd={cmd, "string"},
    num={num, "number"},
    size={size, "number", true},
  }
  -- count
  num = num < 1 and 1 or num
  local term = find_term(num)
  if not find_window(term.window) then
    M.open(num, size)
  end
  term = find_term(num)
  fn.chansend(term.job_id, "clear".."\n"..cmd.."\n")
  vim.cmd('normal! G')
  vim.cmd('wincmd p')
  vim.cmd('stopinsert!')
end

--- @param num number
function M.close(num)
  local term = find_term(num)
  if find_window(term.window) then
    vim.cmd('hide')
  else if num then
      vim.cmd(string.format('echoerr "Failed to close window: %d does not exist"', num))
    else
      vim.cmd('echoerr "Failed to close window: invalid term number"')
    end
  end
end

--- only shade explicitly specified filetypes
function M.__apply_colors()
  local ft = vim.bo.filetype

  if not vim.bo.filetype or vim.bo.filetype == '' then
    ft = 'none'
  end

  local allow_list = vim.g.toggleterm_shade_filetypes or {}
  table.insert(allow_list, term_ft)

  local is_enabled_ft = false
  for _, filetype in ipairs(allow_list) do
      if ft == filetype then
        is_enabled_ft = true
        break
      end
  end
  if vim.bo.buftype == 'terminal' and is_enabled_ft then
    colors.darken_terminal()
  end
end

--- If a count is provided we operate on the specific terminal buffer
--- i.e. 2ToggleTerm => open or close Term 2
--- if the count is 1 we use a heuristic which is as follows
--- if there is no open terminal window we toggle the first one i.e. assumed
--- to be the primary. However if several are open we close them.
--- this can be used with the count commands to allow specific operations
--- per term or mass actions
--- @param count number
--- @param size number
function M.toggle(count, size)
  vim.validate{
    count={count, 'number', true},
    size={size, 'number', true},
  }
  -- reconcile_terminals()
  if count > 1 then
    toggle_nth_term(count, size)
  else
    smart_toggle(count, size)
  end
end

function M.setup()
  setup_global_mappings()
  local autocommands = {
    {
      "BufEnter",
      "term://*toggleterm#*",
      "lua require'toggleterm'.close_last_window()",
    },
    {
      "TermOpen",
      "term://*toggleterm#*",
      "lua require'toggleterm'.on_term_open()",
    }
  }
  if vim.g.toggleterm_shade_terminals then
    vim.list_extend(autocommands, {
        {
          -- call set highlights once on vim start
          -- as this plugin might not be initialised till
          -- after the colorscheme autocommand has fired
          -- reapply highlights when the colorscheme
          -- is re-applied
          "VimEnter,ColorScheme",
          "*",
          "lua require'toggleterm'.__set_highlights(-30)"
        },
        {
          "TermOpen",
          "term://*zsh*,term://*bash*,term://*toggleterm#*",
          "lua require('toggleterm').__apply_colors()"
        },
      })
  end
  create_augroups({ ToggleTerminal = autocommands})
end

--- FIXME this shows a cached version of the terminals
function M.introspect()
  print('All terminals: '..vim.inspect(terminals))
end

return M
