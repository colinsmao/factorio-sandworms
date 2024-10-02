
-- avoid collision with cliffs, and self
local collision_mask_util = require("__core__/lualib/collision-mask-util")
local collision_mask = collision_mask_util.get_mask(data.raw["cliff"]["cliff"])
table.insert(collision_mask, collision_mask_util.get_first_unused_layer())
data.raw["cliff"]["cliff"].collision_mask = collision_mask

local worm_stats = {
  small = {
    max_health = 100,
    scale = 0.5,
  },
  medium = {
    max_health = 200,
    scale = 0.7,
  },
  big = {
    max_health = 800,
    scale = 1.0,
  },
  behemoth = {
    max_health = 3200,
    scale = 1.2,
  },
}

local function make_head(size, stats)
  local worm_head = table.deepcopy(data.raw["car"]["tank"])
  worm_head.name = size.."-worm-head"
  worm_head.minable = {mining_time = 0.5, result = size.."-worm-head"}
  worm_head.friction = 1e-200  -- minimal friction; tank = 0.002
  worm_head.terrain_friction_modifier = 0.0
  worm_head.rotation_speed = 0.0035  -- tank = 0.0035
  worm_head.energy_source = {type = "void"}
  worm_head.effectivity = 1.0  -- void energy anyways; easier math
  worm_head.max_health = stats.max_health  -- tank = 2000
  worm_head.weight = 20000  -- tank = 20000
  worm_head.energy_per_hit_point = 0.05  -- tank = 0.5
  worm_head.is_military_target = true  -- will be targeted by turrets
  worm_head.resistances =
  {
    {
      type = "fire",
      decrease = 15,
      percent = 60
    },
    {
      type = "physical",
      percent = 160
    },
    {
      type = "impact",
      decrease = 50,
      percent = 80
    },
    {
      type = "explosion",
      percent = -1000
    },
    {
      type = "acid",
      decrease = 0,
      percent = 70
    },
    {
      type = "impact",
      percent = 90
    }
  }
  -- worm_head.damaged_trigger_effect = {
  --   type = "script",
  --   effect_id = "worm-damaged"
  -- }
  -- worm_head.crash_trigger = {
  --   type = "script",
  --   effect_id = "worm-crashed"
  -- }

  worm_head.collision_mask = collision_mask
  for _, anim in pairs(worm_head.animation.layers) do
    anim.scale = stats.scale * (anim.scale or 1)
    anim.hr_version.scale = stats.scale * (anim.hr_version.scale or 1)
  end

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

for size, stats in pairs(worm_stats) do
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
