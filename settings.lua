data:extend({
  {
    type = "bool-setting",
    name = "detonation-debug-mode",
    setting_type = "runtime-global",
    default_value = false,
    order = "a"
  },
  {
    type = "int-setting",
    name = "detonation-max-explosions",
    setting_type = "runtime-global",
    default_value = 100000,
    minimum_value = 10,
    maximum_value = 100000,
    order = "b"
  },
  {
    type = "double-setting",
    name = "detonation-average-speed",
    setting_type = "runtime-global",
    default_value = 0.1,
    minimum_value = 0.05,
    maximum_value = 2.0,
    order = "c"
  },
  {
    type = "bool-setting",
    name = "detonation-directional-blasts",
    setting_type = "runtime-global",
    default_value = false,
    order = "d"
  },
  {
    type = "int-setting",
    name = "detonation-staggered-detonations",
    setting_type = "runtime-global",
    default_value = 0,
    minimum_value = 0,
    maximum_value = 3600,
    order = "e"
  },
  {
    type = "int-setting",
    name = "detonation-initial-detonation-delay",
    setting_type = "runtime-global",
    default_value = 0,
    minimum_value = 0,
    maximum_value = 3600,
    order = "f"
  },
  {
    type = "bool-setting",
    name = "detonation-controlled-chest-detonation",
    setting_type = "startup",
    default_value = true,
    order = "g"
  },
})
