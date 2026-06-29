-- ============================================================
-- 54_coop_edit_once_rider_product.sql
--   ① Rider 도 '상품명·가격(yen)' 을 수정요청(mod_request)할 수 있게 approve 확장
--   ② 상품/옵션 수정은 주최자·참여자 모두 '1회만' (서버 강제, Zero-Trust)
--      · Host(buses 옵션): 저장 시 소진 (승인절차 없음)
--      · Rider(주문/상품): 총대 '승인' 시 소진 (거절 시 재요청 가능)
--   ③ 1회 제한은 '상품/주문 정보'에만 적용 — PII(bus_rider_private)는 무제한.
--
--   ⚠️ 기존 최신본 보존:
--      · guard_bus_rider_update 최신 = mig19(method 변경 시 amount 재계산 + issue_text/
--        tracking/courier 동결). 본 마이그는 거기에 1회 게이트 + order_edited 동결만 추가.
--      · approve_mod_request 최신 = mig36(면세한도 재검증 + auto_close_bus_if_full + closed).
--        본 마이그는 거기에 product_name/yen 반영 + order_edited 소진만 추가.
-- ============================================================

-- ── 1. 플래그 컬럼 ──
alter table public.buses       add column if not exists host_edited  boolean not null default false;
alter table public.bus_riders  add column if not exists order_edited boolean not null default false;
comment on column public.buses.host_edited       is '총대가 공구 옵션(상품/가격/수량/도수)을 1회 수정했는지. 서버 트리거만 set.';
comment on column public.bus_riders.order_edited  is '참여자 주문/상품 수정이 1회 소진됐는지(총대 승인 시 set). 서버만 변경.';
comment on column public.bus_riders.mod_request is
  '승인 대기 수정안(비-PII): { qty, power, method, product_name, yen, requested_at }. 승인 시 null.';

-- ── 2. guard_bus_rider_update 재정의 (mig19 보존 + 1회 게이트 + order_edited 동결) ──
create or replace function public.guard_bus_rider_update()
returns trigger
language plpgsql
as $$
declare
  is_owner boolean;
  v_goods  integer;
begin
  select (b.owner_id = auth.uid())
    into is_owner
    from public.buses b
   where b.id = new.bus_id;

  if not coalesce(is_owner, false) then
    -- [추가] 1회 제한: 이미 소진(order_edited)됐는데 '새' 수정요청(null→값) 생성 시도 → 차단
    if old.order_edited and old.mod_request is null and new.mod_request is not null then
      raise exception '상품/주문 정보 수정은 1회만 가능합니다' using errcode = 'P0001';
    end if;

    -- 결제/이슈 상태: 방장 전용
    new.paid            := old.paid;
    new.issue           := old.issue;
    new.issue_text      := old.issue_text;
    -- 상품 데이터: 동결 (무결성 / Zero-Yen 방어)
    new.product_name    := old.product_name;
    new.qty             := old.qty;
    new.yen             := old.yen;
    -- 운송장: 방장 전용
    new.tracking_number := old.tracking_number;
    new.courier_name    := old.courier_name;
    -- [추가] 1회 플래그: 본인 조작 금지(서버 approve 만 set)
    new.order_edited    := old.order_edited;
    -- power(도수)·method(수령방법): 본인 수정 허용 → 동결 안 함

    -- amount: 클라가 보낸 값 무시 → 동결된 yen/qty + (변경 가능한) method 로 서버 재계산.
    v_goods := old.yen * old.qty * 9;
    new.amount := v_goods + (case new.method
                               when 'conv' then 1800
                               when 'home' then 3500
                               else greatest(old.amount - v_goods, 0)
                             end);
  end if;
  return new;
end;
$$;

-- ── 3. guard_bus_host_options: 옵션 변경은 방장·1회만 (어드민 우회) ──
create or replace function public.guard_bus_host_options()
returns trigger
language plpgsql
as $$
begin
  -- 상품/가격/수량/도수 옵션 필드가 실제로 바뀐 경우에만 게이트 적용
  -- (시스템/정산 업데이트는 ordered/current/finalized 만 건드려 영향 없음)
  if (new.product_name  is distinct from old.product_name
   or new.product_price is distinct from old.product_price
   or new.host_qty      is distinct from old.host_qty
   or new.host_power_l  is distinct from old.host_power_l
   or new.host_power_r  is distinct from old.host_power_r) then
    if auth.uid() = old.owner_id then
      if old.host_edited then
        raise exception '공구 옵션 수정은 1회만 가능합니다' using errcode = 'P0001';
      end if;
      new.host_edited := true;             -- 방장 본인 수정 → 1회 소진
    elsif not public.is_app_admin(auth.uid()) then
      raise exception '방장만 공구 옵션을 수정할 수 있습니다' using errcode = '42501';
    end if;
    -- 어드민: 통과(소진 안 함)
  end if;
  return new;
end;
$$;
drop trigger if exists trg_guard_bus_host_options on public.buses;
create trigger trg_guard_bus_host_options
  before update on public.buses
  for each row execute function public.guard_bus_host_options();

-- ── 4. approve_mod_request 재정의 (mig36 보존 + product_name/yen 반영 + order_edited 소진) ──
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
  v_cur_yen integer; v_cur_qty integer; v_cur_pname text; v_cur_power text; v_cur_method text;
  v_yen    integer; v_qty integer; v_power text; v_method text; v_pname text;
  v_goods  integer; v_amount integer;
  v_goal   integer; v_pprice integer; v_others integer; v_total integer;
  v_closed boolean;
begin
  if v_uid is null then raise exception '인증이 필요합니다' using errcode = '28000'; end if;

  select bus_id, mod_request, yen, qty, product_name, power, method
    into v_bus_id, v_req, v_cur_yen, v_cur_qty, v_cur_pname, v_cur_power, v_cur_method
    from public.bus_riders where id = p_rider_id for update;
  if not found then raise exception '대상 라이더를 찾을 수 없습니다' using errcode = 'P0001'; end if;

  select owner_id into v_owner from public.buses where id = v_bus_id;
  if v_owner is distinct from v_uid then
    raise exception '방장만 수정 요청을 승인할 수 있습니다' using errcode = '42501';
  end if;
  if v_req is null then raise exception '대기 중인 수정 요청이 없습니다' using errcode = 'P0001'; end if;

  -- 요청 파싱 (없는 필드는 기존 장부값 유지) + 서버 검증
  v_qty    := coalesce((v_req->>'qty')::int, v_cur_qty, 1);
  v_power  := coalesce(v_req->>'power', v_cur_power, '');
  v_method := coalesce(v_req->>'method', v_cur_method, 'conv');
  v_pname  := coalesce(nullif(btrim(v_req->>'product_name'), ''), v_cur_pname);
  v_yen    := coalesce((v_req->>'yen')::int, v_cur_yen, 0);
  if v_qty < 1 or v_qty > 100 then raise exception '수량이 올바르지 않습니다' using errcode = 'P0001'; end if;
  if v_method not in ('conv','home','etc') then raise exception '수령 방법이 올바르지 않습니다' using errcode = 'P0001'; end if;
  if char_length(v_power) > 60 then raise exception '도수 값이 올바르지 않습니다' using errcode = 'P0001'; end if;
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
     set product_name = v_pname, qty = v_qty, yen = v_yen, power = v_power,
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
