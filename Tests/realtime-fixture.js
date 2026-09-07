
const stats = new Map();
const server = Bun.serve({
  hostname: "127.0.0.1", port: 0,
  fetch(req, server) {
    const url = new URL(req.url);
    if (url.pathname === "/stats") return Response.json(Object.fromEntries(stats));
    const scenario = req.headers.get("xi-api-key") || "unknown";
    if (scenario.startsWith("http")) return new Response("synthetic private server detail", { status: Number(scenario.slice(4)) });
    const record = { bytes: 0, segmentBytes: 0, commits: [], closed: false, violations: [], keyterms: url.searchParams.getAll("keyterms") };
    stats.set(scenario, record);
    if (server.upgrade(req, { data: { scenario, record, pendingAck: false, ready: false } })) return;
    return new Response("Expected WebSocket", { status: 400 });
  },
  websocket: {
    open(ws) {
      const delay = ws.data.scenario === "cancelConnecting" ? 500 : 50;
      if (ws.data.scenario === "connectTimeout") return;
      setTimeout(() => {
        if (ws.readyState !== 1) return;
        const keyterms = ws.data.record.keyterms;
        if (keyterms.length > 50 || keyterms.some(term => Array.from(term).length > 20)) {
          ws.close(1008, "synthetic private query rejection");
          return;
        }
        if (ws.data.scenario === "errorClose") {
          ws.send(JSON.stringify({ message_type: "unaccepted_terms", error: "synthetic secret detail" }));
          ws.close(1008, "synthetic private close reason");
          return;
        }
        if (ws.data.scenario === "policyClose") {
          ws.close(1008, "synthetic private close reason");
          return;
        }
        ws.data.ready = true;
        ws.send(JSON.stringify({ message_type: "session_started", session_id: "synthetic", config: {} }));
        if (ws.data.scenario === "quota") ws.send(JSON.stringify({ message_type: "quota_exceeded", error: "synthetic secret detail" }));
        if (ws.data.scenario === "disconnect") ws.close(1011, "synthetic private close reason");
      }, delay);
    },
    message(ws, raw) {
      const m = JSON.parse(String(raw)), d = ws.data, r = d.record;
      if (!d.ready || d.pendingAck) r.violations.push("audio outside ready/ack boundary");
      if (m.message_type !== "input_audio_chunk" || m.sample_rate !== 16000 || typeof m.commit !== "boolean" || "previous_text" in m) r.violations.push("invalid protocol fields");
      const bytes = Buffer.from(m.audio_base_64, "base64");
      if (bytes.length > 32000 || bytes.length % 2) r.violations.push("invalid packet size");
      r.bytes += bytes.length; r.segmentBytes += bytes.length;
      if (m.commit) {
        r.commits.push(r.segmentBytes); r.segmentBytes = 0; d.pendingAck = true;
        if (d.scenario === "noAck" || d.scenario === "cancelAck") return;
        setTimeout(() => {
          if (ws.readyState !== 1) return;
          d.pendingAck = false;
          const text = d.scenario === "emptyText" ? "" : d.scenario === "long" ? (r.commits.length < 3 ? "Repeat." : "Tail.") : "Synthetic result.";
          if (d.scenario === "partial") {
            ws.send(JSON.stringify({ message_type: "partial_transcript", text: "Initial hypothesis." }));
            ws.send(JSON.stringify({ message_type: "partial_transcript", text: "Revised hypothesis." }));
            ws.send(JSON.stringify({ message_type: "partial_transcript", text: "" }));
          }
          ws.send(JSON.stringify({ message_type: "committed_transcript", text }));
          ws.send(JSON.stringify({ message_type: "committed_transcript_with_timestamps", text, language_code: "en", words: [] }));
          if (d.scenario === "finalClose") ws.close(1000);
        }, 80);
      }
    },
    close(ws) { ws.data.record.closed = true; }
  }
});
console.log(`Fixture ready ${server.port}`);
