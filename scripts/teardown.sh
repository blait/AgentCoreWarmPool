#!/usr/bin/env bash
#
# AgentCore Runtime 웜풀 GUI 데모 — 전체 스택 삭제
#
# deploy.sh 가 만든 것을 역순으로 지운다.
#   CloudFront → 웹 버킷 → API GW → heartbeat 규칙 → Lambda → SQS → DynamoDB
#   → AgentCore Runtime → 코드 버킷 → IAM 역할
#
# 사용법:
#   ./scripts/teardown.sh          # 대상 목록을 보여주고 확인을 받는다
#   ./scripts/teardown.sh --yes    # 확인 없이 삭제
#   REGION=us-west-2 STACK=mydemo ./scripts/teardown.sh --yes
#
# ⚠️ CloudFront 배포는 'disable → 전파 완료 대기 → 삭제' 3단계다. 전파 대기가
#    보통 5~15분 걸리므로 이 스크립트에서 가장 오래 걸리는 구간이다.
#    기다리지 않으려면 --skip-cloudfront 로 배포만 남길 수 있다(비용은 거의 0).
#
set -euo pipefail

REGION="${REGION:-ap-northeast-2}"
STACK="${STACK:-acwp}"
CF_REGION="us-east-1"        # CloudFront 는 글로벌 서비스 — CLI 는 이 엔드포인트로

ASSUME_YES=0
SKIP_CF=0
for arg in "$@"; do
  case "$arg" in
    --yes|-y)         ASSUME_YES=1 ;;
    --skip-cloudfront) SKIP_CF=1 ;;
    -h|--help)
      sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) printf 'ERROR: 알 수 없는 옵션: %s (--yes | --skip-cloudfront)\n' "$arg" >&2; exit 2 ;;
  esac
done

ACCOUNT_ID=""
mask() {
  if [[ -n "$ACCOUNT_ID" ]]; then printf '%s' "$*" | sed "s/${ACCOUNT_ID}/<account>/g"
  else printf '%s' "$*"; fi
}
step() { printf '\n\033[1m==> %s\033[0m\n' "$(mask "$*")"; }
say()  { printf '    %s\n' "$(mask "$*")"; }
skip() { printf '    (없음) %s\n' "$(mask "$*")"; }
warn() { printf '    \033[33m경고: %s\033[0m\n' "$(mask "$*")"; }
die()  { printf '\n\033[31mERROR: %s\033[0m\n' "$(mask "$*")" >&2; exit 1; }

for bin in aws jq; do
  command -v "$bin" >/dev/null 2>&1 || die "'${bin}' 가 필요하다."
done
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)" \
  || die "AWS 자격증명을 확인할 수 없다."

# deploy.sh 와 같은 규칙으로 이름을 재구성한다(계정 ID 는 조회한 값을 쓴다).
RUNTIME_NAME="${RUNTIME_NAME:-$(printf '%s' "${STACK}_runtime" | tr '-' '_')}"
CODE_BUCKET="${STACK}-code-${ACCOUNT_ID}-${REGION}"
WEB_BUCKET="${STACK}-web-${ACCOUNT_ID}-${REGION}"
RUNTIME_ROLE="${STACK}-runtime-exec"
LAMBDA_ROLE="${STACK}-lambda-exec"
TABLE_NAME="${STACK}-sessions"
QUEUE_NAME="${STACK}-pool.fifo"
LAMBDA_NAME="${STACK}-proxy"
API_NAME="${STACK}-api"
RULE_NAME="${STACK}-heartbeat"
OAC_NAME="${STACK}-web-oac"
CF_COMMENT="${STACK} agentcore warm pool demo"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ── 1. 실제로 존재하는 것만 목록에 올린다 ────────────────────────────────
step "삭제 대상 확인 (region=${REGION}, stack=${STACK})"

FOUND=()
add() { FOUND+=("$1"); }

DIST_ID="$(aws cloudfront list-distributions --region "$CF_REGION" \
  --query "DistributionList.Items[?Comment=='${CF_COMMENT}'].Id | [0]" --output text 2>/dev/null || true)"
[[ "$DIST_ID" == "None" ]] && DIST_ID=""
[[ -n "$DIST_ID" ]] && add "CloudFront 배포        ${DIST_ID}"

OAC_ID="$(aws cloudfront list-origin-access-controls --region "$CF_REGION" \
  --query "OriginAccessControlList.Items[?Name=='${OAC_NAME}'].Id | [0]" --output text 2>/dev/null || true)"
[[ "$OAC_ID" == "None" ]] && OAC_ID=""
[[ -n "$OAC_ID" ]] && add "CloudFront OAC         ${OAC_NAME} (${OAC_ID})"

HAS_WEB_BUCKET=0
if aws s3api head-bucket --bucket "$WEB_BUCKET" --expected-bucket-owner "$ACCOUNT_ID" >/dev/null 2>&1; then
  HAS_WEB_BUCKET=1; add "S3 웹 버킷             ${WEB_BUCKET} (내용 전부)"
fi

API_ID="$(aws apigatewayv2 get-apis --region "$REGION" \
  --query "Items[?Name=='${API_NAME}'].ApiId | [0]" --output text 2>/dev/null || true)"
[[ "$API_ID" == "None" ]] && API_ID=""
[[ -n "$API_ID" ]] && add "API Gateway HTTP API   ${API_NAME} (${API_ID})"

HAS_RULE=0
if aws events describe-rule --region "$REGION" --name "$RULE_NAME" >/dev/null 2>&1; then
  HAS_RULE=1; add "EventBridge 규칙       ${RULE_NAME} (heartbeat)"
fi

HAS_LAMBDA=0
if aws lambda get-function --region "$REGION" --function-name "$LAMBDA_NAME" >/dev/null 2>&1; then
  HAS_LAMBDA=1; add "Lambda 함수            ${LAMBDA_NAME}"
fi

QUEUE_URL="$(aws sqs get-queue-url --region "$REGION" --queue-name "$QUEUE_NAME" \
  --query QueueUrl --output text 2>/dev/null || true)"
[[ -n "$QUEUE_URL" ]] && add "SQS FIFO 큐            ${QUEUE_NAME}"

HAS_TABLE=0
if aws dynamodb describe-table --region "$REGION" --table-name "$TABLE_NAME" >/dev/null 2>&1; then
  HAS_TABLE=1; add "DynamoDB 테이블        ${TABLE_NAME} (항목 전부)"
fi

RUNTIME_ID="$(aws bedrock-agentcore-control list-agent-runtimes --region "$REGION" \
  --query "agentRuntimes[?agentRuntimeName=='${RUNTIME_NAME}'].agentRuntimeId | [0]" \
  --output text 2>/dev/null || true)"
[[ "$RUNTIME_ID" == "None" ]] && RUNTIME_ID=""
[[ -n "$RUNTIME_ID" ]] && add "AgentCore Runtime      ${RUNTIME_NAME} (${RUNTIME_ID})"

HAS_CODE_BUCKET=0
if aws s3api head-bucket --bucket "$CODE_BUCKET" --expected-bucket-owner "$ACCOUNT_ID" >/dev/null 2>&1; then
  HAS_CODE_BUCKET=1; add "S3 코드 버킷           ${CODE_BUCKET} (내용 전부)"
fi

HAS_RUNTIME_ROLE=0
if aws iam get-role --role-name "$RUNTIME_ROLE" >/dev/null 2>&1; then
  HAS_RUNTIME_ROLE=1; add "IAM 역할               ${RUNTIME_ROLE}"
fi
HAS_LAMBDA_ROLE=0
if aws iam get-role --role-name "$LAMBDA_ROLE" >/dev/null 2>&1; then
  HAS_LAMBDA_ROLE=1; add "IAM 역할               ${LAMBDA_ROLE}"
fi

if [[ ${#FOUND[@]} -eq 0 ]]; then
  say "지울 것이 없다. 이미 정리된 상태다."
  exit 0
fi

printf '\n  아래 %d개를 \033[31m영구 삭제\033[0m한다:\n\n' "${#FOUND[@]}"
for f in "${FOUND[@]}"; do printf '    - %s\n' "$(mask "$f")"; done

if [[ -n "$DIST_ID" && $SKIP_CF -eq 0 ]]; then
  cat <<'TXT'

  ⚠️ CloudFront 배포는 disable 한 뒤 전파가 끝나야 삭제할 수 있다. 이 대기에
     보통 5~15분 걸린다. 지금 기다리지 않으려면 Ctrl-C 후 --skip-cloudfront 를
     붙여 다시 실행하라(배포는 남지만 요청이 없으면 비용은 거의 없다).
TXT
fi

if [[ $ASSUME_YES -eq 0 ]]; then
  printf '\n  계속하려면 정확히 "delete" 를 입력하라: '
  read -r reply
  [[ "$reply" == "delete" ]] || { printf '\n  취소했다. 아무것도 지우지 않았다.\n'; exit 1; }
fi

# ── 2. CloudFront (disable → 대기 → 삭제) ────────────────────────────────
if [[ -n "$DIST_ID" ]]; then
  if [[ $SKIP_CF -eq 1 ]]; then
    step "CloudFront 배포 ${DIST_ID} — 건너뜀 (--skip-cloudfront)"
    warn "배포가 남아 있다. 나중에 지우려면 --skip-cloudfront 없이 다시 실행하라."
    warn "웹 버킷도 오리진이므로 함께 남긴다."
  else
    step "CloudFront 배포 ${DIST_ID} 비활성화"
    aws cloudfront get-distribution-config --region "$CF_REGION" --id "$DIST_ID" \
      > "${TMP}/dist-get.json"
    ETAG="$(jq -r .ETag "${TMP}/dist-get.json")"
    ENABLED="$(jq -r .DistributionConfig.Enabled "${TMP}/dist-get.json")"

    if [[ "$ENABLED" == "true" ]]; then
      # UpdateDistribution 은 merge 가 아니라 전체 교체다. 받은 config 를 그대로
      # 쓰면서 Enabled 만 false 로 바꿔야 오리진·비헤이비어가 날아가지 않는다.
      jq '.DistributionConfig | .Enabled = false' "${TMP}/dist-get.json" > "${TMP}/dist-off.json"
      aws cloudfront update-distribution --region "$CF_REGION" --id "$DIST_ID" \
        --if-match "$ETAG" --distribution-config "file://${TMP}/dist-off.json" >/dev/null
      say "Enabled=false 적용"
    else
      say "이미 비활성 상태"
    fi

    say "전파 완료 대기… (5~15분, Ctrl-C 로 중단해도 배포는 비활성 상태로 남는다)"
    aws cloudfront wait distribution-deployed --region "$CF_REGION" --id "$DIST_ID"

    # disable 후 ETag 가 바뀌었으므로 다시 읽는다. 옛 ETag 를 쓰면 PreconditionFailed.
    ETAG="$(aws cloudfront get-distribution-config --region "$CF_REGION" --id "$DIST_ID" \
      --query ETag --output text)"
    aws cloudfront delete-distribution --region "$CF_REGION" --id "$DIST_ID" --if-match "$ETAG"
    say "삭제: CloudFront ${DIST_ID}"
    DIST_ID=""
  fi
fi

# OAC 는 어떤 배포에도 붙어 있지 않아야 지울 수 있다.
if [[ -n "$OAC_ID" ]]; then
  step "CloudFront OAC 삭제"
  if [[ -n "$DIST_ID" ]]; then
    warn "배포가 아직 OAC 를 참조한다. OAC 는 남긴다."
  else
    OAC_ETAG="$(aws cloudfront get-origin-access-control --region "$CF_REGION" \
      --id "$OAC_ID" --query ETag --output text)"
    aws cloudfront delete-origin-access-control --region "$CF_REGION" \
      --id "$OAC_ID" --if-match "$OAC_ETAG"
    say "삭제: OAC ${OAC_ID}"
  fi
fi

# ── 3. S3 웹 버킷 ────────────────────────────────────────────────────────
# 버킷은 완전히 비어 있어야 삭제된다.
# 버전 관리를 켠 적은 없지만, 계정/조직 기본 설정이나 수동 변경으로 켜져 있으면
# 현재 객체를 지워도 이전 버전과 삭제 마커가 남아 delete-bucket 이 BucketNotEmpty
# 로 실패한다. 그래서 버전과 삭제 마커를 모두 훑는다.
# delete-objects 는 한 번에 1,000개까지만 받으므로 페이지네이션 루프가 필요하다.
# (단일 호출로 처리하면 1,000개가 넘는 순간 조용히 남고 삭제만 실패한다)
empty_and_delete_bucket() {
  local b="$1"
  aws s3 rm "s3://${b}" --recursive --only-show-errors >/dev/null 2>&1 || true

  local safe="${b//[^a-zA-Z0-9]/_}" vjson objs n page=0
  while :; do
    page=$((page + 1))
    vjson="${TMP}/versions-${safe}-${page}.json"
    # --page-size 1000: 응답 1페이지가 delete-objects 한도와 같아지도록 맞춘다.
    # --max-items 1000: CLI 가 자동 페이지네이션으로 전부 합치지 않게 끊는다.
    aws s3api list-object-versions --bucket "$b" \
      --expected-bucket-owner "$ACCOUNT_ID" \
      --page-size 1000 --max-items 1000 > "$vjson" 2>/dev/null || break

    objs="$(jq -c '{Objects: ([(.Versions // []), (.DeleteMarkers // [])]
                    | flatten | map({Key, VersionId})), Quiet: true}' "$vjson")"
    n="$(jq -r '.Objects | length' <<<"$objs")"
    [[ "$n" == "0" ]] && break

    aws s3api delete-objects --bucket "$b" \
      --expected-bucket-owner "$ACCOUNT_ID" --delete "$objs" >/dev/null 2>&1 || true
    say "버전/삭제마커 ${n}개 제거 (page ${page})"
    # 안전장치: 예상보다 많은 페이지가 나오면 무한 루프 대신 알리고 빠진다.
    if [[ $page -ge 50 ]]; then
      warn "객체가 5만개를 넘는다. 남은 것은 수동으로 비워라: aws s3 rm s3://${b} --recursive"
      break
    fi
  done

  if aws s3api delete-bucket --bucket "$b" --region "$REGION" \
       --expected-bucket-owner "$ACCOUNT_ID" 2>"${TMP}/rmbucket.err"; then
    say "삭제: ${b}"
  else
    warn "버킷 ${b} 삭제 실패: $(tr -d '\n' < "${TMP}/rmbucket.err" | head -c 200)"
  fi
}

if [[ $HAS_WEB_BUCKET -eq 1 ]]; then
  if [[ -n "$DIST_ID" ]]; then
    step "S3 웹 버킷 — 건너뜀"
    warn "남아 있는 CloudFront 배포의 오리진이다. 배포와 함께 나중에 지워라."
  else
    step "S3 웹 버킷 삭제"
    empty_and_delete_bucket "$WEB_BUCKET"
  fi
fi

# ── 4. API Gateway ───────────────────────────────────────────────────────
if [[ -n "$API_ID" ]]; then
  step "API Gateway 삭제"
  # HTTP API 를 지우면 라우트·통합·스테이지가 함께 사라진다.
  aws apigatewayv2 delete-api --region "$REGION" --api-id "$API_ID"
  say "삭제: ${API_NAME} (${API_ID})"
fi

# ── 4b. EventBridge heartbeat 규칙 ───────────────────────────────────────
# Lambda 보다 먼저 지운다. 규칙을 남긴 채 함수를 지우면 규칙이 5분마다 없는 함수를
# 호출하며 실패 지표만 쌓는다. 또 타깃이 붙어 있으면 delete-rule 이 거부된다.
if [[ $HAS_RULE -eq 1 ]]; then
  step "EventBridge 규칙 삭제"
  RULE_TARGET_IDS="$(aws events list-targets-by-rule --region "$REGION" \
    --rule "$RULE_NAME" --query 'Targets[].Id' --output text 2>/dev/null || true)"
  if [[ -n "$RULE_TARGET_IDS" && "$RULE_TARGET_IDS" != "None" ]]; then
    # shellcheck disable=SC2086  # 공백 구분 ID 목록을 개별 인자로 넘겨야 한다
    aws events remove-targets --region "$REGION" --rule "$RULE_NAME" \
      --ids $RULE_TARGET_IDS >/dev/null
    say "타깃 제거: ${RULE_TARGET_IDS}"
  fi
  aws events delete-rule --region "$REGION" --name "$RULE_NAME"
  say "삭제: ${RULE_NAME}"
fi

# ── 5. Lambda ────────────────────────────────────────────────────────────
if [[ $HAS_LAMBDA -eq 1 ]]; then
  step "Lambda 삭제"
  aws lambda delete-function --region "$REGION" --function-name "$LAMBDA_NAME"
  say "삭제: ${LAMBDA_NAME}"
  # 로그 그룹은 함수 삭제로 사라지지 않는다. 남기면 요금이 계속 붙는다.
  if aws logs describe-log-groups --region "$REGION" \
       --log-group-name-prefix "/aws/lambda/${LAMBDA_NAME}" \
       --query 'logGroups[0].logGroupName' --output text 2>/dev/null | grep -q "$LAMBDA_NAME"; then
    aws logs delete-log-group --region "$REGION" \
      --log-group-name "/aws/lambda/${LAMBDA_NAME}" 2>/dev/null || true
    say "삭제: 로그 그룹 /aws/lambda/${LAMBDA_NAME}"
  fi
fi

# ── 6. SQS ───────────────────────────────────────────────────────────────
if [[ -n "$QUEUE_URL" ]]; then
  step "SQS 큐 삭제"
  aws sqs delete-queue --region "$REGION" --queue-url "$QUEUE_URL"
  say "삭제: ${QUEUE_NAME}"
  warn "같은 이름의 큐는 삭제 후 60초 동안 재생성할 수 없다(SQS 제약)."
fi

# ── 7. DynamoDB ──────────────────────────────────────────────────────────
if [[ $HAS_TABLE -eq 1 ]]; then
  step "DynamoDB 테이블 삭제"
  aws dynamodb delete-table --region "$REGION" --table-name "$TABLE_NAME" >/dev/null
  aws dynamodb wait table-not-exists --region "$REGION" --table-name "$TABLE_NAME"
  say "삭제: ${TABLE_NAME}"
fi

# ── 8. AgentCore Runtime ─────────────────────────────────────────────────
if [[ -n "$RUNTIME_ID" ]]; then
  step "AgentCore Runtime 삭제"
  # 살아 있는 microVM 세션은 런타임 삭제와 함께 정리된다. 웜풀에 예열해 둔 세션도
  # 여기서 끝나므로 별도의 StopRuntimeSession 루프는 필요 없다.
  aws bedrock-agentcore-control delete-agent-runtime --region "$REGION" \
    --agent-runtime-id "$RUNTIME_ID" >/dev/null
  say "삭제 요청: ${RUNTIME_NAME} (${RUNTIME_ID})"
  # 삭제 완료를 기다린다. 실행 역할을 먼저 지우면 삭제가 막힐 수 있다.
  for i in $(seq 1 60); do
    if ! aws bedrock-agentcore-control get-agent-runtime --region "$REGION" \
           --agent-runtime-id "$RUNTIME_ID" >/dev/null 2>&1; then
      say "삭제 완료"
      break
    fi
    [[ $i -eq 60 ]] && warn "5분 안에 삭제가 끝나지 않았다. 콘솔에서 상태를 확인하라."
    sleep 5
  done
fi

# ── 9. S3 코드 버킷 ──────────────────────────────────────────────────────
if [[ $HAS_CODE_BUCKET -eq 1 ]]; then
  step "S3 코드 버킷 삭제"
  empty_and_delete_bucket "$CODE_BUCKET"
fi

# ── 10. IAM 역할 ─────────────────────────────────────────────────────────
delete_role() {
  local r="$1"
  step "IAM 역할 ${r} 삭제"
  # 인라인 정책과 관리형 정책 연결을 모두 떼야 역할이 지워진다.
  local p
  for p in $(aws iam list-role-policies --role-name "$r" \
               --query 'PolicyNames[]' --output text 2>/dev/null || true); do
    aws iam delete-role-policy --role-name "$r" --policy-name "$p"
    say "인라인 정책 제거: ${p}"
  done
  for p in $(aws iam list-attached-role-policies --role-name "$r" \
               --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null || true); do
    aws iam detach-role-policy --role-name "$r" --policy-arn "$p"
    say "관리형 정책 분리: $(mask "$p")"
  done
  aws iam delete-role --role-name "$r"
  say "삭제: ${r}"
}
[[ $HAS_LAMBDA_ROLE  -eq 1 ]] && delete_role "$LAMBDA_ROLE"
[[ $HAS_RUNTIME_ROLE -eq 1 ]] && delete_role "$RUNTIME_ROLE"

# ── 완료 ─────────────────────────────────────────────────────────────────
step "정리 완료"
cat <<TXT

  남아 있을 수 있는 것:
    - /aws/bedrock-agentcore/runtimes/* 로그 그룹
      (런타임이 만든 것으로, 삭제해도 남는다. 보존기간이 없으면 요금이 계속 붙는다)

        aws logs describe-log-groups --region ${REGION} \\
          --log-group-name-prefix /aws/bedrock-agentcore/runtimes/${RUNTIME_NAME}

    - --skip-cloudfront 를 썼다면 CloudFront 배포와 웹 버킷

  다시 세우려면: ./scripts/deploy.sh
TXT
