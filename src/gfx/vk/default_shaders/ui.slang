struct UiData {
	float4 rect;
	float4 uv;
	float4 color;
	float4 borderColor;
	float edge;
	float borderEdge;
	uint textureId;
	uint primitive;
	float softness;
	float3 _pad;
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
	nointerpolation float2 rectSize : DATA4;
	float2 shapePos : DATA5;
	nointerpolation float softness : DATA6;
	nointerpolation float4 cornerRadius : DATA7;
};

float roundedRectangle(float2 p, float2 size, float4 cornerRadius) {
	float2 halfSize = size * 0.5;
	float2 centerP = p - halfSize;

	float2 r = (centerP.x > 0.0) ? cornerRadius.yz : cornerRadius.xw;
	float radius = (centerP.y > 0.0) ? r.y : r.x;

	float2 q = abs(centerP) - halfSize + radius;
	return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - radius;
}

[shader("vertex")]
VSOutput vertMain(uint vertexID: SV_VertexID, uint instanceID: SV_InstanceID) {
	UiData ui = pc.uiData[instanceID];

	float2 positions[6] = { 
		float2(0.0, 0.0), float2(1.0, 0.0),
		float2(0.0, 1.0), float2(1.0, 0.0),
		float2(1.0, 1.0), float2(0.0, 1.0) 
	};

	float2 localPos = positions[vertexID];

	float pad = ui.softness + 2.0;
	float2 expandedSize = ui.rect.zw + float2(pad * 2.0);

	float2 screenPos = (ui.rect.xy - float2(pad)) + localPos * expandedSize;
	float2 ndcPos = (screenPos / pc.screenSize) * 2.0 - 1.0;
	float2 shapePos = localPos * expandedSize - float2(pad);

	float2 unpaddedNormPos = shapePos / ui.rect.zw;
	float2 uvPos = float2(
		lerp(ui.uv.x, ui.uv.z, unpaddedNormPos.x),
		lerp(ui.uv.y, ui.uv.w, unpaddedNormPos.y)
	);

	VSOutput output;
	output.pos = float4(ndcPos, 0.0, 1.0);
	output.color = ui.color;
	output.borderColor = ui.borderColor;
	output.uv = uvPos;
	output.textureId = ui.textureId;
	output.primitive = ui.primitive;
	output.edge = ui.edge;
	output.borderEdge = ui.borderEdge;
	output.rectSize = ui.rect.zw;
	output.shapePos = shapePos;
	output.softness = ui.softness;
	output.cornerRadius = ui.uv;

	return output;
}

[[vk::binding(0, 0)]]
Sampler2D textures[];

[shader("fragment")]
float4 fragMain(VSOutput vertIn) : SV_TARGET {
	if (vertIn.primitive == 0) {
		float4 adjustedRadius = max(vertIn.cornerRadius + vertIn.softness, 0.0);
		float dist = roundedRectangle(vertIn.shapePos, vertIn.rectSize, adjustedRadius);
		float smoothing = fwidth(dist) + vertIn.softness;
		
		float shapeAlpha = 1.0 - smoothstep(-smoothing, smoothing, dist);
		float innerAlpha = 1.0 - smoothstep(-smoothing, smoothing, dist + vertIn.edge);

		float4 finalColor = lerp(vertIn.borderColor, vertIn.color, innerAlpha);

		return float4(finalColor.rgb, finalColor.a * shapeAlpha);
	} else {
		float dist = textures[vertIn.textureId].Sample(vertIn.uv).r;
		float smoothing = vertIn.softness;
		
		float totalAlpha = smoothstep(vertIn.borderEdge - smoothing, vertIn.borderEdge + smoothing, dist);
		float textAlpha = smoothstep(0.5 - smoothing, 0.5 + smoothing, dist);
		float4 finalColor = lerp(vertIn.borderColor, vertIn.color, textAlpha);

		return float4(finalColor.rgb, finalColor.a * totalAlpha);
	}
}
