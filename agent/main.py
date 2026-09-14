"""AgentCore Runtime 에이전트 — 웜풀 데모용.

두 가지를 증명하기 위한 최소 구현이다.

1. ``warmup`` 센티널을 조기 반환해 예열 핑이 LLM·툴 실행을 타지 않게 한다.
   이 조기 반환이 없으면 예열 비용이 실제 대화 비용과 같아진다.
2. ``uptime_ms`` 로 "이 microVM 이 방금 떴는지"를 호출자에게 알려준다.
   콜드/웜 판별의 근거가 되는 값이다.

의존성 없이 표준 라이브러리만 쓴다. AgentCore 직접 코드 배포에는 boto3 가
포함되지 않으며, 초기화 30초 제한이 있어 무거운 import 를 피해야 한다.
"""
import json
import os
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# ── 모듈 스코프 ──────────────────────────────────────────────────────────
# 여기의 코드는 microVM 부팅 직후, 첫 요청이 도착하기 전에 실행된다.
# 무거운 import(LangGraph 등)를 여기 두어야 warmup 핑이 실제로 데워준다.
# 핸들러 안으로 옮기면(lazy import) warmup 은 통과하지만 첫 질문에서
# 초기화가 터져 예열 효과가 사라진다.
BOOT_MONO = time.monotonic()
BOOT_WALL = time.time()
MODE = os.environ.get("DEPLOY_MODE", "code")

_served = 0          # 이 microVM 이 처리한 요청 수. 1 이면 첫 요청.
_ctx_cache = {}      # memorySessionId -> 복원한 대화 이력 (microVM 로컬)


def _now_ms(t0):
    return round((time.time() - t0) * 1000, 1)


def handle(payload):
    """실제 대화 처리. 여기서는 LLM 대신 결정적 응답을 만든다.

    데모의 목적은 콜드스타트 측정이므로 LLM 호출을 넣지 않는다. 호출을 넣으면
    LLM 지연이 섞여 플랫폼 오버헤드를 분리할 수 없다(원문 측정 원칙 1번).
    """
    global _served
    _served += 1

    msid = payload.get("memorySessionId") or "unknown"
    user = payload.get("userId") or "anonymous"
    prompt = payload.get("prompt") or ""

    # runtimeSessionId 와 무관한 memorySessionId 로 이력을 관리한다.
    # microVM 이 죽으면 _ctx_cache 가 사라지므로 restored=True 가 되고,
    # 실제 구현에서는 이 지점에서 AgentCore Memory 의 ListEvents 를 호출한다.
    restored = msid not in _ctx_cache
    if restored:
        _ctx_cache[msid] = []
    _ctx_cache[msid].append(prompt)

    return {
        "answer": f"[{MODE}] '{prompt[:60]}' 에 대한 응답입니다. "
                  f"이 대화의 {len(_ctx_cache[msid])}번째 메시지입니다.",
        "userId": user,
        "memorySessionId": msid,
        "turn": len(_ctx_cache[msid]),
        # True 면 이 microVM 에 이력이 없어 복원이 필요했다는 뜻.
        # 세션이 교체되었음을 호출자가 확인하는 근거가 된다.
        "contextRestored": restored,
    }


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _send(self, obj, code=200):
        body = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _meta(self):
        """호출자가 콜드/웜을 판별할 수 있게 microVM 상태를 실어 보낸다."""
        return {
            "mode": MODE,
            # microVM 부팅 후 이 요청까지의 경과 시간.
            #   수백 ms  → 요청이 와서 그 자리에서 부팅함 (콜드)
            #   수 초    → 이미 떠서 기다리고 있었음 (예열 히트)
            "uptimeMs": round((time.monotonic() - BOOT_MONO) * 1000, 1),
            "bootWall": BOOT_WALL,
            "servedByThisVm": _served,   # 1 이면 이 microVM 의 첫 요청
        }

    def do_GET(self):
        if self.path.rstrip("/") == "/ping":
            self._send({"status": "Healthy"})
        else:
            self._send({"error": "not found"}, 404)

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        try:
            payload = json.loads(self.rfile.read(n) or b"{}")
        except json.JSONDecodeError:
            self._send({"error": "invalid json"}, 400)
            return

        # ── warmup 센티널 ────────────────────────────────────────────────
        # 예열 핑은 여기서 끝난다. LLM 호출·툴 실행·과금 compute 를 건너뛴다.
        # 모듈 스코프 초기화는 이미 끝난 상태이므로 예열 효과는 유지된다.
        if payload.get("type") == "warmup":
            self._send({"status": "warm", **self._meta()})
            return

        try:
            self._send({**handle(payload), **self._meta()})
        except Exception as e:                                  # noqa: BLE001
            import traceback
            self._send({"error": f"{type(e).__name__}: {e}",
                        "trace": traceback.format_exc()[-800:],
                        **self._meta()}, 500)

    def log_message(self, *args):
        pass          # AgentCore 가 stdout 을 수집하므로 액세스 로그는 끈다


if __name__ == "__main__":
    port = int(os.environ.get("PORT", "8080"))
    ThreadingHTTPServer(("0.0.0.0", port), Handler).serve_forever()
