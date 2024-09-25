core_util = require("__core__/lualib/util.lua") -- adds table.deepcopy

script.on_init(function()
  global.worms = global.worms or {}  -- map worm_id: worm
  global.pathfinder_requests = global.pathfinder_requests or {}  -- pathfinder_id: worm_id
end)

script.on_configuration_changed(function()  -- only for testing
  global.worms = global.worms or {}  -- map worm_id: worm
  global.pathfinder_requests = global.pathfinder_requests or {}  -- pathfinder_id: worm_id
end)


local Worm = {}
Worm.WORM_LENGTH = 10  -- target worm length in tiles
Worm.SEGMENT_SEP = 2  -- separation in tiles between segments
Worm.HEAD_UPDATE_FREQ = 10  -- ticks
Worm.SEGMENT_UPDATE_FREQ = 5  -- ticks
Worm.MIN_SPEED = 3/60  -- tiles per tick; will die/burrow if below this speed (otherwise animations break)
Worm.MAX_SPEED = 60/60  -- tiles per tick; otherwise animations break
Worm.TARGET_SPEED = 10/60  -- tiles per tick; will accelerate up to this speed, but will not decelerate if above
Worm.PATHFINDER_COOLDOWN = 1  -- ticks; cooldown between pathfinder requests
Worm.TURN_RADIUS = Worm.TARGET_SPEED / (2 * math.pi * 0.0035)  -- TODO read rotation_speed
if Worm.HEAD_UPDATE_FREQ == Worm.SEGMENT_UPDATE_FREQ then
  error("Cannot register two functions to the same nth tick.")
end


function Worm.on_entity_created(event)
  local entity
  if event.entity and event.entity.valid then
    entity = event.entity
  end
  if event.created_entity and event.created_entity.valid then
    entity = event.created_entity
  end
  if not entity then return end
  if entity.name ~= "worm-head" then return end  -- only head defines the worm

  local worm = {
    id = entity.unit_number,
    head = entity,
    segments = {},  -- queue
    min_segment = 0,  -- for queue
    max_segment = 0,  -- for queue
    prev_tick = 0,  -- previous segment tick
    mode = "idle",  -- mode {"idle", "direct_position", "direct_entity", "path"}, default "idle"
    target = nil,  -- target position or entity for direct mode
    path = nil,  -- array[PathfinderWaypoint] for path mode
    target_path = 1,  -- target waypoint index within path; must be <= #path
  }
  entity.color = {r=0.5, g=0.0, b=0.0}

  local orientation = entity.orientation  -- [0, 1) clockwise, north=0
  local displacement = {x=math.sin(2*math.pi*orientation), y=-math.cos(2*math.pi*orientation)}
  local position = entity.position
  local before = entity
  for i=1,8 do
    local segment = entity.surface.create_entity{
      name = "worm-segment",
      position = {position.x - i * Worm.SEGMENT_SEP * displacement.x, position.y - i * Worm.SEGMENT_SEP * displacement.y},
      force = entity.force
    }
    segment.orientation = orientation  -- not an argument for create_entity
    segment.color = {r=0.0, g=0.5, b=0.0}
    table.insert(worm.segments, {
      entity = segment,
      before = before,
    })
    before = segment
  end

  global.worms[worm.id] = worm

end
-- TODO: add event entity filters
-- clone?
script.on_event(defines.events.on_built_entity, Worm.on_entity_created)
script.on_event(defines.events.on_robot_built_entity, Worm.on_entity_created)
script.on_event(defines.events.script_raised_built, Worm.on_entity_created)
script.on_event(defines.events.script_raised_revive, Worm.on_entity_created)


function Worm.on_entity_removed(event)
  if not event.entity or not event.entity.valid or not event.entity.surface then return end
  if event.entity.name ~= "worm-head" then return end

  local worm_id = event.entity.unit_number
  local worm = global.worms[worm_id]
  if worm == nil then return end

  worm.head.destroy{raise_destroy=false}
  for _, segment in pairs(worm.segments) do
    if segment.entity.valid then segment.entity.destroy{raise_destroy=false} end
  end

  if worm.path_points then
    for _, id in pairs(worm.path_points) do
      rendering.destroy(id)
    end
  end
  if worm.path_segments then
    for _, id in pairs(worm.path_segments) do
      rendering.destroy(id)
    end
  end

  global.worms[worm_id] = nil

end
script.on_event(defines.events.on_entity_died, Worm.on_entity_removed)
script.on_event(defines.events.on_robot_mined_entity, Worm.on_entity_removed)
script.on_event(defines.events.on_player_mined_entity, Worm.on_entity_removed)
script.on_event(defines.events.script_raised_destroy, Worm.on_entity_removed)


local function update_labels(tickdata)
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
script.on_nth_tick(6, update_labels)


script.on_event("left-click", function(event)
  local player = game.get_player(event.player_index)
  if player == nil then return end
  local cursor_stack = player.cursor_stack
  if cursor_stack == nil or not cursor_stack.valid_for_read then return end
  if cursor_stack.name == "iron-plate" then
    game.print(event.cursor_position)
    -- refresh all annotations
    if global.boundary_box then rendering.destroy(global.boundary_box) end
    -- global.boundary_box = rendering.draw_rectangle{
    --   color = {1, 0, 0},
    --   width = 5,
    --   filled = false,
    --   left_top = {0, 0},
    --   right_bottom = {BOUNDING_BOX, BOUNDING_BOX},
    --   surface = player.surface,
    -- }
    update_labels(nil)
  elseif cursor_stack.name == "copper-plate" then
    -- path to click
    for _, worm in pairs(global.worms) do
      Worm.get_path(worm, event.cursor_position, event.tick)
    end
  elseif cursor_stack.name == "steel-plate" then
    -- destroy all worms
    for _, worm in pairs(global.worms) do
      worm.head.destroy{raise_destroy=true}
    end
  elseif cursor_stack.name == "plastic-bar" then
    local ent = player.surface.create_entity{
      name = "worm-head",
      position = event.cursor_position,
      force = "enemy",
      create_build_effect_smoke = false,
      raise_built = true,
    }
    ent.orientation = math.random()
    -- ent.speed = Worm.TARGET_SPEED
  elseif cursor_stack.name == "iron-gear-wheel" then

  end
end)


function Worm.get_path(worm, target_pos, tick)
  global.pathfinder_requests = global.pathfinder_requests or {}  -- pathfinder_id: worm_id
  if worm.pathfinder_tick and tick - worm.pathfinder_tick < Worm.PATHFINDER_COOLDOWN then return end
  worm.pathfinder_id = worm.head.surface.request_path{
    bounding_box = worm.head.bounding_box,
    collision_mask = worm.head.prototype.collision_mask,
    start = worm.head.position,
    goal = target_pos,
    pathfind_flags = {
      allow_destroy_friendly_entities = true,
      cache = false,
      prefer_straight_paths = true,
      low_priority = false
    },
    force = worm.head.force,
    can_open_gates = false,
    radius = 1,
    path_resolution_modifier = -4,  -- resolution = 2^-x
  }
  worm.pathfinder_tick = tick
  global.pathfinder_requests[worm.pathfinder_id] = worm.id
end


function Worm.set_path(event)
  -- asynchronous pathfinder response
  -- game.print(event.id)
  local worm_id = global.pathfinder_requests[event.id]
  global.pathfinder_requests[event.id] = nil
  if event.try_again_later or not event.path then return end
  local worm = global.worms[worm_id]
  if worm == nil then return end
  if event.id ~= worm.pathfinder_id then return end  -- not the latest pathfinder request
  worm.path = event.path
  worm.target_path = 1

  worm.target = worm.path[#worm.path].position
  worm.mode = "path"

  -- debug path rendering

  if not worm.path_direct or not rendering.is_valid(worm.path_direct) then
    worm.path_direct = rendering.draw_line{
      color = {r=0,g=64,b=0,a=0.01},
      width = 3,
      from = worm.head,
      to = worm.target,
      surface = worm.head.surface,
    }
  else
    -- rendering.set_from(worm.path_direct, worm.head)
    rendering.set_to(worm.path_direct, worm.target)
  end

  if worm.path_points then
    for _, id in pairs(worm.path_points) do
      rendering.destroy(id)
    end
  end
  worm.path_points = {}
  if worm.path_segments then
    for _, id in pairs(worm.path_segments) do
      rendering.destroy(id)
    end
  end
  worm.path_segments = {}
  prev_pos = worm.head.position
  for _, pathpoint in pairs(worm.path) do
    table.insert(worm.path_segments, rendering.draw_line{
      color = {r=0,g=64,b=0,a=0.01},
      width = 3,
      from = prev_pos,
      to = pathpoint.position,
      surface = worm.head.surface,
    })
    table.insert(worm.path_points, rendering.draw_circle{
      color = {r=0,g=64,b=0,a=0.01},
      radius = 0.5,
      target = pathpoint.position,
      surface = worm.head.surface,
    })
    prev_pos = pathpoint.position
  end
  rendering.set_color(worm.path_points[worm.target_path], {r=0,g=0,b=64,a=0.01})
  rendering.set_color(worm.path_segments[worm.target_path], {r=0,g=0,b=64,a=0.01})

end
script.on_event(defines.events.on_script_path_request_finished, Worm.set_path)


local Util = {}
function Util.dist2(pos0, pos1)
  --[[ Return the squared distance between two positions ]]--
  return (pos0.x - pos1.x)^2 + (pos0.y - pos1.y)^2
end

function Util.dist(pos0, pos1)
  --[[ Return the distance between two positions ]]--
  return math.sqrt(Util.dist2(pos0, pos1))
end

function Util.vector_to_orientation(vector)
  --[[ Return the orientation of a vector ]]--
  local orientation = math.atan2(vector.y, vector.x)/(2 * math.pi) + 0.25  -- atan2 [-0.5, 0.5) -> [-0.25, 0.75)
  if orientation < 0 then ori = orientation + 1 end  -- [0, 1)
  return orientation
end

function Util.delta_orientation(target, origin)
  --[[ Return the difference of two orientations, in range [-0.5, 0.5) ]]--
  local delta = target - origin  -- (-1, 1)
  if delta < -0.5 then delta = delta + 1 end  -- [-0.5, 1)
  if delta >= 0.5 then delta = delta - 1 end  -- [-0.5, 0.5)
  return delta
end


function Worm.update_head(worm)
  --[[
  Pathing logic for enemy worm heads, which are the only 'smart' part of a worm.
  TODO pathfinding + AI
  ]]--
  -- Worm.wrap_entity(worm.head)  -- testing
  if worm.head.force.name ~= "enemy" then return end  -- TODO?

  -- check valid
  if worm.mode == "direct_entity" then
    if not worm.target or not worm.target.position then
      worm.mode = "idle"
    end
  elseif worm.mode == "direct_position" then
    if not worm.target then
      worm.mode = "idle"
    end
  elseif worm.mode == "path" then
    if not worm.path or #worm.path <= 0 then
      worm.mode = "idle"
    end
  end

  if worm.mode == "direct_entity" or worm.mode == "direct_position" or worm.mode == "path" then
    -- Accelerate up to TARGET_SPEED
    local acceleration = defines.riding.acceleration.nothing
    if worm.head.speed < Worm.TARGET_SPEED then
      acceleration = defines.riding.acceleration.accelerating
    end

    -- Pop completed points. Since it takes time to turn, pop points up to some distance away
    local dist_thresh = worm.head.speed * Worm.HEAD_UPDATE_FREQ  -- + 1/2 a t^2
    -- local theta = math.acos()
    -- local dist_thresh = Worm.TURN_RADIUS / math.tan(theta/2)
    while worm.target_path < #worm.path do
      if Util.dist(worm.head.position, worm.path[worm.target_path].position) < dist_thresh then
        rendering.set_color(worm.path_points[worm.target_path], {r=0,g=0,b=64,a=0.01})
        rendering.set_color(worm.path_segments[worm.target_path], {r=0,g=0,b=64,a=0.01})
        rendering.set_color(worm.path_points[worm.target_path + 1], {r=64,g=0,b=0,a=0.01})
        rendering.set_color(worm.path_segments[worm.target_path + 1], {r=64,g=0,b=0,a=0.01})
        worm.target_path = worm.target_path + 1
      else
        break
      end
    end

    local direction = defines.riding.direction.straight
    local disp = {
      x = worm.path[worm.target_path].position.x - worm.head.position.x,
      y = worm.path[worm.target_path].position.y - worm.head.position.y
    }
    local delta = Util.delta_orientation(Util.vector_to_orientation(disp), worm.head.orientation)
    if math.abs(delta) >= 0.5 * worm.head.prototype.rotation_speed * Worm.HEAD_UPDATE_FREQ then
      if delta < 0 then
        direction = defines.riding.direction.left
      else
        direction = defines.riding.direction.right
      end
    end
    worm.head.riding_state = {acceleration=acceleration, direction=direction}
  else  -- worm.mode == "idle" or anything else
    worm.head.riding_state = {acceleration=defines.riding.acceleration.nothing, direction=defines.riding.direction.straight}
  end

end


function Worm.update_segment(segment)
  -- Worm.wrap_entity(segment.entity)  -- testing
  local disp = {
    x = segment.before.position.x - segment.entity.position.x,
    y = segment.before.position.y - segment.entity.position.y
   }
  local clipped_ratio = math.max(0.1, math.min(2, math.sqrt(disp.x^2 + disp.y^2) / Worm.SEGMENT_SEP))  -- prevent explosion
  segment.entity.speed = clipped_ratio * segment.before.speed
  segment.entity.orientation = Util.vector_to_orientation(disp)
end


function Worm.update_segments(tickdata)
  -- if tickdata.tick % Worm.HEAD_UPDATE_FREQ == 0 then
  --   game.print("segment"..tickdata.tick)
  -- end
  for _, worm in pairs(global.worms) do
    for i=1,#worm.segments do
      Worm.update_segment(worm.segments[#worm.segments+1-i])  -- update in reverse
    end
  end
end
script.on_nth_tick(Worm.SEGMENT_UPDATE_FREQ, Worm.update_segments)


function Worm.update_heads(tickdata)
  -- game.print("head"..tickdata.tick)
  for _, worm in pairs(global.worms) do
    Worm.update_head(worm)
  end
end
script.on_nth_tick(Worm.HEAD_UPDATE_FREQ, Worm.update_heads)



return Worm

