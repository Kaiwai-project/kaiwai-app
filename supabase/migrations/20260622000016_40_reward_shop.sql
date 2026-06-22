-- ============================================================
-- 40_reward_shop.sql  —  [과제 9] 포인트 혜택 상점(리워드 교환소) 뼈대
--
--   목표: 제휴사가 생겼을 때 프론트/백엔드 코드 수정 없이
--         DB INSERT 만으로 리워드 상품·쿠폰 재고를 관리할 수 있는 동적 아키텍처.
--
--   설계 원칙(헌법 Zero Trust):
--     · 포인트 차감은 클라가 못 건드리는 _wallet_apply(DEFINER) 단일 관문으로만.
--     · 쿠폰 코드(coupon_code)는 '결제(교환)한 본인'에게만 노출 — RLS 로 물리 차단.
--     · 미사용 재고 '개수'만 필요한 화면은 DEFINER RPC 로 카운트만 내려준다(코드 비노출).
--     · 동시 교환 경쟁(한 쿠폰을 두 명이 가져가기)은 FOR UPDATE SKIP LOCKED 로 차단.
-- ============================================================

-- ── 0. 변동 사유 enum 에 'exchange'(리워드 교환) 추가 ──
--   ※ ALTER TYPE ADD VALUE 로 추가한 값은 '같은 트랜잭션에서 사용(DML)'할 수 없다.
--     아래에서 'exchange' 는 exchange_reward 함수 '본문'에만 등장(생성 시점엔 실행/조회 안 함,
--     런타임 캐스트) + 이 마이그레이션의 어떤 DML 도 'exchange' 를 쓰지 않으므로 안전하다.
alter type public.point_reason add value if not exists 'exchange';

-- ============================================================
-- 1. reward_items — 리워드 상품 카탈로그 (제휴사가 INSERT 만으로 추가)
-- ============================================================
create table if not exists public.reward_items (
  id          uuid        primary key default gen_random_uuid(),
  title       text        not null,
  description text,
  points_cost integer     not null,
  brand_name  text        not null,
  is_active   boolean     not null default true,
  created_at  timestamptz not null default now(),
  constraint reward_items_cost_positive check (points_cost > 0)
);
comment on table public.reward_items is '리워드 교환소 상품 카탈로그. 제휴사 추가는 INSERT 만으로 가능.';

-- ============================================================
-- 2. reward_coupons — 쿠폰 풀(재고)
--    user_id IS NULL  = 미사용 재고 / NOT NULL = 그 유저가 교환해 소유한 쿠폰
-- ============================================================
create table if not exists public.reward_coupons (
  id           uuid        primary key default gen_random_uuid(),
  item_id      uuid        references public.reward_items(id) on delete cascade,
  coupon_code  text        not null,
  user_id      uuid        references auth.users(id) on delete set null,  -- null = 미사용 재고
  exchanged_at timestamptz,
  created_at   timestamptz not null default now(),
  constraint reward_coupons_item_code_unique unique (item_id, coupon_code)
);
comment on table public.reward_coupons is '쿠폰 재고 풀. user_id IS NULL = 미사용 재고. 코드는 교환한 본인만 SELECT(RLS).';
create index if not exists idx_reward_coupons_item_unused
  on public.reward_coupons(item_id) where user_id is null;
create index if not exists idx_reward_coupons_user on public.reward_coupons(user_id);

-- ============================================================
-- 3. RLS
-- ============================================================
alter table public.reward_items   enable row level security;
alter table public.reward_coupons enable row level security;

-- reward_items: 인증 유저는 활성 상품만 조회
drop policy if exists "리워드: 활성 상품 조회" on public.reward_items;
create policy "리워드: 활성 상품 조회" on public.reward_items
  for select to authenticated
  using (is_active = true);

-- reward_coupons: 인증 유저는 '본인이 교환한 쿠폰'만 조회 (미사용 재고 코드는 비노출)
drop policy if exists "쿠폰: 본인 교환분만 조회" on public.reward_coupons;
create policy "쿠폰: 본인 교환분만 조회" on public.reward_coupons
  for select to authenticated
  using (user_id = auth.uid());
-- INSERT/UPDATE/DELETE 정책 없음 = 클라 직접 쓰기 불가(교환은 exchange_reward DEFINER 전용)

-- ============================================================
-- 4. exchange_reward — 리워드 교환(보안 핵심, SECURITY DEFINER)
--    순서: 인증 → 상품조회 → 재고쿠폰 락(SKIP LOCKED) → 포인트차감 → 쿠폰매핑
--    · 재고 먼저 잡고(없으면 즉시 롤백, 포인트 안 건드림) 그 다음 차감 → 안전.
--    · 차감은 _wallet_apply 가 잔액부족 시 raise → 트랜잭션 전체 롤백(쿠폰 락 해제).
-- ============================================================
create or replace function public.exchange_reward(p_item_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid         uuid := auth.uid();
  v_cost        integer;
  v_title       text;
  v_active      boolean;
  v_coupon_id   uuid;
  v_coupon_code text;
  v_new_bal     integer;
begin
  -- 1) 인증
  if v_uid is null then
    raise exception '인증이 필요합니다.' using errcode = '28000';
  end if;

  -- 2) 상품 조회
  select points_cost, title, is_active
    into v_cost, v_title, v_active
    from public.reward_items
   where id = p_item_id;
  if not found then
    raise exception '존재하지 않는 상품입니다.' using errcode = 'P0001';
  end if;
  if not v_active then
    raise exception '현재 교환할 수 없는 상품입니다.' using errcode = 'P0001';
  end if;

  -- 3) 미사용 쿠폰 1건 락 (동시 교환 경쟁 차단: 잠긴 행은 건너뜀)
  select id, coupon_code
    into v_coupon_id, v_coupon_code
    from public.reward_coupons
   where item_id = p_item_id and user_id is null
   order by created_at
   for update skip locked
   limit 1;
  if v_coupon_id is null then
    raise exception '선택하신 상품의 재고가 부족합니다.' using errcode = 'P0003';
  end if;

  -- 4) 포인트 차감 (잔액 부족 시 _wallet_apply 가 raise → 롤백, 원장에 'exchange' 기록)
  v_new_bal := public._wallet_apply(v_uid, -v_cost, 'exchange', p_item_id, 'exchanged for ' || v_title);

  -- 5) 쿠폰 매핑 (주인 지정)
  update public.reward_coupons
     set user_id = v_uid, exchanged_at = now()
   where id = v_coupon_id;

  -- 6) 결과
  return jsonb_build_object(
    'ok', true,
    'coupon_code', v_coupon_code,
    'balance', v_new_bal,
    'title', v_title
  );
end;
$$;
revoke all on function public.exchange_reward(uuid) from public, anon;
grant execute on function public.exchange_reward(uuid) to authenticated;

-- ============================================================
-- 5. reward_shop_items — 교환 탭용: 활성 상품 + 미사용 재고 '개수'만 반환
--    (쿠폰 RLS 는 본인 교환분만 허용하므로, 재고 카운트는 DEFINER 로 우회.
--     코드는 절대 노출하지 않고 count(*) 만 내려줘 보안 표면 최소화.)
-- ============================================================
create or replace function public.reward_shop_items()
returns table (
  id          uuid,
  title       text,
  description text,
  points_cost integer,
  brand_name  text,
  stock       integer
)
language sql
security definer
set search_path = public
as $$
  select i.id, i.title, i.description, i.points_cost, i.brand_name,
         (select count(*) from public.reward_coupons c
           where c.item_id = i.id and c.user_id is null)::integer as stock
    from public.reward_items i
   where i.is_active = true
   order by i.points_cost asc, i.created_at asc;
$$;
revoke all on function public.reward_shop_items() from public, anon;
grant execute on function public.reward_shop_items() to authenticated;

-- ============================================================
-- 6. 테스트용 초기 데이터 시딩 (멱등: on conflict do nothing)
-- ============================================================
insert into public.reward_items (id, title, description, points_cost, brand_name, is_active)
values
  ('11111111-1111-1111-1111-111111111111',
   '[제휴준비중] GS25 5,000원 금액권', '편의점에서 사용 가능한 모바일 금액권이에요.', 500, 'GS25', true),
  ('22222222-2222-2222-2222-222222222222',
   '[제휴준비중] 스타벅스 아메리카노 T', '스타벅스 아메리카노 톨 사이즈 모바일 교환권.', 1000, '스타벅스', true)
on conflict (id) do nothing;

insert into public.reward_coupons (item_id, coupon_code)
values
  ('11111111-1111-1111-1111-111111111111', 'GS25-MOCK-CODE-001'),
  ('11111111-1111-1111-1111-111111111111', 'GS25-MOCK-CODE-002'),
  ('11111111-1111-1111-1111-111111111111', 'GS25-MOCK-CODE-003'),
  ('11111111-1111-1111-1111-111111111111', 'GS25-MOCK-CODE-004'),
  ('11111111-1111-1111-1111-111111111111', 'GS25-MOCK-CODE-005'),
  ('22222222-2222-2222-2222-222222222222', 'STARBUCKS-MOCK-001'),
  ('22222222-2222-2222-2222-222222222222', 'STARBUCKS-MOCK-002'),
  ('22222222-2222-2222-2222-222222222222', 'STARBUCKS-MOCK-003'),
  ('22222222-2222-2222-2222-222222222222', 'STARBUCKS-MOCK-004'),
  ('22222222-2222-2222-2222-222222222222', 'STARBUCKS-MOCK-005')
on conflict (item_id, coupon_code) do nothing;
