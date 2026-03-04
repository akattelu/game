pub fn mapRange(value: f32, in_min: f32, in_max: f32, out_min: f32, out_max: f32) f32 {
    return (value - in_min) / (in_max - in_min) * (out_max - out_min) + out_min;
}

pub fn rgbaToU32(r: u8, g: u8, b: u8, a: u8) u32 {
    return @as(u32, a) << 24 | @as(u32, b) << 16 | @as(u32, g) << 8 | r;
}

fn hash2d(x: f32, y: f32) f32 {
    // Use @mod to keep values in i32 range before converting
    const val = @mod(x * 127.1 + y * 311.7, 65536.0);
    var n = @as(i32, @intFromFloat(val));
    n = (n << 13) ^ n;
    const nn = @as(f32, @floatFromInt((n *% (n *% n *% 15731 +% 789221) +% 1376312589) & 0x7fffffff));
    return nn / 2147483647.0;
}

fn smoothNoise(x: f32, z: f32) f32 {
    const ix = @floor(x);
    const iz = @floor(z);
    const fx = x - ix;
    const fz = z - iz;

    // Smoothstep
    const u = fx * fx * (3.0 - 2.0 * fx);
    const v = fz * fz * (3.0 - 2.0 * fz);

    // Bilinear interpolation of hash values
    const a = hash2d(ix, iz);
    const b = hash2d(ix + 1, iz);
    const c = hash2d(ix, iz + 1);
    const d = hash2d(ix + 1, iz + 1);

    return lerp(lerp(a, b, u), lerp(c, d, u), v);
}

const NoiseOptions = struct { frequency: f32, amplitude: f32, seed: f32, lacunarity: f32, persistence: f32, octaves: c_int };
pub fn sampleNoise(x: f32, z: f32, options: NoiseOptions) f32 {
    var total: f32 = 0;
    var freq = options.frequency;
    var amp: f32 = options.amplitude;

    var i: i32 = 0;
    while (i < options.octaves) : (i += 1) {
        total += smoothNoise(x * freq + options.seed, z * freq + (options.seed)) * amp;
        freq *= options.lacunarity;
        amp *= options.persistence;
    }
    return total;
}

fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}
