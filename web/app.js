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
const coverageNode = document.getElementById('coverage');
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
const hidRpcEndpoint = `${location.origin}/hid/rpc`;
const analysisRecordEndpoint = `${location.origin}/analysis/record`;
const analysisReportEndpoint = `${location.origin}/analysis/report`;
const mouseEvents = ['mousemove', 'mousedown', 'mouseup', 'click', 'dblclick', 'contextmenu', 'mouseover', 'mouseenter', 'mouseleave', 'mouseout'];
const pointerEvents = ['pointermove', 'pointerdown', 'pointerup'];
const wheelEvents = ['wheel', 'scroll'];
const dragEvents = ['dragstart', 'drag', 'dragend', 'dragenter', 'dragover', 'drop'];
const keyEvents = ['keydown', 'keyup', 'beforeinput', 'input', 'change'];
const channelColors = {
  user: {
    line: 'rgba(38, 245, 122, 0.94)',
    tailRgb: '84, 240, 255',
    tailAccent: '198, 255, 235',
    label: '人工',
  },
  virtual: {
    line: 'rgba(255, 74, 96, 0.96)',
    tailRgb: '255, 176, 84',
    tailAccent: '255, 225, 182',
    label: 'HID',
  },
};
const learningTargetMeta = {
  '#morph-button': { sig: 'demo-primary.morph-button', role: 'button' },
  '#split-left': { sig: 'demo-primary.split-left', role: 'button' },
  '#split-right': { sig: 'demo-primary.split-right', role: 'button' },
  '#keyboard-target': { sig: 'demo-form.keyboard-target', role: 'textarea' },
  '#range-target': { sig: 'demo-form.range-target', role: 'slider' },
  '#check-target': { sig: 'demo-form.check-target', role: 'checkbox' },
  '#scroll-zone': { sig: 'demo-scroll.zone', role: 'scroll-area' },
  '.scroll-list': { sig: 'demo-scroll.list', role: 'list' },
  '#draggable': { sig: 'demo-drag.source', role: 'draggable' },
  '#drop-zone': { sig: 'demo-drag.drop-zone', role: 'dropzone' },
  '#shadow-button': { sig: 'demo-shadow.button', role: 'button' },
  '#shadow-input': { sig: 'demo-shadow.input', role: 'input' },
  '#frame-a-button': { sig: 'demo-frame-a.button', role: 'button' },
  '#frame-a-input': { sig: 'demo-frame-a.input', role: 'input' },
  '#frame-a-editable': { sig: 'demo-frame-a.editable', role: 'editable' },
  '#frame-b-button': { sig: 'demo-frame-b.button', role: 'button' },
  '#frame-b-input': { sig: 'demo-frame-b.input', role: 'input' },
  '#frame-b-editable': { sig: 'demo-frame-b.editable', role: 'editable' },
};
const expectedEvents = [
  { type: 'mousemove', label: '鼠标移动', group: 'mouse' },
  { type: 'mouseover', label: '进入目标', group: 'mouse' },
  { type: 'mouseenter', label: 'mouseenter', group: 'mouse' },
  { type: 'mouseleave', label: 'mouseleave', group: 'mouse' },
  { type: 'mousedown', label: '鼠标按下', group: 'mouse' },
  { type: 'mouseup', label: '鼠标释放', group: 'mouse' },
  { type: 'click', label: '单击', group: 'mouse' },
  { type: 'dblclick', label: '双击', group: 'mouse' },
  { type: 'contextmenu', label: '右键菜单', group: 'mouse' },
  { type: 'pointermove', label: 'Pointer 移动', group: 'pointer' },
  { type: 'pointerdown', label: 'Pointer 按下', group: 'pointer' },
  { type: 'pointerup', label: 'Pointer 释放', group: 'pointer' },
  { type: 'wheel', label: '滚轮', group: 'wheel' },
  { type: 'scroll', label: '滚动', group: 'wheel' },
  { type: 'dragstart', label: '拖拽开始', group: 'drag' },
  { type: 'drag', label: '拖拽中', group: 'drag' },
  { type: 'dragover', label: '拖拽悬停', group: 'drag' },
  { type: 'drop', label: '拖放完成', group: 'drag' },
  { type: 'dragend', label: '拖拽结束', group: 'drag' },
  { type: 'keydown', label: '键盘按下', group: 'keyboard' },
  { type: 'beforeinput', label: '输入前', group: 'keyboard' },
  { type: 'input', label: '输入', group: 'keyboard' },
  { type: 'keyup', label: '键盘释放', group: 'keyboard' },
  { type: 'change', label: '表单 change', group: 'form' },
];

let captureMode = 'user';
let virtualCaptureUntil = 0;
let calibrationOffset = null;
let lastCursorCommandVersion = -1;
let hudMessage = null;
let summaryCache = null;
let summaryDirty = true;
let pendingUiRender = false;
let lastUiRenderAt = 0;
let lastTraceRenderAt = 0;
let lastReportAt = 0;
let learningSyncPromise = null;

const eventLog = [];
const traceSamples = [];
const eventCounters = new Map();
const channelEventCounters = { user: new Map(), virtual: new Map() };
const channelCounters = { user: 0, virtual: 0 };
const motionSampleState = new Map();
const learningState = {
  syncStatus: 'idle',
  lastLocalHeuristic: null,
  lastBatch: null,
  lastCommit: null,
  lastRebuild: null,
  daemonState: null,
  daemonTemplates: [],
  analysisReport: null,
  lastSyncedAt: null,
  error: null,
};

window.__virtualHIDLab = {
  runId,
  getLog: () => structuredClone(eventLog),
  getSummary: () => buildSummary(),
  compare: () => compareRuns(),
  getAnalysis: () => structuredClone(learningState.analysisReport),
  clear: () => resetState(),
  runVirtualHID: () => runVirtualHIDDemo(),
};

function resetState() {
  eventLog.length = 0;
  traceSamples.length = 0;
  eventCounters.clear();
  channelEventCounters.user.clear();
  channelEventCounters.virtual.clear();
  motionSampleState.clear();
  channelCounters.user = 0;
  channelCounters.virtual = 0;
  keyboardTarget.value = '';
  scrollZone.scrollTop = 0;
  captureMode = 'user';
  virtualCaptureUntil = 0;
  summaryCache = null;
  summaryDirty = true;
  comparisonNode.textContent = '尚未生成对比。';
  learningState.syncStatus = 'idle';
  learningState.lastLocalHeuristic = null;
  learningState.lastBatch = null;
  learningState.lastCommit = null;
  learningState.lastRebuild = null;
  learningState.error = null;
  learningState.analysisReport = null;
  effectsLayer.innerHTML = '';
  reportState('reset', true);
  renderLearningPanel();
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

  if (shouldSkipHighFrequencyEvent(event.type, channel, source, stagePoint)) {
    return;
  }

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
    detail: 'detail' in event ? event.detail : null,
    deltaX: 'deltaX' in event ? round(event.deltaX) : null,
    deltaY: 'deltaY' in event ? round(event.deltaY) : null,
    key: 'key' in event ? event.key : null,
    code: 'code' in event ? event.code : null,
    repeat: 'repeat' in event ? event.repeat : null,
    keyCode: 'keyCode' in event ? event.keyCode : null,
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
  channelEventCounters[channel].set(entry.type, (channelEventCounters[channel].get(entry.type) || 0) + 1);
  channelCounters[channel] += 1;
  summaryDirty = true;

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
  const effectEvents = ['click', 'dblclick', 'wheel', 'scroll', 'keydown', 'keyup', 'dragstart', 'dragend', 'drop', 'mousedown', 'mouseup'];
  if (effectPoint && effectsToggle.checked && effectEvents.includes(entry.type)) {
    spawnEffect(entry.type, effectPoint.x, effectPoint.y, entry);
  }

  if (eventLog.length <= 20 || eventLog.length % 12 === 0 || ['click', 'dblclick', 'wheel', 'drop', 'input'].includes(entry.type)) {
    reportState(`event:${entry.type}`);
  }
  scheduleUiRender();
}

function trimTraceSamples() {
  const max = 6000;
  if (traceSamples.length > max) {
    traceSamples.splice(0, traceSamples.length - max);
  }
}

function buildSummary() {
  if (!summaryDirty && summaryCache) {
    return summaryCache;
  }
  const metrics = {
    user: computeMetrics('user'),
    virtual: computeMetrics('virtual'),
  };
  summaryCache = {
    runId,
    mode: effectiveCaptureMode(),
    total: eventLog.length,
    channelCounters: { ...channelCounters },
    counters: Object.fromEntries(eventCounters.entries()),
    focus: {
      hasFocus: document.hasFocus(),
      visibilityState: document.visibilityState,
      activeElement: targetLabel(document.activeElement),
    },
    calibrationOffset,
    metrics,
  };
  summaryDirty = false;
  return summaryCache;
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
  const adaptiveProfile = buildAdaptiveProfile(user);
  const learned = {
    generatedAt: new Date().toISOString(),
    basis: 'client-side heuristic comparison',
    appliesToDemo: true,
    adaptiveProfile,
    suggestions,
  };
  localStorage.setItem('virtualhid.demo.learningProfile', JSON.stringify(learned));
  learningState.lastLocalHeuristic = learned;
  comparisonNode.textContent = JSON.stringify(comparison, null, 2);
  renderLearningPanel();
  syncLearningToDaemon(learned).catch((error) => {
    setHudMessage(`学习回灌失败：${error.message}`, 6000);
  });
  persistAnalysisRecord(comparison, learned).catch((error) => {
    learningState.error = error.message;
    renderLearningPanel();
  });
  reportState('compare', true);
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

function buildAdaptiveProfile(user) {
  const moveSpeedPxS = clamp(user.avgSpeedPxS || 320, 100, 1000);
  const clickHoldMs = clamp(Math.round(36 + user.pauses * 10 + user.turnJitter * 8), 30, 88);
  const settleMs = clamp(Math.round(50 + user.pauses * 18), 40, 180);
  return {
    moveSpeedPxS,
    clickHoldMs,
    settleMs,
    basedOn: {
      pointCount: user.pointCount,
      avgSpeedPxS: user.avgSpeedPxS,
      pauses: user.pauses,
      turnJitter: user.turnJitter,
    },
  };
}

function loadAdaptiveProfile() {
  try {
    const raw = localStorage.getItem('virtualhid.demo.learningProfile');
    if (!raw) {
      return null;
    }
    const parsed = JSON.parse(raw);
    return parsed?.adaptiveProfile || null;
  } catch (_) {
    return null;
  }
}

function renderLearningPanel() {
  if (
    !learningState.lastLocalHeuristic &&
    !learningState.daemonState &&
    !learningState.error &&
    learningState.syncStatus === 'idle'
  ) {
    learningNode.textContent = '先完成用户采集和 VirtualHID 采集。';
    return;
  }
  const payload = {
    localHeuristic: learningState.lastLocalHeuristic,
    daemonLearning: {
      status: learningState.syncStatus,
      lastSyncedAt: learningState.lastSyncedAt,
      batch: learningState.lastBatch,
      commit: learningState.lastCommit,
      rebuild: learningState.lastRebuild,
      profiles: learningState.daemonState?.profiles || null,
      templates: learningState.daemonTemplates,
      analysis: learningState.analysisReport,
      error: learningState.error,
    },
  };
  learningNode.textContent = JSON.stringify(payload, null, 2);
}

function learningHost() {
  return location.host || 'virtualhid.local';
}

function learningContextBase() {
  return {
    host: learningHost(),
    taskId: 'compare-capture',
    stage: 'web-lab',
  };
}

function analysisInstructionKey() {
  const base = learningContextBase();
  return `${base.host}|${base.taskId}|${base.stage}|web-demo-complex-stage`;
}

async function callHidRpc(method, params = {}) {
  const response = await fetch(hidRpcEndpoint, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      id: `web-rpc-${method}-${Date.now()}-${Math.random().toString(16).slice(2, 8)}`,
      method,
      params,
    }),
  });
  return readJsonResponse(response, '/hid/rpc');
}

async function syncLearningToDaemon(localHeuristic) {
  learningState.lastLocalHeuristic = localHeuristic;
  if (learningSyncPromise) {
    return learningSyncPromise;
  }

  const batch = buildLearningCommitBatch();
  learningState.lastBatch = batch.summary;
  learningState.lastCommit = null;
  learningState.lastRebuild = null;
  learningState.error = null;

  if (!batch.commits.length) {
    learningState.syncStatus = 'skipped';
    renderLearningPanel();
    return null;
  }

  learningState.syncStatus = 'syncing';
  renderLearningPanel();

  learningSyncPromise = (async () => {
    const commitResults = await commitLearningBatch(batch.commits);
    const commitSummary = summarizeCommitBatch(commitResults);
    learningState.lastCommit = commitSummary;

    if (commitSummary.committed > 0) {
      const rebuildPayload = await callHidRpc('profiles.rebuild', { host: learningHost() });
      if (!rebuildPayload.ok) {
        throw new Error(rebuildPayload.error?.message || 'profiles.rebuild failed');
      }
      learningState.lastRebuild = rebuildPayload.result;

      const templatesPayload = await callHidRpc('profiles.list', { host: learningHost() });
      if (!templatesPayload.ok) {
        throw new Error(templatesPayload.error?.message || 'profiles.list failed');
      }
      learningState.daemonTemplates = compactDaemonTemplates(templatesPayload.result?.templates || []);
      learningState.syncStatus = 'ready';
      learningState.lastSyncedAt = new Date().toISOString();
      await refreshAnalysisReport();
    } else {
      learningState.syncStatus = commitSummary.errors > 0 ? 'error' : 'skipped';
      if (commitSummary.errors > 0) {
        learningState.error = 'trace.commit 全部失败，未生成新的学习模板。';
      }
    }

    await refreshHidState();
  })().catch((error) => {
    learningState.syncStatus = 'error';
    learningState.error = error.message;
    throw error;
  }).finally(() => {
    learningSyncPromise = null;
    renderLearningPanel();
  });

  return learningSyncPromise;
}

async function persistAnalysisRecord(comparison, learned) {
  const record = buildAnalysisRecord(comparison, learned);
  const response = await fetch(analysisRecordEndpoint, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(record),
  });
  await readJsonResponse(response, '/analysis/record');
  await refreshAnalysisReport();
}

async function refreshAnalysisReport() {
  const params = new URLSearchParams({
    host: learningHost(),
    instructionKey: analysisInstructionKey(),
  });
  const response = await fetch(`${analysisReportEndpoint}?${params.toString()}`, { cache: 'no-store' });
  learningState.analysisReport = await readJsonResponse(response, '/analysis/report');
  renderLearningPanel();
  return learningState.analysisReport;
}

async function commitLearningBatch(commits) {
  const results = [];
  const chunkSize = 6;
  for (let index = 0; index < commits.length; index += chunkSize) {
    const chunk = commits.slice(index, index + chunkSize);
    const chunkResults = await Promise.all(chunk.map(async (commit) => {
      try {
        const payload = await callHidRpc('trace.commit', commit.params);
        return { commit, payload };
      } catch (error) {
        return {
          commit,
          payload: {
            ok: false,
            error: { code: 'E_RPC_FAILED', message: error.message },
          },
        };
      }
    }));
    results.push(...chunkResults);
  }
  return results;
}

function summarizeCommitBatch(results) {
  const byType = {};
  const reasons = {};
  const summary = {
    attempted: results.length,
    committed: 0,
    dropped: 0,
    errors: 0,
    byType,
    reasons,
  };

  for (const item of results) {
    byType[item.commit.kind] = (byType[item.commit.kind] || 0) + 1;
    if (!item.payload?.ok) {
      summary.errors += 1;
      const code = item.payload?.error?.code || 'E_UNKNOWN';
      reasons[code] = (reasons[code] || 0) + 1;
      continue;
    }
    if (item.payload.result?.committed) {
      summary.committed += 1;
      continue;
    }
    if (item.payload.result?.dropped) {
      summary.dropped += 1;
      const reason = item.payload.result?.reason || 'dropped';
      reasons[reason] = (reasons[reason] || 0) + 1;
      continue;
    }
    const reason = item.payload.result?.reason || 'no_effect';
    reasons[reason] = (reasons[reason] || 0) + 1;
  }

  return summary;
}

function compactDaemonTemplates(templates) {
  return [...templates]
    .sort((left, right) => {
      if ((right.sampleSize || 0) !== (left.sampleSize || 0)) {
        return (right.sampleSize || 0) - (left.sampleSize || 0);
      }
      return (right.confidence || 0) - (left.confidence || 0);
    })
    .slice(0, 8)
    .map((template) => ({
      elementSig: template.elementSig,
      actionType: template.actionType,
      sampleSize: template.sampleSize,
      confidence: round(template.confidence),
      updatedAt: template.updatedAt,
    }));
}

function buildLearningCommitBatch() {
  const userEntries = eventLog.filter((entry) => entry.channel === 'user');
  const commits = [
    ...deriveMoveLearningCommits(userEntries),
    ...deriveClickLearningCommits(userEntries),
    ...deriveDragLearningCommits(userEntries),
    ...deriveTypeLearningCommits(userEntries),
  ];
  return {
    commits,
    summary: {
      host: learningHost(),
      sourceEvents: userEntries.length,
      sourceTracePoints: traceSamples.filter((point) => point.channel === 'user').length,
      totalCommits: commits.length,
      byType: commits.reduce((accumulator, commit) => {
        accumulator[commit.kind] = (accumulator[commit.kind] || 0) + 1;
        return accumulator;
      }, {}),
    },
  };
}

function deriveMoveLearningCommits(userEntries) {
  const moveEntries = sampleEvenly(
    userEntries.filter((entry) => ['mousemove', 'pointermove'].includes(entry.type) && hasStagePoint(entry)),
    12,
  );
  const commits = moveEntries
    .map((entry, index) => {
      const point = screenPointForEntry(entry);
      if (!point) {
        return null;
      }
      const pathEntries = collectPathWindow(
        userEntries,
        entry,
        (candidate) => ['mousemove', 'pointermove'].includes(candidate.type) && hasStagePoint(candidate),
        1100,
        18,
      );
      const payload = buildLearningPayloadFromEntries(pathEntries, point, {
        eventType: 'mouseMoved',
        traceType: 'move',
        targetRadiusPx: 8,
      });
      return buildLearningCommit('move', 'mouseMoved', resolveLearningTargetMeta(entry), point, {}, index, payload);
    })
    .filter(Boolean);

  if (commits.length >= 6) {
    return commits;
  }

  const fallback = sampleEvenly(
    traceSamples.filter((point) => point.channel === 'user'),
    Math.max(0, 6 - commits.length),
  )
    .map((point, index) => {
      const screenPoint = stagePointToScreenPoint(point.x, point.y);
      if (!screenPoint) {
        return null;
      }
      const payload = buildLearningPayloadFromPoints([screenPoint], [], {
        eventType: 'mouseMoved',
        traceType: 'move',
        targetRadiusPx: 8,
      });
      return buildLearningCommit(
        'move',
        'mouseMoved',
        { sig: 'web-demo-complex-stage', role: 'region' },
        screenPoint,
        {},
        commits.length + index,
        payload,
      );
    })
    .filter(Boolean);
  return [...commits, ...fallback];
}

function deriveClickLearningCommits(userEntries) {
  return sampleEvenly(
    userEntries.filter((entry) => entry.type === 'mousedown' && hasStagePoint(entry)),
    10,
  )
    .map((entry, index, entries) => {
      const point = screenPointForEntry(entry);
      if (!point) {
        return null;
      }
      const pathEntries = collectPathWindow(
        userEntries,
        entry,
        (candidate) => ['mousemove', 'pointermove'].includes(candidate.type) && hasStagePoint(candidate),
        900,
        14,
      );
      const upEntry = findNextEntry(
        userEntries,
        entry,
        (candidate) => candidate.type === 'mouseup' && candidate.button === entry.button && candidate.target === entry.target,
        420,
      );
      const nextDown = findNextEntry(
        entries,
        entry,
        (candidate) => candidate !== entry && candidate.type === 'mousedown' && candidate.button === entry.button,
        540,
      );
      const payload = buildLearningPayloadFromEntries(pathEntries, point, {
        eventType: mouseDownActionType(entry.button),
        traceType: 'click',
        targetRadiusPx: 6,
        clickHoldMs: upEntry ? [Math.max(12, upEntry.timestamp - entry.timestamp)] : [],
        interClickMs: nextDown ? [Math.max(24, nextDown.timestamp - entry.timestamp)] : [],
      });
      return buildLearningCommit(
        'click',
        mouseDownActionType(entry.button),
        resolveLearningTargetMeta(entry),
        point,
        {},
        index,
        payload,
      );
    })
    .filter(Boolean);
}

function deriveDragLearningCommits(userEntries) {
  const dragStarts = userEntries.filter((entry) => entry.type === 'dragstart');
  return sampleEvenly(dragStarts, 8)
    .map((entry, index) => {
      const segment = collectDragSegment(userEntries, entry);
      const endpoint = screenPointForEntry(segment.at(-1)) || screenPointForEntry(entry);
      if (!endpoint) {
        return null;
      }
      const payload = buildLearningPayloadFromEntries(segment, endpoint, {
        eventType: 'leftMouseDragged',
        traceType: 'drag',
        targetRadiusPx: 12,
      });
      return buildLearningCommit('drag', 'leftMouseDragged', resolveLearningTargetMeta(entry), endpoint, {}, index, payload);
    })
    .filter(Boolean);
}

function deriveTypeLearningCommits(userEntries) {
  const keydowns = sampleEvenly(
    userEntries.filter((entry) => entry.type === 'keydown' && entry.target === '#keyboard-target'),
    16,
  );
  return keydowns
    .map((entry, index) => {
      const point = screenPointForEntry(entry) || screenPointForElement(keyboardTarget);
      const keyUp = findNextEntry(
        userEntries,
        entry,
        (candidate) => candidate.type === 'keyup' && candidate.code === entry.code && candidate.target === entry.target,
        420,
      );
      const previousDown = findPreviousEntry(
        userEntries,
        entry,
        (candidate) => candidate.type === 'keydown' && candidate.target === entry.target,
        1200,
      );
      const dwellMs = keyUp ? [Math.max(16, keyUp.timestamp - entry.timestamp)] : [];
      const interKeyMs = previousDown ? [Math.max(24, entry.timestamp - previousDown.timestamp)] : [];
      const payload = buildLearningPayloadFromPoints(point ? [point] : [], [], {
        eventType: 'keyDown',
        traceType: 'type',
        dwellMs,
        interKeyMs,
      });
      return buildLearningCommit(
        'type',
        'keyDown',
        resolveLearningTargetMeta(entry),
        point,
        entry.keyCode ? { keyCode: entry.keyCode } : {},
        index,
        payload,
      );
    })
    .filter(Boolean);
}

function buildLearningCommit(kind, actionType, meta, point, extra, index, payload = null) {
  const params = {
    eventId: buildLearningEventId(kind, meta.sig, index),
    actionType,
    traceType: kind,
    elementSig: meta.sig,
    role: meta.role,
    ...learningContextBase(),
    ...extra,
  };
  if (point) {
    params.point = point;
  }
  if (payload) {
    params.payload = payload;
  }
  return { kind, params };
}

function buildAnalysisRecord(comparison, learned) {
  return {
    version: 1,
    ts: new Date().toISOString(),
    runId,
    host: learningHost(),
    taskId: learningContextBase().taskId,
    stage: learningContextBase().stage,
    instructionKey: analysisInstructionKey(),
    instructionShape: {
      expectedEventTypes: expectedEvents.length,
      userTargets: comparison.user.targetHits.slice(0, 16),
      hidTargets: comparison.virtual.targetHits.slice(0, 16),
    },
    comparison,
    heuristic: {
      adaptiveProfile: learned.adaptiveProfile,
      suggestions: learned.suggestions,
    },
    daemonLearning: {
      profiles: learningState.daemonState?.profiles || null,
      templates: learningState.daemonTemplates,
    },
  };
}

function collectPathWindow(entries, anchor, predicate, lookbackMs, limit) {
  return entries
    .filter((entry) => entry.timestamp <= anchor.timestamp && anchor.timestamp - entry.timestamp <= lookbackMs && predicate(entry))
    .slice(-limit);
}

function findNextEntry(entries, anchor, predicate, lookaheadMs) {
  return entries.find((entry) => entry.timestamp > anchor.timestamp && entry.timestamp - anchor.timestamp <= lookaheadMs && predicate(entry)) || null;
}

function findPreviousEntry(entries, anchor, predicate, lookbackMs) {
  const matches = entries.filter((entry) => entry.timestamp < anchor.timestamp && anchor.timestamp - entry.timestamp <= lookbackMs && predicate(entry));
  return matches.length ? matches[matches.length - 1] : null;
}

function collectDragSegment(entries, dragStart) {
  const startIndex = entries.indexOf(dragStart);
  if (startIndex < 0) {
    return [dragStart];
  }
  const segment = [];
  for (let index = startIndex; index < entries.length; index += 1) {
    const entry = entries[index];
    segment.push(entry);
    if (index > startIndex && ['drop', 'dragend'].includes(entry.type)) {
      break;
    }
    if (entry.timestamp - dragStart.timestamp > 5000) {
      break;
    }
  }
  return segment.filter((entry) => ['dragstart', 'drag', 'dragover', 'dragenter', 'drop', 'dragend', 'mousemove', 'pointermove'].includes(entry.type));
}

function buildLearningPayloadFromEntries(entries, finalPoint, overrides = {}) {
  const timedPoints = extractTimedScreenPoints(entries, finalPoint);
  return buildLearningPayloadFromPoints(
    timedPoints.map((item) => item.point),
    timedPoints.map((item) => item.ts),
    overrides,
  );
}

function buildLearningPayloadFromPoints(points, timestamps, overrides = {}) {
  const filteredPoints = points.filter((point) => Number.isFinite(point?.x) && Number.isFinite(point?.y));
  const analysis = analyzeLearningPath(filteredPoints, timestamps);
  const dwellMs = overrides.dwellMs || [];
  const interKeyMs = overrides.interKeyMs || [];
  const targetPoint = overrides.targetPoint || filteredPoints.at(-1) || null;
  const behaviorMode = overrides.behaviorMode || inferLearningBehaviorMode(analysis, overrides.traceType, dwellMs, interKeyMs);
  const flavor = overrides.flavor || inferLearningFlavor(behaviorMode, analysis);
  return {
    type: overrides.eventType || 'mouseMoved',
    points: filteredPoints.map((point) => ({ x: round(point.x), y: round(point.y) })),
    origin: filteredPoints[0] ? { x: round(filteredPoints[0].x), y: round(filteredPoints[0].y) } : null,
    targetPoint: targetPoint ? { x: round(targetPoint.x), y: round(targetPoint.y) } : null,
    targetRadiusPx: overrides.targetRadiusPx ?? analysis.targetRadiusPx,
    landingErrorPx: overrides.landingErrorPx ?? analysis.landingErrorPx,
    durationMs: analysis.durationMs,
    segmentMs: analysis.segmentMs,
    hesitationMs: overrides.hesitationMs || analysis.hesitationMs,
    clickHoldMs: overrides.clickHoldMs || [],
    interClickMs: overrides.interClickMs || [],
    dwellMs,
    interKeyMs,
    behaviorMode,
    flavor,
    straightness: analysis.straightness,
    turnJitter: analysis.turnJitter,
    pathLengthPx: analysis.pathLengthPx,
    speedPxS: analysis.speedPxS,
  };
}

function extractTimedScreenPoints(entries, finalPoint) {
  const timed = entries
    .map((entry) => {
      const point = screenPointForEntry(entry);
      return point ? { point, ts: entry.timestamp } : null;
    })
    .filter(Boolean);
  if (finalPoint && (!timed.length || timed[timed.length - 1].point.x !== finalPoint.x || timed[timed.length - 1].point.y !== finalPoint.y)) {
    timed.push({ point: finalPoint, ts: timed.length ? timed[timed.length - 1].ts + 16 : Date.now() });
  }
  return timed;
}

function analyzeLearningPath(points, timestamps) {
  if (points.length <= 1) {
    return {
      durationMs: 0,
      segmentMs: [],
      hesitationMs: [],
      pathLengthPx: 0,
      speedPxS: 0,
      straightness: 1,
      turnJitter: 0,
      targetRadiusPx: 6,
      landingErrorPx: 0,
    };
  }

  let pathLengthPx = 0;
  const segmentMs = [];
  const turnAngles = [];
  for (let index = 1; index < points.length; index += 1) {
    const distance = Math.hypot(points[index].x - points[index - 1].x, points[index].y - points[index - 1].y);
    pathLengthPx += distance;
    if (timestamps[index] && timestamps[index - 1]) {
      segmentMs.push(Math.max(8, timestamps[index] - timestamps[index - 1]));
    }
    if (index >= 2) {
      const before = points[index - 2];
      const previous = points[index - 1];
      const current = points[index];
      const a1 = Math.atan2(previous.y - before.y, previous.x - before.x);
      const a2 = Math.atan2(current.y - previous.y, current.x - previous.x);
      turnAngles.push(Math.abs(normalizeAngle(a2 - a1)));
    }
  }
  const durationMs = segmentMs.reduce((sum, value) => sum + value, 0);
  const directDistance = Math.hypot(points.at(-1).x - points[0].x, points.at(-1).y - points[0].y);
  const targetRadiusPx = clamp(round(Math.max(4, stddev(points.map((point) => Math.hypot(point.x - points.at(-1).x, point.y - points.at(-1).y)))) || 6), 4, 28);
  const landingErrorPx = round(mean(points.slice(-3).map((point) => Math.hypot(point.x - points.at(-1).x, point.y - points.at(-1).y))));
  const hesitationBaseline = percentile(segmentMs, 0.55);
  const hesitationMs = segmentMs.filter((value) => value > Math.max(90, hesitationBaseline * 1.8));
  return {
    durationMs: round(durationMs),
    segmentMs: segmentMs.map(round),
    hesitationMs: hesitationMs.map(round),
    pathLengthPx: round(pathLengthPx),
    speedPxS: durationMs > 0 ? round(pathLengthPx / (durationMs / 1000)) : 0,
    straightness: pathLengthPx > 0 ? round(directDistance / pathLengthPx) : 1,
    turnJitter: round(stddev(turnAngles)),
    targetRadiusPx,
    landingErrorPx: Number.isFinite(landingErrorPx) ? landingErrorPx : 0,
  };
}

function inferLearningBehaviorMode(analysis, traceType, dwellMs = [], interKeyMs = []) {
  if (traceType === 'type') {
    return mean(interKeyMs) > 180 || mean(dwellMs) > 150 ? 'idle' : 'normal';
  }
  if ((analysis.speedPxS || 0) >= 650 && (analysis.hesitationMs || []).length === 0 && (analysis.straightness || 0.8) >= 0.72) {
    return 'flow';
  }
  if ((analysis.speedPxS || 0) <= 180 && (analysis.hesitationMs || []).length >= 1) {
    return 'idle';
  }
  if ((analysis.hesitationMs || []).length >= 2 || (analysis.turnJitter || 0) >= 0.45 || (analysis.straightness || 1) < 0.55) {
    return 'low-efficiency';
  }
  return 'normal';
}

function inferLearningFlavor(behaviorMode, analysis) {
  if (behaviorMode === 'flow') {
    return 'hurried';
  }
  if (behaviorMode === 'idle') {
    return 'idle';
  }
  if ((analysis.turnJitter || 0) > 0.34 || (analysis.straightness || 1) < 0.72) {
    return 'gentle';
  }
  return 'smooth';
}

function buildLearningEventId(kind, sig, index) {
  const safeSig = String(sig || 'unknown').replace(/[^a-zA-Z0-9._-]+/g, '-').slice(0, 48);
  return `weblearn-${runId}-${kind}-${safeSig}-${index}`;
}

function resolveLearningTargetMeta(entry) {
  if (entry?.target && learningTargetMeta[entry.target]) {
    return learningTargetMeta[entry.target];
  }
  switch (entry?.source) {
    case 'keyboard':
      return learningTargetMeta['#keyboard-target'];
    case 'range':
      return learningTargetMeta['#range-target'];
    case 'checkbox':
      return learningTargetMeta['#check-target'];
    case 'draggable':
      return learningTargetMeta['#draggable'];
    case 'drop-zone':
      return learningTargetMeta['#drop-zone'];
    case 'shadow-dom':
      return { sig: 'demo-shadow.region', role: 'region' };
    case 'frame-a':
      return { sig: 'demo-frame-a.region', role: 'frame' };
    case 'frame-b':
      return { sig: 'demo-frame-b.region', role: 'frame' };
    case 'stage':
      return { sig: 'web-demo-complex-stage', role: 'region' };
    default:
      return { sig: 'web-demo-complex-stage', role: 'region' };
  }
}

function sampleEvenly(items, limit) {
  if (items.length <= limit) {
    return [...items];
  }
  if (limit <= 1) {
    return items.length ? [items[items.length - 1]] : [];
  }
  const step = (items.length - 1) / (limit - 1);
  const sampled = [];
  for (let index = 0; index < limit; index += 1) {
    sampled.push(items[Math.round(index * step)]);
  }
  return sampled;
}

function hasStagePoint(entry) {
  return Number.isFinite(entry?.stageX) && Number.isFinite(entry?.stageY);
}

function screenPointForEntry(entry) {
  if (Number.isFinite(entry?.screenX) && Number.isFinite(entry?.screenY)) {
    return { x: round(entry.screenX), y: round(entry.screenY) };
  }
  if (Number.isFinite(entry?.clientX) && Number.isFinite(entry?.clientY)) {
    const offset = calibrationOffset || fallbackScreenOffset();
    return {
      x: round(entry.clientX + offset.x),
      y: round(entry.clientY + offset.y),
    };
  }
  if (hasStagePoint(entry)) {
    return stagePointToScreenPoint(entry.stageX, entry.stageY);
  }
  return null;
}

function stagePointToScreenPoint(stageX, stageY) {
  if (!Number.isFinite(stageX) || !Number.isFinite(stageY)) {
    return null;
  }
  const rect = stage.getBoundingClientRect();
  const clientX = rect.left + stageX;
  const clientY = rect.top + stageY;
  const offset = calibrationOffset || fallbackScreenOffset();
  return {
    x: round(clientX + offset.x),
    y: round(clientY + offset.y),
  };
}

function screenPointForElement(element) {
  if (!element) {
    return null;
  }
  const point = getElementScreenPoint(element);
  return {
    x: round(point.x),
    y: round(point.y),
  };
}

function fallbackScreenOffset() {
  return {
    x: window.screenX,
    y: window.screenY + Math.max(0, window.outerHeight - window.innerHeight),
  };
}

function mouseDownActionType(button) {
  if (button === 2) {
    return 'rightMouseDown';
  }
  if (button === 1) {
    return 'otherMouseDown';
  }
  return 'leftMouseDown';
}

function mouseUpActionType(button) {
  if (button === 2) {
    return 'rightMouseUp';
  }
  if (button === 1) {
    return 'otherMouseUp';
  }
  return 'leftMouseUp';
}

async function runVirtualHIDDemo() {
  captureMode = 'virtual';
  virtualCaptureUntil = performance.now() + 16000;
  const adaptiveProfile = loadAdaptiveProfile() || buildAdaptiveProfile(buildSummary().metrics.user);
  const hidState = await refreshHidState();
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
  let previousPoint = hidState?.cursor
    ? { x: Number(hidState.cursor.x), y: Number(hidState.cursor.y) }
    : null;

  for (const target of targets) {
    const point = getElementScreenPoint(target);
    primitives.push({
      type: 'move',
      to: point,
      via: 'wind',
      durationMs: estimateMoveDuration(previousPoint, point, adaptiveProfile, 520),
    });
    primitives.push({
      type: 'click',
      at: point,
      button: 'left',
      holdMs: adaptiveProfile?.clickHoldMs ?? 45,
      count: 1,
    });
    previousPoint = point;
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
    const payload = await readJsonResponse(response, '/hid/action');
    if (!payload.ok) {
      setHudMessage(`VirtualHID 调用失败：${payload.error?.code || 'E_UNKNOWN'} ${payload.error?.message || ''}`, 6000);
      playVirtualCursorPreview(targets);
      return;
    }
    setHudMessage(`VirtualHID 已调用：post=${payload.result?.post?.used || 'unknown'} dryRun=${dryRunToggle.checked} learn=${adaptiveProfile ? 'on' : 'off'}`, 6000);
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
    const payload = await readJsonResponse(response, '/hid/state');
    if (payload.ok) {
      learningState.daemonState = payload.result;
      renderLearningPanel();
      return payload.result;
    }
  } catch (_) {
  }
  return null;
}

async function readJsonResponse(response, endpoint) {
  const text = await response.text();
  try {
    return JSON.parse(text);
  } catch (error) {
    const preview = text.trim().slice(0, 80).replace(/\s+/g, ' ');
    throw new Error(`${endpoint} 返回的不是 JSON。通常是没有用 scripts/report_server.py 启动页面，或 8123 上跑的是旧服务。HTTP ${response.status}; preview=${preview}`);
  }
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
    channelEventCounters.virtual.set('mousemove', (channelEventCounters.virtual.get('mousemove') || 0) + 1);
    summaryDirty = true;
    spawnEffect('click', point.x, point.y);
    scheduleUiRender();
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
  const summary = buildSummary();
  renderStatus(summary);
  renderSummary(summary);
  renderCoverage();
  renderLog();
}

function renderStatus(summary) {
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

function renderSummary(summary) {
  summaryNode.innerHTML = [
    `总事件：${summary.total}`,
    `当前 activeElement：${summary.focus.activeElement}`,
    `用户轨迹点：${summary.metrics.user.pointCount}，虚拟轨迹点：${summary.metrics.virtual.pointCount}`,
    `<span class="legend-dot user"></span>人工平均速度：${summary.metrics.user.avgSpeedPxS}px/s`,
    `<span class="legend-dot virtual"></span>HID平均速度：${summary.metrics.virtual.avgSpeedPxS}px/s`,
    `<span class="metric-note">平均速度 = 轨迹总长度 / 轨迹持续时长，只用于人工和 HID 的相对对比，不等于系统鼠标灵敏度。</span>`,
    `事件计数：${JSON.stringify(summary.counters)}`,
  ].map((line) => `<div>${line.includes('<span') ? line : escapeHtml(line)}</div>`).join('');
}

function renderCoverage() {
  const rows = expectedEvents.map((item) => {
    const userCount = countEvent(item.type, 'user');
    const hidCount = countEvent(item.type, 'virtual');
    const state = userCount > 0 || hidCount > 0 ? 'hit' : 'miss';
    return `
      <div class="coverage-row ${state}">
        <span class="coverage-name">${escapeHtml(item.label)}</span>
        <span class="coverage-type">${escapeHtml(item.type)}</span>
        <span class="coverage-pill user">人 ${userCount}</span>
        <span class="coverage-pill virtual">HID ${hidCount}</span>
      </div>
    `;
  }).join('');
  coverageNode.innerHTML = rows;
}

function countEvent(type, channel) {
  return channelEventCounters[channel].get(type) || 0;
}

function renderLog() {
  logNode.textContent = eventLog.slice(-40).map((entry) => JSON.stringify(entry)).join('\n');
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
  drawPath(ctx, persistent.filter((point) => point.channel === 'user'), channelColors.user.line, 1.5, 0.5);
  drawPath(ctx, persistent.filter((point) => point.channel === 'virtual'), channelColors.virtual.line, 1.5, 0.54);
  drawTail(ctx, tail.filter((point) => point.channel === 'user'), now, channelColors.user.tailRgb, channelColors.user.tailAccent);
  drawTail(ctx, tail.filter((point) => point.channel === 'virtual'), now, channelColors.virtual.tailRgb, channelColors.virtual.tailAccent);

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

function drawTail(ctx, points, now, rgb, accentRgb) {
  if (points.length < 2) {
    return;
  }
  for (let index = 1; index < points.length; index += 1) {
    const point = points[index];
    const previous = points[index - 1];
    const age = Math.min(1, (now - point.ts) / 4200);
    const energy = 1 - age;
    ctx.strokeStyle = `rgba(${rgb}, ${energy * 0.94})`;
    ctx.lineWidth = 1.25 + energy * 3.7;
    ctx.lineCap = 'round';
    ctx.shadowColor = `rgba(${accentRgb}, ${energy * 0.7})`;
    ctx.shadowBlur = 12 * energy;
    ctx.beginPath();
    ctx.moveTo(previous.x, previous.y);
    ctx.lineTo(point.x, point.y);
    ctx.stroke();

    if (index % 2 === 0) {
      ctx.fillStyle = `rgba(${accentRgb}, ${energy * 0.45})`;
      ctx.beginPath();
      ctx.arc(point.x + Math.sin(index) * 1.8, point.y + Math.cos(index * 1.4) * 1.8, 0.7 + energy * 1.4, 0, Math.PI * 2);
      ctx.fill();
    }
  }
  ctx.shadowBlur = 0;
}

function spawnEffect(type, x, y, entry = {}) {
  if (type === 'click') {
    spawnTapEffect(x, y, 'single');
    return;
  }
  if (type === 'dblclick') {
    spawnTapEffect(x, y, 'double');
    setTimeout(() => spawnTapEffect(x, y, 'double'), 125);
    return;
  }
  if (type === 'dragstart' || type === 'dragend' || type === 'drop') {
    spawnDragEffect(type, x, y, entry);
    return;
  }
  if (type === 'wheel' || type === 'scroll') {
    spawnBasicEffect('wheel', x, y);
    return;
  }

  spawnBasicEffect(type.startsWith('key') ? 'key' : 'press', x, y, entry.key || 'key');
}

function spawnBasicEffect(kind, x, y, text = '') {
  const effect = document.createElement('div');
  effect.className = `fx ${kind}`;
  effect.style.left = `${x}px`;
  effect.style.top = `${y}px`;
  effect.textContent = kind === 'key' ? text : '';
  effectsLayer.append(effect);
  setTimeout(() => effect.remove(), kind === 'wheel' ? 760 : 900);
}

function spawnTapEffect(x, y, variant = 'single') {
  const effect = document.createElement('div');
  effect.className = `tap-bloom ${variant}`;
  effect.style.left = `${x}px`;
  effect.style.top = `${y}px`;
  effectsLayer.append(effect);
  setTimeout(() => effect.remove(), 620);
}

function spawnDragEffect(type, x, y, entry = {}) {
  if (type === 'drop') {
    spawnTapEffect(x, y, 'drop');
    return;
  }
  spawnTapEffect(x, y, 'single');
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

function reportState(reason, force = false) {
  const now = performance.now();
  if (!force && now - lastReportAt < 900) {
    return;
  }
  lastReportAt = now;
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

function percentile(values, ratio) {
  if (!values.length) {
    return 0;
  }
  const sorted = [...values].sort((left, right) => left - right);
  if (sorted.length === 1) {
    return sorted[0];
  }
  const clamped = clamp(ratio, 0, 1);
  const index = clamped * (sorted.length - 1);
  const lower = Math.floor(index);
  const upper = Math.ceil(index);
  if (lower === upper) {
    return sorted[lower];
  }
  const progress = index - lower;
  return sorted[lower] + (sorted[upper] - sorted[lower]) * progress;
}

function round(value) {
  return Number(Number(value || 0).toFixed(2));
}

function clamp(value, min, max) {
  return Math.min(max, Math.max(min, value));
}

function estimateMoveDuration(from, to, adaptiveProfile, fallback) {
  if (!from || !to || !adaptiveProfile?.moveSpeedPxS) {
    return fallback;
  }
  const distance = Math.hypot(to.x - from.x, to.y - from.y);
  return clamp(Math.round(distance / adaptiveProfile.moveSpeedPxS * 1000 + (adaptiveProfile.settleMs || 0)), 180, 1600);
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

function shouldSkipHighFrequencyEvent(type, channel, source, stagePoint) {
  if (!stagePoint || !['mousemove', 'pointermove', 'drag', 'dragover'].includes(type)) {
    return false;
  }
  const key = `${channel}:${source}`;
  const now = performance.now();
  const previous = motionSampleState.get(key);
  motionSampleState.set(key, { ts: now, x: stagePoint.x, y: stagePoint.y });
  if (!previous) {
    return false;
  }
  return now - previous.ts < 24 && Math.hypot(stagePoint.x - previous.x, stagePoint.y - previous.y) < 6;
}

function scheduleUiRender() {
  if (pendingUiRender) {
    return;
  }
  pendingUiRender = true;
  const delay = Math.max(0, 120 - (performance.now() - lastUiRenderAt));
  setTimeout(() => {
    requestAnimationFrame(() => {
      pendingUiRender = false;
      lastUiRenderAt = performance.now();
      render();
    });
  }, delay);
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
window.addEventListener('pagehide', () => reportState('pagehide', true));

new ResizeObserver(() => renderTrace()).observe(stage);
wireComplexDom();
resetState();
refreshHidState();
refreshAnalysisReport().catch(() => {});
setInterval(pollCursorCommand, 500);
function animationLoop(now = 0) {
  if (now - lastTraceRenderAt >= 33) {
    renderTrace();
    lastTraceRenderAt = now;
  }
  requestAnimationFrame(animationLoop);
}
animationLoop();
