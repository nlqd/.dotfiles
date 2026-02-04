return {
    'nvim-treesitter/nvim-treesitter',
    dependencies = {
        'nvim-treesitter/nvim-treesitter-textobjects',
        {
            'nvim-treesitter/nvim-treesitter-context',
            opts = {
                multiline_threshold = 1,
                max_lines = 4,
            },
        },
    },
    config = function()
        local parser_config = require "nvim-treesitter.parsers".get_parser_configs()
        parser_config.move = {
            install_info = {
                url = (vim.env.DEV_HOME or "~/Desktop/DungNgo") .. "/tree-sitter-move",
                files = { "src/parser.c" },
            },
            filetype = "move",
        }

        require('nvim-treesitter.configs').setup {
            ensure_installed = {
                'c', 'cpp', 'go', 'lua', 'python', 'rust', 'tsx', 'typescript',
                'vim', 'html', 'javascript', 'json', 'vimdoc', 'move'
            },
            ignore_install = {},

            modules = {},

            auto_install = false,
            sync_install = false,

            highlight = { enable = true },
            indent = { enable = true, disable = { 'python' } },
            incremental_selection = {
                enable = true,
                keymaps = {
                    init_selection = '<c-space>',
                    node_incremental = '<c-space>',
                    scope_incremental = '<c-s>',
                    node_decremental = '<M-space>',
                },
            },
            textobjects = {
                select = {
                    enable = true,
                    lookahead = true,
                    keymaps = {
                        -- You can use the capture groups defined in textobjects.scm
                        ['aa'] = '@parameter.outer',
                        ['ia'] = '@parameter.inner',
                        ['af'] = '@function.outer',
                        ['if'] = '@function.inner',
                        ['ac'] = '@class.outer',
                        ['ic'] = '@class.inner',
                    },
                },
                move = {
                    enable = true,
                    set_jumps = true,     -- whether to set jumps in the jumplist
                    goto_next_start = {
                        [']m'] = '@function.outer',
                        [']]'] = '@class.outer',
                    },
                    goto_next_end = {
                        [']M'] = '@function.outer',
                        [']['] = '@class.outer',
                    },
                    goto_previous_start = {
                        ['[m'] = '@function.outer',
                        ['[['] = '@class.outer',
                    },
                    goto_previous_end = {
                        ['[M'] = '@function.outer',
                        ['[]'] = '@class.outer',
                    },
                },
            },
        }
    end,
}
