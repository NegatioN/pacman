package main

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "vendor:sdl2"
import img "vendor:sdl2/image"

WINDOW_TITLE  :: "Odin SDL2 Pacman"
WINDOW_WIDTH  :: i32(800)
WINDOW_HEIGHT :: i32(600)
PLAYER_SPEED  :: 4.0
TILE_SIZE     :: 48

Texture_Asset :: struct {
	tex:      ^sdl2.Texture,
	w:        i32,
	h:        i32,
	x:        f32,
	y:        f32,
	rotation: f64,
}

Input :: struct {
	up:    bool,
	down:  bool,
	left:  bool,
	right: bool,
}

CTX :: struct {
	window:       ^sdl2.Window,
	renderer:     ^sdl2.Renderer,
	
	player:       Texture_Asset,
	wall_tex:     ^sdl2.Texture,
	level:        [dynamic]string,
	
	level_offset_x: i32,
	level_offset_y: i32,
	
	input:        Input,
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

	// Load Player Texture
	pac_path := "assets/pacman.png"
	c_pac_path := strings.clone_to_cstring(pac_path, context.temp_allocator)
	player_tex := img.LoadTexture(ctx.renderer, c_pac_path)
	if player_tex == nil {
		log.errorf("Failed to load texture %s: %s", pac_path, sdl2.GetError())
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
		rotation = 0.0,
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

	// Find player position and apply offsets
	for row, y in ctx.level {
		if idx := strings.index(row, "3"); idx != -1 {
			ctx.player.x = f32(ctx.level_offset_x + i32(idx) * TILE_SIZE)
			ctx.player.y = f32(ctx.level_offset_y + i32(y) * TILE_SIZE)
			break
		}
	}

	log.infof("Loaded level with %d rows. Offsets: %d, %d", len(ctx.level), ctx.level_offset_x, ctx.level_offset_y)
	return true
}

cleanup :: proc() {
	for line in ctx.level {
		delete(line)
	}
	delete(ctx.level)

	if ctx.player.tex != nil {
		sdl2.DestroyTexture(ctx.player.tex)
	}
	if ctx.wall_tex != nil {
		sdl2.DestroyTexture(ctx.wall_tex)
	}

	if ctx.renderer != nil {
		sdl2.DestroyRenderer(ctx.renderer)
	}
	if ctx.window != nil {
		sdl2.DestroyWindow(ctx.window)
	}
	img.Quit()
	sdl2.Quit()
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
			case .W: ctx.input.up = true
			case .S: ctx.input.down = true
			case .A: ctx.input.left = true
			case .D: ctx.input.right = true
			}
		case .KEYUP:
			#partial switch e.key.keysym.sym {
			case .W: ctx.input.up = false
			case .S: ctx.input.down = false
			case .A: ctx.input.left = false
			case .D: ctx.input.right = false
			}
		}
	}
}

update :: proc() {
	tex := &ctx.player
	
	if ctx.input.up {
		tex.y -= PLAYER_SPEED
		tex.rotation = 270
	} else if ctx.input.down {
		tex.y += PLAYER_SPEED
		tex.rotation = 90
	} else if ctx.input.left {
		tex.x -= PLAYER_SPEED
		tex.rotation = 180
	} else if ctx.input.right {
		tex.x += PLAYER_SPEED
		tex.rotation = 0
	}
}

draw :: proc() {
	sdl2.SetRenderDrawColor(ctx.renderer, 0, 0, 0, 255) // Black background
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

	// Draw Player
	p := ctx.player
	dst := sdl2.Rect{
		x = i32(p.x),
		y = i32(p.y),
		w = TILE_SIZE,
		h = TILE_SIZE,
	}
	sdl2.RenderCopyEx(ctx.renderer, p.tex, nil, &dst, p.rotation, nil, .NONE)

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
