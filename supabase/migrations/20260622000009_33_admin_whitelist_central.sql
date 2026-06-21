-- ============================================================
-- 32_admin_whitelist_central.sql  —  서버 관리자(God Mode) UUID 화이트리스트 중앙화 + 갱신
--
--   문제: admin_grant_points(마이그23) · guard_bus_order_start(27→29→31) ·
--         god_force_delete_bus(30) 가 각자 동일한 관리자 UUID 목록을 인라인 하드코딩.
--         그 목록(4a612066…)은 히스토리 재작성으로 DB 에서 사라진 옛 계정이라,
--         현재 운영자 계정(jisulee 8eb7bdd7 / 네이버 c3f8e50f)이 빠져
--         God Mode 의 +1000P(admin_grant_points) 등이 '관리자 전용 기능입니다'(42501) 로 거부됨.
--   해결: 단일 헬퍼 public.is_app_admin(uuid) 로 목록을 중앙화하고 현재 UUID 로 갱신,
--         세 함수를 헬퍼 호출로 재배선(create or replace). 향후엔 이 한 곳만 고치면 됨.
--   ※ index.html / profile.js 의 ADMIN_IDS 와 동일하게 유지할 것.
-- ============================================================

-- 1) 중앙 관리자 판별 헬퍼
create or replace function public.is_app_admin(p_uid uuid)
returns boolean
language sql
stable
set search_path = public
as $$
  select p_uid in (
    '8eb7bdd7-e50f-4683-9b41-94b882a2ac5a',  -- jisulee83@naver.com (이메일/카카오 연동)
    'c3f8e50f-f858-457e-80f2-44a58ceb045d',  -- 네이버 로그인(verify-naver, noreply 이메일)
    '82feb4b1-5365-4ff9-b68b-ce1b0805a2b2',  -- noitaloiv@gmail.com
    '6b2482ab-ddde-46a2-bb71-f26880619fd2'   -- rmfjwlak114@gmail.com (운영자)
  );
$$;
grant execute on function public.is_app_admin(uuid) to authenticated;

-- 2) admin_grant_points 재배선 (마이그23 본문 = 헬퍼 호출만 교체)
create or replace function public.admin_grant_points(p_amount integer)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception '인증이 필요합니다' using errcode = '28000'; end if;
  if not public.is_app_admin(v_uid) then
    raise exception '관리자 전용 기능입니다' using errcode = '42501';
  end if;
  if p_amount is null or p_amount <= 0 or p_amount > 100000 then
    raise exception '지급액이 올바르지 않습니다' using errcode = 'P0001';
  end if;
  return public._wallet_apply(v_uid, p_amount, 'admin_grant', null, 'god mode grant');
end;
$$;
revoke all on function public.admin_grant_points(integer) from public, anon;
grant execute on function public.admin_grant_points(integer) to authenticated;

-- 3) guard_bus_order_start 재배선 (마이그31 본문 = 관리자 판별만 헬퍼로)
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

    -- 조기 출발 차단(관리자 우회) — 달성 = 총대 본인 물품가 + 탑승자 장부 합산
    if not v_is_admin then
      select coalesce(sum(yen * qty), 0) into v_current
        from public.bus_riders where bus_id = new.id;
      v_current := v_current + coalesce(new.product_price, 0);   -- ★ 총대 물품가 포함
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

-- 4) god_force_delete_bus 재배선 (마이그30 본문 = 헬퍼 호출만 교체)
create or replace function public.god_force_delete_bus(p_bus_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid      uuid := auth.uid();
  v_deposit  constant integer := 300;
  v_refunded integer := 0;
  v_rrec     record;
begin
  if v_uid is null then raise exception '인증이 필요합니다' using errcode = '28000'; end if;
  if not public.is_app_admin(v_uid) then
    raise exception '관리자 전용 기능입니다' using errcode = '42501';
  end if;

  -- 존재 확인 + 잠금(동시 호출 직렬화)
  perform 1 from public.buses where id = p_bus_id for update;
  if not found then
    raise exception '존재하지 않거나 이미 삭제된 공구입니다' using errcode = 'P0001';
  end if;

  -- 관리자 강제 삭제 → 탑승자 보증금(300P) 전원 자동 환불(유저별 합산, 원장 기록)
  for v_rrec in
    select user_id as uid, count(*)::int as cnt
      from public.bus_riders where bus_id = p_bus_id group by user_id
  loop
    perform public._wallet_apply(v_rrec.uid, v_rrec.cnt * v_deposit, 'refund', p_bus_id, 'god force delete refund');
    v_refunded := v_refunded + 1;
  end loop;

  delete from public.buses where id = p_bus_id;   -- bus_riders / bus_rider_private 는 cascade

  return jsonb_build_object('deleted', true, 'bus_id', p_bus_id, 'refunded_riders', v_refunded);
end;
$$;
revoke all on function public.god_force_delete_bus(uuid) from public, anon;
grant execute on function public.god_force_delete_bus(uuid) to authenticated;
