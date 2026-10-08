-- Snake: the playfield.
--
-- Game logic runs on a grid, one step at a time. Rendering interpolates
-- between the previous step and the current one, so the snake glides
-- instead of jumping cell to cell.
--
-- This script never draws snake or food art itself. It draws the Head, Body
-- and Food artboards (art/snake-art.rml) handed in as inputs, so swapping the
-- art never means touching this file. Each art artboard is 100x100, centred
-- on (50, 50), and is scaled to one grid cell. Head faces right.
--
-- The HUD and the start / game-over cards are markup; this script only writes
-- the Game view model they read: score, best, showStart, showGameOver.

type Cell = { x: number, y: number }
type Spark = { x: number, y: number, vx: number, vy: number, life: number, size: number }

type Game = {
    -- inputs (set in scene.rml)
    head: Input<Artboard>,
    body: Input<Artboard>,
    food: Input<Artboard>,
    gridSize: Input<number>,
    startStepTime: Input<number>,
    fastestStepTime: Input<number>,
    speedUpPerFood: Input<number>,

    -- art instances
    headArt: Artboard?,
    bodyArt: Artboard?,
    foodArt: Artboard?,

    -- view model handles
    score: Property<number>?,
    best: Property<number>?,
    showStart: Property<boolean>?,
    showGameOver: Property<boolean>?,

    -- board
    size: Vector,
    cols: number,
    cell: number,
    ox: number,
    oy: number,
    builtFor: number,

    -- game state
    ready: boolean,
    state: string, -- 'ready' | 'playing' | 'over'
    snake: { Cell },
    prev: { Cell },
    dir: Cell,
    queue: { Cell },
    foodCell: Cell,
    stepTime: number,
    acc: number,
    points: number,
    bestPoints: number,

    -- animation state
    time: number,
    foodAge: number,
    eatAge: number,
    deathAge: number,
    headAngle: number,
    sparks: { Spark },

    -- drawing resources
    boardPath: Path,
    tilePath: Path,
    dot: Path,
    boardPaint: Paint,
    tilePaint: Paint,
    glowPaint: Paint,
    sparkPaint: Paint,
}

local ART = 100 -- art artboards are 100x100
local KAPPA = 0.5522847

local KEY_RIGHT, KEY_LEFT, KEY_DOWN, KEY_UP = 262, 263, 264, 265
local KEY_W, KEY_A, KEY_S, KEY_D = 87, 65, 83, 68
local KEY_SPACE, KEY_ENTER, KEY_KP_ENTER = 32, 257, 335

-- ---------------------------------------------------------------- helpers

local function lerp(a: number, b: number, t: number): number
    return a + (b - a) * t
end

local function clamp(v: number, lo: number, hi: number): number
    return math.max(lo, math.min(hi, v))
end

local function easeOutBack(t: number): number
    local c1 = 1.70158
    local c3 = c1 + 1
    local u = t - 1
    return 1 + c3 * u * u * u + c1 * u * u
end

local function copyCells(cells: { Cell }): { Cell }
    local out: { Cell } = {}
    for i, c in cells do
        out[i] = { x = c.x, y = c.y }
    end
    return out
end

local function addCircle(path: Path, cx: number, cy: number, r: number)
    local k = r * KAPPA
    path:moveTo(Vector.xy(cx + r, cy))
    path:cubicTo(Vector.xy(cx + r, cy + k), Vector.xy(cx + k, cy + r), Vector.xy(cx, cy + r))
    path:cubicTo(Vector.xy(cx - k, cy + r), Vector.xy(cx - r, cy + k), Vector.xy(cx - r, cy))
    path:cubicTo(Vector.xy(cx - r, cy - k), Vector.xy(cx - k, cy - r), Vector.xy(cx, cy - r))
    path:cubicTo(Vector.xy(cx + k, cy - r), Vector.xy(cx + r, cy - k), Vector.xy(cx + r, cy))
    path:close()
end

local function addRoundRect(path: Path, x: number, y: number, w: number, h: number, r: number)
    local k = r * (1 - KAPPA)
    path:moveTo(Vector.xy(x + r, y))
    path:lineTo(Vector.xy(x + w - r, y))
    path:cubicTo(Vector.xy(x + w - k, y), Vector.xy(x + w, y + k), Vector.xy(x + w, y + r))
    path:lineTo(Vector.xy(x + w, y + h - r))
    path:cubicTo(Vector.xy(x + w, y + h - k), Vector.xy(x + w - k, y + h), Vector.xy(x + w - r, y + h))
    path:lineTo(Vector.xy(x + r, y + h))
    path:cubicTo(Vector.xy(x + k, y + h), Vector.xy(x, y + h - k), Vector.xy(x, y + h - r))
    path:lineTo(Vector.xy(x, y + r))
    path:cubicTo(Vector.xy(x, y + k), Vector.xy(x + k, y), Vector.xy(x + r, y))
    path:close()
end

-- Shortest signed difference between two angles.
local function angleDelta(from: number, to: number): number
    local d = (to - from) % (2 * math.pi)
    if d > math.pi then
        d -= 2 * math.pi
    end
    return d
end

-- Draw one art artboard centred on (x, y), rotated, at `scale` cells.
local function drawArt(self: Game, renderer: Renderer, art: Artboard?, x: number, y: number, angle: number, scale: number)
    if art == nil then
        return
    end
    local s = self.cell / ART * scale
    renderer:save()
    renderer:transform(Mat2D.withTranslation(x, y))
    if angle ~= 0 then
        renderer:transform(Mat2D.withRotation(angle))
    end
    renderer:transform(Mat2D.withScale(s, s))
    renderer:transform(Mat2D.withTranslation(-ART / 2, -ART / 2))
    art:draw(renderer)
    renderer:restore()
end

-- Grid cell -> pixel centre.
local function px(self: Game, gx: number): number
    return self.ox + (gx + 0.5) * self.cell
end
local function py(self: Game, gy: number): number
    return self.oy + (gy + 0.5) * self.cell
end

-- ---------------------------------------------------------------- view model

local function publish(self: Game)
    local score = self.score
    if score then
        score.value = self.points
    end
    local best = self.best
    if best then
        best.value = self.bestPoints
    end
    local showStart = self.showStart
    if showStart then
        showStart.value = self.state == 'ready'
    end
    local showGameOver = self.showGameOver
    if showGameOver then
        showGameOver.value = self.state == 'over'
    end
end

-- ---------------------------------------------------------------- game logic

local function placeFood(self: Game)
    local taken: { [number]: boolean } = {}
    for _, c in self.snake do
        taken[c.y * self.cols + c.x] = true
    end
    local free: { Cell } = {}
    for y = 0, self.cols - 1 do
        for x = 0, self.cols - 1 do
            if not taken[y * self.cols + x] then
                table.insert(free, { x = x, y = y })
            end
        end
    end
    if #free == 0 then
        return
    end
    self.foodCell = free[math.random(1, #free)]
    self.foodAge = 0
end

local function reset(self: Game, state: string)
    self.cols = math.max(6, math.floor(self.gridSize))
    local mid = math.floor(self.cols / 2)
    self.snake = {}
    for i = 0, 3 do
        table.insert(self.snake, { x = mid - 2 - i, y = mid })
    end
    self.prev = copyCells(self.snake)
    self.dir = { x = 1, y = 0 }
    self.queue = {}
    self.headAngle = 0
    self.stepTime = self.startStepTime
    self.acc = 0
    self.points = 0
    self.eatAge = 10
    self.deathAge = 0
    self.state = state
    self.builtFor = -1
    placeFood(self)
    publish(self)
end

local function burst(self: Game, x: number, y: number)
    for i = 1, 14 do
        local a = (i / 14) * 2 * math.pi + math.random() * 0.4
        local speed = self.cell * (2.5 + math.random() * 3.5)
        table.insert(self.sparks, {
            x = x,
            y = y,
            vx = math.cos(a) * speed,
            vy = math.sin(a) * speed,
            life = 1,
            size = self.cell * (0.06 + math.random() * 0.07),
        })
    end
end

local function die(self: Game)
    self.state = 'over'
    self.deathAge = 0
    self.prev = copyCells(self.snake)
    self.queue = {}
    if self.points > self.bestPoints then
        self.bestPoints = self.points
    end
    publish(self)
end

local function step(self: Game)
    -- take the next buffered turn
    if #self.queue > 0 then
        self.dir = table.remove(self.queue, 1) :: Cell
    end

    local head = self.snake[1]
    local nx, ny = head.x + self.dir.x, head.y + self.dir.y

    -- walls
    if nx < 0 or ny < 0 or nx >= self.cols or ny >= self.cols then
        die(self)
        return
    end

    local eats = nx == self.foodCell.x and ny == self.foodCell.y

    -- body (the tail cell is free this step unless we are growing)
    local last = if eats then #self.snake else #self.snake - 1
    for i = 1, last do
        local c = self.snake[i]
        if c.x == nx and c.y == ny then
            die(self)
            return
        end
    end

    self.prev = copyCells(self.snake)
    table.insert(self.snake, 1, { x = nx, y = ny })
    if eats then
        -- the new tail segment grows out of where the tail already is
        local tail = self.prev[#self.prev]
        table.insert(self.prev, { x = tail.x, y = tail.y })
        self.points += 1
        self.stepTime = math.max(self.fastestStepTime, self.stepTime - self.speedUpPerFood)
        self.eatAge = 0
        burst(self, px(self, nx), py(self, ny))
        placeFood(self)
        publish(self)
    else
        table.remove(self.snake)
    end
end

local function turn(self: Game, dx: number, dy: number)
    -- compare against the last queued direction so quick double-taps work
    local last = if #self.queue > 0 then self.queue[#self.queue] else self.dir
    if (dx == last.x and dy == last.y) or (dx == -last.x and dy == -last.y) then
        return
    end
    if #self.queue < 3 then
        table.insert(self.queue, { x = dx, y = dy })
    end
end

-- ---------------------------------------------------------------- protocol

function init(self: Game, context: Context): boolean
    -- init runs twice; the view model only exists on the second call
    local vm = context:viewModel()
    if vm then
        self.score = vm:getNumber('score')
        self.best = vm:getNumber('best')
        self.showStart = vm:getBoolean('showStart')
        self.showGameOver = vm:getBoolean('showGameOver')
    end
    if self.headArt == nil then
        self.headArt = self.head:instance()
        self.bodyArt = self.body:instance()
        self.foodArt = self.food:instance()
    end
    if self.ready then
        publish(self)
    end
    return true
end

function resize(self: Game, size: Vector, scale: number)
    self.size = size
    self.builtFor = -1
end

function keyboardEvent(self: Game, event: KeyboardEvent): boolean
    if event.phase ~= 'down' then
        return false
    end
    local k = event.key
    local dx, dy = 0, 0
    if k == KEY_RIGHT or k == KEY_D then
        dx = 1
    elseif k == KEY_LEFT or k == KEY_A then
        dx = -1
    elseif k == KEY_DOWN or k == KEY_S then
        dy = 1
    elseif k == KEY_UP or k == KEY_W then
        dy = -1
    end
    local isDirection = dx ~= 0 or dy ~= 0
    local isConfirm = k == KEY_SPACE or k == KEY_ENTER or k == KEY_KP_ENTER
    if not isDirection and not isConfirm then
        return false
    end

    if self.state == 'over' then
        -- a short grace period so a held key does not skip the game-over card
        if self.deathAge < 0.5 then
            return true
        end
        reset(self, 'playing')
        if isDirection then
            turn(self, dx, dy)
        end
        return true
    end

    if self.state == 'ready' then
        self.state = 'playing'
        publish(self)
    end
    if isDirection then
        turn(self, dx, dy)
    end
    return true
end

function advance(self: Game, seconds: number): boolean
    local dt = math.min(seconds, 0.05)
    if not self.ready then
        self.ready = true
        reset(self, 'ready')
    end
    self.time += dt
    self.foodAge += dt
    self.eatAge += dt

    local headArt, bodyArt, foodArt = self.headArt, self.bodyArt, self.foodArt
    if headArt then headArt:advance(dt) end
    if bodyArt then bodyArt:advance(dt) end
    if foodArt then foodArt:advance(dt) end

    if self.state == 'playing' then
        self.acc += dt
        while self.acc >= self.stepTime and self.state == 'playing' do
            self.acc -= self.stepTime
            step(self)
        end
    elseif self.state == 'over' then
        self.deathAge += dt
    end

    -- ease the head toward the travel direction
    local target = math.atan2(self.dir.y, self.dir.x)
    local turnRate = 1 - math.exp(-dt * 22)
    self.headAngle += angleDelta(self.headAngle, target) * turnRate

    -- sparks
    local alive: { Spark } = {}
    for _, s in self.sparks do
        s.life -= dt * 2.2
        if s.life > 0 then
            s.vx *= 1 - dt * 4
            s.vy *= 1 - dt * 4
            s.x += s.vx * dt
            s.y += s.vy * dt
            table.insert(alive, s)
        end
    end
    self.sparks = alive
    return true
end

local function buildBoard(self: Game)
    local w, h = self.size.x, self.size.y
    local margin = 16
    self.cell = math.floor((math.min(w, h) - margin * 2) / self.cols)
    local span = self.cell * self.cols
    self.ox = math.floor((w - span) / 2)
    self.oy = math.floor((h - span) / 2)

    self.boardPath:reset()
    addRoundRect(self.boardPath, self.ox - 6, self.oy - 6, span + 12, span + 12, 18)

    -- checkerboard: every other cell, slightly lighter
    self.tilePath:reset()
    local inset = 1.5
    for y = 0, self.cols - 1 do
        for x = 0, self.cols - 1 do
            if (x + y) % 2 == 0 then
                addRoundRect(
                    self.tilePath,
                    self.ox + x * self.cell + inset,
                    self.oy + y * self.cell + inset,
                    self.cell - inset * 2,
                    self.cell - inset * 2,
                    self.cell * 0.18
                )
            end
        end
    end
    self.builtFor = self.cols
end

function draw(self: Game, renderer: Renderer)
    if not self.ready then
        return
    end
    if self.builtFor ~= self.cols then
        buildBoard(self)
    end

    -- a short shake when the snake crashes
    local shake = 0
    if self.state == 'over' then
        local fade = math.max(0, 1 - self.deathAge * 3.5)
        shake = math.sin(self.deathAge * 70) * self.cell * 0.22 * fade
    end
    renderer:save()
    renderer:transform(Mat2D.withTranslation(shake, 0))

    renderer:drawPath(self.boardPath, self.boardPaint)
    renderer:drawPath(self.tilePath, self.tilePaint)

    local alpha = if self.state == 'playing' then clamp(self.acc / self.stepTime, 0, 1) else 1

    -- food: glow, then the art popping in
    local fx, fy = px(self, self.foodCell.x), py(self, self.foodCell.y)
    local pop = easeOutBack(clamp(self.foodAge / 0.35, 0, 1))
    local glow = 0.75 + 0.25 * math.sin(self.time * 4)
    self.glowPaint.color = Color.rgba(255, 90, 110, math.floor(70 * glow))
    renderer:save()
    renderer:transform(Mat2D.values(self.cell * pop, 0, 0, self.cell * pop, fx, fy))
    renderer:drawPath(self.dot, self.glowPaint)
    renderer:restore()
    drawArt(self, renderer, self.foodArt, fx, fy, 0, 1.1 * pop)

    -- snake positions this frame (interpolated between steps)
    local n = #self.snake
    local xs: { number } = {}
    local ys: { number } = {}
    for i = 1, n do
        local a, b = self.prev[i], self.snake[i]
        xs[i] = px(self, lerp(a.x, b.x, alpha))
        ys[i] = py(self, lerp(a.y, b.y, alpha))
    end

    -- crash: nudge the head into the wall and back
    if self.state == 'over' then
        local bonk = math.sin(clamp(self.deathAge / 0.22, 0, 1) * math.pi) * 0.3 * self.cell
        xs[1] += self.dir.x * bonk
        ys[1] += self.dir.y * bonk
    end

    -- a bulge travels from head to tail after eating
    local wave = self.eatAge * 22
    local function bodyScale(i: number): number
        local t = if n > 1 then (i - 1) / (n - 1) else 0
        local s = lerp(1.0, 0.62, t)
        local d = (i - 1) - wave
        return s + 0.28 * math.exp(-d * d * 0.35)
    end

    renderer:save()
    if self.state == 'over' then
        -- blink a few times after the crash
        local blink = 0.45 + 0.55 * math.abs(math.cos(math.min(self.deathAge, 0.9) * 10))
        renderer:modulateOpacity(blink)
    end

    -- body, tail first so segments nearer the head sit on top. Midpoints
    -- between segments fill the gaps so the body reads as one smooth tube.
    local bodyArt = self.bodyArt
    for i = n, 2, -1 do
        local s = bodyScale(i)
        local j = i - 1
        drawArt(self, renderer, bodyArt, (xs[i] + xs[j]) / 2, (ys[i] + ys[j]) / 2, 0, (s + bodyScale(j)) / 2)
        drawArt(self, renderer, bodyArt, xs[i], ys[i], 0, s)
    end

    -- head
    local headScale = 1.08 + 0.3 * math.exp(-self.eatAge * 9)
    drawArt(self, renderer, self.headArt, xs[1], ys[1], self.headAngle, headScale)
    renderer:restore()

    -- sparks from eating
    for _, s in self.sparks do
        self.sparkPaint.color = Color.rgba(255, 215, 110, math.floor(255 * clamp(s.life, 0, 1)))
        local r = s.size * (0.4 + 0.6 * s.life)
        renderer:save()
        renderer:transform(Mat2D.values(r, 0, 0, r, s.x, s.y))
        renderer:drawPath(self.dot, self.sparkPaint)
        renderer:restore()
    end

    renderer:restore()
end

return function(context: Context): Layout<Game>
    local dot = Path.new()
    addCircle(dot, 0, 0, 1)
    return {
        head = late(),
        body = late(),
        food = late(),
        gridSize = 20,
        startStepTime = 0.15,
        fastestStepTime = 0.06,
        speedUpPerFood = 0.005,

        headArt = nil,
        bodyArt = nil,
        foodArt = nil,

        score = nil,
        best = nil,
        showStart = nil,
        showGameOver = nil,

        size = Vector.xy(720, 720),
        cols = 20,
        cell = 34,
        ox = 0,
        oy = 0,
        builtFor = -1,

        ready = false,
        state = 'ready',
        snake = {},
        prev = {},
        dir = { x = 1, y = 0 },
        queue = {},
        foodCell = { x = 0, y = 0 },
        stepTime = 0.15,
        acc = 0,
        points = 0,
        bestPoints = 0,

        time = 0,
        foodAge = 0,
        eatAge = 10,
        deathAge = 0,
        headAngle = 0,
        sparks = {},

        boardPath = Path.new(),
        tilePath = Path.new(),
        dot = dot,
        boardPaint = Paint.with({ color = Color.rgb(22, 31, 40) }),
        tilePaint = Paint.with({ color = Color.rgb(27, 38, 49) }),
        glowPaint = Paint.with({ color = Color.rgba(255, 90, 110, 70), feather = 0.7 }),
        sparkPaint = Paint.with({ color = Color.rgb(255, 215, 110) }),

        init = init,
        resize = resize,
        advance = advance,
        draw = draw,
        keyboardEvent = keyboardEvent,
    }
end
