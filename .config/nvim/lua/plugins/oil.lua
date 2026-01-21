return {
    'stevearc/oil.nvim',
    opts = {
        default_file_explorer = true,
        columns = { "icon" },
        -- constrain_cursor = "editable",
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
    }
}
