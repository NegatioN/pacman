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
POWER_PELLET_SIZE :: 16

// Movement speed: how fast lerp_t increments per frame (1.0 = instant)
MOVE_SPEED :: 0.15

// Scatter mode duration in frames (assuming ~60 FPS)
SCATTER_DURATION :: 600

// Tile type constants for level data
TILE_EMPTY  :: '0'
TILE_PELLET :: '1'
TILE_WALL   :: '2'
TILE_SPAWN  :: '3'
TILE_GHOST_HOUSE :: '4'
TILE_POWER_PELLET :: '5'

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

GhostType :: enum {
	Blinky,
	Pinky,
	Inky,
	Clyde,
}

Ghost :: struct {
	using entity: Entity,
	type:         GhostType,
	scatter_pos:  GridPos,
	home_pos:     GridPos,
}

Pellet :: struct {
	grid_pos: GridPos,
	active:   bool,
	is_power: bool,
}

CTX :: struct {
	window:         ^sdl2.Window,
	renderer:       ^sdl2.Renderer,
	
	player:         Entity,
	ghosts:         [dynamic]Ghost,
	
	wall_tex:       ^sdl2.Texture,
	pellet_tex:     ^sdl2.Texture,
	power_pellet_tex: ^sdl2.Texture,
	
	level:          [dynamic]string,
	level_width:    int,
	level_height:   int,
	pellets:        [dynamic]Pellet,
	
	font:           ^ttf.Font,
	score:          int,
	pellets_active: int,
	game_won:       bool,
	
	scatter_mode_timer: int,
	
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
		WINDOW_WIDTH,
		WINDOW_HEIGHT, sdl2.WINDOW_SHOWN)
	if ctx.window == nil {
		log.errorf("Window creation failed: %s", sdl2.GetError())
		return false
	}

	ctx.renderer = sdl2.CreateRenderer(ctx.window, -1, sdl2.RENDERER_ACCELERATED + sdl2.RENDERER_PRESENTVSYNC)
	if ctx.renderer == nil {
		log.errorf("Renderer creation failed: %s", sdl2.GetError())
		return false
	}

	return true
}

load_texture :: proc(path: string) -> ^sdl2.Texture {
	c_path := strings.clone_to_cstring(path, context.temp_allocator)
	tex := img.LoadTexture(ctx.renderer, c_path)
	if tex == nil {
		log.errorf("Failed to load texture %s: %s", path, sdl2.GetError())
	}
	return tex
}

init_resources :: proc() -> bool {
	ctx.wall_tex = load_texture("assets/wall.png")
	if ctx.wall_tex == nil { return false }

	ctx.pellet_tex = load_texture("assets/pellet.bmp")
	if ctx.pellet_tex == nil { return false }

	ctx.power_pellet_tex = load_texture("assets/power_pellet.bmp")
	if ctx.power_pellet_tex == nil { return false }

	player_tex := load_texture("assets/pacman.png")
	if player_tex == nil { return false }

	font_path := "/usr/share/fonts/TTF/DejaVuSans.ttf"
	c_font_path := strings.clone_to_cstring(font_path, context.temp_allocator)
	
	ctx.font = ttf.OpenFont(c_font_path, 24)
	if ctx.font == nil {
		log.errorf("Failed to load font %s: %s", font_path, sdl2.GetError())
		return false
	}

	ctx.player = Entity{
		tex = player_tex,
		pos = {0, 0},
		target = {0, 0},
		lerp_t = 1.0,
		rotation = 0.0,
		current_dir = .None,
		next_dir = .None,
	}

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

	ctx.offset_x = (WINDOW_WIDTH - i32(ctx.level_width) * TILE_SIZE) / 2
	ctx.offset_y = (WINDOW_HEIGHT - i32(ctx.level_height) * TILE_SIZE) / 2

	spawn_ghosts_at := GridPos{0, 0}
	found_ghost_spawn := false

	for row, y in ctx.level {
		for char, x in row {
			grid_pos := GridPos{x, y}

			switch char {
			case TILE_SPAWN:
				ctx.player.pos = grid_pos
				ctx.player.target = grid_pos
			case TILE_GHOST_HOUSE:
				spawn_ghosts_at = grid_pos
				found_ghost_spawn = true
			case TILE_PELLET:
				append(&ctx.pellets, Pellet{grid_pos = grid_pos, active = true, is_power = false})
			case TILE_POWER_PELLET:
				append(&ctx.pellets, Pellet{grid_pos = grid_pos, active = true, is_power = true})
			}
		}
	}
	
	if found_ghost_spawn {
		ghost_types := [?]GhostType{.Blinky, .Pinky, .Inky, .Clyde}
		tex_names   := [?]string{"assets/blinky.png", "assets/pinky.png", "assets/inky.png", "assets/clyde.png"}
		
		scatter_targets := [?]GridPos{
			{ctx.level_width-2, 1}, 
			{1, 1}, 
			{ctx.level_width-2, ctx.level_height-2}, 
			{1, ctx.level_height-2},
		}

		for gt, i in ghost_types {
			tex := load_texture(tex_names[i])
			if tex != nil {
				g := Ghost{
					entity = Entity{
						tex = tex,
						pos = spawn_ghosts_at,
					target = spawn_ghosts_at,
					lerp_t = 1.0,
					current_dir = .None,
					next_dir = .None,
				},
				type = gt,
				home_pos = spawn_ghosts_at,
				scatter_pos = scatter_targets[i],
			}
			append(&ctx.ghosts, g)
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
	for g in ctx.ghosts {
		if g.tex != nil do sdl2.DestroyTexture(g.tex)
	}
	delete(ctx.ghosts)

	if ctx.wall_tex != nil {
		sdl2.DestroyTexture(ctx.wall_tex)
	}
	if ctx.pellet_tex != nil {
		sdl2.DestroyTexture(ctx.pellet_tex)
	}
	if ctx.power_pellet_tex != nil {
		sdl2.DestroyTexture(ctx.power_pellet_tex)
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

grid_to_screen :: proc(gx, gy: int) -> (x, y: i32) {
	return ctx.offset_x + i32(gx) * TILE_SIZE, ctx.offset_y + i32(gy) * TILE_SIZE
}

is_walkable :: proc(gx, gy: int) -> bool {
	if gy < 0 || gy >= ctx.level_height { return false }
	row := ctx.level[gy]
	if gx < 0 || gx >= len(row) { return false }
	return row[gx] != TILE_WALL
}

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

get_opposite_dir :: proc(dir: Direction) -> Direction {
	switch dir {
	case .Up:    return .Down
	case .Down:  return .Up
	case .Left:  return .Right
	case .Right: return .Left
	case .None:  return .None
	}
	return .None
}

dist_sq :: proc(a, b: GridPos) -> int {
	dx := a.x - b.x
	dy := a.y - b.y
	return dx*dx + dy*dy
}

dir_to_gridpos :: proc(pos: GridPos, dir: Direction) -> GridPos {
	dx, dy := dir_to_offset(dir)
	return GridPos{pos.x + dx, pos.y + dy}
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

get_ghost_target :: proc(ghost: ^Ghost) -> GridPos {
	// If in scatter mode, return scatter position
	if ctx.scatter_mode_timer > 0 {
		return ghost.scatter_pos
	}

	pacman_pos := ctx.player.target
	pacman_dir := ctx.player.current_dir

	switch ghost.type {
	case .Blinky:
		return pacman_pos
	case .Pinky:
		dx, dy := dir_to_offset(pacman_dir)
		return GridPos{pacman_pos.x + dx * 4, pacman_pos.y + dy * 4}
	case .Inky:
		dx, dy := dir_to_offset(pacman_dir)
		return GridPos{pacman_pos.x + dx * 2, pacman_pos.y + dy * 2}
	case .Clyde:
		d_sq := dist_sq(ghost.pos, pacman_pos)
		if d_sq > 64 {
			return pacman_pos
		} else {
			return ghost.scatter_pos
		}
	}
	return pacman_pos
}

update_ghost_ai :: proc(ghost: ^Ghost) {
	if ghost.lerp_t >= 1.0 {
		origin := ghost.target
		
		valid_directions := [len(DIRECTIONS)]bool{}
		opposite_dir := get_opposite_dir(ghost.current_dir)
		
		valid_count := 0
		for d, i in DIRECTIONS {
			dx, dy := dir_to_offset(d)
			if is_walkable(origin.x + dx, origin.y + dy) {
				valid_directions[i] = true
				valid_count += 1
			}
		}

		if valid_count > 1 {
			for d, i in DIRECTIONS {
				if d == opposite_dir {
					valid_directions[i] = false
				}
			}
		}

		best_score := max(int)
		best_dir_ind := -1
		
		target_tile := get_ghost_target(ghost)
		
		for vd, i in valid_directions {
			if vd {
				neighbor := dir_to_gridpos(origin, DIRECTIONS[i])
				cur_score := dist_sq(neighbor, target_tile)
				if cur_score < best_score {
					best_score = cur_score
					best_dir_ind = i
				}
			}
		}

		if best_dir_ind != -1 {
			ghost.next_dir = DIRECTIONS[best_dir_ind]
		} else {
			ghost.next_dir = opposite_dir
		}
	}
	update_entity_movement(&ghost.entity)
}

update_entity_movement :: proc(entity: ^Entity) {
	if entity.lerp_t >= 1.0 {
		entity.pos = entity.target
		entity.lerp_t = 1.0
		
		if entity.next_dir != .None {
			dx, dy := dir_to_offset(entity.next_dir)
			if is_walkable(entity.pos.x + dx, entity.pos.y + dy) {
				entity.current_dir = entity.next_dir
			}
		}
		
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
	
	if ctx.scatter_mode_timer > 0 {
		ctx.scatter_mode_timer -= 1
	}
	
	for &g in ctx.ghosts {
		update_ghost_ai(&g)
	}
	
	update_entity_movement(&ctx.player)

	for &pellet in ctx.pellets {
		if pellet.active && pellet.grid_pos == ctx.player.pos {
			pellet.active = false
			ctx.score += 10
			ctx.pellets_active -= 1
			if pellet.is_power {
				ctx.scatter_mode_timer = SCATTER_DURATION
				log.info("Scatter Mode Activated!")
				
				// Reverse all ghosts immediately
				for &g in ctx.ghosts {
					if g.lerp_t < 1.0 {
						// Moving: Flip pos/target and lerp
						g.pos, g.target = g.target, g.pos
						g.lerp_t = 1.0 - g.lerp_t
						g.current_dir = get_opposite_dir(g.current_dir)
						g.next_dir = .None
					} else {
						// Stationary: just flip direction so they are forced to turn around
						g.current_dir = get_opposite_dir(g.current_dir)
					}
				}
			}
		}
	}
	
	if ctx.pellets_active == 0 {
		ctx.game_won = true
	}
}

draw_entity :: proc(entity: ^Entity) {
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

	for row, y in ctx.level {
		for char, x in row {
			if char == TILE_WALL {
				sx, sy := grid_to_screen(x, y)
				rect := sdl2.Rect{x = sx, y = sy, w = TILE_SIZE, h = TILE_SIZE}
				sdl2.RenderCopy(ctx.renderer, ctx.wall_tex, nil, &rect)
			}
		}
	}

	for pellet in ctx.pellets {
		if pellet.active {
			sx, sy := grid_to_screen(pellet.grid_pos.x, pellet.grid_pos.y)
			
			size := i32(PELLET_SIZE)
			tex := ctx.pellet_tex
			if pellet.is_power {
				size = POWER_PELLET_SIZE
				tex = ctx.power_pellet_tex
			}
			
			offset := (TILE_SIZE - size) / 2
			rect := sdl2.Rect{x = sx + offset, y = sy + offset, w = size, h = size}
			sdl2.RenderCopy(ctx.renderer, tex, nil, &rect)
		}
	}

	draw_entity(&ctx.player)
	for &g in ctx.ghosts {
		draw_entity(&g.entity)
	}

	score_str := fmt.tprintf("Score: %d", ctx.score)
	if ctx.scatter_mode_timer > 0 {
		score_str = fmt.tprintf("Score: %d (SCATTER)", ctx.score)
	}
	
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
	
	if ctx.game_won {
		c_win_str := strings.clone_to_cstring("YOU WIN!", context.temp_allocator)
		yellow := sdl2.Color{255, 255, 0, 255}
		win_surface := ttf.RenderText_Solid(ctx.font, c_win_str, yellow)
		if win_surface != nil {
			texture := sdl2.CreateTextureFromSurface(ctx.renderer, win_surface)
			if texture != nil {
				w, h: i32
				sdl2.QueryTexture(texture, nil, nil, &w, &h)
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
