"""Exercise the real WebSocket client with synthetic PCM on loopback only.

Requires Xcode and Bun. No microphone, Keychain access, provider request or
credentials. The fixture uses an ephemeral port and is always terminated.
"""
from pathlib import Path
import json
import os
import selectors
import shutil
import subprocess
import urllib.request

root = Path(__file__).resolve().parent.parent
build = root / ".build" / "verification"
build.mkdir(parents=True, exist_ok=True)
environment = dict(os.environ)
environment.setdefault("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")
bun = shutil.which("bun")
if not bun:
    raise SystemExit("Install Bun to run the loopback WebSocket fixture.")

subprocess.run([
    "xcrun", "swiftc", "-swift-version", "6", "-warnings-as-errors", "-parse-as-library",
    "-module-cache-path", str(build / "ModuleCache.noindex"),
    str(root / "Dictation" / "RealtimeClient.swift"),
    str(root / "Tests" / "RealtimeSmoke.swift"), "-o", str(build / "realtime-smoke")
], env=environment, check=True)

server = subprocess.Popen([bun, str(root / "Tests" / "realtime-fixture.js")],
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
try:
    with selectors.DefaultSelector() as selector:
        selector.register(server.stdout, selectors.EVENT_READ)
        if not selector.select(timeout=10):
            raise RuntimeError("Loopback fixture did not start")
        banner = server.stdout.readline().strip()
    if not banner.startswith("Fixture ready "):
        raise RuntimeError("Loopback fixture failed to start")
    port = int(banner.removeprefix("Fixture ready "))
    endpoint = f"ws://127.0.0.1:{port}/realtime"
    cases = ["idle", "short", "partial", "long", "exactCommit", "emptyText", "zero", "overflow", "invalidHints",
             "cancelConnecting", "cancelAck", "quota", "http401", "http403", "http429",
             "disconnect", "noAck", "connectTimeout", "errorClose", "policyClose", "finalClose", "vocabulary"]
    for case in cases:
        subprocess.run([str(build / "realtime-smoke"), case, endpoint], check=True, timeout=25)
    with urllib.request.urlopen(f"http://127.0.0.1:{port}/stats", timeout=5) as response:
        stats = json.load(response)
    for scenario, record in stats.items():
        if record["violations"] or not record["closed"]:
            raise AssertionError(f"{scenario}: packet order/closure contract failed")
    if stats["short"]["commits"] != [64_000]:
        raise AssertionError("Short speech did not reach the 2-second processing minimum")
    if stats["partial"]["commits"] != [64_000]:
        raise AssertionError("Partial transcript events changed short-speech commit accounting")
    if stats["long"]["commits"] != [768_000, 768_000, 64_000]:
        raise AssertionError("Long speech was truncated or committed out of order")
    if stats["exactCommit"]["commits"] != [768_000]:
        raise AssertionError("Exact commit boundary was finalized early or committed twice")
    if stats["cancelConnecting"]["bytes"] != 0:
        raise AssertionError("Audio escaped after cancellation during connection startup")
    if stats["vocabulary"]["keyterms"] != ["Kinekt", "Oh My Pi", "één & twee + drie"]:
        raise AssertionError("Vocabulary hints were not preserved as separate query parameters")
    print("PASS observed wire order, short padding, long segment boundaries and transport closure")
finally:
    server.terminate()
    try:
        server.communicate(timeout=5)
    except subprocess.TimeoutExpired:
        server.kill()
        server.communicate()
