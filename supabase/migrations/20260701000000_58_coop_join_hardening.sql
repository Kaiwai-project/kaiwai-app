-- ============================================================
-- 58_coop_join_hardening.sql  —  보안 감사 대응 (CRITICAL C1 + Q5)
--
--   [C1 · CRITICAL] bus_riders / bus_rider_private 직접 INSERT 우회 차단
--     문제: join_coop_bus 는 SECURITY INVOKER 라 탑승 INSERT 를 RLS 정책
--           ("탑승은 본인+마감전", user_id=auth.uid() AND ordered=false)에 의존한다.
--           그런데 이 정책은 PostgREST 직접 INSERT(sb.from('bus_riders').insert(...))
--           도 그대로 허용 → 300P 보증금 차감·Zero-Yen 검증·면세 한도·도메인 락·
--           중복 탑승 방어를 전부 건너뛰고 장부 행을 위조할 수 있었다.
--           (join_coop_bus 가 유일한 정상 경로임은 마이그 확인 완료: bus_riders 로의
--            INSERT 는 14~43 의 join_coop_bus 재정의 안에만 존재.)
--     해결: bus_riders / bus_rider_private 에 BEFORE INSERT 가드 트리거를 걸고,
--           트랜잭션-로컬 GUC(app.coop_join_ok = 대상 bus_id)가 세팅된 경우에만 허용.
--           이 GUC 는 join_coop_bus 내부에서만 set_config(...,true) 로 설정되므로
--           PostgREST 직접 INSERT(임의 SQL 실행 불가)는 트리거에서 거부된다.
--
--   [Q5 · MEDIUM] 방장이 자기 공구에 탑승(직접 RPC)하여 인원/수고비를 부풀리는 것 차단
--           — 기존엔 클라이언트(coop-core.js)만 막고 있었음(서버 미검증).
--
--   ※ 기존 방어(mig14~44)는 유지·비파괴. join_coop_bus 본문은 mig43 과 동일하며
--     GUC 세팅 1줄 + 방장 탑승 차단 블록만 추가했다.
-- ============================================================

-- ── 1. 탑승 INSERT 가드 트리거 함수 ──────────────────────────
--   정식 절차(join_coop_bus)가 세팅한 트랜잭션-로컬 GUC 가 대상 버스와 일치할 때만 허용.
create or replace function public.guard_coop_rider_insert()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if current_setting('app.coop_join_ok', true) is distinct from new.bus_id::text then
    raise exception '탑승은 정식 절차로만 가능합니다.' using errcode = '42501';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_guard_coop_rider_insert on public.bus_riders;
create trigger trg_guard_coop_rider_insert
  before insert on public.bus_riders
  for each row execute function public.guard_coop_rider_insert();

drop trigger if exists trg_guard_coop_rider_private_insert on public.bus_rider_private;
create trigger trg_guard_coop_rider_private_insert
  before insert on public.bus_rider_private
  for each row execute function public.guard_coop_rider_insert();

-- ── 2. join_coop_bus 재정의 (mig43 기준 + GUC 세팅 + 방장 탑승 차단) ──
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
  v_owner    uuid;
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

  -- ★[Q5] 방장 본인 탑승 차단 (서버 강제) — 인원/수고비 부풀리기 방어
  select owner_id into v_owner from public.buses where id = p_bus_id;
  if v_owner = v_uid then
    raise exception '방장은 자신의 공구에 탑승할 수 없습니다' using errcode = 'P0001';
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

  -- ★[C1] 정식 절차 표식: 이 GUC 가 세팅된 INSERT 만 가드 트리거를 통과한다.
  --   is_local=true → 현재 트랜잭션 종료 시 자동 해제(아래 두 INSERT 를 커버).
  perform set_config('app.coop_join_ok', p_bus_id::text, true);

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
