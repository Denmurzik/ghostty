// Shared declarations for the builtin HLSL shaders (SM 5.0), ported 1:1 from
// shaders.metal. D3D11 is Y-down like Metal, so no flips are needed.
//
// This file is the single source of the register map. It is mirrored by
// src/renderer/d3d11/slots.zig, which RenderPass binds from:
//
//   b1                  Globals, VS + PS
//   t0, t1              cell_text.hlsl: glyph atlases (grayscale, color), PS only
//   t0                  image.hlsl, bg_image.hlsl: the image, PS only
//   t4                  bg_cells, VS + PS (buffers[i >= 1] -> t(3 + i))
//   s0                  linear clamp sampler, PS only
//
// Vertex inputs use the semantic TEXCOORD<i> for attribute location i.

#ifndef GHOSTTY_COMMON_HLSLI
#define GHOSTTY_COMMON_HLSLI

//-------------------------------------------------------------------
// Uniforms
//-------------------------------------------------------------------

// Must match `Uniforms` in src/renderer/d3d11/shaders.zig byte for byte.
// Every member has an explicit packoffset; the packed members hold the
// little-endian bytes of the CPU-side u16/u8 vectors and are unpacked with
// the accessors below.
cbuffer Globals : register(b1) {
  column_major float4x4 projection_matrix : packoffset(c0);
  float2 screen_size : packoffset(c4.x);
  float2 cell_size : packoffset(c4.z);
  uint grid_size_packed : packoffset(c5.x);     // ushort2
  float4 grid_padding : packoffset(c6);
  uint padding_extend : packoffset(c7.x);
  float min_contrast : packoffset(c7.y);
  uint cursor_pos_packed : packoffset(c7.z);    // ushort2
  uint cursor_color_packed : packoffset(c7.w);  // uchar4
  uint bg_color_packed : packoffset(c8.x);      // uchar4
  uint bools_packed : packoffset(c8.y);
};

static const uint EXTEND_LEFT = 1u;
static const uint EXTEND_RIGHT = 2u;
static const uint EXTEND_UP = 4u;
static const uint EXTEND_DOWN = 8u;

static const uint BOOL_CURSOR_WIDE = 1u;
static const uint BOOL_USE_DISPLAY_P3 = 2u;
static const uint BOOL_USE_LINEAR_BLENDING = 4u;
static const uint BOOL_USE_LINEAR_CORRECTION = 8u;
static const uint BOOL_COMPOSITION = 16u;

uint2 unpack_ushort2(uint v) {
  return uint2(v & 0xFFFFu, v >> 16);
}

uint4 unpack_uchar4(uint v) {
  return uint4(v & 0xFFu, (v >> 8) & 0xFFu, (v >> 16) & 0xFFu, v >> 24);
}

int2 uniform_grid_size() { return int2(unpack_ushort2(grid_size_packed)); }
uint2 uniform_cursor_pos() { return unpack_ushort2(cursor_pos_packed); }
uint4 uniform_cursor_color() { return unpack_uchar4(cursor_color_packed); }
uint4 uniform_bg_color() { return unpack_uchar4(bg_color_packed); }
bool uniform_cursor_wide() { return (bools_packed & BOOL_CURSOR_WIDE) != 0u; }
bool uniform_use_display_p3() { return (bools_packed & BOOL_USE_DISPLAY_P3) != 0u; }
bool uniform_use_linear_blending() { return (bools_packed & BOOL_USE_LINEAR_BLENDING) != 0u; }
bool uniform_use_linear_correction() { return (bools_packed & BOOL_USE_LINEAR_CORRECTION) != 0u; }
bool uniform_composition() { return (bools_packed & BOOL_COMPOSITION) != 0u; }

//-------------------------------------------------------------------
// Resources
//-------------------------------------------------------------------

// Per-cell background colors, one RGBA8 value (R in the low byte) per cell.
StructuredBuffer<uint> bg_cells : register(t4);

// Linear filtering, clamp to edge, normalized coordinates. Used by the
// image shader. Texture registers (t0..t2) are declared by each shader file
// that uses them, since the texture bound there differs per pipeline.
SamplerState linear_clamp : register(s0);

//-------------------------------------------------------------------
// Color Functions
//-------------------------------------------------------------------

// D50-adapted sRGB to XYZ conversion matrix.
// http://www.brucelindbloom.com/Eqn_RGB_XYZ_Matrix.html
//
// HLSL matrix constructors fill row by row, so unlike the Metal source
// no transpose is needed to get the matrix as written.
static const float3x3 sRGB_XYZ = float3x3(
  0.4360747, 0.3850649, 0.1430804,
  0.2225045, 0.7168786, 0.0606169,
  0.0139322, 0.0971045, 0.7141733
);
// XYZ to Display P3 conversion matrix.
// http://endavid.com/index.php?entry=79
static const float3x3 XYZ_DP3 = float3x3(
  2.40414768,-0.99010704,-0.39759019,
 -0.84239098, 1.79905954, 0.01597023,
  0.04838763,-0.09752546, 1.27393636
);
// By composing the two above matrices we get
// our sRGB to Display P3 conversion matrix.
static const float3x3 sRGB_DP3 = mul(XYZ_DP3, sRGB_XYZ);

// Converts a color in linear sRGB to linear Display P3
float3 srgb_to_display_p3(float3 srgb) {
  return mul(sRGB_DP3, srgb);
}

// Converts a color from sRGB gamma encoding to linear.
float4 linearize(float4 srgb) {
  bool3 cutoff = srgb.rgb <= 0.04045;
  float3 lower = srgb.rgb / 12.92;
  float3 higher = pow((srgb.rgb + 0.055) / 1.055, 2.4);
  srgb.rgb = lerp(higher, lower, float3(cutoff));

  return srgb;
}
float linearize(float v) {
  return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4);
}

// Converts a color from linear to sRGB gamma encoding.
float4 unlinearize(float4 lin) {
  bool3 cutoff = lin.rgb <= 0.0031308;
  float3 lower = lin.rgb * 12.92;
  float3 higher = pow(lin.rgb, 1.0 / 2.4) * 1.055 - 0.055;
  lin.rgb = lerp(higher, lower, float3(cutoff));

  return lin;
}
float unlinearize(float v) {
  return v <= 0.0031308 ? v * 12.92 : pow(v, 1.0 / 2.4) * 1.055 - 0.055;
}

// Compute the luminance of the provided color.
//
// Takes colors in linear RGB space. If your colors are gamma
// encoded, linearize them before using them with this function.
float luminance(float3 color) {
  return dot(color, float3(0.2126f, 0.7152f, 0.0722f));
}

// https://www.w3.org/TR/2008/REC-WCAG20-20081211/#contrast-ratiodef
//
// Takes colors in linear RGB space. If your colors are gamma
// encoded, linearize them before using them with this function.
float contrast_ratio(float3 color1, float3 color2) {
  float l1 = luminance(color1);
  float l2 = luminance(color2);
  return (max(l1, l2) + 0.05f) / (min(l1, l2) + 0.05f);
}

// Return the fg if the contrast ratio is greater than min_ratio, otherwise
// return a color that satisfies the contrast ratio. Currently, the color
// is always white or black, whichever has the highest contrast ratio.
//
// Takes colors in linear RGB space. If your colors are gamma
// encoded, linearize them before using them with this function.
float4 contrasted_color(float min_ratio, float4 fg, float4 bg) {
  float ratio = contrast_ratio(fg.rgb, bg.rgb);
  if (ratio < min_ratio) {
    float white_ratio = contrast_ratio(float3(1.0f, 1.0f, 1.0f), bg.rgb);
    float black_ratio = contrast_ratio(float3(0.0f, 0.0f, 0.0f), bg.rgb);
    if (white_ratio > black_ratio) {
      return float4(1.0f, 1.0f, 1.0f, 1.0f);
    } else {
      return float4(0.0f, 0.0f, 0.0f, 1.0f);
    }
  }

  return fg;
}

// Load a 4 byte RGBA non-premultiplied color and linearize it if needed.
//
// Unlike Metal, whose layer is always Display P3, the D3D11 back buffer is
// plain sRGB, so (like the GLSL shaders) no color space conversion happens:
// `display_p3` is accepted to keep the Metal call shape and the uniform
// layout, and ignored. Both color spaces use the sRGB transfer function.
//
// `is_linear` controls whether the returned color is linear or gamma encoded.
float4 load_color(
  uint4 in_color,
  bool display_p3,
  bool is_linear
) {
  // 0 .. 255 -> 0.0 .. 1.0
  float4 color = float4(in_color) / 255.0f;

  // Linearize if necessary.
  if (is_linear) {
    color = linearize(color);
  }

  // Premultiply our color by its alpha.
  color.rgb *= color.a;

  return color;
}

// Like `load_color`, for the layers whose alpha reaches DWM: the background
// colour and the cell backgrounds. A composition chain is blended by DWM on
// the stored sRGB bytes, which must hold the premultiplied sRGB colour:
// premultiply the encoded colour, then linearize the product so that the
// hardware's encode on write gives it back. Everything else (text, cursor,
// faint text, images, colour glyphs, `background-image` opacity, custom shader
// post passes) keeps `load_color`'s linear premultiply.
float4 load_bg_color(
  uint4 in_color,
  bool display_p3,
  bool is_linear
) {
  if (is_linear && uniform_composition()) {
    float4 color = float4(in_color) / 255.0f;
    color.rgb *= color.a;
    color.rgb = linearize(float4(color.rgb, 1.0)).rgb;
    return color;
  }
  return load_color(in_color, display_p3, is_linear);
}

//-------------------------------------------------------------------
// Full Screen Triangle
//-------------------------------------------------------------------

// Single triangle clipped to the viewport, drawn with 3 vertices.
//
//   X <- vid == 0: (-1, -3)
//   |\
//   | \
//   |  \
//   |###\
//   |#+# \ `+` is (0, 0). `#`s are viewport area.
//   |###  \
//   X------X <- vid == 2: (3, 1)
//   ^
//   vid == 1: (-1, 1)
float4 full_screen_position(uint vid) {
  float4 position;
  position.x = (vid == 2) ? 3.0 : -1.0;
  position.y = (vid == 0) ? -3.0 : 1.0;
  position.zw = 1.0;
  return position;
}

#endif // GHOSTTY_COMMON_HLSLI
