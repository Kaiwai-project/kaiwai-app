# God Mode 운영 도구: 피드/공구 강제삭제 · 유저 포인트 ±지급

작성일: 2026-06-26
상태: 설계 승인됨 (사용자 검토 대기)

## 배경 / 목적

관리자(God Mode)가 운영 중 발견한 **부적절한 피드 게시물·공구방을 다이렉트로 삭제**하고,
**특정 유저에게 포인트를 직접 지급/차감**할 수 있어야 한다.

현재 상태:
- 공구방 강제삭제 `god_force_delete_bus(p_bus_id)` 는 **이미 존재** (보증금 300P 자동환불). UI도 완비.
- 피드 게시물(`posts`) 강제삭제는 **RPC·UI 모두 없음**.
- `admin_grant_points(p_amount)` 는 **관리자 본인 지갑에만** 지급 가능 — 타깃 유저 지정 불가.

관리자 게이트는 서버 `public.is_app_admin(uuid)` 화이트리스트 + 클라 `ADMIN_IDS`(index.html / profile.js)로
이미 중앙화되어 있다. 신규 기능도 **이 게이트만** 재사용한다(새 권한 체계 도입 없음).

## 비범위 (Out of Scope)

- 이미지 스토리지 파일 삭제(피드 삭제 시 `image_urls` 의 storage 객체는 고아로 남김 — 별도 정리 대상).
- 삭제 게시물 작성자에 대한 페널티/신고 누적 로직.
- 관리자 행위 전용 audit 테이블(포인트 변동은 기존 `point_transactions` 원장으로 충분히 추적됨).

---

## A. 피드 게시물 강제삭제

### A-1. 서버 (신규 마이그레이션)

`supabase/migrations/20260626000000_49_god_force_delete_post.sql`

```sql
create or replace function public.god_force_delete_post(p_post_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception '인증이 필요합니다' using errcode = '28000'; end if;
  if not public.is_app_admin(v_uid) then
    raise exception '관리자 전용 기능입니다' using errcode = '42501';
  end if;

  perform 1 from public.posts where id = p_post_id for update;
  if not found then
    raise exception '존재하지 않거나 이미 삭제된 게시물입니다' using errcode = 'P0001';
  end if;

  delete from public.posts where id = p_post_id;  -- post_likes 는 ON DELETE CASCADE

  return jsonb_build_object('deleted', true, 'post_id', p_post_id);
end;
$$;
revoke all on function public.god_force_delete_post(uuid) from public, anon;
grant execute on function public.god_force_delete_post(uuid) to authenticated;
```

`god_force_delete_bus` 와 동일한 패턴(인증→admin 검증→잠금→삭제→jsonb 반환).
`post_likes` FK 는 `on delete cascade` 라 좋아요·저장목록도 자동 정리, `like_count` 트리거 영향 없음.

### A-2. 클라이언트 (index.html)

- 노출 게이트: **`_godOverride && isAdminUser()`** (공구방 강제삭제와 동일 — God Override 토글 ON일 때만).
- 위치: `drawFeed()` 의 피드 카드 + `renderPostDetail()` 상세 화면에 🗑️ "강제삭제" 버튼.
- 동작: `confirm("[God Override] 이 게시물을 강제 삭제할까요?")` → `window.sb.rpc('god_force_delete_post', { p_post_id })`
  → 성공 시 `FEED` 배열에서 해당 항목 제거 후 `drawFeed()` 갱신(상세였다면 피드 탭으로 복귀), 실패 시 토스트.

---

## B. 특정 유저 포인트 ± 지급/차감

### B-1. 서버 (같은 마이그레이션)

1) **enum 확장** — 음수 차감 감사용 사유 추가:
```sql
alter type public.point_reason add value if not exists 'admin_revoke';
```
> `alter type ... add value` 는 트랜잭션 제약이 있으므로 마이그레이션 파일 선두에서 단독 실행
> (이후 함수 본문에서 해당 값 사용). 필요 시 별도 마이그레이션으로 분리.

2) **타깃 유저 ±지급 RPC**:
```sql
create or replace function public.admin_grant_points_to(p_target uuid, p_amount integer)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid    uuid := auth.uid();
  v_reason public.point_reason;
begin
  if v_uid is null then raise exception '인증이 필요합니다' using errcode = '28000'; end if;
  if not public.is_app_admin(v_uid) then
    raise exception '관리자 전용 기능입니다' using errcode = '42501';
  end if;
  if p_target is null then raise exception '대상 유저가 없습니다' using errcode = 'P0001'; end if;
  if p_amount is null or p_amount = 0 or abs(p_amount) > 100000 then
    raise exception '지급/차감액이 올바르지 않습니다 (±1~100000)' using errcode = 'P0001';
  end if;

  v_reason := case when p_amount > 0 then 'admin_grant' else 'admin_revoke' end;
  -- 차감 시 잔액 < 0 이면 _wallet_apply 가 '포인트가 부족합니다'(P0001) raise → 트랜잭션 롤백
  return public._wallet_apply(p_target, p_amount, v_reason,
                              null, 'god grant by ' || v_uid::text);
end;
$$;
revoke all on function public.admin_grant_points_to(uuid, integer) from public, anon;
grant execute on function public.admin_grant_points_to(uuid, integer) to authenticated;
```

3) **유저 검색 RPC** (닉네임/아이디 → id·닉네임·현재잔액):
```sql
create or replace function public.admin_search_users(p_query text)
returns table (id uuid, display_name text, username text, balance integer)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_app_admin(auth.uid()) then
    raise exception '관리자 전용 기능입니다' using errcode = '42501';
  end if;
  if coalesce(length(trim(p_query)), 0) < 1 then return; end if;

  return query
    select p.id, p.display_name, p.username, coalesce(w.balance, 0)
      from public.profiles p
      left join public.user_wallets w on w.user_id = p.id
     where p.display_name ilike '%' || p_query || '%'
        or p.username     ilike '%' || p_query || '%'
     order by p.display_name
     limit 20;
end;
$$;
revoke all on function public.admin_search_users(text) from public, anon;
grant execute on function public.admin_search_users(text) to authenticated;
```

### B-2. 클라이언트 (index.html)

god 패널(`godOverlay`)에 **"🎁 유저 포인트 관리"** 섹션 신설:
- 검색 입력 → `admin_search_users(query)` → 결과 리스트(닉네임 + 현재 잔액 P).
- 항목 선택 → 금액 입력(부호 허용, 예: `500` 지급 / `-300` 차감) → "실행".
- `admin_grant_points_to(p_target, p_amount)` 호출 → 성공 시 토스트로 대상 새 잔액 표시.
- **추가 진입점**: god 모드에서 피드/공구 카드의 작성자(👤)를 누르면 해당 `user_id` 를 프리필한 채 동일 입력 UI 호출.

기존 `admin_grant_points`(본인 +1000P, `godAddPoints`)는 **그대로 유지**.

---

## 데이터 흐름 요약

```
[관리자] God Override ON
  ├─ 피드 카드 🗑️  → god_force_delete_post(post_id)  → posts DELETE (likes cascade)
  ├─ 공구 카드 🗑️  → god_force_delete_bus(bus_id)   → (기존) 보증금 환불 + buses DELETE
  └─ 🎁 유저 포인트 관리
        ├─ admin_search_users(q)            → 후보 리스트(잔액 포함)
        └─ admin_grant_points_to(uid, ±amt) → _wallet_apply → user_wallets 갱신 + point_transactions 원장 기록
```

## 보안 / 무결성

- 모든 신규 RPC 는 `SECURITY DEFINER` + 첫 줄에서 `is_app_admin(auth.uid())` 검증 → 클라 위조 불가.
- 포인트 변동은 전부 단일 관문 `_wallet_apply` 경유 → 잔액과 `point_transactions` 원장이 항상 정합.
- 음수 차감으로 잔액이 0 미만이 되는 경우 `_wallet_apply` 가 막아 롤백(잔액 0 미만 불가 — 설계 결정).
- 원장 `memo` 에 `god grant by <admin_uid>` 기록 → 누가 지급/차감했는지 사후 추적 가능.

## 테스트 관점

- 비관리자 계정으로 세 RPC 호출 시 42501 거부.
- 존재하지 않는 post_id/bus_id 강제삭제 시 P0001.
- 게시물 삭제 후 `post_likes` 동반 삭제 + `like_count` 정상.
- `admin_grant_points_to`: 양수 지급/음수 차감/잔액부족 차감(롤백)/한도초과(±100000 초과) 케이스.
- 원장 `point_transactions` 에 reason(admin_grant·admin_revoke)·memo 정확히 기록.
