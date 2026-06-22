# [Step 8] 상호 평점 및 매너 프로필 시스템 — 설계 초안 (DRAFT)

> 상태: **구현 완료** ✅ — mig45 db push + `index.html` UI + `persona_hardtest.mjs` 21/21 PASS. 아래 본문은 확정 5대 스펙 기준으로 갱신됨.
> 컨벤션 준수: 2테이블+ 변경은 RPC 트랜잭션 / Zero-Trust(클라 평점·집계 위조 금지) / SECURITY DEFINER + `SET search_path=public` / 개인정보·익명성 보호 / KAIWAI 핑크·둥근 UI.

---

## 1. 목표 & 핵심 설계 원칙

공구 종료 후 **총대↔탑승자 상호 별점(1~5) + 매너 배지**를 남기고, 유저의 **평균 별점·긍정 배지를 매너 프로필**로 카드/장부/마이페이지에 노출한다.

- **익명성(보복 방지)**: "누가 나에게 몇 점을 줬는지"는 **피평가자에게 비공개**. 개별 리뷰 원본은 작성자 본인만 조회, 외부 노출은 **집계값(평균·개수·배지 카운트)만** 한다.
- **Zero-Trust**: 평점/집계는 클라가 못 건드린다. 쓰기는 검증 RPC, 집계는 SECURITY DEFINER 뷰/RPC만.
- **무결성**: 한 공구에서 (작성자→대상) 1회만. 참여자(총대/그 방 탑승자)만, 종료된 공구만.
- **기존 `trust_score`(3진아웃 패널티)와 별개**: 매너 별점은 *동료 평가 기반 신규 지표*. 둘을 함께 노출(👑 신뢰도 + ⭐ 매너).

---

## 2. 평가 시점(상태) — 설계 결정 + ❓확인 필요

현재 `buses`에는 `ordered`(주문 시작=마감)만 있고 별도 '배송 완료' 상태가 없음. 두 안:

| 안 | 트리거 | 장단 |
|----|--------|------|
| **A안 (권장, v1)** | `buses.ordered = true` (마감/주문 진행) | 추가 컬럼 0, 즉시 가능. 단 '배송 전'에도 평가 열림 |
| B안 | `buses.finalized_at` 신설(총대가 '배송 완료' 처리 시 set, 또는 전원 운송장 등록 시 자동) | '진짜 완료' 기준이지만 상태/트리거 추가 필요 |

> ✅ **확정: B안** — `buses.finalized = true`(배송 완료 처리) 이후에만 상호 평가 활성화. `finalized boolean` + `finalized_at timestamptz` 신설. 방장이 `finalize_coop(p_bus_id)` RPC 로 배송 완료 처리(공구방 '✅ 배송 완료 처리' 버튼). 마감(ordered=true) 후엔 `guard_bus_update_after_ordered` 가 수정을 막으므로, finalize 전용 GUC(`app.allow_finalize`) 우회로 통과시킴.

---

## 3. DB 스키마 (마이그레이션 `…_45_coop_reviews.sql`)

### 3-1. 배지 마스터 (동적 관리 — reward_items 패턴)
코드 수정 없이 INSERT만으로 배지를 추가/비활성할 수 있도록 룩업 테이블화.

```sql
create table public.review_badges (
  code        text primary key,                 -- 'fast_reply', 'noshow' 등
  label       text not null,                     -- '답장이 빨라요'
  emoji       text,                              -- '⚡'
  target_role text not null check (target_role in ('host','rider')),  -- 이 배지를 '받는' 대상
  polarity    text not null check (polarity in ('positive','negative')),
  sort_order  int  not null default 0,
  is_active   boolean not null default true
);
-- RLS: 인증 유저는 활성 배지 조회만
alter table public.review_badges enable row level security;
create policy "배지: 활성 조회" on public.review_badges
  for select to authenticated using (is_active = true);
-- INSERT/UPDATE/DELETE 정책 없음 = 운영자(service_role/대시보드)만 관리

-- 시드 예시
insert into public.review_badges(code,label,emoji,target_role,polarity,sort_order) values
  ('host_fast_reply','답장이 빨라요','⚡','host','positive',1),
  ('host_kind','친절해요','💖','host','positive',2),
  ('host_accurate','발주가 정확해요','🎯','host','positive',3),
  ('host_ship_delay','배송이 지연돼요','🐢','host','negative',10),
  ('rider_fast_pay','입금이 빨라요','💸','rider','positive',1),
  ('rider_manner','매너가 좋아요','😊','rider','positive',2),
  ('rider_noshow','노쇼/잠수해요','🚨','rider','negative',10);
```

### 3-2. 리뷰 본문 (append-only)
```sql
create table public.coop_reviews (
  id          uuid primary key default gen_random_uuid(),
  bus_id      uuid not null references public.buses(id) on delete cascade,
  reviewer_id uuid not null references auth.users(id)  on delete cascade,
  reviewee_id uuid not null references auth.users(id)  on delete cascade,
  direction   text not null check (direction in ('rider_to_host','host_to_rider')),
  rating      int  not null check (rating between 1 and 5),
  badges      text[] not null default '{}',      -- review_badges.code 의 부분집합(RPC가 검증)
  created_at  timestamptz not null default now(),  -- ※ 코멘트 컬럼 없음(확정 스펙: rating+badges 만)
  constraint coop_reviews_once unique (bus_id, reviewer_id, reviewee_id),
  constraint coop_reviews_no_self check (reviewer_id <> reviewee_id)
);
create index idx_coop_reviews_reviewee on public.coop_reviews(reviewee_id);

-- RLS
alter table public.coop_reviews enable row level security;
-- 작성자 본인만 원본 조회(피평가자는 못 봄 = 보복 방지). 집계는 아래 DEFINER 함수로만.
create policy "리뷰: 작성자 본인만 조회" on public.coop_reviews
  for select to authenticated using (reviewer_id = auth.uid());
-- INSERT/UPDATE/DELETE 정책 없음 = submit_coop_review RPC 전용(클라 위조 차단)
```

### 3-3. (옵션 B안) 배송 완료 상태
```sql
alter table public.buses add column if not exists finalized_at timestamptz;  -- 총대 '배송 완료' 처리 시각
```

---

## 4. 쓰기 RPC — `submit_coop_review` (SECURITY DEFINER)

검증을 한 트랜잭션에 모아 수행. 테이블엔 클라 INSERT 정책이 없으므로 이 함수가 유일 입구.

```sql
create or replace function public.submit_coop_review(
  p_bus_id uuid, p_reviewee_id uuid, p_rating int, p_badges text[], p_comment text default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_owner uuid; v_ordered boolean;
  v_is_owner_reviewer boolean; v_is_owner_reviewee boolean;
  v_direction text; v_target_role text; v_id uuid;
begin
  if v_uid is null then raise exception '인증이 필요합니다' using errcode='28000'; end if;
  if v_uid = p_reviewee_id then raise exception '본인은 평가할 수 없습니다' using errcode='P0001'; end if;
  if p_rating < 1 or p_rating > 5 then raise exception '별점은 1~5 입니다' using errcode='P0001'; end if;
  if coalesce(length(p_comment),0) > 200 then raise exception '코멘트가 너무 깁니다' using errcode='P0001'; end if;

  -- 공구 상태/소유자 확인 (평가는 마감 이후에만)
  select owner_id, ordered into v_owner, v_ordered from public.buses where id = p_bus_id;
  if not found then raise exception '존재하지 않는 공구입니다' using errcode='P0001'; end if;
  if not v_ordered then raise exception '마감(주문 시작)된 공구만 평가할 수 있습니다' using errcode='P0001'; end if;
  -- B안 채택 시: if finalized_at is null then raise '배송 완료 후 평가 가능' ...

  v_is_owner_reviewer := (v_uid = v_owner);
  v_is_owner_reviewee := (p_reviewee_id = v_owner);

  if v_is_owner_reviewer then
    -- 총대 → 탑승자 : 대상이 그 방 탑승자여야
    if not exists(select 1 from public.bus_riders where bus_id=p_bus_id and user_id=p_reviewee_id) then
      raise exception '해당 공구의 탑승자만 평가할 수 있습니다' using errcode='P0001';
    end if;
    v_direction := 'host_to_rider'; v_target_role := 'rider';
  else
    -- 탑승자 → 총대 : 작성자가 그 방 탑승자 + 대상이 그 방 총대여야
    if not exists(select 1 from public.bus_riders where bus_id=p_bus_id and user_id=v_uid) then
      raise exception '해당 공구의 참여자만 평가할 수 있습니다' using errcode='P0001';
    end if;
    if not v_is_owner_reviewee then raise exception '탑승자는 총대만 평가할 수 있습니다' using errcode='P0001'; end if;
    v_direction := 'rider_to_host'; v_target_role := 'host';
  end if;

  -- 배지 화이트리스트 검증: 전달된 배지가 모두 그 대상 role 의 활성 배지여야
  if p_badges is not null and array_length(p_badges,1) is not null then
    if exists (
      select 1 from unnest(p_badges) c
      where c not in (select code from public.review_badges where is_active and target_role = v_target_role)
    ) then raise exception '유효하지 않은 배지가 포함되어 있습니다' using errcode='P0001'; end if;
  end if;

  insert into public.coop_reviews(bus_id,reviewer_id,reviewee_id,direction,rating,badges,comment)
  values (p_bus_id, v_uid, p_reviewee_id, v_direction, p_rating, coalesce(p_badges,'{}'), nullif(btrim(p_comment),''))
  returning id into v_id;   -- UNIQUE 위반 시 23505 → 클라 "이미 평가했어요"
  return v_id;
end; $$;
revoke all on function public.submit_coop_review(uuid,uuid,int,text[],text) from public, anon;
grant execute on function public.submit_coop_review(uuid,uuid,int,text[],text) to authenticated;
```

---

## 5. 집계 노출 — 매너 프로필 (익명 집계 전용, DEFINER 배치 RPC)

개별 리뷰는 가리고 **평균·개수·긍정 배지 카운트만** 노출. 카드/장부에서 여러 명을 한 번에 그릴 수 있도록 **배치 RPC**(기존 `get_host_trust_score`/`_attachTrustScores` 패턴).

```sql
create or replace function public.get_manner_profiles(p_user_ids uuid[])
returns table (user_id uuid, avg_rating numeric, review_count int, top_badges jsonb)
language sql security definer set search_path = public as $$
  with base as (
    select reviewee_id, rating, badges
      from public.coop_reviews
     where reviewee_id = any(p_user_ids)
  ),
  agg as (
    select reviewee_id,
           round(avg(rating)::numeric, 1) as avg_rating,
           count(*)::int as review_count
      from base group by reviewee_id
  ),
  pos as (   -- 긍정 배지만 카운트(부정 배지는 공개 비노출)
    select b.reviewee_id, x.code, count(*)::int as cnt
      from base b, lateral unnest(b.badges) x(code)
      join public.review_badges rb on rb.code = x.code and rb.polarity='positive'
     group by b.reviewee_id, x.code
  )
  select a.reviewee_id,
         a.avg_rating, a.review_count,
         coalesce((select jsonb_agg(jsonb_build_object('code',p.code,'cnt',p.cnt) order by p.cnt desc)
                     from pos p where p.reviewee_id=a.reviewee_id), '[]'::jsonb) as top_badges
    from agg a;
$$;
revoke all on function public.get_manner_profiles(uuid[]) from public, anon;
grant execute on function public.get_manner_profiles(uuid[]) to authenticated;
```

- 부정 배지(노쇼·지연)는 **공개 미노출**(보복/낙인 방지). 필요 시 운영자 전용 집계나 `trust_score` 연동은 후속 논의. ❓부정 배지 누적이 일정 횟수 이상이면 "주의" 표식 노출할지 확인 필요.

---

## 6. 프론트엔드 (`index.html`)

### 6-1. 평가 모달 `#reviewOverlay`
- 별점: 1~5 탭 가능한 ⭐ 토글, 선택 점수 하이라이트.
- 배지 칩: `review_badges`(대상 role 필터)를 SWR 캐시 후 다중선택 칩(긍정=핑크, 부정=회색). KAIWAI 둥근 칩.
- 코멘트(선택, 200자), 제출 → `sb.rpc('submit_coop_review', {...})`. 23505면 "이미 평가했어요" 토스트.
- 헌법: 이미지 0, 이모지+CSS만.

### 6-2. 진입점
- **공구방(renderBusRoom, `ordered=true`)**:
  - 탑승자(본인): "⭐ 총대 평가하기" 버튼(이미 평가했으면 비활성 + 내 별점 표시).
  - 총대: 관리자 패널 각 탑승자 행에 "⭐ 평가" 버튼.
- **마이페이지**: "완료된 공구" 목록에서 미평가 건 "평가하기" 유도(평가 시점 알림).

### 6-3. 매너 배지 렌더 (`_attachTrustScores` 패턴 확장)
- `loadBuses()`에서 owner_id 목록으로 `get_manner_profiles` 배치 호출 → `_mannerHtml(profile)` = `⭐ 4.8 (12)` + 상위 긍정 배지 1~2개 이모지.
- 노출 위치: 공구 카드(총대), 공구방 헤더(총대), 장부 각 행(탑승자 닉 옆), 프로필 카드. 기존 `_trustBadgeHtml`(👑 신뢰도)와 **나란히**.

### 6-4. 알림(옵션)
- 평가 수신 시 익명 알림("새 매너 평가를 받았어요 ⭐") — 누가/몇 점인지 미표기(익명성 유지). 기존 `notifications`/`_notify` 트리거 재사용 가능. ❓도입 여부 확인.

---

## 7. 보안 체크리스트 (구현 시 검증)
- [ ] 리뷰 원본은 작성자만 SELECT(피평가자/타인 불가) — RLS 테스트.
- [ ] 클라 직접 INSERT/UPDATE/DELETE 차단(정책 없음) — RPC만.
- [ ] 비참여자/자기평가/미마감 공구/별점 범위 밖/타 role 배지 — 전부 RPC 거부.
- [ ] 1공구·1방향 1회(UNIQUE 23505).
- [ ] 집계 RPC는 평균·개수·긍정배지만 반환(개별 평점·작성자 노출 0).
- [ ] DEFINER 함수 전부 `set search_path=public` + authenticated only(public/anon revoke).

## 8. 검증 계획 (persona_hardtest 확장)
- 일회용 유저(총대1·탑승자2)로 실 JWT: ①탑승자→총대 평가 성공/중복거부 ②총대→탑승자 평가 ③비참여자 평가 거부 ④미마감 공구 평가 거부 ⑤자기평가 거부 ⑥타 role 배지 거부 ⑦`get_manner_profiles` 평균·개수·긍정배지만 반환·부정배지 비노출 ⑧리뷰 원본 RLS(작성자만).

## 9. 산출물 / 순서
1. mig45 `…_45_coop_reviews.sql` (review_badges + coop_reviews + RLS + submit_coop_review + get_manner_profiles [+옵션 finalized_at])
2. `index.html` (#reviewOverlay + 진입점 + 매너 배지 렌더 + 배지 SWR)
3. persona_hardtest 평가 페르소나 추가 → 8+ assertions
4. `user_guide.md`/가이드 모달에 매너 정책 1줄 추가
5. db push → E2E → 커밋/푸시

---

## ✅ 확정 5대 스펙 (반영 완료)
1. **평가 시점**: B안 — `buses.finalized = true`(배송 완료) 이후에만 활성화. `finalize_coop` RPC + GUC 우회.
2. **부정 배지 누적 경고**: 외부 노출은 **긍정 배지만** 카운트. 단 부정 배지 **누적 3회 이상**이면 `get_manner_profiles` 가 **`is_warned = true`** 반환 → 프론트 닉 옆 `⚠️` 노출.
3. **스키마(코멘트 제외)**: `coop_reviews` = `rating(1~5)` + `badges(text[])` 만. `UNIQUE(bus,reviewer,reviewee)`(중복) + `CHECK(reviewer<>reviewee)`(셀프) 방지.
4. **알림 배제**: 평가 작성 시 푸시/알림 없음 — 조용히 기록, Lazy 집계(`get_manner_profiles`)만.
5. **배지 세트 시딩 완료**: 총대(host) 긍정4/부정3 + 탑승자(rider) 긍정3/부정3 = 13종(§3-1 DDL 참조).

## 📦 구현 산출물 (완료)
- **mig45** `supabase/migrations/20260622000021_45_coop_reviews.sql` — db push 완료.
  - `buses.finalized/finalized_at` + `guard_bus_update_after_ordered`(GUC 우회) + `finalize_coop` RPC
  - `review_badges`(13종 시드) · `coop_reviews`(RLS: 작성자만 SELECT) · `submit_coop_review`(DEFINER 검증) · `get_manner_profiles`(DEFINER 집계 + is_warned)
- **index.html** — `#reviewOverlay`(별점/배지 모달) + `openReview/submitReview/finalizeCoop/_loadMyReviews` + 매너 배지 렌더(`_attachMannerProfiles`/`_mannerHtml`, 카드·방헤더·장부행) + 배송완료/평가 진입 버튼. `node --check` PASS.
- **persona_hardtest.mjs** — 페르소나 R0~R12 추가, **전체 21/21 PASS**(완료처리·양방향평가·중복/셀프/비참여자/역할배지/미완료 거부·is_warned 3회·긍정배지만 노출·RLS 격리).
