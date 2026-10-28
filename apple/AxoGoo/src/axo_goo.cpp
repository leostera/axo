#include "axo_goo.h"

#include <Box2D/Box2D.h>

#include <algorithm>
#include <cmath>
#include <vector>

namespace {

/// Points to the metre: LiquidFun is tuned for things about a metre across.
constexpr float kPointsPerMetre = 20.0f;
/// Each particle, in points.
constexpr float kParticleRadius = 1.6f;
/// The fluid blob it starts as, and the two hands, in points.
constexpr float kFluidRadius = 28.0f;
constexpr float kIconHandRadius = 6.0f;
constexpr float kAxoHandRadius = 15.0f;
/// Gravity, points per second squared: enough to make the goo droop.
constexpr float kGravity = 500.0f;
constexpr float kStep = 1.0f / 120.0f;
/// How fast goo flows home after the snap, and how near home it is taken in.
/// How much stronger the goo holds on to the hands than to itself: so it snaps in the strand, not
/// at either end.
constexpr float kAdhesion = 2.0f;
constexpr float kTakeBackSpeed = 900.0f;
constexpr float kTakenIn = 5.0f;
/// How fast the icon's end is drawn up into the menu bar after the snap, points per second.
constexpr float kIconRetreat = 160.0f;
/// The two hands are kept this far apart, centre to centre, so they never overlap.
constexpr float kHandGap = kIconHandRadius + kAxoHandRadius + 2 * kParticleRadius;

/// The metaball kernel's reach, in points, and where its surface and outline are.
constexpr float kReach = kParticleRadius * 4.5f;
constexpr float kSurface = 1.6f;
constexpr float kOutline = 0.8f;
/// The outline's width is about this many pixels of blending at each edge.
constexpr float kEdge = 0.08f;

b2Vec2 metres(float x, float y) { return b2Vec2(x / kPointsPerMetre, y / kPointsPerMetre); }

/// Particles held in shape and moved to wherever its centre is. The hands are the first
/// particles in the buffer and lose none, so their indices hold while fluid is taken away.
struct Hand {
  int32 first = 0;
  b2Vec2 centre;
  /// Each particle's place from the centre.
  std::vector<b2Vec2> offsets;
  int32 count() const { return int32(offsets.size()); }
  bool contains(int32 index) const { return index >= first && index < first + count(); }
};

/// The particles in a disc `radius` across around (x, y), a particle apart on a hex grid, in
/// points; leaving out those `keepOut` says no to.
template <typename KeepOut>
std::vector<b2Vec2> disc(float x, float y, float radius, KeepOut keepOut) {
  const float spacing = 2 * kParticleRadius * 0.75f;
  std::vector<b2Vec2> points;
  for (int row = 0; float(row) * spacing * 0.866f <= 2 * radius; row++) {
    const float py = y - radius + float(row) * spacing * 0.866f;
    for (int column = 0; float(column) * spacing <= 2 * radius + spacing; column++) {
      const float px = x - radius + float(column) * spacing + (row % 2 ? spacing / 2 : 0);
      if (std::hypot(px - x, py - y) > radius || keepOut(px, py)) continue;
      points.push_back(b2Vec2(px, py));
    }
  }
  return points;
}

}  // namespace

struct AxoGoo {
  b2World world{b2Vec2(0, -kGravity / kPointsPerMetre)};
  b2ParticleSystem *system = nullptr;
  Hand icon;
  Hand axo;
  int32_t particleIterations = 1;
  float pending = 0;
  bool takingBack = false;
  /// How far each hand's particles are from where they started around its centre: they draw in
  /// once the goo has snapped.
  float handSpread = 1;
};

namespace {

/// Moves each of the hand's particles to its place, through its velocity, so the fluid feels it.
void drive(AxoGoo *goo, const Hand &hand, float dt) {
  b2Vec2 *positions = goo->system->GetPositionBuffer();
  b2Vec2 *velocities = goo->system->GetVelocityBuffer();
  for (int32 k = 0; k < hand.count(); k++) {
    const b2Vec2 target = hand.centre + goo->handSpread * hand.offsets[k];
    velocities[hand.first + k] = (1.0f / dt) * (target - positions[hand.first + k]);
  }
}

/// For each particle, which end it is joined to through touching or bonded particles: 1 the icon, 2 Axo,
/// 3 both, 0 neither.
std::vector<uint8_t> reach(const AxoGoo *goo) {
  const int32 count = goo->system->GetParticleCount();
  std::vector<std::vector<int32>> touching(count);
  const b2ParticleContact *contacts = goo->system->GetContacts();
  for (int32 c = 0; c < goo->system->GetContactCount(); c++) {
    touching[contacts[c].GetIndexA()].push_back(contacts[c].GetIndexB());
    touching[contacts[c].GetIndexB()].push_back(contacts[c].GetIndexA());
  }
  // Bonded counts as joined too: a stretched strand's particles are further apart than touching.
  const b2ParticlePair *pairs = goo->system->GetPairs();
  for (int32 k = 0; k < goo->system->GetPairCount(); k++) {
    if (!(pairs[k].flags & b2_springParticle) || pairs[k].indexA < 0 || pairs[k].indexB < 0) continue;
    touching[pairs[k].indexA].push_back(pairs[k].indexB);
    touching[pairs[k].indexB].push_back(pairs[k].indexA);
  }
  std::vector<uint8_t> joined(count, 0);
  for (uint8_t end : {uint8_t(1), uint8_t(2)}) {
    const Hand &hand = end == 1 ? goo->icon : goo->axo;
    std::vector<int32> queue;
    for (int32 i = hand.first; i < hand.first + hand.count(); i++) {
      joined[i] |= end;
      queue.push_back(i);
    }
    while (!queue.empty()) {
      const int32 i = queue.back();
      queue.pop_back();
      for (int32 j : touching[i]) {
        if (joined[j] & end) continue;
        joined[j] |= end;
        queue.push_back(j);
      }
    }
  }
  return joined;
}

/// After the snap: the fluid flows home, and is taken in there.
void takeBack(AxoGoo *goo) {
  const std::vector<uint8_t> joined = reach(goo);
  b2Vec2 *positions = goo->system->GetPositionBuffer();
  b2Vec2 *velocities = goo->system->GetVelocityBuffer();
  const float speed = kTakeBackSpeed / kPointsPerMetre;
  for (int32 i = 0; i < goo->system->GetParticleCount(); i++) {
    if (goo->icon.contains(i) || goo->axo.contains(i)) continue;
    const b2Vec2 toIcon = goo->icon.centre - positions[i];
    const b2Vec2 toAxo = goo->axo.centre - positions[i];
    const bool homeIsIcon = joined[i] == 1 || (joined[i] != 2 && toIcon.Length() < toAxo.Length());
    b2Vec2 home = homeIsIcon ? toIcon : toAxo;
    const float distance = home.Normalize();
    if (distance * kPointsPerMetre < kTakenIn) {
      goo->system->DestroyParticle(i);
      continue;
    }
    // Eased in, so it still moves like the fluid it is.
    velocities[i] = 0.65f * velocities[i] + 0.35f * (speed * home);
  }
}

}  // namespace

extern "C" {

AxoGoo *axo_goo_create(float iconX, float iconY, float axoX, float axoY) {
  AxoGoo *goo = new AxoGoo();
  b2ParticleSystemDef def;
  def.radius = kParticleRadius / kPointsPerMetre;
  def.viscousStrength = 1.0f;
  def.surfaceTensionPressureStrength = 0.3f;
  def.surfaceTensionNormalStrength = 0.3f;
  def.dampingStrength = 0.6f;
  def.pressureStrength = 0.05f;
  def.springStrength = 0.5f;
  def.springYield = 0.1f;
  def.springPlasticity = 100.0f;
  def.springBreak = 5.0f;
  goo->system = goo->world.CreateParticleSystem(&def);

  // Axo's hand starts just under the icon's, touching it, and is moved to Axo from there: two
  // hands made overlapping would push each other apart at once.
  const float startX = iconX, startY = iconY - kHandGap;
  // Close enough to touch (particles touch within a diameter), not to overlap.
  const float clear = 1.2f * kParticleRadius;
  auto none = [](float, float) { return false; };
  std::vector<b2Vec2> points = disc(iconX, iconY, kIconHandRadius, none);
  goo->icon.first = 0;
  for (const b2Vec2 &p : points) goo->icon.offsets.push_back(metres(p.x - iconX, p.y - iconY));
  goo->icon.centre = metres(iconX, iconY);
  const std::vector<b2Vec2> axoHand = disc(startX, startY, kAxoHandRadius, none);
  goo->axo.first = int32(points.size());
  for (const b2Vec2 &p : axoHand) goo->axo.offsets.push_back(metres(p.x - startX, p.y - startY));
  goo->axo.centre = metres(startX, startY);
  points.insert(points.end(), axoHand.begin(), axoHand.end());
  // The fluid: a blob around both, with room left around the hands, since overlapping particles
  // burst apart.
  const std::vector<b2Vec2> fluid = disc(iconX, iconY - kHandGap / 2, kFluidRadius, [&](float x, float y) {
    return std::hypot(x - iconX, y - iconY) < kIconHandRadius + clear ||
           std::hypot(x - startX, y - startY) < kAxoHandRadius + clear;
  });
  points.insert(points.end(), fluid.begin(), fluid.end());
  for (b2Vec2 &p : points) p = metres(p.x, p.y);

  // One group, so springs join every particle to its neighbours, the hands' to the fluid's.
  b2ParticleGroupDef group;
  group.flags = b2_springParticle | b2_viscousParticle | b2_tensileParticle;
  group.groupFlags = b2_particleGroupCanBeEmpty;
  group.particleCount = int32(points.size());
  group.positionData = points.data();
  goo->system->CreateParticleGroup(group);
  // LiquidFun gives every bond in a group the same strength, and only reads them; the pairs are
  // ours to set before the first step.
  b2ParticlePair *pairs = const_cast<b2ParticlePair *>(goo->system->GetPairs());
  for (int32 k = 0; k < goo->system->GetPairCount(); k++) {
    const bool a = goo->icon.contains(pairs[k].indexA) || goo->axo.contains(pairs[k].indexA);
    const bool b = goo->icon.contains(pairs[k].indexB) || goo->axo.contains(pairs[k].indexB);
    if (a != b) pairs[k].strength = kAdhesion;
  }
  goo->particleIterations = goo->world.CalculateReasonableParticleIterations(kStep);
  // Settled for a moment, so the particles touch before Axo pulls.
  for (int i = 0; i < 12; i++) {
    drive(goo, goo->icon, kStep);
    drive(goo, goo->axo, kStep);
    goo->world.Step(kStep, 1, 1, goo->particleIterations);
  }
  axo_goo_move_axo(goo, axoX, axoY);

  return goo;
}

void axo_goo_destroy(AxoGoo *goo) { delete goo; }

void axo_goo_move_axo(AxoGoo *goo, float x, float y) {
  // Near the icon, Axo's hand stays a gap below it (the icon is in the menu bar, at the top).
  const b2Vec2 icon = goo->icon.centre;
  const b2Vec2 wanted = metres(x, y);
  const float gap = kHandGap / kPointsPerMetre;
  if ((wanted - icon).Length() >= gap) {
    goo->axo.centre = wanted;
  } else {
    const float across = std::max(-gap, std::min(gap, wanted.x - icon.x));
    goo->axo.centre = b2Vec2(wanted.x, icon.y - std::sqrt(gap * gap - across * across));
  }
}

void axo_goo_step(AxoGoo *goo, float seconds) {
  // A long stall (the app was busy) is not simulated in full.
  goo->pending = std::min(goo->pending + seconds, 0.1f);
  while (goo->pending >= kStep) {
    goo->pending -= kStep;
    drive(goo, goo->icon, kStep);
    drive(goo, goo->axo, kStep);
    if (goo->takingBack) {
      takeBack(goo);
      goo->handSpread *= 0.975f;
      goo->icon.centre.y += kIconRetreat / kPointsPerMetre * kStep;
    }
    goo->world.Step(kStep, 1, 1, goo->particleIterations);
  }
}

bool axo_goo_connected(AxoGoo *goo) {
  const std::vector<uint8_t> joined = reach(goo);
  return (joined[goo->icon.first] & 2) != 0;
}

void axo_goo_take_back(AxoGoo *goo) { goo->takingBack = true; }

int32_t axo_goo_fluid_count(const AxoGoo *goo) {
  return goo->system->GetParticleCount() - goo->icon.count() - goo->axo.count();
}

void axo_goo_split(const AxoGoo *goo, int32_t held[2]) {
  const std::vector<uint8_t> joined = reach(goo);
  held[0] = held[1] = 0;
  for (int32 i = 0; i < int32(joined.size()); i++) {
    if (goo->icon.contains(i) || goo->axo.contains(i)) continue;
    if (joined[i] & 1) held[0]++;
    if (joined[i] & 2) held[1]++;
  }
}

void axo_goo_bounds(const AxoGoo *goo, float bounds[4]) {
  const b2Vec2 *positions = goo->system->GetPositionBuffer();
  float minX = INFINITY, minY = INFINITY, maxX = -INFINITY, maxY = -INFINITY;
  for (int32 i = 0; i < goo->system->GetParticleCount(); i++) {
    minX = std::min(minX, positions[i].x);
    minY = std::min(minY, positions[i].y);
    maxX = std::max(maxX, positions[i].x);
    maxY = std::max(maxY, positions[i].y);
  }
  if (minX > maxX) {
    bounds[0] = bounds[1] = bounds[2] = bounds[3] = 0;
    return;
  }
  const float pad = kReach + 2;
  bounds[0] = minX * kPointsPerMetre - pad;
  bounds[1] = minY * kPointsPerMetre - pad;
  bounds[2] = (maxX - minX) * kPointsPerMetre + 2 * pad;
  bounds[3] = (maxY - minY) * kPointsPerMetre + 2 * pad;
}

void axo_goo_draw(const AxoGoo *goo, uint8_t *pixels, int32_t width, int32_t height, float originX, float originY,
                  float scale) {
  // The field: each particle adds (1 − d²/R²)², out to R.
  std::vector<float> field(size_t(width) * size_t(height), 0.0f);
  const b2Vec2 *positions = goo->system->GetPositionBuffer();
  const float reach = kReach * scale;
  const float reach2 = reach * reach;
  for (int32 i = 0; i < goo->system->GetParticleCount(); i++) {
    // Pixel space: x right, y down from the top row.
    const float px = (positions[i].x * kPointsPerMetre - originX) * scale;
    const float py = float(height) - (positions[i].y * kPointsPerMetre - originY) * scale;
    const int32_t x0 = std::max(0, int32_t(px - reach)), x1 = std::min(width - 1, int32_t(px + reach));
    const int32_t y0 = std::max(0, int32_t(py - reach)), y1 = std::min(height - 1, int32_t(py + reach));
    for (int32_t y = y0; y <= y1; y++) {
      const float dy = float(y) + 0.5f - py;
      float *row = &field[size_t(y) * size_t(width)];
      for (int32_t x = x0; x <= x1; x++) {
        const float dx = float(x) + 0.5f - px;
        const float d2 = dx * dx + dy * dy;
        if (d2 >= reach2) continue;
        const float k = 1.0f - d2 / reach2;
        row[x] += k * k;
      }
    }
  }
  // Stretched bonds, as threads: a capsule along each, thinner the longer it is (it keeps its
  // volume), so a strand still bonded reads as one even where its particles have drawn apart.
  const b2ParticlePair *pairs = goo->system->GetPairs();
  const float diameter = 2 * kParticleRadius;
  for (int32 k = 0; k < goo->system->GetPairCount(); k++) {
    const b2ParticlePair &pair = pairs[k];
    if (!(pair.flags & b2_springParticle) || pair.indexA < 0 || pair.indexB < 0) continue;
    if (goo->icon.contains(pair.indexA) && goo->icon.contains(pair.indexB)) continue;
    if (goo->axo.contains(pair.indexA) && goo->axo.contains(pair.indexB)) continue;
    const float ax = (positions[pair.indexA].x * kPointsPerMetre - originX) * scale;
    const float ay = float(height) - (positions[pair.indexA].y * kPointsPerMetre - originY) * scale;
    const float bx = (positions[pair.indexB].x * kPointsPerMetre - originX) * scale;
    const float by = float(height) - (positions[pair.indexB].y * kPointsPerMetre - originY) * scale;
    const float length = std::hypot(bx - ax, by - ay);
    if (length <= diameter * scale) continue;
    const float thread = reach * std::sqrt(diameter * scale / length) * 0.8f;
    const float thread2 = thread * thread;
    const int32_t x0 = std::max(0, int32_t(std::min(ax, bx) - thread)), x1 = std::min(width - 1, int32_t(std::max(ax, bx) + thread));
    const int32_t y0 = std::max(0, int32_t(std::min(ay, by) - thread)), y1 = std::min(height - 1, int32_t(std::max(ay, by) + thread));
    const float ux = (bx - ax) / length, uy = (by - ay) / length;
    for (int32_t y = y0; y <= y1; y++) {
      float *row = &field[size_t(y) * size_t(width)];
      for (int32_t x = x0; x <= x1; x++) {
        const float px = float(x) + 0.5f - ax, py = float(y) + 0.5f - ay;
        const float along = std::max(0.0f, std::min(length, px * ux + py * uy));
        const float dx = px - along * ux, dy = py - along * uy;
        const float d2 = dx * dx + dy * dy;
        if (d2 >= thread2) continue;
        const float t = 1.0f - d2 / thread2;
        // Bonds overlap where the strand is thick; only the thin part needs them.
        row[x] = std::max(row[x], kSurface * 1.15f * t * t);
      }
    }
  }
  auto smooth = [](float edge, float f) {
    const float t = std::min(1.0f, std::max(0.0f, (f - edge + kEdge) / (2 * kEdge)));
    return t * t * (3 - 2 * t);
  };
  const float face = 251.0f, ink = 31.0f;
  for (size_t p = 0; p < field.size(); p++) {
    const float f = field[p];
    const float alpha = smooth(kOutline, f);
    const float grey = ink + (face - ink) * smooth(kSurface, f);
    const uint8_t value = uint8_t(grey * alpha + 0.5f);
    pixels[p * 4 + 0] = value;
    pixels[p * 4 + 1] = value;
    pixels[p * 4 + 2] = value;
    pixels[p * 4 + 3] = uint8_t(255.0f * alpha + 0.5f);
  }
}

}  // extern "C"
