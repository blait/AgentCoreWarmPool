"""AgentCore Runtime 웜풀 데모 — Lambda proxy (API Gateway HTTP API payload v2.0).

이 프록시가 하는 일은 하나다. **어떤 runtimeSessionId 로 런타임을 호출할지 고르는 것.**
그 선택이 콜드스타트(실측 p50 1,328ms)와 웜스타트(실측 p50 101ms)를 가른다.

세션 ID 두 종류를 반드시 분리한다. 이 분리가 웜풀의 전제다.

  runtimeSessionId : microVM 을 식별. 33자 이상. 풀에서 꺼내 쓰므로 매번 바뀔 수 있다.
  memorySessionId  : "chat-{userId}". 대화 이력을 식별. 유저에 고정.

이력이 microVM 에 묶여 있으면 미리 만들어둔 uuid 는 "남의 대화"가 되어 풀에서 꺼내
쓸 수 없다. 이력을 memorySessionId 로 떼어내야 microVM 을 자유롭게 교체할 수 있다.

환경변수는 모듈 로드 시 읽는다. 미설정이면 여기서 즉시 죽는다 — 핸들러에서 뒤늦게
터지면 "왜 fresh 만 나오지"를 디버깅하게 되므로, 배포 직후 실패하는 편이 낫다.
"""
import json
import logging
import os
import time
import uuid

import boto3
from botocore.config import Config

# 예외 상세는 응답이 아니라 CloudWatch 로만 보낸다(계정 ID 유출 방지).
logger = logging.getLogger()
logger.setLevel(logging.INFO)

# ── 환경변수 ────────────────────────────────────────────────────────────────
# os.environ[...] 로 읽어 미설정 시 KeyError 로 즉시 실패시킨다.
# 계정 ID·ARN·큐 URL·테이블명은 공개 레포에 하드코딩하지 않는다.
RUNTIME_ARN = os.environ["RUNTIME_ARN"]
TABLE_NAME = os.environ["TABLE_NAME"]
QUEUE_URL = os.environ["QUEUE_URL"]
# 리전은 RUNTIME_REGION 을 우선하고, 없으면 Lambda 가 자동 주입하는 AWS_REGION 을 쓴다.
# AWS_REGION 은 예약 환경변수라 --environment 로 직접 설정할 수 없다(InvalidParameterValue).
# 그래서 "런타임이 넣어주는 값"을 기본으로 두고, 다른 리전의 런타임을 호출해야 할 때만
# RUNTIME_REGION 으로 덮어쓴다. 둘 다 없으면 여기서 KeyError 로 즉시 죽는다.
RUNTIME_REGION = os.environ.get("RUNTIME_REGION") or os.environ["AWS_REGION"]
POOL_TARGET = int(os.environ["POOL_TARGET"])

# ── 상수 ────────────────────────────────────────────────────────────────────
# 세션 유효로 보는 시간. AgentCore idle 타임아웃(데모에서 13분 가정)보다 짧게 잡아
# "만료 직전 세션을 재사용해 콜드스타트를 맞는" 경계 사고를 피한다.
# 참고: idle 최소 설정값은 60초이고 idle=0 은 API 가 거부한다("valid min value: 60").
SESSION_TTL_SEC = 780

# microVM maxLifetime 상한은 8시간이고 초과할 수 없다. 8시간에 닿으면 대화 중에
# 죽으므로 7시간에서 미리 폐기한다(rolling replacement). 남는 1시간은 안전 여유.
MAX_VM_AGE_SEC = 7 * 3600

# 콜드/웜 판정 경계. 실측에서 두 분포가 약 390ms 대 약 3,900ms 로 명확히 갈렸으므로
# 이 경계값 선택에 결과가 민감하지 않다.
#   uptimeMs > 1500  → 이미 떠서 기다리던 microVM 에 안착 (웜)
#   uptimeMs <= 1500 → 요청이 와서 그 자리에서 부팅 (콜드)
COLD_UPTIME_MS = 1500

METRICS_MAX = 50            # /api/metrics 보관 건수
REFILL_MAX_PER_CALL = 20    # 1회 refill 상한 (아래 주석 참조)

# ── boto3 클라이언트 (모듈 스코프에서 1회 생성) ─────────────────────────────
# 핸들러 안에서 만들면 매 호출마다 클라이언트 생성 비용이 지연에 섞여 들어간다.
# 이 데모는 101ms 대 1,328ms 를 보여주는 것이 목적이므로, 측정 대상이 아닌 비용은
# 콜드스타트된 Lambda 컨테이너의 초기화 구간으로 밀어낸다.
_CFG = Config(
    retries={"max_attempts": 3, "mode": "standard"},
    connect_timeout=5,
    read_timeout=60,
)
agentcore = boto3.client("bedrock-agentcore", region_name=RUNTIME_REGION, config=_CFG)
ddb = boto3.client("dynamodb", config=_CFG)
sqs = boto3.client("sqs", config=_CFG)

# ── /api/metrics 저장소 ─────────────────────────────────────────────────────
# ⚠️ 한계: Lambda 컨테이너 전역 변수다. 컨테이너가 재사용될 때만 값이 남고,
# 스케일아웃되면 컨테이너별로 다른 목록이 보이며, 컨테이너가 회수되면 사라진다.
# 즉 이 목록은 데모 화면용이고 신뢰할 수 있는 지표 저장소가 아니다.
# 실제로 지표를 남길 것이면 CloudWatch EMF 또는 DynamoDB 를 써야 한다.
_METRICS: list[dict] = []


def _record(mode, latency_ms, source, cold_start):
    _METRICS.append({
        "ts": round(time.time() * 1000),
        "mode": mode,
        "latencyMs": latency_ms,
        "source": source,
        "coldStart": cold_start,
    })
    # 앞에서 잘라 최근 METRICS_MAX 건만 남긴다.
    del _METRICS[:-METRICS_MAX]


# ── HTTP 응답 ───────────────────────────────────────────────────────────────
# CloudFront 와 API Gateway 가 다른 오리진이므로 CORS 헤더를 항상 실어 보낸다.
# 에러 응답에도 붙여야 한다 — 안 붙이면 브라우저가 CORS 오류로 가려버려서
# 실제 원인(예: DynamoDB 권한 부족)이 콘솔에 보이지 않는다.
_CORS = {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "content-type",
    "Access-Control-Allow-Methods": "GET,POST,OPTIONS",
    "Content-Type": "application/json; charset=utf-8",
}


def _resp(body, code=200):
    return {
        "statusCode": code,
        "headers": _CORS,
        "body": json.dumps(body, ensure_ascii=False),
    }


# ── 세션 ID 생성 ────────────────────────────────────────────────────────────
def _new_session_id():
    """runtimeSessionId 를 만든다. **33자 이상이어야 한다.**

    uuid4().hex 는 32자라서 그대로 쓰면 ValidationException 이 난다.
    1자 차이라 로컬에서는 눈치채기 어렵고 배포 후에야 드러나므로 접두어로 패딩한다.
    "wp-" + 32 = 35자.
    """
    sid = f"wp-{uuid.uuid4().hex}"
    if len(sid) < 33:                      # 방어: 위 계산이 깨지면 여기서 잡는다
        raise RuntimeError(f"runtimeSessionId too short: {len(sid)}")
    return sid


def _memory_session_id(user_id):
    """대화 이력 키. runtimeSessionId 와 **독립**이어야 한다."""
    return f"chat-{user_id}"


# ── AgentCore 호출 ──────────────────────────────────────────────────────────
def _invoke(session_id, payload):
    """런타임을 호출하고 (응답 dict, 지연 ms) 를 돌려준다.

    지연은 invoke 구간만 잰다. DynamoDB 조회·SQS pop 을 포함하면 플랫폼
    오버헤드와 프록시 오버헤드가 섞여 콜드/웜 차이를 분리할 수 없다.
    """
    t0 = time.perf_counter()
    r = agentcore.invoke_agent_runtime(
        agentRuntimeArn=RUNTIME_ARN,
        runtimeSessionId=session_id,
        contentType="application/json",
        accept="application/json",
        payload=json.dumps(payload, ensure_ascii=False).encode(),
    )
    latency_ms = round((time.perf_counter() - t0) * 1000, 1)

    # response 는 StreamingBody. 에이전트가 application/json 을 돌려주므로 read()
    # 한 번으로 끝나지만, text/event-stream 으로 바뀌어도 죽지 않게 둘 다 받는다.
    stream = r.get("response")
    if stream is None:
        raw = b""
    elif hasattr(stream, "read"):
        raw = stream.read()
    else:
        raw = b"".join(chunk for chunk in stream)

    body = json.loads(raw or b"{}")
    return body, latency_ms


def _warm_ping(session_id):
    """예열 핑. 에이전트가 {"type":"warmup"} 을 조기 반환하므로 LLM·툴을 타지 않는다.

    이 조기 반환이 없으면 예열 비용이 실제 대화 비용과 같아진다.
    성공하면 True. 실패는 삼키고 False — 호출자가 "큐에 넣지 않는다"로 처리한다.
    """
    try:
        _invoke(session_id, {"type": "warmup"})
        return True
    except Exception:                                            # noqa: BLE001
        return False


# ── SQS 풀 연산 ─────────────────────────────────────────────────────────────
# 큐에 담기는 것은 "예열된 uuid 재고"다. 메시지 본문 스키마:
#   {"sessionId": str, "createdAt": epoch초, "lastPingAt": epoch초}
#
# createdAt  : microVM 이 태어난 시각. 8시간 maxLifetime 계산용. **절대 갱신 금지.**
#              갱신하면 8시간 상한을 넘긴 세션이 영원히 풀에 남는다.
# lastPingAt : 마지막 예열 핑 시각. idle 만료 위험(staleRisk) 계산용. heartbeat 마다 갱신.
#
# 두 시각을 하나로 합치면 안 된다. "태어난 지 오래됐지만 방금 핑한 세션"과
# "방금 태어났지만 핑이 끊긴 세션"은 처분이 정반대다.

def _send_to_pool(session_id, created_at, last_ping_at):
    """재고를 큐에 넣는다.

    ⚠️ MessageDeduplicationId 를 매번 새로 준다. FIFO 큐는 5분 중복 제거 창을
    가지므로, 같은 내용을 5분 안에 다시 넣으면 **성공 응답을 받지만 전달되지 않는다**
    (accepted successfully but aren't delivered). heartbeat 는 같은 uuid 를 반복해서
    환원하므로, 이걸 놓치면 재고가 조용히 사라지고 원인이 로그에 남지 않는다.

    ⚠️ MessageGroupId 를 uuid 별로 준다. FIFO 는 한 그룹의 메시지가 처리 중(invisible)
    이면 같은 그룹의 다른 메시지를 내주지 않는다. 전체를 한 그룹에 넣으면 heartbeat 가
    메시지를 잡고 있는 동안 pop 이 빈손이 되어 전 유저가 콜드스타트를 맞는다.
    재고는 순서에 의미가 없으므로 그룹을 쪼개도 잃는 것이 없다.
    """
    sqs.send_message(
        QueueUrl=QUEUE_URL,
        MessageBody=json.dumps({
            "sessionId": session_id,
            "createdAt": created_at,
            "lastPingAt": last_ping_at,
        }),
        MessageGroupId=session_id,
        MessageDeduplicationId=uuid.uuid4().hex,
        MessageAttributes={
            "createdAt": {"DataType": "Number", "StringValue": str(int(created_at))},
        },
    )


def _parse_item(msg):
    """큐 메시지에서 (sessionId, createdAt, lastPingAt) 를 뽑는다."""
    body = json.loads(msg.get("Body") or "{}")
    session_id = body.get("sessionId")
    now = time.time()

    # createdAt 은 메시지 속성을 우선한다. 속성은 receive 때
    # MessageAttributeNames 를 주지 않으면 비어 오므로 본문을 폴백으로 둔다.
    created_at = None
    attr = (msg.get("MessageAttributes") or {}).get("createdAt")
    if attr and attr.get("StringValue"):
        try:
            created_at = float(attr["StringValue"])
        except ValueError:
            created_at = None
    if created_at is None:
        created_at = float(body.get("createdAt") or now)

    last_ping_at = float(body.get("lastPingAt") or created_at)
    return session_id, created_at, last_ping_at


def _pool_depth():
    """재고 수. ApproximateNumberOfMessages 는 이름대로 근사값이다 — 정확한
    재고를 세려면 큐를 비워야 하므로, 화면 표시용으로만 쓴다."""
    try:
        a = sqs.get_queue_attributes(
            QueueUrl=QUEUE_URL,
            AttributeNames=["ApproximateNumberOfMessages"],
        )["Attributes"]
        return int(a.get("ApproximateNumberOfMessages", 0))
    except Exception:                                            # noqa: BLE001
        # 깊이를 못 읽는 것은 대화를 막을 이유가 아니다. -1 로 "모름"을 표시한다.
        return -1


def _pop_from_pool():
    """재고에서 uuid 하나를 꺼낸다. 없으면 None.

    ⚠️ receive 직후 **즉시 delete** 한다. 재고는 1회용이다. 지우지 않으면 가시성
    타임아웃이 끝난 뒤 같은 uuid 가 다시 나와 두 유저가 같은 microVM 을 공유하고,
    한 유저의 대화가 다른 유저에게 보인다.

    WaitTimeSeconds=0(short poll) 을 쓴다. 이 경로는 유저가 기다리는 대화 경로이고
    웜스타트가 101ms 이므로, 롱폴링 1초를 넣으면 측정하려는 지연을 프록시가
    덮어써 버린다. 대가로 재고가 있어도 빈손이 나올 수 있음을 감수한다
    (그 경우 fresh 로 떨어져 콜드스타트가 되지만, 데모는 이것도 보여줘야 한다).
    """
    for _ in range(3):          # 수명 초과분을 버리고 다시 뽑는 재시도
        r = sqs.receive_message(
            QueueUrl=QUEUE_URL,
            MaxNumberOfMessages=1,
            VisibilityTimeout=30,
            WaitTimeSeconds=0,
            MessageAttributeNames=["All"],
        )
        msgs = r.get("Messages") or []
        if not msgs:
            return None

        msg = msgs[0]
        # 먼저 지운다. 아래에서 폐기로 판정되든 반환되든 이 메시지는 재사용 금지다.
        sqs.delete_message(QueueUrl=QUEUE_URL, ReceiptHandle=msg["ReceiptHandle"])

        session_id, created_at, _ = _parse_item(msg)
        if not session_id:
            continue            # 스키마가 깨진 메시지는 버리고 다음을 본다

        # 8시간 상한에 가까운 세션을 유저에게 주면 대화 중에 microVM 이 죽는다.
        # 지금 콜드스타트를 한 번 맞는 것이 대화 도중 끊기는 것보다 낫다.
        if time.time() - created_at > MAX_VM_AGE_SEC:
            continue
        return session_id
    return None


def _refill(count):
    """uuid 를 만들어 예열 핑을 넣고, **성공한 것만** 큐에 넣는다.

    핑이 실패한 uuid 를 큐에 넣으면 재고 숫자는 올라가지만 실제로는 빈 껍데기라서,
    유저가 그걸 꺼낼 때 콜드스타트가 난다. 재고 수치가 거짓말을 하게 되는 쪽이
    재고가 부족한 것보다 나쁘다.

    1회 상한을 두는 이유: 세션 생성률 쿼터 L-8EE2AEA2 가 **계정당 25 TPS** 이고
    모든 엔드포인트가 이 한도를 공유한다. 한 번에 크게 보충하면 스로틀에 걸려
    실제 유저의 세션 생성까지 같이 막힌다.
    """
    added, errors = 0, []
    for _ in range(max(0, min(count, REFILL_MAX_PER_CALL))):
        session_id = _new_session_id()
        try:
            _invoke(session_id, {"type": "warmup"})
        except Exception as e:                                   # noqa: BLE001
            logger.exception("warmup ping failed")
            # ⚠️ 예외 문자열에는 ARN 이 들어간다. 타입명만 남긴다.
            errors.append(type(e).__name__)
            continue                                  # 실패분은 큐에 넣지 않는다
        now = time.time()
        try:
            _send_to_pool(session_id, now, now)
            added += 1
        except Exception as e:                                   # noqa: BLE001
            # 예열은 됐지만 큐 입력이 실패한 경우. 세션은 살아 있고 아무도 모르므로
            # idle 만료까지 메모리 과금만 남는다(누수). 감추지 말고 노출한다.
            errors.append(f"send_message: {type(e).__name__}")
    return added, errors


def _heartbeat():
    """재고 세션에 예열 핑을 보내 idle 타이머를 리셋한다.

    한 번 호출에 **receive 1회(최대 10건)** 만 처리한다. 이 설계는 아래 버그를
    실측으로 겪고 나서 바꾼 것이다.

    ⚠️ 처음에는 재고를 다 훑으려고 receive 를 여러 라운드 돌렸다. 그런데 환원한
    메시지가 같은 실행에서 다시 receive 되고, 그때 VisibilityTimeout 이 다시
    걸리면서 **heartbeat 직후 재고 전체가 약 40초간 보이지 않는** 상태가 됐다.
    그 사이 pop 은 빈손이 되어 전 유저가 콜드스타트를 맞았다.
    (실측: heartbeat 가 pinged=3 을 반환한 직후 invisible=3 / visible=0,
     이어진 요청이 source=fresh, 1,329ms)
    예열해 둔 세션이 살아 있는데도 못 쓰는 상태였으므로, 웜풀의 목적 자체가
    무너지는 버그였다.

    라운드를 1회로 묶으면 환원분을 다시 집을 일이 없어 문제가 사라진다.
    재고가 10개를 넘으면 이 함수를 여러 번 호출하면 된다(스케줄러에서 병렬 호출).
    한 번에 전부 훑는 것보다, 어느 시점에도 재고가 잠기지 않는 것이 중요하다.

    ⚠️ 삭제와 재전송의 순서: **delete 먼저, send 나중.**
    사이에서 죽으면 uuid 를 잃어 세션이 누수된다(idle 만료까지 메모리 과금).
    반대 순서였다면 같은 uuid 가 큐에 두 개 남아 두 유저가 한 microVM 을 공유하고
    대화가 섞인다. 돈이 조금 새는 것과 유저 대화가 섞이는 것 중 전자를 고른다.
    """
    pinged, dropped = 0, 0

    r = sqs.receive_message(
        QueueUrl=QUEUE_URL,
        MaxNumberOfMessages=10,
        # 핑 10건이 끝날 때까지 다른 실행이 같은 메시지를 집지 않을 만큼만 잡는다.
        # 처리한 메시지는 전부 delete 되므로 이 값이 재고를 잠그는 시간이 되지 않는다.
        VisibilityTimeout=30,
        WaitTimeSeconds=1,
        MessageAttributeNames=["All"],
    )

    for msg in r.get("Messages") or []:
        session_id, created_at, _ = _parse_item(msg)
        handle = msg["ReceiptHandle"]

        if not session_id:
            # 형식이 깨진 메시지는 재고 숫자를 거짓으로 만들므로 버린다.
            sqs.delete_message(QueueUrl=QUEUE_URL, ReceiptHandle=handle)
            dropped += 1
            continue

        # 8시간 상한 초과분은 환원하지 않고 폐기한다(rolling replacement).
        # 폐기한 만큼은 refill 이 새 uuid 로 채운다.
        if time.time() - created_at > MAX_VM_AGE_SEC:
            sqs.delete_message(QueueUrl=QUEUE_URL, ReceiptHandle=handle)
            dropped += 1
            continue

        if not _warm_ping(session_id):
            # 핑이 실패한 세션은 이미 죽은 것으로 본다. 환원하면 재고 숫자가
            # 거짓이 되므로 폐기한다.
            sqs.delete_message(QueueUrl=QUEUE_URL, ReceiptHandle=handle)
            dropped += 1
            continue

        sqs.delete_message(QueueUrl=QUEUE_URL, ReceiptHandle=handle)
        _send_to_pool(session_id, created_at, time.time())
        pinged += 1

    return pinged, dropped


def _peek_pool():
    """재고를 훑어 화면에 보여준다.

    VisibilityTimeout=0 으로 받아 **즉시 다시 보이게** 한다. 조회 때문에 재고가
    잠기면, 화면을 열어둔 것만으로 pop 이 빈손이 되어 콜드스타트가 난다.
    그래도 receive 자체가 순간적으로 재고를 만지므로 이 목록은 근사값이다.
    """
    r = sqs.receive_message(
        QueueUrl=QUEUE_URL,
        MaxNumberOfMessages=10,
        VisibilityTimeout=0,
        WaitTimeSeconds=1,
        MessageAttributeNames=["All"],
    )
    now = time.time()
    items = []
    for msg in r.get("Messages") or []:
        session_id, created_at, last_ping_at = _parse_item(msg)
        if not session_id:
            continue
        items.append({
            # uuid 는 앞 8자만 노출한다. 전체를 내보내면 브라우저에서 남의 세션으로
            # 호출할 수 있는 값이 되고, 그건 방식 1의 위조 문제를 방식 2에도 들여오는 것이다.
            "uuid": session_id[:8],
            "ageSec": round(now - created_at),
            # 마지막 핑 이후 idle 창을 넘겼는지. createdAt 이 아니라 lastPingAt 기준이다
            # — heartbeat 가 도는 세션은 오래됐어도 살아 있다.
            "staleRisk": (now - last_ping_at) > SESSION_TTL_SEC
                         or (now - created_at) > MAX_VM_AGE_SEC,
        })
    return items


# ── 세션 선택 ───────────────────────────────────────────────────────────────
def _normalize_epoch_sec(v):
    """epoch 초로 맞춘다.

    클라이언트가 JS 라면 Date.now() 로 **밀리초**를 보낸다. 그대로 초로 쓰면
    now - lastCallAt 이 거대한 음수가 되어 "항상 유효한 세션"으로 판정되고,
    죽은 uuid 를 계속 재사용한다. 그런데 죽은 uuid 호출은 에러가 아니라
    HTTP 200 + 콜드스타트이므로(실측) 이 버그는 실패가 아니라 "가끔 느림"으로만
    드러나 발견이 매우 늦다. 그래서 단위를 추론해 방어한다.
    """
    try:
        f = float(v)
    except (TypeError, ValueError):
        return None
    if f <= 0:
        return None
    return f / 1000.0 if f > 1e11 else f       # 1e11 초 ≈ 서기 5138년


def _resolve_store(user_id):
    """모드 2 (store): DynamoDB 가 만료를 판단한다. 클라이언트는 userId 만 보낸다.

    반환: (sessionId, source, error)
    """
    now = time.time()
    pk = f"sess#{user_id}"

    try:
        # ConsistentRead=True 를 쓴다. 유저가 첫 응답 직후 두 번째 메시지를 보내면
        # 결과적 일관성 읽기로는 방금 쓴 행을 못 볼 수 있고, 그러면 MISS 로 판정해
        # 풀에서 또 하나를 꺼낸다 — 세션 한 개를 버리고 대화 이력도 갈린다.
        item = ddb.get_item(
            TableName=TABLE_NAME,
            Key={"pk": {"S": pk}},
            ConsistentRead=True,
        ).get("Item")
    except Exception as e:                                       # noqa: BLE001
        # ⚠️ DynamoDB 조회 실패 시 **절대 pop 하지 않는다.**
        # 조회 실패를 MISS 로 처리하면 장애 순간 전 유저가 동시에 풀을 꺼내가
        # 재고가 즉시 고갈되고, 그 다음부터는 전원이 콜드스타트다. 즉 DynamoDB
        # 장애가 "조금 느려짐"에서 "전면 성능 붕괴"로 증폭된다.
        # 여기서는 fresh 로 폴백한다 — 이 유저 한 명만 콜드스타트를 맞고,
        # 남은 재고는 정상 유저들이 계속 쓴다.
        return _new_session_id(), "fresh", f"ddb_get: {type(e).__name__}"

    # ⚠️ TTL 값을 직접 비교해 만료를 판정한다.
    # DynamoDB TTL 삭제는 만료 시각 이후 **최대 48시간까지 지연**될 수 있다.
    # 즉 "행이 존재한다"는 것은 "유효하다"가 아니다. 삭제를 기다렸다가 판정하면
    # 13분 전에 죽은 microVM 의 uuid 를 며칠 동안 재사용하게 된다.
    if item:
        try:
            ttl = float(item["ttl"]["N"])
        except (KeyError, ValueError):
            ttl = 0.0
        if ttl > now and item.get("sessionId", {}).get("S"):
            return item["sessionId"]["S"], "reused", None

    # MISS(행이 없거나 ttl 만료) → 풀에서 꺼낸다.
    try:
        popped = _pop_from_pool()
    except Exception as e:                                       # noqa: BLE001
        return _new_session_id(), "fresh", f"sqs_pop: {type(e).__name__}"

    if popped:
        return popped, "pool", None
    return _new_session_id(), "fresh", None


def _resolve_client(session_id_in, last_call_at_in):
    """모드 1 (client): 클라이언트가 보낸 sessionId / lastCallAt 을 신뢰한다.

    반환: (sessionId, source, error)

    ⚠️ **uuid 위조가 가능하다.** 서버는 이 sessionId 가 이 userId 의 것인지 확인할
    수단이 없다(그래서 DynamoDB 를 안 쓰는 방식이다). 남의 세션 uuid 를 알아낸
    클라이언트가 그걸 보내면 그 microVM 에 그대로 올라탄다. memorySessionId 는
    userId 로 갈라지므로 대화 이력이 바로 새지는 않지만, 남의 microVM 을 점유하고
    프로세스 로컬 상태에 접근할 수 있다.
    운영에서 방식 1을 쓸 것이면 uuid 에 서버 HMAC 서명을 붙여 검증하거나,
    애초에 클라이언트가 uuid 를 모르는 방식 2(store)를 써야 한다.

    ⚠️ 만료 판정이 클라이언트 기기 시계에 의존한다. 시계가 틀리면 죽은 uuid 로
    호출하고, 그것은 에러가 아니라 조용한 콜드스타트로만 드러난다.
    """
    last_call_at = _normalize_epoch_sec(last_call_at_in)
    if session_id_in and last_call_at is not None:
        if (time.time() - last_call_at) <= SESSION_TTL_SEC:
            return session_id_in, "reused", None

    try:
        popped = _pop_from_pool()
    except Exception as e:                                       # noqa: BLE001
        return _new_session_id(), "fresh", f"sqs_pop: {type(e).__name__}"

    if popped:
        return popped, "pool", None
    return _new_session_id(), "fresh", None


# ── 엔드포인트 ──────────────────────────────────────────────────────────────
def _api_chat(body):
    mode = body.get("mode") or "store"
    user_id = body.get("userId")
    prompt = body.get("prompt") or ""

    if not user_id:
        return _resp({"error": "userId is required"}, 400)
    if mode not in ("client", "store"):
        return _resp({"error": f"unknown mode: {mode}"}, 400)

    if mode == "client":
        session_id, source, sel_err = _resolve_client(
            body.get("sessionId"), body.get("lastCallAt"))
    else:
        session_id, source, sel_err = _resolve_store(user_id)

    try:
        agent, latency_ms = _invoke(session_id, {
            "prompt": prompt,
            "userId": user_id,
            # runtimeSessionId 와 독립된 이력 키. 이것이 있어야 microVM 을 바꿔도
            # 대화가 이어진다.
            "memorySessionId": _memory_session_id(user_id),
        })
    except Exception as e:                                       # noqa: BLE001
        # 실패를 감추지는 않되(콜드스타트 데모에서 조용한 실패는 "그냥 느린 것"과
        # 구별되지 않는다), 예외 문자열은 응답에 싣지 않는다. AWS 예외 메시지에는
        # 호출 주체와 대상 리소스의 ARN 이 들어가고, 이 API 는 오소라이저가 없다.
        logger.exception("invoke failed (session=%s, mode=%s)", session_id, mode)
        return _resp({
            "error": f"invoke: {type(e).__name__}",
            "sessionId": session_id, "source": source, "mode": mode,
            "selectError": sel_err,
        }, 502)

    uptime_ms = float(agent.get("uptimeMs") or 0)
    # uptimeMs 가 크다 = 이 microVM 은 예열되어 기다리고 있었다 = 웜.
    cold_start = uptime_ms <= COLD_UPTIME_MS

    # store 모드는 이번 호출 시각으로 TTL 을 밀어 세션을 살려둔다.
    # invoke 성공 뒤에 쓴다 — 실패한 세션을 유저에게 묶어두면 다음 호출도 같은
    # 죽은 uuid 로 가서 계속 콜드스타트가 난다.
    write_err = None
    if mode == "store":
        now = int(time.time())
        try:
            ddb.put_item(
                TableName=TABLE_NAME,
                Item={
                    "pk": {"S": f"sess#{user_id}"},
                    "sessionId": {"S": session_id},
                    "ttl": {"N": str(now + SESSION_TTL_SEC)},
                    "lastCallAt": {"N": str(now)},
                },
            )
        except Exception as e:                                   # noqa: BLE001
            # 쓰기 실패는 이번 응답을 망치지 않는다(답변은 이미 받았다).
            # 다음 호출이 MISS 로 떨어져 세션 하나를 더 쓰게 될 뿐이다.
            write_err = f"ddb_put: {type(e).__name__}"

    _record(mode, latency_ms, source, cold_start)

    # 응답을 필드별로 조립한다. agent 응답을 그대로 펼치면(**agent) 에이전트의
    # mode("code"/"container" — 배포 방식)가 요청의 mode("client"/"store")를
    # 덮어써서 화면에 엉뚱한 값이 뜬다. 두 mode 는 이름만 같고 의미가 다르다.
    out = {
        "answer": agent.get("answer", ""),
        "sessionId": session_id,
        "latencyMs": latency_ms,
        "source": source,
        "coldStart": cold_start,
        "uptimeMs": uptime_ms,
        "servedByThisVm": agent.get("servedByThisVm", 0),
        "contextRestored": bool(agent.get("contextRestored", False)),
        "turn": agent.get("turn", 0),
        "poolDepth": _pool_depth(),
        "mode": mode,
    }
    err = sel_err or write_err or agent.get("error")
    if err:
        out["error"] = err
    return _resp(out)


def _api_pool():
    try:
        return _resp({
            "depth": _pool_depth(),
            "target": POOL_TARGET,
            "items": _peek_pool(),
        })
    except Exception as e:                                       # noqa: BLE001
        logger.exception("pool peek failed")
        return _resp({"depth": -1, "target": POOL_TARGET, "items": [],
                      "error": type(e).__name__}, 500)


def _api_pool_refill(body):
    # count 미지정이면 목표치까지 채운다.
    depth = _pool_depth()
    count = body.get("count")
    if count is None:
        count = POOL_TARGET - depth if depth >= 0 else POOL_TARGET
    try:
        count = int(count)
    except (TypeError, ValueError):
        return _resp({"error": "count must be a number"}, 400)

    added, errors = _refill(count)
    out = {"added": added, "depth": _pool_depth()}
    if errors:
        out["error"] = "; ".join(errors[:5])
    return _resp(out)


def _api_pool_heartbeat():
    try:
        pinged, dropped = _heartbeat()
    except Exception as e:                                       # noqa: BLE001
        logger.exception("heartbeat failed")
        return _resp({"pinged": 0, "depth": _pool_depth(),
                      "error": type(e).__name__}, 500)
    out = {"pinged": pinged, "depth": _pool_depth()}
    if dropped:
        # 8시간 초과분·핑 실패분. refill 로 채워야 하므로 화면에 알린다.
        out["dropped"] = dropped
    return _resp(out)


def _api_session_end(body):
    user_id = body.get("userId")
    if not user_id:
        return _resp({"error": "userId is required"}, 400)

    session_id = body.get("sessionId")
    err = None

    # sessionId 를 안 줬으면 store 모드 매핑에서 찾는다.
    if not session_id:
        try:
            item = ddb.get_item(
                TableName=TABLE_NAME,
                Key={"pk": {"S": f"sess#{user_id}"}},
                ConsistentRead=True,
            ).get("Item")
            if item:
                session_id = item.get("sessionId", {}).get("S")
        except Exception as e:                                   # noqa: BLE001
            err = f"ddb_get: {type(e).__name__}"

    stopped = False
    if session_id:
        try:
            agentcore.stop_runtime_session(
                agentRuntimeArn=RUNTIME_ARN,
                runtimeSessionId=session_id,
            )
            stopped = True
        except Exception as e:                                   # noqa: BLE001
            # 이미 죽은 세션을 끄는 것은 정상 흐름이다(ResourceNotFound 등).
            # 실패해도 아래 매핑 삭제는 진행한다 — 남겨두면 다음 호출이 죽은
            # uuid 를 재사용해 콜드스타트가 난다.
            err = f"stop: {type(e).__name__}"

    # 매핑을 지운다. TTL 만료를 기다리지 않는다(삭제가 최대 48시간 지연될 수 있고,
    # 여기서는 ttl 값 비교로 판정하므로 남아 있으면 계속 유효로 읽힐 수 있다).
    try:
        ddb.delete_item(TableName=TABLE_NAME, Key={"pk": {"S": f"sess#{user_id}"}})
    except Exception as e:                                       # noqa: BLE001
        err = err or f"ddb_delete: {type(e).__name__}"

    out = {"stopped": stopped, "sessionId": session_id or ""}
    if err:
        out["error"] = err
    return _resp(out)


def _api_metrics():
    return _resp({"calls": list(_METRICS)})


# ── 라우팅 ──────────────────────────────────────────────────────────────────
def _route_of(event):
    """rawPath 에서 /api/... 부분만 뽑는다.

    $default 스테이지면 rawPath 가 "/api/chat" 이지만, 이름 있는 스테이지를 쓰면
    "/prod/api/chat" 처럼 스테이지가 앞에 붙는다. 그대로 비교하면 배포 방식만
    바꿨을 때 전부 404 가 되므로 "/api" 위치를 찾아 자른다.
    """
    raw = event.get("rawPath") or ""
    i = raw.find("/api/")
    path = raw[i:] if i >= 0 else raw
    path = path.rstrip("/")
    return path or "/"


def lambda_handler(event, context):                              # noqa: ARG001
    method = ((event.get("requestContext") or {}).get("http") or {}).get("method", "")
    path = _route_of(event)

    # 프리플라이트는 본문 없이 200 + CORS 헤더만.
    if method == "OPTIONS":
        return _resp({"ok": True})

    try:
        body = json.loads(event.get("body") or "{}")
        if not isinstance(body, dict):
            body = {}
    except json.JSONDecodeError:
        return _resp({"error": "invalid json body"}, 400)

    try:
        if path == "/api/chat" and method == "POST":
            return _api_chat(body)
        if path == "/api/pool" and method == "GET":
            return _api_pool()
        if path == "/api/pool/refill" and method == "POST":
            return _api_pool_refill(body)
        if path == "/api/pool/heartbeat" and method == "POST":
            return _api_pool_heartbeat()
        if path == "/api/session/end" and method == "POST":
            return _api_session_end(body)
        if path == "/api/metrics" and method == "GET":
            return _api_metrics()
        return _resp({"error": f"not found: {method} {path}"}, 404)
    except Exception as e:                                       # noqa: BLE001
        # 최후 방어. 전체 내용은 CloudWatch 로만 보내고, 응답에는 예외 타입만 남긴다.
        #
        # ⚠️ 예전에는 str(e) 와 traceback 을 그대로 응답에 실었다. 그런데 이 API 는
        # 오소라이저가 없고 CORS 가 * 이므로, URL 을 아는 누구나 일부러 실패를
        # 유발해 응답을 읽을 수 있다. AWS 예외 문자열에는 호출 주체와 대상 리소스의
        # ARN 이 그대로 들어가고(AccessDenied·ValidationException 등), QUEUE_URL 자체에
        # 계정 ID 가 포함되어 있다. 즉 traceback 하나로 계정 ID 가 공개된다.
        #
        # 디버깅은 requestId 로 CloudWatch 로그를 찾아서 한다.
        logger.exception("unhandled error on %s %s", method, path)
        return _resp({
            "error": type(e).__name__,
            "hint": "자세한 내용은 CloudWatch 로그를 확인하십시오",
            "requestId": (event.get("requestContext") or {}).get("requestId"),
        }, 500)
