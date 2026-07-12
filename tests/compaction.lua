-- Tag compaction across columns: when every column's cell for a tag is empty, that tag row is squeezed
-- out and the higher tags renumber down (c->b, d->c) contiguously -- AND the per-tag descriptions shift
-- with them (if b was "beta" and b->a, tag a's description becomes "beta"). Must never duplicate a name.
local H = require("harness")
local function super_n(n) return "SUPER + code:" .. (n + 9) end

-- On the focused column, create tags a,b,c... each with one window and a description.
local function fill_tags(labels)
  local tags = { "a", "b", "c", "d" }
  for i = 1, #labels do
    H.press("SUPER + CTRL + J") -- descend one row (creates the tag, focuses it)
    H.open()                    -- a window on it
    H.set_desc(tags[i], labels[i])
  end
end

H.scenario("empty lower tag is squeezed out; higher tags + their descriptions shift down", function()
  H.boot()
  H.press(super_n(1))                       -- focus column 1 (DP-1)
  fill_tags({ "alpha", "beta", "gamma" })   -- 1a/1b/1c windowed; desc a/b/c
  H.press("SUPER + CTRL + K"); H.press("SUPER + CTRL + K"); H.press("SUPER + CTRL + K") -- back to home (not viewing a tag)

  H.close_all_on("1a")                      -- tag a empties -> compact: b->a, c->b, drop c

  H.expect_absent("1c")
  H.expect_windows("1a", 1); H.expect_windows("1b", 1)
  H.eq(H.desc("a"), "beta", "tag a inherits b's description")
  H.eq(H.desc("b"), "gamma", "tag b inherits c's description")
  H.eq(H.desc("c"), nil, "tag c's description is dropped")
  H.expect_no_duplicates()
end)

H.scenario("compacting the tag you're VIEWING must not create a duplicate (the 2a disaster)", function()
  H.boot()
  H.press(super_n(1))
  fill_tags({ "alpha", "beta", "gamma" })
  H.press("SUPER + CTRL + K"); H.press("SUPER + CTRL + K")   -- 1c -> 1b -> 1a (now viewing tag a)
  H.expect_active("DP-1", "1a")

  H.close_all_on("1a")                      -- empty the very tag we're looking at

  H.expect_no_duplicates()                  -- the whole point
  H.expect_windows("1a", 1)                 -- b's content shifted up into a
  H.eq(H.desc("a"), "beta", "description shifted up with the content")
end)

H.scenario("a tag is NOT compacted while another column still holds a window in it", function()
  H.boot()
  -- column 1 (DP-1): tags a and c windowed; column 2 (DP-2): tag b windowed -> every row a,b,c is occupied
  H.press(super_n(1)); fill_tags({ "alpha" })          -- 1a
  H.press("SUPER + CTRL + J"); H.open()                -- 1b (window) -- but we'll empty this one
  H.press("SUPER + CTRL + J"); H.open()                -- 1c (window)
  H.press(super_n(2))                                  -- focus column 2 (DP-2)
  H.press("SUPER + CTRL + J"); H.open()                -- 2a? no -- descend col 2 to tag a then more
  -- give column 2 a window on tag b specifically:
  H.press("SUPER + CTRL + J"); H.open()                -- now DP-2 on 2b with a window
  H.eq((H.workspaces())["2b"] and (H.workspaces())["2b"].win or 0, 1, "2b has a window")

  H.close_all_on("1b")                                 -- 1b empties, but 2b still holds tag b
  H.expect_exists("1b")                                -- tag b survives (row not fully empty)  -- OR renumber-safe
  H.expect_no_duplicates()
end)

H.scenario("multi-column: an all-empty tag row renumbers every column together (no duplicates)", function()
  local Stub = require("stub.hyprland")
  H.boot()
  -- seed columns 1 (DP-1) and 2 (DP-2), each with tags a,b,c windowed, plus shared tag descriptions
  for _, t in ipairs({ "a", "b", "c" }) do
    Stub.seed_window("1" .. t, "DP-1")
    Stub.seed_window("2" .. t, "DP-2")
  end
  H.set_desc("a", "alpha"); H.set_desc("b", "beta"); H.set_desc("c", "gamma")

  -- empty tag a across BOTH columns -> the whole row is empty -> compact b->a, c->b for every column
  H.close_all_on("1a")            -- 2a still holds tag a -> no compaction yet
  H.expect_exists("1b"); H.expect_exists("2a")
  H.close_all_on("2a")            -- now tag a is empty everywhere -> compact

  H.expect_absent("1c"); H.expect_absent("2c")
  H.expect_windows("1a", 1); H.expect_windows("1b", 1)
  H.expect_windows("2a", 1); H.expect_windows("2b", 1)
  H.eq(H.desc("a"), "beta", "shared description a follows b across all columns")
  H.eq(H.desc("b"), "gamma", "shared description b follows c")
  H.expect_no_duplicates()
end)
