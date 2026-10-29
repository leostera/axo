#include "axo_squishy.h"

#include <BulletSoftBody/btSoftBody.h>
#include <BulletSoftBody/btSoftBodyHelpers.h>
#include <BulletSoftBody/btSoftBodyRigidBodyCollisionConfiguration.h>
#include <BulletSoftBody/btSoftRigidDynamicsWorld.h>
#include <btBulletDynamicsCommon.h>

#include <algorithm>
#include <cmath>
#include <memory>
#include <vector>

namespace {

/// Points to Bullet's unit: it is tuned for things about a metre across, and Axo is about 90
/// points.
constexpr btScalar kPointsPerUnit = 60;
constexpr btScalar kStep = 1.0 / 120.0;
/// Air pushed in as it is blown up, per unit of `inflation` over 1: it rounds out as it grows.
constexpr btScalar kPressure = 5;
/// The part of it a grab holds, and a poke pushes, in points.
constexpr btScalar kHandRadius = 14;
/// How hard a grab pulls its patch to the pointer, and how hard a poke pushes, in points a second.
constexpr btScalar kPull = 120;
constexpr btScalar kPoke = 300;
/// How firmly it is pulled back to its shape, upright, per second squared: it comes back after a
/// dent, wobbling, and does not stay turned (its window turns it). Bullet's own shape matching
/// lets it turn.
constexpr btScalar kShape = 300;
/// How firmly it is kept in the middle of its window, per second squared.
constexpr btScalar kTether = 10;
/// The part of its bottom that stops when it lands, in points.
constexpr btScalar kFoot = 8;

btVector3 units(float x, float y, float z) { return btVector3(x, y, z) / kPointsPerUnit; }

}  // namespace

struct AxoSquishy {
  std::unique_ptr<btSoftBodyRigidBodyCollisionConfiguration> configuration;
  std::unique_ptr<btCollisionDispatcher> dispatcher;
  std::unique_ptr<btBroadphaseInterface> broadphase;
  std::unique_ptr<btSequentialImpulseConstraintSolver> solver;
  std::unique_ptr<btSoftRigidDynamicsWorld> world;
  btSoftBody *body = nullptr;
  int32_t count = 0;
  std::vector<int> held;
  std::vector<btVector3> heldOffsets;
  btVector3 hold;
  float pending = 0;
  /// Its shape and volume as made, which blowing it up scales (with its springs).
  std::vector<btVector3> pose;
  btScalar volume = 0;
  /// Where its centre is kept: where it was made.
  btVector3 home;

  ~AxoSquishy() {
    if (body) {
      world->removeSoftBody(body);
      delete body;
    }
  }
};

namespace {

/// The vertices facing the viewer within `kHandRadius` of (x, y) on the screen, nearest first;
/// at least the nearest.
/// Its centre of mass, which its shape (`m_pose.m_pos`) is about.
btVector3 centre(const btSoftBody *body) {
  btVector3 sum(0, 0, 0);
  btScalar mass = 0;
  for (int i = 0; i < body->m_nodes.size(); i++) {
    const btScalar m = body->m_nodes[i].m_im > 0 ? 1 / body->m_nodes[i].m_im : 0;
    sum += body->m_nodes[i].m_x * m;
    mass += m;
  }
  return sum / mass;
}

std::vector<int> under(const AxoSquishy *squishy, float x, float y) {
  const btVector3 at = units(x, y, 0);
  const btScalar radius = kHandRadius / kPointsPerUnit;
  std::vector<std::pair<btScalar, int>> found;
  int nearest = -1;
  btScalar nearestDistance = BT_LARGE_FLOAT;
  const btSoftBody::tNodeArray &nodes = squishy->body->m_nodes;
  for (int i = 0; i < nodes.size(); i++) {
    if (nodes[i].m_n.z() <= 0) continue;
    const btScalar distance = btVector3(nodes[i].m_x.x() - at.x(), nodes[i].m_x.y() - at.y(), 0).length();
    if (distance < nearestDistance) {
      nearestDistance = distance;
      nearest = i;
    }
    if (distance <= radius) found.push_back({distance, i});
  }
  std::sort(found.begin(), found.end());
  std::vector<int> indices;
  for (const auto &entry : found) indices.push_back(entry.second);
  if (indices.empty() && nearest >= 0) indices.push_back(nearest);
  return indices;
}

}  // namespace

extern "C" {

AxoSquishy *axo_squishy_create(const float *vertices, int32_t vertex_count, const int32_t *triangles,
                               int32_t triangle_count) {
  AxoSquishy *squishy = new AxoSquishy();
  squishy->configuration = std::make_unique<btSoftBodyRigidBodyCollisionConfiguration>();
  squishy->dispatcher = std::make_unique<btCollisionDispatcher>(squishy->configuration.get());
  squishy->broadphase = std::make_unique<btDbvtBroadphase>();
  squishy->solver = std::make_unique<btSequentialImpulseConstraintSolver>();
  squishy->world = std::make_unique<btSoftRigidDynamicsWorld>(
      squishy->dispatcher.get(), squishy->broadphase.get(), squishy->solver.get(), squishy->configuration.get());
  // No gravity: its window falls, not it. It only feels its window's jolts.
  squishy->world->setGravity(btVector3(0, 0, 0));
  btSoftBodyWorldInfo &info = squishy->world->getWorldInfo();
  info.m_gravity.setZero();
  info.air_density = 0;
  info.m_broadphase = squishy->broadphase.get();
  info.m_dispatcher = squishy->dispatcher.get();
  info.m_sparsesdf.Initialize();

  std::vector<btScalar> points(size_t(vertex_count) * 3);
  for (int32_t i = 0; i < vertex_count * 3; i++) points[size_t(i)] = vertices[i] / kPointsPerUnit;
  std::vector<int> faces(triangles, triangles + triangle_count * 3);
  btSoftBody *body = btSoftBodyHelpers::CreateFromTriMesh(info, points.data(), faces.data(), triangle_count, false);
  body->m_materials[0]->m_kLST = 0.2;
  body->m_materials[0]->m_kAST = 0.2;
  body->generateBendingConstraints(2, body->m_materials[0]);
  body->m_cfg.piterations = 4;
  body->m_cfg.kDP = 0.01;
  body->m_cfg.kPR = 0;
  // Like a water balloon: it keeps its volume, so pushed in somewhere it bulges somewhere else.
  body->m_cfg.kVC = 20;
  body->setTotalMass(1, true);
  // Its shape as made, about its centre, which `step` pulls it back to.
  body->setPose(true, false);
  body->m_cfg.collisions = 0;
  body->updateNormals();
  // Bullet keeps the shape about the origin unless it also lets it turn: about its centre, here.
  squishy->home = centre(body);
  for (int i = 0; i < body->m_pose.m_pos.size(); i++) body->m_pose.m_pos[i] -= squishy->home;
  for (int i = 0; i < body->m_pose.m_pos.size(); i++) squishy->pose.push_back(body->m_pose.m_pos[i]);
  // Bullet would work out its constants (its springs' lengths among them) from where it is at its
  // first step, by when it may be blown up: now, as made.
  body->updateConstants();
  body->m_bUpdateRtCst = false;
  squishy->volume = body->m_pose.m_volume;
  squishy->world->addSoftBody(body, 0, 0);
  squishy->body = body;
  squishy->count = vertex_count;
  return squishy;
}

void axo_squishy_destroy(AxoSquishy *squishy) { delete squishy; }

void axo_squishy_positions(const AxoSquishy *squishy, float *xyz) {
  const btSoftBody::tNodeArray &nodes = squishy->body->m_nodes;
  for (int i = 0; i < nodes.size(); i++) {
    xyz[3 * i] = float(nodes[i].m_x.x() * kPointsPerUnit);
    xyz[3 * i + 1] = float(nodes[i].m_x.y() * kPointsPerUnit);
    xyz[3 * i + 2] = float(nodes[i].m_x.z() * kPointsPerUnit);
  }
}

void axo_squishy_step(AxoSquishy *squishy, float seconds) {
  squishy->pending = std::min(squishy->pending + seconds, 0.1f);
  while (squishy->pending >= kStep) {
    squishy->pending -= float(kStep);
    if (!squishy->held.empty()) {
      btSoftBody::tNodeArray &nodes = squishy->body->m_nodes;
      for (size_t k = 0; k < squishy->held.size(); k++) {
        btSoftBody::Node &node = nodes[squishy->held[k]];
        const btVector3 target = squishy->hold + squishy->heldOffsets[k];
        // Pulled there through its velocity, which the rest of it feels through its springs.
        node.m_v = (target - node.m_x) * kPull;
      }
    }
    squishy->world->stepSimulation(kStep, 0);
    // Kept in the middle of its window (a spring on its centre, pulling all of it alike), and
    // pulled back to its shape about that centre.
    btSoftBody::tNodeArray &nodes = squishy->body->m_nodes;
    const btSoftBody::Pose &pose = squishy->body->m_pose;
    const btVector3 middle = centre(squishy->body);
    const btVector3 back = (squishy->home - middle) * (kTether * kStep);
    for (int i = 0; i < nodes.size(); i++) {
      const btVector3 goal = middle + pose.m_pos[i];
      nodes[i].m_v += back + (goal - nodes[i].m_x) * (kShape * kStep);
    }
  }
}

void axo_squishy_set_inflation(AxoSquishy *squishy, float inflation) {
  // Blown up: everything it remembers about its shape grows, and the air in it rounds it out.
  btSoftBody *body = squishy->body;
  const btScalar scale = std::max<btScalar>(0.5, inflation);
  for (int i = 0; i < body->m_pose.m_pos.size(); i++) body->m_pose.m_pos[i] = squishy->pose[size_t(i)] * scale;
  body->setRestLengthScale(scale);
  body->m_pose.m_volume = squishy->volume * scale * scale * scale;
  body->m_cfg.kPR = kPressure * std::max<btScalar>(0, scale - 1);
}

void axo_squishy_poke(AxoSquishy *squishy, float x, float y) {
  const std::vector<int> nodes = under(squishy, x, y);
  for (size_t k = 0; k < nodes.size(); k++) {
    btSoftBody::Node &node = squishy->body->m_nodes[nodes[k]];
    // Hardest in the middle of the jab, pushed in along the surface's inward normal.
    const btScalar falloff = 1 - btScalar(k) / btScalar(nodes.size() + 1);
    node.m_v -= node.m_n * (kPoke / kPointsPerUnit * falloff);
  }
}

void axo_squishy_grab(AxoSquishy *squishy, float x, float y) {
  squishy->held = under(squishy, x, y);
  squishy->hold = units(x, y, 0);
  squishy->heldOffsets.clear();
  for (int i : squishy->held) {
    const btVector3 &at = squishy->body->m_nodes[i].m_x;
    squishy->heldOffsets.push_back(btVector3(at.x() - squishy->hold.x(), at.y() - squishy->hold.y(), at.z()));
  }
  squishy->hold.setZ(0);
}

void axo_squishy_pull_to(AxoSquishy *squishy, float x, float y) { squishy->hold = units(x, y, 0); }

void axo_squishy_let_go(AxoSquishy *squishy) {
  squishy->held.clear();
  squishy->heldOffsets.clear();
}

void axo_squishy_jolt(AxoSquishy *squishy, float dx, float dy) {
  // Carried along, it is left behind by however much its carrier sped up; the held part keeps up
  // (it is pulled back to the pointer each step).
  squishy->body->addVelocity(-units(dx, dy, 0));
}

void axo_squishy_land(AxoSquishy *squishy, float speed) {
  btSoftBody::tNodeArray &nodes = squishy->body->m_nodes;
  btScalar bottom = BT_LARGE_FLOAT;
  for (int i = 0; i < nodes.size(); i++) bottom = std::min(bottom, nodes[i].m_x.y());
  const btScalar foot = bottom + kFoot / kPointsPerUnit;
  // Its window has stopped; in it, everything but its foot carries on down.
  const btVector3 down = units(0, -speed, 0);
  for (int i = 0; i < nodes.size(); i++) {
    if (nodes[i].m_x.y() > foot) nodes[i].m_v += down;
  }
}

float axo_squishy_wobble(const AxoSquishy *squishy) {
  const btSoftBody::Pose &pose = squishy->body->m_pose;
  const btSoftBody::tNodeArray &nodes = squishy->body->m_nodes;
  const btVector3 middle = centre(squishy->body);
  btScalar total = 0;
  for (int i = 0; i < nodes.size(); i++) {
    const btVector3 goal = middle + pose.m_pos[i];
    total += (nodes[i].m_x - goal).length();
  }
  return float(total / nodes.size() * kPointsPerUnit);
}

}  // extern "C"
