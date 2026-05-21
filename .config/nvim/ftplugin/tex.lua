local enabled = false

vim.api.nvim_create_augroup('Fcitx5Handler', { clear = true })

local function magic()
    vim.api.nvim_create_autocmd('InsertEnter', {
        pattern = { '*.tex' },
        group = 'Fcitx5Handler',
        callback = function ()
            vim.fn.execute([[ !fcitx5-remote -o ]], 'silent!')
        end,
    })

    vim.api.nvim_create_autocmd('InsertLeave', {
        pattern = { '*.tex' },
        group = 'Fcitx5Handler',
        callback = function ()
            vim.fn.execute([[ !fcitx5-remote -c ]], 'silent!')
        end,
    })
end

vim.api.nvim_create_user_command('Bamboo', function()
    enabled = not enabled
    if enabled then
        magic()
    else
        vim.api.nvim_clear_autocmds({ group = 'Fcitx5Handler' })
    end
end, {})
