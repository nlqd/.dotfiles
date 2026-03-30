-- options
vim.g.mapleader = ' '
vim.g.maplocalleader = ' '
vim.o.background = 'light'
vim.o.colorcolumn = '100'
vim.o.tabstop = 4
vim.o.shiftwidth = 4
vim.o.breakindent = true
vim.wo.number = true
vim.o.relativenumber = true
vim.o.updatetime = 250
vim.o.timeout = true
vim.o.timeoutlen = 300
vim.o.mouse = 'a'
vim.o.undofile = true
vim.o.ignorecase = true
vim.o.smartcase = true
vim.wo.signcolumn = 'yes'
vim.o.complete = vim.o.complete .. ',i,kspell'
vim.o.completeopt = 'fuzzy,menuone,noselect'
vim.o.termguicolors = true
vim.o.splitright = true
vim.o.list = true
vim.o.listchars = "tab:» ,trail:·,nbsp:␣"
vim.o.inccommand = 'split'
vim.o.cursorline = true
vim.o.scrolloff = 10
vim.o.exrc = true
vim.o.hlsearch = true

-- Keymaps
vim.keymap.set('v', '<leader>y', '\"+y', { desc = '[Y]ank to system' })
vim.keymap.set("v", "J", ":m '>+1<CR>gv=gv")
vim.keymap.set("v", "K", ":m '<-2<CR>gv=gv")
vim.keymap.set('n', 'k', "v:count == 0 ? 'gk' : 'k'", { expr = true, silent = true })
vim.keymap.set('n', 'j', "v:count == 0 ? 'gj' : 'j'", { expr = true, silent = true })
vim.keymap.set('n', '<C-c>', '<cmd>nohlsearch<CR>')

-- Autocmds
vim.api.nvim_create_autocmd('TextYankPost', {
    callback = function() vim.highlight.on_yank() end,
    group = vim.api.nvim_create_augroup('YankHighlight', { clear = true }),
    pattern = '*',
})
vim.api.nvim_create_user_command('Make', function(opts)
    local command = table.concat(opts.fargs, ' ') or vim.o.makeprg
    vim.cmd([[below terminal ]] .. command)
    vim.api.nvim_win_set_height(0, math.floor(vim.api.nvim_win_get_height(0) / 2))
end, { nargs = '*' })

-- helper
local gh = function(x) return 'https://github.com/' .. x end
vim.pack.add({ gh('folke/which-key.nvim') })
vim.pack.add({ gh('iamcco/markdown-preview.nvim') })
vim.pack.add({ gh('nvim-lua/plenary.nvim') })
vim.pack.add({ gh('nvim-tree/nvim-web-devicons') })
vim.pack.add({ gh('stefandtw/quickfix-reflector.vim') })
vim.pack.add({ gh('tpope/vim-fugitive') })
vim.pack.add({ gh('tpope/vim-projectionist') })
vim.pack.add({ gh('tpope/vim-sleuth') })

-- lsp
vim.pack.add({
    gh('neovim/nvim-lspconfig'),
    gh('j-hui/fidget.nvim'),
    gh('nvimtools/none-ls.nvim'),
})
require('fidget').setup({})
require('null-ls').setup({
    sources = { require('null-ls').builtins.formatting.prettier },
})
vim.diagnostic.config({ virtual_text = { current_line = true } })
vim.keymap.set('n', '<leader>gf', vim.lsp.buf.format, { desc = '[G]o and [F]ormat the code' })
vim.lsp.config('lua_ls', { settings = { Lua = {
    runtime = { version = 'LuaJIT' },
    diagnostics = { globals = { 'vim', 'require' }},
    workspace = { library = vim.api.nvim_get_runtime_file("", true) },
}}})
vim.lsp.enable({ 'lua_ls', 'ts_ls', 'pyright', 'rust_analyzer', 'gopls' })

-- mason
vim.pack.add({
    gh('williamboman/mason.nvim'),
    gh('williamboman/mason-lspconfig.nvim'),
})
require('mason').setup()
require('mason-lspconfig').setup()

-- oil
vim.pack.add({ gh('stevearc/oil.nvim') })
require('oil').setup({
    default_file_explorer = true,
    columns = { "icon" },
    constrain_cursor = "editable",
    delete_to_trash = true,
    view_options = {
        show_hidden = true,
        natural_order = true,
        is_always_hidden = function(name, _)
            return name == ".."
        end
    },
    win_options = {
        wrap = true,
    },
    keymaps = {
        ["gd"] = function ()
            if #require("oil.config").columns == 1 then
                require("oil").set_columns({ "icon", "premissions", "size", "mtime" })
            else
                require("oil").set_columns({ "icon" })
            end
        end
    },
})
vim.keymap.set('n', '<leader>-', '<CMD>Oil<CR>')

-- gitsigns
vim.pack.add({ gh('lewis6991/gitsigns.nvim') })
require('gitsigns').setup({
    current_line_blame = true,
    on_attach = function()
        local gitsigns = require('gitsigns')
        local function map(mode, l, r, opts)
            opts = opts or {}
            -- opts.buffer = bufnr
            vim.keymap.set(mode, l, r, opts)
        end
        map('n', ']c', function()
            if vim.wo.diff then
                vim.cmd.normal({ ']c', bang = true })
            else
                gitsigns.nav_hunk('next')
            end
        end, { desc = 'Go to next git change'})
        map('n', '[c', function()
            if vim.wo.diff then
                vim.cmd.normal({ '[c', bang = true })
            else
                gitsigns.nav_hunk('prev')
            end
        end, { desc = 'Go to prev git change'})
        map('n', '<leader>gp', gitsigns.preview_hunk, { desc = '[G]itsigns [P]review Hunk'})
    end
})

-- indent-blankline
vim.pack.add({gh('lukas-reineke/indent-blankline.nvim'),})
require('ibl').setup({
    debounce = 100,
    indent = { char = "┊" },
    whitespace = { highlight = { "Whitespace", "NonText" } },
    scope = { exclude = { language = { "lua" } } },
})

-- multi.lua
vim.pack.add({ gh('jake-stewart/multicursor.nvim') })
local mc = require("multicursor-nvim")
mc.setup()
-- Add or skip cursor above/below the main cursor.
vim.keymap.set({ "n", "x" }, "<up>", function() mc.lineAddCursor(-1) end)
vim.keymap.set({ "n", "x" }, "<down>", function() mc.lineAddCursor(1) end)
vim.keymap.set({ "n", "x" }, "<leader><up>", function() mc.lineSkipCursor(-1) end)
vim.keymap.set({ "n", "x" }, "<leader><down>", function() mc.lineSkipCursor(1) end)
-- Add or skip adding a new cursor by matching word/selection
vim.keymap.set({ "n", "x" }, "<leader>n", function() mc.matchAddCursor(1) end)
vim.keymap.set({ "n", "x" }, "<leader>s", function() mc.matchSkipCursor(1) end)
vim.keymap.set({ "n", "x" }, "<leader>N", function() mc.matchAddCursor(-1) end)
vim.keymap.set({ "n", "x" }, "<leader>S", function() mc.matchSkipCursor(-1) end)
mc.addKeymapLayer(function(layerSet)
    layerSet("n", "<esc>", function()
        if not mc.cursorsEnabled() then
            mc.enableCursors()
        else
            mc.clearCursors()
        end
    end)
end)

-- treesitter
vim.pack.add({
    gh('nvim-treesitter/nvim-treesitter'),
    gh('nvim-treesitter/nvim-treesitter-context'),
    gh('nvim-treesitter/nvim-treesitter-textobjects'),
})
require('treesitter-context').setup({
    multiline_threshold = 1,
    max_lines = 4,
})
--     incremental_selection = {
--     enable = true,
--     keymaps = {
--         init_selection = '<c-space>',
--         node_incremental = '<c-space>',
--         scope_incremental = '<c-s>',
--         node_decremental = '<M-space>',
--     },
--     },
--     textobjects = {
--     move = {
--         enable = true,
--         set_jumps = true,     -- whether to set jumps in the jumplist
--         goto_next_start = {
--         [']m'] = '@function.outer',
--         [']]'] = '@class.outer',
--         },
--         goto_next_end = {
--         [']M'] = '@function.outer',
--         [']['] = '@class.outer',
--         },
--         goto_previous_start = {
--         ['[m'] = '@function.outer',
--         ['[['] = '@class.outer',
--         },
--         goto_previous_end = {
--         ['[M'] = '@function.outer',
--         ['[]'] = '@class.outer',
--         },
--     },
--     },
-- })

-- todo-comments
vim.pack.add({ gh('folke/todo-comments.nvim') })
require('todo-comments').setup({ signs = false })

-- undotree
vim.pack.add({ gh('mbbill/undotree') })
vim.keymap.set('n', '<leader>u', '<cmd>UndotreeToggle<CR>', { desc = '[U]ndoTree' })

-- vim-slime.lua
vim.pack.add({ gh('jpalardy/vim-slime') })
vim.g.slime_no_mappings = 1
vim.g.slime_cell_delimiter = "# %%"
vim.g.slime_target = 'tmux'
vim.g.slime_bracketed_paste = 1
vim.keymap.set('n', '<leader>s',  '<Plug>SlimeRegionSend')
vim.keymap.set('n', '<leader>ss', '<Plug>SlimeLineSend')
vim.keymap.set('n', '<leader>sc', '<Plug>SlimeSendCell')

-- vimtex
vim.pack.add({ gh('lervag/vimtex') })
vim.g.vimtex_view_method = "zathura"
vim.g.vimtex_quickfix_open_on_warning = 0

-- dadbod
vim.pack.add({
    gh('tpope/vim-dadbod'),
    gh('kristijanhusak/vim-dadbod-completion'),
    gh('kristijanhusak/vim-dadbod-ui'),
})
vim.g.db_ui_winwidth = 30
vim.g.db_ui_use_nerd_fonts = 1
