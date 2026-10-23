// CubeMap's position-only cube and panorama.vsh/fsh: sample its untransformed direction.
struct Projection { view_proj: mat4x4<f32> }
@group(0) @binding(0) var<uniform> projection: Projection;
@group(0) @binding(1) var panorama: texture_cube<f32>;
@group(0) @binding(2) var panorama_sampler: sampler;
struct Out {
    @builtin(position) clip: vec4<f32>,
    @location(0) direction: vec3<f32>,
}
// The cube's 12 triangles as corner numbers, 3 bits each, ten to a word: the Adreno compiler
// loses the device on a constant array indexed by the vertex number, so the tables are plain
// numbers and shifts. Corners 1, 2, 5, 6 have x = 1; 2, 3, 6, 7 have y = 1; 4 to 7 have z = 1.
const CUBE0 = 0x2ad6e9bcu;
const CUBE1 = 0x180cb44au;
const CUBE2 = 0x32e9f9c7u;
const CUBE3 = 0xd160u;

fn cube_corner(index: u32) -> u32 {
    let word = index / 10u;
    let packed = select(select(select(CUBE3, CUBE2, word < 3u), CUBE1, word < 2u), CUBE0, word < 1u);
    return (packed >> ((index % 10u) * 3u)) & 7u;
}

@vertex fn vs_panorama(@builtin(vertex_index) index: u32) -> Out {
    let corner = cube_corner(index);
    let position = vec3(
        select(-1.0, 1.0, ((0x66u >> corner) & 1u) != 0u),
        select(-1.0, 1.0, ((0xCCu >> corner) & 1u) != 0u),
        select(-1.0, 1.0, ((0xF0u >> corner) & 1u) != 0u),
    );
    var out: Out;
    out.clip = projection.view_proj * vec4(position, 1.0);
    out.direction = position;
    return out;
}
@fragment fn fs_panorama(in: Out) -> @location(0) vec4<f32> {
    return textureSample(panorama, panorama_sampler, in.direction);
}
