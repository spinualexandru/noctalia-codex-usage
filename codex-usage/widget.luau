--!nonstrict

local STATE_KEY = "usage_snapshot"
local PANEL_ID = "spinualexandru/codex-usage:details"
local snapshot = noctalia.state.get(STATE_KEY) or { status = "loading" }

local function tr(key, substitutions)
  return noctalia.tr(key, substitutions)
end

local function showFiveHour()
  local value = noctalia.getConfig("show_five_hour_bar")
  return value == true or value == "true"
end

-- The bar's standard presentation settings ("Color" / "Icon Color") are seeded under
-- these keys; an empty value means the user left them unset.
local function configuredColor(key)
  local value = noctalia.getConfig(key)
  if type(value) == "string" and value ~= "" then
    return value
  end
  return nil
end

local function roundedPercent(window)
  if type(window) ~= "table" or tonumber(window.usedPercent) == nil then
    return nil
  end
  return math.floor(math.max(0, math.min(100, window.usedPercent)) + 0.5)
end

local function percentText(window)
  local percent = roundedPercent(window)
  return percent ~= nil and (`{percent}%`) or "—"
end

local function accent(window)
  local percent = roundedPercent(window)
  if percent == nil then
    return "on_surface_variant"
  elseif percent >= 90 then
    return "error"
  elseif percent >= 75 then
    return "secondary"
  end
  return "primary"
end

local function resetText(window)
  if type(window) ~= "table" or tonumber(window.resetAt) == nil then
    return tr("labels.reset_unknown")
  end

  local remaining = math.max(0, math.floor(window.resetAt - os.time()))
  if remaining == 0 then
    return tr("labels.reset_now")
  end
  local days = remaining // 86400
  local hours = (remaining % 86400) // 3600
  local minutes = math.max(1, (remaining % 3600) // 60)
  if days > 0 then
    return `{days}d {hours}h`
  elseif hours > 0 then
    return `{hours}h {minutes}m`
  end
  return `{minutes}m`
end

local function percentage(window)
  return ui.label({
    text = percentText(window),
    color = configuredColor("color") or accent(window),
    fontWeight = "bold",
  })
end

local function render()
  local container = barWidget.isVertical() and ui.column or ui.row
  local children = { ui.glyph({ name = "brand-openai", color = configuredColor("icon_color") or configuredColor("color") }) }
  if showFiveHour() then
    table.insert(children, percentage(snapshot.fiveHour))
  end
  table.insert(children, percentage(snapshot.weekly))
  barWidget.render(container({ gap = 6, align = "center" }, children))

  local tooltip = {}
  if showFiveHour() then
    table.insert(tooltip, {
      key = tr("labels.five_hour"),
      value = tr("labels.usage_and_reset", {
        percent = percentText(snapshot.fiveHour),
        time = resetText(snapshot.fiveHour),
      }),
    })
  end
  table.insert(tooltip, {
    key = tr("labels.weekly"),
    value = tr("labels.usage_and_reset", {
      percent = percentText(snapshot.weekly),
      time = resetText(snapshot.weekly),
    }),
  })
  if snapshot.status == "loading" then
    table.insert(tooltip, { key = tr("labels.status"), value = tr("status.loading") })
  elseif snapshot.error ~= nil then
    table.insert(tooltip, { key = tr("labels.status"), value = snapshot.error })
  end
  barWidget.setTooltip(tooltip)
end

noctalia.setUpdateInterval(60000)

noctalia.state.watch(STATE_KEY, function(value)
  snapshot = type(value) == "table" and value or { status = "loading" }
  render()
end)

function update()
  render()
end

function onConfigChanged()
  render()
end

function onClick()
  noctalia.togglePanel(PANEL_ID)
end

render()
