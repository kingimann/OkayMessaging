#version 460 core
#include <flutter/runtime_effect.glsl>

// Liquid Glass: the part a gradient cannot fake.
//
// A blur plus a tint gives you frosted plastic. What makes Apple's material
// read as GLASS is that the edge behaves like the rim of a real lens: it
// BENDS what is behind it, so straight lines passing under the panel kink
// as they cross the boundary, and light collects along the curve.
//
// This shader does exactly that and nothing else — the tint, the sheen and
// the shadow stay in Dart where they are easy to tune. It samples the
// already-blurred backdrop, displaces the sample toward the panel's centre
// near the edge (refraction), and adds a specular term along the rim.
//
// Uniform ORDER IS THE CONTRACT: the engine writes the bound texture's size
// into the first vec2, and binds the first sampler2D to the filter input.

uniform vec2 uSize;

// Corner radius, in the same pixels as uSize.
uniform float uRadius;

// How wide the lens band is — how far in from the edge the bending reaches.
uniform float uEdge;

// How hard it bends. 0 is a flat pane; higher is a thicker, rounder edge.
uniform float uRefract;

// Strength of the specular highlight along the rim.
uniform float uSpecular;

// 1.0 in light mode, 0.0 in dark — the highlight is white either way, but a
// dark panel needs less of it before it reads as smeared.
uniform float uLight;

uniform sampler2D uTexture;

out vec4 fragColor;

// Signed distance to a rounded rectangle. Negative inside.
float roundedBoxSdf(vec2 p, vec2 halfSize, float r) {
  vec2 q = abs(p) - halfSize + r;
  return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
}

void main() {
  vec2 frag = FlutterFragCoord().xy;
  vec2 uv = frag / uSize;
#ifdef IMPELLER_TARGET_OPENGLES
  uv.y = 1.0 - uv.y;
#endif

  vec2 halfSize = uSize * 0.5;
  vec2 p = frag - halfSize;
  float r = min(uRadius, min(halfSize.x, halfSize.y));
  float d = roundedBoxSdf(p, halfSize, r);

  // Outside the pane: hand the backdrop back untouched. The clip should
  // already have removed these pixels; not assuming so costs one branch and
  // means a mismatch degrades to "no effect" rather than to garbage.
  if (d > 0.0) {
    fragColor = texture(uTexture, uv);
    return;
  }

  // 0 at the centre-side of the lens band, 1 right at the rim.
  float band = clamp(1.0 + d / max(uEdge, 1.0), 0.0, 1.0);
  // Cubed rather than linear: a real lens is almost flat across the middle
  // and bends sharply in the last sliver. Linear looks like a dent.
  float bend = band * band * band;

  // The inward normal — the direction the SDF grows — found by sampling it.
  // Cheaper and steadier than an analytic derivative at the corners, where
  // the analytic one flips sign across the diagonal.
  vec2 e = vec2(1.0, 0.0);
  vec2 grad = vec2(
    roundedBoxSdf(p + e.xy, halfSize, r) - roundedBoxSdf(p - e.xy, halfSize, r),
    roundedBoxSdf(p + e.yx, halfSize, r) - roundedBoxSdf(p - e.yx, halfSize, r)
  );
  float glen = length(grad);
  vec2 normal = glen > 0.0001 ? grad / glen : vec2(0.0);

  // Pull the sample INWARD near the rim: what is behind the edge appears
  // squeezed toward the panel's middle, which is what a convex edge does.
  vec2 offset = -normal * bend * uRefract;
  vec2 sampleUv = clamp((frag + offset) / uSize, vec2(0.0), vec2(1.0));
#ifdef IMPELLER_TARGET_OPENGLES
  sampleUv.y = 1.0 - sampleUv.y;
#endif

  vec4 color = texture(uTexture, sampleUv);

  // Specular: light from the upper left, so the top-left rim lifts and the
  // bottom-right catches a weaker second highlight — the way a lit bead of
  // glass does. A rim that glows evenly all the way round reads as a
  // drawn outline.
  vec2 lightDir = normalize(vec2(-0.6, -0.8));
  float facing = max(dot(normal, lightDir), 0.0);
  float back = max(dot(normal, -lightDir), 0.0);
  float spec = (pow(facing, 2.0) + pow(back, 5.0) * 0.35) * bend * uSpecular;
  // A dark panel needs a lighter touch before the rim looks smeared.
  spec *= mix(0.72, 1.0, uLight);

  fragColor = vec4(color.rgb + spec * color.a, color.a);
}
