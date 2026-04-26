export function daemonUnavailable(message) {
  return {
    code: "E_DAEMON_UNREACHABLE",
    message: message || "VirtualHID runtime is not reachable"
  };
}

export function errorText(error) {
  const code = error?.code || "E_UNKNOWN";
  const message = error?.message || "unknown error";
  return `${code}: ${message}`;
}

export function mcpError(error) {
  return {
    isError: true,
    content: [{ type: "text", text: errorText(error) }]
  };
}
