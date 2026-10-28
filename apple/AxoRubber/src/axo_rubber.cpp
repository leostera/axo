#include "axo_rubber.h"

#include <Box2D/Box2D.h>

#include <algorithm>
#include <cmath>
#include <vector>

namespace {

/// Points to the metre: LiquidFun is tuned for things about a metre across.
constexpr float kPointsPerMetre = 20.0f;
/// Particles this far apart, in points: a 28 x 16 icon is a 15 x 9 grid.
constexpr float kSpacing = 2.0f;
/// LiquidFun lays particles out three quarters of a diameter apart.
constexpr float kParticleRadius = kSpacing / (2 * 0.75f);
/// The particles this near the grab, in points, are what is held: about a gill's worth.
constexpr float kGrabRadius = 6.5f;
/// While it is pulled, how firmly a particle is held to its place (per second squared) and how
/// quickly its motion dies away (per second): the far side of the icon fully, the grabbed part
/// not at all, eased in between, so the far side holds on and the rest stretches.
constexpr float kHome = 30000.0f;
constexpr float kDamping = 12.0f;
/// Let go, all of it springs back: on a softer, looser spring (about 6 wobbles a second), so it
/// overshoots and wobbles into place.
constexpr float kReturn = 1500.0f;
constexpr float kReturnDamping = 6.0f;
constexpr float kStep = 1.0f / 240.0f;

b2Vec2 metres(float x, float y) { return b2Vec2(x / kPointsPerMetre, y / kPointsPerMetre); }

}  // namespace

struct AxoRubber {
  b2World world{b2Vec2(0, 0)};
  b2ParticleSystem *system = nullptr;
  int32_t columns = 0;
  int32_t rows = 0;
  float width = 0;
  /// Each particle's place on the icon.
  std::vector<b2Vec2> home;
  /// How firmly each is held there, 0 to 1.
  std::vector<float> hold;
  std::vector<int32> grabbed;
  std::vector<b2Vec2> grabOffsets;
  b2Vec2 grab;
  bool holding = false;
  float pending = 0;
  int32 particleIterations = 1;
};

namespace {

void step(AxoRubber *rubber) {
  b2Vec2 *positions = rubber->system->GetPositionBuffer();
  b2Vec2 *velocities = rubber->system->GetVelocityBuffer();
  const int32 count = rubber->system->GetParticleCount();
  for (int32 i = 0; i < count; i++) {
    const float k = rubber->holding ? kHome * rubber->hold[i] : kReturn;
    const float damping = rubber->holding ? kDamping : kReturnDamping;
    velocities[i] += kStep * k * (rubber->home[i] - positions[i]);
    velocities[i] *= std::max(0.0f, 1 - damping * kStep);
  }
  if (rubber->holding) {
    // The grabbed particles go where the pointer is, through their velocity, so the rest feels it.
    for (size_t k = 0; k < rubber->grabbed.size(); k++) {
      const int32 i = rubber->grabbed[k];
      velocities[i] = (1 / kStep) * (rubber->grab + rubber->grabOffsets[k] - positions[i]);
    }
  }
  rubber->world.Step(kStep, 1, 1, rubber->particleIterations);
}

}  // namespace

extern "C" {

AxoRubber *axo_rubber_create(float x, float y, float width, float height) {
  AxoRubber *rubber = new AxoRubber();
  rubber->columns = std::max(2, int32_t(std::lround(width / kSpacing)) + 1);
  rubber->rows = std::max(2, int32_t(std::lround(height / kSpacing)) + 1);
  rubber->width = width;
  b2ParticleSystemDef def;
  def.radius = kParticleRadius / kPointsPerMetre;
  def.elasticStrength = 0.2f;
  def.springStrength = 0.2f;
  def.pressureStrength = 0;
  rubber->system = rubber->world.CreateParticleSystem(&def);

  for (int32 row = 0; row < rubber->rows; row++) {
    for (int32 column = 0; column < rubber->columns; column++) {
      rubber->home.push_back(metres(x + width * float(column) / float(rubber->columns - 1),
                                    y + height * float(row) / float(rubber->rows - 1)));
    }
  }
  rubber->hold.assign(rubber->home.size(), 1.0f);
  // One group, so it is one body: springs and elastic triangles between neighbours.
  b2ParticleGroupDef group;
  group.flags = b2_elasticParticle | b2_springParticle;
  group.groupFlags = b2_solidParticleGroup;
  group.particleCount = int32(rubber->home.size());
  group.positionData = rubber->home.data();
  rubber->system->CreateParticleGroup(group);
  rubber->particleIterations = rubber->world.CalculateReasonableParticleIterations(kStep);
  return rubber;
}

void axo_rubber_destroy(AxoRubber *rubber) { delete rubber; }

int32_t axo_rubber_columns(const AxoRubber *rubber) { return rubber->columns; }
int32_t axo_rubber_rows(const AxoRubber *rubber) { return rubber->rows; }

void axo_rubber_points(const AxoRubber *rubber, float *xy) {
  const b2Vec2 *positions = rubber->system->GetPositionBuffer();
  for (int32 i = 0; i < rubber->system->GetParticleCount(); i++) {
    xy[2 * i] = positions[i].x * kPointsPerMetre;
    xy[2 * i + 1] = positions[i].y * kPointsPerMetre;
  }
}

void axo_rubber_grab(AxoRubber *rubber, float x, float y) {
  const b2Vec2 at = metres(x, y);
  const b2Vec2 *positions = rubber->system->GetPositionBuffer();
  rubber->grabbed.clear();
  rubber->grabOffsets.clear();
  int32 nearest = 0;
  for (int32 i = 0; i < int32(rubber->home.size()); i++) {
    const float distance = (rubber->home[i] - at).Length() * kPointsPerMetre;
    if ((rubber->home[i] - at).Length() < (rubber->home[nearest] - at).Length()) nearest = i;
    if (distance <= kGrabRadius) {
      rubber->grabbed.push_back(i);
      rubber->grabOffsets.push_back(positions[i] - at);
    }
    // Held less the nearer the grab, over most of the icon: so it all leans into the pull, and
    // the far side holds.
    const float reach = rubber->width * 0.6f;
    const float t = std::min(1.0f, std::max(0.0f, (distance - kGrabRadius) / reach));
    rubber->hold[i] = t * t * (3 - 2 * t);
  }
  if (rubber->grabbed.empty()) {
    rubber->grabbed.push_back(nearest);
    rubber->grabOffsets.push_back(positions[nearest] - at);
  }
  rubber->grab = at;
  rubber->holding = true;
}

void axo_rubber_move(AxoRubber *rubber, float x, float y) { rubber->grab = metres(x, y); }

void axo_rubber_let_go(AxoRubber *rubber) { rubber->holding = false; }

float axo_rubber_stretch(const AxoRubber *rubber) {
  if (rubber->grabbed.empty()) return 0;
  const b2Vec2 *positions = rubber->system->GetPositionBuffer();
  b2Vec2 offset(0, 0);
  for (int32 i : rubber->grabbed) offset += positions[i] - rubber->home[i];
  return offset.Length() / float(rubber->grabbed.size()) * kPointsPerMetre;
}

bool axo_rubber_at_rest(const AxoRubber *rubber) {
  if (rubber->holding) return false;
  const b2Vec2 *positions = rubber->system->GetPositionBuffer();
  const b2Vec2 *velocities = rubber->system->GetVelocityBuffer();
  for (int32 i = 0; i < rubber->system->GetParticleCount(); i++) {
    if ((positions[i] - rubber->home[i]).Length() * kPointsPerMetre > 0.25f) return false;
    if (velocities[i].Length() * kPointsPerMetre > 4) return false;
  }
  return true;
}

void axo_rubber_step(AxoRubber *rubber, float seconds) {
  // A long stall (the app was busy) is not simulated in full.
  rubber->pending = std::min(rubber->pending + seconds, 0.1f);
  while (rubber->pending >= kStep) {
    rubber->pending -= kStep;
    step(rubber);
  }
}

}  // extern "C"
