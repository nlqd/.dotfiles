-- Highlight on yank
vim.api.nvim_create_autocmd('TextYankPost', {
    callback = function() vim.highlight.on_yank() end,
    group = vim.api.nvim_create_augroup('YankHighlight', { clear = true }),
    pattern = '*',
})

-- Crude Make command
vim.api.nvim_create_user_command('Make', function(opts)
    local command = table.concat(opts.fargs, ' ') or vim.o.makeprg
    vim.cmd([[below terminal ]] .. command)
    vim.api.nvim_win_set_height(0, math.floor(vim.api.nvim_win_get_height(0) / 2))
end, {
        nargs = '*',
        complete = function(ArgLead, CmdLine, CursorPos)
            -- return completion candidates as a list-like table
            return { "foo", "bar", "baz" }
        end,
    })
