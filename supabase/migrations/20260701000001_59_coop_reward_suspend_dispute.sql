-- ============================================================
-- 59_coop_reward_suspend_dispute.sql  —  보안 감사 대응 (C3 + H1 + H2)
--   (mig56 라이프사이클 함수 3종 개편. 다른 로직은 mig56 원본 유지.)
--
--   [C3 · CRITICAL] 총대 수고비 무산 시 회수 불가(포인트 농사) 원천 차단
--     기존: guard_bus_order_start 가 '마감(closed)' 전환 즉시 150P×인원 선지급.
--           무산(rpc_cancel_coop_by_host)/만료(expire)에서 회수 로직이 없어,
--           알트계정으로 마감만 시키고 무산하면 수고비가 순증했다.
--     해결: 선지급 폐지 → '수령완료(complete_coop, closed→completed)' 확정 시점에만 지급.
--           canceled/expired 는 completed 로 못 가므로 수고비가 아예 발생하지 않는다.
--
--   [H1 · HIGH] 3진아웃/쿨다운 정지 총대의 신규 개설 차단(서버 강제)
--     기존: is_host_suspended/suspended_until 은 기록·표시만 되고 개설 INSERT 정책에서 미검사.
--     해결: _is_host_suspended(DEFINER) 헬퍼 + "인증 총대만 개설" 정책에 정지 검사 추가.
--
--   [H2 · HIGH] 분쟁 신고 1건이 미달 공구 환불을 영구 동결(그리핑 DoS)
--     기존: expire_overdue_buses 가 open report 있으면 방 전체를 skip → 미달 방의
--           탑승자 보증금이 관리자 개입 전까지 환불되지 않았다.
--     해결: 분쟁 잠금은 '출발(closed 승급)'만 보류하고, 미달 방의 '보증금 환불+만료'는
--           예정대로 진행(행은 소프트 전이로 1년 보존 → 증빙 회피 아님).
-- ============================================================

-- ── [C3-1] guard_bus_order_start: 마감 시 수고비 선지급 제거 (최소금액 가드는 유지) ──
create or replace function public.guard_bus_order_start()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_current  integer;
  v_is_admin boolean;
begin
  if new.ordered = true and coalesce(old.ordered, false) = false
     and new.status = 'closed' then
    v_is_admin := public.is_app_admin(auth.uid());

    if not v_is_admin then
      select coalesce(sum(yen * qty), 0) into v_current
        from public.bus_riders where bus_id = new.id;
      v_current := v_current + coalesce(new.product_price * new.host_qty, 0);
      if v_current < new.minimum_goal then
        raise exception '최소 출발 금액 달성 후 출발할 수 있습니다. (현재 %엔 / 최소 %엔)', v_current, new.minimum_goal
          using errcode = 'P0001';
      end if;
    end if;
    -- ★[C3] 총대 수고비는 여기(마감)서 선지급하지 않고 complete_coop(완료)로 이관.
  end if;
  return new;
end;
$$;

-- ── [C3-2] complete_coop: 수령완료 확정 시 수고비 지급 ──
create or replace function public.complete_coop(p_bus_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid    uuid := auth.uid();
  v_owner  uuid;
  v_status public.coop_status;
  v_count  integer;
  v_reward constant integer := 150;   -- 300P 수수료의 50%
begin
  if v_uid is null then raise exception '인증이 필요합니다' using errcode = '28000'; end if;

  select owner_id, status into v_owner, v_status
    from public.buses where id = p_bus_id for update;
  if not found then raise exception '존재하지 않는 공구입니다' using errcode = 'P0001'; end if;

  if v_owner is distinct from v_uid and not public.is_app_admin(v_uid) then
    raise exception '총대만 수령완료를 선언할 수 있습니다' using errcode = '42501';
  end if;
  if v_status <> 'closed' then
    raise exception '마감(출발)된 공구만 수령완료로 변경할 수 있습니다' using errcode = 'P0001';
  end if;
  -- 분쟁 잠금: open 신고가 있으면 완료 선언 차단(증거 회피 방지)
  if public._coop_has_open_report(p_bus_id) and not public.is_app_admin(v_uid) then
    raise exception '진행 중인 신고가 있어 완료 처리할 수 없습니다. 관리자 확인이 필요합니다.' using errcode = 'P0001';
  end if;

  perform set_config('app.allow_coop_transition', '1', true);
  update public.buses
     set status = 'completed', completed_at = now()
   where id = p_bus_id;

  -- ★[C3] 총대 수고비(수수료 50% × 탑승인원) — '완료' 확정 시점에만 1회 지급.
  --   (complete_coop 은 closed→completed 로 1회만 실행되므로 중복 지급 없음.)
  select count(*) into v_count from public.bus_riders where bus_id = p_bus_id;
  if v_count > 0 then
    perform public._wallet_apply(v_owner, v_count * v_reward, 'host_reward', p_bus_id,
                                 'coop completion reward 50% x ' || v_count);
  end if;

  return jsonb_build_object('ok', true, 'bus_id', p_bus_id, 'status', 'completed');
end;
$$;
revoke all on function public.complete_coop(uuid) from public, anon;
grant execute on function public.complete_coop(uuid) to authenticated;


-- ── [H1] 정지 총대 개설 차단 ──
create or replace function public._is_host_suspended(p_uid uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.user_coop_stats s
     where s.user_id = p_uid
       and (s.is_host_suspended = true
            or (s.suspended_until is not null and s.suspended_until > now()))
  );
$$;
revoke all on function public._is_host_suspended(uuid) from public, anon;
grant execute on function public._is_host_suspended(uuid) to authenticated;

drop policy if exists "인증 총대만 개설" on public.buses;
create policy "인증 총대만 개설" on public.buses
  for insert to authenticated
  with check (
    auth.uid() = owner_id
    and exists (select 1 from public.profiles p     where p.id = auth.uid()      and p.verified_host = true)
    and exists (select 1 from public.host_accounts a where a.user_id = auth.uid() and a.account_verified = true)
    and not public._is_host_suspended(auth.uid())   -- ★[H1] 3진아웃/쿨다운 정지 시 개설 차단
  );


-- ── [H2] 만료 처리: 분쟁 잠금이 미달 방 환불을 막지 않도록 개편 ──
create or replace function public.expire_overdue_buses()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_bus      record;
  v_current  integer;
  v_deposit  constant integer := 300;
  v_rrec     record;
  v_expired  integer := 0;
  v_closed   integer := 0;
  v_refunded integer := 0;
begin
  for v_bus in
    select id, minimum_goal, product_price, host_qty
      from public.buses
     where expired_at < now() and status = 'recruiting'
     for update skip locked
  loop
    select coalesce(v_bus.product_price * v_bus.host_qty, 0) + coalesce(sum(yen * qty), 0)
      into v_current
      from public.bus_riders where bus_id = v_bus.id;

    if v_current >= v_bus.minimum_goal then
      -- 최소 달성 → 정상 마감(closed) 승급.
      -- 단, 분쟁(open report) 있으면 '자동 출발'만 보류(관리자 확인 후 처리).
      if public._coop_has_open_report(v_bus.id) then
        continue;
      end if;
      perform set_config('app.allow_coop_transition', '1', true);
      update public.buses set status = 'closed' where id = v_bus.id;
      v_closed := v_closed + 1;
    else
      -- ★[H2] 미달 → 만료(expired) + 전원 환불. 분쟁 신고가 있어도 '보증금 환불'은 동결 안 함.
      --   (신고는 출발/정산 분쟁 대상. 미출발 방의 예치금 반환까지 막으면 그리핑 DoS.
      --    행은 소프트 전이로 보존되어 증빙 회피가 아님.)
      for v_rrec in
        select user_id as uid, count(*)::int as cnt
          from public.bus_riders where bus_id = v_bus.id group by user_id
      loop
        perform public._wallet_apply(v_rrec.uid, v_rrec.cnt * v_deposit, 'refund', v_bus.id, 'coop expire refund');
        perform public._notify(v_rrec.uid, '⌛ 공구 만료', '기한 내 목표 미달로 공구가 만료되어 보증금이 환불되었어요.', 'coop_expired', v_bus.id);
        v_refunded := v_refunded + v_rrec.cnt;
      end loop;

      perform set_config('app.allow_coop_transition', '1', true);
      update public.buses set status = 'expired', ended_at = now() where id = v_bus.id;
      v_expired := v_expired + 1;
    end if;
  end loop;

  return jsonb_build_object('expired', v_expired, 'closed', v_closed, 'refunded_riders', v_refunded);
end;
$$;
revoke all on function public.expire_overdue_buses() from public, anon;
grant execute on function public.expire_overdue_buses() to authenticated;
