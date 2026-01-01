package main

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "vendor:sdl2"
import img "vendor:sdl2/image"
import ttf "vendor:sdl2/ttf"

WINDOW_TITLE  :: "Odin SDL2 Pacman"
WINDOW_WIDTH  :: i32(800)
WINDOW_HEIGHT :: i32(600)
PLAYER_SPEED  :: 4.0
TILE_SIZE     :: 32
PELLET_SIZE   :: 8

Direction :: enum {
	None,
	Up,
	Down,
	Left,
	Right,
}

Texture_Asset :: struct {
	tex:         ^sdl2.Texture,
	w:           i32,
	h:           i32,
	x:           f32,
	y:           f32,
	dest_x:      f32,
	dest_y:      f32,
	rotation:    f64,
	is_moving:   bool,
	current_dir: Direction,
	next_dir:    Direction,
}

Pellet :: struct {
	x, y:   f32,
	active: bool,
}

CTX :: struct {
	window:         ^sdl2.Window,
	renderer:       ^sdl2.Renderer,
	
	player:         Texture_Asset,
	wall_tex:       ^sdl2.Texture,
	pellet_tex:     ^sdl2.Texture,
	level:          [dynamic]string,
	pellets:        [dynamic]Pellet,
	
	font:           ^ttf.Font,
	score:          int,
	pellets_active: int,
	game_won:       bool,
	
	level_offset_x: i32,
	level_offset_y: i32,
	
	should_close:   bool,
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

	// Load Font
	font_path := "/usr/share/fonts/TTF/DejaVuSans.ttf"
	c_font_path := strings.clone_to_cstring(font_path, context.temp_allocator)
	
	ctx.font = ttf.OpenFont(c_font_path, 24)
	if ctx.font == nil {
		log.errorf("Failed to load font %s: %s", font_path, sdl2.GetError())
		return false
	}

	// Setup Player Asset
	w, h: i32
	sdl2.QueryTexture(player_tex, nil, nil, &w, &h)
	ctx.player = Texture_Asset{
		tex = player_tex,
		w = w,
		h = h,
		x = 0,
		y = 0,
		dest_x = 0,
		dest_y = 0,
		rotation = 0.0,
		is_moving = false,
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
	max_w := 0
	for line in strings.split_iterator(&it, "\n") {
		trimmed := strings.trim_space(line)
		if len(trimmed) == 0 { continue }
		if strings.has_prefix(trimmed, "#") { continue }

		if len(trimmed) > max_w {
			max_w = len(trimmed)
		}
		append(&ctx.level, strings.clone(trimmed))
	}

	// Calculate centering offsets
	num_h := len(ctx.level)
	ctx.level_offset_x = (WINDOW_WIDTH - (i32(max_w) * TILE_SIZE)) / 2
	ctx.level_offset_y = (WINDOW_HEIGHT - (i32(num_h) * TILE_SIZE)) / 2

	// Initialize Entities
	for row, y in ctx.level {
		for char, x in row {
			pos_x := f32(ctx.level_offset_x + i32(x) * TILE_SIZE)
			pos_y := f32(ctx.level_offset_y + i32(y) * TILE_SIZE)

			if char == '3' {
				ctx.player.x = pos_x
				ctx.player.y = pos_y
				ctx.player.dest_x = pos_x
				ctx.player.dest_y = pos_y
			} else if char == '1' {
				// Spawn pellet centered in tile
				p := Pellet{
					x = pos_x + f32(TILE_SIZE - PELLET_SIZE)/2,
					y = pos_y + f32(TILE_SIZE - PELLET_SIZE)/2,
					active = true,
				}
				append(&ctx.pellets, p)
			}
		}
	}
	
	ctx.pellets_active = len(ctx.pellets)

	log.infof("Loaded level with %d rows. Offsets: %d, %d", len(ctx.level), ctx.level_offset_x, ctx.level_offset_y)
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

get_tile_at :: proc(x, y: f32) -> u8 {
	gx := i32((x - f32(ctx.level_offset_x)) / f32(TILE_SIZE))
	gy := i32((y - f32(ctx.level_offset_y)) / f32(TILE_SIZE))

	if gy < 0 || gy >= i32(len(ctx.level)) {
		return 0
	}
	
	row := ctx.level[gy]
	if gx < 0 || gx >= i32(len(row)) {
		return 0
	}

	return row[gx]
}

check_collision :: proc(x, y: f32) -> bool {
	epsilon :: 1.0
	if get_tile_at(x + epsilon, y + epsilon) == '2' { return true }
	if get_tile_at(x + f32(TILE_SIZE) - epsilon, y + epsilon) == '2' { return true }
	if get_tile_at(x + epsilon, y + f32(TILE_SIZE) - epsilon) == '2' { return true }
	if get_tile_at(x + f32(TILE_SIZE) - epsilon, y + f32(TILE_SIZE) - epsilon) == '2' { return true }
	return false
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

update :: proc() {
	if ctx.game_won {
		return
	}

	p := &ctx.player
	
	// Movement Logic
	if !p.is_moving {
		// Attempt to turn to next_dir if valid
		if p.next_dir != .None {
			dx, dy: f32 = 0, 0
			switch p.next_dir {
			case .Up:    dy = -TILE_SIZE
			case .Down:  dy = TILE_SIZE
			case .Left:  dx = -TILE_SIZE
			case .Right: dx = TILE_SIZE
			case .None: 
			}
			
			if !check_collision(p.x + dx, p.y + dy) {
				p.current_dir = p.next_dir
				// Optional: clear next_dir if we want single-turn buffering
				// p.next_dir = .None 
			}
		}

		// Calculate movement based on current_dir
		dx, dy: f32 = 0, 0
		switch p.current_dir {
		case .Up:    dy = -TILE_SIZE; p.rotation = 270
		case .Down:  dy = TILE_SIZE;  p.rotation = 90
		case .Left:  dx = -TILE_SIZE; p.rotation = 180
		case .Right: dx = TILE_SIZE;  p.rotation = 0
		case .None:
		}
		
		if (dx != 0 || dy != 0) && !check_collision(p.x + dx, p.y + dy) {
			p.dest_x = p.x + dx
			p.dest_y = p.y + dy
			p.is_moving = true
		}
	}
	
	if p.is_moving {
		if p.x < p.dest_x {
			p.x += PLAYER_SPEED
			if p.x > p.dest_x do p.x = p.dest_x
		} else if p.x > p.dest_x {
			p.x -= PLAYER_SPEED
			if p.x < p.dest_x do p.x = p.dest_x
		}
		
		if p.y < p.dest_y {
			p.y += PLAYER_SPEED
			if p.y > p.dest_y do p.y = p.dest_y
		} else if p.y > p.dest_y {
			p.y -= PLAYER_SPEED
			if p.y < p.dest_y do p.y = p.dest_y
		}
		
		if p.x == p.dest_x && p.y == p.dest_y {
			p.is_moving = false
		}
	}

	// Pellet Collision Logic
	player_center_x := p.x + f32(TILE_SIZE)/2
	player_center_y := p.y + f32(TILE_SIZE)/2
	
	for &pellet in ctx.pellets {
		if pellet.active {
			pellet_center_x := pellet.x + f32(PELLET_SIZE)/2
			pellet_center_y := pellet.y + f32(PELLET_SIZE)/2
			
			dx := player_center_x - pellet_center_x
			dy := player_center_y - pellet_center_y
			dist_sq := dx*dx + dy*dy
		
			if dist_sq < 64 {
				pellet.active = false
				ctx.score += 10
				ctx.pellets_active -= 1
			}
		}
	}
	
	if ctx.pellets_active == 0 {
		ctx.game_won = true
	}
}

draw :: proc() {
	sdl2.SetRenderDrawColor(ctx.renderer, 0, 0, 0, 255)
	sdl2.RenderClear(ctx.renderer)

	// Draw Level
	for row, y in ctx.level {
		for char, x in row {
			if char == '2' {
				rect := sdl2.Rect{
					x = ctx.level_offset_x + i32(x) * TILE_SIZE,
					y = ctx.level_offset_y + i32(y) * TILE_SIZE,
					w = TILE_SIZE,
					h = TILE_SIZE,
				}
				sdl2.RenderCopy(ctx.renderer, ctx.wall_tex, nil, &rect)
			}
		}
	}

	// Draw Pellets
	for pellet in ctx.pellets {
		if pellet.active {
			rect := sdl2.Rect{
				x = i32(pellet.x),
				y = i32(pellet.y),
				w = PELLET_SIZE,
				h = PELLET_SIZE,
			}
			sdl2.RenderCopy(ctx.renderer, ctx.pellet_tex, nil, &rect)
		}
	}

	// Draw Player
	p := ctx.player
	dst := sdl2.Rect{
		x = i32(p.x),
		y = i32(p.y),
		w = TILE_SIZE,
		h = TILE_SIZE,
	}
	sdl2.RenderCopyEx(ctx.renderer, p.tex, nil, &dst, p.rotation, nil, .NONE)

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
