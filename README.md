# Snake (Rive CLI)

A smooth, animated Snake game built with the [Rive CLI](https://rive.app/docs/cli/getting-started).

## Play

```bash
rive .
```

| Key | Action |
|---|---|
| Arrow keys or WASD | Steer (also starts the game) |
| Space or Enter | Play again after a game over |

The snake speeds up a little every time it eats.

## Project layout

| Path | What it is |
|---|---|
| `scene.rml` | The game screen: HUD, start card, game-over card, and the view model the game writes to |
| `art/snake-art.rml` | **The swappable art**: the `Head`, `Body` and `Food` artboards |
| `game.luau` | Game logic and the playfield renderer |
| `Inter.ttf` | UI font (SIL Open Font License) |
| `rive.yaml` | Project config (`main: Game` is the artboard that opens) |

## Syncing with the Rive editor

The project is linked to a Rive file (see `push:` in `rive.yaml`).

```bash
rive push   # send local changes to the Rive file
rive pull   # bring editor changes down (overwrites local files)
```

Commit before pulling so the changes show up as a reviewable diff. A pull
lays files out the way the Rive file holds them, which is why the script and
font live in the project root.

## Swapping art

The game script never draws the snake or food itself. It draws the three
artboards in `art/snake-art.rml`, so you can change the look without touching
any code.

Every piece of art follows the same rules:

- The artboard is **100 × 100**, and the art is centred on **(50, 50)**.
- The game scales it to one grid cell, so 100 units = 1 cell.
- **Head faces right.** The game rotates it toward the direction of travel.
- The artboard's own state machine keeps playing, so idle animations such as
  the head's blink and the food's bob work automatically.

### Option 1: edit the vector art

Change the shapes inside the `Head`, `Body` or `Food` artboard in
`art/snake-art.rml` and save. The running preview rebuilds on its own.

### Option 2: use your own image

1. Put the image in the project folder, for example `head.png`.
2. Add an image asset next to the `ComponentAsset` lines at the bottom of
   `art/snake-art.rml`:

   ```xml
   <ImageAsset file="head.png" name="head" id="1:500"/>
   ```

3. Replace the contents of the artboard (for example, the `Face` node in
   `Head`) with an image centred in the 100 × 100 frame:

   ```xml
   <Image x="50" y="50" assetId="1:500" name="Head Image"/>
   ```

   An image draws at its pixel size, so scale it to fit the 100-unit frame:
   for a 500 px image, `scaleX="0.2" scaleY="0.2"`. The animations key the
   ids of the original shapes (for example `Eye Top` in `Head`), so delete any
   `KeyedObject` whose target you removed.

### Option 3: the Rive editor

Export an editor file and redraw the `Head`, `Body` and `Food` artboards in
the Rive editor, keeping the 100 × 100 frame and the facing-right head. This
needs a Rive account:

```bash
rive login
rive . --once --rev=build/snake-game.rev
```

## Tuning

These inputs are on the `Snake Game` scripted layout in `scene.rml`:

| Input | Default | Meaning |
|---|---|---|
| `gridSize` | `20` | Cells per side |
| `startStepTime` | `0.15` | Seconds per move at the start |
| `fastestStepTime` | `0.06` | Speed cap (seconds per move) |
| `speedUpPerFood` | `0.005` | How much faster each bite makes the snake |

## Checks

```bash
rive . --verify
rive . --screenshot=build/play.png --advance=10 --key=right --advance=1s
```
