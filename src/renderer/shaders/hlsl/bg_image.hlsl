#include "common.hlsli"

//-------------------------------------------------------------------
// Background Image Shader
//-------------------------------------------------------------------

// The image being drawn. Textures are bound to the PS only (see
// slots.zig), which is why the image size dependent layout is computed
// in the PS and not in the VS as the Metal source does. The results are
// identical because the inputs are the same for every pixel.
Texture2D<float4> image : register(t0);

// Bits of the `info` attribute.
static const uint BG_IMAGE_POSITION = 15u;

static const uint BG_IMAGE_TL = 0u;
static const uint BG_IMAGE_TC = 1u;
static const uint BG_IMAGE_TR = 2u;
static const uint BG_IMAGE_ML = 3u;
static const uint BG_IMAGE_MC = 4u;
static const uint BG_IMAGE_MR = 5u;
static const uint BG_IMAGE_BL = 6u;
static const uint BG_IMAGE_BC = 7u;
static const uint BG_IMAGE_BR = 8u;

// 2 bits of info shifted 4.
static const uint BG_IMAGE_FIT = 3u << 4;

static const uint BG_IMAGE_CONTAIN = 0u << 4;
static const uint BG_IMAGE_COVER = 1u << 4;
static const uint BG_IMAGE_STRETCH = 2u << 4;
static const uint BG_IMAGE_NO_FIT = 3u << 4;

// 1 bit of info shifted 6.
static const uint BG_IMAGE_REPEAT = 1u << 6;

// Attribute i is bound to the semantic TEXCOORD<i>, matching the
// DXGI formats of the CPU-side `BgImage`.
struct BgImageVertexIn {
  float opacity : TEXCOORD0;
  uint info : TEXCOORD1;
};

struct BgImageVertexOut {
  float4 position : SV_Position;
  nointerpolation float4 bg_color : COLOR0;
  nointerpolation float opacity : OPACITY;
  nointerpolation uint info : INFO;
};

BgImageVertexOut bg_image_vs(
  uint vid : SV_VertexID,
  BgImageVertexIn input
) {
  BgImageVertexOut output;

  // Single triangle is clipped to viewport.
  output.position = full_screen_position(vid);

  output.opacity = input.opacity;
  output.info = input.info;

  // We load a fully opaque version of the bg color and combine it with
  // the alpha separately, because we need these as separate values in
  // the pixel shader.
  uint4 bg = uniform_bg_color();
  output.bg_color = float4(load_color(
    uint4(bg.rgb, 255),
    uniform_use_display_p3(),
    uniform_use_linear_blending()
  ).rgb, float(bg.a) / 255.0);

  return output;
}

float4 load_or_zero(int2 coord, int2 tex_size) {
  if (any(coord < 0) || any(coord >= tex_size)) return float4(0.0, 0.0, 0.0, 0.0);
  return image.Load(int3(coord, 0));
}

// Bilinear sample at a pixel coordinate (texel centers at +0.5) where
// anything outside of the texture is transparent black, which is what the
// Metal sampler does with `address::clamp_to_zero`. The linear-clamp sampler
// cannot do this, so the four texels are fetched and blended by hand.
float4 sample_clamp_to_zero(float2 pixel, int2 tex_size) {
  float2 p = pixel - 0.5;
  float2 base = floor(p);
  float2 f = p - base;
  int2 i = int2(base);

  float4 t00 = load_or_zero(i, tex_size);
  float4 t10 = load_or_zero(i + int2(1, 0), tex_size);
  float4 t01 = load_or_zero(i + int2(0, 1), tex_size);
  float4 t11 = load_or_zero(i + int2(1, 1), tex_size);

  return lerp(lerp(t00, t10, f.x), lerp(t01, t11, f.x), f.y);
}

float4 bg_image_ps(BgImageVertexOut input) : SV_Target0 {
  uint info = input.info;

  float2 tex_size;
  image.GetDimensions(tex_size.x, tex_size.y);

  float2 dest_size = tex_size;
  switch (info & BG_IMAGE_FIT) {
    // For `contain` we scale by a factor that makes the image
    // width match the screen width or makes the image height
    // match the screen height, whichever is smaller.
    case BG_IMAGE_CONTAIN: {
      float scale = min(screen_size.x / tex_size.x, screen_size.y / tex_size.y);
      dest_size = tex_size * scale;
    } break;

    // For `cover` we scale by a factor that makes the image
    // width match the screen width or makes the image height
    // match the screen height, whichever is larger.
    case BG_IMAGE_COVER: {
      float scale = max(screen_size.x / tex_size.x, screen_size.y / tex_size.y);
      dest_size = tex_size * scale;
    } break;

    // For `stretch` we stretch the image to the size of
    // the screen without worrying about aspect ratio.
    case BG_IMAGE_STRETCH: {
      dest_size = screen_size;
    } break;

    // For `none` we just use the original texture size.
    case BG_IMAGE_NO_FIT: {
      dest_size = tex_size;
    } break;
  }

  float2 start = float2(0.0, 0.0);
  float2 mid = (screen_size - dest_size) / 2;
  float2 end = screen_size - dest_size;

  float2 dest_offset = mid;
  switch (info & BG_IMAGE_POSITION) {
    case BG_IMAGE_TL: {
      dest_offset = float2(start.x, start.y);
    } break;
    case BG_IMAGE_TC: {
      dest_offset = float2(mid.x, start.y);
    } break;
    case BG_IMAGE_TR: {
      dest_offset = float2(end.x, start.y);
    } break;
    case BG_IMAGE_ML: {
      dest_offset = float2(start.x, mid.y);
    } break;
    case BG_IMAGE_MC: {
      dest_offset = float2(mid.x, mid.y);
    } break;
    case BG_IMAGE_MR: {
      dest_offset = float2(end.x, mid.y);
    } break;
    case BG_IMAGE_BL: {
      dest_offset = float2(start.x, end.y);
    } break;
    case BG_IMAGE_BC: {
      dest_offset = float2(mid.x, end.y);
    } break;
    case BG_IMAGE_BR: {
      dest_offset = float2(end.x, end.y);
    } break;
  }

  float2 scale = tex_size / dest_size;

  // Our texture coordinate is based on the screen position, offset by the
  // dest rect origin, and scaled by the ratio between the dest rect size
  // and the original texture size, which effectively scales the original
  // size of the texture to the dest rect size.
  float2 tex_coord = (input.position.xy - dest_offset) * scale;

  // If we need to repeat the texture, wrap the coordinates.
  if ((info & BG_IMAGE_REPEAT) == BG_IMAGE_REPEAT) {
    tex_coord = fmod(fmod(tex_coord, tex_size) + tex_size, tex_size);
  }

  float4 rgba = sample_clamp_to_zero(tex_coord, int2(tex_size));

  if (!uniform_use_linear_blending()) {
    rgba = unlinearize(rgba);
  }

  // Premultiply the bg image.
  rgba.rgb *= rgba.a;

  // Multiply it by the configured opacity, but cap it at
  // the value that will make it fully opaque relative to
  // the background color alpha, so it isn't overexposed.
  rgba *= min(input.opacity, 1.0 / input.bg_color.a);

  // Blend it on to a fully opaque version of the background color.
  rgba += max(float4(0.0, 0.0, 0.0, 0.0), float4(input.bg_color.rgb, 1.0) * (1.0 - rgba.a));

  // Multiply everything by the background color alpha.
  rgba *= input.bg_color.a;

  return rgba;
}
