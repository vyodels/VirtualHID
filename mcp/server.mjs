#!/usr/bin/env node
import crypto from "node:crypto";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { daemonUnavailable, mcpError } from "./errors.mjs";
import { toolMethodMap, tools } from "./tools.mjs";

const socketPath = process.env.VIRTUALHID_SOCKET || path.join(os.tmpdir(), "virtualhid.sock");
const daemonTimeoutMs = Number(process.env.VIRTUALHID_MCP_DAEMON_TIMEOUT_MS || 15000);

if (process.argv.includes("--smoke-tools")) {
  process.stdout.write(`${JSON.stringify({ tools: tools.map((tool) => tool.name) })}\n`);
  process.exit(0);
}

async function callDaemon(method, params) {
  const id = crypto.randomUUID();
  const payload = `${JSON.stringify({ id, method, params: params || {} })}\n`;

  return await new Promise((resolve, reject) => {
    const socket = net.createConnection(socketPath);
    let buffer = "";
    const timeout = setTimeout(() => {
      socket.destroy();
      reject(daemonUnavailable(`timeout waiting for daemon response from ${socketPath} after ${daemonTimeoutMs}ms`));
    }, daemonTimeoutMs);

    socket.on("connect", () => {
      socket.write(payload);
    });
    socket.on("data", (chunk) => {
      buffer += chunk.toString("utf8");
      const newline = buffer.indexOf("\n");
      if (newline === -1) {
        return;
      }
      clearTimeout(timeout);
      const line = buffer.slice(0, newline);
      socket.end();
      try {
        resolve(JSON.parse(line));
      } catch (error) {
        reject({ code: "E_UNKNOWN", message: `invalid daemon response: ${error.message}` });
      }
    });
    socket.on("error", (error) => {
      clearTimeout(timeout);
      reject(daemonUnavailable(error.message));
    });
    socket.on("close", () => {
      clearTimeout(timeout);
    });
  });
}

async function handleToolCall(name, args) {
  const method = toolMethodMap[name];
  if (!method) {
    return mcpError({ code: "E_UNKNOWN", message: `unknown tool ${name}` });
  }

  try {
    const response = await callDaemon(method, args || {});
    if (!response.ok) {
      return mcpError(response.error);
    }
    return {
      content: [{ type: "text", text: JSON.stringify(response.result || {}, null, 2) }]
    };
  } catch (error) {
    return mcpError(error);
  }
}

async function runWithSdk() {
  const [{ Server }, { StdioServerTransport }, types] = await Promise.all([
    import("@modelcontextprotocol/sdk/server/index.js"),
    import("@modelcontextprotocol/sdk/server/stdio.js"),
    import("@modelcontextprotocol/sdk/types.js")
  ]);
  const { CallToolRequestSchema, ListToolsRequestSchema } = types;
  const server = new Server(
    { name: "virtualhid", version: "0.2.0" },
    { capabilities: { tools: {} } }
  );

  server.setRequestHandler(ListToolsRequestSchema, async () => ({ tools }));
  server.setRequestHandler(CallToolRequestSchema, async (request) => {
    const { name, arguments: args } = request.params;
    return await handleToolCall(name, args);
  });

  await server.connect(new StdioServerTransport());
}

async function runFallbackJsonRpc() {
  process.stdin.setEncoding("utf8");
  let buffer = "";

  process.stdin.on("data", async (chunk) => {
    buffer += chunk;
    while (buffer.includes("\n")) {
      const index = buffer.indexOf("\n");
      const line = buffer.slice(0, index).trim();
      buffer = buffer.slice(index + 1);
      if (!line) {
        continue;
      }

      let request;
      try {
        request = JSON.parse(line);
      } catch (error) {
        writeRpc(null, { code: -32700, message: error.message });
        continue;
      }

      if (request.method === "tools/list") {
        writeRpc(request.id, null, { tools });
      } else if (request.method === "tools/call") {
        const result = await handleToolCall(request.params?.name, request.params?.arguments || {});
        writeRpc(request.id, null, result);
      } else {
        writeRpc(request.id, { code: -32601, message: `unknown method ${request.method}` });
      }
    }
  });
}

function writeRpc(id, error, result) {
  const response = { jsonrpc: "2.0", id };
  if (error) {
    response.error = error;
  } else {
    response.result = result;
  }
  process.stdout.write(`${JSON.stringify(response)}\n`);
}

if (process.env.VIRTUALHID_MCP_FORCE_FALLBACK === "1") {
  runFallbackJsonRpc();
} else {
  runWithSdk().catch((error) => {
    if (error?.code !== "ERR_MODULE_NOT_FOUND") {
      process.stderr.write(`virtualhid MCP SDK unavailable, using fallback: ${error.message}\n`);
    }
    runFallbackJsonRpc();
  });
}
