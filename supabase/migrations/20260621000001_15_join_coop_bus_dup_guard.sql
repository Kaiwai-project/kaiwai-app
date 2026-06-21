-- ============================================================
-- 15_join_coop_bus_dup_guard.sql
--   join_coop_bus RPC 보강: 중복 탑승(1인 다역) 원천 차단.
--   14번 함수를 create or replace 로 교체 (적용된 14 파일은 수정하지 않음).
--   추가: BEGIN 직하에 "같은 bus_id + user_id 로 이미 탑승했으면 예외".
--   나머지 로직(길이/수량/금액/마감 검증, 원자적 2-INSERT)은 14와 동일.
-- ============================================================
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
  p_memo         text default null
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
begin
  if v_uid is null then
    raise exception '인증이 필요합니다' using errcode = '28000';
  end if;

  -- ── [방어 0] 중복 탑승(1인 다역) 차단 ──
  if exists (select 1 from public.bus_riders where bus_id = p_bus_id and user_id = v_uid) then
    raise exception '이미 탑승한 버스입니다' using errcode = 'P0001';
  end if;

  -- ── [방어 1] 데이터 폭탄(Data Bombing): 텍스트 길이 상한 ──
  if coalesce(length(p_nick),0)         > 40  then raise exception '닉네임이 너무 깁니다'   using errcode = 'P0001'; end if;
  if coalesce(length(p_product_name),0) > 200 then raise exception '상품명이 너무 깁니다'   using errcode = 'P0001'; end if;
  if coalesce(length(p_power),0)        > 60  then raise exception '도수 값이 비정상입니다' using errcode = 'P0001'; end if;
  if coalesce(length(p_real_name),0)    > 40  then raise exception '실명이 너무 깁니다'     using errcode = 'P0001'; end if;
  if coalesce(length(p_phone),0)        > 20  then raise exception '전화번호가 비정상입니다' using errcode = 'P0001'; end if;
  if coalesce(length(p_payer),0)        > 40  then raise exception '입금자명이 너무 깁니다' using errcode = 'P0001'; end if;
  if coalesce(length(p_address),0)      > 200 then raise exception '주소가 너무 깁니다'     using errcode = 'P0001'; end if;
  if coalesce(length(p_memo),0)         > 100 then raise exception '메모가 너무 깁니다'     using errcode = 'P0001'; end if;

  -- ── [방어 2] 수량/단가 무결성: 음수·0·과다 차단 ──
  if p_qty <= 0 or p_qty > 100 then
    raise exception '수량이 올바르지 않습니다' using errcode = 'P0001';
  end if;
  if p_yen < 0 or p_yen > 1000000 then
    raise exception '단가가 올바르지 않습니다' using errcode = 'P0001';
  end if;
  if p_method not in ('conv','home','etc') then
    raise exception '수령방법이 올바르지 않습니다' using errcode = 'P0001';
  end if;

  -- ── [방어 3] 금액 위변조(Zero-Yen Hack) 강제 검증 ──
  v_goods := p_yen * p_qty * 9;
  v_fee   := case p_method when 'conv' then 1800
                           when 'home' then 3500
                           else p_amount - v_goods end;
  if p_method in ('conv','home') then
    if p_amount <> v_goods + v_fee then
      raise exception '금액이 변조되었습니다.' using errcode = 'P0001';
    end if;
  else
    if p_amount < v_goods or (p_amount - v_goods) > 100000 then
      raise exception '금액이 변조되었습니다.' using errcode = 'P0001';
    end if;
  end if;

  -- ── 고스트 라이더 방어: 마감/부재 버스엔 탑승 불가 ──
  if not exists (select 1 from public.buses b where b.id = p_bus_id and b.ordered = false) then
    raise exception '이미 마감되었거나 존재하지 않는 공구입니다' using errcode = 'P0001';
  end if;

  -- ① 투명 장부 INSERT
  insert into public.bus_riders
    (bus_id, user_id, nick, product_name, qty, yen, power, method, amount, paid, issue, has_addr, memo)
  values
    (p_bus_id, v_uid, p_nick, p_product_name, coalesce(p_qty,1), coalesce(p_yen,0), p_power,
     coalesce(p_method,'conv'), coalesce(p_amount,0), false, null, true, p_memo)
  returning id into v_rider_id;

  -- ② 개인정보 INSERT (실패 시 ①까지 함께 롤백 = 원자성)
  insert into public.bus_rider_private
    (rider_id, bus_id, user_id, real_name, phone, address, payer)
  values
    (v_rider_id, p_bus_id, v_uid, p_real_name, p_phone, p_address, p_payer);

  return v_rider_id;
end;
$$;
