
-- copied from __base__/prototypes/entity/enemies.lua
small_biter_scale = 0.5
small_biter_tint1 = {r=0.60, g=0.58, b=0.51, a=1}
small_biter_tint2 = {r=0.9 , g=0.83, b=0.54, a=1}

medium_biter_scale = 0.7
medium_biter_tint1 = {r=0.49, g=0.46, b=0.51, a=1}
medium_biter_tint2 = {r=0.93, g=0.72, b=0.72, a=1}

big_biter_scale = 1.0
big_biter_tint1 = {r=0.37, g=0.40, b=0.72, a=1}
big_biter_tint2 = {r=0.55, g=0.76, b=0.75, a=1}

behemoth_biter_scale = 1.2
behemoth_biter_tint1 = {r=0.21, g=0.19, b=0.25, a=1}
behemoth_biter_tint2 = {r = 0.657, g = 0.95, b = 0.432, a = 1.000}

-- copied from __base__/prototypes/entity/spitter-projectiles.lua
range_worm_small    = 25
range_worm_medium   = 30
range_worm_big      = 38
range_worm_behemoth = 48

prepare_range_worm_small    = 8
prepare_range_worm_medium   = 16
prepare_range_worm_big      = 24
prepare_range_worm_behemoth = 36


base_target_speed = 15/60  -- tiles per tick; will accelerate up to this speed, but will not decelerate if above
base_rotation_speed = 0.0035  -- rotations per tick; tank = 0.0035

base_collision_box = {{-1.3, -0.9}, {1.3, 0.9}}
base_selection_box = {{-1.3, -0.9}, {1.3, 0.9}}
base_drawing_box = {{-1.8, -1.8}, {1.8, 1.5}}
local function scale_all(box, scale)
  return {{box[1][1]*scale, box[1][2]*scale}, {box[2][1]*scale, box[2][2]*scale}}
end

-- shared worm stats used by both data.lua and control.lua
local WormStats = {
  SIZES = {"small", "medium", "big", "behemoth"},
  small = {
    max_health = 100,
    scale = small_biter_scale,  -- 0.5
    tint = small_biter_tint2,
    range = range_worm_small + prepare_range_worm_small,
    target_speed = 0.22,  -- biter 0.20
  },
  medium = {
    max_health = 400,
    scale = medium_biter_scale,  -- 0.7
    tint = medium_biter_tint2,
    range = range_worm_medium + prepare_range_worm_medium,
    target_speed = 0.26, -- biter 0.24
  },
  big = {
    max_health = 800,
    scale = big_biter_scale,  -- 1.0
    tint = big_biter_tint2,
    range = range_worm_big + prepare_range_worm_big,
    target_speed = 0.25,  -- biter 0.23
  },
  behemoth = {
    max_health = 3200,
    scale = behemoth_biter_scale,  -- 1.2
    tint = behemoth_biter_tint2,
    range = range_worm_behemoth + prepare_range_worm_behemoth,
    target_speed = 0.32,  -- biter 0.30
  },
}

for _, size in pairs(WormStats.SIZES) do
  local stats = WormStats[size]
  -- stats.target_speed = base_target_speed * math.sqrt(stats.scale)
  stats.rotation_speed = base_rotation_speed  -- rotations per tick
  stats.turn_radius = stats.target_speed / (2 * math.pi * stats.rotation_speed)  -- tiles
  stats.collision_box = scale_all(base_collision_box, stats.scale)
  stats.selection_box = scale_all(base_selection_box, stats.scale)
  stats.drawing_box = scale_all(base_drawing_box, stats.scale)
end

return WormStats
