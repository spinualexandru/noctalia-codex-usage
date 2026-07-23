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

local function compactNumber(value)
  local amount = math.max(0, tonumber(value) or 0)
  local divisor = 1
  local suffix = ""
  if amount >= 1000000000 then
    divisor = 1000000000
    suffix = "B"
  elseif amount >= 1000000 then
    divisor = 1000000
    suffix = "M"
  elseif amount >= 1000 then
    divisor = 1000
    suffix = "K"
  end

  if divisor == 1 then
    return tostring(math.floor(amount + 0.5))
  end
  local formatted = string.format("%.1f", amount / divisor):gsub("%.0$", "")
  return formatted .. suffix
end

local function tokenMetric(label, value, accentValue)
  return ui.column({
    fill = "surface_variant",
    radius = 12,
    paddingH = 14,
    paddingV = 12,
    gap = 3,
    flexGrow = 1,
  }, {
    ui.label({
      text = tr("stats.tokens", { value = compactNumber(value) }),
      fontSize = 21,
      fontWeight = "bold",
      color = accentValue and "primary" or "on_surface",
    }),
    ui.label({
      text = label,
      color = "on_surface_variant",
      fontSize = 11,
      wrap = true,
    }),
  })
end

local function dataCell(label, value, color)
  return ui.column({ gap = 2, flexGrow = 1 }, {
    ui.label({
      text = value,
      fontSize = 15,
      fontWeight = "bold",
      color = color or "on_surface",
    }),
    ui.label({
      text = label,
      color = "on_surface_variant",
      fontSize = 10,
      wrap = true,
    }),
  })
end

local function activityChart(stats)
  local activity = type(stats.dailyActivity) == "table" and stats.dailyActivity or {}
  local maximum = 0
  for _, day in ipairs(activity) do
    maximum = math.max(maximum, tonumber(day.tokens) or 0)
  end

  local bars = {}
  local now = os.time()
  for index = 1, 7 do
    local day = activity[index] or {}
    local tokens = math.max(0, tonumber(day.tokens) or 0)
    local startedAt = tonumber(day.startedAt)
    local height = tokens > 0 and math.max(4, math.floor(tokens / math.max(1, maximum) * 48 + 0.5)) or 3
    local isCurrent = startedAt ~= nil and now >= startedAt
      and (index == 7 or activity[index + 1] == nil or now < (tonumber(activity[index + 1].startedAt) or 0))
    local fill = tokens == 0 and "on_surface_variant/0.2" or (isCurrent and "primary" or "primary/0.45")

    table.insert(bars, ui.column({ flexGrow = 1, gap = 5, align = "center" }, {
      ui.column({ height = 50, justify = "end", align = "center" }, {
        ui.box({ width = 22, height = height, radius = 4, fill = fill }),
      }),
      ui.label({
        text = startedAt ~= nil and noctalia.formatTime("%a", startedAt):sub(1, 1) or "—",
        fontSize = 10,
        fontWeight = isCurrent and "bold" or "normal",
        color = isCurrent and "primary" or "on_surface_variant",
      }),
    }))
  end

  return ui.column({
    fill = "surface_variant",
    radius = 12,
    paddingH = 14,
    paddingV = 12,
    gap = 8,
  }, {
    ui.row({ align = "center", justify = "space_between", gap = 8 }, {
      ui.label({ text = tr("stats.daily_activity"), fontWeight = "bold", color = "on_surface" }),
      ui.label({ text = tr("stats.current_window"), fontSize = 10, color = "on_surface_variant" }),
    }),
    ui.row({ gap = 6, align = "end" }, bars),
  })
end

local function tokenBreakdown(stats)
  local cachedPercent = math.max(0, math.floor(tonumber(stats.cachedInputPercent) or 0))
  local reasoningPercent = math.max(0, math.floor(tonumber(stats.reasoningPercent) or 0))
  return ui.column({
    fill = "surface_variant",
    radius = 12,
    paddingH = 14,
    paddingV = 12,
    gap = 10,
  }, {
    ui.label({ text = tr("stats.breakdown"), fontWeight = "bold", color = "on_surface" }),
    ui.row({ gap = 12, align = "start" }, {
      dataCell(tr("stats.input"), compactNumber(stats.inputTokens)),
      dataCell(tr("stats.output"), compactNumber(stats.outputTokens)),
      dataCell(tr("stats.cached"), compactNumber(stats.cachedInputTokens), "primary"),
    }),
    ui.separator(),
    ui.row({ align = "center", justify = "space_between", gap = 8 }, {
      ui.label({
        text = tr("stats.cached_share", { percent = cachedPercent }),
        fontSize = 11,
        color = "on_surface_variant",
      }),
      ui.label({
        text = tr("stats.reasoning_share", {
          value = compactNumber(stats.reasoningTokens),
          percent = reasoningPercent,
        }),
        fontSize = 11,
        color = "on_surface_variant",
      }),
    }),
  })
end

local function insightRow(label, value)
  return ui.row({ align = "center", justify = "space_between", gap = 10 }, {
    ui.label({ text = label, fontSize = 11, color = "on_surface_variant", flexGrow = 1 }),
    ui.label({ text = value, fontSize = 12, fontWeight = "bold", color = "on_surface" }),
  })
end

local function supportingStats(stats)
  local largestPercent = math.max(0, math.floor(tonumber(stats.largestThreadPercent) or 0))
  return ui.column({
    fill = "surface_variant",
    radius = 12,
    paddingH = 14,
    paddingV = 11,
    gap = 8,
  }, {
    insightRow(
      tr("stats.requests_turns"),
      tr("stats.requests_turns_value", {
        requests = math.max(0, math.floor(tonumber(stats.requestCount) or 0)),
        turns = math.max(0, math.floor(tonumber(stats.turnCount) or 0)),
      })
    ),
    ui.separator(),
    insightRow(
      tr("stats.average_median"),
      tr("stats.average_median_value", {
        average = compactNumber(stats.averagePerThread),
        median = compactNumber(stats.medianPerThread),
      })
    ),
    ui.separator(),
    insightRow(
      tr("stats.largest_thread"),
      tr("stats.largest_thread_value", {
        value = compactNumber(stats.largestThread),
        percent = largestPercent,
      })
    ),
  })
end

local function projectionFooter(stats)
  local change = tonumber(stats.previousChangePercent)
  local comparison = tr("stats.comparison_unavailable")
  if change ~= nil then
    local magnitude = math.abs(math.floor(change))
    if change > 0 then
      comparison = tr("stats.higher_than_previous", { percent = magnitude })
    elseif change < 0 then
      comparison = tr("stats.lower_than_previous", { percent = magnitude })
    else
      comparison = tr("stats.same_as_previous")
    end
  end

  return ui.column({ gap = 4, paddingH = 2 }, {
    ui.row({ align = "center", justify = "space_between", gap = 8 }, {
      ui.label({ text = tr("stats.projected_by_reset"), fontSize = 11, color = "on_surface_variant" }),
      ui.label({
        text = tr("stats.tokens", { value = compactNumber(stats.projectedByReset) }),
        fontSize = 11,
        fontWeight = "bold",
        color = "on_surface",
      }),
    }),
    ui.row({ align = "center", justify = "space_between", gap = 8 }, {
      ui.label({
        text = tr("stats.daily_pace", { value = compactNumber(stats.averagePerDay) }),
        fontSize = 10,
        color = "on_surface_variant",
      }),
      ui.label({ text = comparison, fontSize = 10, color = "on_surface_variant" }),
    }),
  })
end

local function tokenStatsContent()
  local stats = snapshot.tokenStats
  if type(stats) ~= "table" or stats.status == "loading" then
    local loadingText = tr("stats.loading")
    if type(stats) == "table" then
      if stats.calculating then
        loadingText = tr("stats.calculating")
      else
        local processed = tonumber(stats.processedFiles)
        local total = tonumber(stats.totalFiles)
        if processed ~= nil and total ~= nil and total > 0 then
          loadingText = tr("stats.loading_progress", {
            processed = math.max(0, math.floor(processed)),
            total = math.max(0, math.floor(total)),
          })
        end
      end
    end
    return ui.row({
      fill = "surface_variant",
      radius = 12,
      paddingH = 14,
      paddingV = 12,
      gap = 8,
      align = "center",
    }, {
      ui.label({ text = loadingText, color = "on_surface_variant", fontSize = 12 }),
    })
  elseif stats.status ~= "ready" then
    return ui.label({ text = tr("stats.unavailable"), color = "on_surface_variant", fontSize = 12 })
  end

  local threadCount = math.max(0, math.floor(tonumber(stats.threadCount) or 0))
  local threadLabel = threadCount == 1 and tr("stats.one_thread") or tr("stats.threads", { count = threadCount })
  local resetStartedAt = tonumber(stats.resetStartedAt)
  local resetLabel = resetStartedAt ~= nil and noctalia.formatTime("%a %d %b", resetStartedAt) or "—"

  return ui.column({ gap = 8 }, {
    ui.row({ gap = 8, align = "stretch" }, {
      tokenMetric(tr("stats.since_reset"), stats.sinceReset, true),
      tokenMetric(tr("stats.today"), stats.today, false),
    }),
    activityChart(stats),
    tokenBreakdown(stats),
    supportingStats(stats),
    projectionFooter(stats),
    ui.label({
      text = tr("stats.summary", { threads = threadLabel, date = resetLabel }),
      color = "on_surface_variant",
      fontSize = 11,
    }),
  })
end

local function statsSection()
  return ui.column({ gap = 9 }, {
    ui.label({ text = tr("stats.title"), fontSize = 16, fontWeight = "bold", color = "on_surface" }),
    tokenStatsContent(),
  })
end

local function render()
  if not opened then
    return
  end

  local header = ui.row({ align = "center", justify = "space_between", gap = 8 }, {
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
    })
  local children = {}
  if showFiveHour() then
    table.insert(children, windowCard(tr("labels.five_hour"), snapshot.fiveHour))
  end
  table.insert(children, windowCard(tr("labels.weekly"), snapshot.weekly))
  table.insert(children, statusContent())
  table.insert(children, ui.separator())
  table.insert(children, statsSection())
  panel.render(ui.column({ flexGrow = 1, gap = 14 }, {
    header,
    ui.scroll({ flexGrow = 1, gap = 14, align = "stretch" }, children),
  }))
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
