/**
 * test-pattern.h - SMPTE "No Signal" test pattern generator
 *
 * Generates a classic SMPTE-style color bar test pattern with
 * camera name overlay and "NO SIGNAL" text in RGBA format.
 */

#pragma once

#include <cstdint>
#include <string>
#include <vector>

namespace avolocam {

// Bitmap font: 5x7 pixel glyphs covering A-Z, 0-9, and common punctuation.
// Each character is represented as 7 rows of 5-bit patterns.
struct BitmapGlyph {
	uint8_t rows[7];
};

// Glyph dimensions (pixels)
static const int GLYPH_W = 5;
static const int GLYPH_H = 7;
static const int CHAR_SPACING = 1; // 1 pixel gap between characters (at glyph scale)

// Get glyph for a character, returns space glyph for unsupported chars.
// Lowercase a-z is rendered as uppercase A-Z.
const BitmapGlyph &get_glyph(char ch);

// Measure text width in pixels at given scale.
int measure_text(const char *text, int scale);

// Draw text into an RGBA pixel buffer.
void draw_text_rgba(std::vector<uint8_t> &pixels, uint32_t width, uint32_t height,
                    const char *text, int x0, int y0, int scale,
                    uint8_t r, uint8_t g, uint8_t b);

// Draw a filled rectangle into an RGBA pixel buffer.
void fill_rect_rgba(std::vector<uint8_t> &pixels, uint32_t width, uint32_t height,
                    int rx, int ry, int rw, int rh,
                    uint8_t r, uint8_t g, uint8_t b);

/**
 * Generate a classic SMPTE-style test pattern in RGBA with camera info.
 *
 * Layout:
 *   Top 2/3:    7 color bars at 75% with camera name in black rect overlay
 *   Mid strip:  Castellations (blue, black, magenta, black, cyan, black, white)
 *   Bottom 1/4: Dark gray background with "NO SIGNAL" + optional IP
 */
std::vector<uint8_t> generate_test_pattern_rgba(uint32_t width, uint32_t height,
                                                const std::string &camera_name,
                                                const std::string &camera_ip);

} // namespace avolocam
