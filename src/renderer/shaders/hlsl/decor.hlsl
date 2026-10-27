#include "common.hlsli"

//-------------------------------------------------------------------
// Decor Pixel Shader
//-------------------------------------------------------------------
//
// Drawn over the finished frame with full_screen_vs: the unfocused-split
// dim (a premultiplied colour over the whole target) and the bell border
// (a premultiplied colour over the outermost pixels).

cbuffer Decor : register(b2) {
  float4 dim : packoffset(c0);         // premultiplied
  float4 border : packoffset(c1);      // premultiplied
  float border_px : packoffset(c2.x);
  float is_linear : packoffset(c2.y);  // target views are *_SRGB
  float2 size : packoffset(c2.z);
};

float4 decor_ps(float4 position : SV_Position) : SV_Target0 {
  float4 result = dim;

  float2 edge = min(position.xy, size - position.xy);
  if (border.a > 0.0 && min(edge.x, edge.y) < border_px) {
    result = border + result * (1.0 - border.a);
  }

  // The colours are sRGB; an *_SRGB view encodes what is written to it.
  if (is_linear > 0.5 && result.a > 0.0) {
    float3 c = result.rgb / result.a;
    c = pow(max(c, 0.0), 2.2);
    result.rgb = c * result.a;
  }
  return result;
}
