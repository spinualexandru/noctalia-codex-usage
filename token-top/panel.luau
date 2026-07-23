--!nonstrict

local STATE_KEY = "usage_snapshot"
local REFRESH_REQUEST_KEY = "refresh_request"
local snapshot = noctalia.state.get(STATE_KEY) or { status = "loading" }
local opened = false
local COMMERCIAL_PLAN_NAMES = {
  free = "ChatGPT Free",
  free_workspace = "ChatGPT Free",
  guest = "ChatGPT Free",
  go = "ChatGPT Go Subscription",
  plus = "ChatGPT Plus Subscription",
  prolite = "ChatGPT Pro 5x Subscription",
  pro_lite = "ChatGPT Pro 5x Subscription",
  pro = "ChatGPT Pro 20x Subscription",
  team = "ChatGPT Business",
  self_serve_business_usage_based = "ChatGPT Business",
  business = "ChatGPT Enterprise",
  enterprise_cbp_usage_based = "ChatGPT Enterprise",
  enterprise = "ChatGPT Enterprise",
  hc = "ChatGPT Enterprise",
  education = "ChatGPT Edu",
  edu = "ChatGPT Edu",
  k12 = "ChatGPT Edu",
  quorum = "ChatGPT Enterprise",
}

local function tr(key, substitutions)
  return noctalia.tr(key, substitutions)
end

local function showFiveHour()
  local value = noctalia.getConfig("show_five_hour_panel")
  return value == true or value == "true"
end

local function roundedPercent(window)
  if type(window) ~= "table" or tonumber(window.usedPercent) == nil then
    return nil
  end
  return math.floor(math.max(0, math.min(100, window.usedPercent)) + 0.5)
end

local function accent(percent)
  if percent == nil then
    return "on_surface_variant"
  elseif percent >= 90 then
    return "error"
  elseif percent >= 75 then
    return "secondary"
  end
  return "primary"
end

local function relativeReset(resetAt)
  if tonumber(resetAt) == nil then
    return tr("labels.reset_unknown")
  end

  local remaining = math.max(0, math.floor(resetAt - os.time()))
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

local function planLabel(value)
  if type(value) ~= "string" or value == "" then
    return tr("labels.unknown_plan")
  end

  local normalized = value:lower():gsub("[%s%-]+", "_")
  local commercialName = COMMERCIAL_PLAN_NAMES[normalized]
  if commercialName ~= nil then
    return commercialName
  end

  return value
end

local function windowCard(title, window)
  local percent = roundedPercent(window)
  if percent == nil then
    return ui.column({
      fill = "surface_variant",
      radius = 12,
      paddingH = 14,
      paddingV = 12,
      gap = 8,
    }, {
      ui.label({ text = title, fontWeight = "bold", color = "on_surface" }),
      ui.label({ text = tr("labels.unavailable"), color = "on_surface_variant" }),
    })
  end

  local color = accent(percent)
  return ui.column({
    fill = "surface_variant",
    radius = 12,
    paddingH = 14,
    paddingV = 12,
    gap = 8,
  }, {
    ui.row({ align = "center", justify = "space_between", gap = 8 }, {
      ui.label({ text = title, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),
      ui.label({
        text = tr("labels.percent_used", { percent = percent }),
        fontWeight = "bold",
        color = color,
      }),
    }),
    ui.progress({ progress = percent / 100, fill = color, height = 7, radius = 4 }),
    ui.row({ align = "center", justify = "space_between", gap = 8 }, {
      ui.label({
        text = tr("labels.resets_in", { time = relativeReset(window.resetAt) }),
        color = "on_surface_variant",
        fontSize = 12,
        flexGrow = 1,
      }),
      ui.label({
        text = noctalia.formatTime("%a %H:%M", window.resetAt),
        color = "on_surface_variant",
        fontSize = 12,
      }),
    }),
  })
end

local function statusContent()
  if snapshot.status == "error" and snapshot.error ~= nil then
    return ui.row({
      fill = "error/0.15",
      radius = 10,
      paddingH = 10,
      paddingV = 8,
      gap = 8,
      align = "center",
    }, {
      ui.glyph({ name = "alert-triangle", size = 16, color = "error" }),
      ui.label({ text = snapshot.error, color = "error", fontSize = 12, flexGrow = 1, wrap = true }),
    })
  elseif snapshot.status == "loading" then
    return ui.label({ text = tr("status.loading"), color = "on_surface_variant", fontSize = 12 })
  end

  local updatedAt = tonumber(snapshot.updatedAt)
  if updatedAt ~= nil then
    return ui.label({
      text = tr("labels.updated_at", { time = noctalia.formatTime("%Y-%m-%d %H:%M", updatedAt) }),
      color = "on_surface_variant",
      fontSize = 12,
    })
  end
  return ui.label({ text = tr("labels.not_updated"), color = "on_surface_variant", fontSize = 12 })
end

local function render()
  if not opened then
    return
  end

  local children = {
    ui.row({ align = "center", justify = "space_between", gap = 8 }, {
      ui.column({ gap = 2, flexGrow = 1 }, {
        ui.label({ text = tr("title"), fontSize = 18, fontWeight = "bold", color = "on_surface" }),
        ui.label({
          text = tr("labels.plan", { plan = planLabel(snapshot.planType) }),
          color = "on_surface_variant",
          fontSize = 12,
        }),
      }),
      ui.button({
        glyph = "refresh",
        variant = "ghost",
        enabled = snapshot.status ~= "loading",
        onClick = "refreshUsage",
      }),
      ui.button({ glyph = "close", onClick = "closePanel" }),
    }),
  }
  if showFiveHour() then
    table.insert(children, windowCard(tr("labels.five_hour"), snapshot.fiveHour))
  end
  table.insert(children, windowCard(tr("labels.weekly"), snapshot.weekly))
  table.insert(children, statusContent())
  panel.render(ui.column({ flexGrow = 1, gap = 16 }, children))
end

function onOpen(_context)
  opened = true
  panel.setWantsSecondTicks(true)
  render()
end

function onClose()
  opened = false
  panel.setWantsSecondTicks(false)
end

function update()
  render()
end

function onConfigChanged()
  render()
end

function refreshUsage()
  local current = tonumber(noctalia.state.get(REFRESH_REQUEST_KEY)) or 0
  noctalia.state.set(REFRESH_REQUEST_KEY, current + 1)
end

function closePanel()
  panel.close()
end

noctalia.state.watch(STATE_KEY, function(value)
  snapshot = type(value) == "table" and value or { status = "loading" }
  render()
end)
