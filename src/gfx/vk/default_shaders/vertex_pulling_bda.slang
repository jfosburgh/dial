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
  float _p1;
  uint64_t vertexAddr;
  uint64_t indexAddr;
  float2 _p2;
};

struct GlobalData {
  float4x4 view_proj;
}

struct PushConstants {
  GlobalData *global_data;
  ObjectData *object_data;
};

[[vk::push_constant]]
PushConstants pc;

struct VSOutput {
  float4 pos : SV_Position;
  float3 fragColor;
  float2 fragTexCoord;
  nointerpolation uint textureId : DATA0;
};

[shader("vertex")]
VSOutput vertMain(uint vertexID: SV_VertexID, uint drawIndex: SV_DrawIndex) {
  ObjectData object = pc.object_data[drawIndex];
  GlobalData global = pc.global_data[0];
  uint *indices = (uint *)object.indexAddr;
  Vertex *vertices = (Vertex *)object.vertexAddr;

  uint index = indices[vertexID];
  Vertex input = vertices[index];

  VSOutput output;
  output.pos =
      mul(global.view_proj, mul(object.model, float4(input.inPos, 1.0)));
  output.fragColor = input.inColor;
  output.fragTexCoord = input.inTexCoord;
  output.textureId = object.textureId;

  return output;
}

[[vk::binding(0, 0)]]
Sampler2D textures[];

[shader("fragment")]
float4 fragMain(VSOutput vertIn) : SV_TARGET {

  return textures[vertIn.textureId].Sample(vertIn.fragTexCoord);
}
