/**
 * Lyklaborð hero: real-time Wave 5 AEK II keycap.
 *
 * Scene units follow the Blender file: 1 unit ≈ 8.887 mm
 * (17.77458 mm AEK II footprint = 2.0 units).
 *
 * Interaction: click/tap/keydown presses the cap ~3.7 mm into a keyboard-plate
 * aperture with a small randomized tilt; release springs back with a damped
 * overshoot. Idle: breathing float + slow yaw drift. Pointer parallax on the
 * camera. Honors prefers-reduced-motion.
 */

import * as THREE from "three";
import { GLTFLoader } from "three/examples/jsm/loaders/GLTFLoader.js";
import { MeshoptDecoder } from "three/examples/jsm/libs/meshopt_decoder.module.js";
import { RoomEnvironment } from "three/examples/jsm/environments/RoomEnvironment.js";

// ---------------------------------------------------------------------------
// Tuning
// ---------------------------------------------------------------------------
const MM = 1 / 8.887; // one millimetre in scene units

const REST_Y = 1.2 * MM; // skirt floats just above the plate
const TRAVEL = 3.7 * MM; // AEK II (Alps SKCM) full travel
const BOTTOM_Y = REST_Y - TRAVEL;

const PRESS_STIFFNESS = 620; // downstroke: fast, firm
const PRESS_DAMPING_RATIO = 1.05; // no bounce on the way down (finger on cap)
const RELEASE_STIFFNESS = 235; // upstroke: mechanical spring
const RELEASE_DAMPING_RATIO = 0.68; // slightly under critical -> damped overshoot

const TILT_MAX_DEG = 1.9; // randomized wobble amplitude at press
const TILT_STIFFNESS = 320;
const TILT_DAMPING_RATIO = 0.6;

const IDLE_BREATHE_MM = 0.35;
const IDLE_BREATHE_HZ = 0.14;
const IDLE_YAW_DEG = 2.4;
const IDLE_YAW_HZ = 0.045;

const PARALLAX_YAW_DEG = 3.2;
const PARALLAX_PITCH_DEG = 1.6;

const APERTURE_W = 2.12; // plate cutout, slightly larger than the 2.0 skirt
const APERTURE_R = 0.16;
const SOCKET_DEPTH = 0.95;

const THEMES = {
  light: {
    table: 0xe7e3da,
    tableRough: 0.92,
    socketTop: 0x99958d,
    socketBottom: 0x2b2926,
    floor: 0x201e1c,
    envIntensity: 0.72,
    keyIntensity: 1.9,
    fillIntensity: 0.5,
  },
  dark: {
    table: 0x262422,
    tableRough: 0.94,
    socketTop: 0x161514,
    socketBottom: 0x0a0a09,
    floor: 0x080807,
    envIntensity: 0.38,
    keyIntensity: 1.9,
    fillIntensity: 0.35,
  },
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
function roundedRectPoints(width, height, radius, cornerSegments = 12) {
  const points = [];
  const corners = [
    [width / 2 - radius, height / 2 - radius, 0],
    [-width / 2 + radius, height / 2 - radius, 90],
    [-width / 2 + radius, -height / 2 + radius, 180],
    [width / 2 - radius, -height / 2 + radius, 270],
  ];
  for (const [cx, cy, start] of corners) {
    for (let i = 0; i <= cornerSegments; i++) {
      const a = THREE.MathUtils.degToRad(start + (90 * i) / cornerSegments);
      points.push(new THREE.Vector2(cx + radius * Math.cos(a), cy + radius * Math.sin(a)));
    }
  }
  return points;
}

/** Critically-tunable spring step (semi-implicit Euler). */
function springStep(pos, vel, target, stiffness, dampingRatio, dt) {
  const damping = 2 * Math.sqrt(stiffness) * dampingRatio;
  const accel = -stiffness * (pos - target) - damping * vel;
  vel += accel * dt;
  pos += vel * dt;
  return [pos, vel];
}

export function initHero(container) {
  const prefersReducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)");

  // WebGL support gate — caller shows the PNG fallback on false.
  try {
    const probe = document.createElement("canvas");
    if (!(probe.getContext("webgl2") || probe.getContext("webgl"))) return false;
  } catch {
    return false;
  }

  const renderer = new THREE.WebGLRenderer({ antialias: true, alpha: true });
  renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
  renderer.outputColorSpace = THREE.SRGBColorSpace;
  renderer.toneMapping = THREE.NeutralToneMapping;
  renderer.toneMappingExposure = 0.94;
  renderer.shadowMap.enabled = true;
  renderer.shadowMap.type = THREE.PCFSoftShadowMap;
  renderer.domElement.className = "hero-canvas";
  container.appendChild(renderer.domElement);

  const scene = new THREE.Scene();
  const pmrem = new THREE.PMREMGenerator(renderer);
  scene.environment = pmrem.fromScene(new RoomEnvironment(), 0.04).texture;

  // Camera: long-ish lens, 3/4 product angle, slightly from the left so the
  // lower-left Ð legend leads.
  const camera = new THREE.PerspectiveCamera(24, 1, 1, 40);
  const camTarget = new THREE.Vector3(0, 0.42, 0);
  const camDistance = 9.0;
  const baseAz = THREE.MathUtils.degToRad(-16);
  const baseEl = THREE.MathUtils.degToRad(34);

  function placeCamera(azOffset = 0, elOffset = 0) {
    const az = baseAz + azOffset;
    const el = baseEl + elOffset;
    camera.position.set(
      camTarget.x + camDistance * Math.cos(el) * Math.sin(az),
      camTarget.y + camDistance * Math.sin(el),
      camTarget.z + camDistance * Math.cos(el) * Math.cos(az)
    );
    camera.lookAt(camTarget);
  }
  placeCamera();

  // -------------------------------------------------------------------------
  // Lights (matching the Wave 5 renders: one big warm softbox + tiny fill)
  // -------------------------------------------------------------------------
  const keyLight = new THREE.DirectionalLight(0xfff9f2, THEMES.light.keyIntensity);
  keyLight.position.set(-2.6, 6.4, -1.6);
  keyLight.castShadow = true;
  keyLight.shadow.mapSize.set(2048, 2048);
  keyLight.shadow.camera.left = -3;
  keyLight.shadow.camera.right = 3;
  keyLight.shadow.camera.top = 3;
  keyLight.shadow.camera.bottom = -3;
  keyLight.shadow.camera.near = 1;
  keyLight.shadow.camera.far = 14;
  keyLight.shadow.bias = -0.0004;
  keyLight.shadow.normalBias = 0.015;
  keyLight.shadow.radius = 6;
  scene.add(keyLight);
  scene.add(keyLight.target);

  const fillLight = new THREE.DirectionalLight(0xffffff, THEMES.light.fillIntensity);
  fillLight.position.set(0.6, 2.4, 5.0);
  scene.add(fillLight);

  // -------------------------------------------------------------------------
  // Table with keyboard-plate aperture + recessed socket
  // -------------------------------------------------------------------------
  const aperturePoints = roundedRectPoints(APERTURE_W, APERTURE_W, APERTURE_R);

  const tableShape = new THREE.Shape();
  tableShape.moveTo(-30, -30);
  tableShape.lineTo(30, -30);
  tableShape.lineTo(30, 30);
  tableShape.lineTo(-30, 30);
  tableShape.closePath();
  const hole = new THREE.Path();
  hole.setFromPoints([...aperturePoints].reverse());
  hole.closePath();
  tableShape.holes.push(hole);

  const tableGeo = new THREE.ShapeGeometry(tableShape, 4);
  tableGeo.rotateX(-Math.PI / 2); // shape (x, y) -> world (x, 0, -y)
  const tableMat = new THREE.MeshStandardMaterial({
    color: THEMES.light.table,
    roughness: THEMES.light.tableRough,
    metalness: 0,
  });
  const table = new THREE.Mesh(tableGeo, tableMat);
  table.receiveShadow = true;
  scene.add(table);

  // Socket walls: vertical ribbon with a baked-in darkness gradient.
  {
    const n = aperturePoints.length;
    const positions = [];
    const colors = [];
    const indices = [];
    const top = new THREE.Color(THEMES.light.socketTop);
    const bottom = new THREE.Color(THEMES.light.socketBottom);
    for (let i = 0; i < n; i++) {
      const p = aperturePoints[i];
      positions.push(p.x, 0, -p.y, p.x, -SOCKET_DEPTH, -p.y);
      colors.push(top.r, top.g, top.b, bottom.r, bottom.g, bottom.b);
    }
    for (let i = 0; i < n; i++) {
      const j = (i + 1) % n;
      const a = i * 2, b = i * 2 + 1, c = j * 2, d = j * 2 + 1;
      indices.push(a, b, c, c, b, d);
    }
    const wallGeo = new THREE.BufferGeometry();
    wallGeo.setAttribute("position", new THREE.Float32BufferAttribute(positions, 3));
    wallGeo.setAttribute("color", new THREE.Float32BufferAttribute(colors, 3));
    wallGeo.setIndex(indices);
    const wallMat = new THREE.MeshBasicMaterial({ vertexColors: true, side: THREE.DoubleSide });
    wallMat.name = "socketWalls";
    scene.add(new THREE.Mesh(wallGeo, wallMat));
  }

  const floorShape = new THREE.Shape();
  floorShape.setFromPoints(aperturePoints);
  floorShape.closePath();
  const floorGeo = new THREE.ShapeGeometry(floorShape, 4);
  floorGeo.rotateX(-Math.PI / 2);
  floorGeo.translate(0, -SOCKET_DEPTH, 0);
  const floorMat = new THREE.MeshBasicMaterial({ color: THEMES.light.floor });
  scene.add(new THREE.Mesh(floorGeo, floorMat));

  // -------------------------------------------------------------------------
  // Keycap
  // -------------------------------------------------------------------------
  const keyGroup = new THREE.Group();
  scene.add(keyGroup);
  let capLoaded = false;

  // Animation-loop state (declared early: applyTheme/requestRender run during init)
  const clock = new THREE.Clock();
  let rafId = 0;
  let running = false;
  let renderQueued = false;

  const loader = new GLTFLoader();
  loader.setMeshoptDecoder(MeshoptDecoder);
  loader.load(
    "/keycap.glb",
    (gltf) => {
      const cap = gltf.scene;
      // Recenter: base of the skirt at y=0, centered on x/z.
      const box = new THREE.Box3().setFromObject(cap);
      const center = box.getCenter(new THREE.Vector3());
      cap.position.x -= center.x;
      cap.position.z -= center.z;
      cap.position.y -= box.min.y;
      cap.traverse((node) => {
        if (!node.isMesh) return;
        node.castShadow = true;
        const material = node.material;
        if (material.normalScale) material.normalScale.set(0.55, 0.55);
        if (node.name.includes("Legend") || node.name.includes("DYE")) {
          // Conformed dye-sub decals: nudge toward the camera in depth.
          material.polygonOffset = true;
          material.polygonOffsetFactor = -2;
          material.polygonOffsetUnits = -2;
          node.castShadow = false;
          node.renderOrder = material.transparent ? 2 : 1;
          if (material.transparent) material.depthWrite = false;
        }
      });
      keyGroup.add(cap);
      capLoaded = true;
      container.dispatchEvent(new CustomEvent("hero:ready"));
      requestRender();
    },
    undefined,
    (error) => {
      console.error("keycap load failed", error);
      container.dispatchEvent(new CustomEvent("hero:failed"));
    }
  );

  // -------------------------------------------------------------------------
  // Theme
  // -------------------------------------------------------------------------
  function applyTheme(dark) {
    const t = dark ? THEMES.dark : THEMES.light;
    tableMat.color.set(t.table);
    tableMat.roughness = t.tableRough;
    floorMat.color.set(t.floor);
    scene.environmentIntensity = t.envIntensity;
    keyLight.intensity = t.keyIntensity;
    fillLight.intensity = t.fillIntensity;
    scene.traverse((node) => {
      if (node.isMesh && node.material.name === "socketWalls") {
        const colorAttr = node.geometry.getAttribute("color");
        const top = new THREE.Color(t.socketTop);
        const bottom = new THREE.Color(t.socketBottom);
        for (let i = 0; i < colorAttr.count; i += 2) {
          colorAttr.setXYZ(i, top.r, top.g, top.b);
          colorAttr.setXYZ(i + 1, bottom.r, bottom.g, bottom.b);
        }
        colorAttr.needsUpdate = true;
      }
    });
    requestRender();
  }

  const darkQuery = window.matchMedia("(prefers-color-scheme: dark)");
  function currentDark() {
    const forced = document.documentElement.dataset.theme;
    if (forced === "dark") return true;
    if (forced === "light") return false;
    return darkQuery.matches;
  }
  darkQuery.addEventListener("change", () => applyTheme(currentDark()));
  new MutationObserver(() => applyTheme(currentDark())).observe(document.documentElement, {
    attributes: true,
    attributeFilter: ["data-theme"],
  });
  applyTheme(currentDark());

  // -------------------------------------------------------------------------
  // Interaction state
  // -------------------------------------------------------------------------
  let pressed = false;
  let y = REST_Y, vy = 0;
  let rx = 0, vrx = 0, rz = 0, vrz = 0;
  let tiltTargetX = 0, tiltTargetZ = 0;
  let idleAmp = 1; // fades to 0 while pressed
  let parallaxX = 0, parallaxY = 0; // smoothed -1..1
  let pointerX = 0, pointerY = 0;

  function press(px = null, pz = null) {
    if (pressed) return;
    pressed = true;
    const angle = Math.random() * Math.PI * 2;
    const mag = THREE.MathUtils.degToRad(TILT_MAX_DEG * (0.55 + Math.random() * 0.45));
    // Bias the tilt toward the pointer if we have one (key tips toward the finger).
    if (px !== null) {
      tiltTargetZ = -px * mag; // press right edge -> tips right (roll about z is negative)
      tiltTargetX = pz * mag;
      // add a little randomness so repeated presses differ
      tiltTargetX += Math.cos(angle) * mag * 0.3;
      tiltTargetZ += Math.sin(angle) * mag * 0.3;
    } else {
      tiltTargetX = Math.cos(angle) * mag;
      tiltTargetZ = Math.sin(angle) * mag;
    }
    container.dispatchEvent(new CustomEvent("hero:press"));
    wake();
  }

  function release() {
    if (!pressed) return;
    pressed = false;
    tiltTargetX = 0;
    tiltTargetZ = 0;
    container.dispatchEvent(new CustomEvent("hero:release"));
    wake();
  }

  const canvas = renderer.domElement;
  canvas.style.touchAction = "manipulation";

  canvas.addEventListener("pointerdown", (event) => {
    event.preventDefault();
    canvas.setPointerCapture(event.pointerId);
    const rect = canvas.getBoundingClientRect();
    const nx = ((event.clientX - rect.left) / rect.width) * 2 - 1;
    const ny = ((event.clientY - rect.top) / rect.height) * 2 - 1;
    press(nx, ny);
  });
  canvas.addEventListener("pointerup", release);
  canvas.addEventListener("pointercancel", release);
  canvas.addEventListener("lostpointercapture", release);

  container.addEventListener("keydown", (event) => {
    if (event.repeat) return;
    if (event.key === "Tab" || event.metaKey || event.ctrlKey || event.altKey) return;
    event.preventDefault();
    press();
  });
  container.addEventListener("keyup", () => release());
  container.addEventListener("blur", () => release());

  window.addEventListener("pointermove", (event) => {
    const rect = container.getBoundingClientRect();
    if (rect.bottom < 0 || rect.top > window.innerHeight) return;
    pointerX = THREE.MathUtils.clamp(
      ((event.clientX - rect.left) / rect.width) * 2 - 1, -1.4, 1.4);
    pointerY = THREE.MathUtils.clamp(
      ((event.clientY - rect.top) / rect.height) * 2 - 1, -1.4, 1.4);
    wake();
  });

  // -------------------------------------------------------------------------
  // Sizing / visibility
  // -------------------------------------------------------------------------
  function resize() {
    const w = container.clientWidth;
    const h = container.clientHeight;
    if (!w || !h) return;
    renderer.setSize(w, h);
    camera.aspect = w / h;
    camera.updateProjectionMatrix();
    requestRender();
  }
  new ResizeObserver(resize).observe(container);
  resize();

  let visible = true;
  new IntersectionObserver((entries) => {
    visible = entries[0].isIntersecting;
    if (visible) wake();
  }).observe(container);

  // -------------------------------------------------------------------------
  // Animation loop
  // -------------------------------------------------------------------------
  function requestRender() {
    renderQueued = true;
    if (!running) wake();
  }

  function wake() {
    if (running) return;
    running = true;
    clock.getDelta(); // reset delta
    rafId = requestAnimationFrame(tick);
  }

  function sleep() {
    running = false;
    cancelAnimationFrame(rafId);
  }

  function tick() {
    const dt = Math.min(clock.getDelta(), 1 / 30);
    const t = clock.elapsedTime;
    const reduced = prefersReducedMotion.matches;

    if (reduced) {
      // Static render; press is an instant down/up.
      y = pressed ? BOTTOM_Y : REST_Y;
      keyGroup.position.set(0, y, 0);
      keyGroup.rotation.set(0, 0, 0);
      placeCamera();
      renderer.render(scene, camera);
      renderQueued = false;
      running = false;
      return; // render-on-demand only
    }

    // Vertical spring
    const targetY = pressed ? BOTTOM_Y : REST_Y;
    const stiffness = pressed ? PRESS_STIFFNESS : RELEASE_STIFFNESS;
    const ratio = pressed ? PRESS_DAMPING_RATIO : RELEASE_DAMPING_RATIO;
    [y, vy] = springStep(y, vy, targetY, stiffness, ratio, dt);
    if (y < BOTTOM_Y) { y = BOTTOM_Y; vy = 0; } // bottoming out is a hard stop

    // Tilt springs
    [rx, vrx] = springStep(rx, vrx, tiltTargetX, TILT_STIFFNESS, TILT_DAMPING_RATIO, dt);
    [rz, vrz] = springStep(rz, vrz, tiltTargetZ, TILT_STIFFNESS, TILT_DAMPING_RATIO, dt);

    // Idle breathing fades out while pressed
    idleAmp += ((pressed ? 0 : 1) - idleAmp) * (1 - Math.exp(-dt * (pressed ? 14 : 1.4)));
    const breathe = IDLE_BREATHE_MM * MM * Math.sin(2 * Math.PI * IDLE_BREATHE_HZ * t) * idleAmp;
    const yaw = THREE.MathUtils.degToRad(IDLE_YAW_DEG) *
      Math.sin(2 * Math.PI * IDLE_YAW_HZ * t) * idleAmp;

    keyGroup.position.set(0, y + breathe, 0);
    keyGroup.rotation.set(rx, yaw, rz);

    // Camera parallax
    parallaxX += (pointerX - parallaxX) * (1 - Math.exp(-dt * 4));
    parallaxY += (pointerY - parallaxY) * (1 - Math.exp(-dt * 4));
    placeCamera(
      THREE.MathUtils.degToRad(-PARALLAX_YAW_DEG) * parallaxX,
      THREE.MathUtils.degToRad(PARALLAX_PITCH_DEG) * parallaxY
    );

    renderer.render(scene, camera);
    renderQueued = false;

    if (visible && !document.hidden) {
      rafId = requestAnimationFrame(tick);
    } else {
      running = false;
    }
  }

  document.addEventListener("visibilitychange", () => {
    if (!document.hidden) wake();
  });
  prefersReducedMotion.addEventListener("change", () => {
    sleep();
    wake();
  });

  wake();

  return {
    press,
    release,
    get loaded() { return capLoaded; },
  };
}
