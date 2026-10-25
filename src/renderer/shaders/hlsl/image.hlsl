#include "common.hlsli"

//-------------------------------------------------------------------
// Image Shader
//-------------------------------------------------------------------

// The image being drawn. Bound to the PS only (see slots.zig).
Texture2D<float4> image : register(t0);

// Attribute i is bound to the semantic TEXCOORD<i>, matching the
// DXGI formats of the CPU-side `Image`.
struct ImageVertexIn {
  // The grid coordinates (x, y) where x < columns and y < rows where
  // the image will be rendered. It will be rendered from the top left.
  float2 grid_pos : TEXCOORD0;

  // Offset in pixels from the top-left of the cell to make the top-left
  // corner of the image.
  float2 cell_offset : TEXCOORD1;

  // The source rectangle of the texture to sample from.
  float4 source_rect : TEXCOORD2;

  // The final width/height of the image in pixels.
  float2 dest_size : TEXCOORD3;
};

struct ImageVertexOut {
  float4 position : SV_Position;
  float2 tex_coord : TEXCOORD0;
};

ImageVertexOut image_vs(
  uint vid : SV_VertexID,
  ImageVertexIn input
) {
  // We use a triangle strip with 4 vertices to render quads,
  // so we determine which corner of the cell this vertex is in
  // based on the vertex ID.
  //
  //   0 --> 1
  //   |   .'|
  //   |  /  |
  //   | L   |
  //   2 --> 3
  //
  // 0 = top-left  (0, 0)
  // 1 = top-right (1, 0)
  // 2 = bot-left  (0, 1)
  // 3 = bot-right (1, 1)
  float2 corner;
  corner.x = float(vid == 1 || vid == 3);
  corner.y = float(vid == 2 || vid == 3);

  // The texture coordinates start at our source x/y
  // and add the width/height depending on the corner.
  //
  // These are in pixels, the pixel shader normalizes them.
  float2 tex_coord = input.source_rect.xy;
  tex_coord += input.source_rect.zw * corner;

  ImageVertexOut output;

  // The position of our image starts at the top-left of the grid cell and
  // adds the source rect width/height components.
  float2 image_pos = (cell_size * input.grid_pos) + input.cell_offset;
  image_pos += input.dest_size * corner;

  output.position =
      mul(projection_matrix, float4(image_pos.x, image_pos.y, 0.0f, 1.0f));
  output.tex_coord = tex_coord;
  return output;
}

float4 image_ps(ImageVertexOut input) : SV_Target0 {
  // The sampler (linear, clamp to edge) takes normalized coordinates but
  // ours are in pixels.
  float2 tex_size;
  image.GetDimensions(tex_size.x, tex_size.y);

  float4 rgba = image.Sample(linear_clamp, input.tex_coord / tex_size);

  if (!uniform_use_linear_blending()) {
    rgba = unlinearize(rgba);
  }

  rgba.rgb *= rgba.a;

  return rgba;
}
