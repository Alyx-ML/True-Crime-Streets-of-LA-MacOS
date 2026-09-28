#include <metal_stdlib>
using namespace metal;

struct Vertex {
    float4 position;
    float4 color;
    float4 specular;
    float4 normal;
    float4 viewPosition;
    float4 uv[8];
};
struct Transforms {
    float4x4 worldView, clip;
    float3x3 normal;
    uint4 flags;
};
struct TextureTransforms {
    float4x4 matrices[8];
    uint4 settings[8];
};
struct Light {
    float4 diffuse, ambient, specular, position, direction, attenuation, spot;
};
struct Lighting {
    float4 diffuse, ambient, specular, emissive, globalAmbient;
    uint4 flags, sources;
    float4 parameters;
    Light lights[8];
};
struct Fog {
    float4 color, parameters;
    uint4 modes;
};
struct Combiner {
    uint4 color, alpha;
    float4 factor;
    uint4 extra;
};
static float4 texture_argument(uint argument,float4 diffuse,float4 current,float4 texel,float4 factor,float4 specular,float4 temporary) {
    float4 value=diffuse;
    switch(argument&15){case 1:value=current;break;case 2:value=texel;break;
        case 3:value=factor;break;case 4:value=specular;break;case 5:value=temporary;break;}
    if (argument & 0x20) value = float4(value.a);
    return (argument & 0x10) ? 1 - value : value;
}
static float4 texture_operation(uint operation, float4 first, float4 second, float4 third,
                                float diffuseAlpha, float currentAlpha, float textureAlpha, float factorAlpha) {
    switch (operation) {
        case 2: return first;
        case 3: return second;
        case 4: return first * second;
        case 5: return saturate(2 * first * second);
        case 6: return saturate(4 * first * second);
        case 7: return saturate(first + second);
        case 8: return saturate(first + second - 0.5f);
        case 9: return saturate(2 * (first + second - 0.5f));
        case 10: return saturate(first - second);
        case 11: return saturate(first + second * (1 - first));
        case 12: return mix(second, first, diffuseAlpha);
        case 13: return mix(second, first, textureAlpha);
        case 14: return mix(second, first, factorAlpha);
        case 15: return saturate(first + second * (1 - textureAlpha));
        case 16: return mix(second, first, currentAlpha);
        case 18: return saturate(first+first.a*second);
        case 19: return saturate(first*second+first.a);
        case 20: return saturate(first+(1-first.a)*second);
        case 21: return saturate((1-first)*second+first.a);
        case 24: return float4(saturate(dot(2*first.rgb-1,2*second.rgb-1)));
        case 25: return saturate(third+first*second);
        case 26: return saturate(mix(second,first,third));
    }
    return first;
}
struct Fragment {
    float4 position [[position]];
    float4 color;
    float3 uv0, uv1, uv2, uv3, uv4, uv5, uv6, uv7;
    float3 specular;
    float4 specularInput;
    float fogFactor [[center_no_perspective]];
    float eyeDepth;
};

static float fog_factor(uint mode, float distance, float4 parameters) {
    if (mode == 1) return saturate(exp(-parameters.z * distance));
    if (mode == 2) {
        float scaled = parameters.z * distance;
        return saturate(exp(-scaled * scaled));
    }
    if (mode == 3) {
        float interval = parameters.y - parameters.x;
        return interval == 0 ? (distance <= parameters.x ? 1.0f : 0.0f)
            : saturate((parameters.y - distance) / interval);
    }
    return 1;
}

static float3 unit_vector(float3 value) {
    float magnitude = length(value);
    return magnitude > 0 ? value / magnitude : float3(0);
}
static float4 material_color(uint source, float4 material, float4 color, float4 specular) {
    return source == 1 ? color : source == 2 ? specular : material;
}
static float3 texture_coordinate(thread const Vertex &input,constant TextureTransforms &transforms,
                                 uint stage,bool pretransformed,bool normalizeNormal) {
    uint4 setting=transforms.settings[stage];
    if(!setting.w)return float3(0,0,1);
    uint generated=setting.x>>16;
    float4 value=input.uv[setting.x&7];uint count=setting.z&255;
    float3 normal=normalizeNormal?unit_vector(input.normal.xyz):input.normal.xyz;
    if(generated==1)value=float4(normal,1);
    else if(generated==2)value=input.viewPosition;
    else if(generated==3)value=float4(reflect(unit_vector(input.viewPosition.xyz),normal),1);
    if(count&&!pretransformed) {
        // Fixed-function texture transforms append 1 immediately after the
        // supplied components rather than always placing it in W.
        if(setting.y<4)value[setting.y]=1;
        value=transforms.matrices[stage]*value;
    }
    if(!count)count=setting.y;
    float3 result=float3(value.x,count>1?value.y:0,1);
    if(setting.z&256){result.z=value[count-1];if(count==2)result.y=0;}
    return result;
}
vertex Fragment vs(device const Vertex *vertices [[buffer(0)]], uint index [[vertex_id]],
                   constant Lighting &lighting [[buffer(1)]], constant Fog &fog [[buffer(2)]],
                   constant Transforms &transforms [[buffer(3)]],
                   constant TextureTransforms &textureTransforms [[buffer(4)]]) {
    Vertex input = vertices[index];
    if (!transforms.flags.x) {
        input.viewPosition = transforms.worldView * input.position;
        input.position = transforms.clip * input.position;
        input.normal = float4(transforms.normal * input.normal.xyz, 0);
    }
    Fragment result;
    result.position = input.position;
    result.color = input.color;
    result.uv0=texture_coordinate(input,textureTransforms,0,transforms.flags.x,lighting.parameters.y);
    result.uv1=texture_coordinate(input,textureTransforms,1,transforms.flags.x,lighting.parameters.y);
    result.uv2=texture_coordinate(input,textureTransforms,2,transforms.flags.x,lighting.parameters.y);
    result.uv3=texture_coordinate(input,textureTransforms,3,transforms.flags.x,lighting.parameters.y);
    result.uv4=texture_coordinate(input,textureTransforms,4,transforms.flags.x,lighting.parameters.y);
    result.uv5=texture_coordinate(input,textureTransforms,5,transforms.flags.x,lighting.parameters.y);
    result.uv6=texture_coordinate(input,textureTransforms,6,transforms.flags.x,lighting.parameters.y);
    result.uv7=texture_coordinate(input,textureTransforms,7,transforms.flags.x,lighting.parameters.y);
    result.specular = lighting.flags.z ? input.specular.rgb : float3(0);
    result.specularInput=transforms.flags.y?input.specular:float4(1);
    result.eyeDepth = input.position.w;
    result.fogFactor = input.specular.a;
    if (fog.modes.x && !fog.modes.y && fog.modes.z) {
        float distance = (fog.modes.w & 2) ? length(input.viewPosition.xyz) : abs(input.viewPosition.z);
        result.fogFactor = fog_factor(fog.modes.z, distance, fog.parameters);
    }
    if (lighting.flags.x) {
        float4 diffuse = material_color(lighting.sources.x, lighting.diffuse, input.color, input.specular);
        float3 ambient = material_color(lighting.sources.y, lighting.ambient, input.color, input.specular).rgb;
        float3 specular = material_color(lighting.sources.z, lighting.specular, input.color, input.specular).rgb;
        float3 emission = material_color(lighting.sources.w, lighting.emissive, input.color, input.specular).rgb;
        float3 normal = lighting.parameters.y ? unit_vector(input.normal.xyz) : input.normal.xyz;
        float3 eye = lighting.flags.w ? unit_vector(-input.viewPosition.xyz) : float3(0, 0, -1);
        float3 color = emission + ambient * lighting.globalAmbient.rgb;
        float3 highlight = 0;
        for (uint i = 0; i < lighting.flags.y; i++) {
            Light light = lighting.lights[i];
            float3 direction;
            float strength = 1;
            if (light.position.w == 3) {
                direction = unit_vector(-light.direction.xyz);
            } else {
                float3 difference = light.position.xyz - input.viewPosition.xyz;
                float distance = length(difference);
                if (distance > light.direction.w) continue;
                direction = unit_vector(difference);
                float attenuation = light.attenuation.x + light.attenuation.y * distance
                    + light.attenuation.z * distance * distance;
                strength = attenuation > 0 ? 1 / attenuation : 0;
                if (light.position.w == 2) {
                    float cosine = dot(unit_vector(-light.direction.xyz), direction);
                    float spot = cosine >= light.spot.x ? 1 : cosine <= light.spot.y ? 0
                        : pow((cosine - light.spot.y) / (light.spot.x - light.spot.y), light.attenuation.w);
                    strength *= spot;
                }
            }
            float incidence = max(dot(normal, direction), 0.0f);
            color += strength * (ambient * light.ambient.rgb + diffuse.rgb * light.diffuse.rgb * incidence);
            if (lighting.flags.z && incidence > 0) {
                float halfway = max(dot(normal, unit_vector(direction + eye)), 0.0f);
                highlight += strength * specular * light.specular.rgb * pow(halfway, lighting.parameters.x);
            }
        }
        result.color = saturate(float4(color, diffuse.a));
        result.specular = saturate(highlight);
        result.specularInput=float4(result.specular,0);
    }
    return result;
}

fragment float4 fs(Fragment input [[stage_in]], array<texture2d<float>,8> textures [[texture(0)]],
                   array<sampler,8> samplers [[sampler(0)]], constant Combiner *combiners [[buffer(0)]],
                   constant float *lodBias [[buffer(1)]], constant uint4 &alphaTest [[buffer(2)]],
                   constant Fog &fog [[buffer(3)]]) {
    float4 color = input.color,temporary=0;
    float3 uv[]={input.uv0,input.uv1,input.uv2,input.uv3,input.uv4,input.uv5,input.uv6,input.uv7};
    for(uint stage=0;stage<8;stage++) {
        Combiner combiner=combiners[stage];
        if(combiner.color.x<=1)break;
        float4 texel = float4(1);
        if (combiner.alpha.w) {
            float3 coordinate=uv[stage];
            texel=textures[stage].sample(samplers[stage],coordinate.xy/coordinate.z,bias(lodBias[stage]));
        }
        if (combiner.color.w&1) texel.a = 1;
        float4 previous=color,mixed;
        float4 first = texture_argument(combiner.color.y,input.color,previous,texel,combiner.factor,input.specularInput,temporary);
        float4 second = texture_argument(combiner.color.z,input.color,previous,texel,combiner.factor,input.specularInput,temporary);
        float4 third = texture_argument(combiner.extra.x,input.color,previous,texel,combiner.factor,input.specularInput,temporary);
        mixed.rgb = texture_operation(combiner.color.x, first, second, third,
            input.color.a, previous.a, texel.a, combiner.factor.a).rgb;
        first = texture_argument(combiner.alpha.y,input.color,previous,texel,combiner.factor,input.specularInput,temporary);
        second = texture_argument(combiner.alpha.z,input.color,previous,texel,combiner.factor,input.specularInput,temporary);
        third = texture_argument(combiner.extra.y,input.color,previous,texel,combiner.factor,input.specularInput,temporary);
        mixed.a = texture_operation(combiner.alpha.x, first, second, third,
            input.color.a, previous.a, texel.a, combiner.factor.a).a;
        if(combiner.extra.z==5)temporary=mixed;else color=mixed;
    }
    color.rgb = saturate(color.rgb + input.specular);
    if (alphaTest.x) {
        float reference = float(alphaTest.z) / 255.0f;
        bool pass = false;
        switch (alphaTest.y) {
            case 1: break;
            case 2: pass = color.a < reference; break;
            case 3: pass = color.a == reference; break;
            case 4: pass = color.a <= reference; break;
            case 5: pass = color.a > reference; break;
            case 6: pass = color.a != reference; break;
            case 7: pass = color.a >= reference; break;
            case 8: pass = true; break;
        }
        /* Alpha-to-coverage (GREATER/GREATEREQUAL, unblended, multisampled):
           sharpen alpha to a one-pixel ramp at the reference so cutout edges
           resolve smoothly instead of stair-stepping. */
        if (alphaTest.w) {
            color.a = saturate((color.a - reference) / max(fwidth(color.a), 1e-4f) + 0.5f);
            pass = color.a > 0;
        }
        if (!pass) discard_fragment();
    }
    if (fog.modes.x) {
        float factor = fog.modes.y ? fog_factor(fog.modes.y,
            (fog.modes.w & 1) ? input.eyeDepth : input.position.z, fog.parameters) : saturate(input.fogFactor);
        color.rgb = mix(fog.color.rgb, color.rgb, factor);
    }
    return color;
}

/* EDR output: expand the SDR back buffer into extended linear sRGB.
   Paper white scales mid-tones; highlights ramp toward the display's peak. */
struct PresentVertex { float4 position [[position]]; float2 uv; };
vertex PresentVertex present_vs(uint index [[vertex_id]]) {
    float2 uv = float2((index << 1) & 2, index & 2);
    return { float4(uv * float2(2, -2) + float2(-1, 1), 0, 1), uv };
}
fragment float4 present_hdr_fs(PresentVertex input [[stage_in]], texture2d<float> source [[texture(0)]],
                               constant float2 &levels [[buffer(0)]]) {
    constexpr sampler nearest(filter::nearest);
    float3 c = source.sample(nearest, input.uv).rgb;
    float3 linear = select(pow((c + 0.055) / 1.055, 2.4), c / 12.92, c <= 0.04045);
    float paper = levels.x, peak = max(levels.y, paper);
    float luma = dot(linear, float3(0.2126, 0.7152, 0.0722));
    float t = smoothstep(0.6, 1.0, luma);
    return float4(linear * paper * mix(1.0, peak / paper, t * t), 1);
}
