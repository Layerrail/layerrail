// Reasoning is represented by an orb, not included in the visible answer or
// sent back as conversation history. Only a leading <think> section is special;
// literal tags in an answer (for example a code example) remain untouched.
export function visibleAnswer(content) {
  let text = String(content || "");
  while (true) {
    const leading = text.trimStart();
    if (leading && "<think>".startsWith(leading)) return { text: "", thinking: true };
    if (!leading.startsWith("<think>")) return { text, thinking: false };
    const end = leading.indexOf("</think>");
    if (end === -1) return { text: "", thinking: true };
    text = leading.slice(end + "</think>".length).trimStart();
  }
}

// Consume real SSE frames, including split UTF-8 characters, multi-line data,
// CRLF and a final frame without a trailing newline. Release the reader on Stop.
export async function* readEventStream(body) {
  if (!body) throw new Error("The endpoint returned an empty response stream.");
  const reader = body.getReader();
  const decoder = new TextDecoder();
  let buffer = "";
  let data = [];
  function parse(line) {
    if (line.startsWith("data:")) data.push(line.slice(5).trimStart());
    if (line !== "" || !data.length) return undefined;
    const payload = data.join("\n");
    data = [];
    if (payload.trim() === "[DONE]") return null;
    try { return JSON.parse(payload); }
    catch { throw new Error("The endpoint returned an invalid response stream. Please try again."); }
  }
  try {
    while (true) {
      const { done, value } = await reader.read();
      buffer += done ? decoder.decode() : decoder.decode(value, { stream: true });
      const lines = buffer.split("\n");
      buffer = lines.pop();
      if (done) lines.push(buffer, "");
      for (const line of lines) {
        const frame = parse(line.replace(/\r$/, ""));
        if (frame === null) return;
        if (frame !== undefined) yield frame;
      }
      if (done) break;
    }
  } finally {
    await reader.cancel().catch(() => {});
    reader.releaseLock();
  }
}
