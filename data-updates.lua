local collision_mask_util = require("__core__/lualib/collision-mask-util")

worm_head = table.deepcopy(data.raw["car"]["tank"])
worm_head.name = "worm-head"
worm_head.minable = {mining_time = 0.5, result = "worm-head"}
worm_head.friction = 1e-200  -- minimal friction; tank = 0.002
worm_head.terrain_friction_modifier = 0.0
worm_head.rotation_speed = 0.0035  -- tank = 0.0035
worm_head.energy_source = {type = "void"}
worm_head.effectivity = 1.0  -- void energy anyways; easier math
worm_head.max_health = 200  -- tank = 2000
worm_head.weight = 20000  -- tank = 20000
worm_head.energy_per_hit_point = 0.05  -- tank = 0.5
-- avoid collision with cliffs, and self
local collision_mask = collision_mask_util.get_mask(data.raw["cliff"]["cliff"])
table.insert(collision_mask, collision_mask_util.get_first_unused_layer())
data.raw["cliff"]["cliff"].collision_mask = collision_mask
worm_head.collision_mask = collision_mask
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

worm_segment = table.deepcopy(worm_head)
worm_segment.name = "worm-segment"
worm_segment.is_military_target = false

worm_head_item = table.deepcopy(data.raw["item-with-entity-data"]["tank"])
worm_head_item.name = "worm-head"
worm_head_item.place_result = "worm-head"

worm_head_recipe = table.deepcopy(data.raw["recipe"]["tank"])
worm_head_recipe.name = "worm-head"
worm_head_recipe.normal.result = "worm-head"
worm_head_recipe.expensive.result = "worm-head"

data:extend({worm_head, worm_segment, worm_head_item, worm_head_recipe})

