/**
 * test-pattern.cpp - SMPTE "No Signal" test pattern generator
 *
 * Generates a classic SMPTE-style color bar test pattern with
 * camera name overlay and "NO SIGNAL" text in RGBA format.
 */

#include "test-pattern.h"

#include <cstring>

namespace avolocam {

// ASCII-indexed font table (32..127). Index with: g_font[ch - 32]
// Lowercase a-z maps to uppercase via get_glyph(), so those entries are unused.
static const BitmapGlyph g_font[96] = {
    // 32 ' ' (space)
    {{ 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000 }},
    // 33 '!'
    {{ 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b00000, 0b00100 }},
    // 34 '"'
    {{ 0b01010, 0b01010, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000 }},
    // 35 '#'
    {{ 0b01010, 0b11111, 0b01010, 0b01010, 0b11111, 0b01010, 0b00000 }},
    // 36 '$'
    {{ 0b00100, 0b01111, 0b10100, 0b01110, 0b00101, 0b11110, 0b00100 }},
    // 37 '%'
    {{ 0b11001, 0b11010, 0b00100, 0b00100, 0b01011, 0b10011, 0b00000 }},
    // 38 '&'
    {{ 0b01100, 0b10010, 0b01100, 0b10110, 0b10001, 0b10010, 0b01101 }},
    // 39 '\''
    {{ 0b00100, 0b00100, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000 }},
    // 40 '('
    {{ 0b00010, 0b00100, 0b01000, 0b01000, 0b01000, 0b00100, 0b00010 }},
    // 41 ')'
    {{ 0b01000, 0b00100, 0b00010, 0b00010, 0b00010, 0b00100, 0b01000 }},
    // 42 '*'
    {{ 0b00000, 0b00100, 0b10101, 0b01110, 0b10101, 0b00100, 0b00000 }},
    // 43 '+'
    {{ 0b00000, 0b00100, 0b00100, 0b11111, 0b00100, 0b00100, 0b00000 }},
    // 44 ','
    {{ 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b00100, 0b01000 }},
    // 45 '-'
    {{ 0b00000, 0b00000, 0b00000, 0b11111, 0b00000, 0b00000, 0b00000 }},
    // 46 '.'
    {{ 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b00100 }},
    // 47 '/'
    {{ 0b00001, 0b00010, 0b00100, 0b00100, 0b01000, 0b10000, 0b00000 }},
    // 48 '0'
    {{ 0b01110, 0b10001, 0b10011, 0b10101, 0b11001, 0b10001, 0b01110 }},
    // 49 '1'
    {{ 0b00100, 0b01100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110 }},
    // 50 '2'
    {{ 0b01110, 0b10001, 0b00001, 0b00110, 0b01000, 0b10000, 0b11111 }},
    // 51 '3'
    {{ 0b01110, 0b10001, 0b00001, 0b00110, 0b00001, 0b10001, 0b01110 }},
    // 52 '4'
    {{ 0b00010, 0b00110, 0b01010, 0b10010, 0b11111, 0b00010, 0b00010 }},
    // 53 '5'
    {{ 0b11111, 0b10000, 0b11110, 0b00001, 0b00001, 0b10001, 0b01110 }},
    // 54 '6'
    {{ 0b01110, 0b10000, 0b10000, 0b11110, 0b10001, 0b10001, 0b01110 }},
    // 55 '7'
    {{ 0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b01000, 0b01000 }},
    // 56 '8'
    {{ 0b01110, 0b10001, 0b10001, 0b01110, 0b10001, 0b10001, 0b01110 }},
    // 57 '9'
    {{ 0b01110, 0b10001, 0b10001, 0b01111, 0b00001, 0b00001, 0b01110 }},
    // 58 ':'
    {{ 0b00000, 0b00000, 0b00100, 0b00000, 0b00000, 0b00100, 0b00000 }},
    // 59 ';'
    {{ 0b00000, 0b00000, 0b00100, 0b00000, 0b00000, 0b00100, 0b01000 }},
    // 60 '<'
    {{ 0b00010, 0b00100, 0b01000, 0b10000, 0b01000, 0b00100, 0b00010 }},
    // 61 '='
    {{ 0b00000, 0b00000, 0b11111, 0b00000, 0b11111, 0b00000, 0b00000 }},
    // 62 '>'
    {{ 0b10000, 0b01000, 0b00100, 0b00010, 0b00100, 0b01000, 0b10000 }},
    // 63 '?'
    {{ 0b01110, 0b10001, 0b00001, 0b00110, 0b00100, 0b00000, 0b00100 }},
    // 64 '@'
    {{ 0b01110, 0b10001, 0b10111, 0b10101, 0b10110, 0b10000, 0b01110 }},
    // 65 'A'
    {{ 0b01110, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001 }},
    // 66 'B'
    {{ 0b11110, 0b10001, 0b10001, 0b11110, 0b10001, 0b10001, 0b11110 }},
    // 67 'C'
    {{ 0b01110, 0b10001, 0b10000, 0b10000, 0b10000, 0b10001, 0b01110 }},
    // 68 'D'
    {{ 0b11110, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b11110 }},
    // 69 'E'
    {{ 0b11111, 0b10000, 0b10000, 0b11110, 0b10000, 0b10000, 0b11111 }},
    // 70 'F'
    {{ 0b11111, 0b10000, 0b10000, 0b11110, 0b10000, 0b10000, 0b10000 }},
    // 71 'G'
    {{ 0b01110, 0b10001, 0b10000, 0b10111, 0b10001, 0b10001, 0b01110 }},
    // 72 'H'
    {{ 0b10001, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001 }},
    // 73 'I'
    {{ 0b01110, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110 }},
    // 74 'J'
    {{ 0b00111, 0b00010, 0b00010, 0b00010, 0b00010, 0b10010, 0b01100 }},
    // 75 'K'
    {{ 0b10001, 0b10010, 0b10100, 0b11000, 0b10100, 0b10010, 0b10001 }},
    // 76 'L'
    {{ 0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b11111 }},
    // 77 'M'
    {{ 0b10001, 0b11011, 0b10101, 0b10101, 0b10001, 0b10001, 0b10001 }},
    // 78 'N'
    {{ 0b10001, 0b11001, 0b10101, 0b10011, 0b10001, 0b10001, 0b10001 }},
    // 79 'O'
    {{ 0b01110, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110 }},
    // 80 'P'
    {{ 0b11110, 0b10001, 0b10001, 0b11110, 0b10000, 0b10000, 0b10000 }},
    // 81 'Q'
    {{ 0b01110, 0b10001, 0b10001, 0b10001, 0b10101, 0b10010, 0b01101 }},
    // 82 'R'
    {{ 0b11110, 0b10001, 0b10001, 0b11110, 0b10100, 0b10010, 0b10001 }},
    // 83 'S'
    {{ 0b01110, 0b10001, 0b10000, 0b01110, 0b00001, 0b10001, 0b01110 }},
    // 84 'T'
    {{ 0b11111, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100 }},
    // 85 'U'
    {{ 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110 }},
    // 86 'V'
    {{ 0b10001, 0b10001, 0b10001, 0b10001, 0b01010, 0b01010, 0b00100 }},
    // 87 'W'
    {{ 0b10001, 0b10001, 0b10001, 0b10101, 0b10101, 0b11011, 0b10001 }},
    // 88 'X'
    {{ 0b10001, 0b01010, 0b00100, 0b00100, 0b00100, 0b01010, 0b10001 }},
    // 89 'Y'
    {{ 0b10001, 0b01010, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100 }},
    // 90 'Z'
    {{ 0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b10000, 0b11111 }},
    // 91 '['
    {{ 0b01110, 0b01000, 0b01000, 0b01000, 0b01000, 0b01000, 0b01110 }},
    // 92 '\'
    {{ 0b10000, 0b01000, 0b00100, 0b00100, 0b00010, 0b00001, 0b00000 }},
    // 93 ']'
    {{ 0b01110, 0b00010, 0b00010, 0b00010, 0b00010, 0b00010, 0b01110 }},
    // 94 '^'
    {{ 0b00100, 0b01010, 0b10001, 0b00000, 0b00000, 0b00000, 0b00000 }},
    // 95 '_'
    {{ 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b11111 }},
    // 96 '`'
    {{ 0b01000, 0b00100, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000 }},
    // 97-122: lowercase a-z (rendered same as uppercase)
    {{ 0b01110, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001 }}, // a=A
    {{ 0b11110, 0b10001, 0b10001, 0b11110, 0b10001, 0b10001, 0b11110 }}, // b=B
    {{ 0b01110, 0b10001, 0b10000, 0b10000, 0b10000, 0b10001, 0b01110 }}, // c=C
    {{ 0b11110, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b11110 }}, // d=D
    {{ 0b11111, 0b10000, 0b10000, 0b11110, 0b10000, 0b10000, 0b11111 }}, // e=E
    {{ 0b11111, 0b10000, 0b10000, 0b11110, 0b10000, 0b10000, 0b10000 }}, // f=F
    {{ 0b01110, 0b10001, 0b10000, 0b10111, 0b10001, 0b10001, 0b01110 }}, // g=G
    {{ 0b10001, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001 }}, // h=H
    {{ 0b01110, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110 }}, // i=I
    {{ 0b00111, 0b00010, 0b00010, 0b00010, 0b00010, 0b10010, 0b01100 }}, // j=J
    {{ 0b10001, 0b10010, 0b10100, 0b11000, 0b10100, 0b10010, 0b10001 }}, // k=K
    {{ 0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b11111 }}, // l=L
    {{ 0b10001, 0b11011, 0b10101, 0b10101, 0b10001, 0b10001, 0b10001 }}, // m=M
    {{ 0b10001, 0b11001, 0b10101, 0b10011, 0b10001, 0b10001, 0b10001 }}, // n=N
    {{ 0b01110, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110 }}, // o=O
    {{ 0b11110, 0b10001, 0b10001, 0b11110, 0b10000, 0b10000, 0b10000 }}, // p=P
    {{ 0b01110, 0b10001, 0b10001, 0b10001, 0b10101, 0b10010, 0b01101 }}, // q=Q
    {{ 0b11110, 0b10001, 0b10001, 0b11110, 0b10100, 0b10010, 0b10001 }}, // r=R
    {{ 0b01110, 0b10001, 0b10000, 0b01110, 0b00001, 0b10001, 0b01110 }}, // s=S
    {{ 0b11111, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100 }}, // t=T
    {{ 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110 }}, // u=U
    {{ 0b10001, 0b10001, 0b10001, 0b10001, 0b01010, 0b01010, 0b00100 }}, // v=V
    {{ 0b10001, 0b10001, 0b10001, 0b10101, 0b10101, 0b11011, 0b10001 }}, // w=W
    {{ 0b10001, 0b01010, 0b00100, 0b00100, 0b00100, 0b01010, 0b10001 }}, // x=X
    {{ 0b10001, 0b01010, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100 }}, // y=Y
    {{ 0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b10000, 0b11111 }}, // z=Z
    // 123 '{'
    {{ 0b00110, 0b00100, 0b01000, 0b01000, 0b01000, 0b00100, 0b00110 }},
    // 124 '|'
    {{ 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100 }},
    // 125 '}'
    {{ 0b01100, 0b00100, 0b00010, 0b00010, 0b00010, 0b00100, 0b01100 }},
    // 126 '~'
    {{ 0b00000, 0b00000, 0b01000, 0b10101, 0b00010, 0b00000, 0b00000 }},
    // 127 DEL (blank)
    {{ 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000 }},
};

const BitmapGlyph &get_glyph(char ch)
{
	if (ch >= 'a' && ch <= 'z')
		ch = ch - 'a' + 'A';
	if (ch >= 32 && ch <= 127)
		return g_font[ch - 32];
	return g_font[0]; // space
}

int measure_text(const char *text, int scale)
{
	int len = (int)strlen(text);
	if (len == 0) return 0;
	return (len * GLYPH_W + (len - 1) * CHAR_SPACING) * scale;
}

void draw_text_rgba(std::vector<uint8_t> &pixels, uint32_t width, uint32_t height,
                    const char *text, int x0, int y0, int scale,
                    uint8_t r, uint8_t g, uint8_t b)
{
	int len = (int)strlen(text);
	for (int ci = 0; ci < len; ci++) {
		const BitmapGlyph &glyph = get_glyph(text[ci]);
		int cx = x0 + ci * (GLYPH_W + CHAR_SPACING) * scale;

		for (int gy = 0; gy < GLYPH_H; gy++) {
			uint8_t row = glyph.rows[gy];
			for (int gx = 0; gx < GLYPH_W; gx++) {
				if (row & (1 << (GLYPH_W - 1 - gx))) {
					for (int sy = 0; sy < scale; sy++) {
						for (int sx = 0; sx < scale; sx++) {
							int px = cx + gx * scale + sx;
							int py = y0 + gy * scale + sy;
							if (px >= 0 && px < (int)width && py >= 0 && py < (int)height) {
								uint32_t idx = ((uint32_t)py * width + (uint32_t)px) * 4;
								pixels[idx + 0] = r;
								pixels[idx + 1] = g;
								pixels[idx + 2] = b;
								pixels[idx + 3] = 255;
							}
						}
					}
				}
			}
		}
	}
}

void fill_rect_rgba(std::vector<uint8_t> &pixels, uint32_t width, uint32_t height,
                    int rx, int ry, int rw, int rh,
                    uint8_t r, uint8_t g, uint8_t b)
{
	for (int y = ry; y < ry + rh; y++) {
		for (int x = rx; x < rx + rw; x++) {
			if (x >= 0 && x < (int)width && y >= 0 && y < (int)height) {
				uint32_t idx = ((uint32_t)y * width + (uint32_t)x) * 4;
				pixels[idx + 0] = r;
				pixels[idx + 1] = g;
				pixels[idx + 2] = b;
				pixels[idx + 3] = 255;
			}
		}
	}
}

std::vector<uint8_t> generate_test_pattern_rgba(uint32_t width, uint32_t height,
                                                const std::string &camera_name,
                                                const std::string &camera_ip)
{
	std::vector<uint8_t> pixels(width * height * 4);

	// 75% SMPTE color bars (R, G, B)
	const uint8_t bars[7][3] = {
		{191, 191, 191},  // White 75%
		{191, 191,   0},  // Yellow
		{  0, 191, 191},  // Cyan
		{  0, 191,   0},  // Green
		{191,   0, 191},  // Magenta
		{191,   0,   0},  // Red
		{  0,   0, 191},  // Blue
	};

	// Castellation row colors (reverse/complement bars)
	const uint8_t cast[7][3] = {
		{  0,   0, 191},  // Blue
		{  0,   0,   0},  // Black
		{191,   0, 191},  // Magenta
		{  0,   0,   0},  // Black
		{  0, 191, 191},  // Cyan
		{  0,   0,   0},  // Black
		{191, 191, 191},  // White
	};

	uint32_t bar_bottom = height * 2 / 3;
	uint32_t cast_bottom = bar_bottom + height / 12;

	auto set_pixel = [&](uint32_t x, uint32_t y, uint8_t r, uint8_t g, uint8_t b) {
		uint32_t idx = (y * width + x) * 4;
		pixels[idx + 0] = r;
		pixels[idx + 1] = g;
		pixels[idx + 2] = b;
		pixels[idx + 3] = 255;
	};

	for (uint32_t y = 0; y < height; y++) {
		for (uint32_t x = 0; x < width; x++) {
			if (y < bar_bottom) {
				int bar_idx = (int)(x * 7 / width);
				if (bar_idx > 6) bar_idx = 6;
				set_pixel(x, y, bars[bar_idx][0], bars[bar_idx][1], bars[bar_idx][2]);
			} else if (y < cast_bottom) {
				int bar_idx = (int)(x * 7 / width);
				if (bar_idx > 6) bar_idx = 6;
				set_pixel(x, y, cast[bar_idx][0], cast[bar_idx][1], cast[bar_idx][2]);
			} else {
				set_pixel(x, y, 40, 40, 40);
			}
		}
	}

	// --- Camera name overlay in top bar area (truncate to fit) ---
	if (!camera_name.empty()) {
		const int name_scale = 4;
		const int max_name_chars = (int)width / ((GLYPH_W + CHAR_SPACING) * name_scale);
		std::string truncated_name = camera_name.length() > (size_t)max_name_chars
			? camera_name.substr(0, max_name_chars - 1) + "~"
			: camera_name;
		int name_w = measure_text(truncated_name.c_str(), name_scale);
		int name_h = GLYPH_H * name_scale;
		int pad = 10;
		int rect_w = name_w + pad * 2;
		int rect_h = name_h + pad * 2;
		int rect_x = ((int)width - rect_w) / 2;
		int rect_y = (int)(bar_bottom / 4) - rect_h / 2;  // ~25% from top
		if (rect_y < 0) rect_y = 4;

		fill_rect_rgba(pixels, width, height, rect_x, rect_y, rect_w, rect_h, 0, 0, 0);
		draw_text_rgba(pixels, width, height, truncated_name.c_str(),
		               rect_x + pad, rect_y + pad, name_scale, 255, 255, 255);
	}

	// --- "NO SIGNAL" text centered in bottom section ---
	{
		const char *no_signal = "NO SIGNAL";
		const int ns_scale = 6;
		int ns_w = measure_text(no_signal, ns_scale);
		int ns_h = GLYPH_H * ns_scale;
		int bottom_top = (int)cast_bottom;
		int bottom_h = (int)height - bottom_top;

		// Vertical layout: center "NO SIGNAL" (+ optional IP) as a group
		int total_h = ns_h;
		int ip_scale = 3;
		int ip_h = 0;
		int gap = 8;
		if (!camera_ip.empty()) {
			ip_h = GLYPH_H * ip_scale;
			total_h += gap + ip_h;
		}

		int group_y0 = bottom_top + (bottom_h - total_h) / 2;
		int ns_x = ((int)width - ns_w) / 2;
		draw_text_rgba(pixels, width, height, no_signal, ns_x, group_y0, ns_scale,
		               255, 255, 255);

		// IP address below "NO SIGNAL" in light gray
		if (!camera_ip.empty()) {
			int ip_w = measure_text(camera_ip.c_str(), ip_scale);
			int ip_x = ((int)width - ip_w) / 2;
			int ip_y = group_y0 + ns_h + gap;
			draw_text_rgba(pixels, width, height, camera_ip.c_str(),
			               ip_x, ip_y, ip_scale, 160, 160, 160);
		}
	}

	return pixels;
}

} // namespace avolocam
