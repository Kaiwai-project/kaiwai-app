-- ============================================================
-- 56_coop_lifecycle.sql  —  공구방 라이프사이클(상태머신) 정식 도입
--
--   협의 결론(docs/coop_lifecycle_decision.md):
--   · enum 빅뱅 교체 ❌ → buses.status enum 추가 + ordered 를 status 의 미러로 유지.
--     기존 RLS/고스트라이더/autoclose/guard 로직(ordered 참조)을 무손상 보존하고,
--     신규 코드만 status 를 읽고 쓴다.
--   · 상태 전이는 전부 SECURITY DEFINER RPC 경유 + 트랜잭션-로컬 GUC 플래그로만 허용.
--     클라이언트 직접 UPDATE status 는 트리거가 차단(상태 스푸핑 방어).
--
--   상태: recruiting(모집) → closed(마감/출발) → completed(수령완료)
--                         ↘ canceled(취소)   ↘ canceled
--         recruiting → expired(기한만료·미달)
--   ordered 매핑: recruiting → false / 그 외 4개 → true
--
--   트리거 발화 순서(BEFORE UPDATE, 이름 알파벳순):
--     trg_a_sync_coop_status   → ordered↔status 양방향 동기화
--     trg_b_protect_coop_status→ 전이 화이트리스트 + 직접변경 차단
--     trg_guard_bus_order_start→ (기존) 마감 시 목표검증 + 총대 수고비  [status='closed' 게이트 추가]
--     trg_guard_bus_update_after_ordered → (기존) 마감방 수정잠금  [전이 플래그 우회 허용]
-- ============================================================

-- ── 0. enum 타입 ──
do $$
begin
  if not exists (select 1 from pg_type where typname = 'coop_status') then
    create type public.coop_status as enum
      ('recruiting','closed','completed','canceled','expired');
  end if;
end $$;

-- ── 1. 컬럼 추가 ──
alter table public.buses
  add column if not exists status       public.coop_status not null default 'recruiting',
  add column if not exists completed_at timestamptz,
  add column if not exists ended_at     timestamptz,         -- canceled/expired 종료 시각(7일 후 숨김 기준)
  add column if not exists host_hidden_at timestamptz;        -- 총대가 '내역에서 삭제'

alter table public.bus_riders
  add column if not exists hidden_at timestamptz;             -- 탑승자가 '내역에서 삭제'(per-user)

-- ── 2. 기존 데이터 백필 (ordered=true 인 방은 closed 로) ──
update public.buses set status = 'closed' where ordered = true and status = 'recruiting';

create index if not exists idx_buses_status on public.buses(status);
create index if not exists idx_buses_status_expired on public.buses(status, expired_at);


-- ============================================================
--  3. 전이 허용 화이트리스트 헬퍼
-- ============================================================
create or replace function public._coop_transition_allowed(p_from public.coop_status, p_to public.coop_status)
returns boolean
language sql
immutable
as $$
  select case
    when p_from = p_to then true
    when p_from = 'recruiting' and p_to in ('closed','canceled','expired') then true
    when p_from = 'closed'     and p_to in ('completed','canceled')        then true
    else false   -- completed/canceled/expired 는 종착(터미널)
  end;
$$;


-- ============================================================
--  4. trg_a_sync_coop_status — ordered ↔ status 동기화
--     · status 가 바뀌면 ordered = (status <> 'recruiting')
--     · (레거시) ordered 만 바뀌면(수동/auto_close) status 를 closed/recruiting 으로 역산
-- ============================================================
create or replace function public.sync_coop_ordered()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'INSERT' then
    new.ordered := (new.status <> 'recruiting');
    return new;
  end if;

  -- ordered 만 변경됨(레거시 마감 경로) → status 역산
  if new.ordered is distinct from old.ordered
     and new.status is not distinct from old.status then
    new.status := case when new.ordered then 'closed'::public.coop_status
                                        else 'recruiting'::public.coop_status end;
  end if;

  -- status 변경 → ordered 파생(미러 유지)
  if new.status is distinct from old.status then
    new.ordered := (new.status <> 'recruiting');
  end if;

  return new;
end;
$$;

drop trigger if exists trg_a_sync_coop_status on public.buses;
create trigger trg_a_sync_coop_status
  before insert or update on public.buses
  for each row execute function public.sync_coop_ordered();


-- ============================================================
--  5. trg_b_protect_coop_status — 전이 보안 (상태 스푸핑 방어)
--     · status 변경은 RPC(GUC app.allow_coop_transition='1') 경유만 허용.
--       예외: 레거시 마감(recruiting→closed)은 ordered 플립 자체에 기존 가드가 있어 허용.
--     · 모든 전이는 화이트리스트(_coop_transition_allowed) 통과 필수. 관리자는 우회.
-- ============================================================
create or replace function public.protect_coop_status()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_flag boolean := coalesce(current_setting('app.allow_coop_transition', true), '') = '1';
begin
  if new.status is distinct from old.status then
    -- 관리자(God)는 모든 전이 허용
    if public.is_app_admin(auth.uid()) then
      return new;
    end if;

    -- 비-RPC 경로: 레거시 마감(recruiting→closed)만 허용, 그 외 차단
    if not v_flag then
      if not (old.status = 'recruiting' and new.status = 'closed') then
        raise exception '공구 상태는 지정된 절차(RPC)로만 변경할 수 있습니다' using errcode = '42501';
      end if;
    end if;

    -- 전이 화이트리스트
    if not public._coop_transition_allowed(old.status, new.status) then
      raise exception '허용되지 않은 상태 전이입니다 (% → %)', old.status, new.status using errcode = 'P0001';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_b_protect_coop_status on public.buses;
create trigger trg_b_protect_coop_status
  before update on public.buses
  for each row execute function public.protect_coop_status();


-- ============================================================
--  6. guard_bus_order_start 재정의 — 목표검증/총대수고비는 'closed' 전이에서만
--     (기존 mig43 본문 보존 + status='closed' 게이트만 추가)
--     → cancel/expire 로 ordered 가 true 가 되어도 수고비 오지급/목표차단이 일어나지 않음.
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
  -- ★ 정상 '마감/출발'(status=closed) 전환에서만 동작. canceled/expired 는 제외.
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

    select count(*) into v_count from public.bus_riders where bus_id = new.id;
    if v_count > 0 then
      perform public._wallet_apply(new.owner_id, v_count * v_reward, 'host_reward', new.id,
                                   'coop completion reward 50% x ' || v_count);
    end if;
  end if;
  return new;
end;
$$;


-- ============================================================
--  7. guard_bus_update_after_ordered 재정의 — 전이 RPC 플래그면 수정잠금 우회
--     (기존 mig43 본문 보존 + 상품 위변조 방어 유지)
-- ============================================================
create or replace function public.guard_bus_update_after_ordered()
returns trigger
language plpgsql
as $$
declare
  v_flag boolean := coalesce(current_setting('app.allow_coop_transition', true), '') = '1';
begin
  -- 마감된 공구 수정 제한 (어드민·전이RPC 제외)
  if old.ordered = true then
    if not v_flag and not public.is_app_admin(auth.uid()) then
      raise exception '마감된 공구는 수정할 수 없습니다' using errcode = 'P0001';
    end if;
  end if;

  -- 마감 전환 시 핵심 상품 정보 동시 조작 방어
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
-- (트리거 trg_guard_bus_update_after_ordered 는 mig43 에서 이미 생성됨 — 재생성 불필요)


-- ============================================================
--  8. 하드삭제 가드 (QA 취약점#1: 탑승자 있는 방 삭제 → 300P 증발 방어)
--     스펙 2-①: 'recruiting + 탑승자 0명' 일 때만 하드삭제 허용.
--     · 관리자(god_force_delete_bus) / 크론 정리(app.allow_coop_purge) 는 우회.
-- ============================================================
create or replace function public.guard_bus_hard_delete()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  -- 관리자 강제삭제 · 크론 1년 보존만료 정리 경로는 통과
  if public.is_app_admin(auth.uid())
     or coalesce(current_setting('app.allow_coop_purge', true), '') = '1' then
    return old;
  end if;

  if old.status <> 'recruiting' then
    raise exception '진행/완료/종료된 공구는 바로 삭제할 수 없습니다. 공구 취소(환불)를 이용하세요.'
      using errcode = 'P0001';
  end if;
  if exists (select 1 from public.bus_riders where bus_id = old.id) then
    raise exception '탑승자가 있는 공구는 바로 삭제할 수 없습니다. 공구 취소(전원 환불)를 진행하세요.'
      using errcode = 'P0001';
  end if;
  return old;
end;
$$;

drop trigger if exists trg_guard_bus_hard_delete on public.buses;
create trigger trg_guard_bus_hard_delete
  before delete on public.buses
  for each row execute function public.guard_bus_hard_delete();


-- ============================================================
--  9. 분쟁 신고 테이블 + 잠금 헬퍼 (스펙 2-④)
-- ============================================================
create table if not exists public.coop_reports (
  id          uuid        primary key default gen_random_uuid(),
  bus_id      uuid        not null references public.buses(id) on delete cascade,
  reporter_id uuid        not null references public.profiles(id) on delete cascade,
  reason      text        not null,
  detail      text,
  status      text        not null default 'open',   -- open | resolved
  created_at  timestamptz not null default now(),
  resolved_at timestamptz,
  resolved_by uuid
);
create index if not exists idx_coop_reports_bus  on public.coop_reports(bus_id) where status = 'open';
-- 동일 유저가 같은 방에 중복 open 신고 방지
create unique index if not exists uq_coop_reports_open
  on public.coop_reports(bus_id, reporter_id) where status = 'open';

alter table public.coop_reports enable row level security;

-- 조회: 신고자 본인 / 해당 방 총대 / 관리자
drop policy if exists "신고 조회: 본인·총대·관리자" on public.coop_reports;
create policy "신고 조회: 본인·총대·관리자" on public.coop_reports
  for select to authenticated
  using (
    reporter_id = auth.uid()
    or exists (select 1 from public.buses b where b.id = bus_id and b.owner_id = auth.uid())
    or public.is_app_admin(auth.uid())
  );
-- 쓰기는 RPC(DEFINER) 전용 — 직접 INSERT/UPDATE 정책 없음

-- open 신고 존재 여부 (분쟁 잠금 판정)
create or replace function public._coop_has_open_report(p_bus_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.coop_reports where bus_id = p_bus_id and status = 'open');
$$;

-- 신고 접수 RPC (탑승자/총대만, 중복 open 차단)
create or replace function public.report_coop(p_bus_id uuid, p_reason text, p_detail text default null)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_id  uuid;
begin
  if v_uid is null then raise exception '인증이 필요합니다' using errcode = '28000'; end if;
  if coalesce(length(p_reason), 0) = 0 then raise exception '신고 사유를 입력하세요' using errcode = 'P0001'; end if;
  if coalesce(length(p_reason), 0) > 100 or coalesce(length(p_detail), 0) > 1000 then
    raise exception '신고 내용이 너무 깁니다' using errcode = 'P0001';
  end if;

  -- 해당 방의 탑승자 또는 총대만 신고 가능
  if not exists (
    select 1 from public.buses b where b.id = p_bus_id and b.owner_id = v_uid
    union all
    select 1 from public.bus_riders r where r.bus_id = p_bus_id and r.user_id = v_uid
  ) then
    raise exception '해당 공구의 참여자만 신고할 수 있습니다' using errcode = '42501';
  end if;

  insert into public.coop_reports (bus_id, reporter_id, reason, detail)
  values (p_bus_id, v_uid, p_reason, p_detail)
  on conflict (bus_id, reporter_id) where (status = 'open')
  do update set reason = excluded.reason, detail = excluded.detail
  returning id into v_id;

  return v_id;
end;
$$;
revoke all on function public.report_coop(uuid, text, text) from public, anon;
grant execute on function public.report_coop(uuid, text, text) to authenticated;

-- 신고 해소 RPC (관리자 전용)
create or replace function public.resolve_coop_report(p_report_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_uid uuid := auth.uid();
begin
  if not public.is_app_admin(v_uid) then raise exception '관리자 전용 기능입니다' using errcode = '42501'; end if;
  update public.coop_reports
     set status = 'resolved', resolved_at = now(), resolved_by = v_uid
   where id = p_report_id and status = 'open';
end;
$$;
revoke all on function public.resolve_coop_report(uuid) from public, anon;
grant execute on function public.resolve_coop_report(uuid) to authenticated;


-- ============================================================
--  10. complete_coop — 수령완료 선언 (총대, closed → completed)
-- ============================================================
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

  return jsonb_build_object('ok', true, 'bus_id', p_bus_id, 'status', 'completed');
end;
$$;
revoke all on function public.complete_coop(uuid) from public, anon;
grant execute on function public.complete_coop(uuid) to authenticated;


-- ============================================================
--  11. rpc_cancel_coop_by_host 재정의 — 하드삭제 → 소프트취소(status='canceled')
--      (기존 mig23 본문: 보증금 환불 + 3진아웃 패널티 보존. delete → 상태전이로만 교체)
--      · 취소된 방은 행을 보존하여 당사자 '내 내역'에 'canceled' 로 표시(스펙 1·2).
--      · recruiting/closed 모두 취소 가능(closed 취소 시 전이 플래그로 수정잠금 우회).
-- ============================================================
create or replace function public.rpc_cancel_coop_by_host(p_bus_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_deposit   constant integer := 300;
  v_uid       uuid := auth.uid();
  v_owner     uuid;
  v_status    public.coop_status;
  v_refunded  integer := 0;
  v_new_count integer;
  v_count     integer;
  v_trust     integer;
  v_suspended boolean;
  v_until     timestamptz;
  v_rrec      record;
begin
  if v_uid is null then raise exception '인증이 필요합니다.' using errcode = '28000'; end if;

  select owner_id, status into v_owner, v_status
    from public.buses where id = p_bus_id for update;
  if not found then raise exception '이미 무산되었거나 존재하지 않는 공구입니다.' using errcode = 'P0002'; end if;
  if v_owner <> v_uid then raise exception '권한이 없습니다. 방장만 공구를 무산시킬 수 있습니다.' using errcode = '42501'; end if;
  if v_status not in ('recruiting', 'closed') then
    raise exception '모집중/마감 상태의 공구만 무산할 수 있습니다.' using errcode = 'P0001';
  end if;

  -- ① 파티원 보증금 환불 (유저별 루프 → 원장 1줄씩 기록)
  for v_rrec in
    select r.user_id as uid, count(*)::int as cnt
      from public.bus_riders r where r.bus_id = p_bus_id group by r.user_id
  loop
    perform public._wallet_apply(v_rrec.uid, v_rrec.cnt * v_deposit, 'host_cancel_refund', p_bus_id, 'host fault cancel refund');
    perform public._notify(v_rrec.uid, '🚌 공구 무산', '참여하신 공구가 무산되어 보증금 300P가 환불되었어요.', 'coop_canceled', p_bus_id);
    v_refunded := v_refunded + 1;
  end loop;

  -- ② 패널티(3진 아웃)
  insert into public.user_coop_stats (user_id) values (v_uid) on conflict (user_id) do nothing;
  select host_cancel_count into v_count from public.user_coop_stats where user_id = v_uid for update;
  v_new_count := v_count + 1;

  update public.user_coop_stats
     set host_cancel_count = v_new_count,
         trust_score = greatest(0, trust_score - (case v_new_count when 1 then 20 when 2 then 30 else 0 end)),
         suspended_until = (case when v_new_count >= 3 then null
                                 when v_new_count = 2 then now() + interval '30 days'
                                 when v_new_count = 1 then now() + interval '7 days'
                                 else suspended_until end),
         is_host_suspended = (v_new_count >= 3) or is_host_suspended
   where user_id = v_uid
  returning trust_score, is_host_suspended, suspended_until into v_trust, v_suspended, v_until;

  -- ③ 공구 무산: 하드삭제 대신 소프트 전이(status='canceled') — 행 보존
  perform set_config('app.allow_coop_transition', '1', true);
  update public.buses set status = 'canceled', ended_at = now() where id = p_bus_id;

  return jsonb_build_object(
    'bus_id', p_bus_id, 'refunded_riders', v_refunded, 'deposit_each', v_deposit,
    'host_cancel_count', v_new_count, 'trust_score', v_trust,
    'is_host_suspended', v_suspended, 'suspended_until', v_until
  );
end;
$$;
revoke all on function public.rpc_cancel_coop_by_host(uuid) from public, anon;
grant execute on function public.rpc_cancel_coop_by_host(uuid) to authenticated;


-- ============================================================
--  12. expire_overdue_buses 재개편 (스펙 2-③ + QA 취약점#3)
--      만료(expired_at < now) + recruiting 인 방을 순회(SKIP LOCKED):
--        · 분쟁 잠금(open report) → 건너뜀
--        · 최소금액 달성 → closed 승급(정상 자동마감, 총대 수고비 지급)
--        · 미달            → expired 전이 + 전원 환불 (하드삭제 폐지 = 증빙 1년 보존)
-- ============================================================
create or replace function public.expire_overdue_buses()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_bus     record;
  v_current integer;
  v_deposit constant integer := 300;
  v_rrec    record;
  v_expired integer := 0;
  v_closed  integer := 0;
  v_refunded integer := 0;
begin
  for v_bus in
    select id, minimum_goal, product_price, host_qty
      from public.buses
     where expired_at < now() and status = 'recruiting'
     for update skip locked
  loop
    -- 분쟁 잠금: 신고 접수된 방은 자동 처리 대상에서 제외
    if public._coop_has_open_report(v_bus.id) then
      continue;
    end if;

    select coalesce(v_bus.product_price * v_bus.host_qty, 0) + coalesce(sum(yen * qty), 0)
      into v_current
      from public.bus_riders where bus_id = v_bus.id;

    if v_current >= v_bus.minimum_goal then
      -- 기한은 지났지만 최소 달성 → 정상 마감(closed)으로 승급
      perform set_config('app.allow_coop_transition', '1', true);
      update public.buses set status = 'closed' where id = v_bus.id;
      v_closed := v_closed + 1;
    else
      -- 미달 → 만료(expired) + 전원 환불 (소프트 전이, 행 보존)
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


-- ============================================================
--  13. sweep_coop_archive — 1년 보존 만료분 물리 정리 (크론 전용)
--      completed_at / ended_at 가 1년 경과 + 분쟁 없음 → 하드삭제(증빙 보존기간 종료).
-- ============================================================
create or replace function public.sweep_coop_archive()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_bus     record;
  v_purged  integer := 0;
begin
  for v_bus in
    select id from public.buses
     where (
       (status = 'completed' and completed_at < now() - interval '1 year') or
       (status in ('canceled','expired') and ended_at < now() - interval '1 year')
     )
     for update skip locked
  loop
    if public._coop_has_open_report(v_bus.id) then continue; end if;   -- 분쟁 잠금
    perform set_config('app.allow_coop_purge', '1', true);
    delete from public.buses where id = v_bus.id;   -- riders / private cascade
    v_purged := v_purged + 1;
  end loop;

  return jsonb_build_object('purged', v_purged);
end;
$$;
revoke all on function public.sweep_coop_archive() from public, anon, authenticated;


-- ============================================================
--  14. 사용자 '내역에서 삭제' (per-user 숨김) RPC
-- ============================================================
-- 탑승자: 자기 라이더 행 hidden_at 세팅 (완료/취소/만료 방만)
create or replace function public.hide_my_coop_history(p_bus_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception '인증이 필요합니다' using errcode = '28000'; end if;
  update public.bus_riders
     set hidden_at = now()
   where bus_id = p_bus_id and user_id = v_uid
     and exists (select 1 from public.buses b where b.id = p_bus_id
                 and b.status in ('completed','canceled','expired'));
  -- 총대 본인 방이면 host_hidden_at 도 세팅
  update public.buses
     set host_hidden_at = now()
   where id = p_bus_id and owner_id = v_uid
     and status in ('completed','canceled','expired');
end;
$$;
revoke all on function public.hide_my_coop_history(uuid) from public, anon;
grant execute on function public.hide_my_coop_history(uuid) to authenticated;


-- ============================================================
--  15. 피드 가시성 RLS 강화 (mig52 갱신)
--      모집중이라도 기한 만료분은 공개 피드에서 즉시 제외. 총대/탑승자/관리자는 계속 조회.
-- ============================================================
drop policy if exists "출발 전 공개, 출발 후 참가자+관리자 전용" on public.buses;
create policy "출발 전 공개, 출발 후 참가자+관리자 전용" on public.buses
  for select using (
    (not ordered and expired_at > now())
    or auth.uid() = owner_id
    or exists (
      select 1 from public.bus_riders r
      where r.bus_id = buses.id and r.user_id = auth.uid()
    )
    or public.is_app_admin(auth.uid())
  );
