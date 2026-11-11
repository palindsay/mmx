//! Bounded, depth-buffered offscreen wgpu renderer. No Flutter or window handle
//! is required. See README.md for the C ABI, wire format and resource limits.
use std::{
    alloc::{Layout, alloc_zeroed, dealloc},
    panic::{AssertUnwindSafe, catch_unwind},
    sync::{Mutex, OnceLock},
    time::Duration,
};
use wgpu::util::DeviceExt;

const MAX_BYTES: usize = 256 * 1024 * 1024;
const MAX_VERTICES: usize = 4_000_000;
const MAGIC: u32 = 0x47584d4d;
const STRIDE: usize = 16;

struct Reader<'a> {
    bytes: &'a [u8],
    at: usize,
}
impl<'a> Reader<'a> {
    fn take(&mut self, size: usize) -> Result<&'a [u8], String> {
        let end = self.at.checked_add(size).ok_or("Packet length overflow")?;
        let value = self.bytes.get(self.at..end).ok_or("Truncated GPU packet")?;
        self.at = end;
        Ok(value)
    }
    fn u32(&mut self) -> Result<u32, String> {
        Ok(u32::from_le_bytes(self.take(4)?.try_into().unwrap()))
    }
    fn float(&mut self) -> Result<f32, String> {
        let value = f32::from_le_bytes(self.take(4)?.try_into().unwrap());
        if !value.is_finite() {
            return Err("Non-finite GPU input".into());
        }
        Ok(value)
    }
    fn matrix(&mut self) -> Result<[f32; 16], String> {
        let mut result = [0.; 16];
        for x in &mut result {
            *x = self.float()?;
        }
        Ok(result)
    }
}
struct Draw {
    count: u32,
    lines: bool,
    flags: u32,
    model: [f32; 16],
    normal: [f32; 16],
    vertices: Vec<f32>,
    width: u32,
    height: u32,
    texture: Vec<u8>,
}
struct Scene {
    width: u32,
    height: u32,
    background: [f32; 4],
    vp: [f32; 16],
    ambient: f32,
    draws: Vec<Draw>,
}
fn parse(bytes: &[u8]) -> Result<Scene, String> {
    if bytes.len() > MAX_BYTES {
        return Err("GPU packet exceeds 256 MiB".into());
    }
    let mut r = Reader { bytes, at: 0 };
    if r.u32()? != MAGIC || r.u32()? != 1 {
        return Err("Unsupported GPU packet version".into());
    }
    let width = r.u32()?;
    let height = r.u32()?;
    let count = r.u32()?;
    if width == 0 || height == 0 || width > 4096 || height > 4096 || count > 4096 {
        return Err("GPU dimensions/draw count exceed limits".into());
    }
    let mut background = [0.; 4];
    for x in &mut background {
        *x = r.float()?;
    }
    let vp = r.matrix()?;
    let ambient = r.float()?;
    if !(0.0..=1.0).contains(&ambient) {
        return Err("Invalid ambient value".into());
    }
    let mut draws = Vec::new();
    let mut total = 0usize;
    for _ in 0..count {
        let vertex_count = r.u32()?;
        let primitive = r.u32()?;
        let flags = r.u32()?;
        let tw = r.u32()?;
        let th = r.u32()?;
        let texture_len = r.u32()? as usize;
        total = total
            .checked_add(vertex_count as usize)
            .ok_or("Vertex count overflow")?;
        if total > MAX_VERTICES
            || vertex_count == 0
            || primitive > 1
            || flags > 31
            || vertex_count % if primitive == 0 { 3 } else { 2 } != 0
        {
            return Err("Invalid vertex/primitive count".into());
        }
        if tw == 0
            || th == 0
            || tw > 4096
            || th > 4096
            || texture_len != tw as usize * th as usize * 4
        {
            return Err("Invalid texture dimensions".into());
        }
        let model = r.matrix()?;
        let normal = r.matrix()?;
        let size = (vertex_count as usize)
            .checked_mul(STRIDE)
            .ok_or("Vertex size overflow")?;
        if size > (r.bytes.len() - r.at) / 4 {
            return Err("Truncated vertex array".into());
        }
        let mut vertices = Vec::with_capacity(size);
        for _ in 0..size {
            vertices.push(r.float()?);
        }
        let texture = r.take(texture_len)?.to_vec();
        draws.push(Draw {
            count: vertex_count,
            lines: primitive == 1,
            flags,
            model,
            normal,
            vertices,
            width: tw,
            height: th,
            texture,
        });
    }
    if r.at != bytes.len() {
        return Err("Trailing GPU packet data".into());
    }
    Ok(Scene {
        width,
        height,
        background,
        vp,
        ambient,
        draws,
    })
}

struct Renderer {
    device: wgpu::Device,
    queue: wgpu::Queue,
    layout: wgpu::BindGroupLayout,
    pipelines: Vec<wgpu::RenderPipeline>,
    description: String,
    hardware: bool,
    cached_body: Vec<u8>,
    cached_scene: Option<Scene>,
    cached_resources: Vec<(wgpu::Buffer, wgpu::BindGroup, wgpu::Buffer)>,
}
impl Renderer {
    fn new() -> Result<Self, String> {
        let mut descriptor = wgpu::InstanceDescriptor::new_without_display_handle();
        descriptor.backends = wgpu::Backends::VULKAN | wgpu::Backends::METAL | wgpu::Backends::DX12;
        // These shaders need no SM6 features. Use Windows' system FXC, without
        // requiring an unbundled dxcompiler.dll on end-user machines.
        descriptor.backend_options.dx12.shader_compiler = wgpu::Dx12Compiler::Fxc;
        let instance = wgpu::Instance::new(descriptor);
        let adapter = pollster::block_on(instance.request_adapter(&wgpu::RequestAdapterOptions {
            power_preference: wgpu::PowerPreference::HighPerformance,
            ..Default::default()
        }))
        .map_err(|e| format!("No Vulkan/Metal/DX12 adapter: {e}"))?;
        let info = adapter.get_info();
        let hardware = matches!(
            info.device_type,
            wgpu::DeviceType::DiscreteGpu | wgpu::DeviceType::IntegratedGpu
        );
        let description = format!(
            "wgpu {:?}: {} ({:?}; {})",
            info.backend, info.name, info.device_type, info.driver
        );
        let (device, queue) = pollster::block_on(adapter.request_device(&wgpu::DeviceDescriptor {
            label: Some("MMX offscreen renderer"),
            required_limits: wgpu::Limits::default(),
            ..Default::default()
        }))
        .map_err(|e| format!("GPU device unavailable: {e}"))?;
        let layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("MMX material layout"),
            entries: &[
                wgpu::BindGroupLayoutEntry {
                    binding: 0,
                    visibility: wgpu::ShaderStages::VERTEX_FRAGMENT,
                    ty: wgpu::BindingType::Buffer {
                        ty: wgpu::BufferBindingType::Uniform,
                        has_dynamic_offset: false,
                        min_binding_size: None,
                    },
                    count: None,
                },
                wgpu::BindGroupLayoutEntry {
                    binding: 1,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Texture {
                        sample_type: wgpu::TextureSampleType::Float { filterable: true },
                        view_dimension: wgpu::TextureViewDimension::D2,
                        multisampled: false,
                    },
                    count: None,
                },
                wgpu::BindGroupLayoutEntry {
                    binding: 2,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Sampler(wgpu::SamplerBindingType::Filtering),
                    count: None,
                },
            ],
        });
        let pipeline_layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("MMX pipeline layout"),
            bind_group_layouts: &[Some(&layout)],
            immediate_size: 0,
        });
        let shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("MMX shaded material"),
            source: wgpu::ShaderSource::Wgsl(include_str!("shader.wgsl").into()),
        });
        let attributes = wgpu::vertex_attr_array![0=>Float32x3,1=>Float32x3,2=>Float32x4,3=>Float32x2,4=>Float32x3,5=>Float32];
        let mut pipelines = Vec::new();
        for variant in 0..4 {
            pipelines.push(
                device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
                    label: Some("MMX depth-tested pipeline"),
                    layout: Some(&pipeline_layout),
                    vertex: wgpu::VertexState {
                        module: &shader,
                        entry_point: Some("vs_main"),
                        compilation_options: Default::default(),
                        buffers: &[Some(wgpu::VertexBufferLayout {
                            array_stride: (STRIDE * 4) as u64,
                            step_mode: wgpu::VertexStepMode::Vertex,
                            attributes: &attributes,
                        })],
                    },
                    primitive: wgpu::PrimitiveState {
                        topology: if variant == 3 {
                            wgpu::PrimitiveTopology::LineList
                        } else {
                            wgpu::PrimitiveTopology::TriangleList
                        },
                        front_face: if variant == 1 {
                            wgpu::FrontFace::Cw
                        } else {
                            wgpu::FrontFace::Ccw
                        },
                        cull_mode: if variant < 2 {
                            Some(wgpu::Face::Back)
                        } else {
                            None
                        },
                        ..Default::default()
                    },
                    depth_stencil: Some(wgpu::DepthStencilState {
                        format: wgpu::TextureFormat::Depth32Float,
                        depth_write_enabled: Some(true),
                        depth_compare: Some(wgpu::CompareFunction::LessEqual),
                        stencil: Default::default(),
                        bias: Default::default(),
                    }),
                    multisample: Default::default(),
                    fragment: Some(wgpu::FragmentState {
                        module: &shader,
                        entry_point: Some("fs_main"),
                        compilation_options: Default::default(),
                        targets: &[Some(wgpu::ColorTargetState {
                            format: wgpu::TextureFormat::Rgba8Unorm,
                            blend: None,
                            write_mask: wgpu::ColorWrites::ALL,
                        })],
                    }),
                    multiview_mask: None,
                    cache: None,
                }),
            );
        }
        Ok(Self {
            device,
            queue,
            layout,
            pipelines,
            description,
            hardware,
            cached_body: Vec::new(),
            cached_scene: None,
            cached_resources: Vec::new(),
        })
    }
    fn create_resources(
        &self,
        scene: &Scene,
    ) -> Vec<(wgpu::Buffer, wgpu::BindGroup, wgpu::Buffer)> {
        let mut resources = Vec::new();
        for draw in &scene.draws {
            let vertices = self
                .device
                .create_buffer_init(&wgpu::util::BufferInitDescriptor {
                    label: Some("MMX vertices"),
                    contents: bytemuck::cast_slice(&draw.vertices),
                    usage: wgpu::BufferUsages::VERTEX,
                });
            let mut uniform = Vec::with_capacity(52);
            uniform.extend_from_slice(&scene.vp);
            uniform.extend_from_slice(&draw.model);
            uniform.extend_from_slice(&draw.normal);
            uniform.extend_from_slice(&[
                scene.ambient,
                if draw.flags & 1 != 0 { 1. } else { 0. },
                if draw.flags & 2 != 0 { 1. } else { 0. },
                0.,
            ]);
            let buffer = self
                .device
                .create_buffer_init(&wgpu::util::BufferInitDescriptor {
                    label: Some("MMX camera"),
                    contents: bytemuck::cast_slice(&uniform),
                    usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
                });
            let tex = self.device.create_texture(&wgpu::TextureDescriptor {
                label: Some("MMX material texture"),
                size: wgpu::Extent3d {
                    width: draw.width,
                    height: draw.height,
                    depth_or_array_layers: 1,
                },
                mip_level_count: 1,
                sample_count: 1,
                dimension: wgpu::TextureDimension::D2,
                format: wgpu::TextureFormat::Rgba8Unorm,
                usage: wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_DST,
                view_formats: &[],
            });
            self.queue.write_texture(
                wgpu::TexelCopyTextureInfo {
                    texture: &tex,
                    mip_level: 0,
                    origin: wgpu::Origin3d::ZERO,
                    aspect: wgpu::TextureAspect::All,
                },
                &draw.texture,
                wgpu::TexelCopyBufferLayout {
                    offset: 0,
                    bytes_per_row: Some(draw.width * 4),
                    rows_per_image: Some(draw.height),
                },
                tex.size(),
            );
            let tex_view = tex.create_view(&Default::default());
            let mode = if draw.flags & 8 != 0 {
                wgpu::AddressMode::ClampToEdge
            } else {
                wgpu::AddressMode::Repeat
            };
            let sampler = self.device.create_sampler(&wgpu::SamplerDescriptor {
                address_mode_u: mode,
                address_mode_v: mode,
                mag_filter: wgpu::FilterMode::Linear,
                min_filter: wgpu::FilterMode::Linear,
                ..Default::default()
            });
            let bind = self.device.create_bind_group(&wgpu::BindGroupDescriptor {
                label: Some("MMX material"),
                layout: &self.layout,
                entries: &[
                    wgpu::BindGroupEntry {
                        binding: 0,
                        resource: buffer.as_entire_binding(),
                    },
                    wgpu::BindGroupEntry {
                        binding: 1,
                        resource: wgpu::BindingResource::TextureView(&tex_view),
                    },
                    wgpu::BindGroupEntry {
                        binding: 2,
                        resource: wgpu::BindingResource::Sampler(&sampler),
                    },
                ],
            });
            resources.push((vertices, bind, buffer));
        }
        resources
    }

    // Keep only one scene resident. Exact byte comparison avoids hash collision
    // aliases; camera-only frames validate a small header and retain GPU buffers.
    fn render_packet(&mut self, bytes: &[u8], output: &mut [u8]) -> Result<(), String> {
        if bytes.len() < 104 {
            return Err("Truncated GPU packet".into());
        }
        let memory_scope = self.device.push_error_scope(wgpu::ErrorFilter::OutOfMemory);
        let validation_scope = self.device.push_error_scope(wgpu::ErrorFilter::Validation);
        let result = self.render_packet_inner(bytes, output);
        let validation_error = pollster::block_on(validation_scope.pop());
        let memory_error = pollster::block_on(memory_scope.pop());
        if let Some(error) = memory_error.or(validation_error) {
            self.cached_scene = None;
            self.cached_resources.clear();
            self.cached_body.clear();
            return Err(format!("GPU scene upload failed: {error}"));
        }
        result
    }

    fn render_packet_inner(&mut self, bytes: &[u8], output: &mut [u8]) -> Result<(), String> {
        if self.cached_scene.is_none() || self.cached_body != bytes[104..] {
            let mut scene = parse(bytes)?;
            let resources = self.create_resources(&scene);
            for draw in &mut scene.draws {
                draw.vertices = Vec::new();
                draw.texture = Vec::new();
            }
            self.cached_body = bytes[104..].to_vec();
            self.cached_scene = Some(scene);
            self.cached_resources = resources;
        } else if let Some(scene) = self.cached_scene.as_mut() {
            let count = u32::from_le_bytes(bytes[16..20].try_into().unwrap()) as usize;
            if count != scene.draws.len() {
                return Err("Cached draw count mismatch".into());
            }
            let mut header = bytes[..104].to_vec();
            header[16..20].fill(0);
            let frame = parse(&header)?;
            scene.width = frame.width;
            scene.height = frame.height;
            scene.background = frame.background;
            scene.vp = frame.vp;
            scene.ambient = frame.ambient;
        }
        self.render(self.cached_scene.as_ref().unwrap(), output)
    }

    fn render(&self, scene: &Scene, output: &mut [u8]) -> Result<(), String> {
        if output.len() != scene.width as usize * scene.height as usize * 4 {
            return Err("Invalid output buffer length".into());
        }
        let validation_scope = self.device.push_error_scope(wgpu::ErrorFilter::Validation);
        let memory_scope = self.device.push_error_scope(wgpu::ErrorFilter::OutOfMemory);
        let result = self.render_inner(scene, output);
        let memory_error = pollster::block_on(memory_scope.pop());
        let validation_error = pollster::block_on(validation_scope.pop());
        if let Some(e) = memory_error.or(validation_error) {
            return Err(format!("GPU validation/resource failure: {e}"));
        }
        result
    }
    fn render_inner(&self, scene: &Scene, output: &mut [u8]) -> Result<(), String> {
        let extent = wgpu::Extent3d {
            width: scene.width,
            height: scene.height,
            depth_or_array_layers: 1,
        };
        let texture = self.device.create_texture(&wgpu::TextureDescriptor {
            label: Some("MMX offscreen color"),
            size: extent,
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format: wgpu::TextureFormat::Rgba8Unorm,
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT | wgpu::TextureUsages::COPY_SRC,
            view_formats: &[],
        });
        let depth = self.device.create_texture(&wgpu::TextureDescriptor {
            label: Some("MMX depth"),
            size: extent,
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format: wgpu::TextureFormat::Depth32Float,
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
            view_formats: &[],
        });
        let view = texture.create_view(&Default::default());
        let depth_view = depth.create_view(&Default::default());
        for (draw, (_, _, uniform_buffer)) in scene.draws.iter().zip(&self.cached_resources) {
            let mut uniform = Vec::with_capacity(52);
            uniform.extend_from_slice(&scene.vp);
            uniform.extend_from_slice(&draw.model);
            uniform.extend_from_slice(&draw.normal);
            uniform.extend_from_slice(&[
                scene.ambient,
                if draw.flags & 1 != 0 { 1. } else { 0. },
                if draw.flags & 2 != 0 { 1. } else { 0. },
                0.,
            ]);
            self.queue
                .write_buffer(uniform_buffer, 0, bytemuck::cast_slice(&uniform));
        }
        let mut encoder = self.device.create_command_encoder(&Default::default());
        {
            let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: Some("MMX frame"),
                color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                    view: &view,
                    resolve_target: None,
                    depth_slice: None,
                    ops: wgpu::Operations {
                        load: wgpu::LoadOp::Clear(wgpu::Color {
                            r: scene.background[0] as f64,
                            g: scene.background[1] as f64,
                            b: scene.background[2] as f64,
                            a: scene.background[3] as f64,
                        }),
                        store: wgpu::StoreOp::Store,
                    },
                })],
                depth_stencil_attachment: Some(wgpu::RenderPassDepthStencilAttachment {
                    view: &depth_view,
                    depth_ops: Some(wgpu::Operations {
                        load: wgpu::LoadOp::Clear(1.),
                        store: wgpu::StoreOp::Discard,
                    }),
                    stencil_ops: None,
                }),
                timestamp_writes: None,
                occlusion_query_set: None,
                multiview_mask: None,
            });
            for (draw, (vertices, bind, _)) in scene.draws.iter().zip(&self.cached_resources) {
                let variant = if draw.lines {
                    3
                } else if draw.flags & 16 != 0 {
                    2
                } else if draw.flags & 4 != 0 {
                    1
                } else {
                    0
                };
                pass.set_pipeline(&self.pipelines[variant]);
                pass.set_bind_group(0, bind, &[]);
                pass.set_vertex_buffer(0, vertices.slice(..));
                pass.draw(0..draw.count, 0..1);
            }
        }
        let row = (scene.width * 4).div_ceil(256) * 256;
        let readback = self.device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("MMX readback"),
            size: row as u64 * scene.height as u64,
            usage: wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::MAP_READ,
            mapped_at_creation: false,
        });
        encoder.copy_texture_to_buffer(
            wgpu::TexelCopyTextureInfo {
                texture: &texture,
                mip_level: 0,
                origin: wgpu::Origin3d::ZERO,
                aspect: wgpu::TextureAspect::All,
            },
            wgpu::TexelCopyBufferInfo {
                buffer: &readback,
                layout: wgpu::TexelCopyBufferLayout {
                    offset: 0,
                    bytes_per_row: Some(row),
                    rows_per_image: Some(scene.height),
                },
            },
            extent,
        );
        let submission = self.queue.submit([encoder.finish()]);
        let (send, receive) = std::sync::mpsc::channel();
        readback
            .slice(..)
            .map_async(wgpu::MapMode::Read, move |result| {
                let _ = send.send(result);
            });
        self.device
            .poll(wgpu::PollType::Wait {
                submission_index: Some(submission),
                timeout: Some(Duration::from_secs(10)),
            })
            .map_err(|e| format!("GPU readback polling failed: {e}"))?;
        receive
            .recv_timeout(Duration::from_secs(10))
            .map_err(|_| "GPU readback timed out")?
            .map_err(|e| format!("GPU readback failed: {e}"))?;
        let mapped = readback
            .slice(..)
            .get_mapped_range()
            .map_err(|e| format!("GPU mapping failed: {e}"))?;
        for y in 0..scene.height as usize {
            let width = scene.width as usize * 4;
            output[y * width..(y + 1) * width]
                .copy_from_slice(&mapped[y * row as usize..y * row as usize + width]);
        }
        drop(mapped);
        readback.unmap();
        Ok(())
    }
}
// Cache initialization failure too, avoiding a probe on every orbit frame.
static RENDERER: OnceLock<Mutex<Result<Renderer, String>>> = OnceLock::new();

/// ABI version checked by Dart before invoking any other function.
#[unsafe(no_mangle)]
pub extern "C" fn mmx_gpu_abi_version() -> u32 {
    1
}
/// Allocations carry their own size, allowing use as a Dart NativeFinalizer.
#[unsafe(no_mangle)]
pub extern "C" fn mmx_gpu_allocate(size: usize) -> *mut u8 {
    if size == 0 || size > MAX_BYTES {
        return std::ptr::null_mut();
    }
    let Ok(layout) = Layout::from_size_align(size + 8, 8) else {
        return std::ptr::null_mut();
    };
    unsafe {
        let raw = alloc_zeroed(layout);
        if raw.is_null() {
            return raw;
        }
        *(raw as *mut usize) = size;
        raw.add(8)
    }
}
/// # Safety
/// `pointer` must be returned by mmx_gpu_allocate and released exactly once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn mmx_gpu_release(pointer: *mut u8) {
    if pointer.is_null() {
        return;
    }
    unsafe {
        let raw = pointer.sub(8);
        let size = *(raw as *const usize);
        if let Ok(layout) = Layout::from_size_align(size + 8, 8) {
            dealloc(raw, layout);
        }
    }
}
/// # Safety
/// Buffers must be valid for their declared lengths and must not overlap.
/// Returns 0 for a hardware adapter, 1 for a software/unknown adapter, -1 on
/// failure. All panics are contained at this boundary, never unwound into Dart.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn mmx_gpu_render(
    input: *const u8,
    input_len: usize,
    output: *mut u8,
    output_len: usize,
    diagnostic: *mut u8,
    diagnostic_len: usize,
) -> i32 {
    if input.is_null()
        || output.is_null()
        || diagnostic.is_null()
        || input_len > MAX_BYTES
        || output_len > 64 * 1024 * 1024
        || diagnostic_len == 0
        || diagnostic_len > 65536
    {
        return -1;
    }
    let result = catch_unwind(AssertUnwindSafe(|| -> Result<(bool, String), String> {
        let packet = unsafe { std::slice::from_raw_parts(input, input_len) };
        if packet.len() < 104 {
            parse(packet)?;
            return Err("Truncated GPU packet".into());
        }
        let mut frame_header = packet[..104].to_vec();
        frame_header[16..20].fill(0);
        parse(&frame_header)?;
        let output = unsafe { std::slice::from_raw_parts_mut(output, output_len) };
        let mut guard = RENDERER
            .get_or_init(|| Mutex::new(Renderer::new()))
            .lock()
            .map_err(|_| "GPU state unavailable after driver failure")?;
        let renderer = guard.as_mut().map_err(|error| error.clone())?;
        renderer.render_packet(packet, output)?;
        Ok((renderer.hardware, renderer.description.clone()))
    }));
    let (code, message) = match result {
        Ok(Ok((hardware, message))) => (if hardware { 0 } else { 1 }, message),
        Ok(Err(message)) => (-1, message),
        Err(_) => (
            -1,
            "GPU renderer/driver panicked; CPU fallback required".into(),
        ),
    };
    let bytes = message.as_bytes();
    let length = bytes.len().min(diagnostic_len - 1);
    unsafe {
        std::ptr::copy_nonoverlapping(bytes.as_ptr(), diagnostic, length);
        *diagnostic.add(length) = 0;
    }
    code
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rejects_truncated_and_oversized_packets() {
        assert!(parse(&[]).is_err());
        let mut bytes = vec![0u8; 104];
        bytes[..4].copy_from_slice(&MAGIC.to_le_bytes());
        bytes[4..8].copy_from_slice(&1u32.to_le_bytes());
        bytes[8..12].copy_from_slice(&4097u32.to_le_bytes());
        assert!(parse(&bytes).is_err());
    }
    #[test]
    fn allocation_bounds() {
        assert!(mmx_gpu_allocate(0).is_null());
        assert!(mmx_gpu_allocate(MAX_BYTES + 1).is_null());
        let p = mmx_gpu_allocate(32);
        assert!(!p.is_null());
        unsafe {
            assert_eq!(*p, 0);
            mmx_gpu_release(p);
        }
    }
    fn empty_packet() -> Vec<u8> {
        let mut bytes = vec![0u8; 104];
        for (at, value) in [(0, MAGIC), (4, 1), (8, 32), (12, 32)] {
            bytes[at..at + 4].copy_from_slice(&value.to_le_bytes());
        }
        bytes
    }
    #[test]
    fn rejects_unbounded_counts_nonfinite_and_trailing_data() {
        let base = empty_packet();
        assert!(parse(&base).is_ok());
        for (at, value) in [(16, 4097u32), (20, f32::NAN.to_bits())] {
            let mut packet = base.clone();
            packet[at..at + 4].copy_from_slice(&value.to_le_bytes());
            assert!(parse(&packet).is_err());
        }
        let mut packet = base.clone();
        packet.push(0);
        assert!(parse(&packet).is_err());
        let mut packet = base;
        packet[16..20].copy_from_slice(&1u32.to_le_bytes());
        packet.extend_from_slice(&u32::MAX.to_le_bytes());
        packet.extend_from_slice(&[0; 20]);
        assert!(parse(&packet).is_err());
    }
    #[test]
    fn seeded_packet_mutations_do_not_panic_or_allocate_from_bad_counts() {
        let mut seed = 0x4d4d585f475055u64;
        for length in 0..2048 {
            let mut packet = empty_packet();
            packet.resize(length, 0);
            for _ in 0..8 {
                seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1);
                if !packet.is_empty() {
                    let at = seed as usize % packet.len();
                    packet[at] = (seed >> 32) as u8;
                }
            }
            assert!(catch_unwind(|| parse(&packet)).is_ok());
        }
    }
    #[test]
    fn ffi_returns_diagnostic_without_unwinding_for_invalid_packets() {
        let packet = [0u8; 8];
        let mut output = [0u8; 4];
        let mut diagnostic = [0u8; 128];
        let status = unsafe {
            mmx_gpu_render(
                packet.as_ptr(),
                packet.len(),
                output.as_mut_ptr(),
                output.len(),
                diagnostic.as_mut_ptr(),
                diagnostic.len(),
            )
        };
        assert_eq!(status, -1);
        assert!(
            std::str::from_utf8(&diagnostic)
                .unwrap()
                .starts_with("Unsupported GPU packet")
        );
    }
}
