-- Read-only isolated BullMQ telemetry, retained v3.3.3 observer; no payloads or keys.
local result = {}
for _, name in ipairs({'sidecar', 'metadataExtraction'}) do
  local p = 'immich_bull:' .. name .. ':'
  local id = redis.call('GET', p .. 'id')
  local events = redis.call('XREVRANGE', p .. 'events', '+', '-', 'COUNT', 1)
  result[name] = {id = id or cjson.null,
    active = redis.call('LLEN', p .. 'active'),
    waiting = redis.call('LLEN', p .. 'wait'),
    paused = redis.call('LLEN', p .. 'paused'),
    delayed = redis.call('ZCARD', p .. 'delayed'),
    prioritized = redis.call('ZCARD', p .. 'prioritized'),
    completed = redis.call('ZCARD', p .. 'completed'),
    failed = redis.call('ZCARD', p .. 'failed'),
    eventLength = redis.call('XLEN', p .. 'events'),
    lastEventID = events[1] and events[1][1] or cjson.null}
end
return cjson.encode(result)
