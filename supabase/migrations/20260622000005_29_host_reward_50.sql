-- ============================================================
-- 29_host_reward_50.sql  —  총대 수고비 50% 지급
--
--   정책 변경: 탑승 수수료(300P)의 수고비 100% → 50%.
--   기존엔 총대 수고비 적립이 '미구현'(차감만)이었음 → 여기서 실제 지급 로직 신설.
--
--   구현: guard_bus_order_start 트리거(마이그27, 조기출발 차단)를 SECURITY DEFINER 로
--         격상하고, 공구 완료(ordered false→true) 전환 시 목표 검증 통과 후
--         총대에게 '수수료 50% × 탑승인원' = 150P × N 을 _wallet_apply 로 1회 적립한다.
--         · 어떤 경로(RPC/raw UPDATE)로 완료돼도 적립 보장(상태 전환에 내재).
--         · false→true 전환에만 발화 → 정확히 1회.
--         · _wallet_apply 는 authenticated 직접 호출 차단이므로 트리거를 DEFINER 로.
-- ============================================================
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
    v_is_admin := auth.uid() in (
      '4a612066-9a5d-4da1-905f-fe276fb73908',
      '82feb4b1-5365-4ff9-b68b-ce1b0805a2b2',
      '6b2482ab-ddde-46a2-bb71-f26880619fd2'
    );

    -- 조기 출발 차단(관리자 우회) — 목표 미달이면 여기서 예외 → 적립도 함께 롤백
    if not v_is_admin then
      select coalesce(sum(yen * qty), 0) into v_current
        from public.bus_riders where bus_id = new.id;
      if v_current < new.goal then
        raise exception '목표 금액 달성 후 출발할 수 있습니다. (현재 %엔 / 목표 %엔)', v_current, new.goal
          using errcode = 'P0001';
      end if;
    end if;

    -- 총대 수고비: 수수료(300P)의 50% = 150P × 탑승 인원, 완료 시 1회 지급
    select count(*) into v_count from public.bus_riders where bus_id = new.id;
    if v_count > 0 then
      perform public._wallet_apply(new.owner_id, v_count * v_reward, 'host_reward', new.id,
                                   'coop completion reward 50% x ' || v_count);
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_guard_bus_order_start on public.buses;
create trigger trg_guard_bus_order_start
  before update on public.buses
  for each row execute function public.guard_bus_order_start();
