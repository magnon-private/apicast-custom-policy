local handler = require "handler"

local _M = require('apicast.policy').new('Example', '0.1')
local new = _M.new


function _M.new(config)
  local self = new(config)
  self.config = config
  return self
end

function _M:access()
  handler.access(self.config)
end

return _M
