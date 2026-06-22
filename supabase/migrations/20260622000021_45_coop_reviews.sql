-- ============================================================
-- 45_coop_reviews.sql  —  [Step 8] 상호 평점 + 매너 프로필
--
--   확정 스펙:
--   ① 평가 시점: buses.finalized = true (배송 완료 처리) 이후에만 상호 평가 활성화
--   ② 부정 배지 누적 3회+ 유저는 매너 집계에 is_warned=true 반환(프론트 ⚠️)
--      — 외부 공개는 긍정 배지만 카운트(부정 배지 라벨은 비노출)
--   ③ coop_reviews = rating(1~5) + badges(text[]) 만 (코멘트 컬럼 없음) + 중복/셀프 방지
--   ④ 평가 알림 없음(조용히 기록, Lazy 집계)
--   ⑤ review_badges 시드(총대/탑승자 × 긍정/부정)
--
--   보안: 원본 리뷰는 작성자 본인만 SELECT(피평가자 비공개=보복 방지),
--         쓰기는 submit_coop_review(DEFINER) 전용, 집계는 get_manner_profiles(DEFINER)만.
-- ============================================================

-- ── 1. buses 배송 완료 상태 + finalize 우회 트리거 ──
alter table public.buses
  add column if not exists finalized    boolean    not null default false,
  add column if not exists finalized_at timestamptz;
comment on column public.buses.finalized is '배송 완료 처리 여부. true 이후에만 상호 평가 가능.';

-- guard_bus_update_after_ordered 재정의: 마감 후에도 'finalize 전용 경로'는 통과시킴.
--   (finalize_coop RPC 가 트랜잭션-로컬 GUC app.allow_finalize 를 세팅 → 그 외 마감 수정은 계속 차단)
create or replace function public.guard_bus_update_after_ordered()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  -- 배송 완료 처리(finalize_coop)는 우회 (해당 RPC 만 GUC 를 켬)
  if coalesce(current_setting('app.allow_finalize', true), '') = '1' then
    return new;
  end if;

  -- 이미 마감된 공구는 수정 제한 (어드민 제외)
  if old.ordered = true then
    if not public.is_app_admin(auth.uid()) then
      raise exception '마감된 공구는 수정할 수 없습니다' using errcode = 'P0001';
    end if;
  end if;

  -- 마감(ordered=true)으로 전환할 때 핵심 상품 정보 동시 조작 방어
  if old.ordered = false and new.ordered = true then
    if new.product_name is distinct from old.product_name or
       new.product_price is distinct from old.product_price or
       new.host_qty is distinct from old.host_qty or
       new.goal is distinct from old.goal or
       new.minimum_goal is distinct from old.minimum_goal then
      raise exception '마감 처리 중에는 상품 정보를 변경할 수 없습니다' using errcode = 'P0001';
    end if;
  end if;

  return new;
end;
$$;

-- finalize_coop — 방장이 배송 완료 처리(평가 활성화). DEFINER + 행잠금 + GUC 우회.
create or replace function public.finalize_coop(p_bus_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid     uuid := auth.uid();
  v_owner   uuid;
  v_ordered boolean;
  v_final   boolean;
begin
  if v_uid is null then raise exception '인증이 필요합니다' using errcode = '28000'; end if;
  select owner_id, ordered, finalized into v_owner, v_ordered, v_final
    from public.buses where id = p_bus_id for update;
  if not found then raise exception '존재하지 않는 공구입니다' using errcode = 'P0001'; end if;
  if v_owner <> v_uid then raise exception '방장만 배송 완료 처리할 수 있습니다' using errcode = '42501'; end if;
  if not v_ordered then raise exception '주문(마감) 후에만 배송 완료 처리할 수 있습니다' using errcode = 'P0001'; end if;
  if v_final then return false; end if;   -- 이미 완료

  perform set_config('app.allow_finalize', '1', true);   -- 트랜잭션-로컬 → 트리거 우회
  update public.buses set finalized = true, finalized_at = now() where id = p_bus_id;
  return true;
end;
$$;
revoke all on function public.finalize_coop(uuid) from public, anon;
grant execute on function public.finalize_coop(uuid) to authenticated;

-- ── 2. review_badges (동적 배지 룩업) ──
create table if not exists public.review_badges (
  code        text primary key,
  label       text not null,
  emoji       text,
  target_role text not null check (target_role in ('host','rider')),  -- 이 배지를 받는 대상
  polarity    text not null check (polarity in ('positive','negative')),
  sort_order  int  not null default 0,
  is_active   boolean not null default true
);
alter table public.review_badges enable row level security;
drop policy if exists "배지: 활성 조회" on public.review_badges;
create policy "배지: 활성 조회" on public.review_badges
  for select to authenticated using (is_active = true);
-- 쓰기 정책 없음 = 운영자(service_role/대시보드)만 관리

insert into public.review_badges(code,label,emoji,target_role,polarity,sort_order) values
  -- 총대 평가용 (Rider -> Host)
  ('host_kind',        '친절해요',       '🎀','host','positive',1),
  ('host_fast_reply',  '답장이 빨라요',  '⚡','host','positive',2),
  ('host_careful_pack','포장이 꼼꼼해요','📦','host','positive',3),
  ('host_fast_ship',   '배송이 신속해요','🚀','host','positive',4),
  ('host_slow_reply',  '답장이 늦어요',  '🐌','host','negative',10),
  ('host_ship_delay',  '배송이 지연돼요','⏳','host','negative',11),
  ('host_poor_pack',   '포장이 아쉬워요','💔','host','negative',12),
  -- 탑승자 평가용 (Host -> Rider)
  ('rider_fast_pay',   '입금이 빨라요',  '💰','rider','positive',1),
  ('rider_manner',     '매너가 좋아요',  '🌸','rider','positive',2),
  ('rider_good_comm',  '소통이 잘돼요',  '💬','rider','positive',3),
  ('rider_slow_pay',   '입금이 늦어요',  '⏰','rider','negative',10),
  ('rider_ghost',      '잠수가 잦아요',  '💤','rider','negative',11),
  ('rider_rude',       '비매너예요',     '😢','rider','negative',12)
on conflict (code) do nothing;

-- ── 3. coop_reviews (rating + badges 만, 코멘트 없음) ──
create table if not exists public.coop_reviews (
  id          uuid primary key default gen_random_uuid(),
  bus_id      uuid not null references public.buses(id)  on delete cascade,
  reviewer_id uuid not null references auth.users(id)    on delete cascade,
  reviewee_id uuid not null references auth.users(id)    on delete cascade,
  direction   text not null check (direction in ('rider_to_host','host_to_rider')),
  rating      int  not null check (rating between 1 and 5),
  badges      text[] not null default '{}',
  created_at  timestamptz not null default now(),
  constraint coop_reviews_once    unique (bus_id, reviewer_id, reviewee_id),   -- 중복 리뷰 방지
  constraint coop_reviews_no_self check (reviewer_id <> reviewee_id)           -- 셀프 리뷰 방지
);
create index if not exists idx_coop_reviews_reviewee on public.coop_reviews(reviewee_id);

alter table public.coop_reviews enable row level security;
-- 작성자 본인만 원본 조회(피평가자/타인 불가 = 보복 방지). 집계는 DEFINER 함수 전용.
drop policy if exists "리뷰: 작성자 본인만 조회" on public.coop_reviews;
create policy "리뷰: 작성자 본인만 조회" on public.coop_reviews
  for select to authenticated using (reviewer_id = auth.uid());
-- INSERT/UPDATE/DELETE 정책 없음 = submit_coop_review 전용

-- ── 4. submit_coop_review (DEFINER, 모든 검증 + INSERT) ──
create or replace function public.submit_coop_review(
  p_bus_id uuid, p_reviewee_id uuid, p_rating int, p_badges text[]
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_owner uuid; v_ordered boolean; v_final boolean;
  v_direction text; v_target_role text; v_id uuid;
begin
  if v_uid is null then raise exception '인증이 필요합니다' using errcode='28000'; end if;
  if v_uid = p_reviewee_id then raise exception '본인은 평가할 수 없습니다' using errcode='P0001'; end if;
  if p_rating is null or p_rating < 1 or p_rating > 5 then raise exception '별점은 1~5 입니다' using errcode='P0001'; end if;
  if coalesce(array_length(p_badges,1),0) > 5 then raise exception '배지가 너무 많습니다' using errcode='P0001'; end if;

  select owner_id, ordered, finalized into v_owner, v_ordered, v_final
    from public.buses where id = p_bus_id;
  if not found then raise exception '존재하지 않는 공구입니다' using errcode='P0001'; end if;
  if not v_final then raise exception '배송 완료된 공구만 평가할 수 있습니다' using errcode='P0001'; end if;

  if v_uid = v_owner then
    -- 총대 → 탑승자
    if not exists(select 1 from public.bus_riders where bus_id=p_bus_id and user_id=p_reviewee_id) then
      raise exception '해당 공구의 탑승자만 평가할 수 있습니다' using errcode='P0001';
    end if;
    v_direction := 'host_to_rider'; v_target_role := 'rider';
  else
    -- 탑승자 → 총대
    if not exists(select 1 from public.bus_riders where bus_id=p_bus_id and user_id=v_uid) then
      raise exception '해당 공구의 참여자만 평가할 수 있습니다' using errcode='P0001';
    end if;
    if p_reviewee_id <> v_owner then raise exception '탑승자는 총대만 평가할 수 있습니다' using errcode='P0001'; end if;
    v_direction := 'rider_to_host'; v_target_role := 'host';
  end if;

  -- 배지 화이트리스트: 전달 배지가 모두 그 대상 role 의 활성 배지여야
  if coalesce(array_length(p_badges,1),0) > 0 then
    if exists (
      select 1 from unnest(p_badges) c
      where c not in (select code from public.review_badges where is_active and target_role = v_target_role)
    ) then raise exception '유효하지 않은 배지가 포함되어 있습니다' using errcode='P0001'; end if;
  end if;

  insert into public.coop_reviews(bus_id,reviewer_id,reviewee_id,direction,rating,badges)
  values (p_bus_id, v_uid, p_reviewee_id, v_direction, p_rating, coalesce(p_badges,'{}'))
  returning id into v_id;   -- UNIQUE 위반(23505) → 클라 "이미 평가했어요"
  return v_id;
end; $$;
revoke all on function public.submit_coop_review(uuid,uuid,int,text[]) from public, anon;
grant execute on function public.submit_coop_review(uuid,uuid,int,text[]) to authenticated;

-- ── 5. get_manner_profiles (DEFINER 배치 집계: 평균·개수·긍정배지·is_warned) ──
--    is_warned = 받은 부정 배지 누적 3회 이상. 긍정 배지만 top_badges 로 노출(부정 비노출).
create or replace function public.get_manner_profiles(p_user_ids uuid[])
returns table (user_id uuid, avg_rating numeric, review_count int, top_badges jsonb, is_warned boolean)
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
  bdg as (   -- 펼친 배지 + 극성
    select b.reviewee_id, x.code, rb.polarity
      from base b
      cross join lateral unnest(b.badges) x(code)
      join public.review_badges rb on rb.code = x.code
  ),
  pos as (
    select reviewee_id, code, count(*)::int as cnt
      from bdg where polarity='positive' group by reviewee_id, code
  ),
  neg as (
    select reviewee_id, count(*)::int as ncnt
      from bdg where polarity='negative' group by reviewee_id
  )
  select a.reviewee_id, a.avg_rating, a.review_count,
         coalesce((select jsonb_agg(jsonb_build_object('code',p.code,'cnt',p.cnt) order by p.cnt desc, p.code)
                     from pos p where p.reviewee_id=a.reviewee_id), '[]'::jsonb) as top_badges,
         coalesce((select n.ncnt from neg n where n.reviewee_id=a.reviewee_id), 0) >= 3 as is_warned
    from agg a;
$$;
revoke all on function public.get_manner_profiles(uuid[]) from public, anon;
grant execute on function public.get_manner_profiles(uuid[]) to authenticated;
