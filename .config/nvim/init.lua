vim.g.mapleader = ' '
vim.g.maplocalleader = ' '

require 'options'
require 'keymaps'
require 'autocmds'
require 'lazy-bootstrap'

require('fim-simple').setup({
  -- model = "codellama:7b-code",
  model = "qwen2.5-coder:14b-base",
})

vim.keymap.set('i', '<C-f>', function()
  require('fim-simple').fill_in_middle()
end, { desc = "FIM" })

-- vim: ts=2 sts=2 sw=2 et
