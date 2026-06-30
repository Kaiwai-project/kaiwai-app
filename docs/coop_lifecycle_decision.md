# 공구방 라이프사이클 — 3인 전문가 협의 최종 결론 (Decision Record)

> 원본 요구사항: `docs/coop_lifecycle.md`
> 협의: Backend Architect · Frontend Developer · QA Engineer
> 작성일: 2026-06-30

## 0. 현황 진단 (스펙 ↔ 실제 코드 간극)

| 스펙 가정 | 실제 코드베이스 |
|---|---|
| 테이블 `coop_rooms` | 실제는 **`buses`** (+ `bus_riders`, `bus_rider_private`) |
| `status` enum (5단계) | **`ordered` boolean 하나뿐** (false=모집중 / true=마감·출발) |
| `completed_at`, `expires_at` | `expired_at`(기본 now()+24h)만 존재. `completed_at`·`status`·`archived` 없음 |
| 완료(completed) 상태 | 개념 없음. `ordered=true`가 종착역 |
| 취소/만료 환불 | `expire_overdue_buses()`가 하드삭제 + 300P 환불까지 함 (미달방만) |
| 분쟁 잠금 | 신고/분쟁 테이블 전혀 없음 |
| 피드 노출 차단 | mig52 RLS가 `ordered=true` 방을 비참여자에게 원천 차단 |
| 클라 상태머신 | `coop-core.js`: `recruiting/order_started/cancelled/done` — 스펙과 명칭 불일치 |

## 1. 핵심 합의

**enum 빅뱅 교체 ❌ → `status` 추가 + `ordered` 미러 유지 + 전이 RPC 강제.**
`ordered`는 RLS·트리거·RPC 5곳 이상이 참조하므로, 미러로 남겨 기존 로직을 무손상 보존하고
신규 코드만 `status`를 읽고 쓴다.

상태 매핑: `recruiting → ordered=false` / `closed·completed·canceled·expired → ordered=true`

## 2. QA가 막은 취약점 3종 (반드시 방어)

1. **[돈 증발]** 총대가 탑승자 있는 방을 `delete` → cascade로 라이더 삭제되나 **300P 환불 0원**.
   현재 DELETE RLS가 `owner_id`만 검사. → 하드삭제는 `recruiting + 탑승자 0명`일 때만.
2. **[상태 스푸핑]** 신고당한 총대가 `status`를 직접 `completed`로 위조 / 만료방을 `recruiting`으로 부활.
   → 직접 UPDATE 차단 트리거 + 전이 화이트리스트 + 분쟁 잠금.
3. **[좀비/이중환불]** 만료 크론 경합, '만료+초과달성 미마감' 방 영구 림보, 미달방 하드삭제 ↔ 1년 보존 충돌.
   → `FOR UPDATE SKIP LOCKED` + 소프트 전이(`expired`+환불+7일후 hide), 초과달성방 `closed` 승급.

## 3. 결정 사항

| # | 항목 | 결정 |
|---|---|---|
| 1 | 상태 모델 | `buses.status` enum: `recruiting/closed/completed/canceled/expired`. `ordered`는 트리거 자동 동기화 |
| 2 | 신규 컬럼 | buses: `status`, `completed_at`, `canceled_at`, `host_hidden_at` / bus_riders: `hidden_at`. 백필 `status = ordered ? 'closed' : 'recruiting'` |
| 3 | 전이 보안 | 직접 `UPDATE status` 차단 트리거 + 화이트리스트 전이만 허용(RPC 경유) |
| 4 | 피드 | 쿼리·RLS 모두 `status='recruiting' AND expired_at > now()` |
| 5 | 하드삭제 | 총대 DELETE는 `recruiting + 탑승자 0명`만(RLS+트리거). 그 외 cancel 강제 |
| 6 | 완료 | `complete_coop()` RPC (총대, closed→completed, `completed_at`) |
| 7 | 아카이브 | completed 14일 경과 시 내역 기본숨김(쿼리), '내역에서 삭제'=per-user `hidden_at`, DB 1년 보존 |
| 8 | 자동만료 | `expire_overdue_buses` 개편: 미달→`expired`+환불+7일후 hide(하드삭제 폐지), 초과달성 미마감→`closed` 승급 |
| 9 | 분쟁잠금 | `coop_reports` 테이블 + open report 시 자동/수동 전이·삭제·아카이브 전면 차단 |
| 10 | 크론 | `pg_cron` 자정 1회 `expire_overdue_buses()` + 아카이브 스윕 (`supabase db push`) |
| 11 | 보존기간 | **14일** 채택(분쟁 주기 짧음). 물리삭제는 1년 후 별도 크론 |

## 4. 구현 순서

1. `mig56_coop_lifecycle.sql` — status enum·컬럼·백필·동기화/전이/하드삭제 가드·`complete_coop`·`coop_reports`·개편 `expire_overdue_buses`·분쟁잠금
2. `mig57_pg_cron.sql` — 자정 스케줄
3. `coop-core.js` — 상태 상수 스펙 통일
4. `index.html` — 피드 필터, 내역 3탭(진행중/완료/종료), '내역에서 삭제', 완료 버튼
</content>
</invoke>
