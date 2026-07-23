--!nonstrict

-- The service is the only entry that handles credentials or network access.
-- UI entries receive a small, token-free snapshot through noctalia.state.

local STATE_KEY = "usage_snapshot"
local REFRESH_REQUEST_KEY = "refresh_request"
local USAGE_URL = "https://chatgpt.com/backend-api/wham/usage"
local POLL_SECONDS = 5 * 60

local inFlight = false
local nextPollAt = 0
local lastGood = nil
local currentStatus = "loading"
local currentError = nil
local currentAttemptedAt = nil

local function tr(key, substitutions)
  return noctalia.tr(key, substitutions)
end

local function configEnabled(key)
  local value = noctalia.getConfig(key)
  return value == true or value == "true"
end

local function shouldTrackFiveHour()
  return configEnabled("show_five_hour_bar") or configEnabled("show_five_hour_panel")
end

local trackingFiveHour = shouldTrackFiveHour()

local function publish(status, errorMessage, attemptedAt)
  currentStatus = status
  currentError = errorMessage
  currentAttemptedAt = attemptedAt
  local snapshot = {
    status = status,
    error = errorMessage,
    attemptedAt = attemptedAt,
    stale = status == "error" and lastGood ~= nil,
  }

  if lastGood ~= nil then
    snapshot.planType = lastGood.planType
    snapshot.fiveHour = lastGood.fiveHour
    snapshot.weekly = lastGood.weekly
    snapshot.updatedAt = lastGood.updatedAt
  end

  noctalia.state.set(STATE_KEY, snapshot)
end

local function fail(message, attemptedAt)
  inFlight = false
  publish("error", message, attemptedAt)
end

local function authPath()
  local codexHome = noctalia.getenv("CODEX_HOME")
  if type(codexHome) == "string" and noctalia.string.trim(codexHome) ~= "" then
    return noctalia.expandPath(codexHome):gsub("/+$", "") .. "/auth.json"
  end
  return noctalia.expandPath("~/.codex/auth.json")
end

local function loadCredentials()
  local contents = noctalia.readFile(authPath())
  if type(contents) ~= "string" or contents == "" then
    return nil, nil, tr("errors.auth_missing")
  end

  local decoded = noctalia.json.decode(contents)
  if type(decoded) ~= "table" then
    return nil, nil, tr("errors.auth_invalid")
  end

  local tokens = decoded.tokens
  if type(tokens) ~= "table" then
    return nil, nil, tr("errors.oauth_required")
  end

  local accessToken = tokens.access_token or tokens.accessToken
  local accountId = tokens.account_id or tokens.accountId
  if type(accessToken) ~= "string" or accessToken == "" then
    return nil, nil, tr("errors.oauth_required")
  end
  if type(accountId) ~= "string" or accountId == "" then
    accountId = nil
  end

  return accessToken, accountId, nil
end

local function decodeWindow(value)
  if type(value) ~= "table" then
    return nil
  end

  local usedPercent = tonumber(value.used_percent)
  local resetAt = tonumber(value.reset_at)
  local windowSeconds = tonumber(value.limit_window_seconds)
  if usedPercent == nil or resetAt == nil or windowSeconds == nil or windowSeconds <= 0 then
    return nil
  end

  return {
    usedPercent = math.max(0, math.min(100, usedPercent)),
    resetAt = math.floor(resetAt),
    windowSeconds = math.floor(windowSeconds),
  }
end

local function role(window)
  if window == nil then
    return "missing"
  elseif window.windowSeconds == 18000 then
    return "five_hour"
  elseif window.windowSeconds == 604800 then
    return "weekly"
  end
  return "unknown"
end

-- OpenAI does not guarantee that primary_window is the 5-hour lane. Match the
-- CodexBar normalization rule by classifying known window durations first and
-- using response position only for unknown durations.
local function normalizeWindows(rateLimit, includeFiveHour)
  local primary = decodeWindow(rateLimit.primary_window)
  local secondary = decodeWindow(rateLimit.secondary_window)
  local primaryRole = role(primary)
  local secondaryRole = role(secondary)
  local fiveHour = nil
  local weekly = nil

  if includeFiveHour and primaryRole == "five_hour" then
    fiveHour = primary
  elseif primaryRole == "weekly" then
    weekly = primary
  end
  if includeFiveHour and secondaryRole == "five_hour" then
    fiveHour = secondary
  elseif secondaryRole == "weekly" then
    weekly = secondary
  end

  if includeFiveHour and fiveHour == nil then
    if primary ~= nil and primaryRole ~= "weekly" then
      fiveHour = primary
    elseif secondary ~= nil and secondaryRole ~= "weekly" then
      fiveHour = secondary
    end
  end
  if weekly == nil then
    if secondary ~= nil and secondaryRole ~= "five_hour" and secondary ~= fiveHour then
      weekly = secondary
    elseif primary ~= nil and primaryRole ~= "five_hour" and primary ~= fiveHour then
      weekly = primary
    end
  end

  return fiveHour, weekly
end

local function parseUsage(body, includeFiveHour)
  local decoded = noctalia.json.decode(body)
  if type(decoded) ~= "table" then
    return nil, tr("errors.response_invalid")
  end

  local rateLimit = decoded.rate_limit
  if type(rateLimit) ~= "table" then
    return nil, tr("errors.no_windows")
  end

  local fiveHour, weekly = normalizeWindows(rateLimit, includeFiveHour)
  if fiveHour == nil and weekly == nil then
    return nil, tr("errors.no_windows")
  end

  local planType = decoded.plan_type
  if type(planType) ~= "string" or planType == "" then
    planType = nil
  end

  return {
    planType = planType,
    fiveHour = fiveHour,
    weekly = weekly,
    updatedAt = os.time(),
  }, nil
end

local function refreshUsage()
  if inFlight then
    return
  end

  local attemptedAt = os.time()
  local accessToken, accountId, credentialError = loadCredentials()
  nextPollAt = attemptedAt + POLL_SECONDS
  if credentialError ~= nil then
    fail(credentialError, attemptedAt)
    return
  end

  inFlight = true
  publish("loading", nil, attemptedAt)

  local headers = {
    "Authorization: Bearer " .. accessToken,
    "Accept: application/json",
    "User-Agent: Noctalia-token-top/0.2.0",
  }
  if accountId ~= nil then
    table.insert(headers, "ChatGPT-Account-Id: " .. accountId)
  end

  local started = noctalia.http({
    url = USAGE_URL,
    method = "GET",
    headers = headers,
  }, function(response)
    if not response.ok then
      fail(tr("errors.network"), attemptedAt)
      return
    end
    if response.status == 401 or response.status == 403 then
      fail(tr("errors.unauthorized"), attemptedAt)
      return
    end
    if response.status < 200 or response.status >= 300 then
      fail(tr("errors.http_status", { status = response.status }), attemptedAt)
      return
    end

    local parsed, parseError = parseUsage(response.body, shouldTrackFiveHour())
    if parsed == nil then
      fail(parseError, attemptedAt)
      return
    end

    lastGood = parsed
    inFlight = false
    publish("ready", nil, attemptedAt)
  end)

  if not started then
    fail(tr("errors.request_not_started"), attemptedAt)
  end
end

noctalia.setUpdateInterval(60000)

noctalia.state.watch(REFRESH_REQUEST_KEY, function(_value)
  refreshUsage()
end)

-- Fetch once as soon as the service starts; later updates enforce the poll.
refreshUsage()

function update()
  if os.time() >= nextPollAt then
    refreshUsage()
  end
end


function onConfigChanged()
  local includeFiveHour = shouldTrackFiveHour()
  if includeFiveHour == trackingFiveHour then
    return
  end
  trackingFiveHour = includeFiveHour

  if not includeFiveHour and lastGood ~= nil and lastGood.fiveHour ~= nil then
    lastGood.fiveHour = nil
    publish(currentStatus, currentError, currentAttemptedAt)
  elseif includeFiveHour then
    nextPollAt = 0
    refreshUsage()
  end
end
