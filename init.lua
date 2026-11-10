hs.window.animationDuration = 0

local winMode = hs.hotkey.modal.new()
local previousFrames = {} -- stores frame per window ID

function winMode:entered()
  hs.alert.show("⬜ window", { textSize = 14 }, 0.8)
end

hs.hotkey.bind({"cmd", "shift"}, "2", function()
  winMode:enter()
end)

winMode:bind({}, "escape", function() winMode:exit() end)

-- macOS sometimes nudges frames by a pixel, so compare with tolerance
local EPSILON = 2
local function framesMatch(a, b)
  return math.abs(a.x - b.x) <= EPSILON
     and math.abs(a.y - b.y) <= EPSILON
     and math.abs(a.w - b.w) <= EPSILON
     and math.abs(a.h - b.h) <= EPSILON
end

local function layout(unit)
  local win = hs.window.focusedWindow()
  if not win then winMode:exit() return end

  local screen = win:screen()
  local target = screen:fromUnitRect(hs.geometry(unit))

  if framesMatch(win:frame(), target) then
    -- Already snapped here → same position on the next monitor.
    -- Don't overwrite previousFrames: restore should go back to
    -- the original un-snapped frame, not the monitor-1 snap.
    screen = screen:next()
    target = screen:fromUnitRect(hs.geometry(unit))
  else
    previousFrames[win:id()] = win:frame() -- save before moving
  end

  win:setFrame(target)
  winMode:exit()
end

-- 1. Left 1/3:    A
winMode:bind({},        "a", function() layout({0,   0, 1/3, 1}) end)
-- 2. Right 1/3:   D
winMode:bind({},        "d", function() layout({2/3, 0, 1/3, 1}) end)
-- 3. Left half:   Shift+A
winMode:bind({"shift"}, "a", function() layout({0,   0, 0.5, 1}) end)
-- 4. Right half:  Shift+D
winMode:bind({"shift"}, "d", function() layout({0.5, 0, 0.5, 1}) end)
-- 5. Center 1/3:  S
winMode:bind({},        "s", function() layout({1/3, 0, 1/3, 1}) end)
-- 6. Center 2/3:  Shift+S
winMode:bind({"shift"}, "s", function() layout({1/6, 0, 2/3, 1}) end)
-- 7. Full screen: F
winMode:bind({},        "f", function() layout({0,   0, 1,   1}) end)
-- 8. Top half:    W
winMode:bind({}, "w", function() layout({0, 0,   1, 0.5}) end)
-- 9. Bottom half: X
winMode:bind({}, "x", function() layout({0, 0.5, 1, 0.5}) end)

-- 10. Restore:    Space
winMode:bind({}, "space", function()
  local win = hs.window.focusedWindow()
  local prev = win and previousFrames[win:id()]
  if prev then
    win:setFrame(prev)
    previousFrames[win:id()] = nil -- clear after restoring
  else
    hs.alert.show("no previous position", 0.8)
  end
  winMode:exit()
end)

--------------------------------------------------------------------
-- 11. Grid drag-resize: G (Divvy-style, snaps to cells)
--     Overlays every screen: 9x6 landscape, 6x9 portrait/vertical.
--     Drag on whichever screen the window should land on.
--------------------------------------------------------------------
local gridCanvases, gridTap = {}, nil

local function gridCleanup()
  if gridTap then gridTap:stop() gridTap = nil end
  for _, g in ipairs(gridCanvases) do g.canvas:delete() end
  gridCanvases = {}
end

-- build one overlay for a screen; returns its state table
local function buildGrid(screen)
  local f = screen:frame() -- usable area (excludes menu bar / dock)
  local cols, rows = 9, 6
  if f.h > f.w then cols, rows = 6, 9 end -- portrait/vertical screen
  local g = { frame = f, cols = cols, rows = rows,
              cellW = f.w / cols, cellH = f.h / rows }

  local canvas = hs.canvas.new(f):level(hs.canvas.windowLevels.overlay)
  canvas[#canvas + 1] = { -- dim background
    type = "rectangle", action = "fill",
    fillColor = { alpha = 0.30 },
  }
  for c = 1, cols - 1 do
    canvas[#canvas + 1] = {
      type = "segments", action = "stroke", strokeWidth = 1,
      strokeColor = { white = 1, alpha = 0.4 },
      coordinates = { { x = c * g.cellW, y = 0 }, { x = c * g.cellW, y = f.h } },
    }
  end
  for r = 1, rows - 1 do
    canvas[#canvas + 1] = {
      type = "segments", action = "stroke", strokeWidth = 1,
      strokeColor = { white = 1, alpha = 0.4 },
      coordinates = { { x = 0, y = r * g.cellH }, { x = f.w, y = r * g.cellH } },
    }
  end
  g.hoverIdx = #canvas + 1
  canvas[g.hoverIdx] = { -- cell under cursor before dragging
    type = "rectangle", action = "skip",
    fillColor = { white = 1, alpha = 0.15 },
  }
  g.selIdx = #canvas + 1
  canvas[g.selIdx] = { -- dragged selection
    type = "rectangle", action = "skip",
    fillColor = { red = 0.25, green = 0.55, blue = 1, alpha = 0.4 },
    strokeColor = { red = 0.35, green = 0.65, blue = 1, alpha = 0.9 },
    strokeWidth = 2,
  }
  canvas:show()
  g.canvas = canvas
  return g
end

local function showDragGrid()
  local win = hs.window.focusedWindow()
  if not win then return end
  gridCleanup() -- in case an overlay is already up

  for _, screen in ipairs(hs.screen.allScreens()) do
    table.insert(gridCanvases, buildGrid(screen))
  end

  -- grid under an absolute point (nil if outside every screen's frame)
  local function gridAt(loc)
    for _, g in ipairs(gridCanvases) do
      local f = g.frame
      if loc.x >= f.x and loc.x < f.x + f.w
         and loc.y >= f.y and loc.y < f.y + f.h then
        return g
      end
    end
    return nil
  end

  -- absolute mouse location -> cell in grid g (clamped to its screen)
  local function cellAt(g, loc)
    local col = math.max(0, math.min(g.cols - 1, math.floor((loc.x - g.frame.x) / g.cellW)))
    local row = math.max(0, math.min(g.rows - 1, math.floor((loc.y - g.frame.y) / g.cellH)))
    return col, row
  end

  -- canvas-local rect spanning two cells (inclusive)
  local function spanRect(g, c1, r1, c2, r2)
    local minC, maxC = math.min(c1, c2), math.max(c1, c2)
    local minR, maxR = math.min(r1, r2), math.max(r1, r2)
    return { x = minC * g.cellW, y = minR * g.cellH,
             w = (maxC - minC + 1) * g.cellW, h = (maxR - minR + 1) * g.cellH }
  end

  local dragGrid, dragStart = nil, nil
  local types = hs.eventtap.event.types

  gridTap = hs.eventtap.new(
    { types.leftMouseDown, types.leftMouseDragged, types.leftMouseUp,
      types.mouseMoved, types.keyDown },
    function(e)
      local t = e:getType()

      if t == types.keyDown then
        if e:getKeyCode() == 53 then gridCleanup() return true end -- esc
        return false
      end

      local loc = e:location()

      if t == types.mouseMoved then
        if not dragStart then
          local cur = gridAt(loc)
          for _, g in ipairs(gridCanvases) do
            if g == cur then
              local col, row = cellAt(g, loc)
              g.canvas:elementAttribute(g.hoverIdx, "frame", spanRect(g, col, row, col, row))
              g.canvas:elementAttribute(g.hoverIdx, "action", "fill")
            else
              g.canvas:elementAttribute(g.hoverIdx, "action", "skip")
            end
          end
        end
        return false -- don't swallow cursor movement
      end

      if t == types.leftMouseDown then
        local g = gridAt(loc)
        if not g then gridCleanup() return true end -- click outside any grid cancels
        local col, row = cellAt(g, loc)
        dragGrid, dragStart = g, { col = col, row = row }
        g.canvas:elementAttribute(g.hoverIdx, "action", "skip")
        g.canvas:elementAttribute(g.selIdx, "frame", spanRect(g, col, row, col, row))
        g.canvas:elementAttribute(g.selIdx, "action", "strokeAndFill")
        return true -- swallow the click so it doesn't hit apps below
      end

      if t == types.leftMouseDragged and dragStart then
        -- selection stays on the screen where the drag started
        local col, row = cellAt(dragGrid, loc)
        dragGrid.canvas:elementAttribute(dragGrid.selIdx, "frame",
          spanRect(dragGrid, dragStart.col, dragStart.row, col, row))
        return true
      end

      if t == types.leftMouseUp and dragStart then
        local col, row = cellAt(dragGrid, loc)
        local r = spanRect(dragGrid, dragStart.col, dragStart.row, col, row)
        local f = dragGrid.frame
        gridCleanup()
        previousFrames[win:id()] = win:frame() -- so Space restore works
        win:setFrame({ x = f.x + r.x, y = f.y + r.y, w = r.w, h = r.h })
        return true
      end

      return false
    end)
  gridTap:start()

  hs.alert.show("drag to place window · esc to cancel", { textSize = 14 }, 1.2)
end

-- 12. Grid drag:  G
winMode:bind({}, "g", function()
  winMode:exit()
  showDragGrid()
end)
