import {
  ACESFilmicToneMapping, Color, DirectionalLight, HemisphereLight,
  OrthographicCamera, PCFShadowMap, Scene, WebGLRenderer,
} from 'three';
import { GLTFLoader } from 'three/addons/loaders/GLTFLoader.js';
import { DRACOLoader } from 'three/addons/loaders/DRACOLoader.js';
import { houseStoryProgress } from './house.js';

const clamp = (n, min, max) => Math.max(min, Math.min(max, n));
const stages = [0, 4, 8, 14, 18, 24];

export async function createHouseScene(host, settings) {
  const renderer = new WebGLRenderer({ alpha: true, antialias: true, powerPreference: 'low-power' });
  renderer.setPixelRatio(Math.min(devicePixelRatio, 1.5));
  renderer.setClearColor(0, 0);
  renderer.toneMapping = ACESFilmicToneMapping;
  renderer.toneMappingExposure = 1.12;
  renderer.shadowMap.enabled = true;
  renderer.shadowMap.type = PCFShadowMap;
  renderer.shadowMap.autoUpdate = false;
  renderer.shadowMap.needsUpdate = true;
  const scene = new Scene();
  const camera = new OrthographicCamera(-4, 4, 4, -4, .1, 60);
  const sky = new HemisphereLight(0xfff4d8, 0x536a52, 3);
  const sun = new DirectionalLight(0xffedd0, 4);
  sun.position.set(-3, 7, 5);
  sun.castShadow = true;
  sun.shadow.mapSize.set(1024, 1024);
  Object.assign(sun.shadow.camera, { left: -4, right: 4, top: 4, bottom: -4, near: .1, far: 20 });
  sun.shadow.normalBias = .045;
  sun.shadow.bias = -.0002;
  const rim = new DirectionalLight(0xc4d6e4, 1.8);
  rim.position.set(4, 3, -3);
  scene.add(sky, sun, rim);

  const draco = new DRACOLoader().setDecoderPath('/vendor/draco/').setWorkerLimit(1);
  let model, metadata, companion;
  try {
    [model, metadata, companion] = await Promise.all([
      new GLTFLoader().setDRACOLoader(draco).loadAsync('/models/daily-house.glb'),
      fetch('/models/daily-house.json').then((response) => {
        if (!response.ok) throw new Error('House metadata unavailable');
        return response.json();
      }),
      new GLTFLoader().setDRACOLoader(draco).loadAsync('/models/companion.glb').catch(() => null),
    ]);
  } catch (error) {
    renderer.dispose();
    draco.dispose();
    throw error;
  }
  scene.add(model.scene);
  if (companion) {
    companion.scene.scale.setScalar(.6);
    companion.scene.position.set(-.85, .06, 1.05);
    companion.scene.rotation.y = .35;
    model.scene.add(companion.scene);
  }
  const glowMaterials = new Set();
  model.scene.traverse((node) => {
    if (!node.isMesh) return;
    node.castShadow = true;
    node.receiveShadow = true;
    node.material.roughness = Math.max(.7, node.material.roughness);
    if (/_glow$/.test(node.material.name)) glowMaterials.add(node.material);
  });
  const pieces = metadata.pieces.map((name) => model.scene.getObjectByName(name));
  const sites = metadata.sites.map((name) => model.scene.getObjectByName(name));
  let built = 24;
  let constructionAmount = 24;
  const amounts = pieces.map(() => 1);
  const homeAngle = -.46;
  let angle = homeAngle, desiredAngle = homeAngle;
  let elevation = 5.5, desiredElevation = 5.5;
  let zoom = 1, desiredZoom = 1;
  let lookHeight = .65, desiredLookHeight = .65;
  let evening = 0, desiredEvening = 0;
  let story;
  let visible = false, frame = 0, previous = 0, disposed = false;
  let renderedFrames = 0;
  const frameGaps = [];
  const moving = () => !settings.paused && !settings.reduced.matches;
  let previousMotionMode = `${settings.paused}:${settings.reduced.matches}`;
  let publishedEvening;
  const dayColor = new Color(0xffedd0), nightColor = new Color(0xb7c9ed);
  const lightButton = document.querySelector('.house-light-toggle');
  const resetButton = document.querySelector('.house-view-reset');

  function updateSite() {
    const stage = stages.filter((first) => built >= first).length - 1;  // stages ascend
    sites.forEach((site, index) => { site.visible = index === stage; });
    host.parentElement.style.setProperty('--house-complete', built === pieces.length ? '1' : '0');
    renderer.shadowMap.needsUpdate = true;
  }
  updateSite();

  function draw(time) {
    frame = 0;
    if (disposed || !visible || document.hidden) return;
    if (import.meta.env.DEV && previous) {
      frameGaps.push(time - previous);
      if (frameGaps.length > 120) frameGaps.shift();
    }
    const dt = previous ? Math.min((time - previous) / 1000, .04) : 1 / 60;
    previous = time;
    const blend = moving() ? 1 - Math.exp(-12 * dt) : 1;
    let unsettled = false;
    pieces.forEach((piece, index) => {
      const target = clamp(constructionAmount - index, 0, 1);
      if (Math.abs(target - amounts[index]) > .0001) renderer.shadowMap.needsUpdate = true;
      amounts[index] += (target - amounts[index]) * blend;
      if (Math.abs(target - amounts[index]) < .001) amounts[index] = target;
      else unsettled = true;
      const amount = amounts[index];
      piece.visible = amount > .025;
      piece.position.y = (1 - amount) * 1.1;
      piece.scale.setScalar(.94 + .06 * amount);
    });
    angle += (desiredAngle - angle) * blend;
    elevation += (desiredElevation - elevation) * blend;
    zoom += (desiredZoom - zoom) * blend;
    lookHeight += (desiredLookHeight - lookHeight) * blend;
    evening += (desiredEvening - evening) * blend;
    if (Math.abs(desiredAngle - angle) > .0001 || Math.abs(desiredEvening - evening) > .001
      || Math.abs(desiredElevation - elevation) > .001 || Math.abs(desiredZoom - zoom) > .0001
      || Math.abs(desiredLookHeight - lookHeight) > .001) unsettled = true;
    else {
      angle = desiredAngle; evening = desiredEvening;
      elevation = desiredElevation; zoom = desiredZoom; lookHeight = desiredLookHeight;
    }
    camera.position.set(Math.sin(angle) * 9, elevation, Math.cos(angle) * 9);
    camera.lookAt(0, lookHeight, 0);
    if (camera.zoom !== zoom) { camera.zoom = zoom; camera.updateProjectionMatrix(); }
    sun.color.copy(dayColor).lerp(nightColor, evening);
    sun.intensity = 4 - evening * 2.7;
    sky.intensity = 3 - evening * 1.5;
    rim.intensity = 1.8 + evening * .7;
    renderer.toneMappingExposure = 1.12 - evening * .2;
    glowMaterials.forEach((material) => { material.emissiveIntensity = .35 + evening * 1.8; });
    const eveningValue = evening.toFixed(3);
    if (eveningValue !== publishedEvening) {
      host.parentElement.style.setProperty('--house-evening', eveningValue);
      publishedEvening = eveningValue;
    }
    renderer.render(scene, camera);
    renderedFrames++;
    if (unsettled) frame = requestAnimationFrame(draw);
    else {
      previous = 0;
      if (import.meta.env.DEV) {
        host.dataset.renderState = 'idle';
        host.dataset.renderCount = String(renderedFrames);
        const sorted = [...frameGaps].sort((a, b) => a - b);
        host.dataset.frameP95 = String(Math.round(sorted[Math.floor(sorted.length * .95)] || 0));
        host.dataset.drawCalls = String(renderer.info.render.calls);
      }
    }
  }
  function requestRender() {
    if (!frame && visible && !document.hidden && !disposed) {
      if (import.meta.env.DEV) host.dataset.renderState = 'active';
      frame = requestAnimationFrame(draw);
    }
  }
  function resize() {
    const { width, height } = host.getBoundingClientRect();
    if (!width || !height) return;
    const aspect = width / height;
    const vertical = Math.max(6.4, 8.2 / aspect);
    camera.left = -vertical * aspect / 2;
    camera.right = vertical * aspect / 2;
    camera.top = vertical / 2;
    camera.bottom = -vertical / 2;
    camera.updateProjectionMatrix();
    renderer.setSize(width, height, false);
    requestRender();
  }
  const resizeObserver = new ResizeObserver(resize);
  resizeObserver.observe(host);
  const observer = new IntersectionObserver(([entry]) => {
    visible = entry.isIntersecting;
    if (visible) requestRender();
    else {
      cancelAnimationFrame(frame); frame = 0; previous = 0;
      if (import.meta.env.DEV) host.dataset.renderState = 'offscreen';
    }
  });
  observer.observe(host);
  const controller = new AbortController();
  const on = (element, event, handler) => element.addEventListener(event, handler, { signal: controller.signal });
  const world = host.closest('.world-section');
  function takeControl(kind, input) {
    host.dispatchEvent(new CustomEvent('moku:house-interaction', { bubbles: true, detail: { kind, input } }));
  }
  function updateLightControl() {
    const isEvening = desiredEvening >= .5;
    // Update accessible controls at the threshold, not on every scroll frame.
    if (lightButton.getAttribute('aria-pressed') === String(isEvening)) return;
    lightButton.setAttribute('aria-pressed', String(isEvening));
    lightButton.setAttribute('aria-label', 'Evening lighting');
    lightButton.innerHTML = isEvening ? '<span aria-hidden="true">☾</span> Evening' : '<span aria-hidden="true">☀</span> Daylight';
    world.classList.toggle('is-evening', isEvening);
  }
  function setStoryProgress(value, immediate = false) {
    story = houseStoryProgress(value);
    host.dataset.storyProgress = story.progress.toFixed(4);
    constructionAmount = story.buildProgress * pieces.length;
    const nextBuilt = Math.floor(constructionAmount + 1e-8);
    if (nextBuilt !== built) { built = nextBuilt; updateSite(); }
    const cameraProgress = moving() ? story.cameraProgress : 1;
    desiredAngle = -1.22 + (homeAngle + 1.22) * cameraProgress;
    desiredElevation = 6.8 - 1.3 * cameraProgress;
    desiredZoom = .9 + .1 * cameraProgress;
    desiredLookHeight = .25 + .4 * cameraProgress;
    desiredEvening = story.evening;
    if (immediate || !moving()) {
      angle = desiredAngle; elevation = desiredElevation;
      zoom = desiredZoom; lookHeight = desiredLookHeight; evening = desiredEvening;
      pieces.forEach((_, index) => { amounts[index] = clamp(constructionAmount - index, 0, 1); });
      renderer.shadowMap.needsUpdate = true;
    }
    updateLightControl();
    requestRender();
  }
  let pointer;
  on(host, 'pointerdown', (event) => {
    if (!event.isPrimary || event.button !== 0) return;
    takeControl('rotate', 'pointer');
    pointer = { id: event.pointerId, x: event.clientX, y: event.clientY, angle: desiredAngle, dragging: false };
  });
  on(host, 'pointermove', (event) => {
    if (pointer?.id !== event.pointerId) return;
    const dx = event.clientX - pointer.x;
    const dy = event.clientY - pointer.y;
    if (!pointer.dragging) {
      if (Math.abs(dy) > Math.abs(dx) && Math.abs(dy) > 8) { pointer = null; return; }
      if (Math.abs(dx) < 5) return;
      pointer.dragging = true;
      host.setPointerCapture(event.pointerId);
      host.classList.add('is-dragging');
    }
    desiredAngle = pointer.angle + dx * .008;
    requestRender();
  });
  function release() { pointer = null; host.classList.remove('is-dragging'); }
  on(host, 'pointerup', release);
  on(host, 'pointercancel', release);
  on(host, 'lostpointercapture', release);
  on(host, 'keydown', (event) => {
    if (!['ArrowLeft', 'ArrowRight', 'Home'].includes(event.key)) return;
    event.preventDefault();
    takeControl(event.key === 'Home' ? 'reset' : 'rotate', 'keyboard');
    desiredAngle = event.key === 'Home' ? homeAngle : desiredAngle + (event.key === 'ArrowLeft' ? -.25 : .25);
    requestRender();
  });
  on(resetButton, 'click', (event) => {
    takeControl('reset', event.detail === 0 ? 'keyboard' : 'pointer');
    desiredAngle = homeAngle; desiredElevation = 5.5; desiredZoom = 1; desiredLookHeight = .65;
    requestRender();
  });
  on(lightButton, 'click', (event) => {
    takeControl('lighting', event.detail === 0 ? 'keyboard' : 'pointer');
    desiredEvening = desiredEvening >= .5 ? 0 : 1;
    updateLightControl();
    requestRender();
  });
  on(document, 'moku:motion-change', () => {
    const nextMode = `${settings.paused}:${settings.reduced.matches}`;
    // Companion visibility refreshes share this event. A tab switch must not
    // replace a visitor's chosen camera or lighting with the scroll targets.
    if (nextMode === previousMotionMode) return;
    previousMotionMode = nextMode;
    if (story) setStoryProgress(story.progress, !moving());
    else requestRender();
  });
  on(document, 'visibilitychange', () => {
    cancelAnimationFrame(frame); frame = 0; previous = 0;
    requestRender();
  });
  on(renderer.domElement, 'webglcontextlost', (event) => {
    event.preventDefault();
    host.closest('.house-scene').classList.remove('has-model');
    dispose();
  });
  function dispose() {
    if (disposed) return;
    disposed = true;
    cancelAnimationFrame(frame);
    observer.disconnect(); resizeObserver.disconnect(); controller.abort();
    const geometries = new Set(), materials = new Set();
    model.scene.traverse((node) => { if (node.isMesh) { geometries.add(node.geometry); materials.add(node.material); } });
    geometries.forEach((geometry) => geometry.dispose());
    materials.forEach((material) => material.dispose());
    const textures = new Set();
    materials.forEach((material) => Object.values(material).forEach((value) => { if (value?.isTexture) textures.add(value); }));
    textures.forEach((texture) => texture.dispose());
    renderer.dispose(); draco.dispose();
  }
  on(window, 'pagehide', (event) => { if (!event.persisted) dispose(); });
  host.append(renderer.domElement);
  host.closest('.house-scene').classList.add('has-model');
  resize();
  return {
    setMinutes(minutes, immediate = false) {
      built = clamp(Math.floor(minutes / 10), 0, 24);
      constructionAmount = built;
      story = undefined;
      if (immediate || !moving()) pieces.forEach((_, index) => { amounts[index] = index < built ? 1 : 0; });
      updateSite();
      requestRender();
    },
    setStoryProgress,
    dispose,
  };
}
