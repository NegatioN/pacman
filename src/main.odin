package main

import "core:fmt"
import "core:log"
import "core:math"
import "core:os"
import "core:strings"
import "vendor:sdl2"
import img "vendor:sdl2/image"
import ttf "vendor:sdl2/ttf"

// Window and rendering constants
WINDOW_TITLE  :: "Odin SDL2 Pacman"
WINDOW_WIDTH  :: i32(800)
WINDOW_HEIGHT :: i32(600)
TILE_SIZE     :: 32
PELLET_SIZE   :: 8

// Movement speed: how fast lerp_t increments per frame (1.0 = instant)
MOVE_SPEED :: 0.15

// Tile type constants for level data
TILE_EMPTY :: '0'
TILE_PELLET :: '1'
TILE_WALL  :: '2'
TILE_SPAWN :: '3'
TILE_BLINKY :: '4'


Direction :: enum {
	None,
	Up,
	Down,
	Left,
	Right,
}

DIRECTIONS := [4]Direction{.Left, .Right, .Up, .Down}

// Grid position (logical coordinates)
GridPos :: struct {
	x, y: int,
}

// Entity using grid-based positioning with visual interpolation
Entity :: struct {
	pos:         GridPos,  // current logical grid position
	target:      GridPos,  // target grid position (where we're moving to)
	lerp_t:      f32,      // interpolation progress: 0.0 = at pos, 1.0 = at target
	rotation:    f64,      // visual rotation in degrees
	current_dir: Direction,
	next_dir:    Direction,
	tex:         ^sdl2.Texture,
}

Pellet :: struct {
	grid_pos: GridPos,
	active:   bool,
}

CTX :: struct {
	window:       ^sdl2.Window,
	renderer:     ^sdl2.Renderer,
	
	player:       Entity,
	blinky:       Entity,
	wall_tex:     ^sdl2.Texture,
	pellet_tex:   ^sdl2.Texture,
	level:        [dynamic]string,
	level_width:  int,
	level_height: int,
	pellets:      [dynamic]Pellet,
	
	font:           ^ttf.Font,
	score:          int,
	pellets_active: int,
	game_won:       bool,
	
	// Pixel offset to center level on screen
	offset_x: i32,
	offset_y: i32,
	
	should_close: bool,
}

ctx := CTX{}

init_sdl :: proc() -> bool {
	if sdl2.Init(sdl2.INIT_VIDEO) < 0 {
		log.errorf("SDL2 Init failed: %s", sdl2.GetError())
		return false
	}

	init_flags := img.Init(img.INIT_PNG | img.INIT_JPG)
	if .PNG not_in init_flags {
		log.errorf("SDL2 Image Init failed: %s", sdl2.GetError())
		return false
	}

	if ttf.Init() < 0 {
		log.errorf("SDL2 TTF Init failed: %s", sdl2.GetError())
		return false
	}

	ctx.window = sdl2.CreateWindow(WINDOW_TITLE,
		sdl2.WINDOWPOS_CENTERED, sdl2.WINDOWPOS_CENTERED,
		WINDOW_WIDTH, WINDOW_HEIGHT, sdl2.WINDOW_SHOWN)
	if ctx.window == nil {
		log.errorf("Window creation failed: %s", sdl2.GetError())
		return false
	}

	// Enable VSync
	ctx.renderer = sdl2.CreateRenderer(ctx.window, -1, sdl2.RENDERER_ACCELERATED + sdl2.RENDERER_PRESENTVSYNC)
	if ctx.renderer == nil {
		log.errorf("Renderer creation failed: %s", sdl2.GetError())
		return false
	}

	return true
}

init_resources :: proc() -> bool {
	// Load Wall Texture
	wall_path := "assets/wall.png"
	c_wall_path := strings.clone_to_cstring(wall_path, context.temp_allocator)
	ctx.wall_tex = img.LoadTexture(ctx.renderer, c_wall_path)
	if ctx.wall_tex == nil {
		log.errorf("Failed to load texture %s: %s", wall_path, sdl2.GetError())
		return false
	}

	// Load Pellet Texture
	pellet_path := "assets/pellet.bmp"
	c_pellet_path := strings.clone_to_cstring(pellet_path, context.temp_allocator)
	ctx.pellet_tex = img.LoadTexture(ctx.renderer, c_pellet_path)
	if ctx.pellet_tex == nil {
		log.errorf("Failed to load texture %s: %s", pellet_path, sdl2.GetError())
		return false
	}

	// Load Player Texture
	pac_path := "assets/pacman.png"
	c_pac_path := strings.clone_to_cstring(pac_path, context.temp_allocator)
	player_tex := img.LoadTexture(ctx.renderer, c_pac_path)
	if player_tex == nil {
		log.errorf("Failed to load texture %s: %s", pac_path, sdl2.GetError())
		return false
	}

	// Load Ghost Texture
	ghost_path := "assets/ghost1.png"
	c_ghost_path := strings.clone_to_cstring(ghost_path, context.temp_allocator)
	ghost_tex := img.LoadTexture(ctx.renderer, c_ghost_path)
	if ghost_tex == nil {
		log.errorf("Failed to load texture %s: %s", ghost_path, sdl2.GetError())
		return false
	}

	// Load Font
	font_path := "/usr/share/fonts/TTF/DejaVuSans.ttf"
	c_font_path := strings.clone_to_cstring(font_path, context.temp_allocator)
	
	ctx.font = ttf.OpenFont(c_font_path, 24)
	if ctx.font == nil {
		log.errorf("Failed to load font %s: %s", font_path, sdl2.GetError())
		return false
	}

	// Setup Player Entity
	ctx.player = Entity{
		tex = player_tex,
		pos = {0, 0},
		target = {0, 0},
		lerp_t = 1.0,  // Start fully arrived
		rotation = 0.0,
		current_dir = .None,
		next_dir = .None,
	}

	// Setup Player Entity
	ctx.blinky = Entity{
		tex = ghost_tex,
		pos = {0, 0},
		target = {0, 0},
		lerp_t = 1.0,  // Start fully arrived
		rotation = 0.0,
		current_dir = .None,
		next_dir = .None,
	}

	// Load Level Data
	data, ok := os.read_entire_file("data/level.dat")
	if !ok {
		log.errorf("Failed to read data/level.dat")
		return false
	}
	defer delete(data)

	s_data := string(data)
	it := s_data
	for line in strings.split_iterator(&it, "\n") {
		trimmed := strings.trim_space(line)
		if len(trimmed) == 0 { continue }
		if strings.has_prefix(trimmed, "#") { continue }

		if len(trimmed) > ctx.level_width {
			ctx.level_width = len(trimmed)
		}
		append(&ctx.level, strings.clone(trimmed))
	}
	ctx.level_height = len(ctx.level)

	// Calculate centering offsets
	ctx.offset_x = (WINDOW_WIDTH - i32(ctx.level_width) * TILE_SIZE) / 2
	ctx.offset_y = (WINDOW_HEIGHT - i32(ctx.level_height) * TILE_SIZE) / 2

	// Initialize entities from level data
	for row, y in ctx.level {
		for char, x in row {
			grid_pos := GridPos{x, y}

			switch char {
			case TILE_SPAWN:
				ctx.player.pos = grid_pos
				ctx.player.target = grid_pos
			case TILE_BLINKY:
				ctx.blinky.pos = grid_pos
				ctx.blinky.target = grid_pos
			case TILE_PELLET:
				append(&ctx.pellets, Pellet{grid_pos = grid_pos, active = true})
			}
		}
	}
	
	ctx.pellets_active = len(ctx.pellets)

	log.infof("Loaded level %dx%d. Offsets: %d, %d", ctx.level_width, ctx.level_height, ctx.offset_x, ctx.offset_y)
	return true
}

cleanup :: proc() {
	for line in ctx.level {
		delete(line)
	}
	delete(ctx.level)
	delete(ctx.pellets)

	if ctx.player.tex != nil {
		sdl2.DestroyTexture(ctx.player.tex)
	}
	if ctx.blinky.tex != nil {
		sdl2.DestroyTexture(ctx.blinky.tex)
	}
	if ctx.wall_tex != nil {
		sdl2.DestroyTexture(ctx.wall_tex)
	}
	if ctx.pellet_tex != nil {
		sdl2.DestroyTexture(ctx.pellet_tex)
	}
	if ctx.font != nil {
		ttf.CloseFont(ctx.font)
	}

	if ctx.renderer != nil {
		sdl2.DestroyRenderer(ctx.renderer)
	}
	if ctx.window != nil {
		sdl2.DestroyWindow(ctx.window)
	}
	ttf.Quit()
	img.Quit()
	sdl2.Quit()
}

// Convert grid position to screen pixel position
grid_to_screen :: proc(gx, gy: int) -> (x, y: i32) {
	return ctx.offset_x + i32(gx) * TILE_SIZE, ctx.offset_y + i32(gy) * TILE_SIZE
}

// Check if a grid cell is walkable (not a wall, and within bounds)
is_walkable :: proc(gx, gy: int) -> bool {
	if gy < 0 || gy >= ctx.level_height { return false }
	row := ctx.level[gy]
	if gx < 0 || gx >= len(row) { return false }
	return row[gx] != TILE_WALL
}

// Get the grid offset for a direction
dir_to_offset :: proc(dir: Direction) -> (dx, dy: int) {
	switch dir {
	case .Up:    return 0, -1
	case .Down:  return 0, 1
	case .Left:  return -1, 0
	case .Right: return 1, 0
	case .None:  return 0, 0
	}
	return 0, 0
}

// Get rotation angle for a direction
dir_to_rotation :: proc(dir: Direction) -> f64 {
	switch dir {
	case .Up:    return 270
	case .Down:  return 90
	case .Left:  return 180
	case .Right: return 0
	case .None:  return 0
	}
	return 0
}

process_input :: proc() {
	e: sdl2.Event
	for sdl2.PollEvent(&e) {
		#partial switch e.type {
		case .QUIT:
			ctx.should_close = true
		case .KEYDOWN:
			#partial switch e.key.keysym.sym {
			case .ESCAPE: ctx.should_close = true
			case .W: ctx.player.next_dir = .Up
			case .S: ctx.player.next_dir = .Down
			case .A: ctx.player.next_dir = .Left
			case .D: ctx.player.next_dir = .Right
			}
		}
	}
}

ValidDirection :: struct {
 up,down,left,right: bool
}
get_opposite_dir :: proc(dir: Direction) -> Direction {
	switch dir {
		case .Up: return .Down
		case .Down: return .Up
		case .Left: return .Right
		case .Right: return .Left
		case .None: return .None
	}
	return .None
}
set_valid_dir :: proc(dir: Direction, vd: ^ValidDirection, flag:bool=true){
	switch dir {
	case .Up: vd.up = flag
	case .Down: vd.down = flag
	case .Left:vd.left = flag
	case .Right:vd.right = flag
	case .None:
	}
}
dist_sq :: proc(a, b: GridPos) -> int {
	dx := a.x - b.x
	dy := a.y - b.y
	return dx*dx + dy*dy
}
//TODO dont allocate :shrug:
dir_to_gridpos :: proc(pos: GridPos, dir: Direction) -> GridPos {
	dx, dy := dir_to_offset(dir)
	return GridPos{pos.x + dx, pos.y + dy}
}


update_blinky_target :: proc(entity: ^Entity) {
	if entity.lerp_t >= 1.0 {
		valid_directions := [len(DIRECTIONS)]bool{}
		opposite_dir := get_opposite_dir(entity.current_dir)
		opposite_dir_idx := -1
		for d, i in DIRECTIONS {
			if d == opposite_dir {
				opposite_dir_idx = i
			}
			dx, dy := dir_to_offset(d)
			if is_walkable(entity.pos.x + dx, entity.pos.y + dy) {
				valid_directions[i] = true
			}
		}

		if opposite_dir_idx != -1 {
			valid_directions[opposite_dir_idx] = false //TODO might need to be done after we check if there are other valid directions in case of blind alleys
		}

		// calculate distances for all valid directions, and find best direction
		best_score := max(int)
		best_dir_ind := -1
		for vd, i in valid_directions {
			if vd {
				cur_score := dist_sq(ctx.player.pos, dir_to_gridpos(entity.pos, DIRECTIONS[i]))
				if cur_score <= best_score {
					best_score = cur_score
					best_dir_ind = i
				}
			}
		}
		entity.next_dir = DIRECTIONS[best_dir_ind]
	}
	update_entity_movement(entity)
}

update_entity_movement :: proc(entity: ^Entity) {
	// Check if we've finished moving to target
	if entity.lerp_t >= 1.0 {
		// Snap to target position
		entity.pos = entity.target
		entity.lerp_t = 1.0
		
		// Try to change to queued direction
		if entity.next_dir != .None {
			dx, dy := dir_to_offset(entity.next_dir)
			if is_walkable(entity.pos.x + dx, entity.pos.y + dy) {
				entity.current_dir = entity.next_dir
			}
		}
		
		// Try to continue in current direction
		if entity.current_dir != .None {
			dx, dy := dir_to_offset(entity.current_dir)
			next_x, next_y := entity.pos.x + dx, entity.pos.y + dy
			
			if is_walkable(next_x, next_y) {
				entity.target = GridPos{next_x, next_y}
				entity.lerp_t = 0.0
				entity.rotation = dir_to_rotation(entity.current_dir)
			}
		}
	}
	
	// Advance interpolation
	if entity.lerp_t < 1.0 {
		entity.lerp_t += MOVE_SPEED
		if entity.lerp_t > 1.0 {
			entity.lerp_t = 1.0
		}
	}
}

update :: proc() {
	if ctx.game_won {
		return
	}
	update_blinky_target(&ctx.blinky)
	update_entity_movement(&ctx.player)

	// Pellet collection: check if player's current grid cell has a pellet
	for &pellet in ctx.pellets {
		if pellet.active && pellet.grid_pos == ctx.player.pos {
			pellet.active = false
			ctx.score += 10
			ctx.pellets_active -= 1
		}
	}
	
	if ctx.pellets_active == 0 {
		ctx.game_won = true
	}
}

draw_entity :: proc(entity: ^Entity) {
// Draw entity with interpolation
	// Lerp between pos and target for smooth movement
	lerp_x := f32(entity.pos.x) + (f32(entity.target.x) - f32(entity.pos.x)) * entity.lerp_t
	lerp_y := f32(entity.pos.y) + (f32(entity.target.y) - f32(entity.pos.y)) * entity.lerp_t
	screen_x := ctx.offset_x + i32(lerp_x * f32(TILE_SIZE))
	screen_y := ctx.offset_y + i32(lerp_y * f32(TILE_SIZE))

	dst := sdl2.Rect{x = screen_x, y = screen_y, w = TILE_SIZE, h = TILE_SIZE}
	sdl2.RenderCopyEx(ctx.renderer, entity.tex, nil, &dst, entity.rotation, nil, .NONE)
}

draw :: proc() {
	sdl2.SetRenderDrawColor(ctx.renderer, 0, 0, 0, 255)
	sdl2.RenderClear(ctx.renderer)

	// Draw Level
	for row, y in ctx.level {
		for char, x in row {
			if char == TILE_WALL {
				sx, sy := grid_to_screen(x, y)
				rect := sdl2.Rect{x = sx, y = sy, w = TILE_SIZE, h = TILE_SIZE}
				sdl2.RenderCopy(ctx.renderer, ctx.wall_tex, nil, &rect)
			}
		}
	}

	// Draw Pellets
	for pellet in ctx.pellets {
		if pellet.active {
			sx, sy := grid_to_screen(pellet.grid_pos.x, pellet.grid_pos.y)
			// Center pellet within tile
			offset := i32((TILE_SIZE - PELLET_SIZE) / 2)
			rect := sdl2.Rect{x = sx + offset, y = sy + offset, w = PELLET_SIZE, h = PELLET_SIZE}
			sdl2.RenderCopy(ctx.renderer, ctx.pellet_tex, nil, &rect)
		}
	}

	// Draw Player with interpolation
	draw_entity(&ctx.player)
	draw_entity(&ctx.blinky)

	// Draw Score
	score_str := fmt.tprintf("Score: %d", ctx.score)
	c_score_str := strings.clone_to_cstring(score_str, context.temp_allocator)
	white := sdl2.Color{255, 255, 255, 255}
	surface := ttf.RenderText_Solid(ctx.font, c_score_str, white)
	if surface != nil {
		texture := sdl2.CreateTextureFromSurface(ctx.renderer, surface)
		if texture != nil {
			w, h: i32
			sdl2.QueryTexture(texture, nil, nil, &w, &h)
			dst := sdl2.Rect{
				x = WINDOW_WIDTH - w - 20,
				y = 20,
				w = w,
				h = h,
			}
			sdl2.RenderCopy(ctx.renderer, texture, nil, &dst)
			sdl2.DestroyTexture(texture)
		}
		sdl2.FreeSurface(surface)
	}
	
	// Draw Win Message
	if ctx.game_won {
		c_win_str := strings.clone_to_cstring("YOU WIN!", context.temp_allocator)
		yellow := sdl2.Color{255, 255, 0, 255}
		win_surface := ttf.RenderText_Solid(ctx.font, c_win_str, yellow)
		if win_surface != nil {
			texture := sdl2.CreateTextureFromSurface(ctx.renderer, win_surface)
			if texture != nil {
				w, h: i32
				sdl2.QueryTexture(texture, nil, nil, &w, &h)
				// Scale it up manually for the prototype win message
				dst := sdl2.Rect{
					x = (WINDOW_WIDTH - w * 3) / 2,
					y = (WINDOW_HEIGHT - h * 3) / 2,
					w = w * 3,
					h = h * 3,
				}
				sdl2.RenderCopy(ctx.renderer, texture, nil, &dst)
				sdl2.DestroyTexture(texture)
			}
			sdl2.FreeSurface(win_surface)
		}
	}

	sdl2.RenderPresent(ctx.renderer)
}

main :: proc() {
	context.logger = log.create_console_logger()

	if !init_sdl() {
		return
	}
	defer cleanup()

	if !init_resources() {
		return
	}

	for !ctx.should_close {
		process_input()
		update()
		draw()
	}
}
