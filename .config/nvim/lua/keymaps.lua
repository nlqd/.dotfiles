-- Sync clipboard between OS and Neovim.
--  Remove this option if you want your OS clipboard to remain independent.
--  See `:help 'clipboard'`
-- vim.o.clipboard = 'unnamedplus'
vim.keymap.set('v', '<leader>y', '\"+y', { desc = '[Y]ank to system' })

-- Magic keymap
vim.keymap.set("v", "J", ":m '>+1<CR>gv=gv")
vim.keymap.set("v", "K", ":m '<-2<CR>gv=gv")

-- vim.keymap.set('n', '<leader>-', '<CMD>Explore<CR>')
vim.keymap.set('n', '<leader>-', '<CMD>Oil<CR>')


-- Since Telescope is too smart
vim.keymap.set('n', '<leader>ee', '<CMD>new .env<CR>', { desc = '[E]dit [E]nv' })
vim.keymap.set('n', '<leader>ej', '<CMD>new .envs/.local/.django<CR>', { desc = '[E]dit D[J]ango env' })

-- [[ Basic Keymaps ]]

-- Keymaps for better default experience
vim.keymap.set({ 'n', 'v' }, '<Space>', '<Nop>', { silent = true })

-- Remap for dealing with word wrap
vim.keymap.set({ 'n', 'v' }, 'k', "v:count == 0 ? 'gk' : 'k'", { expr = true, silent = true })
vim.keymap.set({ 'n', 'v' }, 'j', "v:count == 0 ? 'gj' : 'j'", { expr = true, silent = true })

-- Set highlight on search, but clear on pressing <Esc> in normal mode
vim.opt.hlsearch = true
vim.keymap.set('n', '<C-c>', '<cmd>nohlsearch<CR>')
