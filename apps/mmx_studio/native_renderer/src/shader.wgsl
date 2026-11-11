struct Uniforms {
  view_projection: mat4x4<f32>,
  model: mat4x4<f32>,
  normal_matrix: mat4x4<f32>,
  parameters: vec4<f32>, // ambient, unlit, wireframe, unused
};
@group(0) @binding(0) var<uniform> uniforms: Uniforms;
@group(0) @binding(1) var diffuse: texture_2d<f32>;
@group(0) @binding(2) var diffuse_sampler: sampler;
struct VertexOutput {
  @builtin(position) position: vec4<f32>,
  @location(0) normal: vec3<f32>,
  @location(1) color: vec4<f32>,
  @location(2) uv: vec2<f32>,
  @location(3) barycentric: vec3<f32>,
  @location(4) selected: f32,
};
@vertex fn vs_main(
  @location(0) position: vec3<f32>, @location(1) normal: vec3<f32>,
  @location(2) color: vec4<f32>, @location(3) uv: vec2<f32>,
  @location(4) barycentric: vec3<f32>, @location(5) selected: f32,
) -> VertexOutput {
  var result: VertexOutput;
  let clip = uniforms.view_projection * uniforms.model * vec4(position, 1.0);
  // Dart Camera uses OpenGL [-w,w] depth; WebGPU uses [0,w].
  result.position = vec4(clip.xy, (clip.z + clip.w) * 0.5, clip.w);
  result.normal = (uniforms.normal_matrix * vec4(normal, 0.0)).xyz;
  result.color = color;
  result.uv = vec2(uv.x, 1.0 - uv.y);
  result.barycentric = barycentric;
  result.selected = selected;
  return result;
}
@fragment fn fs_main(input: VertexOutput) -> @location(0) vec4<f32> {
  let sampled = textureSample(diffuse, diffuse_sampler, input.uv);
  var color = input.color * sampled;
  if color.a < 0.5 { discard; }
  if input.selected > 0.5 {
    color = vec4(color.rgb * 0.35 + vec3(0.65, 0.45, 0.10), color.a);
  }
  var shade = 1.0;
  if uniforms.parameters.y < 0.5 {
    let normal = normalize(input.normal);
    let first = max(0.0, dot(normal, normalize(vec3(0.45, 0.75, 0.5))));
    let second = max(0.0, dot(normal, normalize(vec3(-0.6, 0.2, -0.4))));
    shade = clamp(uniforms.parameters.x + first * 0.75 + second * 0.35, 0.0, 1.35);
  }
  if uniforms.parameters.z > 0.5 {
    let width = max(fwidth(input.barycentric), vec3(0.000001));
    let edge = smoothstep(vec3(0.0), width * 1.2, input.barycentric);
    shade *= 0.4 + 0.6 * min(edge.x, min(edge.y, edge.z));
  }
  return vec4(clamp(color.rgb * shade, vec3(0.0), vec3(1.0)), 1.0);
}
