return {
    'saghen/blink.cmp',
    event = 'VeryLazy',
    dependencies = {
        'rafamadriz/friendly-snippets',
    },

    -- use a release tag to download pre-built binaries
    version = '*',

    opts = {
        keymap = {
            preset = 'default',
            ['<Up>'] = {},
            ['<Down>'] = {},
        },
        appearance = {
            use_nvim_cmp_as_default = true,
            nerd_font_variant = 'mono',
        },
        completion = {
            documentation = { auto_show = true, auto_show_delay_ms = 500 },
        },
        sources = {
            default = { 'lsp', 'snippets', 'buffer', 'path' },
            per_filetype = {
                sql = { 'dadbod', 'snippets', 'buffer' },
            },
            providers = {
                dadbod = { module = 'vim_dadbod_completion.blink' },
            },
        },
        signature = { enabled = true },
    },
    opts_extend = { "sources.default" },
}
