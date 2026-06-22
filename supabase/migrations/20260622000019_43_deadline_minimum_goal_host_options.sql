-- ============================================================
-- 43_deadline_minimum_goal_host_options.sql  —  Phase 2 - Step 6 백엔드 구현
--
--   사양:
--   ① buses 테이블에 host_qty(기본 1), minimum_goal(기본 10000), expired_at 컬럼 추가
--   ② _lock_bus_for_join이 host_qty를 반영한 product_price 및 expired_at을 반환
--   ③ join_coop_bus에서 만료 여부 검증 및 총대 물품 수량(product_price * host_qty) 적용
--   ④ auto_close_bus_if_full / approve_mod_request에서 product_price * host_qty 적용
--   ⑤ guard_bus_order_start에서 minimum_goal 기준으로 검증하도록 하향 조정
--   ⑥ 마감된 공구방 수정 방지 트리거 추가
--   ⑦ 만료 및 미달 공구방 정리 및 보증금 전액 환불 RPC expire_overdue_buses() 추가
-- ============================================================

-- ── 1. buses 테이블 컬럼 추가 ──
alter table public.buses
  add column if not exists host_qty integer not null default 1 check (host_qty >= 1),
  add column if not exists minimum_goal integer not null default 10000 check (minimum_goal >= 0),
  add column if not exists expired_at timestamptz not null default now() + interval '24 hours';

-- ── 2. _lock_bus_for_join 재정의 (OUT 매개변수가 달라져서 DROP 후 재생성 필수) ──
drop function if exists public._lock_bus_for_join(uuid);

create or replace function public._lock_bus_for_join(p_bus_id uuid)
returns table (out_goal integer, out_pprice integer, out_ordered boolean, out_tdomain text, out_expired_at timestamptz)
language plpgsql
security definer
set search_path = public
as $$
begin
  return query
    select b.goal, coalesce(b.product_price * b.host_qty, 0), b.ordered, b.target_domain, b.expired_at
      from public.buses b
     where b.id = p_bus_id
     for update;
end;
$$;
revoke all on function public._lock_bus_for_join(uuid) from public, anon;
grant execute on function public._lock_bus_for_join(uuid) to authenticated;

-- ── 3. join_coop_bus 재정의 ──
create or replace function public.join_coop_bus(
  p_bus_id       uuid,
  p_nick         text,
  p_product_name text,
  p_qty          integer,
  p_yen          integer,
  p_power        text,
  p_method       text,
  p_amount       integer,
  p_real_name    text,
  p_phone        text,
  p_address      text,
  p_payer        text,
  p_memo         text default null,
  p_product_url  text default null
)
returns uuid
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_uid      uuid := auth.uid();
  v_rider_id uuid;
  v_goods    integer;
  v_fee      integer;
  v_balance  integer;
  v_goal     integer;
  v_pprice   integer;
  v_ordered  boolean;
  v_tdomain  text;
  v_expired_at timestamptz;
  v_rsum     integer;
  v_total    integer;
begin
  if v_uid is null then raise exception '인증이 필요합니다' using errcode = '28000'; end if;

  -- [방어 0.5] 잔액 fail-fast
  select balance into v_balance from public.user_wallets where user_id = v_uid;
  if v_balance is null then raise exception '지갑 정보를 찾을 수 없습니다' using errcode = 'P0001'; end if;
  if v_balance < 300 then
    raise exception '포인트가 부족합니다. (탑승 안심 수수료 300P 필요)' using errcode = 'P0001';
  end if;

  -- [방어 1] 데이터 폭탄: 텍스트 길이 상한
  if coalesce(length(p_nick),0)         > 40  then raise exception '닉네임이 너무 깁니다'   using errcode = 'P0001'; end if;
  if coalesce(length(p_product_name),0) > 200 then raise exception '상품명이 너무 깁니다'   using errcode = 'P0001'; end if;
  if coalesce(length(p_power),0)        > 60  then raise exception '도수 값이 비정상입니다' using errcode = 'P0001'; end if;
  if coalesce(length(p_real_name),0)    > 40  then raise exception '실명이 너무 깁니다'     using errcode = 'P0001'; end if;
  if coalesce(length(p_phone),0)        > 20  then raise exception '전화번호가 비정상입니다' using errcode = 'P0001'; end if;
  if coalesce(length(p_payer),0)        > 40  then raise exception '입금자명이 너무 깁니다' using errcode = 'P0001'; end if;
  if coalesce(length(p_address),0)      > 200 then raise exception '주소가 너무 깁니다'     using errcode = 'P0001'; end if;
  if coalesce(length(p_memo),0)         > 100 then raise exception '메모가 너무 깁니다'     using errcode = 'P0001'; end if;
  if coalesce(length(p_product_url),0)  > 500 then raise exception '상품 링크가 너무 깁니다' using errcode = 'P0001'; end if;

  -- [방어 2] 수량/단가 무결성
  if p_qty <= 0 or p_qty > 100 then raise exception '수량이 올바르지 않습니다' using errcode = 'P0001'; end if;
  if p_yen < 0 or p_yen > 1000000 then raise exception '단가가 올바르지 않습니다' using errcode = 'P0001'; end if;
  if p_method not in ('conv','home','etc') then raise exception '수령방법이 올바르지 않습니다' using errcode = 'P0001'; end if;

  -- [방어 3] 금액 위변조(Zero-Yen) 강제 검증
  v_goods := p_yen * p_qty * 9;
  v_fee   := case p_method when 'conv' then 1800 when 'home' then 3500 else p_amount - v_goods end;
  if p_method in ('conv','home') then
    if p_amount <> v_goods + v_fee then raise exception '금액이 변조되었습니다.' using errcode = 'P0001'; end if;
  else
    if p_amount < v_goods or (p_amount - v_goods) > 100000 then raise exception '금액이 변조되었습니다.' using errcode = 'P0001'; end if;
  end if;

  -- [취약점2] 동시성 직렬화 및 만료 시간 확인
  select out_goal, out_pprice, out_ordered, out_tdomain, out_expired_at
    into v_goal, v_pprice, v_ordered, v_tdomain, v_expired_at
    from public._lock_bus_for_join(p_bus_id);
  if not found then raise exception '존재하지 않는 공구입니다' using errcode = 'P0001'; end if;
  if v_ordered then
    raise exception '이미 마감되었거나 존재하지 않는 공구입니다' using errcode = 'P0001';
  end if;
  
  -- 마감 시간 만료 검증
  if now() > v_expired_at then
    raise exception '마감 시간이 지난 공구입니다' using errcode = 'P0001';
  end if;

  -- [방어 0] 중복 탑승 차단
  if exists (select 1 from public.bus_riders where bus_id = p_bus_id and user_id = v_uid) then
    raise exception '이미 탑승한 버스입니다' using errcode = 'P0001';
  end if;

  -- [취약점3] 구매처 도메인 락 서버 검증
  if v_tdomain is not null and v_tdomain <> '' and coalesce(p_product_url, '') <> '' then
    if position(lower(v_tdomain) in lower(p_product_url)) = 0 then
      raise exception '해당 공구의 지정 구매처 상품만 탑승 가능합니다.' using errcode = 'P0001';
    end if;
  end if;

  -- [방어 4] 면세 한도(goal) 초과 차단 (v_pprice는 product_price * host_qty 임)
  select coalesce(sum(yen * qty), 0) into v_rsum from public.bus_riders where bus_id = p_bus_id;
  v_total := v_pprice + v_rsum + (coalesce(p_yen, 0) * coalesce(p_qty, 1));
  if v_total > v_goal then
    raise exception '해당 공구의 남은 한도(엔)를 초과하여 탑승할 수 없습니다.' using errcode = 'P0001';
  end if;

  -- 300P 차감
  perform public.debit_coop_deposit(300, p_bus_id);

  insert into public.bus_riders
    (bus_id, user_id, nick, product_name, qty, yen, power, method, amount, paid, issue, has_addr, memo, product_url)
  values
    (p_bus_id, v_uid, p_nick, p_product_name, coalesce(p_qty,1), coalesce(p_yen,0), p_power,
     coalesce(p_method,'conv'), coalesce(p_amount,0), false, null, true, p_memo, p_product_url)
  returning id into v_rider_id;

  insert into public.bus_rider_private
    (rider_id, bus_id, user_id, real_name, phone, address, payer)
  values
    (v_rider_id, p_bus_id, v_uid, p_real_name, p_phone, p_address, p_payer);

  -- 100% 달성 시 자동 마감
  perform public.auto_close_bus_if_full(p_bus_id);

  return v_rider_id;
end;
$$;
revoke all on function public.join_coop_bus(uuid, text, text, integer, integer, text, text, integer, text, text, text, text, text, text) from public, anon;
grant execute on function public.join_coop_bus(uuid, text, text, integer, integer, text, text, integer, text, text, text, text, text, text) to authenticated;


-- ── 4. auto_close_bus_if_full 재정의 ──
create or replace function public.auto_close_bus_if_full(p_bus_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_goal    integer;
  v_pprice  integer;
  v_ordered boolean;
  v_total   integer;
begin
  select goal, coalesce(product_price * host_qty, 0), ordered
    into v_goal, v_pprice, v_ordered
    from public.buses where id = p_bus_id for update;
  if not found or v_ordered then return false; end if;

  select v_pprice + coalesce(sum(yen * qty), 0)
    into v_total
    from public.bus_riders where bus_id = p_bus_id;

  if v_total >= v_goal then
    update public.buses set ordered = true where id = p_bus_id;
    return true;
  end if;
  return false;
end;
$$;
revoke all on function public.auto_close_bus_if_full(uuid) from public, anon;
grant execute on function public.auto_close_bus_if_full(uuid) to authenticated;


-- ── 5. approve_mod_request 재정의 ──
create or replace function public.approve_mod_request(p_rider_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid    uuid := auth.uid();
  v_bus_id uuid;
  v_owner  uuid;
  v_req    jsonb;
  v_yen    integer;
  v_qty    integer;
  v_power  text;
  v_method text;
  v_goods  integer;
  v_amount integer;
  v_goal   integer;
  v_pprice integer;
  v_others integer;
  v_total  integer;
  v_closed boolean;
  v_rider  uuid;
begin
  if v_uid is null then raise exception '인증이 필요합니다' using errcode = '28000'; end if;

  select bus_id, mod_request, yen, user_id
    into v_bus_id, v_req, v_yen, v_rider
    from public.bus_riders where id = p_rider_id for update;
  if not found then raise exception '대상 라이더를 찾을 수 없습니다' using errcode = 'P0001'; end if;

  select owner_id into v_owner from public.buses where id = v_bus_id;
  if v_owner is distinct from v_uid then
    raise exception '방장만 수정 요청을 승인할 수 있습니다' using errcode = '42501';
  end if;
  if v_req is null then raise exception '대기 중인 수정 요청이 없습니다' using errcode = 'P0001'; end if;

  v_qty    := coalesce((v_req->>'qty')::int, 1);
  v_power  := coalesce(v_req->>'power', '');
  v_method := coalesce(v_req->>'method', 'conv');
  if v_qty < 1 or v_qty > 100 then raise exception '수량이 올바르지 않습니다' using errcode = 'P0001'; end if;
  if v_method not in ('conv','home','etc') then raise exception '수령 방법이 올바르지 않습니다' using errcode = 'P0001'; end if;
  if char_length(v_power) > 60 then raise exception '도수 값이 올바르지 않습니다' using errcode = 'P0001'; end if;

  -- 면세 한도 방어 (product_price * host_qty 적용)
  select goal, coalesce(product_price * host_qty, 0) into v_goal, v_pprice from public.buses where id = v_bus_id;
  select coalesce(sum(yen * qty), 0) into v_others
    from public.bus_riders where bus_id = v_bus_id and id <> p_rider_id;
  v_total := v_pprice + v_others + (v_yen * v_qty);
  if v_total > v_goal then
    raise exception '수량을 늘리면 공구방의 남은 면세 한도를 초과하게 되어 승인할 수 없습니다.' using errcode = 'P0001';
  end if;

  v_goods  := v_yen * v_qty * 9;
  v_amount := v_goods + case v_method when 'conv' then 1800 when 'home' then 3500 else 0 end;

  update public.bus_riders
     set qty = v_qty, power = v_power, method = v_method, amount = v_amount, mod_request = null
   where id = p_rider_id;

  v_closed := public.auto_close_bus_if_full(v_bus_id);

  -- 탑승자에게 승인 알림
  perform public._notify(v_rider, '✅ 수정 요청 승인', '총대가 수량/도수 변경을 승인했어요. 변경된 금액을 확인해주세요!', 'mod_approved', v_bus_id);

  return jsonb_build_object('ok', true, 'rider_id', p_rider_id, 'qty', v_qty, 'amount', v_amount, 'closed', coalesce(v_closed, false));
end;
$$;
revoke all on function public.approve_mod_request(uuid) from public, anon;
grant execute on function public.approve_mod_request(uuid) to authenticated;


-- ── 6. guard_bus_order_start 재정의 (최소 출발 한도 반영) ──
create or replace function public.guard_bus_order_start()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_current  integer;
  v_count    integer;
  v_is_admin boolean;
  v_reward   constant integer := 150;   -- 300P 수수료의 50%
begin
  if new.ordered = true and coalesce(old.ordered, false) = false then
    v_is_admin := public.is_app_admin(auth.uid());

    -- 조기 출발 차단(관리자 우회) — 달성 = 총대 본인 물품가 (수량 곱) + 탑승자 장부 합산
    if not v_is_admin then
      select coalesce(sum(yen * qty), 0) into v_current
        from public.bus_riders where bus_id = new.id;
      v_current := v_current + coalesce(new.product_price * new.host_qty, 0);   -- ★ 총대 물품가 (수량 반영) 포함
      if v_current < new.minimum_goal then
        raise exception '최소 출발 금액 달성 후 출발할 수 있습니다. (현재 %엔 / 최소 %엔)', v_current, new.minimum_goal
          using errcode = 'P0001';
      end if;
    end if;

    -- 총대 수고비 지급
    select count(*) into v_count from public.bus_riders where bus_id = new.id;
    if v_count > 0 then
      perform public._wallet_apply(new.owner_id, v_count * v_reward, 'host_reward', new.id,
                                   'coop completion reward 50% x ' || v_count);
    end if;
  end if;
  return new;
end;
$$;


-- ── 7. buses 마감 후 상품 정보 수정 차단 트리거 추가 ──
create or replace function public.guard_bus_update_after_ordered()
returns trigger
language plpgsql
as $$
begin
  -- 이미 마감된 공구의 경우 정보 수정 제한 (어드민 제외)
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

drop trigger if exists trg_guard_bus_update_after_ordered on public.buses;
create trigger trg_guard_bus_update_after_ordered
  before update on public.buses
  for each row execute function public.guard_bus_update_after_ordered();


-- ── 8. 만료 무산 처리 RPC expire_overdue_buses() 작성 ──
create or replace function public.expire_overdue_buses()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_bus_rec record;
  v_current integer;
  v_deposit constant integer := 300;
  v_rrec record;
  v_exploded_count integer := 0;
  v_refunded_count integer := 0;
begin
  -- 만료되었고 아직 ordered=false인 공구들을 순회
  for v_bus_rec in
    select id, minimum_goal, product_price, host_qty from public.buses
     where expired_at < now() and ordered = false
     for update   -- 동시 정리 충돌 방지 락
  loop
    -- 누적액 계산 (총대 물품 총합 + 참여자 장부 합)
    select coalesce(v_bus_rec.product_price * v_bus_rec.host_qty, 0) + coalesce(sum(yen * qty), 0)
      into v_current
      from public.bus_riders where bus_id = v_bus_rec.id;

    -- 최소 금액 미달 시 폭파 (자연 무산)
    if v_current < v_bus_rec.minimum_goal then
      -- 탑승 참여자 보증금 300P 환불
      for v_rrec in
        select user_id as uid, count(*)::int as cnt
          from public.bus_riders where bus_id = v_bus_rec.id group by user_id
      loop
        perform public._wallet_apply(v_rrec.uid, v_rrec.cnt * v_deposit, 'refund', v_bus_rec.id, 'coop timeout natural refund');
        v_refunded_count := v_refunded_count + v_rrec.cnt;
      end loop;

      -- 버스 삭제 (cascade로 riders 및 rider_private 삭제됨)
      delete from public.buses where id = v_bus_rec.id;
      v_exploded_count := v_exploded_count + 1;
    end if;
  end loop;

  return jsonb_build_object(
    'exploded_buses', v_exploded_count,
    'refunded_riders', v_refunded_count
  );
end;
$$;

revoke all on function public.expire_overdue_buses() from public, anon;
grant execute on function public.expire_overdue_buses() to authenticated;
