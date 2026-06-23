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

---
---

# [Step 9] 제휴사 커미션 링크 변환 파이프라인 — 설계 초안 (DRAFT)

> 상태: **구현 완료** ✅ — mig46(링크 변환)+mig47(트래픽 트래킹) db push + `index.html` + `persona_hardtest` 31/31 PASS.
> 피벗: 렌즈라라 공식 제휴 코드 발급 전이므로, **역제안용 '경유 트래픽 증명' 사전 적재 파이프라인**으로 확정. 링크 변환은 유지하되 트래킹 코드는 임시값 `kaiwai_test`(코드 발급 시 UPDATE 한 줄로 교체).
> 컨벤션: Zero-Trust(클라가 보낸 URL/파라미터 맹신 금지, 서버가 트래킹 코드 강제) / 동적 설정 테이블(코드 수정 없이 제휴사 추가) / 기존 도메인 락(`buses.target_domain`)·`_domainOf` 재사용.

## 1. 목표 & 비즈니스 흐름
총대가 개설 시 입력한 **렌즈라라 상품 URL**에 KAIWAI 제휴 트래킹 코드를 자동 주입해 `buses.product_url`(신규)에 저장하고, 공구방 "주문 바로가기" 버튼이 이 링크를 타게 해 **커미션이 KAIWAI 로 귀속**되도록 한다.

```
개설(cbUrl 입력) → [클라] _toAffiliateUrl 로 즉시 변환 미리보기
               → INSERT buses(product_url=변환URL, target_domain=host)
               → [서버] enforce_affiliate_url 트리거가 트래킹 코드 재주입(강제) → 저장
공구방 "🛒 주문 바로가기" → b.product_url(트래킹 포함) 로 이동 → 총대 결제 → 커미션 적립
```

## 2. 핵심 보안 명제 (Zero-Trust)
- 클라이언트 변환은 **UX 용**일 뿐, **신뢰 경계가 아님**. 사용자가 API 로 `product_url` 의 트래킹 파라미터를 **삭제/변조**해 저장할 수 있으므로, **서버 트리거가 최종 권위**로 트래킹 코드를 재주입한다(누락/위조 시 강제 덮어쓰기). → 어떤 경로로 저장돼도 커미션 파라미터가 보장됨.

## 3. 데이터 모델 (마이그레이션 `…_46_affiliate_links.sql`)

### 3-1. 제휴사 설정 (동적 — INSERT 만으로 제휴사 추가, reward_items/review_badges 패턴)
```sql
create table public.affiliate_partners (
  domain      text primary key,          -- 매칭 호스트(소문자, www 제거) 예: 'lenslala3.com'
  param_key   text not null,             -- 트래킹 파라미터 키  예: 'partner_id' (또는 'a8')
  param_value text not null,             -- 값  예: 'kaiwai'
  is_active   boolean not null default true,
  created_at  timestamptz not null default now()
);
alter table public.affiliate_partners enable row level security;
create policy "제휴사: 활성 조회" on public.affiliate_partners
  for select to authenticated using (is_active = true);   -- 클라가 변환 미리보기에 사용
-- 쓰기 정책 없음 = 운영자(service_role/대시보드)만 관리
insert into public.affiliate_partners(domain,param_key,param_value) values
  ('lenslala3.com','partner_id','kaiwai')   -- ❓실제 렌즈라라 도메인/파라미터 스킴 확인 필요
on conflict (domain) do nothing;
```

### 3-2. buses 에 변환 링크 컬럼
```sql
alter table public.buses add column if not exists product_url text;   -- 총대 제휴 변환 주문 링크
comment on column public.buses.product_url is '제휴 트래킹 코드가 강제 주입된 주문 링크(서버 트리거가 보증).';
```

## 4. URL 변환 로직

### 4-1. 서버 헬퍼 `inject_affiliate_param(url, key, val)` (IMMUTABLE)
프래그먼트(`#...`) 분리 → 쿼리에서 기존 `key` 제거 → `key=val` 재부착 → 재조립. 멱등(여러 번 적용해도 동일).
```sql
create or replace function public.inject_affiliate_param(p_url text, p_key text, p_val text)
returns text language plpgsql immutable set search_path = public as $$
declare v_base text; v_frag text; v_qpos int; v_path text; v_query text; v_clean text;
begin
  if coalesce(p_url,'') = '' then return p_url; end if;
  -- 1) 프래그먼트 분리
  v_frag := ''; v_base := p_url;
  if position('#' in p_url) > 0 then
    v_base := split_part(p_url,'#',1); v_frag := '#' || split_part(p_url,'#',2);
  end if;
  -- 2) path?query 분리
  v_qpos := position('?' in v_base);
  if v_qpos = 0 then v_path := v_base; v_query := '';
  else v_path := left(v_base, v_qpos-1); v_query := substr(v_base, v_qpos+1); end if;
  -- 3) 기존 key 제거 (key=... 토큰 삭제)
  v_clean := regexp_replace('&'||v_query, '&'||p_key||'=[^&]*', '', 'gi');
  v_clean := ltrim(v_clean,'&');
  -- 4) key=val 재부착
  v_clean := case when v_clean = '' then p_key||'='||p_val else v_clean||'&'||p_key||'='||p_val end;
  return v_path || '?' || v_clean || v_frag;
end; $$;
```

### 4-2. 강제 트리거 `enforce_affiliate_url` (BEFORE INSERT/UPDATE on buses)
```sql
create or replace function public.enforce_affiliate_url()
returns trigger language plpgsql set search_path = public as $$
declare v_host text; v_p record;
begin
  if coalesce(new.product_url,'') = '' then return new; end if;
  -- 호스트 추출(소문자, www 제거) — 프론트 _domainOf 와 동일 규칙
  v_host := lower(regexp_replace(
              regexp_replace(new.product_url, '^[a-z]+://', '', 'i'),  -- 스킴 제거
              '^www\.', ''));
  v_host := split_part(split_part(split_part(v_host,'/',1),'?',1),'#',1);  -- 호스트만
  -- 도메인 락 정합성: target_domain 이 있으면 product_url 호스트와 일치 강제
  if new.target_domain is not null and new.target_domain <> '' and v_host <> lower(new.target_domain) then
    raise exception '주문 링크가 지정 구매처 도메인과 일치하지 않습니다' using errcode='P0001';
  end if;
  -- 제휴사 매칭 시 트래킹 코드 강제 주입(클라 변조/삭제 무력화)
  select * into v_p from public.affiliate_partners where domain = v_host and is_active;
  if found then
    new.product_url := public.inject_affiliate_param(new.product_url, v_p.param_key, v_p.param_value);
  end if;
  return new;
end; $$;
create trigger trg_enforce_affiliate_url
  before insert or update of product_url, target_domain on public.buses
  for each row execute function public.enforce_affiliate_url();
```
- **효과**: 비제휴 도메인은 그대로 통과(변환 없음), 렌즈라라면 `partner_id=kaiwai` 가 **항상** 보장됨. 사용자가 파라미터를 빼고 보내도 트리거가 재주입.
- `guard_bus_update_after_ordered`(마감 후 수정 차단)와 충돌 없음 — product_url 변경은 개설/미마감 시점 위주, 마감 후 변경은 기존 정책이 차단.

## 5. 프론트엔드 (`index.html`)
- **`_toAffiliateUrl(url)`**: `affiliate_partners`(SWR 캐시)로 호스트 매칭 → `URL`/`URLSearchParams` 로 `param_key=param_value` set(기존 값 덮어쓰기) → 문자열 반환. 비매칭/파싱 실패 시 원본 반환.
- **submitCreateBus**: `target_domain` 저장에 더해 `product_url: _toAffiliateUrl(cbUrl)` 전송(서버 트리거가 재보증). 변환 미리보기 토스트("제휴 링크로 자동 변환됐어요").
- **"🛒 주문 바로가기"**: 기존 `openOrderProcess` 동선에서 `b.product_url`(없으면 원본 cbUrl 폴백) 을 `window.open`. 총대 전용 노출.

## 6. 예외 처리
| 케이스 | 처리 |
|--------|------|
| 비제휴 도메인(타 쇼핑몰) | 변환 없이 원본 저장(도메인 락이 탑승 단계에서 별도 통제) |
| 잘못된 URL/파싱 실패 | 클라는 원본 유지, 서버 트리거는 호스트 매칭 실패로 무변환 |
| 트래킹 파라미터 변조/삭제 | 서버 트리거가 재주입(강제) → 무력화 |
| 기존에 다른 `partner_id` 존재 | `inject_*` 가 기존 키 제거 후 재부착(우리 값으로 치환) |
| `#fragment`/다중 파라미터 | 프래그먼트 보존 + 해당 키만 치환 |
| http/https·www 변형 | 스킴/www 정규화 후 호스트 비교 |

## 7. 검증 계획 (persona_hardtest 확장)
- ①렌즈라라 URL 개설 → product_url 에 `partner_id=kaiwai` 주입 확인 ②파라미터 누락 URL 로 직접 INSERT(API) → 트리거가 재주입 ③다른 partner_id 변조 → 우리 값으로 치환 ④비제휴 도메인 → 무변환 ⑤target_domain 불일치 product_url → 거부 ⑥fragment/기존 쿼리 보존 ⑦inject 멱등.

## 8. 구현 순서
1. mig46 (`affiliate_partners` + `buses.product_url` + `inject_affiliate_param` + `enforce_affiliate_url` 트리거 + 시드)
2. index.html (`_toAffiliateUrl` + submitCreateBus 연동 + "주문 바로가기" 바인딩 + affiliate SWR)
3. persona_hardtest 제휴 변환 페르소나
4. db push → E2E → 커밋/푸시

## ✅ 확정 스펙 & 구현 결과 (트래픽 트래킹 피벗)
1. **시드**: `affiliate_partners` 에 `lenslala.com` / `lenslala3.com` → `partner_id` (값=임시 `kaiwai_test`, 공식 코드 발급 시 UPDATE 만으로 교체).
2. **비제휴 도메인**: 무변환·무에러로 원본 저장(트리거가 호스트 매칭 실패 시 통과).
3. **변조/삭제 무력화**: `enforce_affiliate_url`(BEFORE INSERT/UPDATE of product_url, DEFINER)가 제휴 호스트면 `partner_id` 를 **강제 재주입/치환**(클라가 `partner_id=other`/삭제로 보내도 우리 값으로 덮어씀). `inject_affiliate_param`(IMMUTABLE, 프래그먼트 보존·멱등).
4. **트래픽 트래킹**(신규): `affiliate_traffic_logs`(id·bus_id·user_id(null허용)·target_domain·click_type∈{product_view,order_intent}·created_at). **RLS=INSERT 누구나(anon+authenticated)/SELECT 관리자만**. `log_affiliate_click(p_bus_id,p_click_type)`(DEFINER+search_path, anon+authenticated execute) — 외부 이동 직전 비동기 적재(user_id·target_domain 서버 파생).

## 📦 구현 산출물 (완료)
- **mig46** `…0022_46_affiliate_links.sql` — affiliate_partners + buses.product_url + inject_affiliate_param + enforce_affiliate_url 트리거.
- **mig47** `…0023_47_affiliate_traffic_logs.sql` — 시드 `kaiwai_test` 전환 + affiliate_traffic_logs + log_affiliate_click RPC.
- **index.html** — `_toAffiliateUrl`/`loadAffiliatePartners`/`previewAffiliateUrl`(개설 폼 변환 미리보기) + submitCreateBus `product_url` 전송 + `platformUrl` 가 `b.productUrl` 우선 + `logAffiliateClick`/`goOrderLink`/`viewBusProduct` + 진입(탑승폼 '🔗 상품 보기'=product_view / '🛒 주문 바로가기'·주문완료=order_intent). `node --check` PASS.
- **persona_hardtest.mjs** — 페르소나 S0~S9, **전체 31/31 PASS**(주입·위조치환·비제휴무변환·로깅·click_type거부·관리자전용 SELECT·누구나 INSERT).

> 후속(별도 단계): 공식 제휴 코드 발급 시 `affiliate_partners.param_value` UPDATE / 관리자 트래픽 대시보드(전환 리포팅).

---
---

# [Step 10] 채널 밖 외부 실시간 알림 연동 — 설계 초안 (DRAFT)

> 상태: **구현 완료** ✅ — mig48 db push + Edge Function `send-external-notification` 배포(DISPATCH_MODE=mock) + index.html 동의 토글. persona_hardtest 35/35 + Edge Mock 발송 7/7 PASS.
> ⏳ 남은 단계(운영): Supabase **Database Webhook**(notifications INSERT → 함수, `x-webhook-secret` 헤더) 연결 + 실발송 키 발급 시 `DISPATCH_MODE=live`.
> 목표: 사용자가 **브라우저를 닫고 있어도** 입금 요청·공구 성사 알림을 Email/SMS·알림톡으로 받아 **노쇼 0%** 통제.
> 컨벤션: 기존 인앱 `notifications`(mig38)·`_notify` DEFINER 파이프라인 재사용 / PII(이메일·전화) 최소노출·service_role 전용 / Mock↔실발송 스위칭.

## 1. 파이프라인 개요 (Database Webhook → Edge Function)
```
인앱 상태변화(입금요청/성사 등) → _notify(DEFINER) → notifications INSERT
   → [Supabase Database Webhook] notifications AFTER INSERT 감지
   → POST(비동기) → Edge Function send-external-notification
       → (service_role) 수신인 연락처·채널 동의 조회(profiles + auth.users)
       → Dispatcher: 채널별 메시지 빌드 → Mock(콘솔) | 실발송(Resend/Solapi)
       → notification_deliveries 에 발송 결과 적재(상태/멱등)
```
> 용어: 기획서의 `bus_notifications` = 기존 **`notifications`** 테이블(mig38, user_id·title·body·type·link_id·is_read). 신규 테이블 없이 이 INSERT 를 외부발송 트리거 소스로 사용.

## 2. 데이터 모델 (마이그레이션 `…_48_external_notify.sql`)

### 2-1. 수신 연락처 & 채널 동의 (profiles 확장)
```sql
alter table public.profiles
  add column if not exists phone        text,                    -- E.164 (예: +8210...) — 알림톡/SMS용
  add column if not exists notify_email boolean not null default true,
  add column if not exists notify_sms   boolean not null default false;  -- 기본 off(과금/동의)
-- 이메일은 auth.users.email 사용(Edge Function 에서 service_role 로 조회), profiles 에 별도 캐시 불필요.
```

### 2-2. 외부 발송 로그(멱등·상태·재시도) — service_role 전용
```sql
create table public.notification_deliveries (
  id              bigint generated always as identity primary key,
  notification_id uuid not null references public.notifications(id) on delete cascade,
  user_id         uuid not null,
  channel         text not null check (channel in ('email','sms','alimtalk')),
  status          text not null check (status in ('queued','sent','failed','skipped','mock')),
  provider        text,                       -- 'resend' | 'solapi' | 'mock'
  error           text,
  created_at      timestamptz not null default now(),
  constraint nd_once unique (notification_id, channel)   -- 웹훅 재시도 중복발송 차단(멱등)
);
alter table public.notification_deliveries enable row level security;
-- SELECT 관리자만(운영 모니터링), 쓰기 정책 없음 = Edge Function(service_role)만 적재
create policy "발송로그: 관리자만 조회" on public.notification_deliveries
  for select to authenticated using (public.is_app_admin(auth.uid()));
```

## 3. Database Webhook 설정
- **방법 A (권장, Supabase 관리형 Webhook)**: Dashboard → Database → Webhooks → `notifications` `INSERT` → HTTP POST `https://<ref>.functions.supabase.co/send-external-notification`, 헤더에 공유 시크릿(`x-webhook-secret`). 내부적으로 `supabase_functions.http_request` 트리거 생성.
- **방법 B (코드로 고정, pg_net + 트리거)**: 마이그레이션에서 `pg_net.http_post` 를 호출하는 AFTER INSERT 트리거. 재현성↑(IaC), 단 pg_net 확장 필요.
- 보안: Edge Function 이 `x-webhook-secret` 검증(시크릿 불일치 401). `verify_jwt = false`(웹훅은 JWT 없음) + 시크릿으로 인증.

## 4. Edge Function `send-external-notification` 구조 (Deno)
```ts
// 1) 웹훅 시크릿 검증 → 2) payload.record(=notifications 행) 파싱
// 3) 수신인 해석: service_role 로 profiles(phone, notify_*) + auth.admin.getUserById(email)
// 4) 채널 결정: notify_email && email → email / notify_sms && phone → sms|alimtalk
// 5) 메시지 빌드: record.type 별 템플릿(입금요청/성사/운송장 등) + title/body
// 6) Dispatcher 발송 → 7) notification_deliveries upsert(멱등: nd_once)
serve(async (req) => {
  if (req.headers.get("x-webhook-secret") !== Deno.env.get("WEBHOOK_SECRET")) return new Response("unauthorized",{status:401});
  const { record } = await req.json();                 // notifications 행
  const sb = createClient(URL, SERVICE_ROLE);          // service_role(연락처 조회)
  const prof = await sb.from("profiles").select("phone,notify_email,notify_sms").eq("id", record.user_id).single();
  const { data:{ user } } = await sb.auth.admin.getUserById(record.user_id);  // email
  const msg = buildMessage(record);                    // {subject, text}
  const results = [];
  if (prof.notify_email && user?.email) results.push(await dispatch("email", user.email, msg, record));
  if (prof.notify_sms && prof.phone)    results.push(await dispatch("sms",   prof.phone, msg, record));
  return Response.json({ ok:true, results });
});
```

## 5. Mock ↔ 실발송 Dispatcher (스위칭 뼈대) — 핵심 요구
```ts
const MODE = Deno.env.get("DISPATCH_MODE") ?? "mock";   // 'mock' | 'live'

const ADAPTERS = {
  email: { live: sendResend,  mock: mockLog("email") },   // Resend API
  sms:   { live: sendSolapi,  mock: mockLog("sms")   },   // Solapi(SMS/알림톡)
};
async function dispatch(channel, to, msg, record){
  const adapter = ADAPTERS[channel][MODE] ?? ADAPTERS[channel].mock;
  let status="sent", provider=(MODE==="live"?(channel==="email"?"resend":"solapi"):"mock"), error=null;
  try { await adapter(to, msg); if(MODE!=="live") status="mock"; }
  catch(e){ status="failed"; error=String(e); }
  await logDelivery(record.id, record.user_id, channel, status, provider, error);   // service_role, 멱등 upsert
  return { channel, status };
}
function mockLog(ch){ return async (to,msg)=>{ console.log(`[MOCK ${ch}] → ${to}\n${msg.subject}\n${msg.text}`); }; }  // 개발: 콘솔
async function sendResend(to,msg){ /* POST https://api.resend.com/emails (RESEND_API_KEY) */ }
async function sendSolapi(to,msg){ /* POST Solapi SMS/알림톡 (SOLAPI_KEY/SECRET, 템플릿ID) */ }
```
- **개발/크레딧 전**: `DISPATCH_MODE=mock` → 메일/문자 내용 콘솔 출력(+`status='mock'` 로그). **상용**: `DISPATCH_MODE=live` + API 키 시크릿 주입 시 어댑터만 바뀜(호출부 무변경).

## 6. 발송 솔루션 매핑(초안)
| 채널 | 솔루션 | 키/시크릿 | 비고 |
|------|--------|-----------|------|
| Email | **Resend** | `RESEND_API_KEY` | 무료 티어, 도메인 인증(SPF/DKIM) 필요 |
| SMS / 알림톡 | **Solapi** | `SOLAPI_API_KEY`/`SOLAPI_API_SECRET`, 알림톡 `templateId`/발신프로필 | 알림톡=사전 템플릿 심사, 실패 시 SMS 대체발송 |

## 7. 보안 / 정합성
- 웹훅 시크릿 검증(401), Edge Function `verify_jwt=false`.
- 연락처 조회는 **service_role 전용**(이메일=auth.users, 전화=profiles.phone). 클라엔 절대 노출 안 함.
- **멱등**: `notification_deliveries` UNIQUE(notification_id, channel) → 웹훅 재시도/중복 INSERT 시 중복 발송 차단.
- **동의(opt-in)**: `notify_email`/`notify_sms` true + 연락처 존재 시에만 발송(미동의=skipped).
- 발송 로그 SELECT 관리자만(연락처/내용 유출 차단).
- 인앱 알림(notifications)은 그대로 — 외부 발송은 **부가 채널**(실패해도 인앱은 정상).

## 8. 검증 계획
- Edge Function 로컬(`supabase functions serve`) + Mock: notifications 행 페이로드 모킹 → 콘솔에 email/sms 출력, `notification_deliveries` status='mock' 적재, 멱등(같은 notification_id 재호출 시 중복 0).
- 동의 off/연락처 없음 → skipped. 웹훅 시크릿 불일치 → 401.
- (실발송은 키 발급 후) Resend/Solapi 샌드박스 1건.

## 9. 구현 순서
1. mig48 (profiles 연락처/동의 + notification_deliveries)
2. Edge Function `send-external-notification`(Dispatcher Mock 모드) + 시크릿(WEBHOOK_SECRET) 설정
3. Database Webhook(notifications INSERT) 연결
4. (선택) profiles 연락처/알림 설정 UI(마이페이지 토글)
5. Mock E2E → 키 발급 후 live 스위치

## ✅ 확정 5대 스펙 (반영 완료)
1. **profiles 연락처/동의**: `phone` + `notify_email`(기본 true) + `notify_sms`(기본 false).
2. **phone 자동 동기화**: `sync_profile_phone()`(DEFINER) 트리거 — `host_verifications`(총대 인증) / `bus_rider_private`(탑승 결제) 의 phone 을 `profiles.phone` 으로 최신 동기화.
3. **멱등 발송로그**: `notification_deliveries`(UNIQUE(notification_id,channel)) — 웹훅 재시도 중복발송 차단. SELECT 관리자만.
4. **Mock/Live Dispatcher**: `DISPATCH_MODE` env. mock=콘솔 출력+status='mock' / live=Resend(email)·Solapi(sms) 어댑터. 호출부 무변경 스위칭.
5. **핵심 타입 필터**: `EXTERNAL_TYPES`(bus_ordered·bus_finalized·tracking_registered·shipped·join_limit_warning·paid·issue) 만 외부 발송.

## 📦 구현 산출물 (완료)
- **mig48** `…0024_48_external_notify.sql` — profiles phone/notify_* + sync_profile_phone 트리거(host_verifications·bus_rider_private) + notification_deliveries(멱등·RLS 관리자만).
- **Edge Function** `supabase/functions/send-external-notification/index.ts` — 시크릿 검증 → 타입 필터 → service_role 연락처/동의 조회 → Dispatcher(Mock/Live, Resend·Solapi 어댑터) → 멱등 발송로그. `config.toml` verify_jwt=false. **배포 완료**(DISPATCH_MODE=mock, WEBHOOK_SECRET 설정).
- **index.html** — 내 계정 모달에 📧 이메일/💬 SMS 동의 토글 + `loadNotifyPrefs`/`saveNotifyPref`(profiles update).
- **검증** — persona_hardtest T0~T3(profiles 기본값·phone 동기화·발송로그 멱등·RLS) **전체 35/35** + Edge Function Mock 발송 7/7(401 차단·mock 발송·미동의 skip·로그 적재·멱등·타입필터).

## ⏳ 운영 잔여(별도)
- **Database Webhook 연결**: Dashboard → Database → Webhooks → `notifications` INSERT → `https://<ref>.functions.supabase.co/send-external-notification`, 헤더 `x-webhook-secret: <WEBHOOK_SECRET>`. (또는 pg_net 트리거+Vault 로 IaC 화 가능 — 시크릿 커밋 방지 위해 Vault 권장.)
- **실발송 전환**: Resend/Solapi 키 발급 → 시크릿 등록 → `DISPATCH_MODE=live`.
