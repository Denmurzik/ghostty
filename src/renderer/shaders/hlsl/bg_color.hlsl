#include "common.hlsli"

//-------------------------------------------------------------------
// Background Color Shader
//-------------------------------------------------------------------

float4 bg_color_ps(float4 position : SV_Position) : SV_Target0 {
  return load_color(
    uniform_bg_color(),
    uniform_use_display_p3(),
    uniform_use_linear_blending()
  );
}
