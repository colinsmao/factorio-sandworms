
local hit_effects = require("__base__/prototypes/entity/hit-effects.lua")
local sounds = require("__base__/prototypes/entity/sounds.lua")
local movement_triggers = require("__base__/prototypes/entity/movement-triggers.lua")

-- avoid collision with cliffs, and self
local collision_mask_util = require("__core__/lualib/collision-mask-util")
local collision_mask = collision_mask_util.get_mask(data.raw["cliff"]["cliff"])
table.insert(collision_mask, collision_mask_util.get_first_unused_layer())
data.raw["cliff"]["cliff"].collision_mask = collision_mask

local WormStats = require("worm-stats")
base_collision_box = {{-0.9, -1.3}, {0.9, 1.3}}
base_selection_box = {{-0.9, -1.3}, {0.9, 1.3}}
base_drawing_box = {{-1.8, -1.8}, {1.8, 1.5}}


local function make_head(size, stats)
  local worm_head = {
    type = "car",
    name = size.."-worm-head",
    icon = "__base__/graphics/icons/"..size.."-worm.png",  -- use vanilla worm icon for now, TODO
    icon_size = 64, icon_mipmaps = 4,
    flags = {"placeable-player", "placeable-enemy", "placeable-off-grid", "not-repairable", "breaths-air"},
    immune_to_tree_impacts = true,
    immune_to_rock_impacts = true,
    inventory_size = 0,

    -- inherited from "tank"
    minable = {mining_time = 0.5, result = size.."-worm-head"},
    mined_sound = sounds.deconstruct_large(0.8),
    corpse = "tank-remnants",
    dying_explosion = "tank-explosion",
    alert_icon_shift = util.by_pixel(0, -13),
    damaged_trigger_effect = hit_effects.entity(),
    vehicle_impact_sound = sounds.generic_impact,
    track_particle_triggers = movement_triggers.tank,

    friction = 1e-200,  -- minimal friction; tank = 0.002
    terrain_friction_modifier = 0.0,
    energy_source = {type = "void"},
    effectivity = 1.0,  -- void energy anyways; easier math
    braking_power = (800*stats.scale).."kW",  -- tank = 800kW
    consumption = (600*stats.scale).."kW",  -- tank = 600kW

    max_health = stats.max_health,  -- tank = 2000
    rotation_speed = stats.rotation_speed,  -- tank = 0.0035
    weight = 20000 * stats.scale^3,  -- tank = 20000
    energy_per_hit_point = 0.05,  -- tank = 0.5
    tank_driving = true,

    is_military_target = true,  -- will be targeted by turrets
    resistances =
    {
      {
        type = "impact",
        percent = 75
      },
      {
        type = "explosion",
        percent = -200
      },
      {
        type = "acid",
        percent = 90
      },
      {
        type = "poison",
        percent = 90
      },
      {
        type = "fire",
        percent = 90
      },
      {
        type = "physical",
        percent = 90
      },
      {
        type = "laser",
        percent = 90
      },
      {
        type = "electric",
        percent = 90
      },
    },
    -- damaged_trigger_effect = {
    --   type = "script",
    --   effect_id = "worm-damaged"
    -- }
    -- crash_trigger = {
    --   type = "script",
    --   effect_id = "worm-crashed"
    -- }

    collision_mask = collision_mask,
    collision_box = base_collision_box,
    selection_box = base_selection_box,
    drawing_box = base_drawing_box,
    animation =
    {
      priority = "low",
      width = 110,
      height = 100,
      frame_count = 1,
      direction_count = 64,
      scale = stats.scale,
      tint = stats.tint,
      stripes =
      {
        {
          filename = "__sandworms__/graphics/worm-base-1.png",
          width_in_frames = 1,
          height_in_frames = 16
        },
        {
          filename = "__sandworms__/graphics/worm-base-2.png",
          width_in_frames = 1,
          height_in_frames = 16
        },
        {  -- front/back symmetrical
          filename = "__sandworms__/graphics/worm-base-1.png",
          width_in_frames = 1,
          height_in_frames = 16
        },
        {
          filename = "__sandworms__/graphics/worm-base-2.png",
          width_in_frames = 1,
          height_in_frames = 16
        },
      }
    },
  }

  return worm_head
end

local function make_segment(size, worm_head)
  local worm_segment = table.deepcopy(worm_head)
  worm_segment.name = size.."-worm-segment"
  worm_segment.is_military_target = false
  return worm_segment
end

local function make_item_recipe(size)
  local worm_head_item =
  {
    type = "item",
    name = size.."-worm-head",
    icon = "__base__/graphics/icons/tank.png",
    icon_size = 64, icon_mipmaps = 4,
    subgroup = "enemies",
    order = "b",
    place_result = size.."-worm-head",
    stack_size = 1
  }

  local worm_head_recipe =
  {
    type = "recipe",
    name = size.."-worm-head",
    normal =
    {
      enabled = true,
      energy_required = 1,
      ingredients = {},
      result = size.."-worm-head"
    }
  }

  return {worm_head_item, worm_head_recipe}
end

for size, stats in pairs(WormStats) do
  local head_prototype = make_head(size, stats)
  local segment_prototype = make_segment(size, head_prototype)
  data:extend({head_prototype, segment_prototype})
  data:extend(make_item_recipe(size))
end

data:extend({
  {
    type = "custom-input",
    name = "left-click",
    key_sequence = "mouse-button-1",
  },
  {
    type = "custom-input",
    name = "right-click",
    key_sequence = "mouse-button-2",
  }
})
