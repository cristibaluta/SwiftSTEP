#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float4x4 viewProjection;
    float4 color;
    float4 light;      // xyz: direction toward the light
    float ambient;     // share of the colour that shows on faces turned away from the light
};

struct LineVertex {
    float3 position [[attribute(0)]];
};

struct SolidVertex {
    float3 position [[attribute(0)]];
    float3 normal   [[attribute(1)]];
};

struct LineOut {
    float4 position [[position]];
};

struct SolidOut {
    float4 position [[position]];
    float3 normal;
};

vertex LineOut line_vertex(LineVertex in [[stage_in]], constant Uniforms& u [[buffer(1)]]) {
    LineOut out;
    out.position = u.viewProjection * float4(in.position, 1.0);
    return out;
}

fragment float4 line_fragment(LineOut in [[stage_in]], constant Uniforms& u [[buffer(1)]]) {
    return u.color;
}

vertex SolidOut solid_vertex(SolidVertex in [[stage_in]], constant Uniforms& u [[buffer(1)]]) {
    SolidOut out;
    out.position = u.viewProjection * float4(in.position, 1.0);
    out.normal = in.normal;   // positions are already in world space: no model matrix
    return out;
}

fragment float4 solid_fragment(SolidOut in [[stage_in]], constant Uniforms& u [[buffer(1)]]) {
    float3 n = normalize(in.normal);
    float diffuse = max(dot(n, normalize(u.light.xyz)), 0.0);
    float lit = u.ambient + (1.0 - u.ambient) * diffuse;
    return float4(u.color.rgb * lit, u.color.a);
}
