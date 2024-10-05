Stats (balanced around vanilla):

| Stat           | Small | Medium | Large | Behemoth | Tank | Player |
|----------------|-------|--------|-------|----------|------|--------|
| HP of vanilla worm | 200   | 400    | 750   | 750      | 2000 | 250    |
| Max Impact Dmg |       |        |       |          |      |        |
| Max Walls      |       |        |       |          |      |        |


Worm HP: Small 200, Medium 400, Big 750, Behemoth 750

Wall HP: 350

Give worms 30% impact resistance, ie 1/0.7=1.43x damage multiplier.

Max impact damage before death: Small xx

Explosion damage (no technologies): Grenade 35, Landmine 250, Rocket 200

Explosion damage (x6 tech, ie pre-infinite): Grenade 78.75, Landmine 500, Rocket 560

---

TODO:
- Graphics, of all forms. Not an artist
  - Worm head+segment art. Corpses. Movement particles.
  - Spawn/despawn animations, eg burrowing into the ground
- Balancing. Some basic balancing done (eg health, speed), but not really tested in real scenarios
- Idle worms sitting and/or moving around. Since worms are controlled via script, this seems like it could become inefficient.

Issues:
- To stop worm segments from colliding with each other, the collision mask contains "not-colliding-with-itself". But since segment entitys do not know which worm they belong to (within cpp), different worms will also not collide with each other.
  - However, worms will still collide with other units. This means they sometimes run over their biter/spitter allies and kill each other.
- Chained worm targets are found using find_nearest_enemy, which may be behind the worm, causing it to make loops. But this function is optimized, so I am using it instead of find_entities_filtered + custom target selection.
  - Construction robots are military targets, which means worms sometimes end up chasing robots around.
- Worms are spawned along with on_unit_group_finished_gathering, ie when a usual unit group is dispatched on an attack. This way worms spawn with a known target, minimizing the number of living worms at once (since they are script powered and thus inefficient). And I don't have to deal with evolution, since I can just base the worm size on the size of the units in the group.
  - However, the often end up killing a portion of their allies 

