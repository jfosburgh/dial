struct Vertex {
  float3 inPos;
  float3 inColor;
  float2 inTexCoord;
};

struct ObjectData {
  float4x4 model;
};

struct CameraData {
  float4x4 view;
  float4x4 proj;
};

struct PushConstants {
  uint objectId;
  uint textureId;
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
};

[shader("vertex")]
VSOutput vertMain(uint index: SV_VertexID) {
  Vertex input = vertices[index];
  float4x4 model = objects[pc.objectId].model;

  VSOutput output;
  output.pos =
      mul(camera.proj, mul(camera.view, mul(model, float4(input.inPos, 1.0))));
  output.fragColor = input.inColor;
  output.fragTexCoord = input.inTexCoord;
  return output;
}

[[vk::binding(3, 0)]]
Sampler2D textures[];

[shader("fragment")]
float4 fragMain(VSOutput vertIn) : SV_TARGET {
  return textures[pc.textureId].Sample(vertIn.fragTexCoord);
}
