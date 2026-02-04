-- Simple Fill-In-Middle completion for Neovim with Virtual Text Preview
-- Requires: Ollama running locally, Neovim 0.10+
-- Usage: :lua require('fim-simple').fill_in_middle()

local M = {}

-- Configuration
local config = {
  model = "codellama:7b-code",
  api_url = "http://127.0.0.1:11434/api/generate",
  temperature = 0.2,
  num_predict = 128,
  context_lines = 50,
}

-- State for preview
local preview_state = {
  ns_id = vim.api.nvim_create_namespace('fim_preview'),
  extmark_id = nil,
  completion_lines = nil,
  cursor_pos = nil,
  bufnr = nil,
}

-- Extract code before and after cursor
local function extract_context()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local cursor_row, cursor_col = cursor[1], cursor[2]
  local bufnr = vim.api.nvim_get_current_buf()
  local total_lines = vim.api.nvim_buf_line_count(bufnr)

  local current_line = vim.api.nvim_get_current_line()
  local line_before = current_line:sub(1, cursor_col)
  local line_after = current_line:sub(cursor_col + 1)

  local start_row = math.max(0, cursor_row - config.context_lines)
  local lines_before = vim.api.nvim_buf_get_lines(bufnr, start_row, cursor_row - 1, false)
  table.insert(lines_before, line_before)
  local prefix = table.concat(lines_before, "\n")

  local end_row = math.min(total_lines, cursor_row + config.context_lines)
  local lines_after = vim.api.nvim_buf_get_lines(bufnr, cursor_row, end_row, false)
  table.insert(lines_after, 1, line_after)
  local suffix = table.concat(lines_after, "\n")

  return prefix, suffix, cursor_row, cursor_col
end

-- Parse completion from response
local function extract_completion(response)
  local cleaned = response:gsub("<EOT>", ""):gsub("<|endoftext|>", "")
  return cleaned:match("^%s*(.-)%s*$")
end

-- Clear any existing preview
local function clear_preview()
  if preview_state.extmark_id then
    vim.api.nvim_buf_del_extmark(preview_state.bufnr, preview_state.ns_id, preview_state.extmark_id)
    preview_state.extmark_id = nil
    preview_state.completion_lines = nil
  end
end

-- Show loading indicator
local function show_loading(row, col)
  local bufnr = vim.api.nvim_get_current_buf()
  preview_state.bufnr = bufnr

  preview_state.extmark_id = vim.api.nvim_buf_set_extmark(bufnr, preview_state.ns_id, row - 1, col, {
    virt_text = {{"⏳ Generating...", "Comment"}},
    virt_text_pos = "eol",
  })
end

-- Show completion as virtual text (ghost text)
local function show_preview(completion, row, col)
  clear_preview()

  local bufnr = vim.api.nvim_get_current_buf()
  preview_state.bufnr = bufnr
  preview_state.cursor_pos = {row, col}

  local lines = vim.split(completion, "\n", {plain = true})
  preview_state.completion_lines = lines

  -- Show first line as inline virtual text
  local first_line = lines[1] or ""
  local virt_lines = {}

  -- If multi-line, show remaining lines below
  if #lines > 1 then
    for i = 2, #lines do
      table.insert(virt_lines, {{lines[i], "Comment"}})
    end
  end

  preview_state.extmark_id = vim.api.nvim_buf_set_extmark(bufnr, preview_state.ns_id, row - 1, col, {
    virt_text = {{first_line, "Comment"}},
    virt_text_pos = "inline",
    virt_lines = virt_lines,
    hl_mode = "combine",
  })

  -- Show hint
  vim.api.nvim_echo({{" Tab ", "MoreMsg"}, {" to accept | ", "Normal"}, {" Ctrl+e ", "WarningMsg"}, {" to reject", "Normal"}}, false, {})
end

-- Accept the completion
local function accept_completion()
  if not preview_state.completion_lines then
    return
  end

  local lines = preview_state.completion_lines
  local row, col = preview_state.cursor_pos[1], preview_state.cursor_pos[2]
  local bufnr = preview_state.bufnr

  -- Need to exit insert mode, make changes, then re-enter
  vim.schedule(function()
    -- Save mode
    local mode = vim.api.nvim_get_mode().mode

    -- Exit insert mode if we're in it
    if mode == 'i' then
      vim.cmd('stopinsert')
    end

    -- Insert the completion
    vim.api.nvim_buf_set_text(bufnr, row - 1, col, row - 1, col, lines)

    -- Move cursor to end
    local last_line_len = #lines[#lines]
    local new_row = row + #lines - 1
    local new_col = #lines == 1 and col + last_line_len or last_line_len
    vim.api.nvim_win_set_cursor(0, {new_row, new_col})

    clear_preview()

    -- Re-enter insert mode if we were in it
    if mode == 'i' then
      vim.cmd('startinsert!')
    end

    vim.api.nvim_echo({{"✓ Accepted", "String"}}, false, {})
  end)
end

-- Reject the completion
local function reject_completion()
  clear_preview()
  vim.api.nvim_echo({{"✗ Rejected", "WarningMsg"}}, false, {})
end

-- Set up keybindings for accept/reject (once per buffer)
local setup_buffers = {}
local function setup_preview_keymaps()
  local bufnr = vim.api.nvim_get_current_buf()
  if setup_buffers[bufnr] then return end
  setup_buffers[bufnr] = true

  -- Tab to accept (Ctrl+y also works)
  vim.keymap.set('i', '<Tab>', function()
    if preview_state.extmark_id then
      accept_completion()
    else
      vim.api.nvim_feedkeys('\t', 'n', true)
    end
  end, { buffer = bufnr, desc = "Accept FIM" })

  vim.keymap.set('i', '<C-y>', function()
    if preview_state.extmark_id then
      accept_completion()
    end
  end, { buffer = bufnr, desc = "Accept FIM" })

  -- Ctrl+e to reject (keeps you in insert mode)
  vim.keymap.set('i', '<C-e>', function()
    if preview_state.extmark_id then
      reject_completion()
    end
  end, { buffer = bufnr, desc = "Reject FIM" })

  -- Auto-clear preview when leaving insert mode
  vim.api.nvim_create_autocmd("InsertLeave", {
    buffer = bufnr,
    callback = function()
      if preview_state.extmark_id then
        vim.schedule(function()
          clear_preview()
          vim.api.nvim_echo({{"✗ Rejected (left insert mode)", "WarningMsg"}}, false, {})
        end)
      end
    end,
  })
end

-- Call Ollama API using vim.system (Neovim 0.10+)
local function call_ollama(prefix, suffix, callback)
  local payload = vim.json.encode({
    model = config.model,
    prompt = prefix,
    suffix = suffix,
    stream = false,
    options = {
      temperature = config.temperature,
      num_predict = config.num_predict,
    }
  })

  vim.system(
    {"curl", "-s", "-X", "POST", config.api_url, "-H", "Content-Type: application/json", "-d", payload},
    { text = true },
    function(result)
      if result.code ~= 0 then
        vim.schedule(function()
          clear_preview()
          vim.notify("❌ Ollama request failed: " .. (result.stderr or "Unknown error"), vim.log.levels.ERROR)
        end)
        return
      end

      local ok, response = pcall(vim.json.decode, result.stdout)
      if ok and response.response then
        callback(response.response)
      elseif ok and response.error then
        vim.schedule(function()
          clear_preview()
          vim.notify("❌ Ollama error: " .. response.error, vim.log.levels.ERROR)
        end)
      else
        vim.schedule(function()
          clear_preview()
          vim.notify("❌ Failed to parse response", vim.log.levels.ERROR)
        end)
      end
    end
  )
end

-- Main function to trigger FIM completion
function M.fill_in_middle()
  -- Clear any existing preview
  clear_preview()

  local prefix, suffix, cursor_row, cursor_col = extract_context()

  -- Show loading indicator
  show_loading(cursor_row, cursor_col)

  -- Set up keymaps if not already done
  setup_preview_keymaps()

  call_ollama(prefix, suffix, function(completion_text)
    vim.schedule(function()
      local completion = extract_completion(completion_text)

      if not completion or completion == "" then
        clear_preview()
        vim.notify("⚠ No completion generated", vim.log.levels.WARN)
        return
      end

      -- Show preview
      show_preview(completion, cursor_row, cursor_col)
    end)
  end)
end

-- Setup function to customize config
function M.setup(opts)
  config = vim.tbl_deep_extend("force", config, opts or {})
end

return M
