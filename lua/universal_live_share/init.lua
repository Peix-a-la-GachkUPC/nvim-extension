local uv = vim.uv
local bit = bit

local M = {}

local WS_HOST = "127.0.0.1"
local WS_PORT = 42069
local WS_PATH = "/"
local RECONNECT_MS = 1000
local SEND_DEBOUNCE_MS = 500
local SEND_MAX_WAIT_MS = 1000

local snapshots = {}
local attached = {}
local applying_remote = 0

local pending_by_buf = {}
local flush_timer_by_buf = {}
local first_buffered_at_by_buf = {}

local client = {
  tcp = nil,
  connected = false,
  handshake_done = false,
  read_buffer = "",
  reconnect_timer = nil,
}

local function notify(msg, level)
  vim.schedule(function()
    vim.notify("[universal-live-share] " .. msg, level or vim.log.levels.INFO)
  end)
end

local function is_trackable(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end

  if vim.bo[bufnr].buftype ~= "" then
    return false
  end

  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then
    return false
  end

  return true
end

local function buf_text(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, true)
  return table.concat(lines, "\n")
end

local function json_encode(obj)
  return vim.json.encode(obj)
end

local function json_decode(str)
  return vim.json.decode(str)
end

local function pack_u16(n)
  local b1 = math.floor(n / 256) % 256
  local b2 = n % 256
  return string.char(b1, b2)
end

local function pack_u64(n)
  local t = {}
  for i = 7, 0, -1 do
    local d = 2 ^ (i * 8)
    t[#t + 1] = string.char(math.floor(n / d) % 256)
  end
  return table.concat(t)
end

local function random_mask()
  return string.char(
    math.random(0, 255),
    math.random(0, 255),
    math.random(0, 255),
    math.random(0, 255)
  )
end

local function xor_mask(payload, mask)
  local out = {}
  for i = 1, #payload do
    local p = string.byte(payload, i)
    local m = string.byte(mask, ((i - 1) % 4) + 1)
    out[i] = string.char(bit.bxor(p, m))
  end
  return table.concat(out)
end

local function ws_frame_text(payload)
  local len = #payload
  local first = string.char(0x81)
  local second
  local ext = ""

  if len < 126 then
    second = string.char(bit.bor(0x80, len))
  elseif len <= 65535 then
    second = string.char(bit.bor(0x80, 126))
    ext = pack_u16(len)
  else
    second = string.char(bit.bor(0x80, 127))
    ext = pack_u64(len)
  end

  local mask = random_mask()
  return first .. second .. ext .. mask .. xor_mask(payload, mask)
end

local function ws_frame_pong(payload)
  payload = payload or ""
  local len = #payload
  local first = string.char(0x8A)
  local second = string.char(bit.bor(0x80, len))
  local mask = random_mask()
  return first .. second .. mask .. xor_mask(payload, mask)
end

local function parse_frame(buffer)
  if #buffer < 2 then
    return nil
  end

  local b1 = string.byte(buffer, 1)
  local b2 = string.byte(buffer, 2)
  local opcode = bit.band(b1, 0x0F)
  local masked = bit.band(b2, 0x80) ~= 0
  local len = bit.band(b2, 0x7F)
  local idx = 3

  if len == 126 then
    if #buffer < idx + 1 then
      return nil
    end
    len = string.byte(buffer, idx) * 256 + string.byte(buffer, idx + 1)
    idx = idx + 2
  elseif len == 127 then
    if #buffer < idx + 7 then
      return nil
    end
    len = 0
    for i = 0, 7 do
      len = len * 256 + string.byte(buffer, idx + i)
    end
    idx = idx + 8
  end

  local mask
  if masked then
    if #buffer < idx + 3 then
      return nil
    end
    mask = buffer:sub(idx, idx + 3)
    idx = idx + 4
  end

  if #buffer < idx + len - 1 then
    return nil
  end

  local payload = buffer:sub(idx, idx + len - 1)
  local rest = buffer:sub(idx + len)

  if masked and mask then
    payload = xor_mask(payload, mask)
  end

  return {
    opcode = opcode,
    payload = payload,
    rest = rest,
  }
end

local function send_payload(obj)
  if not client.connected or not client.tcp then
    return
  end
  local encoded = json_encode(obj)
  client.tcp:write(ws_frame_text(encoded))
end

local function flush_buffered(bufnr)
  local timer = flush_timer_by_buf[bufnr]
  if timer then
    timer:stop()
    timer:close()
    flush_timer_by_buf[bufnr] = nil
  end

  local commands = pending_by_buf[bufnr]
  if not commands or #commands == 0 then
    pending_by_buf[bufnr] = nil
    first_buffered_at_by_buf[bufnr] = nil
    return
  end

  send_payload(commands)
  pending_by_buf[bufnr] = nil
  first_buffered_at_by_buf[bufnr] = nil
end

local function schedule_flush(bufnr)
  local existing = flush_timer_by_buf[bufnr]
  if existing then
    existing:stop()
    existing:close()
  end

  local now = uv.now()
  local first = first_buffered_at_by_buf[bufnr] or now
  first_buffered_at_by_buf[bufnr] = first

  local elapsed = now - first
  local remaining_max_wait = math.max(0, SEND_MAX_WAIT_MS - elapsed)
  local delay = math.min(SEND_DEBOUNCE_MS, remaining_max_wait)

  local timer = uv.new_timer()
  timer:start(delay, 0, function()
    vim.schedule(function()
      flush_buffered(bufnr)
    end)
  end)
  flush_timer_by_buf[bufnr] = timer
end

local function byte_to_row_col(text, byte_index)
  local row = 0
  local line_start = 1
  local clamped = math.min(math.max(0, byte_index), #text)
  local target = clamped + 1

  while true do
    local nl = text:find("\n", line_start, true)
    if not nl or nl >= target then
      break
    end
    row = row + 1
    line_start = nl + 1
  end

  local col = math.max(0, target - line_start)
  return row, col
end

local function apply_remote_commands(commands)
  local bufnr = vim.api.nvim_get_current_buf()
  if not is_trackable(bufnr) then
    return
  end

  applying_remote = applying_remote + 1
  for _, command in ipairs(commands) do
    local text_before = buf_text(bufnr)
    local text_len = #text_before
    local index = math.min(math.max(0, command.index or 0), text_len)
    local row, col = byte_to_row_col(text_before, index)

    if command.add ~= nil then
      vim.api.nvim_buf_set_text(bufnr, row, col, row, col, vim.split(command.add, "\n", { plain = true }))
    elseif command.del ~= nil then
      local del = math.max(0, command.del or (type(command.deleted_text) == "string" and #command.deleted_text or 0))
      local end_index = math.min(index + del, text_len)
      local r2, c2 = byte_to_row_col(text_before, end_index)
      vim.api.nvim_buf_set_text(bufnr, row, col, r2, c2, {})
    end
  end
  applying_remote = applying_remote - 1

  snapshots[bufnr] = buf_text(bufnr)
end

local function handle_message(text)
  local ok, decoded = pcall(json_decode, text)
  if not ok then
    return
  end

  if type(decoded) ~= "table" or type(decoded.value) ~= "string" then
    return
  end

  local ok2, commands = pcall(json_decode, decoded.value)
  if not ok2 or type(commands) ~= "table" then
    return
  end

  vim.schedule(function()
    apply_remote_commands(commands)
  end)
end

local function schedule_reconnect()
  if client.reconnect_timer then
    client.reconnect_timer:stop()
    client.reconnect_timer:close()
  end

  client.reconnect_timer = uv.new_timer()
  client.reconnect_timer:start(RECONNECT_MS, 0, function()
    vim.schedule(function()
      M.connect()
    end)
  end)
end

function M.connect()
  if client.tcp and (client.connected or not client.handshake_done) then
    return
  end

  client.tcp = uv.new_tcp()
  client.connected = false
  client.handshake_done = false
  client.read_buffer = ""

  client.tcp:connect(WS_HOST, WS_PORT, function(err)
    if err then
      notify("websocket connect error: " .. tostring(err), vim.log.levels.WARN)
      if client.tcp then
        client.tcp:close()
      end
      client.tcp = nil
      schedule_reconnect()
      return
    end

    local key = "dGhlIHNhbXBsZSBub25jZQ=="
    local req = table.concat({
      "GET " .. WS_PATH .. " HTTP/1.1",
      "Host: " .. WS_HOST .. ":" .. WS_PORT,
      "Upgrade: websocket",
      "Connection: Upgrade",
      "Sec-WebSocket-Key: " .. key,
      "Sec-WebSocket-Version: 13",
      "",
      "",
    }, "\r\n")

    client.tcp:write(req)
    client.tcp:read_start(function(read_err, chunk)
      if read_err then
        notify("websocket read error: " .. tostring(read_err), vim.log.levels.WARN)
        return
      end

      if not chunk then
        client.connected = false
        client.handshake_done = false
        if client.tcp then
          client.tcp:close()
        end
        client.tcp = nil
        schedule_reconnect()
        return
      end

      client.read_buffer = client.read_buffer .. chunk

      if not client.handshake_done then
        local i = client.read_buffer:find("\r\n\r\n", 1, true)
        if not i then
          return
        end

        local headers = client.read_buffer:sub(1, i + 3)
        if not headers:find("101", 1, true) then
          notify("websocket handshake failed", vim.log.levels.WARN)
          return
        end

        client.handshake_done = true
        client.connected = true
        client.read_buffer = client.read_buffer:sub(i + 4)
      end

      while true do
        local frame = parse_frame(client.read_buffer)
        if not frame then
          break
        end

        client.read_buffer = frame.rest

        if frame.opcode == 0x1 then
          handle_message(frame.payload)
        elseif frame.opcode == 0x8 then
          client.connected = false
          if client.tcp then
            client.tcp:close()
          end
          client.tcp = nil
          schedule_reconnect()
          break
        elseif frame.opcode == 0x9 then
          if client.tcp then
            client.tcp:write(ws_frame_pong(frame.payload))
          end
        end
      end
    end)
  end)
end

local function attach_buffer(bufnr)
  if attached[bufnr] or not is_trackable(bufnr) then
    return
  end

  snapshots[bufnr] = buf_text(bufnr)

  vim.api.nvim_buf_attach(bufnr, false, {
    on_detach = function()
      attached[bufnr] = nil
      flush_buffered(bufnr)
      snapshots[bufnr] = nil
      pending_by_buf[bufnr] = nil
      first_buffered_at_by_buf[bufnr] = nil
      return true
    end,
    on_bytes = function(_, _, _, _, _, start_byte, _, _, old_end_byte, _, _, new_end_byte)
      if applying_remote > 0 then
        snapshots[bufnr] = buf_text(bufnr)
        return
      end

      local before = snapshots[bufnr] or ""
      local current = buf_text(bufnr)
      local commands = {}
      local del = old_end_byte
      if del > 0 then
        local from = math.min(math.max(0, start_byte), #before)
        local to = math.min(from + del, #before)
        local deleted_text = before:sub(from + 1, to)
        commands[#commands + 1] = { index = start_byte, del = del, deleted_text = deleted_text }
      end

      local add_text = ""
      if new_end_byte > 0 then
        add_text = current:sub(start_byte + 1, start_byte + new_end_byte)
      end
      if #add_text > 0 then
        commands[#commands + 1] = { index = start_byte, add = add_text }
      end

      if #commands > 0 then
        pending_by_buf[bufnr] = pending_by_buf[bufnr] or {}
        for _, cmd in ipairs(commands) do
          pending_by_buf[bufnr][#pending_by_buf[bufnr] + 1] = cmd
        end
        schedule_flush(bufnr)
      end

      snapshots[bufnr] = current
    end,
  })

  attached[bufnr] = true
end

function M.setup()
  math.randomseed(uv.hrtime())
  M.connect()

  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    attach_buffer(bufnr)
  end

  local group = vim.api.nvim_create_augroup("UniversalLiveShare", { clear = true })
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile" }, {
    group = group,
    callback = function(args)
      attach_buffer(args.buf)
    end,
  })

  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      for bufnr, _ in pairs(pending_by_buf) do
        flush_buffered(bufnr)
      end
      if client.tcp then
        client.tcp:close()
        client.tcp = nil
      end
    end,
  })
end

return M
