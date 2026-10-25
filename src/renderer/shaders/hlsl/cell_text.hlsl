#include "common.hlsli"

//-------------------------------------------------------------------
// Cell Text Shader
//-------------------------------------------------------------------

static const uint ATLAS_GRAYSCALE = 0u;
static const uint ATLAS_COLOR = 1u;

// We use a packed struct of bools for misc properties of the glyph.
// Don't apply min contrast to this glyph.
static const uint NO_MIN_CONTRAST = 1u;
// This is the cursor glyph.
static const uint IS_CURSOR_GLYPH = 2u;

// Attribute i is bound to the semantic TEXCOORD<i>. The integer types match
// the DXGI formats of the CPU-side `CellText`.
struct CellTextVertexIn {
  // The position of the glyph in the texture (x, y)
  uint2 glyph_pos : TEXCOORD0;

  // The size of the glyph in the texture (w, h)
  uint2 glyph_size : TEXCOORD1;

  // The left and top bearings for the glyph (x, y)
  int2 bearings : TEXCOORD2;

  // The grid coordinates (x, y) where x < columns and y < rows
  uint2 grid_pos : TEXCOORD3;

  // The color of the rendered text glyph.
  uint4 color : TEXCOORD4;

  // Which atlas to sample for our glyph.
  uint atlas : TEXCOORD5;

  // Misc properties of the glyph.
  uint bools : TEXCOORD6;
};

struct CellTextVertexOut {
  float4 position : SV_Position;
  nointerpolation uint atlas : ATLAS;
  nointerpolation float4 color : COLOR0;
  nointerpolation float4 bg_color : COLOR1;
  float2 tex_coord : TEXCOORD0;
};

CellTextVertexOut cell_text_vs(
  uint vid : SV_VertexID,
  CellTextVertexIn input
) {
  int2 grid_size = uniform_grid_size();
  uint2 cursor_pos = uniform_cursor_pos();

  // Convert the grid x, y into world space x, y by accounting for cell size
  float2 cell_pos = cell_size * float2(input.grid_pos);

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

  CellTextVertexOut output;
  output.atlas = input.atlas;

  //              === Grid Cell ===
  //      +X
  // 0,0--...->
  //   |
  //   . offset.x = bearings.x
  // +Y.               .|.
  //   .               | |
  //   |   cell_pos -> +-------+   _.
  //   v             ._|       |_. _|- offset.y = cell_size.y - bearings.y
  //                 | | .###. | |
  //                 | | #...# | |
  //   glyph_size.y -+ | ##### | |
  //                 | | #.... | +- bearings.y
  //                 |_| .#### | |
  //                   |       |_|
  //                   +-------+
  //                     |_._|
  //                       |
  //                  glyph_size.x
  //
  // In order to get the top left of the glyph, we compute an offset based on
  // the bearings. The Y bearing is the distance from the bottom of the cell
  // to the top of the glyph, so we subtract it from the cell height to get
  // the y offset. The X bearing is the distance from the left of the cell
  // to the left of the glyph, so it works as the x offset directly.

  float2 size = float2(input.glyph_size);
  float2 offset = float2(input.bearings);

  offset.y = cell_size.y - offset.y;

  // Calculate the final position of the cell which uses our glyph size
  // and glyph offset to create the correct bounding box for the glyph.
  cell_pos = cell_pos + size * corner + offset;
  output.position =
      mul(projection_matrix, float4(cell_pos.x, cell_pos.y, 0.0f, 1.0f));

  // Calculate the texture coordinate in pixels. This is NOT normalized
  // (between 0.0 and 1.0), and does not need to be, since the atlases
  // are read with Load.
  output.tex_coord = float2(input.glyph_pos) + float2(input.glyph_size) * corner;

  // Get our color. We always fetch a linearized version to
  // make it easier to handle minimum contrast calculations.
  output.color = load_color(
    input.color,
    uniform_use_display_p3(),
    true
  );

  // Get the BG color
  output.bg_color = load_color(
    unpack_uchar4(bg_cells[input.grid_pos.y * grid_size.x + input.grid_pos.x]),
    uniform_use_display_p3(),
    true
  );
  // Blend it with the global bg color
  float4 global_bg = load_color(
    uniform_bg_color(),
    uniform_use_display_p3(),
    true
  );
  output.bg_color += global_bg * (1.0 - output.bg_color.a);

  // If we have a minimum contrast, we need to check if we need to
  // change the color of the text to ensure it has enough contrast
  // with the background.
  if (min_contrast > 1.0f && (input.bools & NO_MIN_CONTRAST) == 0u) {
    // Ensure our minimum contrast
    output.color = contrasted_color(min_contrast, output.color, output.bg_color);
  }

  // Check if current position is under cursor (including wide cursor)
  bool is_cursor_pos = (
      input.grid_pos.x == cursor_pos.x ||
      (uniform_cursor_wide() &&
        input.grid_pos.x == cursor_pos.x + 1)
    ) && input.grid_pos.y == cursor_pos.y;

  // If this cell is the cursor cell, but we're not processing
  // the cursor glyph itself, then we need to change the color.
  if ((input.bools & IS_CURSOR_GLYPH) == 0u && is_cursor_pos) {
    output.color = load_color(
      uniform_cursor_color(),
      uniform_use_display_p3(),
      true
    );
  }

  return output;
}

float4 cell_text_ps(CellTextVertexOut input) : SV_Target0 {
  bool use_linear_blending = uniform_use_linear_blending();

  if (input.atlas == ATLAS_COLOR) {
    // For now, we assume that color glyphs
    // are already premultiplied linear colors.
    float4 color = atlas_color.Load(int3(int2(input.tex_coord), 0));

    // If we're doing linear blending, we can return this right away.
    if (use_linear_blending) {
      return color;
    }

    // Otherwise we need to unlinearize the color. Since the alpha is
    // premultiplied, we need to divide it out before unlinearizing.
    color.rgb /= color.a;
    color = unlinearize(color);
    color.rgb *= color.a;

    return color;
  }

  // ATLAS_GRAYSCALE (and the default for unknown values).

  // Our input color is always linear.
  float4 color = input.color;

  // If we're not doing linear blending, then we need to
  // re-apply the gamma encoding to our color manually.
  //
  // Since the alpha is premultiplied, we need to divide
  // it out before unlinearizing and re-multiply it after.
  if (!use_linear_blending) {
    color.rgb /= color.a;
    color = unlinearize(color);
    color.rgb *= color.a;
  }

  // Fetch our alpha mask for this pixel.
  float a = atlas_grayscale.Load(int3(int2(input.tex_coord), 0));

  // Linear blending weight correction corrects the alpha value to
  // produce blending results which match gamma-incorrect blending.
  if (uniform_use_linear_correction()) {
    // Short explanation of how this works:
    //
    // We get the luminances of the foreground and background colors,
    // and then unlinearize them and perform blending on them. This
    // gives us our desired luminance, which we derive our new alpha
    // value from by mapping the range [bg_l, fg_l] to [0, 1], since
    // our final blend will be a linear interpolation from bg to fg.
    //
    // This yields virtually identical results for grayscale blending,
    // and very similar but non-identical results for color blending.
    float4 bg = input.bg_color;
    float fg_l = luminance(color.rgb);
    float bg_l = luminance(bg.rgb);
    // To avoid numbers going haywire, we don't apply correction
    // when the bg and fg luminances are within 0.001 of each other.
    if (abs(fg_l - bg_l) > 0.001) {
      float blend_l = linearize(unlinearize(fg_l) * a + unlinearize(bg_l) * (1.0 - a));
      a = clamp((blend_l - bg_l) / (fg_l - bg_l), 0.0, 1.0);
    }
  }

  // Multiply our whole color by the alpha mask.
  // Since we use premultiplied alpha, this is
  // the correct way to apply the mask.
  color *= a;

  return color;
}
