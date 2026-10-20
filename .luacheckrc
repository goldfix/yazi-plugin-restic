-- luacheck configuration: Yazi runtime globals + busted globals for specs.
std = "lua54"
max_line_length = 120
globals = { "ya", "ps", "ui", "fs", "cx", "rt", "th", "km", "Command", "Url", "Err", "Cha", "File" }

files["spec"] = { std = "+busted", ignore = { "212/self" } }
files["tests"] = { std = "+busted" }
files["restic.yazi/main.lua"] = { ignore = { "212/self" } }
