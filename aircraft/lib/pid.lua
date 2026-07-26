local PID = {}
PID.__index = PID

local function clamp(value, minimum, maximum)
  if minimum and value < minimum then return minimum end
  if maximum and value > maximum then return maximum end
  return value
end

function PID.new(options)
  options = options or {}
  return setmetatable({
    kp = tonumber(options.kp) or 0,
    ki = tonumber(options.ki) or 0,
    kd = tonumber(options.kd) or 0,
    minimum = tonumber(options.minimum) or -1,
    maximum = tonumber(options.maximum) or 1,
    integralMinimum = tonumber(options.integralMinimum) or -1,
    integralMaximum = tonumber(options.integralMaximum) or 1,
    derivativeFilter = math.max(0, math.min(1, tonumber(options.derivativeFilter) or 0.65)),
    integral = 0,
    previousError = nil,
    derivative = 0,
  }, PID)
end

function PID:reset()
  self.integral = 0
  self.previousError = nil
  self.derivative = 0
end

function PID:update(error, dt, measuredRate)
  error = tonumber(error) or 0
  dt = math.max(0.001, tonumber(dt) or 0.05)

  self.integral = clamp(self.integral + error * dt, self.integralMinimum, self.integralMaximum)

  local derivative
  if measuredRate ~= nil then
    derivative = -(tonumber(measuredRate) or 0)
  elseif self.previousError ~= nil then
    derivative = (error - self.previousError) / dt
  else
    derivative = 0
  end

  self.derivative = self.derivative * self.derivativeFilter + derivative * (1 - self.derivativeFilter)
  self.previousError = error

  local output = self.kp * error + self.ki * self.integral + self.kd * self.derivative
  local limited = clamp(output, self.minimum, self.maximum)

  if limited ~= output and self.ki ~= 0 then
    self.integral = clamp(self.integral - error * dt, self.integralMinimum, self.integralMaximum)
  end

  return limited, {
    error = error,
    proportional = self.kp * error,
    integral = self.ki * self.integral,
    derivative = self.kd * self.derivative,
    unclamped = output,
  }
end

return PID
