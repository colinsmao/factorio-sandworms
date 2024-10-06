
local hit_effects = require("__base__/prototypes/entity/hit-effects.lua")
local sounds = require("__base__/prototypes/entity/sounds.lua")
local movement_triggers = require("__base__/prototypes/entity/movement-triggers.lua")
local collision_mask_util = require("__core__/lualib/collision-mask-util")

local WormStats = require("worm-stats")

local function make_head(size, stats)
  local worm_head = {
    type = "car",
    name = size.."-worm-head",
    icon = "__base__/graphics/icons/"..size.."-worm.png",  -- use vanilla worm icon for now, TODO
    icon_size = 64, icon_mipmaps = 4,
    flags = {"placeable-player", "placeable-enemy", "placeable-off-grid", "not-repairable", "breaths-air"},
    subgroup="enemies",

    -- inherited from "tank"
    minable = {mining_time = 0.5, result = size.."-worm-head"},
    mined_sound = sounds.deconstruct_large(0.8),
    -- corpse = "tank-remnants",
    -- dying_explosion = "tank-explosion",
    alert_icon_shift = util.by_pixel(0, -13),
    -- damaged_trigger_effect = hit_effects.entity(),
    vehicle_impact_sound = sounds.generic_impact,
    track_particle_triggers = movement_triggers.tank,
    tank_driving = true,
    immune_to_tree_impacts = true,
    immune_to_rock_impacts = true,

    -- inherited from vanilla worms
    damaged_trigger_effect = hit_effects.biter(),
    corpse = size.."-worm-corpse",
    dying_explosion = size.."-worm-die",
    dying_sound = data.raw["turret"][size.."-worm-turret"].dying_sound,

    -- vehicle stats
    inventory_size = 0,
    friction = 1e-200,  -- minimal friction; tank = 0.002
    terrain_friction_modifier = 0.0,
    energy_source = {type = "void"},
    effectivity = 1.0,  -- void energy anyways; easier math
    braking_power = (1200*stats.scale).."kW",  -- tank = 800kW
    consumption = (600*stats.scale).."kW",  -- tank = 600kW

    max_health = stats.max_health,  -- tank = 2000
    healing_per_tick = stats.max_health / (30*60),  -- 30 seconds to heal to full
    rotation_speed = stats.rotation_speed,  -- tank = 0.0035
    weight = 20000 * stats.scale,  -- tank = 20000
    energy_per_hit_point = 0.05,  -- tank = 0.5

    is_military_target = true,  -- will be targeted by turrets
    resistances =
    {
      {
        type = "impact",
        percent = 90
      },
      {
        type = "explosion",
        percent = -100
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
    -- },
    -- crash_trigger = {
    --   type = "script",
    --   effect_id = "worm-crashed"
    -- },

    collision_mask = collision_mask_util.get_default_mask("unit"),
    collision_box = stats.collision_box,
    selection_box = stats.selection_box,
    drawing_box = stats.drawing_box,
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
  worm_segment.corpse = nil
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

for _, size in pairs(WormStats.SIZES) do
  local head_prototype = make_head(size, WormStats[size])
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
