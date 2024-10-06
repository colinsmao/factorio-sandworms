
local WormStats = require("worm-stats")
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
---@param from MapPosition
---@param to MapPosition
---@return number orientation
function Util.vector_to_orientation(from, to)
  local orientation = math.atan2(to.y-from.y, to.x-from.x)/(2 * math.pi) + 0.25  -- atan2 [-0.5, 0.5) -> [-0.25, 0.75)
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


local debug_flag = false
script.on_init(function()
  ---@type { [integer]: Worm } worm_id: worm
  global.worms = global.worms or {}
  ---@type { [integer]: integer } segment_id: worm_id
  global.segment_to_worm_id = global.segment_to_worm_id or {}
  ---@type { [integer]: integer } pathfinder_id: worm_id
  global.pathfinder_requests = global.pathfinder_requests or {}
  debug_flag = settings.global["debug"].value
end)

script.on_configuration_changed(function()  -- only for testing, because the format of global could change
  ---@type { [integer]: Worm } worm_id: worm
  global.worms = global.worms or {}
  ---@type { [integer]: integer } segment_id: worm_id
  global.segment_to_worm_id = global.segment_to_worm_id or {}
  ---@type { [integer]: integer } pathfinder_id: worm_id
  global.pathfinder_requests = global.pathfinder_requests or {}
  debug_flag = settings.global["debug"].value
end)


-- Some type annotations for dev. Does not get enforced at runtime

---@alias Size "small"|"medium"|"big"|"behemoth"
---@alias Mode "idle"|"direct_position"|"direct_entity"|"path"|"reposition"|"stop"

---@class Worm worm object
---@field id integer head.unit_number
---@field size Size size {"small", "medium", "big", "behemoth"}
---@field head LuaEntity "worm-head" entity
---@field segments Segment[] array of worm segments
---@field mode Mode AI mode
---@field target_position MapPosition? must exist for direct_position, could exist for path
---@field target_entity LuaEntity? must exist for direct_entity, could exist for path
---@field target_path Path table containing path info
---@field accumulated_damage { [integer]: float } entity_id: accumulated damage taken
---@field dying boolean flag to prevent infinite loop during on_entity_died
---@field debug table debug info, mostly rendering ids

---@class Segment pair of segment entity and its before entity
---@field entity LuaEntity
---@field before LuaEntity
---@field separation number tiles

---@class Path table containing path info
---@field valid boolean if the path has been successfully requested
---@field retries integer current retry count for this target
---@field path PathfinderWaypoint[]? response from request_path
---@field idx integer? target idx within path
---@field pending_pathfinder_id integer? latest request id
---@field pending_pathfinder_tick integer? latest request tick (for cooldown)
---@field pending_position MapPosition? to fill in target_position if request is successful, and for retry
---@field pending_radius number? for retry


local Worm = {}
Worm.WORM_LENGTH = 10  -- length of worm in segments (not counting head)
Worm.BASE_SEGMENT_SEP = 2  -- tiles; separation between segments (will be scaled by speed)
Worm.HEAD_UPDATE_FREQ = 10  -- ticks; update frequency for worm heads, which have pathfinding AI and stuff
Worm.SEGMENT_UPDATE_FREQ = 2  -- ticks; update frequency for worm segments, which are dumb but more numerous
if Worm.HEAD_UPDATE_FREQ == Worm.SEGMENT_UPDATE_FREQ then
  error("Cannot register two functions to the same nth tick.")
end
Worm.PATHFINDER_COOLDOWN = 1  -- ticks; cooldown between pathfinder requests
Worm.PATHFINDER_MAX_RETRY = 3  -- int; max retries per pathfinder target
---@type Size[]

--- union of func(size) for each size; eg {size.."-worm-head"}
---@param func fun(size: Size): string[]
function Worm.size_map(func)
  local list = {}
  for _, size in pairs(WormStats.SIZES) do
    for _, ret in pairs(func(size)) do
      table.insert(list, ret)
    end
  end
  return list
end
local head_filter = Worm.size_map(function(size) return {{filter = "name", name = size.."-worm-head"}} end)
local head_segment_filter = Worm.size_map(function(size) return {{filter = "name", name = size.."-worm-head"}, {filter = "name", name = size.."-worm-segment"}} end)


--- Constructor; init from a worm-head entity. Assumes head is valid
---@param head LuaEntity
---@return Worm
function Worm._new(head)
  local size = nil
  if head.name == "small-worm-head" then
    size = "small"
  elseif head.name == "medium-worm-head" then
    size = "medium"
  elseif head.name == "big-worm-head" then
    size = "big"
  elseif head.name == "behemoth-worm-head" then
    size = "behemoth"
  end
  if not size then error("invalid worm init entity: "..head.name) end
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
    accumulated_damage = {},
    dying = false,
    debug = {},
  }
  global.worms[worm.id] = worm
  global.segment_to_worm_id[head.unit_number] = worm.id  -- register
  if debug_flag then Worm._draw_range(worm) end
  return worm
end


--- Create body (list of segments) for a worm
---@param worm Worm
---@return boolean success
function Worm._create_body(worm)
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
    if not segment then return false end
    segment.orientation = orientation  -- not an argument for create_entity
    segment.speed = worm.head.speed
    table.insert(worm.segments, {
      entity = segment,
      before = before,
      separation = sep
    })
    global.segment_to_worm_id[segment.unit_number] = worm.id  -- register
    before = segment
  end
  return true
end

--- Create a worm with orientation
---@param surface LuaSurface
---@param force ForceIdentification
---@param size Size
---@param position MapPosition
---@param orientation number
---@return Worm?
function Worm.create_worm_with_orientation(surface, force, size, position, orientation)
  local head = surface.create_entity{
    name = size.."-worm-head",
    position = position,
    force = force,
    create_build_effect_smoke = false,
    raise_built = false,
  }
  if not head then return end
  local worm = Worm._new(head)
  worm.head.orientation = orientation
  worm.head.speed = WormStats[size].target_speed
  if not Worm._create_body(worm) then
    worm.head.destroy{raise_destroy=true}  -- will also destroy any segments that were created
    return
  end
  return worm
end


--- Creates a body for a manually placed worm (for debugging only, as otherwise there is no worm item to place)
---@param event EventData.on_built_entity|EventData.script_raised_built|EventData.on_entity_cloned
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

  local worm = Worm._new(entity)
  worm.head.color = {r=0.5, g=0.0, b=0.0}
  if not Worm._create_body(worm) then
    worm.head.destroy{raise_destroy=true}  -- will also destroy any segments that were created
    return
  end
end
script.on_event(defines.events.on_built_entity, Worm.on_entity_created, head_filter)
script.on_event(defines.events.on_robot_built_entity, Worm.on_entity_created, head_filter)
script.on_event(defines.events.script_raised_built, Worm.on_entity_created, head_filter)
script.on_event(defines.events.script_raised_revive, Worm.on_entity_created, head_filter)
script.on_event(defines.events.on_entity_cloned, Worm.on_entity_created, head_filter)


--- Kills all other segments if a single segment/head dies
---@param event EventData.on_entity_died
function Worm.on_entity_removed(event)
  if not event.entity or not event.entity.valid then return end

  local worm_id = global.segment_to_worm_id[event.entity.unit_number]
  if not worm_id then return end
  local worm = global.worms[worm_id]
  if not worm then return end
  if worm.dying then return end  -- prevent infinite loop (since this function may call .die)
  worm.dying = true

  ---@param entity LuaEntity
  local kill_func = function(entity)
    -- if not entity.valid then return end
    global.segment_to_worm_id[entity.unit_number] = nil  -- deregister
    if entity.unit_number == event.entity.unit_number then return end  -- already dying
    if event.name == defines.events.on_entity_died then
      if event.force then
        if event.cause then
          entity.die(event.force, event.cause)
        else
          entity.die(event.force)
        end
      else
        entity.die()  -- reasonably sure it won't fire with a cause but no force, since force == cause.force
      end
    else  -- mined or script_raised_destroy
      entity.destroy{raise_destroy=false}
    end
  end

  kill_func(worm.head)
  for _, segment in pairs(worm.segments) do
    kill_func(segment.entity)
  end

  if debug_flag then
    Worm._destroy_path_rendering(worm)
    -- since other rendering objects have target=entity, they will be automatically destroyed
  end

  global.worms[worm_id] = nil  -- should be the only reference to worm, so it'll be GCed

end
script.on_event(defines.events.on_entity_died, Worm.on_entity_removed, head_segment_filter)
script.on_event(defines.events.on_robot_mined_entity, Worm.on_entity_removed, head_segment_filter)
script.on_event(defines.events.on_player_mined_entity, Worm.on_entity_removed, head_segment_filter)
script.on_event(defines.events.script_raised_destroy, Worm.on_entity_removed, head_segment_filter)


script.on_event("left-click", function(event)
  local player = game.get_player(event.player_index)
  if not player then return end
  local cursor_stack = player.cursor_stack
  if not cursor_stack or not cursor_stack.valid_for_read then return end
  if cursor_stack.name == "iron-plate" then
    -- game.print(event.cursor_position)
    rendering.draw_circle{
      color = {1,0,0},
      radius = 4,
      filled = false,
      target = event.cursor_position,
      surface = player.surface,
      time_to_live = 60,
    }
    local entities = player.surface.find_entities_filtered{
      position = event.cursor_position,
      radius = 4,
      type = "cliff"
    }
    for _, ent in pairs(entities) do
      ent.destroy{do_cliff_correction=true}
    end
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
        Worm.set_target_position(worm, event.cursor_position, 1)
      end
    end
  elseif cursor_stack.name == "steel-plate" then
    -- destroy all worms
    for _, worm in pairs(global.worms) do
      worm.head.destroy{raise_destroy=true}
    end
  elseif cursor_stack.name == "plastic-bar" then
    local size = WormStats.SIZES[math.random(4)]
    local orientation = math.random()
    if global.target_entity and global.target_entity.valid then
      orientation = Util.vector_to_orientation(event.cursor_position, global.target_entity.position)
    end
    local worm = Worm.create_worm_with_orientation(player.surface, "enemy", size, event.cursor_position, orientation)
    if not worm then return end
    if global.target_entity and global.target_entity.valid then
      Worm.set_target_entity(worm, global.target_entity)
    end
  elseif cursor_stack.name == "iron-gear-wheel" then
    -- check orientation sprites
    local pos = event.cursor_position
    for i=0,63 do
      local head = player.surface.create_entity{
        name = "big-worm-head",
        position = {x = pos.x + (i%8) * 8, y = pos.y + math.floor(i/8) * 8},
        force = "player",
        create_build_effect_smoke = false,
        raise_built = false,
      }
      if not head then return end
      local worm = Worm._new(head)
      worm.head.orientation = i/64
    end
  end
end)

script.on_event("right-click", function(event)
  local player = game.get_player(event.player_index)
  if not player then return end
  local cursor_stack = player.cursor_stack
  if not cursor_stack or not cursor_stack.valid_for_read then return end
  if cursor_stack.name == "iron-plate" then
  elseif cursor_stack.name == "copper-plate" then
  elseif cursor_stack.name == "steel-plate" then
    -- stop all worms
    for _, worm in pairs(global.worms) do
      Worm.set_stop(worm)
    end
  elseif cursor_stack.name == "plastic-bar" then
  elseif cursor_stack.name == "iron-gear-wheel" then
  end
end)


--- debug update rendering objects
---@param worm Worm
function Worm.update_rendering(worm)
  if not debug_flag then return end
  if worm.mode == "path" then
    Worm._draw_direct_rendering(worm, worm.target_position)
    Worm._draw_path_rendering(worm)
  elseif worm.mode == "direct_position" then
    Worm._destroy_path_rendering(worm)
    Worm._draw_direct_rendering(worm, worm.target_position)
  elseif worm.mode == "direct_entity" then
    Worm._destroy_path_rendering(worm)
    Worm._draw_direct_rendering(worm, worm.target_entity)
  elseif worm.mode == "idle" or worm.mode == "stop" then
    Worm._destroy_path_rendering(worm)
    Worm._destroy_direct_rendering(worm)
  end
end

---@param worm Worm
function Worm._draw_path_rendering(worm)
  Worm._destroy_path_rendering(worm)
  worm.debug.path_points = {}
  worm.debug.path_segments = {}
  local prev_pos = worm.head.position
  for i, pathpoint in pairs(worm.target_path.path) do
    local color
    if i < worm.target_path.idx then
      color = {r=0,g=0,b=64,a=0.01}
    elseif i > worm.target_path.idx then
      color = {r=0,g=64,b=0,a=0.01}
    else  -- i == idx
      color = {r=64,g=0,b=0,a=0.01}
    end
    table.insert(worm.debug.path_segments, rendering.draw_line{
      color = color,
      width = 3,
      from = prev_pos,
      to = pathpoint.position,
      surface = worm.head.surface,
    })
    table.insert(worm.debug.path_points, rendering.draw_circle{
      color = color,
      radius = 0.5,
      filled = true,
      target = pathpoint.position,
      surface = worm.head.surface,
    })
    prev_pos = pathpoint.position
  end
end

---@param worm Worm
---@param idx integer worm.target_path.idx (post increment)
function Worm.increment_path_rendering(worm, idx)
  if worm.debug.path_points then
    rendering.set_color(worm.debug.path_points[idx - 1], {r=0,g=0,b=64,a=0.01})
    rendering.set_color(worm.debug.path_points[idx], {r=64,g=0,b=0,a=0.01})
  end
  if worm.debug.path_segments then
    rendering.set_color(worm.debug.path_segments[idx - 1], {r=0,g=0,b=64,a=0.01})
    rendering.set_color(worm.debug.path_segments[idx], {r=64,g=0,b=0,a=0.01})
  end
end

---@param worm Worm
function Worm._destroy_path_rendering(worm)
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

---@param worm Worm
---@param target MapPosition|LuaEntity
function Worm._draw_direct_rendering(worm, target)
  if not worm.debug.direct_line or not rendering.is_valid(worm.debug.direct_line) then
    worm.debug.direct_line = rendering.draw_line{
      color = {r=0,g=64,b=0,a=0.01},
      width = 3,
      from = worm.head,
      to = target,
      surface = worm.head.surface,
    }
  else
    rendering.set_to(worm.debug.direct_line, target)  -- assume from is worm.head already
  end
end

---@param worm Worm
function Worm._destroy_direct_rendering(worm)
  if worm.debug.direct_line then
    rendering.destroy(worm.debug.direct_line)
    worm.debug.direct_line = nil
  end
end

---@param worm Worm
function Worm._draw_range(worm)
  worm.debug.range = rendering.draw_circle{
    color = {r=1, g=0, b=0, a=0.001},
    radius = WormStats[worm.size].range,
    width = 2,
    target = worm.head,
    surface = worm.head.surface,
    draw_on_ground = true,
  }
end

---@param worm Worm
function Worm._destroy_range(worm)
  if worm.debug.range then
    rendering.destroy(worm.debug.range)
  end
end

script.on_event(defines.events.on_runtime_mod_setting_changed, function(event)
  if event.setting ~= "debug" then return end
  debug_flag = settings.global["debug"].value
  if debug_flag then
    for _, worm in pairs(global.worms) do
      Worm.update_rendering(worm)
      Worm._draw_range(worm)
    end
  else
    for _, worm in pairs(global.worms) do
      Worm._destroy_direct_rendering(worm)
      Worm._destroy_path_rendering(worm)
      Worm._destroy_range(worm)
    end
  end
end)


--- Set target position, with pathfinding request if necessary.
---@param worm Worm
---@param target_position MapPosition
---@param radius number
function Worm.set_target_position(worm, target_position, radius)
  -- If nearby, skip pathfinding request and just go directly there
  Worm.set_direct_position(worm, target_position)  -- start moving first
  if Util.dist(worm.head.position, target_position) > 3 * WormStats[worm.size].turn_radius then
    worm.target_path.retries = 1
    Worm.request_path(worm, target_position, radius)
  end
end

--- Set target entity, with pathfinding request if necessary. Note, will pathfind to entity position at time of request
---@param worm Worm
---@param target_entity LuaEntity
function Worm.set_target_entity(worm, target_entity)
  Worm.set_direct_entity(worm, target_entity)  -- start moving first
  if Util.dist(worm.head.position, target_entity.position) > 3 * WormStats[worm.size].turn_radius then
    worm.target_path.retries = 1
    Worm.request_path(worm, target_entity.position, 1)
  end
end

--- Pathfinder request; should only be called by set_target_xx, for proper retry management
---@param worm Worm
---@param target_position MapPosition
---@param radius number
function Worm.request_path(worm, target_position, radius)
  radius = radius or 1
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
    radius = radius,
    path_resolution_modifier = -3,  -- resolution = 2^-x
  }
  worm.target_path.pending_pathfinder_tick = game.tick
  global.pathfinder_requests[worm.target_path.pending_pathfinder_id] = worm.id
  worm.target_path.pending_position = target_position
  worm.target_path.pending_radius = radius
end

--- Process asynchronous pathfinder response
---@param event EventData.on_script_path_request_finished
function Worm.set_target_path(event)
  local worm = global.worms[global.pathfinder_requests[event.id]]
  global.pathfinder_requests[event.id] = nil
  if not worm then return end
  if event.id ~= worm.target_path.pending_pathfinder_id then return end  -- not the latest pathfinder request
  if event.try_again_later and worm.target_path.retries < Worm.PATHFINDER_MAX_RETRY then
    worm.target_path.retries = worm.target_path.retries + 1
    Worm.request_path(worm, worm.target_path.pending_position, worm.target_path.pending_radius)
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

  if debug_flag then Worm.update_rendering(worm) end
end
script.on_event(defines.events.on_script_path_request_finished, Worm.set_target_path)

--- Set mode to idle
---@param worm Worm
function Worm.set_idle(worm)
  worm.mode = "idle"
  worm.target_position = nil
  worm.target_entity = nil
  worm.target_path.valid = false

  if debug_flag then Worm.update_rendering(worm) end
end

--- Set mode to stop
---@param worm Worm
function Worm.set_stop(worm)
  worm.mode = "stop"
  worm.target_position = nil
  worm.target_entity = nil
  worm.target_path.valid = false

  if debug_flag then Worm.update_rendering(worm) end
end

--- Set direct position target
---@param worm Worm
---@param position MapPosition
function Worm.set_direct_position(worm, position)
  worm.mode = "direct_position"
  worm.target_position = position
  worm.target_entity = nil
  worm.target_path.valid = false

  if debug_flag then Worm.update_rendering(worm) end
end

--- Set direct entity target
---@param worm Worm
---@param entity LuaEntity
function Worm.set_direct_entity(worm, entity)
  worm.mode = "direct_entity"
  worm.target_position = nil
  worm.target_entity = entity
  worm.target_path.valid = false

  if debug_flag then Worm.update_rendering(worm) end
end


--- Burrow, ie disappear and become a worm turret
---@param worm Worm
function Worm.burrow(worm)
  local surface = worm.head.surface
  local size = worm.size
  local position = worm.head.position
  local force = worm.head.force
  local health_ratio = worm.head.get_health_ratio()
  worm.head.destroy{raise_destroy=true}
  local worm_turret = surface.create_entity{
    name = size.."-worm-turret",
    position = position,
    force = force
  }
  worm_turret.health = math.max(1, health_ratio * game.entity_prototypes[size.."-worm-turret"].max_health)
end


--- Return riding_state acceleration. No validity checking
---@param worm Worm
---@return defines.riding.acceleration
function Worm.get_acceleration(worm)
  -- Accelerate up to target_speed
  if worm.mode == "stop" then
    return defines.riding.acceleration.braking
  elseif worm.mode ~= "idle" and worm.head.speed < WormStats[worm.size].target_speed then
    return defines.riding.acceleration.accelerating
  end
  return defines.riding.acceleration.nothing
end

--- Return current target orientation, for Worm.get_direction. No validity checking
---@param worm Worm
---@return number orientation
function Worm._get_target_orientation(worm)
  local target_position = nil
  if worm.mode == "path" then
    target_position = worm.target_path.path[worm.target_path.idx].position
  elseif worm.mode == "direct_position" then
    target_position = worm.target_position
  elseif worm.mode == "direct_entity" then
    target_position = worm.target_entity.position
  end
  if target_position then
    return Util.vector_to_orientation(worm.head.position, target_position)
  else
    return worm.head.orientation
  end
end

--- Return riding_state direction. No validity checking
---@param worm Worm
---@return defines.riding.direction
function Worm.get_direction(worm)
  if worm.head.speed < 0.25 * WormStats[worm.size].target_speed then  -- prevent buggy looking animations
    return defines.riding.direction.straight
  end
  if worm.mode == "direct_entity" or worm.mode == "direct_position" or worm.mode == "path" then
    local delta = Util.delta_orientation(Worm._get_target_orientation(worm), worm.head.orientation)
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
      Util.vector_to_orientation(worm.target_path.path[worm.target_path.idx].position, worm.head.position),
      Util.vector_to_orientation(worm.target_path.path[worm.target_path.idx].position, worm.target_path.path[worm.target_path.idx + 1].position)
    )
    -- The length of two tangents from a circle to their intersection, at angle theta. clip to prevent nan
    local dist_thresh = WormStats[worm.size].turn_radius / math.max(0.1, math.abs(math.tan(theta * math.pi)))
    if Util.dist(worm.head.position, worm.target_path.path[worm.target_path.idx].position) < dist_thresh then
      worm.target_path.idx = worm.target_path.idx + 1
      if debug_flag then Worm.increment_path_rendering(worm, worm.target_path.idx) end
    else
      break
    end
  end
end


--- Emulate "distractions" by hooking to on_entity_damaged
---@param event EventData.on_entity_damaged
function Worm.on_entity_damaged(event)
  if not event.entity or not event.entity.valid then return end
  local worm_id = global.segment_to_worm_id[event.entity.unit_number]
  if not worm_id then return end
  local worm = global.worms[worm_id]
  if not worm then error("on_entity_damaged: invalid worm") end
  if not event.force or not worm.head.force.is_enemy(event.force) then return end
  if not event.cause or not event.cause.valid then return end
  local cid = event.cause.unit_number
  if not cid then return end
  -- game.print("dmg src: "..event.cause.name..":"..event.cause.unit_number.."="..event.final_damage_amount)
  worm.accumulated_damage[cid] = (worm.accumulated_damage[cid] or 0) + event.final_damage_amount
  if worm.accumulated_damage[cid] > WormStats[worm.size].max_health * 0.2 then
    Worm.set_target_entity(worm, event.cause)
    worm.accumulated_damage = {}  -- reset accumulated damage
  end
end
script.on_event(defines.events.on_entity_damaged, Worm.on_entity_damaged, head_segment_filter)


---@param worm Worm
---@return MapPosition? position
function Worm.get_target_position(worm)
  -- target_entity takes priority
  if worm.target_entity and worm.target_entity.valid then
    return worm.target_entity.position
  end
  return worm.target_position
end


--- Logic for worm heads, the only 'smart' part of a worm
---@param worm Worm
function Worm.update_head(worm)
  if worm.head.force.name ~= "enemy" then return end

  -- idle worms can be stopped, but all other worms burrow if stopped/stuck
  if worm.mode ~= "idle" and worm.head.speed < 0.25 * WormStats[worm.size].target_speed then
    Worm.burrow(worm)
    return
    -- local target_position = {
    --   x = worm.head.position.x + WormStats[worm.size].collision_box[2][2] * math.sin(2*math.pi*worm.head.orientation),
    --   y = worm.head.position.y - WormStats[worm.size].collision_box[2][2] * math.cos(2*math.pi*worm.head.orientation)
    -- }
    -- rendering.draw_circle{
    --   color = {1,0,0},
    --   radius = WormStats[worm.size].scale * 5,
    --   filled = false,
    --   target = target_position,
    --   surface = worm.head.surface,
    --   time_to_live = 60,
    -- }
    -- local cliffs = worm.head.surface.find_entities_filtered{
    --   position = target_position,
    --   radius = WormStats[worm.size].scale * 5,
    --   type = "cliff"
    -- }
    -- if #cliffs > 0 then
    --   for _, cliff in pairs(cliffs) do
    --     cliff.destroy{do_cliff_correction=true}
    --   end
    --   worm.head.speed = WormStats[worm.size].target_speed
    -- else
    --   Worm.burrow(worm)
    --   return
    -- end
  end
  if worm.mode == "idle" then
    worm.head.riding_state = {
      acceleration = defines.riding.acceleration.nothing,
      direction = defines.riding.direction.straight,
    }
    return
  elseif worm.mode == "stop" then
    worm.head.riding_state = {
      acceleration = defines.riding.acceleration.braking,
      direction = defines.riding.direction.straight,
    }
    return
  end

  -- check whether the worm should repath; generally if reached target
  local repath = false
  local target_position = Worm.get_target_position(worm)
  local dist = nil
  if target_position then
    dist = Util.dist(worm.head.position, target_position)
    -- if reached target position (within a threshold)
    if dist < WormStats[worm.size].target_speed * Worm.HEAD_UPDATE_FREQ then
      repath = true
    end
    -- lose target if it moves too far away, with 1.2 buffer to prevent instant retargetting
    -- if worm.mode == "direct_entity" and dist > 1.2 * WormStats[worm.size].range then
    --   repath = true
    -- end
  else  -- not target_position
    repath = true
  end
  if repath then
    local target_entity = worm.head.surface.find_nearest_enemy{  -- is_military_target only
      position = worm.head.position,
      max_distance = WormStats[worm.size].range,
      force = worm.head.force,  -- finds enemy of this force
    }
    if target_entity then
      Worm.set_target_entity(worm, target_entity)
      target_position = Worm.get_target_position(worm)
      dist = target_position and Util.dist(worm.head.position, target_position)
    else
      Worm.set_stop(worm)
    end
  end

  if target_position and (worm.mode == "direct_position" or worm.mode == "direct_entity") then  -- calculated above
    -- if in direct mode but stuck in orbit, switch to reposition mode, which just drives straight
    if dist < WormStats[worm.size].turn_radius then  -- closer than turn_radius
      local disp_ori = Util.vector_to_orientation(worm.head.position, target_position)
      local delta = Util.delta_orientation(disp_ori, worm.head.orientation)
      if math.abs(delta) > 0.25 then  -- and moving away
        worm.mode = "reposition"
      end
    end
  end
  if worm.mode == "reposition" then
    if worm.target_entity and worm.target_entity.valid and (
          (worm.target_entity.speed and worm.target_entity.speed > 0) or
          (worm.target_entity.name == "character" and worm.target_entity.walking_state and worm.target_entity.walking_state.walking)
        ) then
      -- dont do reposition mode if the target entity is moving (eg a running player), otherwise it looks wierd
      worm.mode = "direct_entity"
    elseif dist > 1.45 * WormStats[worm.size].turn_radius then  -- thresh = sqrt2
      -- if done repositioning, change back to direct mode
      if worm.target_entity and worm.target_entity.valid then
        worm.mode = "direct_entity"
      elseif worm.target_position then
        worm.mode = "direct_position"
      else
        local target_entity = worm.head.surface.find_nearest_enemy{  -- is_military_target only
          position = worm.head.position,
          max_distance = WormStats[worm.size].range,
          force = worm.head.force,  -- finds enemy of this force
        }
        if target_entity then
          Worm.set_target_entity(worm, target_entity)
        else
          Worm.set_stop(worm)
        end
      end
    end
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

function Worm.update_segments(tickdata)
  for _, worm in pairs(global.worms) do
    for _, segment in pairs(worm.segments) do
      -- follow the previous segment
      local ratio = Util.dist(segment.entity.position, segment.before.position) / segment.separation
      ratio = math.max(0.5, math.min(1.5, ratio))  -- prevent explosion
      segment.entity.speed = ratio * worm.head.speed
      segment.entity.orientation = Util.vector_to_orientation(segment.entity.position, segment.before.position)
    end
  end
end
script.on_nth_tick(Worm.SEGMENT_UPDATE_FREQ, Worm.update_segments)

-- Example group: 5 small 5 medium biters: 5/75 small, 10/75 medium worm spawn chance
-- Only one worm per unit group (for now. TODO?)
Worm.WEIGHT_NO_WORM = 60  -- base weight of spawning no worm
Worm.WEIGHT_SMALL_WORM = 1  -- weight of spawning small worm, per small biter/spitter
Worm.WEIGHT_MEDIUM_WORM = 2  -- same for medium/big/behemoth worms
Worm.WEIGHT_BIG_WORM = 2
Worm.WEIGHT_BEHEMOTH_WORM = 3
Worm.GROUP_SEP = 20  -- tiles; distance away from group center to spawn worm, to reduce chance of collisions
---@param event EventData.on_unit_group_finished_gathering
function Worm.create_worm_with_group(event)
  local group = event.group
  local target_position, target_entity, target_radius = nil, nil, 3
  if group.command.type == defines.command.attack then
    target_entity = group.command.target
  elseif group.command.type == defines.command.attack_area then
    target_position = group.command.destination
    target_radius = group.command.radius or 3
  elseif group.command.type == defines.command.go_to_location then
    target_position = group.command.destination
    if group.command.destination_entity and group.command.destination_entity.valid then
      target_entity = group.command.destination_entity
    end
    target_radius = group.command.radius or 3
  end
  if target_entity and target_entity.valid then target_position = target_entity.position end
  if not target_position then return end

  local weights = {0,0,0,0}
  for _, entity in pairs(group.members) do
    if entity.name == "small-biter" or entity.name == "small-spitter" then
      weights[1] = weights[1] + Worm.WEIGHT_SMALL_WORM
    elseif entity.name == "medium-biter" or entity.name == "medium-spitter" then
      weights[2] = weights[2] + Worm.WEIGHT_MEDIUM_WORM
    elseif entity.name == "big-biter" or entity.name == "big-spitter" then
      weights[3] = weights[3] + Worm.WEIGHT_BIG_WORM
    elseif entity.name == "behemoth-biter" or entity.name == "behemoth-spitter" then
      weights[4] = weights[4] + Worm.WEIGHT_BEHEMOTH_WORM
    end
  end
  local total_weight = Worm.WEIGHT_NO_WORM + weights[1] + weights[2] + weights[3] + weights[4]
  local chance = math.random(total_weight)
  local weight = Worm.WEIGHT_NO_WORM
  if chance <= weight then return end
  for i=1,4 do
    weight = weight + weights[i]
    if chance <= weight then
      local size = WormStats.SIZES[i]
      local worm = Worm.create_worm_with_orientation(group.surface, group.force, size, group.position, Util.vector_to_orientation(group.position, target_position))
      if not worm then return end
      if debug_flag then game.print("spawned "..size.." worm at x="..group.position.x..",y="..group.position.y) end
      if target_entity and target_entity.valid then
        Worm.set_target_entity(worm, target_entity)
      else
        Worm.set_target_position(worm, target_position, math.min(target_radius, WormStats[size].range * 0.95))
      end
      return
    end
  end
end
script.on_event(defines.events.on_unit_group_finished_gathering, Worm.create_worm_with_group)

script.on_event(defines.events.on_script_trigger_effect, function(event)
  game.print("id="..event.effect_id)
  if event.source_entity then game.print("source="..event.source_entity.name) end
  if event.target_entity then game.print("target="..event.target_entity.name) end
end)


return Worm

