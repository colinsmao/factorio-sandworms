
local dir_to_disp = {
  [defines.direction.north] = {x=0, y=1},
  [defines.direction.northeast] = {x=0.70710678, y=0.70710678},
  [defines.direction.east] = {x=1, y=0},
  [defines.direction.southeast] = {x=0.70710678, y=-0.70710678},
  [defines.direction.south] = {x=0, y=-1},
  [defines.direction.southwest] = {x=-0.70710678, y=-0.70710678},
  [defines.direction.west] = {x=-1, y=0},
  [defines.direction.northwest] = {x=0.70710678, y=-0.70710678},
}

function Worm.on_entity_created(event)
  local head_entity
  if event.entity and event.entity.valid then
    head_entity = event.entity
  end
  if event.created_entity and event.created_entity.valid then
    head_entity = event.created_entity
  end
  if not head_entity then return end
  if head_entity.name ~= "worm-head" then return end  -- only head defines the worm

  local head = {
    worm = nil,  -- fill later
    entity = head_entity,
    previous_segment = nil,
    next_segment = nil,
    curr_state = {acceleration=defines.riding.acceleration.nothing, direction=defines.riding.direction.straight},
    prev_state = {acceleration=defines.riding.acceleration.nothing, direction=defines.riding.direction.straight},
  }
  local worm = {
    id = head_entity.unit_number,
    head = head,
    segments = {}
  }
  head.worm = worm
  global.segment_to_worm[head_entity.unit_number] = worm.id
  head_entity.color = {r=0.5, g=0.0, b=0.0}
  -- head_entity.speed = Worm.WORM_SIZE / Worm.UPDATE_FREQ

  local orientation = head_entity.orientation  -- [0, 1) clockwise, north=0
  local displacement = {x=math.sin(2*math.pi*orientation), y=-math.cos(2*math.pi*orientation)}  -- ??
  local position = head_entity.position
  local previous_segment = head
  for i=1,8 do
    local segment_entity = head_entity.surface.create_entity{
      name = "worm-segment",
      position = {position.x - i * Worm.WORM_SIZE * displacement.x, position.y - i * Worm.WORM_SIZE * displacement.y},
      force = head_entity.force
    }
    segment_entity.orientation = orientation  -- not an argument for create_entity
    segment_entity.color = {r=0.0, g=0.5, b=0.0}
    -- segment_entity.speed = Worm.WORM_SIZE / Worm.UPDATE_FREQ
    local segment = {
      worm = worm,
      entity = segment_entity,
      previous_segment = previous_segment,
      next_segment = nil,
      curr_state = {acceleration=defines.riding.acceleration.nothing, direction=defines.riding.direction.straight},
      prev_state = {acceleration=defines.riding.acceleration.nothing, direction=defines.riding.direction.straight},
    }
    previous_segment.next_segment = segment
    previous_segment = segment  -- for the next loop
    table.insert(worm.segments, segment)
    global.segment_to_worm[segment_entity.unit_number] = worm.id
  end

  global.worms[worm.id] = worm

end
-- TODO: add event entity filters
-- clone?
script.on_event(defines.events.on_built_entity, Worm.on_entity_created)
script.on_event(defines.events.on_robot_built_entity, Worm.on_entity_created)
script.on_event(defines.events.script_raised_built, Worm.on_entity_created)
script.on_event(defines.events.script_raised_revive, Worm.on_entity_created)


function Worm.on_removed_entity(event)
  if not event.entity or not event.entity.valid or not event.entity.surface then return end
  if event.entity.name ~= "worm-head" and event.entity.name ~= "worm-segment" then return end

  local worm_id = global.segment_to_worm[event.entity.unit_number]
  if worm_id == nil then return end
  local worm = global.worms[worm_id]
  if worm == nil then return end

  global.segment_to_worm[worm.head.entity.unit_number] = nil
  worm.head.entity.destroy{raise_destroy=false}
  for _, segment in pairs(worm.segments) do
    global.segment_to_worm[segment.entity.unit_number] = nil
    segment.entity.destroy{raise_destroy=false}
  end
  global.worms[worm_id] = nil

end
script.on_event(defines.events.on_entity_died, Worm.on_removed_entity)
script.on_event(defines.events.on_robot_mined_entity, Worm.on_removed_entity)
script.on_event(defines.events.on_player_mined_entity, Worm.on_removed_entity)
script.on_event(defines.events.script_raised_destroy, Worm.on_removed_entity)


local BOUNDING_BOX = 100
function Worm.wrap_entity(entity)
  -- wrapping for testing
  if entity.position.x < 0 then
    entity.teleport(BOUNDING_BOX, 0)
  elseif entity.position.x >= BOUNDING_BOX then
    entity.teleport(-BOUNDING_BOX, 0)
  end
  if entity.position.y < 0 then
    entity.teleport(0, BOUNDING_BOX)
  elseif entity.position.y >= BOUNDING_BOX then
    entity.teleport(0, -BOUNDING_BOX)
  end
end


function Worm.update_segment(segment, tick)
  --[[
  Pathing logic for worm segments. Follow the previous segment.
    Just driving towards the previous segment does not work, since the separation between segments becomes dependent on 
    speed. Eg a stopped worm would collapse to a single point.
    Instead, aim to maintain a speed and direction that keeps the desired separation with the previous segment.
  ]]--
  if segment.previous_segment == nil or segment.previous_segment.entity == nil or not segment.previous_segment.entity.valid then
    game.print("Error worm segment has an invalid previous segment")
    return
  end
  segment.curr_state = segment.curr_state or {acceleration=defines.riding.acceleration.nothing, direction=defines.riding.direction.straight}

  if tick % Worm.UPDATE_FREQ ~= 0 then  -- reduce full updates
    segment.entity.riding_state = segment.curr_state
    return
  end

  --[[
  Turning direction
    Try to align the current segment's orientation with the displacement vector to the previous segment.
  ]]--

  local pos0 = segment.previous_segment.entity.position
  local pos1 = segment.entity.position
  local disp_x = pos0.x - pos1.x
  local disp_y = pos0.y - pos1.y
  local target_orientation = math.atan2(disp_y, disp_x)/(2 * math.pi) + 0.25  -- atan2 [-0.5, 0.5] -> [-0.25, 0.75]
  if target_orientation < 0 then target_orientation = target_orientation + 1 end  -- [0, 1]
  local delta_orientation = target_orientation - segment.entity.orientation  -- [-1, 1]
  if delta_orientation < -0.5 then delta_orientation = delta_orientation + 1 end  -- [-0.5, 1]
  if delta_orientation > 0.5 then delta_orientation = delta_orientation - 1 end  -- [-0.5, 0.5]
  if math.abs(delta_orientation) > 0.25 then  -- the segment is moving away from its previous segment
    game.print("Error, worm segment moving away from previous segment")
    segment.entity.riding_state = {acceleration=defines.riding.acceleration.braking, direction=defines.riding.direction.straight}
    -- segment.entity.destroy{raise_destroy=true}  -- raise script, will destroy the whole worm
    return
  end

  target_dir = defines.riding.direction.straight
  if math.abs(delta_orientation) >= 0.5 * game.entity_prototypes["worm-segment"].rotation_speed * Worm.UPDATE_FREQ then
    -- use riding.direction to smoothly correct large errors
    if delta_orientation < 0 then
      target_dir = defines.riding.direction.left
    else
      target_dir = defines.riding.direction.right
    end
  else
    segment.entity.orientation = target_orientation  -- directly correct small errors
  end

  --[[
  Acceleration - basic suvat, assume colinear
    1. Try to maintain the separation distance to the previous segment
    2. Try to match the acceleration and speed of the previous segment
  ]]--

  -- totalPower * fuelAccelerationMultiplier * (1.0 + movementBonus) / totalWeight / 1000.0 / 60.0; // because we want J/tick not J/s
  -- game.entity_prototypes["worm-segment"].weight/consumption/braking_power

  -- final_displacement = current_displacement + δs where δs = δu t + 1/2 δa t^2
  -- both us and the previous segment's a are known and fixed. Thus, the only unknown is the current segment's a
  -- final_displacement = s' - 1/2 a t^2 where s' = current_displacement + (u_prev - u_cur) t + 1/2 a_prev t^2
  -- we want final_disp to be as close to Worm.WORM_SIZE as possible, ie minimize abs(final_disp - Worm.WORM_SIZE)
  -- minimize delta: current_displacement + (u_prev - u_cur) t + 1/2 a_prev t^2 - Worm.WORM_SIZE - 1/2 a t^2
  -- if the delta is positive, either coast or brake. if the delta is negative, either coast or accelerate.
  -- Note: (1/2 a t^2) is actually a fixed value, ignoring friction

  -- TODO: fix hardcode power
  local accel_val = 0.5 * 600 * 1000 / game.entity_prototypes["worm-segment"].weight / 60 * Worm.UPDATE_FREQ * Worm.UPDATE_FREQ
  local brake_val = 0.5 * 800 * 1000 / game.entity_prototypes["worm-segment"].weight / 60 * Worm.UPDATE_FREQ * Worm.UPDATE_FREQ

  local dist = math.sqrt(disp_x^2 + disp_y^2)
  local delta = dist + (segment.previous_segment.entity.speed - segment.entity.speed) * Worm.UPDATE_FREQ - Worm.WORM_SIZE
  if segment.previous_segment.entity.riding_state.acceleration == defines.riding.acceleration.accelerating then
    delta = delta + accel_val
  elseif segment.previous_segment.entity.riding_state.acceleration == defines.riding.acceleration.braking then
    delta = delta - brake_val
  end

  target_acc = defines.riding.acceleration.nothing
  if delta > 0.5 * accel_val then
    target_acc = defines.riding.acceleration.accelerating
  elseif delta < 0.5 * brake_val then
    target_acc = defines.riding.acceleration.braking
  else
    -- segment.entity.speed = segment.previous_segment.entity.speed  -- directly correct small errors
  end
  segment.curr_state = {acceleration=target_acc, direction=target_dir}
  segment.entity.riding_state = {acceleration=target_acc, direction=target_dir}
end


function Worm.create_segment(worm, tick)
  -- TODO: use animation instead of entity
  -- TODO: fix animation layer (eg with cliffs)
  -- TODO: add fire / impact damage
  -- TODO: add movement dirt animation
  if worm.head.speed < Worm.MIN_SPEED then return end
  local segment_entity = worm.head.surface.create_entity{
    name = "worm-segment",
    position = worm.head.position,
    force = worm.head.force,
    create_build_effect_smoke = false,
  }
  segment_entity.orientation = worm.head.orientation  -- not an argument for create_entity
  segment_entity.color = {r=0.0, g=0.5, b=0.0}
  -- segment_entity.speed = 0.01
  local segment = {
    entity = segment_entity,
    final_tick = tick + Worm.WORM_LENGTH / math.max(worm.head.speed, Worm.MIN_SPEED)
  }
  global.segment_to_worm[segment_entity.unit_number] = worm.id  -- register
  -- add segment to queue
  worm.segments[worm.max_segment] = segment
  worm.max_segment = worm.max_segment + 1
end


function Worm.pop_segment(worm, tick)
  local pop = true
  while pop do
    local segment = worm.segments[worm.min_segment]
    if not segment then return end
    if segment.final_tick < tick then
      global.segment_to_worm[segment.entity.unit_number] = nil
      segment.entity.destroy{raise_destroy=false}
      worm.min_segment = worm.min_segment + 1
    else
      pop = false
    end
  end
end


function Worm.update_segment(segment)
  -- Worm.wrap_entity(segment.entity)  -- testing
  local dist = Util.dist(segment.before.position, segment.entity.position)
  local clipped_ratio = math.max(0.1, math.min(2, dist / Worm.SEGMENT_SEP))  -- prevent explosion
  local disp = {
   x = segment.before.position.x - segment.entity.position.x,
   y = segment.before.position.y - segment.entity.position.y
  }
  local vel2x = disp.x / dist * clipped_ratio * segment.before.speed
  local vel2y = disp.y / dist * clipped_ratio * segment.before.speed

  local vel1x = segment.entity.speed * math.sin(2*math.pi*segment.entity.orientation)
  local vel1y = segment.entity.speed * -math.cos(2*math.pi*segment.entity.orientation)

  local vel = {
    x = (vel1x + vel2x) / 2,
    y = (vel1y + vel2y) / 2
  }
  local speed = math.min(math.sqrt(vel.x^2 + vel.y^2), Worm.MAX_SPEED)
  segment.entity.speed = speed
  if speed > 0.002 then  -- draw stopped segments correctly
    segment.entity.orientation = Util.vector_to_orientation(vel)
  else
    segment.entity.orientation = Util.vector_to_orientation(disp)
  end
end


local ent_filter = Worm.size_map(function(size) return {size.."-worm-head"} end)  -- , size.."-worm-segment"
--- debug update labels
function Worm.update_labels(tickdata)
  global.labels = global.labels or {}
  for _, label in pairs(global.labels) do
    rendering.destroy(label)
  end
  global.labels = {}
  local player = game.get_player(1)
  if not player then return end
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

