local api = vim.api
local fn = vim.fn
local M = {}
local helper = require('lsp_signature.helper')
local C = require('lsp_signature.cfg')
local log = helper.log
local match_parameter = helper.match_parameter
-- local check_closer_char = helper.check_closer_char

local status_line = { hint = '', label = '' }
local manager = {
  insertChar = false, -- flag for InsertCharPre event, turn off immediately when performing completion
  insertLeave = true, -- flag for InsertLeave, prevent every completion if true
  changedTick = 0, -- handle changeTick
  confirmedCompletion = false, -- flag for manual confirmation of completion
  timer = nil,
}

function manager.init()
  manager.insertLeave = false
  manager.insertChar = false
  manager.confirmedCompletion = false
end

local function virtual_hint(hint, off_y)
  if hint == nil or hint == '' then
    return
  end
  local dwidth = fn.strdisplaywidth
  local r = vim.api.nvim_win_get_cursor(0)
  local line = api.nvim_get_current_line()
  local line_to_cursor = line:sub(1, r[2])
  local cur_line = r[1] - 1 -- line number of current line, 0 based
  local show_at = cur_line - 1 -- show at above line
  local lines_above = vim.fn.winline() - 1
  local lines_below = vim.fn.winheight(0) - lines_above
  if lines_above > lines_below then
    show_at = cur_line + 1 -- same line
  end
  local pl
  local completion_visible = helper.completion_visible()
  local hp = type(C.LSP_SIG_CFG.hint_prefix) == 'string' and C.LSP_SIG_CFG.hint_prefix
    or (type(C.LSP_SIG_CFG.hint_prefix) == 'table' and C.LSP_SIG_CFG.hint_prefix.current)
    or '🐼 '

  if off_y and off_y ~= 0 then
    local inline = type(C.LSP_SIG_CFG.hint_inline) == 'function'
        and C.LSP_SIG_CFG.hint_inline() == 'inline'
      or C.LSP_SIG_CFG.hint_inline
    -- stay out of the way of the pum
    if completion_visible or inline then
      show_at = cur_line
      if type(C.LSP_SIG_CFG.hint_prefix) == 'table' then
        hp = C.LSP_SIG_CFG.hint_prefix.current or '🐼 '
      end
    else
      -- if no pum, show at user configured line
      if off_y > 0 then
        -- line below
        show_at = cur_line + 1
        if type(C.LSP_SIG_CFG.hint_prefix) == 'table' then
          hp = C.LSP_SIG_CFG.hint_prefix.below or '🐼 '
        end
      end
      if off_y < 0 then
        -- line above
        show_at = cur_line - 1
        if type(C.LSP_SIG_CFG.hint_prefix) == 'table' then
          hp = C.LSP_SIG_CFG.hint_prefix.above or '🐼 '
        end
      end
    end
  end

  if C.LSP_SIG_CFG.floating_window == false then
    local prev_line, next_line
    if cur_line > 0 then
      prev_line = vim.api.nvim_buf_get_lines(0, cur_line - 1, cur_line, false)[1]
    end
    next_line = vim.api.nvim_buf_get_lines(0, cur_line + 1, cur_line + 2, false)[1]
    if prev_line and vim.fn.strdisplaywidth(prev_line) < r[2] then
      show_at = cur_line - 1
      pl = prev_line
      if type(C.LSP_SIG_CFG.hint_prefix) == 'table' then
        hp = C.LSP_SIG_CFG.hint_prefix.above or '🐼 '
      end
    elseif next_line and dwidth(next_line) < r[2] + 2 and not completion_visible then
      show_at = cur_line + 1
      pl = next_line
      if type(C.LSP_SIG_CFG.hint_prefix) == 'table' then
        hp = C.LSP_SIG_CFG.hint_prefix.below or '🐼 '
      end
    else
      show_at = cur_line
      if type(C.LSP_SIG_CFG.hint_prefix) == 'table' then
        hp = C.LSP_SIG_CFG.hint_prefix.current or '🐼 '
      end
    end

    log('virtual text only :', prev_line, next_line, r, show_at, pl)
  end

  pl = pl or ''
  local pad = ''
  local offset = r[2]
  local inline_display = C.LSP_SIG_CFG.hint_inline()
  if inline_display == false then
    local line_to_cursor_width = dwidth(line_to_cursor)
    local pl_width = dwidth(pl)
    if show_at ~= cur_line and line_to_cursor_width > pl_width + 1 then
      pad = string.rep(' ', line_to_cursor_width - pl_width)
      local width = vim.api.nvim_win_get_width(0)
      local hint_width = dwidth(hp .. hint)
      -- todo: 6 is width of sign+linenumber column
      if #pad + pl_width + hint_width + 6 > width then
        pad = string.rep(' ', math.max(1, line_to_cursor_width - pl_width - hint_width - 6))
      end
    end
  else -- inline enabled
    local str = vim.api.nvim_get_current_line()
    local cursor_position = vim.api.nvim_win_get_cursor(0)
    local cursor_index = cursor_position[2]

    local closest_index = nil

    for i = cursor_index, 1, -1 do
      local char = string.sub(str, i, i)
      if char == ',' or char == '(' then
        closest_index = i
        break
      end
    end
    offset = closest_index
    hint = hint .. ': '
  end
  C.LSP_SIG_VT_NS = C.LSP_SIG_VT_NS or vim.api.nvim_create_namespace('lsp_signature_vt')

  log('virtual hint cleanup')
  helper.cleanup(false) -- cleanup extmark
  if offset == nil then
    log('virtual text: ', cur_line, 'invalid offset')
    return -- no offset found
  end
  local vt = { pad .. hp .. hint, C.LSP_SIG_CFG.hint_scheme }
  if inline_display then
    if type(inline_display) == 'boolean' then
      inline_display = 'inline'
    end
    inline_display = inline_display and 'inline'
    log('virtual text: ', cur_line, r[1] - 1, r[2], vt)
    vim.api.nvim_buf_set_extmark(
      0,
      C.LSP_SIG_VT_NS,
      r[1] - 1,
      offset,
      { -- Note: the vt was put after of cursor.
        -- this seems eaiser to handle in the code also easy to read
        virt_text_pos = inline_display,
        -- virt_text_pos = 'right_align',
        virt_text = { vt },
        hl_mode = 'combine',
        ephemeral = false,
        -- hl_group = C.LSP_SIG_CFG.hint_scheme
      }
    )
  else -- I may deprecated this when nvim 0.10 release
    log('virtual text: ', cur_line, show_at, vt)
    vim.api.nvim_buf_set_extmark(0, C.LSP_SIG_VT_NS, show_at, 0, {
      virt_text = { vt },
      virt_text_pos = 'eol',
      hl_mode = 'combine',
      -- virt_lines_above = true,
      -- hl_group = C.LSP_SIG_CFG.hint_scheme
    })
  end
end

local close_events = { 'InsertLeave', 'BufHidden', 'ModeChanged' }
-- ----------------------
-- --  signature help  --
-- ----------------------
-- Note: 0.6.x   - signature_help(err, {result}, {ctx}, {config})
local signature_handler = function(err, result, ctx, config)
  if err ~= nil then
    print('lsp_signatur handler', err)
    return
  end

  -- log("sig result", ctx, result, config)
  local client_id = ctx.client_id
  local bufnr = ctx.bufnr
  if result == nil or result.signatures == nil or result.signatures[1] == nil then
    -- only close if this client opened the signature
    log('no valid signatures', result)

    status_line = { hint = '', label = '' }
    if C.LSP_SIG_CFG.client_id == client_id then
      helper.cleanup_async(true, 0.2, true)
      -- need to close floating window and virtual text (if they are active)
    end

    return
  end

  if api.nvim_get_current_buf() ~= bufnr then
    log('ignore outdated signature result')
    return
  end

  if config.trigger_from_next_sig then
    log('trigger from next sig', config.activeSignature)
  end

  if config.trigger_from_next_sig then
    if #result.signatures > 1 then
      local cnt = math.abs(config.activeSignature - result.activeSignature)
      for _ = 1, cnt do
        local m = result.signatures[1]
        table.insert(result.signatures, #result.signatures + 1, m)
        table.remove(result.signatures, 1)
      end
      result.cfgActiveSignature = config.activeSignature
    end
  else
    result.cfgActiveSignature = 0 -- reset
  end
  log('sig result', ctx, result, config)
  C.LSP_SIG_CFG.signature_result = result

  local activeSignature = result.activeSignature or 0
  activeSignature = activeSignature + 1
  if activeSignature > #result.signatures then
    -- this is a upstream bug of metals
    activeSignature = #result.signatures
  end

  local actSig = result.signatures[activeSignature]

  if actSig == nil then
    log('no valid signature, or invalid response', result)
    print('no valid signature or incorrect lsp response ', vim.inspect(result))
    return
  end

  -- label format and trim
  actSig.label = string.gsub(actSig.label, '[\n\r\t]', ' ')
  if actSig.parameters then
    for i = 1, #actSig.parameters do
      if type(actSig.parameters[i].label) == 'string' then
        actSig.parameters[i].label = string.gsub(actSig.parameters[i].label, '[\n\r\t]', ' ')
      end
    end
  end

  -- if multiple signatures existed, find the best match and correct parameter
  local _, hint, s, l = match_parameter(result, config)
  local force_redraw = false
  if #result.signatures > 1 then
    force_redraw = true
    for i = #result.signatures, 1, -1 do
      local sig = result.signatures[i]
      -- hack for lua
      local actPar = sig.activeParameter or result.activeParameter or 0
      if actPar > 0 and actPar + 1 > #(sig.parameters or {}) then
        log('invalid lsp response, active parameter out of boundary')
        -- reset active parameter to last parameter
        sig.activeParameter = #(sig.parameters or {})
      end
    end
  end

  -- status_line.signature = actSig
  status_line.hint = hint or ''
  status_line.label = actSig.label or ''
  status_line.range = { start = s or 0, ['end'] = l or 0 }
  status_line.doc = helper.get_doc(result)

  local mode = vim.api.nvim_get_mode().mode
  local insert_mode = (mode == 'niI' or mode == 'i')
  local floating_window_on = (
    C.LSP_SIG_CFG.winnr ~= nil
    and C.LSP_SIG_CFG.winnr ~= 0
    and api.nvim_win_is_valid(C.LSP_SIG_CFG.winnr)
  )
  if config.trigger_from_cursor_hold and not floating_window_on and not insert_mode then
    log('trigger from cursor hold, no need to update floating window')
    return
  end

  -- trim the doc
  if C.LSP_SIG_CFG.doc_lines == 0 and config.trigger_from_lsp_sig then -- doc disabled
    helper.remove_doc(result)
  end

  if C.LSP_SIG_CFG.hint_enable == true then
    if C.LSP_SIG_CFG.floating_window == false then
      virtual_hint(hint, 0)
    end
  else
    C.LSP_SIG_VT_NS = C.LSP_SIG_VT_NS or vim.api.nvim_create_namespace('lsp_signature_vt')

    helper.cleanup(false) -- cleanup extmark
  end
  -- floating win disabled
  if
    C.LSP_SIG_CFG.floating_window == false
    and config.toggle ~= true
    and config.trigger_from_lsp_sig
  then
    return {}, s, l
  end

  if C.LSP_SIG_CFG.floating_window == false and config.trigger_from_cursor_hold then
    return {}, s, l
  end
  local off_y
  local ft = vim.bo.filetype

  ft = helper.ft2md(ft)
  -- handles multiple file type, we should just take the first filetype
  -- find the first file type and substring until the .
  local dot_index = string.find(ft, '%.')
  if dot_index ~= nil then
    ft = string.sub(ft, 0, dot_index - 1)
  end

  local lines = vim.lsp.util.convert_signature_help_to_markdown_lines(result, ft)

  if lines == nil or type(lines) ~= 'table' then
    log('incorrect result', result)
    return
  end

  lines = helper.trim_empty_lines(lines)
  -- log('md lines trim', lines)
  local offset = 2
  local num_sigs = #result.signatures
  if #result.signatures > 1 then
    if string.find(lines[1], [[```]]) then -- markdown format start with ```, insert pos need after that
      log('line1 is markdown reset offset to 3')
      offset = 3
    end
    log('before insert', lines)
    for index, sig in ipairs(result.signatures) do
      sig.label = sig.label:gsub('%s+$', ''):gsub('\r', ' '):gsub('\n', ' ')
      if index ~= activeSignature then
        table.insert(lines, offset, sig.label)
        offset = offset + 1
      end
    end
  end

  -- log("md lines", lines)
  local label = result.signatures[1].label
  if #result.signatures > 1 then
    label = result.signatures[activeSignature].label
  end
  label = label:gsub('%s+$', ''):gsub('\r', ' '):gsub('\n', ' ')

  log(
    'label:',
    label,
    result.activeSignature,
    activeSignature,
    result.activeParameter,
    result.signatures[activeSignature]
  )

  -- truncate empty document it
  if
    result.signatures[activeSignature].documentation
    and result.signatures[activeSignature].documentation.kind == 'markdown'
    and result.signatures[activeSignature].documentation.value == '```text\n\n```'
  then
    result.signatures[activeSignature].documentation = nil
    lines = vim.lsp.util.convert_signature_help_to_markdown_lines(result, ft)

    log('md lines remove empty', lines)
  end

  local pos = api.nvim_win_get_cursor(0)
  local line = api.nvim_get_current_line()
  local line_to_cursor = line:sub(1, pos[2])

  local woff = 1
  if config.triggered_chars and vim.tbl_contains(config.triggered_chars, '(') then
    woff = helper.cal_woff(line_to_cursor, label)
  end

  -- total lines allowed
  if config.trigger_from_lsp_sig then
    lines = helper.truncate_doc(lines, num_sigs)
  end

  -- log(lines)
  if vim.tbl_isempty(lines) then
    log('WARN: signature is empty')
    return
  end
  local syntax = helper.try_trim_markdown_code_blocks(lines)

  if config.trigger_from_lsp_sig == true and C.LSP_SIG_CFG.preview == 'guihua' then
    -- This is a TODO
    error('guihua text view not supported yet')
  end
  helper.update_config(config)

  if type(C.LSP_SIG_CFG.fix_pos) == 'function' then
    local client = vim.lsp.get_client_by_id(client_id)
    C.LSP_SIG_CFG._fix_pos = C.LSP_SIG_CFG.fix_pos(result, client)
  else
    C.LSP_SIG_CFG._fix_pos = C.LSP_SIG_CFG.fix_pos or true
  end

  -- when should the floating close
  config.close_events = { 'BufHidden' } -- , 'InsertLeavePre'}
  if not C.LSP_SIG_CFG._fix_pos then
    config.close_events = close_events
  end
  if not config.trigger_from_lsp_sig then
    config.close_events = close_events
  end
  if force_redraw and C.LSP_SIG_CFG._fix_pos == false then
    config.close_events = close_events
  end
  if
    result.signatures[activeSignature].parameters == nil
    or #result.signatures[activeSignature].parameters == 0
  then
    -- auto close when fix_pos is false
    if C.LSP_SIG_CFG._fix_pos == false then
      config.close_events = close_events
    end
  end
  config.zindex = C.LSP_SIG_CFG.zindex

  -- fix pos
  -- log('win config', config)
  local new_line = helper.is_new_line()

  local display_opts

  display_opts, off_y = helper.cal_pos(lines, config)

  if C.LSP_SIG_CFG.hint_enable == true then
    local v_offy = off_y
    if v_offy < 0 then
      v_offy = 1 -- put virtual text below current line
    end
    virtual_hint(hint, v_offy)
  end

  if C.LSP_SIG_CFG.floating_window_off_x then
    local offx = C.LSP_SIG_CFG.floating_window_off_x
    if type(offx) == 'function' then
      woff = woff + offx({ x_off = woff })
    else
      woff = woff + offx
    end
  end

  config.offset_x = woff
  if C.LSP_SIG_CFG.padding ~= '' then
    for lineIndex = 1, #lines do
      lines[lineIndex] = C.LSP_SIG_CFG.padding .. lines[lineIndex] .. C.LSP_SIG_CFG.padding
    end
    config.offset_x = config.offset_x - #C.LSP_SIG_CFG.padding
  end

  if C.LSP_SIG_CFG.floating_window_off_y then
    config.offset_y = C.LSP_SIG_CFG.floating_window_off_y
    if type(config.offset_y) == 'function' then
      config.offset_y = C.LSP_SIG_CFG.floating_window_off_y(display_opts)
    end
  end

  config.offset_y = off_y + config.offset_y
  config.focusable = true -- allow focus
  config.max_height = display_opts.max_height
  config.noautocmd = true

  -- try not to overlap with pum autocomplete menu
  if
    config.check_completion_visible
    and helper.completion_visible()
    and ((display_opts.anchor == 'NW' or display_opts.anchor == 'NE') and off_y == 0)
    and C.LSP_SIG_CFG.zindex < 50
  then
    log('completion is visible, no need to show off_y', off_y)
    return
  end

  config.noautocmd = true
  log('floating opt', config, display_opts, off_y, lines, C.LSP_SIG_CFG.label, label, new_line)
  if C.LSP_SIG_CFG._fix_pos and C.LSP_SIG_CFG.bufnr and C.LSP_SIG_CFG.winnr then
    if
      api.nvim_win_is_valid(C.LSP_SIG_CFG.winnr)
      and C.LSP_SIG_CFG.label == label
      and not new_line
    then
      status_line = { hint = '', label = '', range = nil }
    else
      -- vim.api.nvim_win_close(C.LSP_SIG_CFG.winnr, true)

      -- vim.api.nvim_buf_set_option(C.LSP_SIG_CFG.bufnr, "filetype", "")
      log(
        'sig_cfg bufnr, winnr not valid recreate',
        C.LSP_SIG_CFG.bufnr,
        C.LSP_SIG_CFG.winnr,
        label == C.LSP_SIG_CFG.label,
        api.nvim_win_is_valid(C.LSP_SIG_CFG.winnr),
        not new_line
      )
      C.LSP_SIG_CFG.label = label
      C.LSP_SIG_CFG.client_id = client_id

      C.LSP_SIG_CFG.bufnr, C.LSP_SIG_CFG.winnr =
        vim.lsp.util.open_floating_preview(lines, syntax, config)
      helper.set_keymaps(C.LSP_SIG_CFG.winnr, C.LSP_SIG_CFG.bufnr)
    end
  else
    C.LSP_SIG_CFG.bufnr, C.LSP_SIG_CFG.winnr =
      vim.lsp.util.open_floating_preview(lines, syntax, config)
    C.LSP_SIG_CFG.label = label
    C.LSP_SIG_CFG.client_id = client_id
    vim.api.nvim_win_set_cursor(C.LSP_SIG_CFG.winnr, { 1, 0 })

    helper.set_keymaps(C.LSP_SIG_CFG.winnr, C.LSP_SIG_CFG.bufnr)
    log('sig_cfg new bufnr, winnr ', C.LSP_SIG_CFG.bufnr, C.LSP_SIG_CFG.winnr)
  end

  if
    C.LSP_SIG_CFG.transparency
    and C.LSP_SIG_CFG.transparency > 1
    and C.LSP_SIG_CFG.transparency < 100
  then
    if type(C.LSP_SIG_CFG.winnr) == 'number' and vim.api.nvim_win_is_valid(C.LSP_SIG_CFG.winnr) then
      vim.api.nvim_win_set_option(C.LSP_SIG_CFG.winnr, 'winblend', C.LSP_SIG_CFG.transparency)
    end
  end
  local sig = result.signatures
  -- if it is last parameter, close windows after cursor moved

  local actPar = sig.activeParameter or result.activeParameter or 0
  if
    sig and sig[activeSignature].parameters == nil
    or actPar == nil
    or actPar + 1 == #sig[activeSignature].parameters
  then
    log('last para', close_events)
    if C.LSP_SIG_CFG._fix_pos == false then
      vim.lsp.util.close_preview_autocmd(close_events, C.LSP_SIG_CFG.winnr)
    end
    if C.LSP_SIG_CFG.auto_close_after then
      helper.cleanup_async(true, C.LSP_SIG_CFG.auto_close_after)
      status_line = { hint = '', label = '', range = nil }
    end
  end
  helper.highlight_parameter(s, l)

  return lines, s, l
end

local line_to_cursor_old
local signature = function(opts)
  opts = opts or {}

  local bufnr = api.nvim_get_current_buf()
  local pos = api.nvim_win_get_cursor(0)
  local clients = helper.get_clients({ bufnr = bufnr })
  local ft = vim.opt_local.filetype:get()
  local disabled = { 'TelescopePrompt', 'guihua', 'guihua_rust', 'clap_input', '' }

  if vim.fn.empty(ft) == 1 or vim.tbl_contains(disabled, ft) then
    return log('skip: disabled filetype', ft)
  end
  if clients == nil or next(clients) == nil then
    return log('no active client')
  end

  local line = api.nvim_get_current_line()
  local line_to_cursor = line:sub(1, pos[2])
  local signature_cap, triggered, trigger_position, trigger_chars =
    helper.check_lsp_cap(clients, line_to_cursor)

  if signature_cap == false then
    return log('skip: signature capabilities not enabled')
  end

  local delta = line_to_cursor
  if line_to_cursor_old == nil then
    delta = line_to_cursor
  elseif #line_to_cursor_old > #line_to_cursor then
    delta = line_to_cursor_old:sub(#line_to_cursor)
  elseif #line_to_cursor_old < #line_to_cursor then
    delta = line_to_cursor:sub(#line_to_cursor_old)
  elseif not opts.trigger then
    line_to_cursor_old = line_to_cursor
    return
  end
  log('delta', delta, line_to_cursor, line_to_cursor_old, opts)
  line_to_cursor_old = line_to_cursor

  local should_trigger = false
  for _, c in ipairs(trigger_chars) do
    c = helper.replace_special(c)
    if delta:find(c) then
      should_trigger = true
    end
  end

  -- no signature is shown
  if not C.LSP_SIG_CFG.winnr or not vim.api.nvim_win_is_valid(C.LSP_SIG_CFG.winnr) then
    should_trigger = true
  end
  if not should_trigger then
    local mode = vim.api.nvim_get_mode().mode
    log('mode:   ', mode)
    if mode == 'niI' or mode == 'i' then
      -- line_to_cursor_old = ""
      log('should not trigger')
      return
    end
  end

  local params = vim.lsp.util.make_position_params()
  log('change trigger pos to ', params.position.character, trigger_position)
  local shift = math.max(1, trigger_position - 0)
  params.position.character = shift
  if opts.trigger == 'CursorHold' then
    return vim.lsp.buf_request(
      0,
      'textDocument/signatureHelp',
      params,
      vim.lsp.with(signature_handler, {
        trigger_from_cursor_hold = true,
        border = C.LSP_SIG_CFG.handler_opts.border,
        line_to_cursor = line_to_cursor:sub(1, trigger_position),
        triggered_chars = trigger_chars,
      })
    )
  end

  if opts.trigger == 'NextSignature' then
    if C.LSP_SIG_CFG.signature_result == nil or #C.LSP_SIG_CFG.signature_result.signatures < 2 then
      return
    end
    log(
      C.LSP_SIG_CFG.signature_result.activeSignature,
      C.LSP_SIG_CFG.signature_result.cfgActiveSignature
    )
    local sig = C.LSP_SIG_CFG.signature_result.signatures
    local actSig = (C.LSP_SIG_CFG.signature_result.cfgActiveSignature or 0) + 1
    if actSig > #sig then
      actSig = 1
    end

    return vim.lsp.buf_request(
      0,
      'textDocument/signatureHelp',
      params,
      vim.lsp.with(signature_handler, {
        check_completion_visible = true,
        trigger_from_next_sig = true,
        activeSignature = actSig,
        line_to_cursor = line_to_cursor:sub(1, trigger_position),
        border = C.LSP_SIG_CFG.handler_opts.border,
        triggered_chars = trigger_chars,
      })
    )
  end
  if triggered then
    -- Try using the already binded one, otherwise use it without custom config.
    -- LuaFormatter off
    vim.lsp.buf_request(
      0,
      'textDocument/signatureHelp',
      params,
      vim.lsp.with(signature_handler, {
        check_completion_visible = true,
        trigger_from_lsp_sig = true,
        line_to_cursor = line_to_cursor:sub(1, trigger_position),
        border = C.LSP_SIG_CFG.handler_opts.border,
        triggered_chars = trigger_chars,
      })
    )
    -- LuaFormatter on
  else
    -- check if we should close the signature
    if C.LSP_SIG_CFG.winnr and C.LSP_SIG_CFG.winnr > 0 then
      -- if check_closer_char(line_to_cursor, triggered_chars) then
      if vim.api.nvim_win_is_valid(C.LSP_SIG_CFG.winnr) then
        vim.api.nvim_win_close(C.LSP_SIG_CFG.winnr, true)
      end
      C.LSP_SIG_CFG.winnr = nil
      C.LSP_SIG_CFG.bufnr = nil
      C.LSP_SIG_CFG.startx = nil
      -- end
    end

    -- check should we close virtual hint
    if C.LSP_SIG_CFG.signature_result and C.LSP_SIG_CFG.signature_result.signatures ~= nil then
      local sig = C.LSP_SIG_CFG.signature_result.signatures
      local actSig = C.LSP_SIG_CFG.signature_result.activeSignature or 0
      local actPar = C.LSP_SIG_CFG.signature_result.activeParameter or 0
      actSig, actPar = actSig + 1, actPar + 1
      if
        sig[actSig] ~= nil
        and sig[actSig].parameters ~= nil
        and #sig[actSig].parameters == actPar
      then
        M.on_CompleteDone()
      end
      C.LSP_SIG_CFG.signature_result = nil
      C.LSP_SIG_CFG.activeSignature = nil
      C.LSP_SIG_CFG.activeParameter = nil
    end
  end
end

M.signature = signature

function M.on_InsertCharPre()
  manager.insertChar = true
end

function M.on_InsertLeave()
  line_to_cursor_old = ''
  local mode = vim.api.nvim_get_mode().mode

  log('mode:   ', mode)
  if mode == 'niI' or mode == 'i' or mode == 's' then
    log('mode:  niI ', vim.api.nvim_get_mode().mode)
    return
  end

  local delay = C.LSP_SIG_CFG.timer_interval or 200 -- 200ms
  vim.defer_fn(function()
    mode = vim.api.nvim_get_mode().mode
    log('mode:   ', mode)
    if mode == 'i' or mode == 's' then
      signature()
      -- still in insert mode debounce
      return
    end
    log('close timer')
    manager.insertLeave = true
    if manager.timer then
      manager.timer:stop()
      manager.timer:close()
      manager.timer = nil
    end
  end, delay)

  log('Insert leave cleanup')
  helper.cleanup_async(true, 10, true) -- defer close after 200+10ms
  status_line = { hint = '', label = '' }
end

local start_watch_changes_timer = function()
  if manager.timer then
    return
  end
  manager.changedTick = 0
  local interval = C.LSP_SIG_CFG.timer_interval or 200
  if manager.timer then
    manager.timer:stop()
    manager.timer:close()
    manager.timer = nil
  end
  manager.timer = vim.loop.new_timer()
  manager.timer:start(
    100,
    interval,
    vim.schedule_wrap(function()
      local l_changedTick = api.nvim_buf_get_changedtick(0)
      local m = vim.api.nvim_get_mode().mode
      -- log(m)
      if m == 'n' or m == 'v' then
        log('insert mode changed', m)
        M.on_InsertLeave()
        return
      end
      if l_changedTick ~= manager.changedTick then
        manager.changedTick = l_changedTick
        log('insert leave changed', m)
        signature()
      end
    end)
  )
end

function M.on_InsertEnter()
  log('insert enter')
  line_to_cursor_old = ''

  -- show signature immediately upon entering insert mode
  if manager.insertLeave == true then
    start_watch_changes_timer()
  end
  manager.init()
end

-- handle completion confirmation and dismiss hover popup
-- Note: this function may not work, depends on if complete plugin add parents or not
function M.on_CompleteDone()
  -- need auto brackets to make things work
  -- cleanup virtual hint
  local m = vim.api.nvim_get_mode().mode
  vim.api.nvim_buf_clear_namespace(0, C.LSP_SIG_VT_NS, 0, -1)
  if m == 'i' or m == 's' or m == 'v' then
    log('completedone ', m, 'enable signature ?')
  end

  log('Insert leave cleanup', m)
end

function M.on_UpdateSignature()
  -- need auto brackets to make things work
  local m = vim.api.nvim_get_mode().mode
  log('on update signature cursorhold', m)
  signature({ trigger = 'CursorHold' })
end

local function cleanup_logs()
  if C.LSP_SIG_CFG.debug ~= true then
    return
  end
  if not C.LSP_SIG_CFG.log_path then
    return
  end
  local log_path = C.LSP_SIG_CFG.log_path
  local fp = io.open(log_path, 'r')
  if fp then
    local size = fp:seek('end')
    fp:close()
    if size > 1234567 then
      os.remove(log_path)
    end
  end
end

M.on_attach = function(bufnr)
  bufnr = bufnr or api.nvim_get_current_buf()

  local augroup = api.nvim_create_augroup('Signature', { clear = false })
  api.nvim_create_autocmd('InsertEnter', {
    group = augroup,
    buffer = bufnr,
    callback = function()
      require('lsp_signature').on_InsertEnter()
    end,
    desc = 'signature on insert enter',
  })
  api.nvim_create_autocmd('InsertLeave', {
    group = augroup,
    buffer = bufnr,
    callback = function()
      require('lsp_signature').on_InsertLeave()
    end,
    desc = 'signature on insert leave',
  })
  api.nvim_create_autocmd('InsertCharPre', {
    group = augroup,
    buffer = bufnr,
    callback = function()
      require('lsp_signature').on_InsertCharPre()
    end,
    desc = 'signature on insert char pre',
  })
  api.nvim_create_autocmd('CompleteDone', {
    group = augroup,
    buffer = bufnr,
    callback = function()
      require('lsp_signature').on_CompleteDone()
    end,
    desc = 'signature on complete done',
  })

  helper.cursor_hold(C.LSP_SIG_CFG.cursorhold_update, bufnr)

  cleanup_logs()

  if C.LSP_SIG_CFG.bind then
    vim.lsp.handlers['textDocument/signatureHelp'] = vim.lsp.with(signature_handler, C.LSP_SIG_CFG.handler_opts)
  end

  local shadow_cmd = string.format(
    'hi default FloatShadow blend=%i guibg=%s',
    C.LSP_SIG_CFG.shadow_blend,
    C.LSP_SIG_CFG.shadow_guibg
  )
  vim.cmd(shadow_cmd)

  shadow_cmd = string.format(
    'hi default FloatShadowThrough blend=%i guibg=%s',
    C.LSP_SIG_CFG.shadow_blend + 20,
    C.LSP_SIG_CFG.shadow_guibg
  )
  vim.cmd(shadow_cmd)

  if C.LSP_SIG_CFG.toggle_key then
    vim.keymap.set({ 'i', 'v', 's' }, C.LSP_SIG_CFG.toggle_key, function()
      require('lsp_signature').toggle_float_win()
    end, { silent = true, noremap = true, buffer = bufnr, desc = 'toggle signature' })
  end
  if C.LSP_SIG_CFG.select_signature_key then
    vim.keymap.set('i', C.LSP_SIG_CFG.select_signature_key, function()
      require('lsp_signature').signature({ trigger = 'NextSignature' })
    end, { silent = true, noremap = true, buffer = bufnr, desc = 'select signature' })
  end
  if C.LSP_SIG_CFG.move_cursor_key then
    vim.keymap.set('i', C.LSP_SIG_CFG.move_cursor_key, function()
      require('lsp_signature.helper').change_focus()
    end, { silent = true, noremap = true, desc = 'change cursor focus' })
  end
  C.LSP_SIG_VT_NS = api.nvim_create_namespace('lsp_signature_vt')
end

local signature_should_close_handler = function(err, result, ctx, _)
  if err ~= nil then
    print(err)
    helper.cleanup_async(true, 0.01, true)
    status_line = { hint = '', label = '' }
    return
  end

  -- log('sig should cleanup?', result, ctx)
  local client_id = ctx.client_id
  local valid_result = result and result.signatures and result.signatures[1]
  local rlabel = nil
  if not valid_result then
    log('sig should cleanup? no valid result', result, ctx)
    -- only close if this client opened the signature
    if C.LSP_SIG_CFG.client_id == client_id then
      helper.cleanup_async(true, 0.01, true)
      status_line = { hint = '', label = '' }
      return
    end
  end

  -- corner case, result is not same
  if valid_result then
    rlabel =
      result.signatures[1].label:gsub('%s+$', ''):gsub('\r', ''):gsub('\n', ''):gsub('%s', '')
  end
  result = C.LSP_SIG_CFG.signature_result -- last signature result
  local last_valid_result = result and result.signatures and result.signatures[1]
  local llabel
  if last_valid_result then
    llabel =
      result.signatures[1].label:gsub('%s+$', ''):gsub('\r', ''):gsub('\n', ''):gsub('%s', '')
  end

  log(rlabel, llabel)

  if rlabel and rlabel ~= llabel then
    log('sig should cleanup? result not same', rlabel, llabel)
    helper.cleanup(true)
    status_line = { hint = '', label = '' }
    signature()
  end
end

M.check_signature_should_close = function()
  if
    C.LSP_SIG_CFG.winnr
    and C.LSP_SIG_CFG.winnr > 0
    and vim.api.nvim_win_is_valid(C.LSP_SIG_CFG.winnr)
  then
    local bufnr = vim.api.nvim_get_current_buf()
    local pos = api.nvim_win_get_cursor(0)
    local clients = helper.get_clients({ bufnr = bufnr })
    local line = api.nvim_get_current_line()
    local line_to_cursor = line:sub(1, pos[2])
    local signature_cap, triggered, trigger_position, _ =
      helper.check_lsp_cap(clients, line_to_cursor)
    if not signature_cap or not triggered then
      helper.cleanup_async(true, 0.01, true)
      status_line = { hint = '', label = '' }
      return
    end
    local params = vim.lsp.util.make_position_params()
    params.position.character = math.max(trigger_position, 1)
    line = api.nvim_get_current_line()
    line_to_cursor = line:sub(1, pos[2])
    -- Try using the already binded one, otherwise use it without custom config.
    -- LuaFormatter off
    vim.lsp.buf_request(
      0,
      'textDocument/signatureHelp',
      params,
      vim.lsp.with(signature_should_close_handler, {
        check_completion_visible = true,
        trigger_from_lsp_sig = true,
        line_to_cursor = line_to_cursor,
        border = C.LSP_SIG_CFG.handler_opts.border,
      })
    )
  end

  -- LuaFormatter on
end

M.status_line = function(size)
  size = size or 300
  if #status_line.label + #status_line.hint > size then
    local labelsize = size - #status_line.hint
    -- local hintsize = #status_line.hint
    if labelsize < 10 then
      labelsize = 10
    end
    return {
      hint = status_line.hint,
      label = status_line.label:sub(1, labelsize) .. [[󰇘]],
      range = status_line.range,
    }
  end
  return {
    hint = status_line.hint,
    label = status_line.label,
    range = status_line.range,
    doc = status_line.doc,
  }
end

-- Enables/disables lsp_signature.nvim
---@return boolean state true/false if enabled/disabled.
M.toggle_float_win = function()
  if C.LSP_SIG_CFG.toggle_key_flip_floatwin_setting == true then
    C.LSP_SIG_CFG.floating_window = not C.LSP_SIG_CFG.floating_window
  end

  if
    C.LSP_SIG_CFG.winnr
    and C.LSP_SIG_CFG.winnr > 0
    and vim.api.nvim_win_is_valid(C.LSP_SIG_CFG.winnr)
  then
    vim.api.nvim_win_close(C.LSP_SIG_CFG.winnr, true)
    C.LSP_SIG_CFG.winnr = nil
    C.LSP_SIG_CFG.bufnr = nil
    if C.LSP_SIG_VT_NS then
      vim.api.nvim_buf_clear_namespace(0, C.LSP_SIG_VT_NS, 0, -1)
    end

    helper.cursor_hold(false, vim.api.nvim_get_current_buf())
    vim.api.nvim_create_autocmd('InsertCharPre', {
      callback = function()
        -- disable cursor hold event until next insert enter
        helper.cursor_hold(C.LSP_SIG_CFG.cursorhold_update, vim.api.nvim_get_current_buf())
      end,
      once = true, -- trigger once
    })
    -- disable cursor hold event until next insert enter
    return C.LSP_SIG_CFG.floating_window
  end

  local clients = helper.get_clients({ bufnr = api.nvim_get_current_buf() })
  if clients == nil or next(clients) == nil then
    return C.LSP_SIG_CFG.floating_window
  end

  local params = vim.lsp.util.make_position_params()
  local pos = api.nvim_win_get_cursor(0)
  local line = api.nvim_get_current_line()
  local line_to_cursor = line:sub(1, pos[2])
  local _, _, _, trigger_chars = helper.check_lsp_cap(clients, line_to_cursor)
  -- Try using the already binded one, otherwise use it without custom config.
  -- LuaFormatter off
  vim.lsp.buf_request(
    0,
    'textDocument/signatureHelp',
    params,
    vim.lsp.with(signature_handler, {
      check_completion_visible = true,
      trigger_from_lsp_sig = true,
      toggle = true,
      line_to_cursor = line_to_cursor,
      border = C.LSP_SIG_CFG.handler_opts.border,
      triggered_chars = trigger_chars,
    })
  )
  -- LuaFormatter on
  return C.LSP_SIG_CFG.floating_window
end

M.signature_handler = signature_handler
-- setup function enable the signature and attach it to client
-- call it before startup lsp client

M.setup = function(user_cfg)
  log('user cfg:', user_cfg)

  C.setup(user_cfg)

  local _start_client = vim.lsp.start_client
  C.LSP_SIG_VT_NS = api.nvim_create_namespace('lsp_signature_vt')
  vim.lsp.start_client = function(lsp_config)
    if lsp_config.on_attach == nil then
      -- lsp_config.on_attach = function(client, bufnr)
      lsp_config.on_attach = function(_, bufnr)
        M.on_attach(bufnr)
      end
    else
      local _on_attach = lsp_config.on_attach
      lsp_config.on_attach = function(client, bufnr)
        M.on_attach(bufnr)
        _on_attach(client, bufnr)
      end
    end
    return _start_client(lsp_config)
  end
  vim.lsp.util.make_floating_popup_options =
    require('lsp_signature.helper').make_floating_popup_options

  -- default if not defined
  vim.cmd([[hi default link LspSignatureActiveParameter Search]])
end

return M
