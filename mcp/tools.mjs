const agentNotice = "本工具由 Agent 调度使用，执行前请先通过上游观察工具完成窗口、目标与安全前置条件；当目标是网页时，host 必须从 browser 原始 URL / active tab / snapshot 语义传递而来，禁止凭空编造或写站点分支。";

const objectSchema = {
  type: "object",
  additionalProperties: true
};

const pointSchema = {
  type: "object",
  required: ["x", "y"],
  properties: {
    x: { type: "number" },
    y: { type: "number" }
  },
  additionalProperties: true
};

const primitiveSchema = {
  oneOf: [
    {
      type: "object",
      required: ["type", "to"],
      properties: {
        type: { const: "move" },
        to: pointSchema,
        via: { type: "string" },
        durationMs: { type: "integer" },
        profile: objectSchema
      },
      additionalProperties: true
    },
    {
      type: "object",
      required: ["type", "at"],
      properties: {
        type: { const: "click" },
        at: pointSchema,
        button: { type: "string" },
        holdMs: { type: "integer" },
        count: { type: "integer" },
        profile: objectSchema
      },
      additionalProperties: true
    },
    {
      type: "object",
      required: ["type", "from", "to"],
      properties: {
        type: { const: "drag" },
        from: pointSchema,
        to: pointSchema,
        button: { type: "string" },
        via: { type: "string" },
        profile: objectSchema
      },
      additionalProperties: true
    },
    {
      type: "object",
      required: ["type", "at"],
      properties: {
        type: { const: "scroll" },
        at: pointSchema,
        dx: { type: "number" },
        dy: { type: "number" },
        style: { type: "string" }
      },
      additionalProperties: true
    },
    {
      type: "object",
      required: ["type", "text"],
      properties: {
        type: { const: "type" },
        text: { type: "string" },
        layout: { type: "string" },
        profile: objectSchema
      },
      additionalProperties: true
    },
    {
      type: "object",
      required: ["type"],
      anyOf: [
        { required: ["keyCode"] },
        { required: ["virtualKey"] }
      ],
      properties: {
        type: { const: "key" },
        keyCode: { type: "integer" },
        virtualKey: { type: "integer" },
        holdMs: { type: "integer" },
        profile: objectSchema
      },
      additionalProperties: true
    }
  ]
};

export const toolMethodMap = {
  hid_action: "action",
  hid_state: "state",
  hid_stop: "stop",
  hid_unlock: "unlock",
  hid_observe: "observe",
  hid_profiles_list: "profiles.list",
  hid_profiles_get: "profiles.get",
  hid_profiles_forget: "profiles.forget",
  hid_trace_tail: "trace.tail",
  hid_trace_commit: "trace.commit"
};

export const tools = [
  {
    name: "hid_action",
    description: `${agentNotice} 执行一组 HID 动作原语。调用时必须提供非空 primitives；不要只传 target/context。网页点击应先由上游 browser snapshot/clickPoint 或等价观察证据给出 viewport/document 坐标，再构造 click/move/type 等 primitives；VirtualHID 会用 macOS/AX/CG 证据解析 Chrome 内容 viewport 并换算到真实 HID screen 坐标。调用方不要传或合成可信 macOS screen origin；geometry.viewportInScreen 若出现只作为诊断/兼容输入，网页 viewport/document 映射会以 VirtualHID 解析出的 viewport 为准。网页目标场景中，context.host 是学习、trace 与执行归因键，必须与 browser_target.host 或 target.host 指向同一浏览器目标；非网页桌面目标可使用其它稳定 target/context 归因字段。`,
    inputSchema: {
      type: "object",
      required: ["id", "primitives", "context"],
      properties: {
        id: { type: "string" },
        target: {
          type: "object",
          properties: {
            bundleId: { type: "string" },
            windowId: { type: "integer" },
            windowTitle: { type: "string" },
            tabId: { type: "integer" },
            host: { type: "string" }
          },
          additionalProperties: false
        },
        geometry: {
          type: "object",
          description: "Viewport/document actions may provide coordSpace plus page evidence such as scrollOffset/pageScale/viewportSize. Do not synthesize or trust viewportInScreen from browser screenX/screenY; VirtualHID resolves the Chrome content viewport frame through macOS AX/CG before planning.",
          properties: {
            coordSpace: { type: "string", enum: ["screen", "viewport", "document"] },
            viewportInScreen: {
              ...objectSchema,
              description: "Compatibility/diagnostic field only for web viewport/document actions. VirtualHID-owned AX/CG viewport resolution overrides this value."
            },
            pageScale: { type: "number" },
            scrollOffset: objectSchema,
            viewportSize: objectSchema
          },
          additionalProperties: false
        },
        primitives: {
          type: "array",
          minItems: 1,
          description: "Required non-empty HID primitive list, for example a click primitive with an at/to point derived from browser clickPoint or another observed target region.",
          items: primitiveSchema,
        },
        context: {
          ...objectSchema,
          description: "Required attribution context. For web targets include host derived from browser active tab, tab list, or snapshot URL.",
        },
        options: {
          type: "object",
          properties: {
            postMode: { type: "string", enum: ["global", "pid", "auto"] },
            timeoutMs: { type: "integer" },
            dryRun: { type: "boolean" },
            contextVersion: { type: "integer" }
          },
          additionalProperties: true
        }
      },
      additionalProperties: false
    }
  },
  {
    name: "hid_state",
    description: `${agentNotice} 返回 VirtualHID 当前状态。`,
    inputSchema: { type: "object", properties: {}, additionalProperties: false }
  },
  {
    name: "hid_stop",
    description: `${agentNotice} 停止当前动作，不触发紧急停止锁。`,
    inputSchema: { type: "object", properties: {}, additionalProperties: false }
  },
  {
    name: "hid_unlock",
    description: `${agentNotice} 解除紧急停止锁。`,
    inputSchema: { type: "object", properties: {}, additionalProperties: false }
  },
  {
    name: "hid_observe",
    description: `${agentNotice} 开关被动观察；开启时必须给出 host。`,
    inputSchema: {
      type: "object",
      required: ["enable"],
      properties: {
        enable: { type: "boolean" },
        host: { type: "string" },
        taskId: { type: "string" }
      },
      additionalProperties: false
    }
  },
  {
    name: "hid_profiles_list",
    description: `${agentNotice} 列出已学习模板。`,
    inputSchema: {
      type: "object",
      properties: { host: { type: "string" } },
      additionalProperties: false
    }
  },
  {
    name: "hid_profiles_get",
    description: `${agentNotice} 获取指定 host 与 sig 的模板。`,
    inputSchema: {
      type: "object",
      required: ["host", "sig"],
      properties: {
        host: { type: "string" },
        sig: { type: "string" }
      },
      additionalProperties: false
    }
  },
  {
    name: "hid_profiles_forget",
    description: `${agentNotice} 删除学习数据，可按 host 或 sig 限定。`,
    inputSchema: {
      type: "object",
      properties: {
        host: { type: "string" },
        sig: { type: "string" }
      },
      additionalProperties: false
    }
  },
  {
    name: "hid_trace_tail",
    description: `${agentNotice} 读取最近的真实用户事件缓冲。`,
    inputSchema: {
      type: "object",
      properties: {
        n: { type: "integer" },
        sinceEventId: { type: "string" },
        onlyUnresolved: { type: "boolean" }
      },
      additionalProperties: false
    }
  },
  {
    name: "hid_trace_commit",
    description: `${agentNotice} 回写一条已关联的观察事件。`,
    inputSchema: {
      type: "object",
      required: ["eventId", "elementSig", "host"],
      properties: {
        eventId: { type: "string" },
        elementSig: { type: "string" },
        role: { type: "string" },
        text: { type: "string" },
        host: { type: "string" },
        taskId: { type: "string" },
        stage: { type: "string" }
      },
      additionalProperties: true
    }
  }
];
