import Metal
import simd

/// Draws the squishy Axo like a drawing, like the logo: cel-shaded in two flat tones of its
/// white, with its ink outline round it, and its face drawn on it.
///
/// - The outline is the mesh again, puffed out along its normals with its front faces culled, so
///   only a rim of it shows past the body: an ink line that follows every dent and stretch.
/// - The shading is two bands, lit and in shadow, split where the light falls off.
/// - The face is drawn on the body in the fragment shader from each point's place at rest, so it
///   stays crisp, and stretches, dents and blows up with the body.
@MainActor
final class SquishyRenderer {
  /// What to draw: how it looks this frame.
  struct Frame {
    enum Face: Int32 {
      case calm = 0
      /// ^ ^
      case happy = 1
      /// > <
      case squeezed = 2
      /// Wide eyes, mouth open.
      case scream = 3
    }

    /// Where the drawing goes, in points, and how many pixels a point is.
    var size: CGSize
    var scale: CGFloat
    /// How big Axo is drawn: 1 is the mesh's own size in points.
    var zoom: Float = 1
    /// Turned about the viewer's axis (radians, counterclockwise), and looking towards a point
    /// from -1 to 1 each way (right, up).
    var roll: Float = 0
    var look: SIMD2<Float> = .zero
    var face: Face = .calm
    /// 0 eyes open, 1 shut.
    var blink: Float = 0
  }

  static let pixelFormat = MTLPixelFormat.bgra8Unorm
  static let depthFormat = MTLPixelFormat.depth32Float
  static let sampleCount = 4

  let device: MTLDevice
  private let outlinePipeline: MTLRenderPipelineState
  private let bodyPipeline: MTLRenderPipelineState
  private let depth: MTLDepthStencilState
  private let triangles: MTLBuffer
  private let rest: MTLBuffer
  private let parts: MTLBuffer
  private let triangleIndices: [SIMD3<UInt32>]
  private let indexCount: Int

  init?(mesh: SquishyMesh, device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
    guard let device, let library = try? device.makeLibrary(source: Self.shaders + SquishyMesh.shaderShape + Self.fragment, options: nil)
    else { return nil }
    self.device = device
    func pipeline(vertex: String, fragment: String) -> MTLRenderPipelineState? {
      let descriptor = MTLRenderPipelineDescriptor()
      descriptor.vertexFunction = library.makeFunction(name: vertex)
      descriptor.fragmentFunction = library.makeFunction(name: fragment)
      descriptor.colorAttachments[0].pixelFormat = Self.pixelFormat
      descriptor.depthAttachmentPixelFormat = Self.depthFormat
      descriptor.rasterSampleCount = Self.sampleCount
      return try? device.makeRenderPipelineState(descriptor: descriptor)
    }
    let depthDescriptor = MTLDepthStencilDescriptor()
    depthDescriptor.depthCompareFunction = .lessEqual
    depthDescriptor.isDepthWriteEnabled = true
    guard let outline = pipeline(vertex: "outline_vertex", fragment: "ink_fragment"),
      let body = pipeline(vertex: "body_vertex", fragment: "body_fragment"),
      let depth = device.makeDepthStencilState(descriptor: depthDescriptor),
      let triangles = device.makeBuffer(
        bytes: mesh.triangles.flatMap { [$0.x, $0.y, $0.z] }, length: mesh.triangles.count * 12),
      let rest = device.makeBuffer(bytes: mesh.vertices.map { SIMD4($0, 0) }, length: mesh.vertices.count * 16),
      let parts = device.makeBuffer(
        bytes: mesh.vertices.indices.map { index -> SIMD4<Float> in
          let part = index < mesh.parts.count ? mesh.parts[index] : SquishyMesh.Part()
          return SIMD4(part.gill, 0, 0, 0)
        }, length: mesh.vertices.count * 16)
    else { return nil }
    outlinePipeline = outline
    bodyPipeline = body
    self.depth = depth
    self.triangles = triangles
    self.rest = rest
    self.parts = parts
    triangleIndices = mesh.triangles
    indexCount = mesh.triangles.count * 3
  }

  /// Draws the body, its vertices at `positions`, into `pass`.
  func draw(_ positions: [SIMD3<Float>], frame: Frame, pass: MTLRenderPassDescriptor, commands: MTLCommandBuffer) {
    let normals = SquishyMesh.normals(of: positions, triangles: triangleIndices)
    let vertices = zip(positions, normals).flatMap { [SIMD4($0, 0), SIMD4($1, 0)] }
    guard let vertexBuffer = device.makeBuffer(bytes: vertices, length: vertices.count * 16),
      let encoder = commands.makeRenderCommandEncoder(descriptor: pass)
    else { return }
    var uniforms = Self.uniforms(for: frame)
    encoder.setDepthStencilState(depth)
    encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
    encoder.setVertexBuffer(rest, offset: 0, index: 1)
    encoder.setVertexBuffer(parts, offset: 0, index: 3)
    encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 2)
    encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
    // The outline first, its front faces culled, so the body covers all of it but its rim.
    encoder.setRenderPipelineState(outlinePipeline)
    encoder.setCullMode(.front)
    encoder.setFrontFacing(.counterClockwise)
    encoder.drawIndexedPrimitives(type: .triangle, indexCount: indexCount, indexType: .uint32, indexBuffer: triangles, indexBufferOffset: 0)
    encoder.setRenderPipelineState(bodyPipeline)
    encoder.setCullMode(.back)
    encoder.drawIndexedPrimitives(type: .triangle, indexCount: indexCount, indexType: .uint32, indexBuffer: triangles, indexBufferOffset: 0)
    encoder.endEncoding()
  }

  // MARK: Shaders

  private struct Uniforms {
    var turn: simd_float4x4
    /// Points to clip space, x and y.
    var toClip: SIMD2<Float>
    var zoom: Float
    var outline: Float
    var blink: Float
    var face: Int32
    var padding: SIMD2<Float> = .zero
  }

  private static func uniforms(for frame: Frame) -> Uniforms {
    // A little from above, so it reads as round; then looking where it looks; then rolled.
    let tilt = rotation(angle: -0.22 - frame.look.y * 0.35, axis: [1, 0, 0])
    let turn = rotation(angle: frame.look.x * 0.45, axis: [0, 1, 0])
    let roll = rotation(angle: frame.roll, axis: [0, 0, 1])
    return Uniforms(
      turn: roll * turn * tilt,
      toClip: [Float(2 / frame.size.width), Float(2 / frame.size.height)],
      zoom: frame.zoom,
      // As thick as the logo's, for its size, and never thinner than a point and a half.
      outline: max(3.2, 1.5 / frame.zoom),
      blink: frame.blink,
      face: frame.face.rawValue)
  }

  private static func rotation(angle: Float, axis: SIMD3<Float>) -> simd_float4x4 {
    simd_float4x4(simd_quatf(angle: angle, axis: axis))
  }

  private static let shaders = """
    #include <metal_stdlib>
    using namespace metal;

    struct Vertex { float4 position; float4 normal; };
    struct Uniforms {
      float4x4 turn; float2 toClip; float zoom; float outline; float blink; int face; float2 padding;
    };
    struct Out { float4 position [[position]]; float3 normal; float3 rest; float3 part; };

    static float4 place(float3 p, constant Uniforms &u) {
      float3 turned = (u.turn * float4(p, 1)).xyz * u.zoom;
      // Orthographic; nearer the viewer (larger z) is nearer in depth.
      return float4(turned.xy * u.toClip, 0.5 - turned.z / 1000, 1);
    }

    vertex Out outline_vertex(uint id [[vertex_id]], const device Vertex *vertices [[buffer(0)]],
                              const device float4 *rest [[buffer(1)]], constant Uniforms &u [[buffer(2)]],
                              const device float4 *parts [[buffer(3)]]) {
      Vertex v = vertices[id];
      Out out;
      out.position = place(v.position.xyz + v.normal.xyz * u.outline, u);
      out.normal = v.normal.xyz;
      out.rest = rest[id].xyz;
      out.part = parts[id].xyz;
      return out;
    }

    fragment half4 ink_fragment(Out in [[stage_in]]) { return half4(0.12h, 0.12h, 0.12h, 1); }

    vertex Out body_vertex(uint id [[vertex_id]], const device Vertex *vertices [[buffer(0)]],
                           const device float4 *rest [[buffer(1)]], constant Uniforms &u [[buffer(2)]],
                           const device float4 *parts [[buffer(3)]]) {
      Vertex v = vertices[id];
      Out out;
      out.position = place(v.position.xyz, u);
      out.normal = (u.turn * float4(v.normal.xyz, 0)).xyz;
      out.rest = rest[id].xyz;
      out.part = parts[id].xyz;
      return out;
    }

    // Distance to a segment.
    static float segment(float2 p, float2 a, float2 b) {
      float2 pa = p - a, ba = b - a;
      return length(pa - ba * clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0));
    }

    // How much of a shape `d` (a signed distance, negative inside) covers, with an edge `aa` soft.
    static float cover(float d, float aa) { return 1.0 - smoothstep(-aa, aa, d); }

    constant float3 ink = float3(0.12);

    """

  /// The body's fragment shader, after the shape's distance fields (`SquishyMesh.shaderShape`).
  private static let fragment = """
    // Its face at `p` (a point on its front at rest, in points), over `color`: the logo's, two
    // big dots set wide and a short flat dash.
    static float3 face(float3 color, float2 p, constant Uniforms &u, float aa) {
      for (int side = -1; side <= 1; side += 2) {
        float2 q = p - float2(20.0 * side, -3.0);
        if (u.face == 1) {
          // ^ : two strokes meeting above.
          float2 r = float2(abs(q.x), q.y);
          color = mix(color, ink, cover(segment(r, float2(0, 3.0), float2(4.6, -1.6)) - 1.6, aa));
        } else if (u.face == 2) {
          // > < : pointing in at the nose.
          float2 r = float2(-q.x * side, abs(q.y));
          color = mix(color, ink, cover(segment(r, float2(3.6, 0), float2(-3.4, 3.6)) - 1.6, aa));
        } else {
          float radius = u.face == 3 ? 6.6 : 5.6;
          float tall = max(0.12, 1.0 - u.blink);
          float d = length(float2(q.x, q.y / tall)) - radius;
          color = mix(color, ink, cover(d * min(1.0, tall * 1.6), aa));
        }
      }
      float2 m = p - float2(0, -9.5);
      if (u.face == 3) {
        color = mix(color, ink, cover(length(float2(m.x * 0.8, m.y + 1.0)) - 4.0, aa));
      } else if (u.face == 1) {
        // A laugh: the dash opened into a little half moon.
        color = mix(color, ink, cover(max(length(m / float2(1.6, 1.0)) - 4.2, m.y - 1.2), aa));
      } else {
        color = mix(color, ink, cover(segment(m, float2(-8.5, 0), float2(8.5, 0)) - 1.9, aa));
      }
      return color;
    }

    fragment half4 body_fragment(Out in [[stage_in]], constant Uniforms &u [[buffer(0)]]) {
      float3 n = normalize(in.normal);
      float3 light = normalize(float3(-0.45, 0.6, 0.65));
      float lit = dot(n, light);
      // Two flat tones of its white, and the edge between them soft by a pixel.
      float aa = fwidth(lit);
      float band = smoothstep(0.12 - aa, 0.12 + aa, lit);
      float3 color = mix(float3(0.84, 0.84, 0.88), float3(0.985, 0.985, 0.985), band);
      // Ink where its pieces meet, as in the logo: round the head where the gills come out of
      // it, and between one gill and the next. Worked out from where this point was made, so the
      // lines stretch with it.
      float3 p = in.rest;
      float head = head_distance(p);
      float nearest = 1e3, next = 1e3;
      for (int i = 0; i < LOBES; i++) {
        float d = lobe_distance(i, p);
        if (d < nearest) { next = nearest; nearest = d; } else if (d < next) { next = d; }
      }
      float line = u.outline * 0.5;
      // Between gills only where two of them meet (both at the surface), not across one.
      float between = next < 2.5 ? next - nearest : 1e3;
      float edge = min(abs(head - nearest), between);
      float edgeAA = fwidth(edge);
      color = mix(color, ink, cover(edge - line, edgeAA));
      // The face, on its front (and not on its gills, or through to its back).
      if (in.part.x < 0.3 && in.rest.z > 8.0) {
        float faceAA = max(fwidth(in.rest.x), fwidth(in.rest.y)) * 0.75;
        color = face(color, in.rest.xy, u, faceAA);
      }
      return half4(half3(color), 1);
    }
    """
}
