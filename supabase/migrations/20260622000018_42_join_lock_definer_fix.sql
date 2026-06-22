-- ============================================================
-- 42_join_lock_definer_fix.sql  —  마이그41 핫픽스: 동시성 락을 DEFINER 로 위임
--
--   문제: 마이그41 이 join_coop_bus(SECURITY INVOKER) 안에서 직접
--           `select ... from buses ... for update` 로 락을 걸었는데,
--         PostgreSQL RLS 는 FOR UPDATE 시 대상 행이 UPDATE 정책까지 통과하길 요구한다.
--         buses 의 UPDATE 정책은 '방장 전용' → 탑승자(비방장)는 행이 안 보여 `not found`
--         → '존재하지 않는 공구입니다' 로 모든 탑승이 실패.
--         (마이그41 이전의 비잠금 SELECT 는 공개 SELECT 정책으로 통과했었음.)
--   해결: 코드베이스 기존 패턴(auto_close_bus_if_full 이 DEFINER 로 for update)과 동일하게
--         락 획득을 SECURITY DEFINER 헬퍼(_lock_bus_for_join)로 위임한다.
--         · DEFINER = postgres(BYPASSRLS) 로 실행 → RLS 무관하게 행 잠금 가능.
--         · 헬퍼는 호출자와 '같은 트랜잭션'에서 실행되므로 획득한 행 락은 커밋까지 유지
--           → 동시 탑승 직렬화(취약점2 방어)는 그대로 보장된다.
--         · join_coop_bus 자체는 INVOKER 유지(rider INSERT 는 RLS 통제).
-- ============================================================

-- ── 1. 버스 행 잠금 + 필요한 필드 반환 (DEFINER, 락 위임 전용) ──
create or replace function public._lock_bus_for_join(p_bus_id uuid)
returns table (out_goal integer, out_pprice integer, out_ordered boolean, out_tdomain text)
language plpgsql
security definer
set search_path = public
as $$
begin
  return query
    select b.goal, coalesce(b.product_price, 0), b.ordered, b.target_domain
      from public.buses b
     where b.id = p_bus_id
     for update;          -- 락은 호출 트랜잭션에서 커밋까지 유지 → 동시 탑승 직렬화
end;
$$;
revoke all on function public._lock_bus_for_join(uuid) from public, anon;
grant execute on function public._lock_bus_for_join(uuid) to authenticated;

-- ── 2. join_coop_bus 재정의 — 직접 FOR UPDATE → DEFINER 헬퍼 호출로 교체 ──
--    (시그니처 동일(14-arg)이라 create or replace 로 교체. 그 외 로직은 마이그41 과 동일.)
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
  v_rsum     integer;
  v_total    integer;
begin
  if v_uid is null then raise exception '인증이 필요합니다' using errcode = '28000'; end if;

  -- [방어 0.5] 잔액 fail-fast (비잠금)
  select balance into v_balance from public.user_wallets where user_id = v_uid;
  if v_balance is null then raise exception '지갑 정보를 찾을 수 없습니다' using errcode = 'P0001'; end if;
  if v_balance < 300 then
    raise exception '포인트가 부족합니다. (탑승 안심 수수료 300P 필요)' using errcode = 'P0001';
  end if;

  -- [방어 1] 데이터 폭탄: 텍스트 길이 상한 (락 전 fail-fast)
  if coalesce(length(p_nick),0)         > 40  then raise exception '닉네임이 너무 깁니다'   using errcode = 'P0001'; end if;
  if coalesce(length(p_product_name),0) > 200 then raise exception '상품명이 너무 깁니다'   using errcode = 'P0001'; end if;
  if coalesce(length(p_power),0)        > 60  then raise exception '도수 값이 비정상입니다' using errcode = 'P0001'; end if;
  if coalesce(length(p_real_name),0)    > 40  then raise exception '실명이 너무 깁니다'     using errcode = 'P0001'; end if;
  if coalesce(length(p_phone),0)        > 20  then raise exception '전화번호가 비정상입니다' using errcode = 'P0001'; end if;
  if coalesce(length(p_payer),0)        > 40  then raise exception '입금자명이 너무 깁니다' using errcode = 'P0001'; end if;
  if coalesce(length(p_address),0)      > 200 then raise exception '주소가 너무 깁니다'     using errcode = 'P0001'; end if;
  if coalesce(length(p_memo),0)         > 100 then raise exception '메모가 너무 깁니다'     using errcode = 'P0001'; end if;
  if coalesce(length(p_product_url),0)  > 500 then raise exception '상품 링크가 너무 깁니다' using errcode = 'P0001'; end if;

  -- [방어 2] 수량/단가 무결성 (락 전 fail-fast)
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

  -- ★[취약점2] 동시성 직렬화: buses 행 FOR UPDATE 잠금(DEFINER 헬퍼로 위임 → RLS 무관).
  --   락은 이 트랜잭션 커밋까지 유지되어, 아래 한도검사가 선행 탑승의 커밋을 반영한다.
  select out_goal, out_pprice, out_ordered, out_tdomain
    into v_goal, v_pprice, v_ordered, v_tdomain
    from public._lock_bus_for_join(p_bus_id);
  if not found then raise exception '존재하지 않는 공구입니다' using errcode = 'P0001'; end if;
  if v_ordered then
    raise exception '이미 마감되었거나 존재하지 않는 공구입니다' using errcode = 'P0001';
  end if;

  -- [방어 0] 중복 탑승 차단 (락 이후 → 동일 유저 동시 탑승도 직렬 차단)
  if exists (select 1 from public.bus_riders where bus_id = p_bus_id and user_id = v_uid) then
    raise exception '이미 탑승한 버스입니다' using errcode = 'P0001';
  end if;

  -- ★[취약점3] 구매처 도메인 락 서버 검증 — 지정 도메인이 URL 에 포함돼야 함
  if v_tdomain is not null and v_tdomain <> '' and coalesce(p_product_url, '') <> '' then
    if position(lower(v_tdomain) in lower(p_product_url)) = 0 then
      raise exception '해당 공구의 지정 구매처 상품만 탑승 가능합니다.' using errcode = 'P0001';
    end if;
  end if;

  -- [방어 4] 면세 한도(goal) 초과 차단 (FOR UPDATE 락 이후 읽으므로 동시 탑승 합도 정확)
  select coalesce(sum(yen * qty), 0) into v_rsum from public.bus_riders where bus_id = p_bus_id;
  v_total := v_pprice + v_rsum + (coalesce(p_yen, 0) * coalesce(p_qty, 1));
  if v_total > v_goal then
    raise exception '해당 공구의 남은 한도(엔)를 초과하여 탑승할 수 없습니다.' using errcode = 'P0001';
  end if;

  -- 300P 차감 (락+권위검증+원장 'board' 기록). 잔액부족이면 여기서 롤백.
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
