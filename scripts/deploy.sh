#!/usr/bin/env bash
#
# AgentCore Runtime 웜풀 GUI 데모 — 전체 스택 배포 (빈 AWS 계정에서 1회 실행)
#
# 만드는 것:
#   IAM 역할 2개 → S3 코드 버킷 → AgentCore Runtime → DynamoDB → SQS FIFO
#   → Lambda + API Gateway HTTP API → S3 웹 버킷 + CloudFront(OAC) → 초기 풀 보충
#
# 의존성: bash, AWS CLI v2, jq, zip, curl
#   zip  — Lambda·에이전트 배포 패키지를 만드는 데 필요하다.
#   curl — 마지막 단계에서 API Gateway 를 실제로 한 번 때려 스모크 테스트한다.
#          (aws lambda invoke 로 대신하면 API Gateway 경로가 검증되지 않는다)
#
# 사용법:
#   ./scripts/deploy.sh
#   REGION=us-west-2 STACK=mydemo ./scripts/deploy.sh
#
# 이 스크립트는 idempotent 하다. 이미 있는 리소스는 describe 로 확인해 건너뛴다.
# 중간에 실패해도 고친 뒤 그대로 다시 실행하면 된다.
#
set -euo pipefail

# ── 0. 설정 ──────────────────────────────────────────────────────────────
# 계정 ID 는 절대 하드코딩하지 않는다. sts 로 런타임에 조회한다(아래 preflight).
REGION="${REGION:-ap-northeast-2}"
STACK="${STACK:-acwp}"

# 웜풀 파라미터. Lambda 환경변수로 주입해 서버 코드에 매직넘버를 남기지 않는다.
POOL_TARGET="${POOL_TARGET:-10}"          # 유지할 예열 uuid 개수 (실측 AWS 관리형 웜풀도 10개)
IDLE_SECONDS="${IDLE_SECONDS:-900}"       # idleRuntimeSessionTimeout. API 최소값은 60
MAX_LIFETIME="${MAX_LIFETIME:-28800}"     # microVM maxLifetime 상한 = 8시간
WARM_WINDOW_SEC="${WARM_WINDOW_SEC:-780}" # 13분. mode=client 가 만료를 직접 계산하는 기준
COLD_UPTIME_MS="${COLD_UPTIME_MS:-1500}"  # uptimeMs 가 이 값 이하면 그 자리 부팅(콜드)

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACCOUNT_ID=""                             # preflight 에서 채운다 (set -u 대비 초기화)

# ── 출력 헬퍼 ────────────────────────────────────────────────────────────
# 공개 레포용 데모다. 사용자가 로그를 그대로 붙여넣어도 계정 ID 가 새지 않도록
# 사람이 읽는 출력에서는 12자리 계정 ID 를 <account> 로 가린다.
# (버킷 이름에는 전역 유일성 때문에 계정 ID 가 들어가야 한다 — AgentCore 문서의 관례)
mask() {
  if [[ -n "$ACCOUNT_ID" ]]; then
    printf '%s' "$*" | sed "s/${ACCOUNT_ID}/<account>/g"
  else
    printf '%s' "$*"
  fi
}
step() { printf '\n\033[1m==> %s\033[0m\n' "$(mask "$*")"; }
say()  { printf '    %s\n' "$(mask "$*")"; }
skip() { printf '    (건너뜀) %s\n' "$(mask "$*")"; }
die()  { printf '\n\033[31mERROR: %s\033[0m\n' "$(mask "$*")" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ── 1. preflight ─────────────────────────────────────────────────────────
step "1/10 사전 점검"

for bin in aws jq zip curl; do
  command -v "$bin" >/dev/null 2>&1 || die "'${bin}' 가 필요하다. 설치 후 다시 실행하라."
done

aws --version 2>&1 | grep -q 'aws-cli/2' \
  || die "AWS CLI v2 가 필요하다. 현재: $(aws --version 2>&1)"

# bedrock-agentcore-control 은 비교적 최신 CLI 에서만 제공된다.
aws bedrock-agentcore-control help >/dev/null 2>&1 \
  || die "이 AWS CLI 에는 bedrock-agentcore-control 이 없다. 'aws --version' 을 올려라."

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)" \
  || die "AWS 자격증명을 확인할 수 없다. 'aws sts get-caller-identity' 를 먼저 성공시켜라."
[[ "$ACCOUNT_ID" =~ ^[0-9]{12}$ ]] || die "계정 ID 형식이 예상과 다르다."

# STACK 은 S3 버킷 이름의 접두사로 쓰이므로 소문자·하이픈만 허용한다.
[[ "$STACK" =~ ^[a-z][a-z0-9-]{0,20}$ ]] \
  || die "STACK 은 소문자로 시작하고 [a-z0-9-] 21자 이내여야 한다: '${STACK}'"

# ⚠️ AgentCore Runtime 이름 패턴은 [a-zA-Z][a-zA-Z0-9_]{0,47} — 하이픈을 못 쓴다.
# 다른 리소스처럼 ${STACK}-runtime 으로 지으면 ValidationException 이 난다.
RUNTIME_NAME="${RUNTIME_NAME:-$(printf '%s' "${STACK}_runtime" | tr '-' '_')}"
[[ "$RUNTIME_NAME" =~ ^[a-zA-Z][a-zA-Z0-9_]{0,47}$ ]] \
  || die "RUNTIME_NAME 이 AgentCore 패턴에 맞지 않는다: '${RUNTIME_NAME}'"

# 리소스 이름 (버킷은 전역 유일해야 하므로 account+region 을 붙인다)
CODE_BUCKET="${STACK}-code-${ACCOUNT_ID}-${REGION}"
WEB_BUCKET="${STACK}-web-${ACCOUNT_ID}-${REGION}"
RUNTIME_ROLE="${STACK}-runtime-exec"
LAMBDA_ROLE="${STACK}-lambda-exec"
TABLE_NAME="${STACK}-sessions"
QUEUE_NAME="${STACK}-pool.fifo"        # FIFO 큐는 이름이 .fifo 로 끝나야 한다
LAMBDA_NAME="${STACK}-proxy"
API_NAME="${STACK}-api"
OAC_NAME="${STACK}-web-oac"
CF_COMMENT="${STACK} agentcore warm pool demo"   # 배포본 재조회 키로도 쓴다
CODE_KEY="${RUNTIME_NAME}/agent.zip"

# 입력 소스 확인. server/, web/ 은 다른 작업자의 산출물이다.
[[ -f "${ROOT}/agent/main.py" ]] || die "agent/main.py 가 없다."

# Lambda 진입 파일 자동 탐색. LAMBDA_HANDLER 로 강제 지정도 가능하다.
HANDLER_FILE=""
for cand in lambda_function.py handler.py app.py main.py index.py; do
  if [[ -f "${ROOT}/server/${cand}" ]]; then HANDLER_FILE="$cand"; break; fi
done
[[ -n "$HANDLER_FILE" ]] || die "server/ 에 Lambda 진입 파일이 없다. \
lambda_function.py / handler.py / app.py / main.py / index.py 중 하나를 두어라."
LAMBDA_HANDLER="${LAMBDA_HANDLER:-${HANDLER_FILE%.py}.handler}"

[[ -f "${ROOT}/web/index.html" ]] || die "web/index.html 이 없다."

say "region      : ${REGION}"
say "account     : <account>"
say "stack       : ${STACK}"
say "runtime name: ${RUNTIME_NAME}"
say "lambda entry: server/${HANDLER_FILE} → handler '${LAMBDA_HANDLER}'"

# ── 2. IAM 역할 ──────────────────────────────────────────────────────────
step "2/10 IAM 역할"

# AgentCore Runtime 실행 역할.
# trust 에 aws:SourceAccount / aws:SourceArn 조건을 넣어 confused deputy 를 막는다.
cat > "${TMP}/runtime-trust.json" <<JSON
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "AssumeRoleFromAgentCore",
    "Effect": "Allow",
    "Principal": { "Service": "bedrock-agentcore.amazonaws.com" },
    "Action": "sts:AssumeRole",
    "Condition": {
      "StringEquals": { "aws:SourceAccount": "${ACCOUNT_ID}" },
      "ArnLike": { "aws:SourceArn": "arn:aws:bedrock-agentcore:${REGION}:${ACCOUNT_ID}:*" }
    }
  }]
}
JSON

# 직접 코드 배포(codeConfiguration)에서는 서비스가 이 역할로 S3 의 zip 을 읽는다.
# s3:GetObject 를 빼면 런타임이 CREATE_FAILED 로 떨어진다.
cat > "${TMP}/runtime-policy.json" <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ReadDeploymentPackage",
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:GetObjectVersion"],
      "Resource": "arn:aws:s3:::${CODE_BUCKET}/*"
    },
    {
      "Sid": "ListDeploymentBucket",
      "Effect": "Allow",
      "Action": "s3:ListBucket",
      "Resource": "arn:aws:s3:::${CODE_BUCKET}"
    },
    {
      "Sid": "Logs",
      "Effect": "Allow",
      "Action": ["logs:CreateLogGroup", "logs:DescribeLogStreams",
                 "logs:CreateLogStream", "logs:PutLogEvents"],
      "Resource": "arn:aws:logs:${REGION}:${ACCOUNT_ID}:log-group:/aws/bedrock-agentcore/runtimes/*"
    },
    {
      "Sid": "LogsDescribe",
      "Effect": "Allow",
      "Action": "logs:DescribeLogGroups",
      "Resource": "arn:aws:logs:${REGION}:${ACCOUNT_ID}:log-group:*"
    },
    {
      "Sid": "Tracing",
      "Effect": "Allow",
      "Action": ["xray:PutTraceSegments", "xray:PutTelemetryRecords",
                 "xray:GetSamplingRules", "xray:GetSamplingTargets"],
      "Resource": "*"
    },
    {
      "Sid": "Metrics",
      "Effect": "Allow",
      "Action": "cloudwatch:PutMetricData",
      "Resource": "*",
      "Condition": { "StringEquals": { "cloudwatch:namespace": "bedrock-agentcore" } }
    },
    {
      "Sid": "WorkloadIdentity",
      "Effect": "Allow",
      "Action": ["bedrock-agentcore:GetWorkloadAccessToken",
                 "bedrock-agentcore:GetWorkloadAccessTokenForJWT"],
      "Resource": [
        "arn:aws:bedrock-agentcore:${REGION}:${ACCOUNT_ID}:workload-identity-directory/default",
        "arn:aws:bedrock-agentcore:${REGION}:${ACCOUNT_ID}:workload-identity-directory/default/workload-identity/${RUNTIME_NAME}-*"
      ]
    }
  ]
}
JSON

if aws iam get-role --role-name "$RUNTIME_ROLE" >/dev/null 2>&1; then
  skip "IAM 역할 ${RUNTIME_ROLE} 이미 존재 — trust/policy 만 갱신"
  aws iam update-assume-role-policy --role-name "$RUNTIME_ROLE" \
    --policy-document "file://${TMP}/runtime-trust.json" >/dev/null
else
  aws iam create-role --role-name "$RUNTIME_ROLE" \
    --assume-role-policy-document "file://${TMP}/runtime-trust.json" \
    --description "AgentCore Runtime execution role for ${STACK}" >/dev/null
  say "생성: ${RUNTIME_ROLE}"
fi
aws iam put-role-policy --role-name "$RUNTIME_ROLE" \
  --policy-name "${STACK}-runtime-inline" \
  --policy-document "file://${TMP}/runtime-policy.json"
RUNTIME_ROLE_ARN="$(aws iam get-role --role-name "$RUNTIME_ROLE" --query Role.Arn --output text)"

# Lambda proxy 실행 역할.
cat > "${TMP}/lambda-trust.json" <<'JSON'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "lambda.amazonaws.com" },
    "Action": "sts:AssumeRole"
  }]
}
JSON

# InvokeAgentRuntime 은 런타임과 엔드포인트 두 리소스를 함께 평가한다.
# 그래서 runtime/<name>-* 와 그 하위(/*)를 모두 허용해야 한다.
# 런타임 ID 는 '<name>-<10자>' 형태이므로 와일드카드로 ARN 모양 변화에 견딘다.
# InvokeAgentRuntimeForUser 는 프록시가 X-Amzn-Bedrock-AgentCore-Runtime-User-Id
# 헤더를 붙일 때만 필요하지만, 빼두면 원인을 찾기 어려운 403 이 되므로 넣는다.
cat > "${TMP}/lambda-policy.json" <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "InvokeAndStopRuntime",
      "Effect": "Allow",
      "Action": ["bedrock-agentcore:InvokeAgentRuntime",
                 "bedrock-agentcore:InvokeAgentRuntimeForUser",
                 "bedrock-agentcore:StopRuntimeSession"],
      "Resource": [
        "arn:aws:bedrock-agentcore:${REGION}:${ACCOUNT_ID}:runtime/${RUNTIME_NAME}-*",
        "arn:aws:bedrock-agentcore:${REGION}:${ACCOUNT_ID}:runtime/${RUNTIME_NAME}-*/*"
      ]
    },
    {
      "Sid": "SessionTable",
      "Effect": "Allow",
      "Action": ["dynamodb:GetItem", "dynamodb:PutItem",
                 "dynamodb:UpdateItem", "dynamodb:DeleteItem", "dynamodb:Query"],
      "Resource": "arn:aws:dynamodb:${REGION}:${ACCOUNT_ID}:table/${TABLE_NAME}"
    },
    {
      "Sid": "PoolQueue",
      "Effect": "Allow",
      "Action": ["sqs:SendMessage", "sqs:ReceiveMessage", "sqs:DeleteMessage",
                 "sqs:GetQueueAttributes", "sqs:GetQueueUrl", "sqs:PurgeQueue"],
      "Resource": "arn:aws:sqs:${REGION}:${ACCOUNT_ID}:${QUEUE_NAME}"
    },
    {
      "Sid": "Logs",
      "Effect": "Allow",
      "Action": ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"],
      "Resource": "arn:aws:logs:${REGION}:${ACCOUNT_ID}:log-group:/aws/lambda/${LAMBDA_NAME}:*"
    }
  ]
}
JSON

if aws iam get-role --role-name "$LAMBDA_ROLE" >/dev/null 2>&1; then
  skip "IAM 역할 ${LAMBDA_ROLE} 이미 존재 — policy 만 갱신"
else
  aws iam create-role --role-name "$LAMBDA_ROLE" \
    --assume-role-policy-document "file://${TMP}/lambda-trust.json" \
    --description "Lambda proxy role for ${STACK}" >/dev/null
  say "생성: ${LAMBDA_ROLE}"
fi
aws iam put-role-policy --role-name "$LAMBDA_ROLE" \
  --policy-name "${STACK}-lambda-inline" \
  --policy-document "file://${TMP}/lambda-policy.json"
LAMBDA_ROLE_ARN="$(aws iam get-role --role-name "$LAMBDA_ROLE" --query Role.Arn --output text)"

# ── 3. S3 코드 버킷 + 에이전트 zip ───────────────────────────────────────
step "3/10 S3 코드 버킷 + agent zip 업로드"

make_bucket() {
  local b="$1"
  if aws s3api head-bucket --bucket "$b" --expected-bucket-owner "$ACCOUNT_ID" >/dev/null 2>&1; then
    skip "버킷 ${b} 이미 존재"
    return
  fi
  # us-east-1 은 LocationConstraint 를 주면 InvalidLocationConstraint 로 실패한다.
  if [[ "$REGION" == "us-east-1" ]]; then
    aws s3api create-bucket --bucket "$b" --region "$REGION" >/dev/null
  else
    aws s3api create-bucket --bucket "$b" --region "$REGION" \
      --create-bucket-configuration "LocationConstraint=${REGION}" >/dev/null
  fi
  # 새 계정은 퍼블릭 액세스 차단이 기본이지만, 명시해 두면 계정 설정에 의존하지 않는다.
  aws s3api put-public-access-block --bucket "$b" \
    --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true" >/dev/null
  say "생성: ${b}"
}
make_bucket "$CODE_BUCKET"

# AgentCore Runtime 은 zip 안 파일에 POSIX 권한 644(파일)/755(디렉터리)를 요구한다.
# 권한이 맞지 않으면 부팅 시 읽지 못한다.
rm -rf "${TMP}/agentpkg"
mkdir -p "${TMP}/agentpkg"
cp -R "${ROOT}/agent/." "${TMP}/agentpkg/"
find "${TMP}/agentpkg" -name '__pycache__' -type d -prune -exec rm -rf {} +
find "${TMP}/agentpkg" -type f -exec chmod 644 {} +
find "${TMP}/agentpkg" -type d -exec chmod 755 {} +
( cd "${TMP}/agentpkg" && zip -q -r -X "${TMP}/agent.zip" . )

# --expected-bucket-owner: 버킷 이름을 남이 선점한 경우를 조기에 잡는다.
aws s3api put-object --bucket "$CODE_BUCKET" --key "$CODE_KEY" \
  --body "${TMP}/agent.zip" --expected-bucket-owner "$ACCOUNT_ID" >/dev/null
say "업로드: s3://${CODE_BUCKET}/${CODE_KEY} ($(wc -c < "${TMP}/agent.zip" | tr -d ' ') bytes)"

# ── 4. AgentCore Runtime ─────────────────────────────────────────────────
step "4/10 AgentCore Runtime (직접 코드 배포)"

cat > "${TMP}/artifact.json" <<JSON
{
  "codeConfiguration": {
    "code": { "s3": { "bucket": "${CODE_BUCKET}", "prefix": "${CODE_KEY}" } },
    "runtime": "PYTHON_3_13",
    "entryPoint": ["main.py"]
  }
}
JSON
# idleRuntimeSessionTimeout 최소값은 60 (0 은 API 가 거부: "valid min value: 60").
# idle <= maxLifetime 이어야 한다.
cat > "${TMP}/lifecycle.json" <<JSON
{ "idleRuntimeSessionTimeout": ${IDLE_SECONDS}, "maxLifetime": ${MAX_LIFETIME} }
JSON

# 이름으로 기존 런타임을 찾는다.
RUNTIME_ID="$(aws bedrock-agentcore-control list-agent-runtimes --region "$REGION" \
  --query "agentRuntimes[?agentRuntimeName=='${RUNTIME_NAME}'].agentRuntimeId | [0]" \
  --output text 2>/dev/null || true)"
[[ "$RUNTIME_ID" == "None" ]] && RUNTIME_ID=""

if [[ -n "$RUNTIME_ID" ]]; then
  skip "런타임 ${RUNTIME_NAME} 이미 존재 (${RUNTIME_ID}) — 코드만 갱신"
  aws bedrock-agentcore-control update-agent-runtime --region "$REGION" \
    --agent-runtime-id "$RUNTIME_ID" \
    --agent-runtime-artifact "file://${TMP}/artifact.json" \
    --network-configuration 'networkMode=PUBLIC' \
    --lifecycle-configuration "file://${TMP}/lifecycle.json" \
    --environment-variables 'DEPLOY_MODE=code' \
    --role-arn "$RUNTIME_ROLE_ARN" >/dev/null
else
  # IAM 역할 생성 직후에는 전파가 안 끝나 AccessDenied 가 날 수 있다. 재시도한다.
  for attempt in 1 2 3 4 5 6; do
    if aws bedrock-agentcore-control create-agent-runtime --region "$REGION" \
         --agent-runtime-name "$RUNTIME_NAME" \
         --agent-runtime-artifact "file://${TMP}/artifact.json" \
         --network-configuration 'networkMode=PUBLIC' \
         --lifecycle-configuration "file://${TMP}/lifecycle.json" \
         --environment-variables 'DEPLOY_MODE=code' \
         --role-arn "$RUNTIME_ROLE_ARN" > "${TMP}/runtime.json" 2>"${TMP}/runtime.err"; then
      break
    fi
    if [[ $attempt -eq 6 ]]; then
      # mask 를 거친다 — AWS CLI 오류 문자열에 역할 ARN(계정 ID 포함)이 들어간다.
      mask "$(cat "${TMP}/runtime.err")" >&2; echo >&2
      die "create-agent-runtime 실패"
    fi
    say "IAM 전파 대기 후 재시도 (${attempt}/5)…"
    sleep 10
  done
  RUNTIME_ID="$(jq -r .agentRuntimeId "${TMP}/runtime.json")"
  say "생성: ${RUNTIME_NAME} (${RUNTIME_ID})"
fi

# READY 폴링. 직접 코드 배포는 의존성 설치 때문에 수 분 걸릴 수 있다.
say "READY 대기…"
for i in $(seq 1 120); do
  STATUS="$(aws bedrock-agentcore-control get-agent-runtime --region "$REGION" \
    --agent-runtime-id "$RUNTIME_ID" --query status --output text)"
  case "$STATUS" in
    READY) break ;;
    CREATE_FAILED|UPDATE_FAILED)
      mask "$(aws bedrock-agentcore-control get-agent-runtime --region "$REGION" \
        --agent-runtime-id "$RUNTIME_ID" --query failureReason --output text)" >&2; echo >&2
      die "런타임이 ${STATUS} 상태다." ;;
  esac
  [[ $i -eq 120 ]] && die "10분 안에 READY 가 되지 않았다 (마지막 상태: ${STATUS})."
  sleep 5
done

# ARN 은 응답에서 캡처한다. 직접 조립하면 ARN 모양이 바뀔 때 깨진다.
RUNTIME_ARN="$(aws bedrock-agentcore-control get-agent-runtime --region "$REGION" \
  --agent-runtime-id "$RUNTIME_ID" --query agentRuntimeArn --output text)"
say "status=READY"
say "arn=$(mask "$RUNTIME_ARN")"

# ── 5. DynamoDB (세션 매핑, TTL) ─────────────────────────────────────────
step "5/10 DynamoDB 테이블 + TTL"

if aws dynamodb describe-table --region "$REGION" --table-name "$TABLE_NAME" >/dev/null 2>&1; then
  skip "테이블 ${TABLE_NAME} 이미 존재"
else
  aws dynamodb create-table --region "$REGION" \
    --table-name "$TABLE_NAME" \
    --attribute-definitions 'AttributeName=pk,AttributeType=S' \
    --key-schema 'AttributeName=pk,KeyType=HASH' \
    --billing-mode PAY_PER_REQUEST >/dev/null
  say "생성: ${TABLE_NAME} (pk 해시키, PAY_PER_REQUEST)"
fi
aws dynamodb wait table-exists --region "$REGION" --table-name "$TABLE_NAME"

# 방식 2(store)의 핵심. TTL 이 만료를 판단하므로 클라이언트는 시간 계산을 안 한다.
# 같은 테이블에 UpdateTimeToLive 를 1시간 안에 두 번 부르면 ValidationException 이
# 나므로, 이미 켜져 있으면 건드리지 않는다.
TTL_STATUS="$(aws dynamodb describe-time-to-live --region "$REGION" \
  --table-name "$TABLE_NAME" \
  --query TimeToLiveDescription.TimeToLiveStatus --output text)"
if [[ "$TTL_STATUS" == "ENABLED" || "$TTL_STATUS" == "ENABLING" ]]; then
  skip "TTL 이미 ${TTL_STATUS}"
else
  aws dynamodb update-time-to-live --region "$REGION" \
    --table-name "$TABLE_NAME" \
    --time-to-live-specification 'Enabled=true,AttributeName=ttl' >/dev/null
  say "TTL 활성화 (AttributeName=ttl)"
fi

# ── 6. SQS FIFO (예열 uuid 재고) ─────────────────────────────────────────
step "6/10 SQS FIFO 큐"

# ⚠️ MessageRetentionPeriod 는 microVM 최대 수명(MAX_LIFETIME=8시간) 이상이어야 한다.
# 짧게 잡으면 SQS 가 재고 메시지를 그 시각에 하드 삭제해버려서,
#   - heartbeat 가 살려둔 세션의 uuid 가 큐에서 사라지고(세션은 idle 만료까지 과금 누수),
#   - 서버의 7시간 rolling replacement 판정(MAX_VM_AGE_SEC)에 도달하는 메시지가 아예
#     없어져 그 분기가 죽은 코드가 된다.
# 8시간으로 두면 "8시간에 강제 종료되기 전 7시간에 교체" 설계가 실제로 실행된다.
QUEUE_RETENTION="${QUEUE_RETENTION:-$MAX_LIFETIME}"
QUEUE_ATTRS="VisibilityTimeout=30,MessageRetentionPeriod=${QUEUE_RETENTION}"

if QUEUE_URL="$(aws sqs get-queue-url --region "$REGION" --queue-name "$QUEUE_NAME" \
                  --query QueueUrl --output text 2>/dev/null)"; then
  skip "큐 ${QUEUE_NAME} 이미 존재 — 보관 기간만 갱신"
  # 기존 큐(예: 1시간 보관으로 만들어진 큐)도 재실행으로 고쳐진다.
  # FifoQueue / ContentBasedDeduplication 은 여기서 다시 보내지 않는다
  # (FifoQueue 는 생성 후 변경 불가라 InvalidAttributeName 이 난다).
  aws sqs set-queue-attributes --region "$REGION" --queue-url "$QUEUE_URL" \
    --attributes "$QUEUE_ATTRS" >/dev/null
else
  # ContentBasedDeduplication=true 이면 MessageDeduplicationId 를 매번 만들지 않아도 된다.
  # 단, 같은 uuid 를 5분 안에 두 번 넣으면 중복 제거로 조용히 사라진다(예열 재고 특성상 OK).
  QUEUE_URL="$(aws sqs create-queue --region "$REGION" --queue-name "$QUEUE_NAME" \
    --attributes "FifoQueue=true,ContentBasedDeduplication=true,${QUEUE_ATTRS}" \
    --query QueueUrl --output text)"
  say "생성: ${QUEUE_NAME}"
fi
say "queue=$(mask "$QUEUE_URL")"
say "보관 기간: ${QUEUE_RETENTION}초 (microVM 최대 수명 ${MAX_LIFETIME}초 이상이어야 한다)"

# ── 7. Lambda + API Gateway HTTP API ─────────────────────────────────────
step "7/10 Lambda proxy + API Gateway HTTP API"

rm -rf "${TMP}/lambdapkg"
mkdir -p "${TMP}/lambdapkg"
cp -R "${ROOT}/server/." "${TMP}/lambdapkg/"
find "${TMP}/lambdapkg" -name '__pycache__' -type d -prune -exec rm -rf {} +
find "${TMP}/lambdapkg" -type f -exec chmod 644 {} +
find "${TMP}/lambdapkg" -type d -exec chmod 755 {} +
( cd "${TMP}/lambdapkg" && zip -q -r -X "${TMP}/lambda.zip" . )

# ⚠️ AWS_REGION 은 Lambda 예약 환경변수라 직접 설정하면 InvalidParameterValueException
# 이 난다. 런타임이 자동으로 넣어주므로 코드에서 os.environ["AWS_REGION"] 으로 읽으면 된다.
# RUNTIME_REGION 은 예약어가 아니므로 명시적으로 넣는다 — 코드가 이 값을 우선 읽고,
# 없으면 AWS_REGION 으로 폴백한다. --environment 는 Variables 맵 전체를 교체하므로
# 코드가 읽는 변수를 여기서 하나라도 빼면 모듈 로드가 실패해 전 라우트가 502 가 된다.
LAMBDA_ENV="$(jq -n \
  --arg runtime_arn   "$RUNTIME_ARN" \
  --arg region        "$REGION" \
  --arg table         "$TABLE_NAME" \
  --arg queue         "$QUEUE_URL" \
  --arg target        "$POOL_TARGET" \
  --arg idle          "$IDLE_SECONDS" \
  --arg warm          "$WARM_WINDOW_SEC" \
  --arg cold          "$COLD_UPTIME_MS" \
  '{Variables:{
      RUNTIME_ARN: $runtime_arn,
      RUNTIME_REGION: $region,
      TABLE_NAME: $table,
      QUEUE_URL: $queue,
      POOL_TARGET: $target,
      IDLE_SECONDS: $idle,
      WARM_WINDOW_SEC: $warm,
      COLD_UPTIME_MS: $cold,
      AGENT_QUALIFIER: "DEFAULT"
    }}')"
printf '%s' "$LAMBDA_ENV" > "${TMP}/lambda-env.json"

if aws lambda get-function --region "$REGION" --function-name "$LAMBDA_NAME" >/dev/null 2>&1; then
  skip "Lambda ${LAMBDA_NAME} 이미 존재 — 코드·설정 갱신"
  aws lambda update-function-code --region "$REGION" \
    --function-name "$LAMBDA_NAME" --zip-file "fileb://${TMP}/lambda.zip" >/dev/null
  aws lambda wait function-updated-v2 --region "$REGION" --function-name "$LAMBDA_NAME"
  aws lambda update-function-configuration --region "$REGION" \
    --function-name "$LAMBDA_NAME" \
    --handler "$LAMBDA_HANDLER" --timeout 60 --memory-size 512 \
    --environment "file://${TMP}/lambda-env.json" >/dev/null
else
  # 역할 전파가 끝나기 전에는 "The role defined for the function cannot be assumed"
  # 가 난다. 재시도로 흡수한다.
  for attempt in 1 2 3 4 5 6; do
    if aws lambda create-function --region "$REGION" \
         --function-name "$LAMBDA_NAME" \
         --runtime python3.13 --architectures arm64 \
         --role "$LAMBDA_ROLE_ARN" \
         --handler "$LAMBDA_HANDLER" \
         --timeout 60 --memory-size 512 \
         --zip-file "fileb://${TMP}/lambda.zip" \
         --environment "file://${TMP}/lambda-env.json" \
         --description "AgentCore warm pool demo proxy (${STACK})" \
         > /dev/null 2>"${TMP}/lambda.err"; then
      say "생성: ${LAMBDA_NAME}"
      break
    fi
    if [[ $attempt -eq 6 ]]; then
      mask "$(cat "${TMP}/lambda.err")" >&2; echo >&2
      die "create-function 실패"
    fi
    say "IAM 전파 대기 후 재시도 (${attempt}/5)…"
    sleep 10
  done
fi
aws lambda wait function-active-v2 --region "$REGION" --function-name "$LAMBDA_NAME"
LAMBDA_ARN="$(aws lambda get-function --region "$REGION" --function-name "$LAMBDA_NAME" \
  --query Configuration.FunctionArn --output text)"

# HTTP API 는 quick create(--target)로 만든다.
#   → AWS_PROXY 통합 + $default 캐치올 라우트 + 자동 배포되는 $default 스테이지
# $default 스테이지는 URL 에 스테이지 접두사가 붙지 않아서 CloudFront 뒤에 붙이기 쉽다.
API_ID="$(aws apigatewayv2 get-apis --region "$REGION" \
  --query "Items[?Name=='${API_NAME}'].ApiId | [0]" --output text)"
[[ "$API_ID" == "None" ]] && API_ID=""

if [[ -n "$API_ID" ]]; then
  skip "API ${API_NAME} 이미 존재 (${API_ID})"
else
  API_ID="$(aws apigatewayv2 create-api --region "$REGION" \
    --name "$API_NAME" --protocol-type HTTP \
    --target "$LAMBDA_ARN" \
    --query ApiId --output text)"
  say "생성: ${API_NAME} (${API_ID})"
fi
API_ENDPOINT="https://${API_ID}.execute-api.${REGION}.amazonaws.com"

# quick create 는 Lambda 리소스 정책을 만들어 주지 않는다. 직접 넣어야 한다.
# StatementId 가 이미 있으면 ResourceConflictException 이므로 존재를 먼저 확인한다.
PERM_SID="${STACK}-apigw-invoke"
if aws lambda get-policy --region "$REGION" --function-name "$LAMBDA_NAME" \
     --query Policy --output text 2>/dev/null | grep -q "\"${PERM_SID}\""; then
  skip "Lambda 호출 권한 ${PERM_SID} 이미 존재"
else
  aws lambda add-permission --region "$REGION" \
    --function-name "$LAMBDA_NAME" \
    --statement-id "$PERM_SID" \
    --action lambda:InvokeFunction \
    --principal apigateway.amazonaws.com \
    --source-arn "arn:aws:execute-api:${REGION}:${ACCOUNT_ID}:${API_ID}/*/*" >/dev/null
  say "권한 부여: apigateway.amazonaws.com → ${LAMBDA_NAME}"
fi
say "api=${API_ENDPOINT}"

# ── 8. heartbeat 스케줄러 (EventBridge) ──────────────────────────────────
step "8/11 heartbeat 스케줄러 (EventBridge rule)"

# ⚠️ 이것이 없으면 웜풀은 IDLE_SECONDS 뒤에 스스로 비워지고 회복하지 않는다.
# 큐에 담긴 uuid 는 그 자체로는 아무 일도 하지 않으므로, 마지막 예열 핑으로부터
# idle 타임아웃이 지나면 microVM 이 죽고 큐에는 껍데기 uuid 만 남는다. 그리고
# 죽은 uuid 를 pop 하는 것은 에러가 아니라 HTTP 200 + 콜드스타트이므로 조용히 썩는다.
# UI 의 'heartbeat 실행' 버튼은 시연용이다 — 사람이 안 누르면 아무도 핑하지 않는다.
#
# 주기는 IDLE_SECONDS 보다 충분히 짧아야 한다. 핑 실패·재시도 시간까지 흡수하도록
# idle 의 1/3 로 잡는다 (idle=900 → 5분). rate() 최소 단위가 1분이라 하한을 둔다.
HEARTBEAT_MINUTES="${HEARTBEAT_MINUTES:-$(( IDLE_SECONDS / 180 ))}"
if [[ "$HEARTBEAT_MINUTES" -lt 1 ]]; then HEARTBEAT_MINUTES=1; fi
if [[ $(( HEARTBEAT_MINUTES * 60 * 3 )) -gt "$IDLE_SECONDS" ]]; then
  say "경고: heartbeat 주기 ${HEARTBEAT_MINUTES}분이 idle ${IDLE_SECONDS}초의 1/3 보다 길다."
fi
# rate(1 minute) 는 단수, 2 이상은 복수여야 한다.
if [[ "$HEARTBEAT_MINUTES" -eq 1 ]]; then
  HEARTBEAT_RATE="rate(1 minute)"
else
  HEARTBEAT_RATE="rate(${HEARTBEAT_MINUTES} minutes)"
fi

# _heartbeat() 는 1회 호출에 receive 1회(최대 10건)만 처리한다 — 환원한 메시지를
# 같은 실행에서 다시 집어 재고 전체가 잠기는 버그를 피하기 위한 설계다.
# 그래서 재고가 10개를 넘으면 타깃을 여러 개 두어 병렬로 호출한다.
HEARTBEAT_FANOUT=$(( (POOL_TARGET + 9) / 10 ))
if [[ "$HEARTBEAT_FANOUT" -lt 1 ]]; then HEARTBEAT_FANOUT=1; fi
if [[ "$HEARTBEAT_FANOUT" -gt 5 ]]; then HEARTBEAT_FANOUT=5; fi

RULE_NAME="${STACK}-heartbeat"
RULE_ARN="$(aws events put-rule --region "$REGION" \
  --name "$RULE_NAME" \
  --schedule-expression "$HEARTBEAT_RATE" \
  --state ENABLED \
  --description "AgentCore warm pool heartbeat for ${STACK} (idle=${IDLE_SECONDS}s)" \
  --query RuleArn --output text)"
say "규칙: ${RULE_NAME} — ${HEARTBEAT_RATE}"

# EventBridge 는 Lambda 를 직접 호출하므로 API Gateway 를 거치지 않는다.
# 핸들러는 rawPath 로 라우팅하므로, HTTP API payload v2.0 모양을 그대로 흉내 낸 이벤트를
# --input 으로 넣으면 코드를 고치지 않고 /api/pool/heartbeat 경로를 탄다.
#
# ⚠️ 한계: 핸들러는 실패를 예외로 던지지 않고 statusCode 500 을 담은 dict 로 돌려준다.
# EventBridge 는 반환값을 보지 않으므로, 핑이 계속 실패해도 Lambda Errors 지표는
# 0 이고 규칙은 성공으로 집계된다. 즉 이 규칙만으로는 "재고가 썩는 것"을 감지할 수 없다.
# 운영에서는 /api/pool 의 staleRisk 나 pinged 값에 알람을 걸어야 한다.
HEARTBEAT_INPUT="$(jq -nc '{
  rawPath: "/api/pool/heartbeat",
  requestContext: { http: { method: "POST" } },
  body: "{}"
}')"

# 타깃 Id 는 규칙 안에서만 유일하면 된다. put-targets 는 같은 Id 를 덮어쓰므로 idempotent.
TARGETS="$(jq -nc \
  --arg arn "$LAMBDA_ARN" \
  --arg input "$HEARTBEAT_INPUT" \
  --argjson n "$HEARTBEAT_FANOUT" \
  '[range(1; $n + 1) | {Id: ("hb-" + (. | tostring)), Arn: $arn, Input: $input}]')"
aws events put-targets --region "$REGION" --rule "$RULE_NAME" \
  --targets "$TARGETS" >/dev/null
say "타깃: ${LAMBDA_NAME} × ${HEARTBEAT_FANOUT} (재고 ${POOL_TARGET}개 / 1회 최대 10건)"

# 규칙이 Lambda 를 호출할 권한. SourceArn 을 규칙 ARN 으로 좁힌다.
HB_PERM_SID="${STACK}-events-invoke"
if aws lambda get-policy --region "$REGION" --function-name "$LAMBDA_NAME" \
     --query Policy --output text 2>/dev/null | grep -q "\"${HB_PERM_SID}\""; then
  skip "Lambda 호출 권한 ${HB_PERM_SID} 이미 존재"
else
  aws lambda add-permission --region "$REGION" \
    --function-name "$LAMBDA_NAME" \
    --statement-id "$HB_PERM_SID" \
    --action lambda:InvokeFunction \
    --principal events.amazonaws.com \
    --source-arn "$RULE_ARN" >/dev/null
  say "권한 부여: events.amazonaws.com → ${LAMBDA_NAME}"
fi

# ── 9. S3 웹 버킷 + CloudFront ───────────────────────────────────────────
step "9/11 정적 웹 버킷 + CloudFront"

make_bucket "$WEB_BUCKET"
aws s3api put-object --bucket "$WEB_BUCKET" --key index.html \
  --body "${ROOT}/web/index.html" \
  --content-type 'text/html; charset=utf-8' \
  --cache-control 'no-cache' \
  --expected-bucket-owner "$ACCOUNT_ID" >/dev/null
say "업로드: index.html → ${WEB_BUCKET}"

# CloudFront 는 글로벌 서비스다. 리전 리소스(ap-northeast-2 의 S3/API GW)를 오리진으로
# 쓰는 것은 문제없지만, CLI 호출은 글로벌 엔드포인트로 나가도록 us-east-1 을 지정한다.
CF_REGION="us-east-1"

OAC_ID="$(aws cloudfront list-origin-access-controls --region "$CF_REGION" \
  --query "OriginAccessControlList.Items[?Name=='${OAC_NAME}'].Id | [0]" --output text)"
[[ "$OAC_ID" == "None" ]] && OAC_ID=""
if [[ -n "$OAC_ID" ]]; then
  skip "OAC ${OAC_NAME} 이미 존재 (${OAC_ID})"
else
  OAC_ID="$(aws cloudfront create-origin-access-control --region "$CF_REGION" \
    --origin-access-control-config "$(jq -n --arg n "$OAC_NAME" '{
        Name: $n,
        Description: "OAC for acwp demo web bucket",
        SigningProtocol: "sigv4",
        SigningBehavior: "always",
        OriginAccessControlOriginType: "s3"
      }')" \
    --query OriginAccessControl.Id --output text)"
  say "생성: OAC ${OAC_ID}"
fi

DIST_ID="$(aws cloudfront list-distributions --region "$CF_REGION" \
  --query "DistributionList.Items[?Comment=='${CF_COMMENT}'].Id | [0]" --output text 2>/dev/null || true)"
[[ "$DIST_ID" == "None" ]] && DIST_ID=""

if [[ -n "$DIST_ID" ]]; then
  skip "CloudFront 배포 이미 존재 (${DIST_ID})"
else
  # 캐시/오리진 요청 정책은 AWS 관리형 정책 ID (계정과 무관한 고정 값).
  CACHE_OPTIMIZED="658327ea-f89d-4fab-a63d-7e88639e58f6"   # Managed-CachingOptimized
  CACHE_DISABLED="4135ea2d-6df8-44a3-9df3-4b5a84be39ad"    # Managed-CachingDisabled
  # ⚠️ Managed-AllViewerExceptHostHeader 를 쓴다.
  # Managed-AllViewer 처럼 Host 헤더까지 넘기면 CloudFront 의 Host(도메인)가 오리진에
  # 전달되어 API Gateway 가 자기 호스트로 인식하지 못하고 403(SigV4/호스트 불일치)을
  # 낸다. 이 정책은 Host 만 빼고 나머지 헤더·쿠키·쿼리를 모두 전달한다.
  ORP_ALL_EXCEPT_HOST="b689b0a8-53d0-40ab-baf2-68738e2966ac"

  cat > "${TMP}/dist.json" <<JSON
{
  "CallerReference": "${STACK}-$(date +%s)",
  "Comment": "${CF_COMMENT}",
  "Enabled": true,
  "DefaultRootObject": "index.html",
  "PriceClass": "PriceClass_200",
  "HttpVersion": "http2and3",
  "Origins": {
    "Quantity": 2,
    "Items": [
      {
        "Id": "web-s3",
        "DomainName": "${WEB_BUCKET}.s3.${REGION}.amazonaws.com",
        "OriginPath": "",
        "CustomHeaders": { "Quantity": 0 },
        "S3OriginConfig": { "OriginAccessIdentity": "" },
        "OriginAccessControlId": "${OAC_ID}",
        "ConnectionAttempts": 3,
        "ConnectionTimeout": 10
      },
      {
        "Id": "api-gw",
        "DomainName": "${API_ID}.execute-api.${REGION}.amazonaws.com",
        "OriginPath": "",
        "CustomHeaders": { "Quantity": 0 },
        "CustomOriginConfig": {
          "HTTPPort": 80,
          "HTTPSPort": 443,
          "OriginProtocolPolicy": "https-only",
          "OriginSslProtocols": { "Quantity": 1, "Items": ["TLSv1.2"] },
          "OriginReadTimeout": 60,
          "OriginKeepaliveTimeout": 5
        },
        "ConnectionAttempts": 3,
        "ConnectionTimeout": 10
      }
    ]
  },
  "DefaultCacheBehavior": {
    "TargetOriginId": "web-s3",
    "ViewerProtocolPolicy": "redirect-to-https",
    "AllowedMethods": {
      "Quantity": 2, "Items": ["GET", "HEAD"],
      "CachedMethods": { "Quantity": 2, "Items": ["GET", "HEAD"] }
    },
    "Compress": true,
    "CachePolicyId": "${CACHE_OPTIMIZED}"
  },
  "CacheBehaviors": {
    "Quantity": 1,
    "Items": [
      {
        "PathPattern": "/api/*",
        "TargetOriginId": "api-gw",
        "ViewerProtocolPolicy": "https-only",
        "AllowedMethods": {
          "Quantity": 7,
          "Items": ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"],
          "CachedMethods": { "Quantity": 2, "Items": ["GET", "HEAD"] }
        },
        "Compress": true,
        "CachePolicyId": "${CACHE_DISABLED}",
        "OriginRequestPolicyId": "${ORP_ALL_EXCEPT_HOST}"
      }
    ]
  }
}
JSON
  DIST_ID="$(aws cloudfront create-distribution --region "$CF_REGION" \
    --distribution-config "file://${TMP}/dist.json" \
    --query Distribution.Id --output text)"
  say "생성: CloudFront ${DIST_ID}"
fi

CF_DOMAIN="$(aws cloudfront get-distribution --region "$CF_REGION" --id "$DIST_ID" \
  --query Distribution.DomainName --output text)"

# 버킷 정책은 배포 ID 를 알아야 쓸 수 있어서(순환 의존) 배포 생성 뒤에 넣는다.
# OAC 는 이 서비스 프린시펄 + SourceArn 조합으로만 읽게 잠근다.
aws s3api put-bucket-policy --bucket "$WEB_BUCKET" \
  --expected-bucket-owner "$ACCOUNT_ID" \
  --policy "$(jq -n \
      --arg bucket "$WEB_BUCKET" \
      --arg dist "arn:aws:cloudfront::${ACCOUNT_ID}:distribution/${DIST_ID}" \
      '{Version:"2012-10-17",Statement:[{
          Sid:"AllowCloudFrontOAC",
          Effect:"Allow",
          Principal:{Service:"cloudfront.amazonaws.com"},
          Action:"s3:GetObject",
          Resource:("arn:aws:s3:::" + $bucket + "/*"),
          Condition:{StringEquals:{"AWS:SourceArn":$dist}}
        }]}')" >/dev/null
say "버킷 정책: ${WEB_BUCKET} ← CloudFront OAC 전용"

# ── 10. 초기 풀 보충 ─────────────────────────────────────────────────────
step "10/11 초기 웜풀 보충 (target=${POOL_TARGET})"

# CloudFront 배포 완료를 기다리지 않고 API Gateway 를 직접 호출한다.
# (배포 전파는 수 분 걸리지만 예열은 지금 시작해야 의미가 있다)
REFILL_CODE="$(curl -sS -o "${TMP}/refill.json" -w '%{http_code}' \
  -X POST "${API_ENDPOINT}/api/pool/refill" \
  -H 'Content-Type: application/json' \
  -d "{\"count\": ${POOL_TARGET}}" --max-time 120 || echo "000")"
if [[ "$REFILL_CODE" == "200" ]]; then
  say "refill 응답: $(jq -c . "${TMP}/refill.json" 2>/dev/null || cat "${TMP}/refill.json")"
  if curl -sS -o "${TMP}/pool.json" --max-time 30 "${API_ENDPOINT}/api/pool" >/dev/null 2>&1; then
    say "pool depth: $(jq -r '.depth // "?"' "${TMP}/pool.json" 2>/dev/null || echo '?')"
  fi
elif [[ "$REFILL_CODE" =~ ^5 ]]; then
  # ⚠️ 5xx 는 프록시 자체가 깨진 것이다. 특히 502 Runtime.ImportModuleError 는
  # 모듈 로드 실패(환경변수 누락 등)이므로 /api/chat 을 포함한 **전 라우트**가 죽는다.
  # 이걸 경고로 넘기고 "완료"를 찍으면 운영자가 정상 배포로 믿게 되므로 여기서 죽인다.
  # 인프라는 이미 만들어졌고 이 스크립트는 idempotent 하니, 고친 뒤 그대로 재실행하면 된다.
  printf '    \033[31mrefill 이 HTTP %s 로 응답했다 — 프록시가 깨졌다.\033[0m\n' "$REFILL_CODE"
  [[ -s "${TMP}/refill.json" ]] && printf '    본문: %s\n' "$(mask "$(head -c 400 "${TMP}/refill.json")")"
  printf '    로그를 먼저 보라:\n'
  printf '      aws logs tail /aws/lambda/%s --region %s --since 5m\n' "$LAMBDA_NAME" "$REGION"
  die "스모크 테스트 실패. 인프라는 생성되었으나 API 가 동작하지 않는다(배포 미완료)."
else
  # 네트워크·타임아웃(000)이나 4xx 는 전파 지연 등 일시적일 수 있다. 경고만 남긴다.
  printf '    \033[33m경고: refill 이 HTTP %s 로 응답했다. 인프라는 생성되었으니\n' "$REFILL_CODE"
  printf "           UI 의 'refill' 버튼이나 아래 명령으로 다시 시도하라.\033[0m\n"
  printf '           curl -X POST %s/api/pool/refill -d %s\n' \
    "${API_ENDPOINT}" "'{\"count\":${POOL_TARGET}}'"
  [[ -s "${TMP}/refill.json" ]] && printf '           본문: %s\n' "$(mask "$(head -c 400 "${TMP}/refill.json")")"
fi

# ── 11. 결과 ─────────────────────────────────────────────────────────────
step "11/11 완료"
cat <<TXT

  ┌─────────────────────────────────────────────────────────────
  │  데모 URL:  https://${CF_DOMAIN}
  └─────────────────────────────────────────────────────────────

  CloudFront 는 방금 만들었다면 전파에 보통 3~10분 걸린다. 403/404 가 나오면
  잠시 뒤 새로고침하라. 그동안 API 는 아래 주소로 바로 쓸 수 있다.

    API   : ${API_ENDPOINT}
    런타임: ${RUNTIME_NAME} (${RUNTIME_ID})
    테이블: ${TABLE_NAME}   (TTL: ttl)
    큐    : ${QUEUE_NAME}   (보관 ${QUEUE_RETENTION}초)
    핑    : ${RULE_NAME}  ${HEARTBEAT_RATE} × ${HEARTBEAT_FANOUT}  (idle=${IDLE_SECONDS}초)
    배포  : CloudFront ${DIST_ID}

  ⚠️ heartbeat 규칙이 재고를 계속 살려두므로 아무도 쓰지 않아도 microVM 메모리가
     과금된다. 이것이 웜풀의 비용이다 — 재고가 썩는 것을 막는 대가다.
     비용을 멈추려면 규칙을 끄거나(아래) teardown 하라.

    aws events disable-rule --region ${REGION} --name ${RULE_NAME}

  ⚠️ 이 API 는 인증이 없다(데모 목적). 공개 URL 을 아무에게나 주면 그 사람이
     당신 계정에서 AgentCore 세션을 띄우게 된다. 실습이 끝나면 반드시 정리하라.

    ./scripts/teardown.sh

TXT
