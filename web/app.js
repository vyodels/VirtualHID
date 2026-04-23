const stage = document.getElementById('stage');
const traceCanvas = document.getElementById('trace');
const effectsLayer = document.getElementById('effects');
const cursorGhost = document.getElementById('cursor-ghost');
const traceHud = document.getElementById('trace-hud');
const keyboardTarget = document.getElementById('keyboard-target');
const scrollZone = document.getElementById('scroll-zone');
const logNode = document.getElementById('log');
const summaryNode = document.getElementById('summary');
const statusNode = document.getElementById('status');
const comparisonNode = document.getElementById('comparison');
const learningNode = document.getElementById('learning');
const clearLogButton = document.getElementById('clear-log');
const exportLogButton = document.getElementById('export-log');
const startUserButton = document.getElementById('start-user');
const runVhidButton = document.getElementById('run-vhid');
const compareRunsButton = document.getElementById('compare-runs');
const persistentToggle = document.getElementById('toggle-persistent');
const tailToggle = document.getElementById('toggle-tail');
const effectsToggle = document.getElementById('toggle-effects');
const dryRunToggle = document.getElementById('toggle-dry-run');
const draggable = document.getElementById('draggable');
const dropZone = document.getElementById('drop-zone');
const shadowHost = document.getElementById('shadow-host');
const rangeTarget = document.getElementById('range-target');
const checkTarget = document.getElementById('check-target');

const runId = `${Date.now()}-${Math.random().toString(16).slice(2)}`;
const reportEndpoint = `${location.origin}/report`;
const hidActionEndpoint = `${location.origin}/hid/action`;
const hidStateEndpoint = `${location.origin}/hid/state`;
const mouseEvents = ['mousemove', 'mousedown', 'mouseup', 'click', 'dblclick', 'contextmenu', 'mouseover', 'mouseenter', 'mouseleave', 'mouseout'];
const pointerEvents = ['pointermove', 'pointerdown', 'pointerup'];
const wheelEvents = ['wheel', 'scroll'];
const dragEvents = ['dragstart', 'drag', 'dragend', 'dragenter', 'dragover', 'drop'];
const keyEvents = ['keydown', 'keyup', 'beforeinput', 'input', 'change'];

let captureMode = 'user';
let virtualCaptureUntil = 0;
let calibrationOffset = null;
let lastCursorCommandVersion = -1;
let hudMessage = null;

const eventLog = [];
const traceSamples = [];
const eventCounters = new Map();
const channelCounters = { user: 0, virtual: 0 };

window.__virtualHIDLab = {
  runId,
  getLog: () => structuredClone(eventLog),
  getSummary: () => buildSummary(),
  compare: () => compareRuns(),
  clear: () => resetState(),
  runVirtualHID: () => runVirtualHIDDemo(),
};

function resetState() {
  eventLog.length = 0;
  traceSamples.length = 0;
  eventCounters.clear();
  channelCounters.user = 0;
  channelCounters.virtual = 0;
  keyboardTarget.value = '';
  scrollZone.scrollTop = 0;
  captureMode = 'user';
  virtualCaptureUntil = 0;
  comparisonNode.textContent = '尚未生成对比。';
  learningNode.textContent = '先完成用户采集和 VirtualHID 采集。';
  effectsLayer.innerHTML = '';
  reportState('reset');
  render();
}

function currentChannel(event) {
  if (captureMode === 'virtual' && performance.now() < virtualCaptureUntil) {
    return 'virtual';
  }
  if (event?.syntheticChannel) {
    return event.syntheticChannel;
  }
  return 'user';
}

function effectiveCaptureMode() {
  if (captureMode === 'virtual' && performance.now() >= virtualCaptureUntil) {
    return 'user';
  }
  return captureMode;
}

function pushEvent(source, event, offset = { x: 0, y: 0 }) {
  const channel = currentChannel(event);
  const hasClientPoint = 'clientX' in event && Number.isFinite(event.clientX);
  const clientX = hasClientPoint ? event.clientX + offset.x : null;
  const clientY = hasClientPoint ? event.clientY + offset.y : null;
  const stagePoint = clientX === null ? null : toStagePoint(clientX, clientY);

  if (clientX !== null && 'screenX' in event) {
    calibrationOffset = {
      x: event.screenX - clientX,
      y: event.screenY - clientY,
    };
  }

  const entry = {
    runId,
    channel,
    source,
    type: event.type,
    timestamp: Date.now(),
    perfNow: Number(performance.now().toFixed(3)),
    isTrusted: event.isTrusted ?? false,
    target: targetLabel(event.target),
    activeElement: targetLabel(document.activeElement),
    clientX: clientX === null ? null : round(clientX),
    clientY: clientY === null ? null : round(clientY),
    stageX: stagePoint ? round(stagePoint.x) : null,
    stageY: stagePoint ? round(stagePoint.y) : null,
    screenX: 'screenX' in event ? round(event.screenX) : null,
    screenY: 'screenY' in event ? round(event.screenY) : null,
    button: 'button' in event ? event.button : null,
    buttons: 'buttons' in event ? event.buttons : null,
    deltaX: 'deltaX' in event ? round(event.deltaX) : null,
    deltaY: 'deltaY' in event ? round(event.deltaY) : null,
    key: 'key' in event ? event.key : null,
    code: 'code' in event ? event.code : null,
    repeat: 'repeat' in event ? event.repeat : null,
    modifiers: {
      alt: Boolean(event.altKey),
      ctrl: Boolean(event.ctrlKey),
      meta: Boolean(event.metaKey),
      shift: Boolean(event.shiftKey),
    },
    valueTail: event.target === keyboardTarget ? keyboardTarget.value.slice(-32) : null,
    scrollTop: scrollZone.scrollTop,
    windowScreenX: round(window.screenX),
    windowScreenY: round(window.screenY),
    innerWidth: window.innerWidth,
    innerHeight: window.innerHeight,
  };

  eventLog.push(entry);
  eventCounters.set(entry.type, (eventCounters.get(entry.type) || 0) + 1);
  channelCounters[channel] += 1;

  if (stagePoint && isMoveEvent(entry.type)) {
    traceSamples.push({
      channel,
      x: stagePoint.x,
      y: stagePoint.y,
      ts: performance.now(),
      type: entry.type,
    });
    trimTraceSamples();
  }

  const effectPoint = stagePoint || (entry.type.startsWith('key') ? elementCenterInStage(event.target || keyboardTarget) : null);
  if (effectPoint && effectsToggle.checked && ['click', 'dblclick', 'wheel', 'keydown', 'keyup'].includes(entry.type)) {
    spawnEffect(entry.type, effectPoint.x, effectPoint.y, entry.key);
  }

  if (eventLog.length <= 20 || eventLog.length % 12 === 0 || ['click', 'dblclick', 'wheel', 'drop', 'input'].includes(entry.type)) {
    reportState(`event:${entry.type}`);
  }
  render();
}

function trimTraceSamples() {
  const max = 6000;
  if (traceSamples.length > max) {
    traceSamples.splice(0, traceSamples.length - max);
  }
}

function buildSummary() {
  const metrics = {
    user: computeMetrics('user'),
    virtual: computeMetrics('virtual'),
  };
  return {
    runId,
    mode: effectiveCaptureMode(),
    total: eventLog.length,
    channelCounters,
    counters: Object.fromEntries(eventCounters.entries()),
    focus: {
      hasFocus: document.hasFocus(),
      visibilityState: document.visibilityState,
      activeElement: targetLabel(document.activeElement),
    },
    calibrationOffset,
    metrics,
  };
}

function computeMetrics(channel) {
  const entries = eventLog.filter((entry) => entry.channel === channel);
  const points = traceSamples.filter((point) => point.channel === channel);
  const clicks = entries.filter((entry) => entry.type === 'click');
  const dblClicks = entries.filter((entry) => entry.type === 'dblclick');
  const wheels = entries.filter((entry) => entry.type === 'wheel');
  const keys = entries.filter((entry) => entry.type === 'keydown' || entry.type === 'keyup');
  const durationMs = points.length > 1 ? points[points.length - 1].ts - points[0].ts : 0;
  let pathLength = 0;
  let pauses = 0;
  const steps = [];
  const angles = [];

  for (let index = 1; index < points.length; index += 1) {
    const previous = points[index - 1];
    const current = points[index];
    const distance = Math.hypot(current.x - previous.x, current.y - previous.y);
    const dt = current.ts - previous.ts;
    pathLength += distance;
    steps.push(distance);
    if (dt > 120) {
      pauses += 1;
    }
    if (index >= 2) {
      const before = points[index - 2];
      const a1 = Math.atan2(previous.y - before.y, previous.x - before.x);
      const a2 = Math.atan2(current.y - previous.y, current.x - previous.x);
      angles.push(Math.abs(normalizeAngle(a2 - a1)));
    }
  }

  const direct = points.length > 1 ? Math.hypot(points.at(-1).x - points[0].x, points.at(-1).y - points[0].y) : 0;
  return {
    events: entries.length,
    pointCount: points.length,
    durationMs: round(durationMs),
    pathLength: round(pathLength),
    directDistance: round(direct),
    straightness: pathLength > 0 ? round(direct / pathLength) : 0,
    avgSpeedPxS: durationMs > 0 ? round(pathLength / (durationMs / 1000)) : 0,
    stepMean: round(mean(steps)),
    turnJitter: round(stddev(angles)),
    pauses,
    clicks: clicks.length,
    dblClicks: dblClicks.length,
    wheels: wheels.length,
    keyEvents: keys.length,
    targetHits: targetHits(entries),
  };
}

function compareRuns() {
  const user = computeMetrics('user');
  const virtual = computeMetrics('virtual');
  const comparison = {
    user,
    virtual,
    delta: {
      durationMs: round(virtual.durationMs - user.durationMs),
      straightness: round(virtual.straightness - user.straightness),
      avgSpeedPxS: round(virtual.avgSpeedPxS - user.avgSpeedPxS),
      turnJitter: round(virtual.turnJitter - user.turnJitter),
      pauses: virtual.pauses - user.pauses,
      pointCount: virtual.pointCount - user.pointCount,
    },
  };
  const suggestions = buildLearningSuggestions(user, virtual);
  const learned = {
    generatedAt: new Date().toISOString(),
    basis: 'client-side heuristic comparison',
    suggestions,
  };
  localStorage.setItem('virtualhid.demo.learningProfile', JSON.stringify(learned));
  comparisonNode.textContent = JSON.stringify(comparison, null, 2);
  learningNode.textContent = JSON.stringify(learned, null, 2);
  reportState('compare');
  return comparison;
}

function buildLearningSuggestions(user, virtual) {
  const suggestions = [];
  if (user.pointCount === 0 || virtual.pointCount === 0) {
    return ['需要先采集用户轨迹和 VirtualHID 轨迹。'];
  }
  if (virtual.straightness > user.straightness + 0.08) {
    suggestions.push('VirtualHID 轨迹更直：提高 wind/jitter 或 overshoot，保留轻微回摆。');
  }
  if (virtual.avgSpeedPxS > user.avgSpeedPxS * 1.2) {
    suggestions.push('VirtualHID 偏快：增加 durationMs 或提高每段停顿。');
  }
  if (virtual.avgSpeedPxS < user.avgSpeedPxS * 0.75) {
    suggestions.push('VirtualHID 偏慢：降低 durationMs 或减少点数。');
  }
  if (virtual.pauses < user.pauses) {
    suggestions.push('用户有更多停顿：在目标前 60-160ms 区间加入 hesitation。');
  }
  if (virtual.targetHits.length < user.targetHits.length) {
    suggestions.push('VirtualHID 覆盖的目标少：补齐 checkbox/range/drag/iframe/shadow 等复杂 DOM 目标。');
  }
  if (virtual.turnJitter < user.turnJitter * 0.75) {
    suggestions.push('VirtualHID 转向变化少：增加控制点扰动或 WindMouse wind 参数。');
  }
  if (suggestions.length === 0) {
    suggestions.push('当前基础指标接近，可继续采集更多样本后写入 ProfileStore 聚合。');
  }
  return suggestions;
}

async function runVirtualHIDDemo() {
  captureMode = 'virtual';
  virtualCaptureUntil = performance.now() + 16000;
  const shadowButton = shadowHost.shadowRoot?.getElementById('shadow-button');
  const frameAButton = document.getElementById('frame-a').contentDocument?.getElementById('frame-a-button');
  const targets = [
    document.getElementById('morph-button'),
    document.getElementById('split-right'),
    checkTarget,
    rangeTarget,
    shadowButton,
    frameAButton,
    keyboardTarget,
  ].filter(Boolean);
  const primitives = [];

  for (const target of targets) {
    const point = getElementScreenPoint(target);
    primitives.push({ type: 'move', to: point, via: 'wind', durationMs: 520 });
    primitives.push({ type: 'click', at: point, button: 'left', holdMs: 45, count: 1 });
  }
  primitives.push({ type: 'type', text: 'abc123', layout: 'us' });
  primitives.push({
    type: 'drag',
    from: getElementScreenPoint(draggable),
    to: getElementScreenPoint(dropZone),
    button: 'left',
    via: 'wind',
  });
  const scrollPoint = getElementScreenPoint(scrollZone);
  primitives.push({ type: 'scroll', at: scrollPoint, dx: 0, dy: -360, style: 'wheel' });

  const request = {
    id: `web-demo-${Date.now()}`,
    primitives,
    context: {
      host: location.host || 'virtualhid.local',
      element: { sig: 'web-demo-complex-stage', role: 'demo' },
      taskId: 'compare-capture',
      stage: 'web-lab',
      hints: { urgency: 'normal' },
    },
    options: {
      postMode: 'global',
      dryRun: dryRunToggle.checked,
    },
  };

  try {
    const response = await fetch(hidActionEndpoint, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(request),
    });
    const payload = await response.json();
    if (!payload.ok) {
      setHudMessage(`VirtualHID 调用失败：${payload.error?.code || 'E_UNKNOWN'} ${payload.error?.message || ''}`, 6000);
      playVirtualCursorPreview(targets);
      return;
    }
    setHudMessage(`VirtualHID 已调用：post=${payload.result?.post?.used || 'unknown'} dryRun=${dryRunToggle.checked}`, 6000);
    if (dryRunToggle.checked) {
      playVirtualCursorPreview(targets);
    }
  } catch (error) {
    setHudMessage(`无法连接本地 HID 桥：${error.message}`, 6000);
    playVirtualCursorPreview(targets);
  }
}

async function refreshHidState() {
  try {
    const response = await fetch(hidStateEndpoint, { cache: 'no-store' });
    const payload = await response.json();
    if (payload.ok) {
      return payload.result;
    }
  } catch (_) {
  }
  return null;
}

function playVirtualCursorPreview(targets) {
  const points = targets.map((target) => {
    const center = elementCenterInTopWindow(target);
    const stageRect = stage.getBoundingClientRect();
    return {
      x: center.x - stageRect.left,
      y: center.y - stageRect.top,
    };
  });
  let index = 0;
  const timer = setInterval(() => {
    const point = points[index % points.length];
    const event = { type: 'virtual-preview', syntheticChannel: 'virtual', isTrusted: false };
    traceSamples.push({ channel: 'virtual', x: point.x, y: point.y, ts: performance.now(), type: event.type });
    eventLog.push({
      runId,
      channel: 'virtual',
      source: 'preview',
      type: 'mousemove',
      timestamp: Date.now(),
      perfNow: round(performance.now()),
      isTrusted: false,
      target: 'preview',
      activeElement: targetLabel(document.activeElement),
      clientX: null,
      clientY: null,
      stageX: round(point.x),
      stageY: round(point.y),
    });
    channelCounters.virtual += 1;
    eventCounters.set('mousemove', (eventCounters.get('mousemove') || 0) + 1);
    spawnEffect('click', point.x, point.y);
    render();
    index += 1;
    if (index >= points.length * 2) {
      clearInterval(timer);
    }
  }, 260);
}

function getElementScreenPoint(element) {
  const point = elementCenterInTopWindow(element);
  const fallbackOffset = {
    x: window.screenX,
    y: window.screenY + Math.max(0, window.outerHeight - window.innerHeight),
  };
  const offset = calibrationOffset || fallbackOffset;
  return {
    x: Math.round(point.x + offset.x),
    y: Math.round(point.y + offset.y),
  };
}

function elementCenterInTopWindow(element) {
  const rect = element.getBoundingClientRect();
  let x = rect.left + rect.width / 2;
  let y = rect.top + rect.height / 2;
  const ownerWindow = element.ownerDocument?.defaultView;
  if (ownerWindow && ownerWindow !== window) {
    const frame = [...document.querySelectorAll('iframe')].find((candidate) => candidate.contentWindow === ownerWindow);
    if (frame) {
      const frameRect = frame.getBoundingClientRect();
      x += frameRect.left;
      y += frameRect.top;
    }
  }
  return { x, y };
}

function render() {
  renderStatus();
  renderSummary();
  renderLog();
}

function renderStatus() {
  const summary = buildSummary();
  const items = [
    ['Run ID', runId.slice(-10)],
    ['模式', effectiveCaptureMode()],
    ['用户事件', String(summary.channelCounters.user)],
    ['虚拟事件', String(summary.channelCounters.virtual)],
    ['前台焦点', String(summary.focus.hasFocus)],
    ['校准', calibrationOffset ? `${round(calibrationOffset.x)}, ${round(calibrationOffset.y)}` : '未校准'],
  ];
  statusNode.innerHTML = items
    .map(([label, value]) => `<div class="status-chip"><span class="label">${escapeHtml(label)}</span><span class="value">${escapeHtml(value)}</span></div>`)
    .join('');
}

function renderSummary() {
  const summary = buildSummary();
  summaryNode.innerHTML = [
    `总事件：${summary.total}`,
    `当前 activeElement：${summary.focus.activeElement}`,
    `用户轨迹点：${summary.metrics.user.pointCount}，虚拟轨迹点：${summary.metrics.virtual.pointCount}`,
    `用户平均速度：${summary.metrics.user.avgSpeedPxS}px/s`,
    `虚拟平均速度：${summary.metrics.virtual.avgSpeedPxS}px/s`,
    `事件计数：${JSON.stringify(summary.counters)}`,
  ].map((line) => `<div>${escapeHtml(line)}</div>`).join('');
}

function renderLog() {
  logNode.textContent = eventLog.slice(-90).map((entry) => JSON.stringify(entry)).join('\n');
}

function renderTrace() {
  const rect = stage.getBoundingClientRect();
  const ratio = window.devicePixelRatio || 1;
  traceCanvas.width = Math.max(1, Math.floor(rect.width * ratio));
  traceCanvas.height = Math.max(1, Math.floor(rect.height * ratio));
  const ctx = traceCanvas.getContext('2d');
  ctx.setTransform(ratio, 0, 0, ratio, 0, 0);
  ctx.clearRect(0, 0, rect.width, rect.height);

  const now = performance.now();
  const persistent = persistentToggle.checked ? traceSamples : [];
  const tail = tailToggle.checked ? traceSamples.filter((point) => now - point.ts <= 4200) : [];
  drawPath(ctx, persistent.filter((point) => point.channel === 'user'), 'rgba(85, 215, 255, 0.70)', 3, 0.30);
  drawPath(ctx, persistent.filter((point) => point.channel === 'virtual'), 'rgba(255, 180, 84, 0.82)', 3, 0.28);
  drawTail(ctx, tail.filter((point) => point.channel === 'user'), now, '85, 215, 255');
  drawTail(ctx, tail.filter((point) => point.channel === 'virtual'), now, '255, 180, 84');

  const last = traceSamples.at(-1);
  if (!last) {
    cursorGhost.style.opacity = '0';
    traceHud.textContent = activeHudMessage() || '等待采集...';
    return;
  }
  cursorGhost.style.opacity = '1';
  cursorGhost.style.transform = `translate(${last.x}px, ${last.y}px)`;
  traceHud.textContent = activeHudMessage() || `最近轨迹：${last.channel} (${Math.round(last.x)}, ${Math.round(last.y)}) | 点数=${traceSamples.length} | scrollTop=${scrollZone.scrollTop}`;
}

function drawPath(ctx, points, color, width, alpha) {
  if (points.length < 2) {
    return;
  }
  ctx.save();
  ctx.globalAlpha = alpha;
  ctx.strokeStyle = color;
  ctx.lineWidth = width;
  ctx.lineCap = 'round';
  ctx.lineJoin = 'round';
  ctx.beginPath();
  ctx.moveTo(points[0].x, points[0].y);
  for (const point of points.slice(1)) {
    ctx.lineTo(point.x, point.y);
  }
  ctx.stroke();
  ctx.restore();
}

function drawTail(ctx, points, now, rgb) {
  if (points.length < 2) {
    return;
  }
  for (let index = 1; index < points.length; index += 1) {
    const point = points[index];
    const previous = points[index - 1];
    const age = Math.min(1, (now - point.ts) / 4200);
    ctx.strokeStyle = `rgba(${rgb}, ${1 - age})`;
    ctx.lineWidth = 10 * (1 - age) + 2;
    ctx.lineCap = 'round';
    ctx.beginPath();
    ctx.moveTo(previous.x, previous.y);
    ctx.lineTo(point.x, point.y);
    ctx.stroke();
  }
}

function spawnEffect(type, x, y, key = '') {
  const effect = document.createElement('div');
  effect.className = `fx ${type === 'dblclick' ? 'dblclick' : type === 'wheel' ? 'wheel' : type.startsWith('key') ? 'key' : 'click'}`;
  effect.style.left = `${x}px`;
  effect.style.top = `${y}px`;
  if (type.startsWith('key')) {
    effect.textContent = key || 'key';
  }
  effectsLayer.append(effect);
  setTimeout(() => effect.remove(), 850);
}

function setHudMessage(text, ttlMs = 4000) {
  hudMessage = {
    text,
    until: performance.now() + ttlMs,
  };
  traceHud.textContent = text;
}

function activeHudMessage() {
  if (hudMessage && performance.now() < hudMessage.until) {
    return hudMessage.text;
  }
  return null;
}

function reportState(reason) {
  const payload = {
    reason,
    runId,
    summary: buildSummary(),
    events: eventLog.slice(-700),
    pageUrl: location.href,
  };
  const body = JSON.stringify(payload);
  if (navigator.sendBeacon) {
    navigator.sendBeacon(reportEndpoint, body);
    return;
  }
  fetch(reportEndpoint, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body,
    keepalive: true,
  }).catch(() => {});
}

async function pollCursorCommand() {
  try {
    const response = await fetch(`${location.origin}/cursor-command`, { cache: 'no-store' });
    if (!response.ok) {
      return;
    }
    const command = await response.json();
    if (!command || typeof command.version !== 'number' || command.version === lastCursorCommandVersion) {
      return;
    }
    lastCursorCommandVersion = command.version;
    if (command.type === 'virtual-cursor-demo' && Array.isArray(command.points)) {
      captureMode = 'virtual';
      virtualCaptureUntil = performance.now() + 8000;
      for (const point of command.points) {
        traceSamples.push({ channel: 'virtual', x: point.x, y: point.y, ts: performance.now(), type: 'cursor-command' });
        eventLog.push({
          runId,
          channel: 'virtual',
          source: 'cursor-command',
          type: 'mousemove',
          timestamp: Date.now(),
          perfNow: round(performance.now()),
          isTrusted: false,
          target: 'cursor-command',
          activeElement: targetLabel(document.activeElement),
          clientX: null,
          clientY: null,
          stageX: round(point.x),
          stageY: round(point.y),
        });
        channelCounters.virtual += 1;
        eventCounters.set('mousemove', (eventCounters.get('mousemove') || 0) + 1);
        await sleep(point.delayMs || 120);
      }
    }
  } catch (_) {
  }
}

function wireComplexDom() {
  document.querySelector('.scroll-list').innerHTML = Array.from({ length: 28 }, (_, index) => `<div>Nested scroll item ${String(index + 1).padStart(2, '0')}</div>`).join('');

  const shadow = shadowHost.attachShadow({ mode: 'open' });
  shadow.innerHTML = `
    <style>
      button,input { font: inherit; }
      .box { display:grid; gap:10px; padding:12px; border-radius:16px; background:rgba(255,255,255,.06); }
      button { border:0; border-radius:999px; padding:9px 12px; background:#ffb454; color:#07111f; font-weight:800; }
      input { min-width:0; border-radius:10px; border:1px solid rgba(255,255,255,.18); padding:8px; background:#080b12; color:white; }
    </style>
    <div class="box">
      <button id="shadow-button">Shadow Button</button>
      <input id="shadow-input" placeholder="shadow input" />
    </div>
  `;
  attachCapture(shadow, 'shadow-dom');

  setupFrame(document.getElementById('frame-a'), 'frame-a');
  setupFrame(document.getElementById('frame-b'), 'frame-b');
}

function setupFrame(frame, label) {
  frame.addEventListener('load', () => {
    attachFrameCapture(frame, label);
  });
  frame.srcdoc = `
    <!doctype html><html><head><style>
      body { margin:0; font:14px Avenir Next, sans-serif; color:#edf4ff; background:#101827; }
      main { display:grid; gap:10px; padding:14px; }
      button,input,[contenteditable] { font:inherit; border-radius:12px; padding:10px; border:1px solid rgba(255,255,255,.18); }
      button { background:#55d7ff; color:#06111f; font-weight:800; }
      [contenteditable] { min-height:48px; background:rgba(255,255,255,.07); }
    </style></head><body>
      <main>
        <strong>${label} nested document</strong>
        <button id="${label}-button">iframe button</button>
        <input id="${label}-input" placeholder="iframe input" />
        <div id="${label}-editable" contenteditable="true">contenteditable DOM island</div>
      </main>
    </body></html>`;
}

function attachFrameCapture(frame, label) {
  for (const type of [...mouseEvents, ...pointerEvents, ...wheelEvents, ...keyEvents]) {
    frame.contentDocument.addEventListener(type, (event) => {
      const rect = frame.getBoundingClientRect();
      pushEvent(label, event, { x: rect.left, y: rect.top });
    }, true);
  }
}

function attachCapture(root, source, offset = { x: 0, y: 0 }, types = [...mouseEvents, ...pointerEvents, ...wheelEvents, ...keyEvents]) {
  for (const type of types) {
    root.addEventListener(type, (event) => pushEvent(source, event, offset), true);
  }
}

function toStagePoint(clientX, clientY) {
  const rect = stage.getBoundingClientRect();
  return { x: clientX - rect.left, y: clientY - rect.top };
}

function elementCenterInStage(element) {
  if (!element || !element.getBoundingClientRect) {
    return null;
  }
  const rect = element.getBoundingClientRect();
  const stageRect = stage.getBoundingClientRect();
  return {
    x: rect.left + rect.width / 2 - stageRect.left,
    y: rect.top + Math.min(rect.height / 2, 48) - stageRect.top,
  };
}

function targetLabel(target) {
  if (!target) {
    return null;
  }
  if (target.id) {
    return `#${target.id}`;
  }
  if (target.className && typeof target.className === 'string') {
    return `.${target.className.split(/\s+/).filter(Boolean).join('.')}`;
  }
  return target.tagName || String(target);
}

function isMoveEvent(type) {
  return type === 'mousemove' || type === 'pointermove' || type === 'drag' || type === 'dragover' || type === 'virtual-preview';
}

function targetHits(entries) {
  return [...new Set(entries.map((entry) => entry.target).filter(Boolean))];
}

function normalizeAngle(value) {
  let result = value;
  while (result > Math.PI) result -= Math.PI * 2;
  while (result < -Math.PI) result += Math.PI * 2;
  return result;
}

function mean(values) {
  return values.length ? values.reduce((sum, value) => sum + value, 0) / values.length : 0;
}

function stddev(values) {
  if (values.length < 2) {
    return 0;
  }
  const average = mean(values);
  return Math.sqrt(mean(values.map((value) => (value - average) ** 2)));
}

function round(value) {
  return Number(Number(value || 0).toFixed(2));
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function escapeHtml(value) {
  return String(value)
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');
}

attachCapture(stage, 'stage', { x: 0, y: 0 }, [...mouseEvents, ...pointerEvents, ...wheelEvents]);
attachCapture(keyboardTarget, 'keyboard', { x: 0, y: 0 }, keyEvents);
attachCapture(rangeTarget, 'range', { x: 0, y: 0 }, ['input', 'change', 'mousedown', 'mouseup', 'click']);
attachCapture(checkTarget, 'checkbox', { x: 0, y: 0 }, ['input', 'change', 'mousedown', 'mouseup', 'click']);
for (const type of dragEvents) {
  draggable.addEventListener(type, (event) => pushEvent('draggable', event), true);
  dropZone.addEventListener(type, (event) => {
    event.preventDefault();
    pushEvent('drop-zone', event);
  }, true);
}

startUserButton.addEventListener('click', () => {
  captureMode = 'user';
  setHudMessage('用户采集已开始：请操作复杂按钮、滚动、拖拽、iframe 和输入框。', 6000);
  keyboardTarget.focus();
});
runVhidButton.addEventListener('click', runVirtualHIDDemo);
compareRunsButton.addEventListener('click', compareRuns);
clearLogButton.addEventListener('click', resetState);
exportLogButton.addEventListener('click', () => {
  const blob = new Blob([JSON.stringify({ runId, summary: buildSummary(), events: eventLog }, null, 2)], {
    type: 'application/json',
  });
  const url = URL.createObjectURL(blob);
  const link = document.createElement('a');
  link.href = url;
  link.download = `virtualhid-lab-${runId}.json`;
  link.click();
  URL.revokeObjectURL(url);
});

window.addEventListener('focus', (event) => pushEvent('window', event), true);
window.addEventListener('blur', (event) => pushEvent('window', event), true);
document.addEventListener('visibilitychange', (event) => pushEvent('document', event), true);
window.addEventListener('pagehide', () => reportState('pagehide'));

new ResizeObserver(() => renderTrace()).observe(stage);
wireComplexDom();
resetState();
refreshHidState().then((state) => {
  if (state) {
    setHudMessage(`Daemon 已连接：post.default=${state.post?.default || 'unknown'}，frontmost=${state.targetApp?.frontmost}`, 6000);
  }
});
setInterval(pollCursorCommand, 500);
function animationLoop() {
  renderTrace();
  requestAnimationFrame(animationLoop);
}
animationLoop();
