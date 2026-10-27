#include "common.hlsli"

//-------------------------------------------------------------------
// Cell Background Shader
//-------------------------------------------------------------------

float4 cell_bg_ps(float4 position : SV_Position) : SV_Target0 {
  int2 grid_size = uniform_grid_size();
  int2 grid_pos = int2(floor((position.xy - grid_padding.wx) / cell_size));

  float4 bg = float4(0.0, 0.0, 0.0, 0.0);

  // Clamp x position, extends edge bg colors in to padding on sides.
  if (grid_pos.x < 0) {
    if ((padding_extend & EXTEND_LEFT) != 0u) {
      grid_pos.x = 0;
    } else {
      return bg;
    }
  } else if (grid_pos.x > grid_size.x - 1) {
    if ((padding_extend & EXTEND_RIGHT) != 0u) {
      grid_pos.x = grid_size.x - 1;
    } else {
      return bg;
    }
  }

  // Clamp y position if we should extend, otherwise discard if out of bounds.
  if (grid_pos.y < 0) {
    if ((padding_extend & EXTEND_UP) != 0u) {
      grid_pos.y = 0;
    } else {
      return bg;
    }
  } else if (grid_pos.y > grid_size.y - 1) {
    if ((padding_extend & EXTEND_DOWN) != 0u) {
      grid_pos.y = grid_size.y - 1;
    } else {
      return bg;
    }
  }

  // Load the color for the cell.
  uint4 cell_color = unpack_uchar4(bg_cells[grid_pos.y * grid_size.x + grid_pos.x]);

  // Convert the color and return it.
  //
  // TODO: It might be a good idea to do a pass before this
  //       to convert all of the bg colors, so we don't waste
  //       a bunch of work converting the cell color in every
  //       fragment of each cell. It's not the most epxensive
  //       operation, but it is still wasted work.
  return load_bg_color(
    cell_color,
    uniform_use_display_p3(),
    uniform_use_linear_blending()
  );
}
