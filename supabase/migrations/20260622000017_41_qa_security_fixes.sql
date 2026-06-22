-- ============================================================
-- 41_qa_security_fixes.sql  —  블랙컨슈머 QA 발견 3대 취약점 패치
--
--   [취약점1] 총대 직접 삭제 시 보증금 증발 + 패널티 우회
--     보증금 300P 는 '탑승(join)' 시점에 차감된다. 기존 buses DELETE 정책은
--     '입금자(paid) 0명' 만 막아서, paid=false(렌즈값 미입금)지만 이미 300P 를 낸
--     참여자가 있는 방을 방장이 직접 DELETE → 참여자 보증금이 환불 없이 증발하고
--     방장은 3진아웃 패널티도 받지 않았다. → 참여자가 1명이라도 있으면 직접 DELETE 금지.
--        참여자 있는 방의 무산은 반드시 rpc_cancel_coop_by_host(DEFINER, RLS 우회)를 거쳐
--        보증금 자동 환불 + 패널티가 적용되도록 강제한다.
--
--   [취약점2] 동시 탑승 시 면세 한도(goal) 초과 동시성 문제
--     마이그36 의 한도검사는 buses/bus_riders 를 비잠금으로 읽어, 두 탑승 트랜잭션이
--     동시에 '아직 여유 있음'으로 통과 → 둘 다 INSERT → goal 초과(관부가세 폭탄).
--     → join_coop_bus 시작부에서 buses 행을 FOR UPDATE 로 잠가 동시 탑승을 완전 직렬화.
--
--   [취약점3] DB 단 도메인 락 우회
--     도메인 검증이 프론트(_boardDomainOk)에만 있어, API 직접 호출로 우회 가능했다.
--     → buses.target_domain 이 있고 p_product_url 이 오면 서버에서도 포함여부 검증.
-- ============================================================

-- ── 1. bus_riders 에 product_url 컬럼 (탑승자가 담은 상품 링크, 공개 장부) ──
alter table public.bus_riders
  add column if not exists product_url text;
comment on column public.bus_riders.product_url is '탑승 시 입력한 상품 링크(도메인 락 서버검증용). 공개 장부 컬럼.';

-- ── 2. buses DELETE 정책 강화: 참여자(rider) 0명일 때만 직접 삭제 허용 ──
--    (참여자 1명+ 이면 rpc_cancel_coop_by_host 경유 강제 → 환불+패널티)
drop policy if exists "방 삭제: 방장+미주문+입금자0" on public.buses;
drop policy if exists "방 삭제: 방장+미주문+참여자0" on public.buses;
create policy "방 삭제: 방장+미주문+참여자0" on public.buses
  for delete to authenticated
  using (
    owner_id = auth.uid()
    and ordered = false
    and not exists (
      select 1 from public.bus_riders r where r.bus_id = buses.id
    )
  );

-- ── 3. join_coop_bus 재정의 ──
--    · 시그니처 변경(p_product_url 추가) → 기존 13-arg 함수 DROP 후 재생성(오버로드 충돌 방지).
--    · buses 행 FOR UPDATE 잠금으로 동시 탑승 직렬화(취약점2).
--    · target_domain 서버 검증(취약점3).
--    · bus_riders INSERT 에 product_url 저장.
--    · 그 외 검증(잔액/중복/데이터폭탄/Zero-Yen/한도/자동마감)은 마이그36 과 동일하게 보존.
drop function if exists public.join_coop_bus(
  uuid, text, text, integer, integer, text, text, integer, text, text, text, text, text
);

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

  -- [방어 0.5] 잔액 fail-fast (비잠금) — 실제 차감/락은 debit_coop_deposit 이 담당
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

  -- ★[취약점2] 동시성 직렬화: buses 행 FOR UPDATE 잠금.
  --   이 락을 잡은 뒤 읽는 bus_riders 합(아래 [방어4])은 선행 탑승 트랜잭션의 커밋을 반영하므로
  --   두 탑승이 동시에 한도를 통과해 goal 을 초과하는 일이 구조적으로 불가능해진다.
  --   (락은 트랜잭션 끝까지 유지 → 중복탑승/한도검사/INSERT/자동마감이 전부 직렬화)
  select goal, coalesce(product_price, 0), ordered, target_domain
    into v_goal, v_pprice, v_ordered, v_tdomain
    from public.buses where id = p_bus_id for update;
  if not found then raise exception '존재하지 않는 공구입니다' using errcode = 'P0001'; end if;
  if v_ordered then
    raise exception '이미 마감되었거나 존재하지 않는 공구입니다' using errcode = 'P0001';
  end if;

  -- [방어 0] 중복 탑승 차단 (락 이후 검사 → 동일 유저 동시 탑승도 직렬 차단)
  if exists (select 1 from public.bus_riders where bus_id = p_bus_id and user_id = v_uid) then
    raise exception '이미 탑승한 버스입니다' using errcode = 'P0001';
  end if;

  -- ★[취약점3] 구매처 도메인 락 서버 검증 — 지정 도메인이 URL 에 포함돼야 함
  if v_tdomain is not null and v_tdomain <> '' and coalesce(p_product_url, '') <> '' then
    if position(lower(v_tdomain) in lower(p_product_url)) = 0 then
      raise exception '해당 공구의 지정 구매처 상품만 탑승 가능합니다.' using errcode = 'P0001';
    end if;
  end if;

  -- [방어 4] 면세 한도(goal) 초과 차단 — 총대 물품가 + 기존 탑승 + 이번 탑승 의 yen*qty 합
  --   (FOR UPDATE 락 이후 읽으므로 동시 탑승의 합도 정확)
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

  -- 100% 달성 시 자동 마감 (총합 == goal). 초과는 위에서 이미 차단됨.
  perform public.auto_close_bus_if_full(p_bus_id);

  return v_rider_id;
end;
$$;
