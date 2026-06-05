-- ============================================================================
-- DEBUG LOGGING SYSTEM
-- Separated debug functionality for cleaner code organization
-- ============================================================================

local Debug = {}

-- Storage
local DEBUG_LOGS = {}

function Debug.enabled()
  if not game then return false end

  local global_settings = settings and settings.global
  local debug_setting = global_settings and global_settings["detonation-debug-mode"]
  return debug_setting and debug_setting.value == true
end

local function write_log(message)
  table.insert(DEBUG_LOGS, "[" .. game.tick .. "] " .. message)

  -- Print to all players with debug enabled
  for _, player in pairs(game.players) do
    if player.connected then
      player.print(message)
    end
  end
end

-- Add a log entry (only if debug mode enabled)
function Debug.log(message)
  if not Debug.enabled() then return end
  write_log(message)
end

-- Clear all logs
function Debug.clear()
  DEBUG_LOGS = {}
end

-- Create debug window GUI
function Debug.create_window(player)
  if not player or not player.valid then return end

  -- Close existing window if any
  if player.gui.screen.debug_log_window then
    player.gui.screen.debug_log_window.destroy()
  end

  -- Create main window
  local window = player.gui.screen.add {
    type = "frame",
    name = "debug_log_window",
    direction = "vertical",
    caption = "Detonation - Debug Logs"
  }
  window.auto_center = true

  -- Create scroll pane for logs
  local scroll = window.add {
    type = "scroll-pane",
    name = "log_scroll",
    vertical_scroll_policy = "always",
    horizontal_scroll_policy = "auto"
  }
  scroll.style.maximal_height = 600
  scroll.style.minimal_width = 800

  -- Create text box for logs
  local textbox = scroll.add {
    type = "text-box",
    name = "log_text",
    text = table.concat(DEBUG_LOGS, "\n")
  }
  textbox.read_only = true
  textbox.style.width = 780
  textbox.style.height = 580

  -- Create button bar
  local button_flow = window.add {
    type = "flow",
    name = "button_flow",
    direction = "horizontal"
  }

  button_flow.add {
    type = "button",
    name = "detonation_close_debug",
    caption = "Close"
  }

  button_flow.add {
    type = "button",
    name = "detonation_clear_debug",
    caption = "Clear Logs"
  }

  button_flow.add {
    type = "button",
    name = "detonation_refresh_debug",
    caption = "Refresh"
  }

  player.opened = window
end

-- Handle GUI clicks
function Debug.on_gui_click(event)
  local element = event.element
  if not element or not element.valid then return end

  local player = game.get_player(event.player_index)
  if not player then return end

  if element.name == "detonation_close_debug" then
    if player.gui.screen.debug_log_window then
      player.gui.screen.debug_log_window.destroy()
    end
  elseif element.name == "detonation_clear_debug" then
    Debug.clear()
    if player.gui.screen.debug_log_window then
      player.gui.screen.debug_log_window.destroy()
    end
    Debug.create_window(player)
  elseif element.name == "detonation_refresh_debug" then
    if player.gui.screen.debug_log_window then
      local textbox = player.gui.screen.debug_log_window.log_scroll.log_text
      if textbox then
        textbox.text = table.concat(DEBUG_LOGS, "\n")
      end
    end
  end
end

-- Register events
script.on_event(defines.events.on_gui_click, Debug.on_gui_click)

-- Commands
commands.add_command("detonation-debug", "Show debug logs window", function(command)
  local player = game.get_player(command.player_index)
  if player then
    Debug.create_window(player)
  end
end)

commands.add_command("detonation-toggle-debug", "Toggle debug mode", function(command)
  local current = settings.global["detonation-debug-mode"].value
  settings.global["detonation-debug-mode"] = { value = not current }

  local player = game.get_player(command.player_index)
  if player then
    player.print("Detonation debug mode: " .. tostring(not current))
  end
end)

return Debug
