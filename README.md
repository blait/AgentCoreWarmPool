# AgentCore Runtime 웜풀 데모

**AgentCore Runtime의 콜드스타트를 웜풀로 없앨 수 있다는 것을, 웹 UI에서 직접 눌러 확인하는 데모입니다.**

버튼을 누르면 실제 AgentCore Runtime을 호출하고, 응답에 실린 `uptimeMs`로
"이 요청이 미리 켜둔 microVM에 안착했는지, 그 자리에서 부팅했는지"를 화면에 표시합니다.
지연 차이는 추정이 아니라 매 호출의 실측값입니다.

이 레포가 증명하려는 것은 하나입니다 — **콜드스타트는 배포 방식을 바꾸지 않고도
세션 재사용만으로 제거할 수 있고, 그 이득이 배포 방식을 바꾸는 것보다 큽니다.**

---

## 0. 문서와 코드

### 상세 문서 — 먼저 보십시오

| 문서 | 내용 | 보는 법 |
|---|---|---|
| **[`docs/architecture.html`](docs/architecture.html)** | **SVG 아키텍처 다이어그램 3장** + 두 방식 상세 + **시나리오 8개** + **실배포 검증 결과** + heartbeat 버그 분석 | 클론 후 브라우저로 열기 |
| [`docs/architecture.md`](docs/architecture.md) | 요청 흐름 단계별 설명, heartbeat·8시간 rolling replacement 설계 근거, 원문과 추가 설계의 구분 | GitHub 에서 바로 |

`architecture.html` 은 GitHub 에서 소스로만 보이므로 로컬에서 열어야 합니다.

```bash
git clone https://github.com/blait/AgentCoreWarmPool.git
cd AgentCoreWarmPool
open docs/architecture.html          # macOS
xdg-open docs/architecture.html     # Linux
start docs\architecture.html        # Windows
```

**HTML 문서에서 특히 볼 것**

| 절 | 왜 |
|---|---|
| §1 | 콜드 1,328ms vs 웜 101ms 실측 근거, AWS 관리형 웜풀 10개 |
| §5-1 | **heartbeat 가 웜풀을 무력화시킨 실제 버그** — 로그와 원인 |
| §5-2 | **`VisibilityTimeout=0` 으로 해결** — 재고를 잠그지 않는 방법 |
| §6 | 시나리오 8개별 예상 지연과 `source` 값 |
| §9 | 실배포 검증 결과 전체 |

### 코드 구성

| 경로 | 역할 | 핵심 |
|---|---|---|
| [`agent/main.py`](agent/main.py) | AgentCore Runtime 에이전트 | `warmup` 센티널 조기 반환, `uptimeMs` 로 콜드/웜 판별 근거 제공. **stdlib 만 사용** |
| [`server/lambda_function.py`](server/lambda_function.py) | Lambda 프록시 | 두 방식 분기, SQS 풀 pop/보충/heartbeat |
| [`web/index.html`](web/index.html) | 데모 GUI | 모드 토글, 풀 시각화, 인라인 SVG 차트, 시나리오 4종. **외부 CDN 의존 없음** |
| [`scripts/deploy.sh`](scripts/deploy.sh) | 전체 배포 | 빈 계정에서 1회 실행. 계정 ID 하드코딩 없음 |
| [`scripts/teardown.sh`](scripts/teardown.sh) | 정리 | 역순 삭제. `--yes` 로 확인 생략 |

---

## 1. 실측 결과

| 항목 | 값 | 비고 |
|---|---|---|
| **콜드스타트 p50** | **1,328ms** | 직접 코드 배포, 매번 새 세션 |
| **웜스타트 p50** | **101ms** | 같은 세션 ID 재호출 |
| **차이** | **13배** | 세션 재사용의 이득 |
| **AWS 관리형 웜풀 크기** | **10개** | 엔드포인트당. 버스트 30·60에서 동일하게 재현 |

**이 수치를 신뢰할 수 있는 이유**: 바이트 단위로 동일한 `main.py`를 직접 코드·컨테이너
두 방식으로 각각 배포해 배포 방식 외 변수를 제거하고, `ap-northeast-2`(서울)에서 두 모드를
교대 호출해 시간대 편향을 제거한 뒤 12회 반복 측정했습니다. LLM·툴 호출은 넣지 않아
플랫폼 오버헤드만 분리했습니다.

참고로 **웜스타트 101ms는 배포 방식과 무관**했습니다(직접 코드 101.5ms / 컨테이너 100.6ms).
핸들러가 실행되기 시작하면 두 방식이 같아지므로, 웜풀은 어느 배포 방식에서도 동일하게 효과가 있습니다.

> **왜 13배가 3.5배보다 중요한가**
> 컨테이너 배포로 바꾸면 콜드스타트가 1,328ms → 379ms로 3.5배 개선됩니다(실측). 하지만 그 효과는
> AWS 관리형 웜풀 **10개**에 히트할 때만 나옵니다. 풀이 비면 3,337ms로 오히려 직접 코드(1,376ms)보다
> 2.4배 느려집니다. 반면 세션 재사용의 13배는 풀 크기와 무관하고, 배포 방식을 바꾸지 않아도 됩니다.

---

## 2. 실배포 검증 결과 (2026-09-14)

이 레포의 코드를 실제로 `ap-northeast-2`에 배포해 두 방식 모두 동작을 확인했습니다.
아래는 실행 로그를 그대로 옮긴 값입니다.

> **⚠️ 아래 로그와 현재 커밋의 차이 (2026-09-14 수정)**
>
> 이 로그를 얻은 뒤 코드 리뷰에서 세 가지 배포 결함을 찾아 고쳤습니다. 로그를 만든
> 실행본과 현재 트리는 아래만큼 다릅니다.
>
> 1. **`RUNTIME_REGION`** — 프록시가 모듈 스코프에서 이 변수를 필수로 읽는데
>    `deploy.sh`가 주입하지 않았습니다. 로그를 얻은 실행본은 리전을 다른 방식으로
>    받았고, 지금은 `RUNTIME_REGION` 주입 + `AWS_REGION` 폴백 양쪽을 갖췄습니다.
>    **아래 지연·`source` 값은 세션 선택 로직의 결과이고, 그 로직은 이 수정으로
>    바뀌지 않았습니다.**
> 2. **heartbeat 스케줄러** — 로그를 얻을 때 heartbeat는 **손으로 호출**했습니다
>    (아래 "heartbeat 후 재고 사용 가능" 항목도 수동 호출 결과입니다).
>    EventBridge 규칙은 이 수정에서 새로 추가한 것이며 **아직 실측하지 않았습니다.**
> 3. **큐 보관 기간** — 1시간이었습니다. 즉 §7의 8시간 rolling replacement는
>    당시 도달 불가능한 코드였고, **지금도 실측되지 않았습니다**(보관 기간만 8시간으로
>    올려 도달 가능하게 만든 상태입니다).
>
> 요약하면 **1회성 지연 측정치는 유효하고, 시간이 지나야 드러나는 항목
> (heartbeat 자동 주기, 8시간 교체)은 미검증**입니다.

### 방식 2 — 연속 질문

```
질문1:  117.9ms  source=pool     cold=False  uptime=8149ms  turn=1  restored=True
질문2:  104.5ms  source=reused   cold=False  uptime=8392ms  turn=2  restored=False
질문3:   84.2ms  source=reused   cold=False  uptime=8604ms  turn=3  restored=False
```

`uptime=8149ms` — 요청이 도달하기 8초 전에 이미 부팅되어 있던 microVM에 안착했습니다.
콜드스타트 1,328ms가 예열 파이프라인으로 옮겨간 결과입니다.

### 방식 1 — 13분 경과 감지

```
q1:  107.2ms  source=pool     q2:  95.0ms  source=reused
lastCallAt 을 900초 과거로 설정 → 125.0ms  source=pool   ← 만료 감지 후 큐에서 교체
```

### ⭐ 풀 소진 — 웜풀이 필요한 이유

재고 2개 상태에서 신규 유저 6명을 연달아 호출했습니다.

```
유저1:   100.4ms  source=pool     웜
유저2:   134.2ms  source=pool     웜
유저3:  1307.7ms  source=fresh    콜드   ← 재고 바닥
유저4:  1296.7ms  source=fresh    콜드
유저5:  1349.7ms  source=fresh    콜드
유저6:  1263.2ms  source=fresh    콜드
```

**같은 코드·같은 런타임에서 풀 재고 유무만으로 10배 이상 차이가 납니다.**
콜드 구간(1,263~1,350ms)은 위 실측 p50 1,328ms와 일치합니다.

### ⚠️ 실배포에서 발견해 고친 버그 — heartbeat가 재고를 잠갔다

```
heartbeat 실행 → {"pinged": 3, "depth": 3}    ← 성공한 것처럼 보인다
SQS 상태        → visible=0, invisible=3       ← 그런데 재고 전부가 잠김
이어진 요청      → 1329.5ms  source=fresh      ← 전 유저가 콜드스타트
```

heartbeat가 재고를 다 훑으려고 `receive`를 여러 라운드 돌렸는데, 환원한 메시지가 같은
실행에서 다시 잡히며 `VisibilityTimeout`이 재적용됐습니다. **예열된 세션이 살아 있는데도
pop이 빈손이 되어, 웜풀의 목적 자체가 무너지는 버그입니다.**

`receive`를 1회(최대 10건)로 제한해 고쳤습니다.

```
수정 후: heartbeat → {"pinged": 7, "depth": 7}  ·  SQS: visible=7, invisible=0
         직후 요청: 95.5ms / 103.7ms  source=pool  웜
```

> **운영 전에 "heartbeat 직후 pop이 웜인가"를 반드시 검증하십시오.**
> 원문에는 heartbeat가 "필요하다"는 한 줄만 있고 구현이 없습니다. 실제로 만들어보면
> **SQS 가시성 관리가 웜풀 운영의 핵심 난점**입니다.

### 검증 항목

| 항목 | 결과 |
|---|---|
| 방식 2 — pool → reused 전환 | ✅ 117.9 → 104.5 → 84.2ms |
| 방식 1 — 13분 초과 감지 후 교체 | ✅ source=pool, 125ms |
| 풀 소진 시 fresh 폴백 | ✅ 1,263~1,350ms |
| heartbeat 후 재고 사용 가능 | ✅ 수정 후 확인 (**수동 호출**) |
| StopRuntimeSession → 재질문 | ✅ 세션 교체 |
| CloudFront → API GW → Lambda → Runtime | ✅ 158ms |
| warmup 센티널이 LLM 우회 | ✅ 예열 1,489ms 흡수 |
| 보충 속도 · 지속 부하 | ⚠️ 미측정 (6절 참조) |
| **heartbeat 자동 주기(EventBridge)로 재고 유지** | ⚠️ **미측정** — 규칙은 추가했으나 1주기 이상 관측하지 않았습니다 |
| **8시간 rolling replacement 실제 발동** | ⚠️ **미측정** — 8시간 관측이 필요합니다 |

---

## 3. 아키텍처

```
                      ┌────────────────────────────┐
                      │  브라우저 (데모 UI)        │
                      │  mode: client / store      │
                      │  지연 · source · 콜드      │
                      └─────────────┬──────────────┘
                                    │ HTTPS
                      ┌─────────────▼──────────────┐
                      │  S3 + CloudFront (정적)    │
                      └─────────────┬──────────────┘
                                    │ /api/*
                      ┌─────────────▼──────────────┐
                      │  API Gateway (HTTP API)    │
                      └─────────────┬──────────────┘
                                    │
                      ┌─────────────▼──────────────┐
                      │  Lambda proxy              │
                      │  세션 선택 · 지연 계측     │
                      └──┬─────────┬─────────┬─────┘
                         │         │         │
           ┌─────────────┘         │         └───────────────────┐
           │                       │                             │
┌──────────▼──────────┐ ┌──────────▼──────────┐   ┌──────────────▼──────────────┐
│  DynamoDB           │ │  SQS FIFO           │   │  AgentCore Runtime          │
│  세션 매핑 + TTL    │ │  예열 uuid 재고     │   │  세션 1개 = microVM 1개     │
│  만료 판단 담당     │ │  pop 후 보충        │   │  warmup 핑은 조기 반환      │
└─────────────────────┘ └─────────────────────┘   └─────────────────────────────┘
```

요청 경로는 두 가지입니다. 상세는 [`docs/architecture.md`](docs/architecture.md)에 있습니다.

```
[방식 1 · client]  브라우저가 uuid + lastCallAt 보관 → 13분 경과를 직접 계산
                   POST /api/chat { mode:"client", userId, prompt, sessionId, lastCallAt }

[방식 2 · store ]  브라우저는 userId만 전송 → DynamoDB TTL이 만료를 판단  ★추천
                   POST /api/chat { mode:"store",  userId, prompt }
```

---

## 4. 두 방식 비교

| 기준 | 방식 1 · client | 방식 2 · store ★추천 |
|---|---|---|
| **추가 인프라** | 없음 | DynamoDB 테이블 1개 |
| **클라이언트 수정** | **필요** — uuid·lastCallAt 보관, 만료 계산 | **불필요** — userId만 보내면 됨 |
| **시간 비교 코드** | 클라이언트에 있음 (기기 시계 의존) | 서버에 없음 — TTL이 대신 판단 |
| **uuid 위조** | **가능** — 남의 세션 uuid를 보낼 수 있음 | 불가 — 클라이언트가 uuid를 모름 |
| **외부 장애 전파** | 없음 (의존 대상이 없음) | DynamoDB 장애가 전파됨 |
| **조회 지연** | 0ms | 한 자리 ms (DynamoDB 단건 조회) |

**방식 2를 추천합니다.**

결정적인 이유는 **게임 클라이언트를 고치지 않고 서버만 배포하면 된다**는 점입니다. 클라이언트
패치는 심사·배포·강제 업데이트를 거쳐야 하고, 구버전 클라이언트가 남아 있는 동안 두 로직이
공존합니다. 방식 2는 `userId`만 받으므로 이미 배포된 클라이언트를 그대로 두고 서버에서
세션 전략을 바꾸거나 되돌릴 수 있습니다.

부수적으로 얻는 것도 있습니다. 만료 판단이 기기 시계에서 서버로 옮겨가고(방식 1은 클라이언트
시계가 틀리면 죽은 uuid로 호출하게 됩니다), uuid가 클라이언트에 노출되지 않아 위조 경로가
사라집니다.

**방식 1을 고르는 경우**: 추가 인프라를 전혀 쓸 수 없거나, DynamoDB 장애가 채팅 전체를
막는 것을 허용할 수 없을 때입니다. 단, 죽은 uuid로 호출해도 **에러가 아니라 HTTP 200 +
콜드스타트**로 조용히 응답이 느려질 뿐이므로(실측), 만료 계산이 틀려도 눈에 잘 띄지 않습니다.

---

## 5. 빠른 시작

### 필요 권한

배포하는 주체에게 아래 권한이 필요합니다.

| 서비스 | 용도 |
|---|---|
| `bedrock-agentcore` | 런타임 생성·호출 (`CreateAgentRuntime`, `InvokeAgentRuntime`) |
| `iam` | 런타임·Lambda 실행 역할 생성 |
| `lambda`, `apigateway` | proxy API |
| `dynamodb` | 세션 매핑 테이블 (방식 2) |
| `sqs` | 예열 uuid 큐 |
| `events` | heartbeat 스케줄 규칙 (`PutRule`, `PutTargets`) |
| `s3`, `cloudfront` | 정적 웹 호스팅 |

### 배포

```bash
# 리전은 명시적으로 지정한다. 미설정 시 스크립트가 즉시 실패한다.
export AWS_REGION=ap-northeast-2

./scripts/deploy.sh
```

스크립트가 끝나면 **CloudFront URL이 출력**됩니다. 브라우저로 접속해 `client` / `store` 모드를
번갈아 누르며 지연과 `source` 값(`reused` / `pool` / `fresh`)을 확인하십시오.

> CloudFront 배포 전파에 수 분 걸릴 수 있습니다. 403이 보이면 잠시 뒤 다시 시도하십시오.

### 환경변수

계정 ID·ARN·버킷명은 **코드와 문서에 하드코딩되어 있지 않습니다.** 아래 값을 환경에서 읽으며,
미설정이면 즉시 실패합니다.

| 변수 | 내용 |
|---|---|
| `AWS_REGION` | 배포 리전. Lambda 가 자동 주입하는 예약 변수이므로 직접 설정할 수 없습니다 |
| `RUNTIME_REGION` | 런타임을 호출할 리전. `deploy.sh` 가 주입하며, 없으면 `AWS_REGION` 으로 폴백합니다 |
| `RUNTIME_ARN` | AgentCore Runtime ARN |
| `TABLE_NAME` | DynamoDB 세션 매핑 테이블 |
| `QUEUE_URL` | SQS FIFO 큐 URL |

`deploy.sh` 는 `--environment` 로 Lambda 의 `Variables` 맵을 **전체 교체**합니다.
코드가 읽는 변수를 스크립트에서 하나라도 빼면 모듈 로드 시점에 `KeyError` 가 나고
**전 라우트가 502** 가 됩니다. 그래서 변수를 추가할 때는 양쪽을 함께 고쳐야 합니다.


### 웹 UI 사용법

배포 후 CloudFront URL 로 접속하면 아래를 직접 눌러볼 수 있습니다.

| 화면 요소 | 하는 일 |
|---|---|
| **모드 토글** | `방식 2(store)` / `방식 1(client)` 전환. 선택에 따라 **요청 바디가 달라지는 것**이 화면에 표시됩니다 |
| **채팅** | 질문 전송 → 응답에 지연·`source`·콜드여부·`uptimeMs`·`turn` 배지가 붙습니다. **콜드는 빨강, 웜은 초록** |
| **웜풀 재고** | 큐에 있는 uuid 를 슬롯으로 표시(3초 폴링). `[재고 보충]` `[heartbeat 실행]` 버튼 |
| **지연 비교 차트** | 최근 호출을 막대로. **1,328ms 기준선** 표시 |
| **시나리오 4종** | 원클릭 재현 (아래) |

**시나리오 버튼이 증명하는 것**

| 시나리오 | 기대 결과 |
|---|---|
| ① 연속 질문 3회 | 1회 `pool` → 2·3회 `reused`. **전부 웜** |
| ② 세션 종료 후 재질문 | `StopRuntimeSession` 으로 15분 만료를 시뮬레이션. 재고가 있으면 `pool` 로 다시 웜 |
| **③ 풀 소진** | 재고가 있는 동안 `pool`(웜) → **바닥나면 `fresh`(콜드)로 지연 급등.** 웜풀이 필요한 이유를 보여주는 핵심 |
| ④ A/B 비교 | 같은 질문을 두 방식으로. **지연이 비슷해야 정상** — 두 방식의 차이는 성능이 아니라 운영 특성 |

### API 직접 호출

웹 UI 없이 `curl` 로도 전부 테스트할 수 있습니다. `$BASE` 는 배포 시 출력된 CloudFront URL 입니다.

```bash
BASE=https://<your-distribution>.cloudfront.net
```

**① 재고 보충** — 예열된 세션을 큐에 채웁니다

```bash
curl -s -XPOST $BASE/api/pool/refill \
  -H 'content-type: application/json' -d '{"count":5}'
# {"added": 5, "depth": 5}
```

**② 재고 확인**

```bash
curl -s $BASE/api/pool
# {"depth":5,"target":8,"items":[{"uuid":"wp-c4d43","ageSec":6,"staleRisk":false}, ...]}
```

`uuid` 는 **앞 8자만** 노출됩니다. 전체를 내보내면 브라우저에서 남의 세션으로 호출할 수 있는 값이 됩니다.

**③ 대화 — 방식 2 (store)**

```bash
curl -s -XPOST $BASE/api/chat -H 'content-type: application/json' \
  -d '{"mode":"store","userId":"u1","prompt":"안녕"}'
```

```json
{
  "answer": "...", "sessionId": "wp-3e37b3...", "latencyMs": 117.9,
  "source": "pool", "coldStart": false, "uptimeMs": 8149.2,
  "servedByThisVm": 1, "contextRestored": true, "turn": 1, "poolDepth": 4
}
```

같은 `userId` 로 다시 호출하면 `source` 가 `reused` 로 바뀝니다. **클라이언트는 `sessionId` 를 보내지 않습니다** — 서버의 TTL 이 만료를 판단합니다.

**④ 대화 — 방식 1 (client)**

클라이언트가 `sessionId` 와 `lastCallAt`(epoch 초)을 직접 관리합니다.

```bash
# 첫 호출 — 세션 정보 없이
curl -s -XPOST $BASE/api/chat -H 'content-type: application/json' \
  -d '{"mode":"client","userId":"u2","prompt":"첫 질문"}'

# 이어서 — 응답의 sessionId 와 현재 시각을 실어 보낸다
curl -s -XPOST $BASE/api/chat -H 'content-type: application/json' \
  -d '{"mode":"client","userId":"u2","prompt":"두번째",
       "sessionId":"wp-...","lastCallAt":'$(date +%s)'}'

# 13분 초과 시뮬레이션 — lastCallAt 을 과거로 주면 큐에서 새로 꺼낸다
curl -s -XPOST $BASE/api/chat -H 'content-type: application/json' \
  -d '{"mode":"client","userId":"u2","prompt":"오래된 세션",
       "sessionId":"wp-...","lastCallAt":'$(( $(date +%s) - 900 ))'}'
# → source: "pool"  (만료를 감지해 교체)
```

**⑤ heartbeat** — 재고 세션의 idle 타이머를 리셋합니다

```bash
curl -s -XPOST $BASE/api/pool/heartbeat
# {"pinged": 7, "depth": 7}
```

> ⚠️ **실행 직후 반드시 검증하십시오.** `pinged` 값만 보면 [§2 의 버그](#실배포에서-발견해-고친-버그-heartbeat가-재고를-잠갔다)를 놓칩니다.
> ```bash
> curl -s -XPOST $BASE/api/pool/heartbeat
> curl -s -XPOST $BASE/api/chat -H 'content-type: application/json' \
>   -d '{"mode":"store","userId":"hb-check","prompt":"직후"}' \
> | python3 -c 'import sys,json; print(json.load(sys.stdin)["source"])' 
> # pool 이어야 정상. fresh 면 재고가 잠겨 있거나 비어 있다
> ```
> 
> 재고가 0이면 heartbeat 와 무관하게 `fresh` 가 나옵니다. **먼저 `/api/pool` 로
> `depth` 가 1 이상인지 확인**한 뒤 검증하십시오.

**⑥ 세션 종료** — `StopRuntimeSession` 으로 microVM 을 즉시 종료합니다

```bash
curl -s -XPOST $BASE/api/session/end \
  -H 'content-type: application/json' -d '{"userId":"u1"}'
# {"stopped": true, "sessionId": "wp-..."}
```

**⑦ 최근 호출 이력**

```bash
curl -s $BASE/api/metrics
# {"calls":[{"ts":...,"mode":"store","latencyMs":117.9,"source":"pool","coldStart":false}, ...]}
```

⚠️ Lambda 컨테이너 전역에 보관하므로 **컨테이너가 재사용될 때만** 남습니다. 신뢰할 수 있는 지표 저장소가 아닙니다.

### 재현 스크립트 — 풀 소진 실험

README 2절의 결과를 그대로 재현합니다. **이 데모가 증명하려는 것이 한 번에 보이는 실험입니다.**

`drain.sh` 로 저장해 실행하십시오. (한 줄 `for` 문으로 쓰면 셸 따옴표 이스케이프가 깨집니다)

```bash
#!/usr/bin/env bash
# drain.sh — 재고가 바닥나는 지점에서 지연이 뛰는 것을 확인한다
BASE=${BASE:?BASE 를 설정하십시오}

curl -s -XPOST "$BASE/api/pool/refill" \
  -H 'content-type: application/json' -d '{"count":3}' > /dev/null

for i in $(seq 1 6); do
  curl -s -XPOST "$BASE/api/chat" -H 'content-type: application/json' \
    -d '{"mode":"store","userId":"drain-'$RANDOM'-'$i'","prompt":"신규"}' \
  | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(f\"{d['latencyMs']:>8}ms  {d['source']:7} cold={d['coldStart']}\")"
done
```

```bash
BASE=https://<your-distribution>.cloudfront.net bash drain.sh
```

실제 실행 결과입니다. **재고가 바닥나는 지점에서 지연이 14배 뜁니다.**

```
    90.2ms  pool    cold=False
   108.7ms  pool    cold=False
    93.1ms  pool    cold=False     ← 재고 3개 소진
  1295.7ms  fresh   cold=True
  1320.6ms  fresh   cold=True
  1227.1ms  fresh   cold=True
```

콜드 구간(1,227~1,321ms)이 [1절의 콜드스타트 실측 p50 1,328ms](#1-실측-결과)와 일치합니다.
**같은 코드·같은 런타임에서 풀 재고 유무만으로 갈린 차이**입니다.

### 정리

```bash
./scripts/teardown.sh          # 대상 목록을 보여주고 확인을 받는다
./scripts/teardown.sh --yes    # 확인 생략
```

---

## 6. ⚠️ 비용 경고 — 데모 후 teardown은 필수입니다

**웜풀은 "안 쓰는 microVM을 켜둔 채 유지하는" 구조이므로, 아무도 쓰지 않아도 과금됩니다.**

두 가지가 함께 소모됩니다.

1. **메모리 과금** — microVM이 idle이면 CPU는 과금되지 않지만 **메모리는 계속 과금**됩니다.
   예열 세션을 유지하는 비용은 여기서 발생합니다.
2. **동시 세션 쿼터 차감** — 풀에 쌓아둔 재고는 그만큼 `L-3E5722B2`(동시 세션) 한도를
   차감합니다. 재고를 늘리면 실제 유저가 쓸 수 있는 세션이 줄어듭니다.

### 비용 추정 (상한 추정치)

세션 1개, 메모리 8GB, 15분 유휴 기준입니다.

```
8 GB × 0.25 h × $0.00945/GB-hour ≈ $0.019 / 세션
```

**이것은 상한 추정치입니다.** 실측한 값이 아닙니다. 근거와 한계는 다음과 같습니다.

- 요율 `$0.00945/GB-hour`는 AgentCore 공개 요금표(Runtime microVMs, Memory)입니다.
- **8GB는 최댓값을 가정한 것**입니다. 실제 과금은 "그 시점까지의 최대 메모리 사용량"
  기준이고 이 데모 에이전트는 표준 라이브러리만 쓰므로, 실제 비용은 이보다 **훨씬 낮을
  것으로 추정**됩니다. 8GB를 쓰는 것은 안전한 쪽으로 크게 잡기 위한 것입니다.
- CPU 과금(`$0.0895/vCPU-hour`)과 시스템 오버헤드는 위 계산에 포함되지 않았습니다.
  유휴 구간에서는 CPU가 과금되지 않지만, 부팅·초기화·응답 처리 구간에는 과금됩니다.
- 풀 재고 N개를 유지하면 위 값의 N배가 됩니다. heartbeat로 세션을 계속 살려두면
  15분이 아니라 **유지하는 시간 전체**에 대해 과금됩니다.

> **⚠️ heartbeat는 스케줄러로 자동 실행됩니다.** `deploy.sh`가 EventBridge 규칙을
> 만들어 기본 5분마다 재고를 예열하므로, **브라우저를 닫아도 과금이 계속됩니다.**
> 이것이 웜풀의 본질적 비용입니다(재고가 썩는 것을 막는 대가). 데모를 잠시 멈추려면
> 규칙만 끄고, 끝났으면 teardown 하십시오.
>
> ```bash
> aws events disable-rule --region ap-northeast-2 --name acwp-heartbeat   # 잠시 멈춤
> ./scripts/teardown.sh                                                   # 완전 정리
> ```

DynamoDB·SQS·Lambda·EventBridge·CloudFront 비용은 별도이며, 데모 규모에서는 무시할 수준입니다.

---

## 7. 한계와 미확인 사항

**이 레포의 수치 중 무엇이 실측이고 무엇이 아닌지 명확히 구분합니다.**

| # | 미확인 사항 | 왜 중요한가 |
|---|---|---|
| **1** | **보충 속도를 측정하지 않았습니다** | 풀 크기 계산식(`필요 풀 = 초당 요청 × 보충 시간`)의 핵심 변수입니다. 흔히 쓰는 **3.5초는 실측한 보충 시간이 아니라 컨테이너 즉석 부팅 시간을 대용값으로 쓴 것**입니다. 따라서 이 식으로 나온 풀 크기는 추정입니다. |
| **2** | **지속 부하를 측정하지 않았습니다** | **버스트 1회만** 측정했습니다. 원문이 강조하는 "실제 예상 동시성·요청률에서 측정" 원칙을 충족하지 못합니다. 낮은 트래픽 측정은 콜드스타트 노출을 낙관하게 만듭니다. |
| **3** | **관리형 풀 10개는 단일 조건 측정입니다** | 하나의 계정·리전·이미지 크기에서 얻은 값입니다. 계정·리전·아티팩트 크기에 따라 다른지 확인하지 않았습니다. |
| **4** | **엔드포인트 N개면 풀이 N배인지 검증하지 않았습니다** | 원문의 주장이며 이 레포에서 확인하지 않았습니다. |
| **5** | **이 데모에는 LLM 호출이 없습니다** | 플랫폼 오버헤드만 분리하려는 의도적 선택입니다(원문 측정 원칙). 따라서 **여기의 지연은 실제 에이전트의 응답 시간이 아닙니다.** LLM·툴 지연이 더해지면 콜드스타트가 전체에서 차지하는 비중은 줄어듭니다. |
| **6** | **웜풀 크기를 조회·지정하는 API가 없습니다** | `CreateAgentRuntime` / `CreateAgentRuntimeEndpoint` 파라미터에 warm/prewarm/provision/capacity 관련 항목이 없고 Service Quotas에도 항목이 없음을 확인했습니다(실측). 즉 관리형 풀은 관측만 가능하고 제어할 수 없습니다. |

### 그 밖에 알아둘 실측 사실

- **죽은 uuid로 호출해도 에러가 아닙니다.** HTTP 200에 콜드스타트로 응답합니다. 세션 만료는
  실패로 드러나지 않고 **지연으로만** 드러납니다.
- **`idle` 최소값은 60초입니다.** `idle=0`은 API가 거부합니다 (`valid min value: 60`).
- **microVM 최대 수명은 8시간이고 초과할 수 없습니다.** 그래서 풀에는 rolling replacement가
  필요합니다 ([`docs/architecture.md`](docs/architecture.md) 참조).
- **콜드/웜 판정은 `uptimeMs > 1500`을 씁니다.** 실측에서 두 분포가 약 390ms 대 약 3,900ms로
  명확히 갈려 경계값 선택에 민감하지 않았습니다.

---

## 8. 관련 쿼터

| 쿼터 코드 | 항목 | 기본값 | 조정 |
|---|---|---|---|
| `L-8EE2AEA2` | 세션 생성률 (New session creation rate) | **25 TPS / 계정** | 가능 |
| `L-3E5722B2` | 동시 세션 (Concurrent sessions) | — | 가능 |
| `L-9B442722` | Endpoints per Agent | **10** | 가능 |

**⚠️ 세션 생성률 쿼터는 2026-08에 통합되었습니다.**

이전에는 컨테이너 이미지 에이전트(엔드포인트당 400 TPM)와 직접 코드 배포(25 TPS)가 각각
다른 한도를 가졌습니다. 지금은 `L-8EE2AEA2` **하나로 통합**되어 **배포 방식과 무관하게
계정당 25 TPS이고, 모든 엔드포인트가 이 한도를 공유**합니다.

이 통합에는 중요한 결과가 따라옵니다.

> **엔드포인트를 늘려도 지속 트래픽은 개선되지 않습니다.** 예열 풀은 여전히 엔드포인트별이므로
> 엔드포인트를 늘리면 **히트율은** 배수로 늘어납니다. 그러나 풀이 비었을 때의 **보충 처리량은
> 계정 단위 25 TPS로 고정**되어 배수 효과가 없습니다. 즉 다중 엔드포인트는 **버스트 흡수용이며,
> 지속 트래픽에는 무효**입니다.

세션 생성률 쿼터 사용량은 CloudWatch `Usage` 네임스페이스의 `CombinedNewSessionCreation`
메트릭으로 확인합니다 (`Bedrock-AgentCore` 네임스페이스가 아닙니다).

---

## 9. 레포 구성

```
agent/main.py            AgentCore Runtime 에이전트 (warmup 조기 반환 + uptimeMs 계측)
server/                  Lambda proxy — 세션 선택·지연 계측·풀 관리
web/                     데모 UI (정적)
scripts/deploy.sh        배포
scripts/teardown.sh      정리
docs/architecture.md     두 방식의 요청 흐름 + 8개 시나리오
```

### API

| 엔드포인트 | 용도 |
|---|---|
| `POST /api/chat` | 대화. `source`(`reused`/`pool`/`fresh`)와 `coldStart`를 함께 반환 |
| `GET /api/pool` | 풀 재고 조회 (uuid는 앞 8자만 노출) |
| `POST /api/pool/refill` | 재고 보충 |
| `POST /api/pool/heartbeat` | 재고 세션에 핑 — idle 만료 방지. `deploy.sh`가 만든 EventBridge 규칙 `<stack>-heartbeat`가 `idle/3` 주기(기본 5분)로 Lambda를 직접 호출합니다. UI 버튼은 시연용입니다 |
| `POST /api/session/end` | 세션 종료 |
| `GET /api/metrics` | 최근 50건 호출 기록 |

### 세션 ID는 두 종류입니다 — 반드시 분리하십시오

이 데모의 핵심 개념입니다.

| | `runtimeSessionId` | `memorySessionId` |
|---|---|---|
| 값 | `uuid4()`, **33자 이상 필수** | `chat-{userId}` |
| 식별 대상 | microVM | 대화 이력 |
| 교체 | 매번 바뀔 수 있음 | 유저에 고정 |

**이 분리가 없으면 풀에서 세션을 꺼내 쓸 수 없습니다.** 대화 이력이 microVM에 묶여 있으면
미리 만들어둔 uuid는 "남의 대화"가 되기 때문입니다. 이력을 `memorySessionId`로 분리해야
microVM을 자유롭게 교체할 수 있습니다.

---

## 출처

- 원문: AWS re:Post — [Minimizing startup latency with Amazon Bedrock AgentCore Runtime](https://repost.aws/articles/ARCJIn3t7aRC2FxiRTV1SuCA/minimizing-startup-latency-with-amazon-bedrock-agentcore-runtime)
- 요금: [Amazon Bedrock AgentCore Pricing](https://aws.amazon.com/bedrock/agentcore/pricing/)
- 실측: `ap-northeast-2`, 직접 코드·컨테이너 두 방식 동일 코드 배포 비교

원문에 있는 내용과 이 레포에서 추가 설계한 부분의 구분은
[`docs/architecture.md`](docs/architecture.md)에 정리했습니다.

문서 목록과 보는 법은 [0절](#0-문서와-코드)에 있습니다.
