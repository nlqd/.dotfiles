local wezterm = require 'wezterm'

local config = wezterm.config_builder()

if os.getenv('USER') == 'dungngo' then
  config.font = wezterm.font('BerkeleyMono Nerd Font Mono', { weight = 'Regular' })
  config.font_size = 16.0
  config.line_height = 1.3
else
  config.font = wezterm.font('Iosevka NF', { weight = 'Regular' })
  config.font_size = 12.0
  config.line_height = 1.2
end
config.window_decorations = 'RESIZE'

config.hide_mouse_cursor_when_typing = false
config.hide_tab_bar_if_only_one_tab = true

config.enable_scroll_bar = false
config.use_fancy_tab_bar = false
config.tab_bar_at_bottom = true
config.freetype_load_target = 'HorizontalLcd'
config.warn_about_missing_glyphs = false

config.keys = {
  { mods = 'SHIFT | CTRL', key = '^', action = wezterm.action.DisableDefaultAssignment, },
  { mods = 'CTRL', key = 'Return', action = wezterm.action.DisableDefaultAssignment, },
}

config.window_padding = {
  left   = 16,
  right  = 16,
  top    = 16,
  bottom = 16,
}

function scheme_for_appearance(appearance)
  local lighttheme = 'nvim_default_light'
  local darktheme = 'nvim_default_dark'

  if os.getenv('USER') == 'dungngo' then
    return lighttheme
  end

  if appearance:find 'Dark' then
    return darktheme
  else
    return lighttheme
  end
end

wezterm.on('window-config-reloaded', function(window, pane)
  local overrides = window:get_config_overrides() or {}
  local appearance = window:get_appearance()
  local scheme = scheme_for_appearance(appearance)
  if overrides.color_scheme ~= scheme then
    overrides.color_scheme = scheme
    window:set_config_overrides(overrides)
  end
end)

-- claude-code
config.keys = {
  {key="Enter", mods="SHIFT", action=wezterm.action{SendString="\x1b\r"}},
}

return config
