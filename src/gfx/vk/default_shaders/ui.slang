struct UiData {
  float4 rect;
  float4 uv;
  float4 color;
  float4 borderColor;
  float edge;
  float borderEdge;
  uint textureId;
  uint primitive;
  float blur;
  float3 _pad;
  float4 cornerRadius;
};

struct PushConstants {
  UiData *uiData;
  float2 screenSize;
};

[[vk::push_constant]]
PushConstants pc;

struct VSOutput {
  float4 pos : SV_Position;
  float4 color;
  float4 borderColor;
  float2 uv;
  nointerpolation uint textureId : DATA0;
  nointerpolation uint primitive : DATA1;
  nointerpolation float edge : DATA2;
  nointerpolation float borderEdge : DATA3;
  nointerpolation float blur : DATA4;
  nointerpolation float4 cornerRadius : DATA5;
  nointerpolation float2 rectSize : DATA6;
  float2 localPos : DATA7;
};

[shader("vertex")]
VSOutput vertMain(uint vertexID: SV_VertexID, uint instanceID: SV_InstanceID) {
  UiData ui = pc.uiData[instanceID];

  float2 positions[6] = { float2(0.0, 0.0), float2(1.0, 0.0),
                          float2(0.0, 1.0), float2(1.0, 0.0),
                          float2(1.0, 1.0), float2(0.0, 1.0) };

  float2 localPos = positions[vertexID];
  float2 screenPos = ui.rect.xy + localPos * ui.rect.zw;
  float2 ndcPos = (screenPos / pc.screenSize) * 2.0 - 1.0;

  float2 uvPos = float2(lerp(ui.uv.x, ui.uv.z, localPos.x),
                        lerp(ui.uv.y, ui.uv.w, localPos.y));

  VSOutput output;
  output.pos = float4(ndcPos, 0.0, 1.0);
  output.color = ui.color;
  output.borderColor = ui.borderColor;
  output.uv = uvPos;
  output.textureId = ui.textureId;
  output.primitive = ui.primitive;
  output.edge = ui.edge;
  output.borderEdge = ui.borderEdge;
  output.blur = ui.blur;
  output.cornerRadius = ui.cornerRadius;
  output.rectSize = ui.rect.zw;
  output.localPos = localPos;

  return output;
}

[[vk::binding(0, 0)]]
Sampler2D textures[];

[shader("fragment")]
float4 fragMain(VSOutput vertIn) : SV_TARGET {
  if (vertIn.primitive == 0) {
    float2 halfSize = vertIn.rectSize * 0.5;
	float2 p = (vertIn.localPos - 0.5) * vertIn.rectSize;
	float r = (p.x > 0.0) ? ((p.y > 0.0) ? vertIn.cornerRadius.z : vertIn.cornerRadius.y) : ((p.y > 0.0) ? vertIn.cornerRadius.w : vertIn.cornerRadius.x);
	r = min(r, min(halfSize.x, halfSize.y));
	float2 q = abs(p) - halfSize + r;
	float dist = min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;

	float smoothing = fwidth(dist) * (1.0 + vertIn.blur);
	float totalAlpha = smoothstep(smoothing, -smoothing, dist);
	float innerDist = dist + vertIn.edge;
	float fillAlpha = smoothstep(smoothing, -smoothing, innerDist);

	float4 finalColor = lerp(vertIn.borderColor, vertIn.color, fillAlpha);
	return float4(finalColor.rgb, finalColor.a * totalAlpha);
  } else {
    float dist = textures[vertIn.textureId].Sample(vertIn.uv).r;

    float smoothing = fwidth(dist) * (1.0 + vertIn.blur);
	float totalAlpha = smoothstep(vertIn.borderEdge - smoothing, vertIn.borderEdge + smoothing, dist);
    float textAlpha = smoothstep(vertIn.edge - smoothing, vertIn.edge + smoothing, dist);
	float4 finalColor = lerp(vertIn.borderColor, vertIn.color, textAlpha);

    return float4(finalColor.rgb, finalColor.a*totalAlpha);
  }
}
