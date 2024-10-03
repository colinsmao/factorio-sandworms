
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


local WormStats = require("worm-stats")

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
---@field size string size {"small", "medium", "big", "behemoth"}
---@field head LuaEntity "worm-head" entity
---@field segments Segment[] array of worm segments
---@field mode string mode {"idle", "direct_position", "direct_entity", "path"}, default "idle"
---@field target_position MapPosition? must exist for direct_position, could exist for path
---@field target_entity LuaEntity? must exist for direct_entity, could exist for path
---@field target_path Path table containing path info
---@field debug table debug info, mostly rendering ids
local Worm = {}

---@class Segment pair of segment entity and its before entity
---@field entity LuaEntity
---@field before LuaEntity
---@field separation number tiles
local Segment = {}

---@class Path table containing path info
---@field valid boolean if the path has been successfully requested
---@field retries integer current retry count for this target
---@field path PathfinderWaypoint[]? response from request_path
---@field idx integer? target idx within path
---@field pending_pathfinder_id integer? latest request id
---@field pending_pathfinder_tick integer? latest request tick (for cooldown)
---@field pending_position MapPosition? to fill in target_position if request is successful

Worm.WORM_LENGTH = 10  -- length of worm in segments (not counting head)
Worm.BASE_SEGMENT_SEP = 1.8  -- tiles; separation between segments (will be scaled by size)
Worm.HEAD_UPDATE_FREQ = 10  -- ticks; update frequency for worm heads, which have pathfinding AI and stuff
Worm.SEGMENT_UPDATE_FREQ = 5  -- ticks; update frequency for worm segments, which are dumb but more numerous
if Worm.HEAD_UPDATE_FREQ == Worm.SEGMENT_UPDATE_FREQ then
  error("Cannot register two functions to the same nth tick.")
end
Worm.PATHFINDER_COOLDOWN = 1  -- ticks; cooldown between pathfinder requests
Worm.PATHFINDER_MAX_RETRY = 3  -- int; max retries per pathfinder target
Worm.SIZES = {"small", "medium", "big", "behemoth"}

--- union of func(size) for each size; eg {size.."-worm-head"}
---@param func fun(size: string): string[]
function Worm.size_map(func)
  local list = {}
  for _, size in pairs(Worm.SIZES) do
    for _, ret in pairs(func(size)) do
      table.insert(list, ret)
    end
  end
  return list
end


--- Constructor; init from a worm-head entity. Assumes head is valid
---@param head LuaEntity
---@return Worm
function Worm.new(head)
  local size = ""
  if head.name == "small-worm-head" then
    size = "small"
  elseif head.name == "medium-worm-head" then
    size = "medium"
  elseif head.name == "big-worm-head" then
    size = "big"
  elseif head.name == "behemoth-worm-head" then
    size = "behemoth"
  end
  if size == "" then error("invalid worm init entity: "..head.name) end
  ---@type Worm
  local worm = {
    id = head.unit_number,
    size = size,
    head = head,
    segments = {},
    mode = "idle",
    target_path = {
      valid = false,
      retries = 1,
    },
    debug = {},
  }
  worm.debug.range = rendering.draw_circle{
    color = {r=1, g=0, b=0, a=0.001},
    radius = WormStats[worm.size].range,
    width = 3,
    target = head,
    surface = head.surface,
    draw_on_ground = true,
  }
  global.worms[worm.id] = worm
  global.segment_to_worm_id[head.unit_number] = worm.id  -- register
  return worm
end


--- Create body (list of segments) for a worm
---@param worm Worm
function Worm.create_body(worm)
  local orientation = worm.head.orientation  -- [0, 1) clockwise, north=0
  local sep = WormStats[worm.size].scale * Worm.BASE_SEGMENT_SEP
  local displacement = {x=sep*math.sin(2*math.pi*orientation), y=-sep*math.cos(2*math.pi*orientation)}
  local position = worm.head.position
  local before = worm.head
  for i=1,Worm.WORM_LENGTH do
    local segment = worm.head.surface.create_entity{
      name = worm.size.."-worm-segment",
      position = {position.x - i * displacement.x, position.y - i * displacement.y},
      force = worm.head.force
    }
    if not segment then
      error("failed to create worm segment")
    end
    segment.orientation = orientation  -- not an argument for create_entity
    segment.color = {r=0.0, g=0.5, b=0.0}
    table.insert(worm.segments, {
      entity = segment,
      before = before,
      separation = sep
    })
    global.segment_to_worm_id[segment.unit_number] = worm.id  -- register
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

  local worm = Worm.new(entity)
  worm.head.color = {r=0.5, g=0.0, b=0.0}
  Worm.create_body(worm)

end
create_filter = Worm.size_map(function(size) return {{filter = "name", name = size.."-worm-head"}} end)
script.on_event(defines.events.on_built_entity, Worm.on_entity_created, create_filter)
script.on_event(defines.events.on_robot_built_entity, Worm.on_entity_created, create_filter)
script.on_event(defines.events.script_raised_built, Worm.on_entity_created, create_filter)
script.on_event(defines.events.script_raised_revive, Worm.on_entity_created, create_filter)
script.on_event(defines.events.on_entity_cloned, Worm.on_entity_created, create_filter)


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
destroy_filter = Worm.size_map(function(size) return {{filter = "name", name = size.."-worm-head"}, {filter = "name", name = size.."-worm-segment"}} end)
script.on_event(defines.events.on_entity_died, Worm.on_entity_removed, destroy_filter)
script.on_event(defines.events.on_robot_mined_entity, Worm.on_entity_removed, destroy_filter)
script.on_event(defines.events.on_player_mined_entity, Worm.on_entity_removed, destroy_filter)
script.on_event(defines.events.script_raised_destroy, Worm.on_entity_removed, destroy_filter)


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
        Worm.set_target_entity(worm, global.target_entity)
      else
        Worm.set_target_position(worm, event.cursor_position)
      end
    end
  elseif cursor_stack.name == "steel-plate" then
    -- destroy all worms
    for _, worm in pairs(global.worms) do
      worm.head.destroy{raise_destroy=true}
    end
  elseif cursor_stack.name == "plastic-bar" then
    local size = Worm.SIZES[math.random(4)]
    local head = player.surface.create_entity{
      name = size.."-worm-head",
      position = event.cursor_position,
      force = "enemy",
      create_build_effect_smoke = false,
      raise_built = false,
    }
    if not head then return end
    local worm = Worm.new(head)
    if global.target_entity and global.target_entity.valid then
      worm.head.orientation = Util.vector_to_orientation({
        x = global.target_entity.position.x - head.position.x,
        y = global.target_entity.position.y - head.position.y
      })
      Worm.set_target_entity(worm, global.target_entity)
    else
      worm.head.orientation = math.random()
    end
    Worm.create_body(worm)  -- requires orientation to be set
  elseif cursor_stack.name == "iron-gear-wheel" then
    -- path to player
    local pos = event.cursor_position
    for i=0,31 do
      local head = player.surface.create_entity{
        name = "big-worm-head",
        position = {x = pos.x + (i%8) * 8, y = pos.y + math.floor(i/8) * 8},
        force = "player",
        create_build_effect_smoke = false,
        raise_built = false,
      }
      if not head then return end
      local worm = Worm.new(head)
      worm.head.orientation = i/32
    end
  end
end)

local ent_filter = Worm.size_map(function(size) return {size.."-worm-head"} end)  -- , size.."-worm-segment"
--- debug update labels
function Worm.update_labels(tickdata)
  global.labels = global.labels or {}
  for _, label in pairs(global.labels) do
    rendering.destroy(label)
  end
  global.labels = {}
  local player = game.get_player(1)
  if player == nil then return end
  for _, ent in pairs(player.surface.find_entities_filtered{name=ent_filter}) do
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
---@param worm Worm
function Worm.destroy_path_rendering(worm)
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
  worm.debug.path_points = nil
  worm.debug.path_segments = nil
end

-- debug draw or update direct path
---@param worm Worm
---@param target MapPosition|LuaEntity
function Worm.draw_direct_path(worm, target)
  if not worm.debug.path_direct or not rendering.is_valid(worm.debug.path_direct) then
    worm.debug.path_direct = rendering.draw_line{
      color = {r=0,g=64,b=0,a=0.01},
      width = 3,
      from = worm.head,
      to = target,
      surface = worm.head.surface,
    }
  else
    -- rendering.set_from(worm.debug.path_direct, worm.head)
    rendering.set_to(worm.debug.path_direct, target)
  end
end

--- Set target position, with pathfinding request if necessary.
---@param worm Worm
---@param target_position MapPosition
function Worm.set_target_position(worm, target_position)
  -- If nearby, skip pathfinding request and just go directly there
  if Util.dist(worm.head.position, target_position) < 3 * WormStats[worm.size].turn_radius then
    Worm.set_direct_position(worm, target_position)
  else
    worm.target_path.retries = 1
    Worm.request_path(worm, target_position)
  end
end

--- Set target entity, with pathfinding request if necessary. Note, will pathfind to entity position at time of request
---@param worm Worm
---@param target_entity LuaEntity
function Worm.set_target_entity(worm, target_entity)
  -- If nearby, skip pathfinding request and just go directly there
  if Util.dist(worm.head.position, target_entity.position) < 3 * WormStats[worm.size].turn_radius then
    Worm.set_direct_entity(worm, target_entity)
  else
    worm.target_path.retries = 1
    Worm.request_path(worm, target_entity.position)
  end
end

--- Pathfinder request; should only be called by set_target_xx, for proper retry management
---@param worm Worm
---@param target_position MapPosition
function Worm.request_path(worm, target_position)
  -- if worm.target_path.pending_pathfinder_tick and game.tick - worm.target_path.pending_pathfinder_tick < Worm.PATHFINDER_COOLDOWN then return end
  worm.target_path.pending_pathfinder_id = worm.head.surface.request_path{
    bounding_box = worm.head.bounding_box,
    collision_mask = worm.head.prototype.collision_mask,
    start = worm.head.position,
    goal = target_position,
    pathfind_flags = {
      allow_destroy_friendly_entities = true,
      cache = false,
      prefer_straight_paths = false,
      low_priority = false
    },
    force = worm.head.force,
    can_open_gates = false,
    radius = 1,
    path_resolution_modifier = -3,  -- resolution = 2^-x
  }
  worm.target_path.pending_pathfinder_tick = game.tick
  global.pathfinder_requests[worm.target_path.pending_pathfinder_id] = worm.id
  worm.target_path.pending_position = target_position
end

--- Process asynchronous pathfinder response
function Worm.set_target_path(event)
  local worm = global.worms[global.pathfinder_requests[event.id]]
  global.pathfinder_requests[event.id] = nil
  if worm == nil then return end
  if event.id ~= worm.target_path.pending_pathfinder_id then return end  -- not the latest pathfinder request
  if event.try_again_later and worm.target_path.retries < Worm.PATHFINDER_MAX_RETRY then
    worm.target_path.retries = worm.target_path.retries + 1
    Worm.request_path(worm, worm.target_path.pending_position)
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

  Worm.draw_direct_path(worm, worm.target_position)
  Worm.destroy_path_rendering(worm)
  worm.debug.path_points = {}
  worm.debug.path_segments = {}
  local prev_pos = worm.head.position
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
---@param worm Worm
function Worm.set_idle(worm)
  worm.mode = "idle"
  worm.target_position = nil
  worm.target_entity = nil
  worm.target_path.valid = false
  if worm.debug.path_direct then
    rendering.destroy(worm.debug.path_direct)
    worm.debug.path_direct = nil
  end
  Worm.destroy_path_rendering(worm)
end

--- Set direct position target
---@param worm Worm
---@param position MapPosition
function Worm.set_direct_position(worm, position)
  worm.mode = "direct_position"
  worm.target_position = position
  worm.target_entity = nil
  worm.target_path.valid = false
  Worm.destroy_path_rendering(worm)
  Worm.draw_direct_path(worm, position)
end

--- Set direct entity target
---@param worm Worm
---@param entity LuaEntity
function Worm.set_direct_entity(worm, entity)
  worm.mode = "direct_entity"
  worm.target_position = nil
  worm.target_entity = entity
  worm.target_path.valid = false
  Worm.destroy_path_rendering(worm)
  Worm.draw_direct_path(worm, entity)
end


--- Return riding_state acceleration. No validity checking
---@param worm Worm
---@return defines.riding.acceleration
function Worm.get_acceleration(worm)
  if worm.mode == "direct_entity" or worm.mode == "direct_position" or worm.mode == "path" then
    -- Accelerate up to target_speed
    if worm.head.speed < WormStats[worm.size].target_speed then
      return defines.riding.acceleration.accelerating
    end
    return defines.riding.acceleration.nothing
  end
  return defines.riding.acceleration.nothing
end

--- Return target position, for Worm.get_direction. No validity checking
---@param worm Worm
---@return MapPosition
function Worm.get_target_position(worm)
  if worm.mode == "path" then
    return worm.target_path.path[worm.target_path.idx].position
  elseif worm.mode == "direct_position" then
    return worm.target_position
  elseif worm.mode == "direct_entity" then
    return worm.target_entity.position
  end
  return {0, 0}
end

--- Return riding_state direction. No validity checking
---@param worm Worm
---@return defines.riding.direction
function Worm.get_direction(worm)
  if worm.head.speed < 0.25 * WormStats[worm.size].target_speed then  -- prevent buggy looking animations
    return defines.riding.direction.straight
  end
  if worm.mode == "direct_entity" or worm.mode == "direct_position" or worm.mode == "path" then
    local target_position = Worm.get_target_position(worm)
    local disp = {
      x = target_position.x - worm.head.position.x,
      y = target_position.y - worm.head.position.y
    }
    local delta = Util.delta_orientation(Util.vector_to_orientation(disp), worm.head.orientation)
    if math.abs(delta) >= 0.5 * worm.head.prototype.rotation_speed * Worm.HEAD_UPDATE_FREQ then
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
---@param worm Worm
function Worm.pop_path(worm)
  while worm.target_path.idx < #worm.target_path.path do  -- pop up to the last point
    -- Since it takes time to turn, pop points up to some distance away. Possibly overkill
    local theta = Util.delta_orientation(
      Util.vector_to_orientation({
        x = worm.head.position.x - worm.target_path.path[worm.target_path.idx].position.x,
        y = worm.head.position.y - worm.target_path.path[worm.target_path.idx].position.y,
      }),
      Util.vector_to_orientation({
        x = worm.target_path.path[worm.target_path.idx + 1].position.x - worm.target_path.path[worm.target_path.idx].position.x,
        y = worm.target_path.path[worm.target_path.idx + 1].position.y - worm.target_path.path[worm.target_path.idx].position.y,
      })
    )
    -- The length of two tangents from a circle to their intersection, at angle theta. clip to prevent nan
    local dist_thresh = WormStats[worm.size].turn_radius / math.max(0.1, math.abs(math.tan(theta * math.pi)))
    if Util.dist(worm.head.position, worm.target_path.path[worm.target_path.idx].position) < dist_thresh then
      if worm.debug.path_points then
        rendering.set_color(worm.debug.path_points[worm.target_path.idx], {r=0,g=0,b=64,a=0.01})
        rendering.set_color(worm.debug.path_points[worm.target_path.idx + 1], {r=64,g=0,b=0,a=0.01})
      end
      if worm.debug.path_segments then
        rendering.set_color(worm.debug.path_segments[worm.target_path.idx], {r=0,g=0,b=64,a=0.01})
        rendering.set_color(worm.debug.path_segments[worm.target_path.idx + 1], {r=64,g=0,b=0,a=0.01})
      end
      worm.target_path.idx = worm.target_path.idx + 1
    else
      break
    end
  end
end

--- Logic for worm heads, the only 'smart' part of a worm
---@param worm Worm
function Worm.update_head(worm)
  if worm.head.force.name ~= "enemy" then return end

  -- TODO: auto set targets

  -- check whether the worm should repath, eg reached target, or invalid target (which might mean successfully destroyed)
  local repath = false
  -- invalid target
  if worm.mode == "direct_entity" then
    if not worm.target_entity.valid then
      repath = true
    else
      local dist = Util.dist(worm.head.position, worm.target_entity.position)
      if dist < WormStats[worm.size].target_speed * Worm.HEAD_UPDATE_FREQ or dist > 1.2 * WormStats[worm.size].range then  -- buffer to prevent instant retargetting
        repath = true
      end
    end
  elseif worm.mode == "direct_position" or worm.mode == "path" then
    -- path mode also has target_position set. But usually, path mode should've switched to direct mode already
    if Util.dist(worm.head.position, worm.target_position) < WormStats[worm.size].target_speed * Worm.HEAD_UPDATE_FREQ then
      repath = true
    end
  end
  if repath then
    Worm.set_idle(worm)  -- idle while waiting for pathfinder request
    local target_entity = worm.head.surface.find_nearest_enemy{  -- is_military_target only
      position = worm.head.position,
      max_distance = WormStats[worm.size].range,
      force = worm.head.force,  -- finds enemy of enemy, ie player structures
    }
    if target_entity then Worm.set_target_entity(worm, target_entity) end
  end

  if worm.mode == "path" then
    if not worm.target_path.valid then
      -- If mode is path but the path is not ready yet, idle
      worm.head.riding_state = {acceleration=defines.riding.acceleration.nothing, direction=defines.riding.direction.straight}
      return
    end
    if Util.dist(worm.head.position, worm.target_path.path[#worm.target_path.path].position) < 3 * WormStats[worm.size].turn_radius then
      -- If almost there, switch to direct_position mode
      Worm.set_direct_position(worm, worm.target_position)
      Worm.destroy_path_rendering(worm)
    else
      -- Pop completed points
      Worm.pop_path(worm)
    end
  end

  worm.head.riding_state = {
    acceleration = Worm.get_acceleration(worm),
    direction = Worm.get_direction(worm),
  }

end

function Worm.update_heads(tickdata)
  -- game.print("head"..tickdata.tick)
  for _, worm in pairs(global.worms) do
    Worm.update_head(worm)
  end
end
script.on_nth_tick(Worm.HEAD_UPDATE_FREQ, Worm.update_heads)


--- Logic for worm segments; follow the previous segment
---@param segment Segment
function Segment.update_segment(segment)
  local disp = {
    x = segment.before.position.x - segment.entity.position.x,
    y = segment.before.position.y - segment.entity.position.y
   }
  local clipped_ratio = math.max(0.1, math.min(2, math.sqrt(disp.x^2 + disp.y^2) / segment.separation))  -- prevent explosion
  segment.entity.speed = clipped_ratio * segment.before.speed
  segment.entity.orientation = Util.vector_to_orientation(disp)
end

function Worm.update_segments(tickdata)
  -- if tickdata.tick % Worm.HEAD_UPDATE_FREQ == 0 then
  --   game.print("segment"..tickdata.tick)
  -- end
  for _, worm in pairs(global.worms) do
    for _, segment in pairs(worm.segments) do
      Segment.update_segment(segment)
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

