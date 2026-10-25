#include "common.hlsli"

//-------------------------------------------------------------------
// Full Screen Vertex Shader
//-------------------------------------------------------------------

struct FullScreenVertexOut {
  float4 position : SV_Position;
};

FullScreenVertexOut full_screen_vs(uint vid : SV_VertexID) {
  FullScreenVertexOut output;
  output.position = full_screen_position(vid);
  return output;
}
