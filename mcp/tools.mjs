const agentNotice = "本工具由 Agent 调度使用，执行前请先通过 browser-mcp 完成窗口、目标与安全前置条件。";

const objectSchema = {
  type: "object",
  additionalProperties: true
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
    description: `${agentNotice} 执行一组 HID 动作原语。`,
    inputSchema: {
      type: "object",
      required: ["id", "primitives", "context"],
      properties: {
        id: { type: "string" },
        primitives: { type: "array", items: objectSchema },
        context: objectSchema,
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
