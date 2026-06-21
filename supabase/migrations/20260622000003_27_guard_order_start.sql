-- ============================================================
-- 27_guard_order_start.sql  —  [버그픽스] 조기 출발 차단
--
--   문제: '버스 출발'(buses.ordered false→true)이 평범한 UPDATE 이고,
--         buses UPDATE 정책은 소유권(owner_id=auth.uid())만 검사 → 달성률 미달이어도
--         아무 총대나 조기 출발(ordered=true) 가능. current>=goal 검증이 백엔드에 전무.
--         (current 는 컬럼이 아니라 bus_riders 의 sum(yen*qty) 로 계산됨.)
--
--   해결: BEFORE UPDATE 트리거로 ordered false→true 전환 시점에
--         장부 합산(sum(yen*qty)) >= goal 을 강제. ADMIN_IDS 는 테스트/긴급용 우회.
-- ============================================================
create or replace function public.guard_bus_order_start()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_current integer;
begin
  -- '출발' 전환(미주문 → 주문)에만 적용. 그 외 UPDATE(공지 수정 등)는 통과.
  if new.ordered = true and coalesce(old.ordered, false) = false then
    -- 관리자(ADMIN_IDS): 테스트/긴급 조치를 위해 달성률 미달이어도 출발 허용
    if auth.uid() in (
      '4a612066-9a5d-4da1-905f-fe276fb73908',
      '82feb4b1-5365-4ff9-b68b-ce1b0805a2b2',
      '6b2482ab-ddde-46a2-bb71-f26880619fd2'
    ) then
      return new;
    end if;

    -- 달성 금액 = 장부 합산(yen×qty), 목표 = buses.goal (둘 다 엔 단위)
    select coalesce(sum(yen * qty), 0) into v_current
      from public.bus_riders
     where bus_id = new.id;

    if v_current < new.goal then
      raise exception '목표 금액 달성 후 출발할 수 있습니다. (현재 %엔 / 목표 %엔)', v_current, new.goal
        using errcode = 'P0001';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_guard_bus_order_start on public.buses;
create trigger trg_guard_bus_order_start
  before update on public.buses
  for each row execute function public.guard_bus_order_start();
