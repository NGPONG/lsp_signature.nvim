local M = {}

local path_sep = vim.loop.os_uname().sysname == 'Windows' and '\\' or '/'

local function path_join(...)
  local tbl_flatten = function(t)
    if vim.fn.has('nvim-0.10') == 0 then -- for old versions
      return vim.tbl_flatten(t)
    end
    return vim.iter(t):flatten():totable()
  end
  return table.concat(tbl_flatten({ ... }), path_sep)
end

local function deprecated(cfg)
  if cfg.trigger_on_new_line ~= nil or cfg.trigger_on_nomatch ~= nil then
    print('trigger_on_new_line and trigger_on_nomatch deprecated, using always_trigger instead')
  end

  if cfg.use_lspsaga or cfg.check_3rd_handler ~= nil then
    print('lspsaga signature and 3rd handler deprecated')
  end
  if cfg.floating_window_above_first ~= nil then
    print('use floating_window_above_cur_line instead')
  end
  if cfg.decorator then
    print('decorator deprecated, use hi_parameter instead')
  end
end

M.LSP_SIG_CFG = {
  bind = true, -- This is mandatory, otherwise border config won't get registered.
  doc_lines = 10, -- how many lines to show in doc, set to 0 if you only want the signature
  max_height = 12, -- max height of signature floating_window
  max_width = 80, -- max_width of signature floating_window
  wrap = true, -- allow doc/signature wrap inside floating_window, useful if your lsp doc/sig is too long

  floating_window = true, -- show hint in a floating window
  floating_window_above_cur_line = true, -- try to place the floating above the current line
  toggle_key_flip_floatwin_setting = false, -- toggle key will enable|disable floating_window flag
  floating_window_off_x = 1, -- adjust float windows x position. or a function return the x offset
  floating_window_off_y = function(floating_opts) -- adjust float windows y position.
    --e.g. set to -2 can make floating window move up 2 lines
    -- local linenr = vim.api.nvim_win_get_cursor(0)[1] -- buf line number
    -- local pumheight = vim.o.pumheight
    -- local winline = vim.fn.winline() -- line number in the window
    -- local winheight = vim.fn.winheight(0)
    --
    -- -- window top
    -- if winline < pumheight then
    --   return pumheight
    -- end
    --
    -- -- window bottom
    -- if winheight - winline < pumheight then
    --   return -pumheight
    -- end
    return 0
  end,
  close_timeout = 4000, -- close floating window after ms when laster parameter is entered
  fix_pos = function(signatures, client) -- first arg: second argument is the client
    _, _ = signatures, client
    return true -- can be expression like : return signatures[1].activeParameter >= 0 and signatures[1].parameters > 1
  end,
  -- also can be bool value fix floating_window position
  hint_enable = true, -- virtual hint
  hint_prefix = '🐼 ',
  hint_scheme = 'String',
  hint_inline = function()
    -- options:
    -- 'inline', 'eol'
    return false -- return fn.has('nvim_0.10') == 1
  end,
  hi_parameter = 'LspSignatureActiveParameter',
  handler_opts = { border = 'rounded' },
  cursorhold_update = true, -- if cursorhold slows down the completion, set to false to disable it
  padding = '', -- character to pad on left and right of signature
  always_trigger = false, -- sometime show signature on new line can be confusing, set it to false for #58
  -- set this to true if you the triggered_chars failed to work
  -- this will allow lsp server decide show signature or not
  auto_close_after = nil, -- autoclose signature after x sec, disabled if nil.
  check_completion_visible = true, -- adjust position of signature window relative to completion popup
  debug = false,
  log_path = path_join(vim.fn.stdpath('cache'), 'lsp_signature.log'), -- log dir when debug is no
  verbose = false, -- debug show code line number
  extra_trigger_chars = {}, -- Array of extra characters that will trigger signature completion, e.g., {"(", ","}
  zindex = 200,
  transparency = nil, -- disabled by default
  shadow_blend = 36, -- if you using shadow as border use this set the opacity
  shadow_guibg = 'Black', -- if you using shadow as border use this set the color e.g. 'Green' or '#121315'
  timer_interval = 200, -- default timer check interval
  toggle_key = nil, -- toggle signature on and off in insert mode,  e.g. '<M-x>'
  -- set this key also helps if you want see signature in newline
  select_signature_key = nil, -- cycle to next signature, e.g. '<M-n>' function overloading
  -- internal vars, init here to suppress linter warnings
  move_cursor_key = nil, -- use nvim_set_current_win

  --- private vars
  winnr = nil,
  bufnr = 0,
  mainwin = 0,
}

M.LSP_SIG_VT_NS = nil

function M.setup(cfg)
  assert(type(cfg) == 'table')
  deprecated(cfg)

  M.LSP_SIG_CFG = vim.tbl_extend('keep', cfg, M.LSP_SIG_CFG)
end

return M