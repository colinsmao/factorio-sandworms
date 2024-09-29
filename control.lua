core_util = require("__core__/lualib/util.lua") -- adds table.deepcopy

local Util = {}

--- Return the squared distance between two positions
---@param pos0 MapPosition
---@param pos1 MapPosition
function Util.dist2(pos0, pos1)
  return (pos0.x - pos1.x)^2 + (pos0.y - pos1.y)^2
end

--- Return the distance between two positions
---@param pos0 MapPosition
---@param pos1 MapPosition
function Util.dist(pos0, pos1)
  return math.sqrt(Util.dist2(pos0, pos1))
end

--- Return the orientation of a vector
---@param vector {x: number, y: number}
---@return number orientation
function Util.vector_to_orientation(vector)
  local orientation = math.atan2(vector.y, vector.x)/(2 * math.pi) + 0.25  -- atan2 [-0.5, 0.5) -> [-0.25, 0.75)
  return orientation % 1  -- [0, 1)
end

--- Return the difference of two orientations, in range [-0.5, 0.5)
---@param target number
---@param origin number
---@return number delta
function Util.delta_orientation(target, origin)
  local delta = target - origin  -- (-1, 1)
  if delta < -0.5 then delta = delta + 1 end  -- [-0.5, 1)
  if delta >= 0.5 then delta = delta - 1 end  -- [-0.5, 0.5)
  return delta
end


script.on_init(function()
  ---@type { [integer]: Worm } worm_id: worm
  global.worms = global.worms or {}
  ---@type { [integer]: integer } segment_id: worm_id
  global.segment_to_worm_id = global.segment_to_worm_id or {}
  ---@type { [integer]: integer } pathfinder_id: worm_id
  global.pathfinder_requests = global.pathfinder_requests or {}
end)

script.on_configuration_changed(function()  -- only for testing, because the format of global could change
  ---@type { [integer]: Worm } worm_id: worm
  global.worms = global.worms or {}
  ---@type { [integer]: integer } segment_id: worm_id
  global.segment_to_worm_id = global.segment_to_worm_id or {}
  ---@type { [integer]: integer } pathfinder_id: worm_id
  global.pathfinder_requests = global.pathfinder_requests or {}
end)


-- Some type annotations for dev. Does not get enforced at runtime

---@class Worm worm object
---@field id integer head.unit_number
---@field head LuaEntity "worm-head" entity
---@field segments Segment[] array of worm segments
---@field mode string mode {"idle", "direct_position", "direct_entity", "path"}, default "idle"
---@field target_position MapPosition? must exist for direct_position, could exist for path
---@field target_entity LuaEntity? must exist for direct_entity, could exist for path
---@field target_path Path table containing path info
---@field debug table debug info, mostly rendering ids
local Worm = {}
Worm.__index = Worm

---@class Segment pair of segment entity and its before entity
---@field entity LuaEntity
---@field before LuaEntity
local Segment = {}
Segment.__index = Segment

---@class Path table containing path info
---@field valid boolean if the path has been successfully requested
---@field retries integer current retry count for this target
---@field path PathfinderWaypoint[]? response from request_path
---@field idx integer? target idx within path
---@field pending_pathfinder_id integer? latest request id
---@field pending_pathfinder_tick integer? latest request tick (for cooldown)
---@field pending_position MapPosition? to fill in target_position if request is successful

Worm.WORM_LENGTH = 10  -- length of worm in segments (not counting head)
Worm.SEGMENT_SEP = 2  -- tiles; separation between segments
Worm.HEAD_UPDATE_FREQ = 10  -- ticks; update frequency for worm heads, which have pathfinding AI and stuff
Worm.SEGMENT_UPDATE_FREQ = 5  -- ticks; update frequency for worm segments, which are dumb but more numerous
if Worm.HEAD_UPDATE_FREQ == Worm.SEGMENT_UPDATE_FREQ then
  error("Cannot register two functions to the same nth tick.")
end
Worm.MIN_SPEED = 3/60  -- tiles per tick; will die/burrow if below this speed (otherwise animations break)
Worm.TARGET_SPEED = 10/60  -- tiles per tick; will accelerate up to this speed, but will not decelerate if above
Worm.PATHFINDER_COOLDOWN = 1  -- ticks; cooldown between pathfinder requests
Worm.PATHFINDER_MAX_RETRY = 3  -- int; max retries per pathfinder target
Worm.TURN_RADIUS = Worm.TARGET_SPEED / (2 * math.pi * 0.0035)  -- tiles; TODO read rotation_speed from prototype
Worm.CHARGE_RADIUS = 3 * Worm.TURN_RADIUS  -- tiles; distance within the worm just charges straight at the target
Worm.COLLISION_RADIUS = Worm.TARGET_SPEED * Worm.HEAD_UPDATE_FREQ  -- tiles; count as reached target
Worm.AGGRO_RANGE = 48  -- tiles; behemoth worm shooting range TODO read from prototypes


--- Constructor; init from a worm-head entity. Assumes head is valid
---@param head LuaEntity
---@return Worm
function Worm:new(head)
  local worm = {}
  setmetatable(worm, self)
  worm.id = head.unit_number
  worm.head = head
  worm.segments = {}
  worm.mode = "idle"
  worm.target_path = {valid = false}
  worm.debug = {}
  worm.debug.range = rendering.draw_circle{
    color = {r=1, g=0, b=0, a=0.001},
    radius = Worm.AGGRO_RANGE,
    width = 3,
    target = head,
    surface = head.surface,
    draw_on_ground = true,
  }
  global.worms[worm.id] = worm
  global.segment_to_worm_id[head.unit_number] = worm.id  -- register
  return worm
end

--- Constructor; init from segment entity and before entity
---@param entity LuaEntity the worm-segment entity
---@param before LuaEntity the before entity (can be a worm-segment or a worm-head)
---@return Segment
function Segment:new(entity, before)
  local segment = {
    entity = entity,
    before = before,
  }
  setmetatable(segment, self)
  return segment
end

--- Create body (list of segments) for a worm
---@param self Worm
function Worm:create_body()
  local orientation = self.head.orientation  -- [0, 1) clockwise, north=0
  local displacement = {x=math.sin(2*math.pi*orientation), y=-math.cos(2*math.pi*orientation)}
  local position = self.head.position
  local before = self.head
  for i=1,Worm.WORM_LENGTH do
    local segment = self.head.surface.create_entity{
      name = "worm-segment",
      position = {position.x - i * Worm.SEGMENT_SEP * displacement.x, position.y - i * Worm.SEGMENT_SEP * displacement.y},
      force = self.head.force
    }
    if not segment then
      error("failed to create worm segment")
    end
    segment.orientation = orientation  -- not an argument for create_entity
    segment.color = {r=0.0, g=0.5, b=0.0}
    table.insert(self.segments, Segment:new(segment, before))
    global.segment_to_worm_id[segment.unit_number] = self.id  -- register
    before = segment
  end
end


function Worm.on_entity_created(event)
  local entity
  if event.entity and event.entity.valid then  -- script_raise_built and revive
    entity = event.entity
  end
  if event.created_entity and event.created_entity.valid then  -- on_{robot_}built_entity
    entity = event.created_entity
  end
  if event.destination and event.destination.valid then  -- on_entity_cloned
    entity = event.destination
  end
  if not entity then return end

  local worm = Worm:new(entity)
  worm.head.color = {r=0.5, g=0.0, b=0.0}
  worm:create_body()

end
script.on_event(defines.events.on_built_entity, Worm.on_entity_created, {{filter = "name", name = "worm-head"}})
script.on_event(defines.events.on_robot_built_entity, Worm.on_entity_created, {{filter = "name", name = "worm-head"}})
script.on_event(defines.events.script_raised_built, Worm.on_entity_created, {{filter = "name", name = "worm-head"}})
script.on_event(defines.events.script_raised_revive, Worm.on_entity_created, {{filter = "name", name = "worm-head"}})
script.on_event(defines.events.on_entity_cloned, Worm.on_entity_created, {{filter = "name", name = "worm-head"}})


function Worm.on_entity_removed(event)
  if not event.entity or not event.entity.valid then return end

  local worm_id = global.segment_to_worm_id[event.entity.unit_number]
  local worm = global.worms[worm_id]
  if worm == nil then return end

  global.segment_to_worm_id[worm_id] = nil
  worm.head.destroy{raise_destroy=false}
  for _, segment in pairs(worm.segments) do
    if segment.entity.valid then
      global.segment_to_worm_id[segment.entity.unit_number] = nil
      segment.entity.destroy{raise_destroy=false}
    end
  end

  if worm.debug.path_points then
    for _, id in pairs(worm.debug.path_points) do
      rendering.destroy(id)
    end
  end
  if worm.debug.path_segments then
    for _, id in pairs(worm.debug.path_segments) do
      rendering.destroy(id)
    end
  end

  global.worms[worm_id] = nil

end
script.on_event(defines.events.on_entity_died, Worm.on_entity_removed, {{filter = "name", name = "worm-head"}, {filter = "name", name = "worm-segment"}})
script.on_event(defines.events.on_robot_mined_entity, Worm.on_entity_removed, {{filter = "name", name = "worm-head"}, {filter = "name", name = "worm-segment"}})
script.on_event(defines.events.on_player_mined_entity, Worm.on_entity_removed, {{filter = "name", name = "worm-head"}, {filter = "name", name = "worm-segment"}})
script.on_event(defines.events.script_raised_destroy, Worm.on_entity_removed, {{filter = "name", name = "worm-head"}, {filter = "name", name = "worm-segment"}})


script.on_event("left-click", function(event)
  local player = game.get_player(event.player_index)
  if player == nil then return end
  local cursor_stack = player.cursor_stack
  if cursor_stack == nil or not cursor_stack.valid_for_read then return end
  if cursor_stack.name == "iron-plate" then
    game.print(event.cursor_position)
    Worm.update_labels(nil)  -- refresh annotations
  elseif cursor_stack.name == "copper-plate" then
    -- path to click
    global.target_entity = player.surface.find_nearest_enemy{
      position = event.cursor_position,
      max_distance = 8,
      force = "enemy",  -- finds enemy of enemy, ie player structures
    }
    for _, worm in pairs(global.worms) do
      if global.target_entity then
        worm:set_target_entity(global.target_entity)
      else
        worm:set_target_position(event.cursor_position)
      end
    end
  elseif cursor_stack.name == "steel-plate" then
    -- destroy all worms
    for _, worm in pairs(global.worms) do
      worm.head.destroy{raise_destroy=true}
    end
  elseif cursor_stack.name == "plastic-bar" then
    local head = player.surface.create_entity{
      name = "worm-head",
      position = event.cursor_position,
      force = "enemy",
      create_build_effect_smoke = false,
      raise_built = false,
    }
    if not head then return end
    local worm = Worm:new(head)
    if global.target_entity and global.target_entity.valid then
      worm.head.orientation = Util.vector_to_orientation({
        x = global.target_entity.position.x - head.position.x,
        y = global.target_entity.position.y - head.position.y
      })
      worm:set_target_entity(global.target_entity)
    else
      worm.head.orientation = math.random()
    end
    worm:create_body()  -- requires orientation to be set
    -- ent.speed = Worm.TARGET_SPEED
  elseif cursor_stack.name == "iron-gear-wheel" then
    -- path to player
    for _, worm in pairs(global.worms) do
      worm:set_direct_entity(player.character)
    end
  end
end)


--- debug update labels
function Worm.update_labels(tickdata)
  global.labels = global.labels or {}
  for _, label in pairs(global.labels) do
    rendering.destroy(label)
  end
  global.labels = {}
  local player = game.get_player(1)
  if player == nil then return end
  for _, ent in pairs(player.surface.find_entities_filtered{name={"worm-head", "worm-segment"}}) do
    table.insert(global.labels, rendering.draw_text{
      text = ent.speed * 60,
      surface = player.surface,
      target = ent,  -- rendering object will be destroyed automatically when the entity is destroyed
      target_offset = {0, 1},
      color = {1, 1, 1}
    })
  end
end
script.on_nth_tick(6, Worm.update_labels)


--- debug destroy path segments
---@param self Worm
function Worm:destroy_path_rendering()
  if self.debug.path_points then
    for _, id in pairs(self.debug.path_points) do
      rendering.destroy(id)
    end
  end
  if self.debug.path_segments then
    for _, id in pairs(self.debug.path_segments) do
      rendering.destroy(id)
    end
  end
  self.debug.path_points = nil
  self.debug.path_segments = nil
end

-- debug draw or update direct path
---@param self Worm
---@param target MapPosition|LuaEntity
function Worm:draw_direct_path(target)
  if not self.debug.path_direct or not rendering.is_valid(self.debug.path_direct) then
    self.debug.path_direct = rendering.draw_line{
      color = {r=0,g=64,b=0,a=0.01},
      width = 3,
      from = self.head,
      to = target,
      surface = self.head.surface,
    }
  else
    -- rendering.set_from(self.debug.path_direct, worm.head)
    rendering.set_to(self.debug.path_direct, target)
  end
end

--- Set target position, with pathfinding request if necessary.
---@param self Worm
---@param target_position MapPosition
function Worm:set_target_position(target_position)
  -- If nearby, skip pathfinding request and just go directly there
  if Util.dist(self.head.position, target_position) < Worm.CHARGE_RADIUS then
    self:set_direct_position(target_position)
  else
    self.target_path.retries = 1
    self:request_path(target_position)
  end
end

--- Set target entity, with pathfinding request if necessary. Note, will pathfind to entity position at time of request
---@param self Worm
---@param target_entity LuaEntity
function Worm:set_target_entity(target_entity)
  -- If nearby, skip pathfinding request and just go directly there
  if Util.dist(self.head.position, target_entity.position) < Worm.CHARGE_RADIUS then
    self:set_direct_entity(target_entity)
  else
    self.target_path.retries = 1
    self:request_path(target_entity.position)
  end
end

--- Pathfinder request; should only be called by set_target_xx, for proper retry management
---@param self Worm
---@param target_position MapPosition
function Worm:request_path(target_position)
  -- if self.target_path.pending_pathfinder_tick and game.tick - self.target_path.pending_pathfinder_tick < Worm.PATHFINDER_COOLDOWN then return end
  self.target_path.pending_pathfinder_id = self.head.surface.request_path{
    bounding_box = self.head.bounding_box,
    collision_mask = self.head.prototype.collision_mask,
    start = self.head.position,
    goal = target_position,
    pathfind_flags = {
      allow_destroy_friendly_entities = true,
      cache = false,
      prefer_straight_paths = false,
      low_priority = false
    },
    force = self.head.force,
    can_open_gates = false,
    radius = 1,
    path_resolution_modifier = -3,  -- resolution = 2^-x
  }
  self.target_path.pending_pathfinder_tick = game.tick
  global.pathfinder_requests[self.target_path.pending_pathfinder_id] = self.id
  self.target_path.pending_position = target_position
end

--- Process asynchronous pathfinder response
function Worm.set_target_path(event)
  local worm = global.worms[global.pathfinder_requests[event.id]]
  global.pathfinder_requests[event.id] = nil
  if worm == nil then return end
  if event.id ~= worm.target_path.pending_pathfinder_id then return end  -- not the latest pathfinder request
  if event.try_again_later and worm.target_path.retries < Worm.PATHFINDER_MAX_RETRY then
    worm.target_path.retries = worm.target_path.retries + 1
    worm:request_path(worm.target_path.pending_position)
    return
  end
  if not event.path then return end
  worm.mode = "path"
  worm.target_path.valid = true
  worm.target_path.path = event.path
  worm.target_path.idx = 1
  worm.target_path.pending_pathfinder_id = nil
  worm.target_path.pending_pathfinder_tick = nil
  worm.target_position = worm.target_path.pending_position

  -- debug path rendering

  worm:draw_direct_path(worm.target_position)
  worm:destroy_path_rendering()
  worm.debug.path_points = {}
  worm.debug.path_segments = {}
  prev_pos = worm.head.position
  for _, pathpoint in pairs(worm.target_path.path) do
    table.insert(worm.debug.path_segments, rendering.draw_line{
      color = {r=0,g=64,b=0,a=0.01},
      width = 3,
      from = prev_pos,
      to = pathpoint.position,
      surface = worm.head.surface,
    })
    table.insert(worm.debug.path_points, rendering.draw_circle{
      color = {r=0,g=64,b=0,a=0.01},
      radius = 0.5,
      filled = true,
      target = pathpoint.position,
      surface = worm.head.surface,
    })
    prev_pos = pathpoint.position
  end
  rendering.set_color(worm.debug.path_points[worm.target_path.idx], {r=0,g=0,b=64,a=0.01})
  rendering.set_color(worm.debug.path_segments[worm.target_path.idx], {r=0,g=0,b=64,a=0.01})

end
script.on_event(defines.events.on_script_path_request_finished, Worm.set_target_path)

--- Set mode to idle
---@param self Worm
function Worm:set_idle()
  self.mode = "idle"
  self.target_position = nil
  self.target_entity = nil
  self.target_path.valid = false
  if self.debug.path_direct then
    rendering.destroy(self.debug.path_direct)
    self.debug.path_direct = nil
  end
  self:destroy_path_rendering()
end

--- Set direct position target
---@param self Worm
---@param position MapPosition
function Worm:set_direct_position(position)
  self.mode = "direct_position"
  self.target_position = position
  self.target_entity = nil
  self.target_path.valid = false
  self:destroy_path_rendering()
  self:draw_direct_path(position)
end

--- Set direct entity target
---@param self Worm
---@param entity LuaEntity
function Worm:set_direct_entity(entity)
  self.mode = "direct_entity"
  self.target_position = nil
  self.target_entity = entity
  self.target_path.valid = false
  self:destroy_path_rendering()
  self:draw_direct_path(entity)
end


--- Return riding_state acceleration. No validity checking
---@param self Worm
---@return defines.riding.acceleration
function Worm:get_acceleration()
  if self.mode == "direct_entity" or self.mode == "direct_position" or self.mode == "path" then
    -- Accelerate up to TARGET_SPEED
    if self.head.speed < Worm.TARGET_SPEED then
      return defines.riding.acceleration.accelerating
    end
    return defines.riding.acceleration.nothing
  end
  return defines.riding.acceleration.nothing
end

--- Return target position, for Worm:get_direction. No validity checking
---@param self Worm
---@return MapPosition
function Worm:get_target_position()
  if self.mode == "path" then
    return self.target_path.path[self.target_path.idx].position
  elseif self.mode == "direct_position" then
    return self.target_position
  elseif self.mode == "direct_entity" then
    return self.target_entity.position
  end
  return {0, 0}
end

--- Return riding_state direction. No validity checking
---@param self Worm
---@return defines.riding.direction
function Worm:get_direction()
  if self.head.speed < Worm.MIN_SPEED then
    return defines.riding.direction.straight
  end
  if self.mode == "direct_entity" or self.mode == "direct_position" or self.mode == "path" then
    local target_position = self:get_target_position()
    local disp = {
      x = target_position.x - self.head.position.x,
      y = target_position.y - self.head.position.y
    }
    local delta = Util.delta_orientation(Util.vector_to_orientation(disp), self.head.orientation)
    if math.abs(delta) >= 0.5 * self.head.prototype.rotation_speed * Worm.HEAD_UPDATE_FREQ then
      if delta < 0 then
        return defines.riding.direction.left
      else
        return defines.riding.direction.right
      end
    end
    return defines.riding.direction.straight
  end
  return defines.riding.direction.straight
end

--- Pop completed points from a path
---@param self Worm
function Worm:pop_path()
  while self.target_path.idx < #self.target_path.path do  -- pop up to the last point
    -- Since it takes time to turn, pop points up to some distance away. Possibly overkill
    local theta = Util.delta_orientation(
      Util.vector_to_orientation({
        x = self.head.position.x - self.target_path.path[self.target_path.idx].position.x,
        y = self.head.position.y - self.target_path.path[self.target_path.idx].position.y,
      }),
      Util.vector_to_orientation({
        x = self.target_path.path[self.target_path.idx + 1].position.x - self.target_path.path[self.target_path.idx].position.x,
        y = self.target_path.path[self.target_path.idx + 1].position.y - self.target_path.path[self.target_path.idx].position.y,
      })
    )
    -- The length of two tangents from a circle to their intersection, at angle theta. clip to prevent nan
    local dist_thresh = Worm.TURN_RADIUS / math.max(0.1, math.abs(math.tan(theta * math.pi)))
    if Util.dist(self.head.position, self.target_path.path[self.target_path.idx].position) < dist_thresh then
      if self.debug.path_points then
        rendering.set_color(self.debug.path_points[self.target_path.idx], {r=0,g=0,b=64,a=0.01})
        rendering.set_color(self.debug.path_points[self.target_path.idx + 1], {r=64,g=0,b=0,a=0.01})
      end
      if self.debug.path_segments then
        rendering.set_color(self.debug.path_segments[self.target_path.idx], {r=0,g=0,b=64,a=0.01})
        rendering.set_color(self.debug.path_segments[self.target_path.idx + 1], {r=64,g=0,b=0,a=0.01})
      end
      self.target_path.idx = self.target_path.idx + 1
    else
      break
    end
  end
end

--- Logic for worm heads, the only 'smart' part of a worm
---@param self Worm
function Worm:update_head()
  if self.head.force.name ~= "enemy" then return end

  -- TODO: auto set targets

  -- check whether the worm should repath, eg reached target, or invalid target (which might mean successfully destroyed)
  local repath = false
  -- invalid target
  if self.mode == "direct_entity" then
    if not self.target_entity.valid then
      repath = true
    else
      local dist = Util.dist(self.head.position, self.target_entity.position)
      if dist < Worm.COLLISION_RADIUS or dist > 1.2 * Worm.AGGRO_RANGE then  -- buffer to prevent instant retargetting
        repath = true
      end
    end
  elseif self.mode == "direct_position" or self.mode == "path" then
    -- path mode also has target_position set. But usually, path mode should've switched to direct mode already
    if Util.dist(self.head.position, self.target_position) < Worm.COLLISION_RADIUS then
      repath = true
    end
  end
  if repath then
    self:set_idle()  -- idle while waiting for pathfinder request
    local target_entity = self.head.surface.find_nearest_enemy{  -- is_military_target only
      position = self.head.position,
      max_distance = Worm.AGGRO_RANGE,
      force = self.head.force,  -- finds enemy of enemy, ie player structures
    }
    if target_entity then self:set_target_entity(target_entity) end
  end

  if self.mode == "path" then
    if not self.target_path.valid then
      -- If mode is path but the path is not ready yet, idle
      self.head.riding_state = {acceleration=defines.riding.acceleration.nothing, direction=defines.riding.direction.straight}
      return
    end
    if Util.dist(self.head.position, self.target_path.path[#self.target_path.path].position) < Worm.CHARGE_RADIUS then
      -- If almost there, switch to direct_position mode
      self:set_direct_position(self.target_position)
      self:destroy_path_rendering()
    else
      -- Pop completed points
      self:pop_path()
    end
  end

  self.head.riding_state = {
    acceleration = self:get_acceleration(),
    direction = self:get_direction(),
  }

end

function Worm.update_heads(tickdata)
  -- game.print("head"..tickdata.tick)
  for _, worm in pairs(global.worms) do
    worm:update_head()
  end
end
script.on_nth_tick(Worm.HEAD_UPDATE_FREQ, Worm.update_heads)


--- Logic for worm segments; follow the previous segment
---@param self Segment
function Segment:update_segment()
  local disp = {
    x = self.before.position.x - self.entity.position.x,
    y = self.before.position.y - self.entity.position.y
   }
  local clipped_ratio = math.max(0.1, math.min(2, math.sqrt(disp.x^2 + disp.y^2) / Worm.SEGMENT_SEP))  -- prevent explosion
  self.entity.speed = clipped_ratio * self.before.speed
  self.entity.orientation = Util.vector_to_orientation(disp)
end

function Worm.update_segments(tickdata)
  -- if tickdata.tick % Worm.HEAD_UPDATE_FREQ == 0 then
  --   game.print("segment"..tickdata.tick)
  -- end
  for _, worm in pairs(global.worms) do
    for _, segment in pairs(worm.segments) do
      segment:update_segment()
    end
  end
end
script.on_nth_tick(Worm.SEGMENT_UPDATE_FREQ, Worm.update_segments)


script.on_event(defines.events.on_script_trigger_effect, function(event)
  game.print("id="..event.effect_id)
  if event.source_entity then game.print("source="..event.source_entity.name) end
  if event.target_entity then game.print("target="..event.target_entity.name) end
end)


return Worm

