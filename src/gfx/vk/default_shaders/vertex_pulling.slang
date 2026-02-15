struct Vertex {
  float3 inPos;
  float _p1;
  float3 inColor;
  float _p2;
  float2 inTexCoord;
  float2 _p3;
};

struct ObjectData {
  float4x4 model;
  uint textureId;
  uint3 _pad;
};

struct CameraData {
  float4x4 view;
  float4x4 proj;
};

struct PushConstants {
  uint drawIdOffset;
};

[[vk::push_constant]]
PushConstants pc;

[[vk::binding(0, 0)]]
StructuredBuffer<Vertex> vertices;

[[vk::binding(1, 0)]]
ConstantBuffer<CameraData> camera;

[[vk::binding(2, 0)]]
StructuredBuffer<ObjectData> objects;

struct VSOutput {
  float4 pos : SV_Position;
  float3 fragColor;
  float2 fragTexCoord;
  nointerpolation uint textureId : DATA0;
};

[shader("vertex")]
VSOutput vertMain(uint index: SV_VertexID, uint drawIndex: SV_DrawIndex) {
  uint objectIndex = drawIndex + pc.drawIdOffset;
  Vertex input = vertices[index];
  float4x4 model = objects[objectIndex].model;

  VSOutput output;
  output.pos =
      mul(camera.proj, mul(camera.view, mul(model, float4(input.inPos, 1.0))));
  output.fragColor = input.inColor;
  output.fragTexCoord = input.inTexCoord;
  output.textureId = objects[objectIndex].textureId;

  return output;
}

[[vk::binding(3, 0)]]
Sampler2D textures[];

[shader("fragment")]
float4 fragMain(VSOutput vertIn) : SV_TARGET {

  return textures[vertIn.textureId].Sample(vertIn.fragTexCoord);
}
