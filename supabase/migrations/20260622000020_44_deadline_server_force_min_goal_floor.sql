-- ============================================================
-- 44_deadline_server_force_min_goal_floor.sql  —  Phase2-6 보안/정합성 보완
--
--   ① [하드닝] guard_bus_update_after_ordered(INVOKER 트리거)에 SET search_path=public
--      명시(심층 방어 — public.* 호출이 search_path 하이재킹에 흔들리지 않도록 고정).
--   ② [시간 정합성] expired_at 을 클라가 보낸 값 대신 서버 now() 기준으로 강제.
--      buses.deadline_hours(기본 12) 추가 + BEFORE INSERT 트리거 set_bus_expired_at()
--      이 NEW.expired_at = now() + deadline_hours 시간으로 덮어씀(클라 시계 위조 차단).
--   ③ [배송비 분쟁 차단] 최소 출발/조기 출발 하한선 10,000엔(무배 기준) 강제.
--      minimum_goal CHECK(>=10000) + guard_bus_order_start 에 10,000엔 절대 하한 가드.
-- ============================================================

-- ── 1. guard_bus_update_after_ordered 하드닝 (SET search_path 추가) ──
--    본문은 마이그43 과 동일, 선언부에 search_path 고정만 추가.
create or replace function public.guard_bus_update_after_ordered()
returns trigger
language plpgsql
set search_path = public           -- ★ 심층 방어: 스키마 경로 고정
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
-- 트리거 바인딩은 마이그43 의 trg_guard_bus_update_after_ordered 를 그대로 사용(함수만 교체).

-- ── 2. [시간 정합성] deadline_hours 컬럼 + 서버 강제 expired_at 트리거 ──
alter table public.buses
  add column if not exists deadline_hours integer default 12;
comment on column public.buses.deadline_hours is '마감까지 시간(시간 단위). expired_at 은 서버 트리거가 now()+deadline_hours 로 강제 산정.';

create or replace function public.set_bus_expired_at()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  -- 클라이언트가 보낸 expired_at 은 신뢰하지 않고 서버 시간 기준으로 덮어씀(시계 위조 차단)
  new.expired_at := now() + (coalesce(new.deadline_hours, 12) * interval '1 hour');
  return new;
end;
$$;

drop trigger if exists trg_set_bus_expired_at on public.buses;
create trigger trg_set_bus_expired_at
  before insert on public.buses
  for each row execute function public.set_bus_expired_at();

-- ── 3. [하한선] minimum_goal 10,000엔 floor ──
--    기존 데이터가 10000 미만이면 CHECK 추가가 실패하므로 먼저 보정(무배 기준으로 상향).
alter table public.buses drop constraint if exists buses_minimum_goal_floor;
update public.buses set minimum_goal = 10000 where minimum_goal < 10000;
alter table public.buses
  add constraint buses_minimum_goal_floor check (minimum_goal >= 10000);

-- ── 4. guard_bus_order_start — 10,000엔 절대 하한 가드 추가 ──
--    본문은 마이그43 과 동일, 출발 검사에 '무배 기준 10,000엔 미만 차단'을 명시 추가.
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
  v_floor    constant integer := 10000; -- 무료 배송(무배) 절대 하한
begin
  if new.ordered = true and coalesce(old.ordered, false) = false then
    v_is_admin := public.is_app_admin(auth.uid());

    -- 조기 출발 차단(관리자 우회) — 달성 = 총대 본인 물품가(수량 곱) + 탑승자 장부 합산
    if not v_is_admin then
      select coalesce(sum(yen * qty), 0) into v_current
        from public.bus_riders where bus_id = new.id;
      v_current := v_current + coalesce(new.product_price * new.host_qty, 0);

      -- ★[무배 하한] 누적액이 10,000엔 미만이면 추가 배송비 분쟁 위험 → 출발 원천 차단
      if v_current < v_floor then
        raise exception '무료 배송 기준(%엔) 미만으로는 출발할 수 없습니다. (현재 %엔) 추가 배송비 분쟁 방지를 위해 차단됩니다.', v_floor, v_current
          using errcode = 'P0001';
      end if;

      -- 최소 출발 금액(minimum_goal) 미달 차단
      if v_current < new.minimum_goal then
        raise exception '최소 출발 금액 달성 후 출발할 수 있습니다. (현재 %엔 / 최소 %엔)', v_current, new.minimum_goal
          using errcode = 'P0001';
      end if;
    end if;

    -- 총대 수고비 지급(수수료 50% × 탑승 인원)
    select count(*) into v_count from public.bus_riders where bus_id = new.id;
    if v_count > 0 then
      perform public._wallet_apply(new.owner_id, v_count * v_reward, 'host_reward', new.id,
                                   'coop completion reward 50% x ' || v_count);
    end if;
  end if;
  return new;
end;
$$;
-- 트리거 바인딩(trg_guard_bus_order_start)은 기존 것 재사용(함수만 교체).
