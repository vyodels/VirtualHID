const stage = document.getElementById('stage');
const traceCanvas = document.getElementById('trace');
const cursorGhost = document.getElementById('cursor-ghost');
const traceHud = document.getElementById('trace-hud');
const keyboardTarget = document.getElementById('keyboard-target');
const scrollZone = document.getElementById('scroll-zone');
const logNode = document.getElementById('log');
const summaryNode = document.getElementById('summary');
const statusNode = document.getElementById('status');
const clearLogButton = document.getElementById('clear-log');
const exportLogButton = document.getElementById('export-log');
const focusInputButton = document.getElementById('focus-input');
const draggable = document.getElementById('draggable');

const runId = `${Date.now()}-${Math.random().toString(16).slice(2)}`;
const eventLog = [];
const tracePoints = [];
const eventCounters = new Map();
const reportEndpoint = `${location.origin}/report`;
const cursorCommandEndpoint = `${location.origin}/cursor-command`;
const searchParams = new URLSearchParams(location.search);
let lastCursorCommandVersion = -1;

const mouseEvents = ['mousemove', 'mousedown', 'mouseup', 'click'];
const pointerEvents = ['pointermove', 'pointerdown', 'pointerup'];
const dragEvents = ['dragstart', 'drag', 'dragend'];
const wheelEvents = ['wheel'];
const keyEvents = ['keydown', 'keyup', 'beforeinput', 'input', 'change'];

window.__cgEventPostToPidHarness = {
  runId,
  getLog: () => structuredClone(eventLog),
  getSummary: () => buildSummary(),
  getLogJSON: () => JSON.stringify(structuredClone(eventLog)),
  getSummaryJSON: () => JSON.stringify(buildSummary()),
  clear: () => resetState(),
  focusInput: () => {
    keyboardTarget.focus();
    keyboardTarget.select();
    render();
    return buildSummary();
  },
  focusStage: () => {
    stage.focus();
    render();
    return buildSummary();
  },
  focusScrollZone: () => {
    scrollZone.focus();
    render();
    return buildSummary();
  },
  playCursorDemo: (points, holdMs = 1200) => playVirtualCursor(points, holdMs),
};

function resetState() {
  eventLog.length = 0;
  tracePoints.length = 0;
  eventCounters.clear();
  keyboardTarget.value = '';
  scrollZone.scrollTop = 0;
  reportState('reset');
  render();
}

function buildSummary() {
  return {
    runId,
    total: eventLog.length,
    allTrusted: eventLog.every((entry) => entry.isTrusted === true),
    lastEvent: eventLog[eventLog.length - 1] ?? null,
    counters: Object.fromEntries(eventCounters.entries()),
    focus: {
      hasFocus: document.hasFocus(),
      visibilityState: document.visibilityState,
      activeElement: document.activeElement?.id || document.activeElement?.tagName || null,
    },
    scroll: {
      scrollTop: scrollZone.scrollTop,
      scrollLeft: scrollZone.scrollLeft,
    },
  };
}

function pushEvent(source, event) {
  const entry = {
    runId,
    source,
    type: event.type,
    timestamp: Date.now(),
    perfNow: Number(performance.now().toFixed(3)),
    isTrusted: event.isTrusted,
    hasFocus: document.hasFocus(),
    visibilityState: document.visibilityState,
    target: event.target?.id || event.target?.className || event.target?.tagName || null,
    activeElement: document.activeElement?.id || document.activeElement?.tagName || null,
    button: 'button' in event ? event.button : null,
    buttons: 'buttons' in event ? event.buttons : null,
    clientX: 'clientX' in event ? round(event.clientX) : null,
    clientY: 'clientY' in event ? round(event.clientY) : null,
    screenX: 'screenX' in event ? round(event.screenX) : null,
    screenY: 'screenY' in event ? round(event.screenY) : null,
    movementX: 'movementX' in event ? round(event.movementX) : null,
    movementY: 'movementY' in event ? round(event.movementY) : null,
    deltaX: 'deltaX' in event ? round(event.deltaX) : null,
    deltaY: 'deltaY' in event ? round(event.deltaY) : null,
    deltaMode: 'deltaMode' in event ? event.deltaMode : null,
    detail: 'detail' in event ? event.detail : null,
    pointerType: 'pointerType' in event ? event.pointerType : null,
    key: 'key' in event ? event.key : null,
    code: 'code' in event ? event.code : null,
    repeat: 'repeat' in event ? event.repeat : null,
    altKey: 'altKey' in event ? event.altKey : null,
    ctrlKey: 'ctrlKey' in event ? event.ctrlKey : null,
    metaKey: 'metaKey' in event ? event.metaKey : null,
    shiftKey: 'shiftKey' in event ? event.shiftKey : null,
    value: event.target === keyboardTarget ? keyboardTarget.value : null,
    scrollTop: scrollZone.scrollTop,
    scrollLeft: scrollZone.scrollLeft,
    userAgent: navigator.userAgent,
    devicePixelRatio: window.devicePixelRatio,
    windowScreenX: round(window.screenX),
    windowScreenY: round(window.screenY),
    innerWidth: window.innerWidth,
    innerHeight: window.innerHeight,
  };

  eventLog.push(entry);
  eventCounters.set(entry.type, (eventCounters.get(entry.type) || 0) + 1);

  if ((entry.type === 'mousemove' || entry.type === 'pointermove') && entry.clientX !== null && entry.clientY !== null) {
    const rect = stage.getBoundingClientRect();
    tracePoints.push({ x: entry.clientX - rect.left, y: entry.clientY - rect.top, trusted: entry.isTrusted, type: entry.type });
    if (tracePoints.length > 3000) {
      tracePoints.shift();
    }
  }

  render();
  if (eventLog.length <= 24 || eventLog.length % 8 === 0 || ['click', 'blur', 'focus', 'wheel', 'scroll'].includes(event.type)) {
    reportState(`event:${event.type}`);
  }
}

function render() {
  renderTrace();
  renderStatus();
  renderSummary();
  renderLog();
}

async function pollCursorCommand() {
  try {
    const response = await fetch(cursorCommandEndpoint, { cache: 'no-store' });
    if (!response.ok) {
      return;
    }
    const command = await response.json();
    if (!command || typeof command.version !== 'number' || command.version === lastCursorCommandVersion) {
      return;
    }
    lastCursorCommandVersion = command.version;
    if (command.type === 'virtual-cursor-demo' && Array.isArray(command.points)) {
      await playVirtualCursor(command.points, command.holdMs || 1200);
    }
  } catch (_) {
  }
}

function playVirtualCursor(points, holdMs) {
  return new Promise((resolve) => {
    tracePoints.length = 0;
    render();
    let index = 0;

    function step() {
      if (index >= points.length) {
        reportState('virtual-cursor-demo-complete');
        setTimeout(resolve, holdMs);
        return;
      }
      const point = points[index];
      tracePoints.push({ x: point.x, y: point.y, trusted: false, type: 'virtual-demo' });
      render();
      index += 1;
      setTimeout(step, point.delayMs || 180);
    }

    step();
  });
}

function buildDefaultDemoPoints() {
  const points = [];

  function addLine(start, end, steps, delayMs) {
    for (let index = 0; index < steps; index += 1) {
      const progress = index / Math.max(steps - 1, 1);
      points.push({
        x: Math.round(start.x + (end.x - start.x) * progress),
        y: Math.round(start.y + (end.y - start.y) * progress),
        delayMs,
      });
    }
  }

  addLine({ x: 180, y: 170 }, { x: 720, y: 240 }, 18, 220);
  points.push({ x: 720, y: 240, delayMs: 1800 });
  addLine({ x: 720, y: 240 }, { x: 980, y: 430 }, 12, 180);
  points.push({ x: 980, y: 430, delayMs: 1600 });
  addLine({ x: 980, y: 430 }, { x: 330, y: 470 }, 16, 170);
  points.push({ x: 330, y: 470, delayMs: 2200 });
  return points;
}

function reportState(reason) {
  const payload = {
    reason,
    runId,
    summary: buildSummary(),
    events: eventLog.slice(-500),
    textValue: keyboardTarget.value,
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

function renderStatus() {
  const statusItems = [
    ['Run ID', runId],
    ['document.hasFocus()', String(document.hasFocus())],
    ['visibilityState', document.visibilityState],
    ['activeElement', document.activeElement?.id || document.activeElement?.tagName || 'none'],
    ['scrollTop', String(scrollZone.scrollTop)],
    ['events', String(eventLog.length)],
  ];

  statusNode.innerHTML = statusItems
    .map(([label, value]) => `<div class="status-chip"><span class="label">${escapeHtml(label)}</span><span class="value">${escapeHtml(value)}</span></div>`)
    .join('');
}

function renderSummary() {
  const summary = buildSummary();
  summaryNode.innerHTML = [
    `总事件数：${summary.total}`,
    `全部 isTrusted=true：${summary.allTrusted}`,
    `当前焦点：${summary.focus.hasFocus}`,
    `当前 visibilityState：${summary.focus.visibilityState}`,
    `当前 activeElement：${summary.focus.activeElement}`,
    `Scroll Top：${summary.scroll.scrollTop}`,
    `事件计数：${JSON.stringify(summary.counters)}`,
  ]
    .map((line) => `<div>${escapeHtml(line)}</div>`)
    .join('');
}

function renderLog() {
  const recent = eventLog.slice(-80).map((entry) => JSON.stringify(entry));
  logNode.textContent = recent.join('\n');
}

function renderTrace() {
  const rect = stage.getBoundingClientRect();
  const ratio = window.devicePixelRatio || 1;
  traceCanvas.width = Math.max(1, Math.floor(rect.width * ratio));
  traceCanvas.height = Math.max(1, Math.floor(rect.height * ratio));
  const ctx = traceCanvas.getContext('2d');
  ctx.setTransform(ratio, 0, 0, ratio, 0, 0);
  ctx.clearRect(0, 0, rect.width, rect.height);

  if (tracePoints.length < 1) {
    cursorGhost.style.opacity = '0';
    traceHud.textContent = `等待虚拟鼠标轨迹… | scrollTop=${scrollZone.scrollTop}`;
    return;
  }

  if (tracePoints.length >= 2) {
    ctx.lineCap = 'round';
    ctx.lineJoin = 'round';
    ctx.strokeStyle = 'rgba(14, 165, 233, 0.18)';
    ctx.lineWidth = 14;
    ctx.beginPath();
    ctx.moveTo(tracePoints[0].x, tracePoints[0].y);
    for (let index = 1; index < tracePoints.length; index += 1) {
      ctx.lineTo(tracePoints[index].x, tracePoints[index].y);
    }
    ctx.stroke();

    ctx.strokeStyle = '#38bdf8';
    ctx.lineWidth = 4;
    ctx.beginPath();
    ctx.moveTo(tracePoints[0].x, tracePoints[0].y);
    for (let index = 1; index < tracePoints.length; index += 1) {
      ctx.lineTo(tracePoints[index].x, tracePoints[index].y);
    }
    ctx.stroke();
  }

  const last = tracePoints[tracePoints.length - 1];
  ctx.fillStyle = '#fb923c';
  ctx.beginPath();
  ctx.arc(last.x, last.y, 8, 0, Math.PI * 2);
  ctx.fill();
  ctx.strokeStyle = 'rgba(255,255,255,0.95)';
  ctx.lineWidth = 2;
  ctx.beginPath();
  ctx.arc(last.x, last.y, 15, 0, Math.PI * 2);
  ctx.stroke();

  cursorGhost.style.opacity = '1';
  cursorGhost.style.transform = `translate(${last.x}px, ${last.y}px)`;
  traceHud.textContent = `最近轨迹点：(${Math.round(last.x)}, ${Math.round(last.y)}) | 点数=${tracePoints.length} | scrollTop=${scrollZone.scrollTop}`;
}

function round(value) {
  return Number(Number(value).toFixed(2));
}

function escapeHtml(value) {
  return String(value)
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');
}

function handleFocusEvent(event) {
  pushEvent('document', event);
}

[...mouseEvents, ...pointerEvents, ...wheelEvents].forEach((type) => {
  stage.addEventListener(type, (event) => pushEvent('stage', event), true);
});

dragEvents.forEach((type) => {
  draggable.addEventListener(type, (event) => pushEvent('draggable', event), true);
});

scrollZone.addEventListener('wheel', (event) => pushEvent('scroll-zone', event), true);
scrollZone.addEventListener('scroll', (event) => pushEvent('scroll-zone', event), true);

keyEvents.forEach((type) => {
  keyboardTarget.addEventListener(type, (event) => pushEvent('keyboard', event), true);
});

window.addEventListener('focus', handleFocusEvent, true);
window.addEventListener('blur', handleFocusEvent, true);
document.addEventListener('visibilitychange', handleFocusEvent, true);

document.addEventListener('keydown', (event) => {
  if (event.target !== keyboardTarget) {
    pushEvent('document', event);
  }
}, true);

document.addEventListener('keyup', (event) => {
  if (event.target !== keyboardTarget) {
    pushEvent('document', event);
  }
}, true);

clearLogButton.addEventListener('click', resetState);
focusInputButton.addEventListener('click', () => {
  keyboardTarget.focus();
  keyboardTarget.select();
  render();
  reportState('focus-input-button');
});
exportLogButton.addEventListener('click', () => {
  const blob = new Blob([JSON.stringify({ runId, summary: buildSummary(), events: eventLog }, null, 2)], {
    type: 'application/json',
  });
  const url = URL.createObjectURL(blob);
  const link = document.createElement('a');
  link.href = url;
  link.download = `cgeventposttopid-${runId}.json`;
  link.click();
  URL.revokeObjectURL(url);
});

window.addEventListener('load', () => {
  keyboardTarget.focus();
  keyboardTarget.select();
  render();
  reportState('window-load');

  if (searchParams.get('demo') === 'cursor') {
    setTimeout(() => {
      playVirtualCursor(buildDefaultDemoPoints(), 2200);
    }, 800);
  }
});

window.addEventListener('pagehide', () => reportState('pagehide'));
document.addEventListener('selectionchange', () => {
  if (document.activeElement === keyboardTarget) {
    reportState('selectionchange');
  }
});

new ResizeObserver(renderTrace).observe(stage);
resetState();
setInterval(pollCursorCommand, 500);
