local Recorder = {}
Recorder.__index = Recorder

local function ensureDirectory(path)
  local directory = fs.getDir(path)
  if directory and directory ~= "" and not fs.exists(directory) then fs.makeDir(directory) end
end

function Recorder.new(options)
  options = options or {}
  local root = options.root or "/navtool/logs"
  if not fs.exists(root) then fs.makeDir(root) end
  local stamp = tostring(os.epoch and os.epoch("utc") or math.floor(os.clock() * 1000))
  return setmetatable({
    enabled = options.enabled ~= false,
    path = options.path or fs.combine(root, "flight-" .. stamp .. ".log"),
    flushInterval = math.max(0.25, tonumber(options.flushInterval) or 2),
    maximumBuffer = math.max(1, math.floor(tonumber(options.maximumBuffer) or 40)),
    buffer = {},
    lastFlush = os.clock(),
  }, Recorder)
end

function Recorder:append(entry)
  if not self.enabled then return end
  entry = entry or {}
  entry.epoch = entry.epoch or (os.epoch and os.epoch("utc") or nil)
  entry.clock = entry.clock or os.clock()
  self.buffer[#self.buffer + 1] = textutils.serializeJSON and textutils.serializeJSON(entry) or textutils.serialize(entry)
  if #self.buffer >= self.maximumBuffer or os.clock() - self.lastFlush >= self.flushInterval then self:flush() end
end

function Recorder:flush()
  if not self.enabled or #self.buffer == 0 then return true end
  ensureDirectory(self.path)
  local file = fs.open(self.path, fs.exists(self.path) and "a" or "w")
  if not file then return false, "unable to open flight log" end
  for _, line in ipairs(self.buffer) do file.writeLine(line) end
  file.close()
  self.buffer = {}
  self.lastFlush = os.clock()
  return true
end

function Recorder:close()
  return self:flush()
end

return Recorder
