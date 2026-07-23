--!nonstrict

-- The service is the only entry that handles credentials or network access.
-- UI entries receive a small, token-free snapshot through noctalia.state.

local STATE_KEY = "usage_snapshot"
local REFRESH_REQUEST_KEY = "refresh_request"
local USAGE_URL = "https://chatgpt.com/backend-api/wham/usage"
local POLL_SECONDS = 5 * 60
local STATS_REFRESH_SECONDS = 5 * 60
local IDLE_UPDATE_MS = 60000
local SCAN_UPDATE_MS = 32
local STATS_STREAM_DONE = "__TOKEN_TOP_STATS_STREAM_DONE__"

local inFlight = false
local nextPollAt = 0
local nextStatsScanAt = 0
local lastGood = nil
local currentStatus = "loading"
local currentError = nil
local currentAttemptedAt = nil
local tokenStats = { status = "loading" }
local statsCache = {}
local statsCacheReady = false
local statsQueue = {}
local statsSeenPaths = {}
local statsScanning = false
local statsAggregating = false
local statsAggregationQueue = {}
local statsAggregationIndex = 1
local statsAggregationContext = nil

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

local function codexHome()
  local configured = noctalia.getenv("CODEX_HOME")
  if type(configured) == "string" and noctalia.string.trim(configured) ~= "" then
    return noctalia.expandPath(configured):gsub("/+$", "")
  end
  return noctalia.expandPath("~/.codex")
end

local function publish(status, errorMessage, attemptedAt)
  currentStatus = status
  currentError = errorMessage
  currentAttemptedAt = attemptedAt
  local snapshot = {
    status = status,
    error = errorMessage,
    attemptedAt = attemptedAt,
    stale = status == "error" and lastGood ~= nil,
    tokenStats = tokenStats,
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
  return codexHome() .. "/auth.json"
end

-- Convert the UTC timestamps written to rollout JSONL without depending on the
-- machine's local timezone.
local function daysFromCivil(year, month, day)
  year -= month <= 2 and 1 or 0
  local era = (year >= 0 and year or year - 399) // 400
  local yearOfEra = year - era * 400
  local shiftedMonth = month + (month > 2 and -3 or 9)
  local dayOfYear = (153 * shiftedMonth + 2) // 5 + day - 1
  local dayOfEra = yearOfEra * 365 + yearOfEra // 4 - yearOfEra // 100 + dayOfYear
  return era * 146097 + dayOfEra - 719468
end

local function parseIsoTimestamp(value)
  if type(value) ~= "string" then
    return nil
  end
  local year, month, day, hour, minute, second =
    value:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)")
  year = tonumber(year)
  month = tonumber(month)
  day = tonumber(day)
  hour = tonumber(hour)
  minute = tonumber(minute)
  second = tonumber(second)
  if year == nil or month == nil or day == nil or hour == nil or minute == nil or second == nil then
    return nil
  end
  return daysFromCivil(year, month, day) * 86400 + hour * 3600 + minute * 60 + second
end

local function collectSessionFiles(directory, files)
  local entries, listError = noctalia.listDir(directory)
  if entries == nil then
    return false, listError
  end

  table.sort(entries)
  for _, name in ipairs(entries) do
    if name:sub(1, 1) ~= "." then
      local path = directory .. "/" .. name
      local info = noctalia.fileInfo(path)
      if info ~= nil and info.isDir then
        local ok, childError = collectSessionFiles(path, files)
        if not ok then
          return false, childError
        end
      elseif info ~= nil and name:sub(-6) == ".jsonl" then
        table.insert(files, { path = path, size = info.size, mtime = info.mtime })
      end
    end
  end
  return true, nil
end

local function parseStatsLine(line, parsed)
  -- Most rollout records contain prompts, tool output, or model messages. A
  -- cheap string test avoids JSON-decoding those large records inside
  -- Noctalia's tightly budgeted script callbacks.
  local usageMarker = line:find('"token_count"', 1, true)
  local turnMarker = line:find('"type":"turn_context"', 1, true)
  local mayContainUsage = usageMarker ~= nil and usageMarker < 200
  local mayContainTurn = turnMarker ~= nil and turnMarker < 200
  if not mayContainUsage and not mayContainTurn then
    return false
  end

  -- A turn_context record can contain a very large compacted summary. Extract
  -- its two scalar fields without JSON-decoding the entire line.
  if mayContainTurn and not mayContainUsage then
    local timestamp = line:match('"timestamp"%s*:%s*"([^"]+)"')
    local occurredAt = parseIsoTimestamp(timestamp)
    if occurredAt ~= nil then
      table.insert(parsed.turns, {
        occurredAt = occurredAt,
        id = line:match('"turn_id"%s*:%s*"([^"]+)"'),
      })
    end
    return true
  end

  local record = noctalia.json.decode(line)
  if type(record) ~= "table" or type(record.payload) ~= "table" then
    return true
  end

  local occurredAt = parseIsoTimestamp(record.timestamp)
  if occurredAt == nil then
    return true
  end

  if record.type ~= "event_msg" or record.payload.type ~= "token_count" then
    return true
  end

  local info = record.payload.info
  local usage = type(info) == "table" and info.total_token_usage or nil
  local total = type(usage) == "table" and tonumber(usage.total_tokens) or nil
  if total ~= nil then
    table.insert(parsed.samples, {
      occurredAt = occurredAt,
      total = math.max(0, total),
      input = math.max(0, tonumber(usage.input_tokens) or 0),
      output = math.max(0, tonumber(usage.output_tokens) or 0),
      cached = math.max(0, tonumber(usage.cached_input_tokens) or 0),
      reasoning = math.max(0, tonumber(usage.reasoning_output_tokens) or 0),
    })
  end
  return true
end

local function positiveDelta(current, previous)
  local delta = current - previous
  if delta < 0 then
    -- Be defensive if a future Codex version resets cumulative usage.
    return math.max(0, current)
  end
  return math.max(0, delta)
end

local function summarizeRange(cached, startedAt, endedAt)
  local previous = {
    total = 0,
    input = 0,
    output = 0,
    cached = 0,
    reasoning = 0,
  }
  local summary = {
    total = 0,
    input = 0,
    output = 0,
    cached = 0,
    reasoning = 0,
    requests = 0,
    turns = 0,
  }

  local samples = type(cached.samples) == "table" and cached.samples or {}
  for _, sample in ipairs(samples) do
    local deltas = {
      total = positiveDelta(sample.total or 0, previous.total),
      input = positiveDelta(sample.input or 0, previous.input),
      output = positiveDelta(sample.output or 0, previous.output),
      cached = positiveDelta(sample.cached or 0, previous.cached),
      reasoning = positiveDelta(sample.reasoning or 0, previous.reasoning),
    }
    if sample.occurredAt >= startedAt and (endedAt == nil or sample.occurredAt < endedAt) then
      summary.total += deltas.total
      summary.input += deltas.input
      summary.output += deltas.output
      summary.cached += deltas.cached
      summary.reasoning += deltas.reasoning
      if deltas.total > 0 then
        summary.requests += 1
      end
    end
    previous.total = sample.total or 0
    previous.input = sample.input or 0
    previous.output = sample.output or 0
    previous.cached = sample.cached or 0
    previous.reasoning = sample.reasoning or 0
  end

  local turns = type(cached.turns) == "table" and cached.turns or {}
  for _, turn in ipairs(turns) do
    if turn.occurredAt >= startedAt and (endedAt == nil or turn.occurredAt < endedAt) then
      summary.turns += 1
    end
  end

  return summary
end

local function selectThreadSummary(selected, threadId, summary)
  if summary.total <= 0 and summary.turns <= 0 then
    return
  end

  local previous = selected[threadId]
  if previous == nil
    or summary.total > previous.summary.total
    or (summary.total == previous.summary.total and summary.turns > previous.summary.turns)
  then
    selected[threadId] = { summary = summary }
  end
end

local function aggregateSelected(selected)
  local aggregate = {
    total = 0,
    input = 0,
    output = 0,
    cached = 0,
    reasoning = 0,
    requests = 0,
    turns = 0,
  }
  for _, item in pairs(selected) do
    for key, _ in pairs(aggregate) do
      aggregate[key] += item.summary[key] or 0
    end
  end
  return aggregate
end

local function localMidnight(timestamp)
  local parts = os.date("*t", timestamp)
  parts.hour = 0
  parts.min = 0
  parts.sec = 0
  parts.isdst = nil
  return os.time(parts)
end

local function buildTokenStats(context)
  local current = aggregateSelected(context.current)
  local today = aggregateSelected(context.today)
  local previous = aggregateSelected(context.previous)
  local perThread = {}
  local largestThread = 0
  for _, item in pairs(context.current) do
    if item.summary.total > 0 then
      table.insert(perThread, item.summary.total)
      largestThread = math.max(largestThread, item.summary.total)
    end
  end
  table.sort(perThread)

  local threadCount = #perThread
  local medianPerThread = 0
  if threadCount > 0 then
    local middle = (threadCount + 1) // 2
    if threadCount % 2 == 0 then
      medianPerThread = math.floor((perThread[middle] + perThread[middle + 1]) / 2 + 0.5)
    else
      medianPerThread = perThread[middle]
    end
  end

  local dailyActivity = {}
  local bucketSeconds = context.windowSeconds / 7
  for index = 1, 7 do
    local bucketStartedAt = context.resetStartedAt + (index - 1) * bucketSeconds
    local bucket = aggregateSelected(context.daily[index])
    table.insert(dailyActivity, {
      startedAt = math.floor(bucketStartedAt),
      tokens = math.floor(bucket.total + 0.5),
    })
  end

  local elapsedSeconds = math.max(1, context.now - context.resetStartedAt)
  local projectedByReset = math.floor(current.total * context.windowSeconds / elapsedSeconds + 0.5)
  local previousChangePercent = nil
  if previous.total > 0 then
    -- Compare pace fairly: the current window is still partial, so compare its
    -- reset projection with the complete previous window.
    previousChangePercent = math.floor(((projectedByReset - previous.total) / previous.total) * 100 + 0.5)
  end

  return {
    status = "ready",
    sinceReset = math.floor(current.total + 0.5),
    today = math.floor(today.total + 0.5),
    averagePerDay = math.floor(current.total * 86400 / elapsedSeconds + 0.5),
    averagePerThread = threadCount > 0 and math.floor(current.total / threadCount + 0.5) or 0,
    medianPerThread = medianPerThread,
    largestThread = math.floor(largestThread + 0.5),
    largestThreadPercent = current.total > 0 and math.floor(largestThread / current.total * 100 + 0.5) or 0,
    threadCount = threadCount,
    requestCount = current.requests,
    turnCount = current.turns,
    inputTokens = math.floor(current.input + 0.5),
    outputTokens = math.floor(current.output + 0.5),
    cachedInputTokens = math.floor(current.cached + 0.5),
    cachedInputPercent = current.input > 0 and math.floor(current.cached / current.input * 100 + 0.5) or 0,
    reasoningTokens = math.floor(current.reasoning + 0.5),
    reasoningPercent = current.output > 0 and math.floor(current.reasoning / current.output * 100 + 0.5) or 0,
    dailyActivity = dailyActivity,
    projectedByReset = projectedByReset,
    previousWindow = math.floor(previous.total + 0.5),
    previousChangePercent = previousChangePercent,
    resetStartedAt = context.resetStartedAt,
    updatedAt = os.time(),
  }
end

local function finishStatsAggregation()
  tokenStats = buildTokenStats(statsAggregationContext)
  statsAggregating = false
  statsAggregationQueue = {}
  statsAggregationIndex = 1
  statsAggregationContext = nil
  noctalia.setUpdateInterval(IDLE_UPDATE_MS)
  publish(currentStatus, currentError, currentAttemptedAt)
end

local function processNextStatsAggregation()
  local cached = statsAggregationQueue[statsAggregationIndex]
  if cached == nil then
    finishStatsAggregation()
    return
  end

  local context = statsAggregationContext
  local current = summarizeRange(cached, context.resetStartedAt, context.resetAt)
  local today = summarizeRange(cached, context.todayStartedAt, context.now + 1)
  local previous = summarizeRange(
    cached,
    context.resetStartedAt - context.windowSeconds,
    context.resetStartedAt
  )
  selectThreadSummary(context.current, cached.threadId, current)
  selectThreadSummary(context.today, cached.threadId, today)
  selectThreadSummary(context.previous, cached.threadId, previous)

  local bucketSeconds = context.windowSeconds / 7
  for index = 1, 7 do
    local bucketStartedAt = context.resetStartedAt + (index - 1) * bucketSeconds
    local bucketEndedAt = math.min(context.resetAt, bucketStartedAt + bucketSeconds)
    local bucket = summarizeRange(cached, bucketStartedAt, bucketEndedAt)
    selectThreadSummary(context.daily[index], cached.threadId, bucket)
  end

  statsAggregationIndex += 1
end

local function beginStatsAggregation()
  if not statsCacheReady or statsScanning or statsAggregating then
    return false
  end

  local weekly = lastGood ~= nil and lastGood.weekly or nil
  local resetAt = type(weekly) == "table" and tonumber(weekly.resetAt) or nil
  local windowSeconds = type(weekly) == "table" and tonumber(weekly.windowSeconds) or nil
  if resetAt == nil or windowSeconds == nil or windowSeconds <= 0 then
    tokenStats = { status = "unavailable" }
    return false
  end

  local now = math.min(os.time(), resetAt)
  local daily = {}
  for index = 1, 7 do
    daily[index] = {}
  end

  statsAggregationQueue = {}
  for _, cached in pairs(statsCache) do
    table.insert(statsAggregationQueue, cached)
  end
  statsAggregationIndex = 1
  statsAggregationContext = {
    resetAt = resetAt,
    windowSeconds = windowSeconds,
    resetStartedAt = resetAt - windowSeconds,
    now = now,
    todayStartedAt = localMidnight(now),
    current = {},
    today = {},
    previous = {},
    daily = daily,
  }
  statsAggregating = true
  if tokenStats.status ~= "ready" then
    tokenStats = { status = "loading", calculating = true }
  end
  noctalia.setUpdateInterval(SCAN_UPDATE_MS)
  return true
end

local function finishStatsScan()
  for path, _ in pairs(statsCache) do
    if not statsSeenPaths[path] then
      statsCache[path] = nil
    end
  end

  statsScanning = false
  statsCacheReady = true
  statsQueue = {}
  nextStatsScanAt = os.time() + STATS_REFRESH_SECONDS
  if not beginStatsAggregation() then
    noctalia.setUpdateInterval(IDLE_UPDATE_MS)
  end
  publish(currentStatus, currentError, currentAttemptedAt)
end

local function shellQuote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function onStatsStreamLine(line)
  if line == STATS_STREAM_DONE then
    finishStatsScan()
    return
  end

  local path, recordLine = line:match("^(.-):(%{.*)$")
  if path == nil or recordLine == nil then
    return
  end

  local cached = statsCache[path]
  if type(cached) == "table" then
    parseStatsLine(recordLine, cached)
  end
end

local function statsStreamCommand(files)
  local paths = {}
  for _, file in ipairs(files) do
    table.insert(paths, shellQuote(file.path))
  end
  local pathArguments = table.concat(paths, " ")
  local tokenPattern =
    [[^\{"timestamp":"[^"]+","type":"event_msg","payload":\{"type":"token_count"]]
  local turnPattern =
    [[^\{"timestamp":"[^"]+","type":"turn_context","payload":\{"turn_id":"[^"]+"]]

  return "{ rg --no-messages --with-filename --no-line-number --color never "
    .. shellQuote(tokenPattern)
    .. " "
    .. pathArguments
    .. "; rg --no-messages --with-filename --no-line-number --color never -o "
    .. shellQuote(turnPattern)
    .. " "
    .. pathArguments
    .. "; printf '%s\\n' "
    .. shellQuote(STATS_STREAM_DONE)
    .. "; }"
end

local function beginStatsScan()
  if statsScanning or statsAggregating then
    return
  end

  local files = {}
  local ok = collectSessionFiles(codexHome() .. "/sessions", files)
  if not ok then
    tokenStats = { status = "unavailable" }
    nextStatsScanAt = os.time() + STATS_REFRESH_SECONDS
    publish(currentStatus, currentError, currentAttemptedAt)
    return
  end

  statsQueue = {}
  statsSeenPaths = {}
  local weekly = lastGood ~= nil and lastGood.weekly or nil
  local resetAt = type(weekly) == "table" and tonumber(weekly.resetAt) or nil
  local windowSeconds = type(weekly) == "table" and tonumber(weekly.windowSeconds) or nil
  local scanStartedAt = resetAt ~= nil and windowSeconds ~= nil and (resetAt - windowSeconds * 2 - 86400) or 0
  for _, file in ipairs(files) do
    if file.mtime >= scanStartedAt then
      statsSeenPaths[file.path] = true
      local cached = statsCache[file.path]
      if cached == nil or cached.size ~= file.size or cached.mtime ~= file.mtime then
        statsCache[file.path] = {
          threadId = file.path:match("([0-9a-f%-]+)%.jsonl$") or file.path,
          samples = {},
          turns = {},
          size = file.size,
          mtime = file.mtime,
        }
        table.insert(statsQueue, file)
      end
    end
  end

  if #statsQueue == 0 then
    finishStatsScan()
    return
  end

  statsScanning = true
  if not statsCacheReady then
    tokenStats = { status = "loading" }
    publish(currentStatus, currentError, currentAttemptedAt)
  end
  if not noctalia.commandExists("rg") or not noctalia.runStream(statsStreamCommand(statsQueue), onStatsStreamLine) then
    statsScanning = false
    tokenStats = { status = "unavailable" }
    nextStatsScanAt = os.time() + STATS_REFRESH_SECONDS
    noctalia.setUpdateInterval(IDLE_UPDATE_MS)
    publish(currentStatus, currentError, currentAttemptedAt)
  end
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
    "User-Agent: Noctalia-token-top/0.3.1",
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
    if statsCacheReady then
      beginStatsAggregation()
    else
      beginStatsScan()
    end
    inFlight = false
    publish("ready", nil, attemptedAt)
  end)

  if not started then
    fail(tr("errors.request_not_started"), attemptedAt)
  end
end

noctalia.setUpdateInterval(IDLE_UPDATE_MS)

noctalia.state.watch(REFRESH_REQUEST_KEY, function(_value)
  beginStatsScan()
  refreshUsage()
end)

-- Fetch the weekly boundaries first so the session stream only scans the
-- current and previous limit windows.
refreshUsage()

function update()
  if statsAggregating then
    processNextStatsAggregation()
  elseif not statsScanning and os.time() >= nextStatsScanAt then
    beginStatsScan()
  end
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
