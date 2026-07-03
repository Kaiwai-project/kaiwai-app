-- ============================================================
-- 60_remove_lenses.sql  —  렌즈/렌즈라라 종속 제거 → 범용 "안심 공구" 전환
--
--   [배경] 콘택트렌즈는 국내법상 의료기기 → 공구 주선 자체가 처벌 대상.
--          렌즈 전용 스키마(플랫폼/도수/렌즈카탈로그)를 뿌리째 제거하고
--          범용 공동구매 플랫폼으로 전환한다.
--
--   [Zero-Downtime 원칙 · Backend Architect + QA]
--     platform / host_power_l / host_power_r / power 는 단순 컬럼이 아니라
--     보안 하드닝된 함수·트리거에 박혀 있다. plpgsql 은 late-bound 라 컬럼만
--     드롭하면 다음 INSERT/UPDATE 시 런타임에 폭발한다. 따라서:
--       ① 의존 함수 3종을 "최신 본문(보안검증 100% 보존) + 렌즈 라인만 절제" 로
--          먼저 재정의한 뒤
--       ② 컬럼/테이블을 드롭한다.
--
--   [expand-contract] join_coop_bus 시그니처는 14-arg 그대로 유지한다.
--     p_power 파라미터는 받되 무시·미INSERT. (프론트가 p_power:"" 를 계속
--     전송해도 무해 → Vercel 배포와 db push 사이에 탑승 실패 창이 없다.)
--     추후 프론트가 p_power 를 완전히 끊은 뒤 별도 마이그로 파라미터를 제거한다.
--
--   재정의 근거 본문:
--     · guard_bus_host_options  최신 = mig55  (host_power 체크만 제거)
--     · approve_mod_request     최신 = mig54  (power 읽기/파싱/UPDATE 만 제거)
--     · join_coop_bus           최신 = mig58  (power INSERT + 길이검증만 제거)
-- ============================================================

-- ── 1. guard_bus_host_options 재정의 (mig55 - host_power 체크 제거) ──
create or replace function public.guard_bus_host_options()
returns trigger
language plpgsql
as $$
begin
  -- 상품/가격/수량 옵션 필드가 실제로 바뀐 경우에만 게이트 적용
  if (new.product_name  is distinct from old.product_name
   or new.product_price is distinct from old.product_price
   or new.host_qty      is distinct from old.host_qty) then
    if auth.uid() = old.owner_id then
      -- 탑승자가 1명이라도 있을 때만 1회 제한 적용. 없으면 자유 수정(소진 안 함).
      if exists (select 1 from public.bus_riders where bus_id = old.id) then
        if old.host_edited then
          raise exception '공구 옵션 수정은 1회만 가능합니다' using errcode = 'P0001';
        end if;
        new.host_edited := true;
      end if;
    elsif not public.is_app_admin(auth.uid()) then
      raise exception '방장만 공구 옵션을 수정할 수 있습니다' using errcode = '42501';
    end if;
  end if;
  return new;
end;
$$;

-- ── 2. approve_mod_request 재정의 (mig54 - power 읽기/파싱/UPDATE 제거) ──
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
  v_cur_yen integer; v_cur_qty integer; v_cur_pname text; v_cur_method text;
  v_yen    integer; v_qty integer; v_method text; v_pname text;
  v_goods  integer; v_amount integer;
  v_goal   integer; v_pprice integer; v_others integer; v_total integer;
  v_closed boolean;
begin
  if v_uid is null then raise exception '인증이 필요합니다' using errcode = '28000'; end if;

  select bus_id, mod_request, yen, qty, product_name, method
    into v_bus_id, v_req, v_cur_yen, v_cur_qty, v_cur_pname, v_cur_method
    from public.bus_riders where id = p_rider_id for update;
  if not found then raise exception '대상 라이더를 찾을 수 없습니다' using errcode = 'P0001'; end if;

  select owner_id into v_owner from public.buses where id = v_bus_id;
  if v_owner is distinct from v_uid then
    raise exception '방장만 수정 요청을 승인할 수 있습니다' using errcode = '42501';
  end if;
  if v_req is null then raise exception '대기 중인 수정 요청이 없습니다' using errcode = 'P0001'; end if;

  -- 요청 파싱 (없는 필드는 기존 장부값 유지) + 서버 검증
  v_qty    := coalesce((v_req->>'qty')::int, v_cur_qty, 1);
  v_method := coalesce(v_req->>'method', v_cur_method, 'conv');
  v_pname  := coalesce(nullif(btrim(v_req->>'product_name'), ''), v_cur_pname);
  v_yen    := coalesce((v_req->>'yen')::int, v_cur_yen, 0);
  if v_qty < 1 or v_qty > 100 then raise exception '수량이 올바르지 않습니다' using errcode = 'P0001'; end if;
  if v_method not in ('conv','home','etc') then raise exception '수령 방법이 올바르지 않습니다' using errcode = 'P0001'; end if;
  if char_length(coalesce(v_pname,'')) > 200 then raise exception '상품명이 너무 깁니다' using errcode = 'P0001'; end if;
  if v_yen < 0 or v_yen > 1000000 then raise exception '가격이 올바르지 않습니다' using errcode = 'P0001'; end if;

  -- [면세 한도 방어] mig36 과 동일 산식(총대 물품가 + 타 라이더 + 본인 새 단가×수량) > goal 이면 거부
  select goal, coalesce(product_price, 0) into v_goal, v_pprice from public.buses where id = v_bus_id;
  select coalesce(sum(yen * qty), 0) into v_others
    from public.bus_riders where bus_id = v_bus_id and id <> p_rider_id;
  v_total := v_pprice + v_others + (v_yen * v_qty);
  if v_total > v_goal then
    raise exception '수정하면 공구방의 남은 면세 한도를 초과하게 되어 승인할 수 없습니다.' using errcode = 'P0001';
  end if;

  -- amount 서버 재계산 (yen×qty×9 + 배송비). 클라/요청 amount 는 신뢰하지 않음.
  v_goods  := v_yen * v_qty * 9;
  v_amount := v_goods + case v_method when 'conv' then 1800 when 'home' then 3500 else 0 end;

  -- 실제 반영 (auth.uid()=방장 → guard_bus_rider_update 동결 우회) + 1회 소진
  update public.bus_riders
     set product_name = v_pname, qty = v_qty, yen = v_yen,
         method = v_method, amount = v_amount, mod_request = null, order_edited = true
   where id = p_rider_id;

  -- 100% 달성 시 자동 마감 (mig36 보존)
  v_closed := public.auto_close_bus_if_full(v_bus_id);

  return jsonb_build_object('ok', true, 'rider_id', p_rider_id, 'qty', v_qty, 'yen', v_yen,
                            'amount', v_amount, 'product_name', v_pname, 'closed', coalesce(v_closed, false));
end;
$$;
revoke all on function public.approve_mod_request(uuid) from public, anon;
grant execute on function public.approve_mod_request(uuid) to authenticated;

-- ── 3. join_coop_bus 재정의 (mig58 - power INSERT/길이검증 제거, 시그니처 14-arg 유지) ──
--    ★ p_power 파라미터는 expand-contract 를 위해 유지하되 무시한다(미INSERT).
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

  -- [방어 1] 데이터 폭탄: 텍스트 길이 상한 (p_power 는 무시 → 검증 불필요)
  if coalesce(length(p_nick),0)         > 40  then raise exception '닉네임이 너무 깁니다'   using errcode = 'P0001'; end if;
  if coalesce(length(p_product_name),0) > 200 then raise exception '상품명이 너무 깁니다'   using errcode = 'P0001'; end if;
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
  perform set_config('app.coop_join_ok', p_bus_id::text, true);

  insert into public.bus_riders
    (bus_id, user_id, nick, product_name, qty, yen, method, amount, paid, issue, has_addr, memo, product_url)
  values
    (p_bus_id, v_uid, p_nick, p_product_name, coalesce(p_qty,1), coalesce(p_yen,0),
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

-- ── 4. 렌즈 종속 컬럼/테이블 드롭 (함수 재정의 후이므로 안전) ──
alter table public.buses      drop column if exists platform;
alter table public.buses      drop column if exists host_power_l;
alter table public.buses      drop column if exists host_power_r;
alter table public.bus_riders drop column if exists power;

-- 렌즈 카탈로그 테이블(+RLS/트리거/인덱스는 CASCADE 로 함께 제거)
drop table if exists public.lens_catalog cascade;

-- 렌즈 이미지 스토리지 공개조회 정책 제거 (버킷/오브젝트 실삭제는 Storage API/대시보드 전용 —
-- SQL DELETE 가 42501 로 금지되므로 여기선 정책만 제거. 남는 lens-assets 빈 버킷은 무해.)
drop policy if exists "렌즈 이미지 공개 조회" on storage.objects;

-- 렌즈라라 제휴 도메인 시드 제거 (하드코딩 도메인 제거 — 제휴 인프라 자체는 범용 유지)
delete from public.affiliate_partners where domain in ('lenslala.com', 'lenslala3.com');
