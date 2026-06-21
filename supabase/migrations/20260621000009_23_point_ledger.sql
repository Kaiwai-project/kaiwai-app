-- ============================================================
-- 23_point_ledger.sql
--   [Slice 5] 포인트 원장(Ledger) + 출석 적립 + 관리자 적립
--
--   설계 철학: "잔액(user_wallets.balance)은 원장(point_transactions)의 파생값이다."
--     · 모든 자금 변동은 단일 중앙 헬퍼 _wallet_apply() 한 곳으로만 흐른다.
--     · _wallet_apply 는 [지갑 잠금+갱신] + [원장 INSERT] 를 한 트랜잭션에 원자적으로 수행
--       → '잔액은 변했는데 로그가 없다 / 로그는 있는데 잔액이 안 맞다' 가 구조적으로 불가능.
--     · 마이그 21·22 의 sync/debit, 마이그 20 의 refund 도 전부 이 헬퍼를 타도록 재배선한다.
--   감사(Audit) 무결성: 원장은 append-only(불변). UPDATE/DELETE 정책을 두지 않아 위변조 차단.
-- ============================================================

-- ── 1. 변동 사유 enum ──
do $$
begin
  if not exists (select 1 from pg_type where typname = 'point_reason') then
    create type public.point_reason as enum
      ('attendance','sync','board','refund','host_cancel_refund','admin_grant');
  end if;
end $$;

-- ── 2. 원장 테이블 (append-only 감사 로그) ──
create table if not exists public.point_transactions (
  id            uuid        primary key default gen_random_uuid(),
  user_id       uuid        not null references auth.users(id) on delete cascade,
  delta         integer     not null,                 -- +적립 / -차감
  reason        public.point_reason not null,
  balance_after integer     not null,                 -- 변동 후 잔액 스냅샷(정합성 대조용)
  ref_id        uuid,                                  -- 관련 엔티티(bus_id 등)
  memo          text,
  created_at    timestamptz not null default now(),
  constraint point_tx_delta_nonzero check (delta <> 0)
);
comment on table public.point_transactions is '포인트 변동 원장(불변 감사 로그). 쓰기는 _wallet_apply(DEFINER) 전용.';
create index if not exists idx_point_tx_user_created on public.point_transactions(user_id, created_at desc);

-- 출석 1회/일 판정용 (지갑 행에 두어 단일 락으로 날짜검사+잔액갱신 동시 처리)
alter table public.user_wallets
  add column if not exists last_attendance_date date;

-- ── 3. RLS — 본인 내역만 조회. 쓰기 정책 없음(=DEFINER 헬퍼 전용, 불변) ──
alter table public.point_transactions enable row level security;
drop policy if exists "원장: 본인만 조회" on public.point_transactions;
create policy "원장: 본인만 조회" on public.point_transactions
  for select to authenticated
  using (user_id = auth.uid());

-- ============================================================
-- 4. _wallet_apply — 모든 자금 변동의 단일 관문 (SECURITY DEFINER, 내부 전용)
--    · 대상 지갑 행 잠금(FOR UPDATE) → 잔액 갱신 → 원장 INSERT 를 원자적으로.
--    · authenticated 에게도 EXECUTE 를 주지 않는다(직접 호출 차단). DEFINER 함수들만 호출.
-- ============================================================
create or replace function public._wallet_apply(
  p_uid    uuid,
  p_delta  integer,
  p_reason public.point_reason,
  p_ref    uuid  default null,
  p_memo   text  default null
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_new integer;
begin
  if p_uid is null then raise exception '대상 유저가 없습니다' using errcode = 'P0001'; end if;
  if p_delta = 0   then raise exception '변동액이 0입니다'   using errcode = 'P0001'; end if;

  -- 대상 지갑 보장 후 잠금 (없으면 balance 0 으로 생성)
  insert into public.user_wallets (user_id) values (p_uid) on conflict (user_id) do nothing;
  select balance + p_delta into v_new
    from public.user_wallets where user_id = p_uid for update;

  if v_new < 0 then
    raise exception '포인트가 부족합니다.' using errcode = 'P0001';
  end if;

  update public.user_wallets set balance = v_new where user_id = p_uid;

  insert into public.point_transactions (user_id, delta, reason, balance_after, ref_id, memo)
  values (p_uid, p_delta, p_reason, v_new, p_ref, p_memo);

  return v_new;
end;
$$;
revoke all on function public._wallet_apply(uuid,integer,public.point_reason,uuid,text) from public, anon, authenticated;

-- ============================================================
-- 5. debit_coop_deposit 재배선 — 차감을 _wallet_apply('board') 로 위임
--    (시그니처에 ref 추가: 어떤 버스의 차감인지 원장에 남기기 위함 → 1-arg 버전 drop)
-- ============================================================
drop function if exists public.debit_coop_deposit(integer);
create or replace function public.debit_coop_deposit(p_amount integer, p_ref uuid default null)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception '인증이 필요합니다' using errcode = '28000'; end if;
  if p_amount is null or p_amount <= 0 then
    raise exception '차감액이 올바르지 않습니다' using errcode = 'P0001';
  end if;
  -- 음수 delta → 잔액 부족 시 _wallet_apply 가 '포인트가 부족합니다' raise (트랜잭션 롤백)
  return public._wallet_apply(v_uid, -p_amount, 'board', p_ref, null);
end;
$$;
revoke all on function public.debit_coop_deposit(integer, uuid) from public, anon;
grant execute on function public.debit_coop_deposit(integer, uuid) to authenticated;

-- ============================================================
-- 6. add_attendance_points — 출석 적립 50P (KST 하루 1회, 서버 강제)
--    어뷰징 방지: 지갑 행 FOR UPDATE 잠금으로 동시 광클/직접 API 연타를 직렬화.
--    '하루' 경계는 반드시 KST(Asia/Seoul) — UTC 쓰면 자정~09시 경계 어긋남.
-- ============================================================
create or replace function public.add_attendance_points()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid     uuid := auth.uid();
  v_award   constant integer := 50;
  v_today   date := (now() at time zone 'Asia/Seoul')::date;
  v_last    date;
  v_balance integer;
begin
  if v_uid is null then raise exception '인증이 필요합니다' using errcode = '28000'; end if;

  insert into public.user_wallets (user_id) values (v_uid) on conflict (user_id) do nothing;
  select balance, last_attendance_date into v_balance, v_last
    from public.user_wallets where user_id = v_uid for update;   -- 동시 호출 직렬화

  if v_last = v_today then
    return jsonb_build_object('awarded', false, 'already', true, 'points', 0, 'balance', v_balance);
  end if;

  update public.user_wallets set last_attendance_date = v_today where user_id = v_uid;
  v_balance := public._wallet_apply(v_uid, v_award, 'attendance', null, 'daily attendance KST ' || v_today::text);

  return jsonb_build_object('awarded', true, 'already', false, 'points', v_award, 'balance', v_balance);
end;
$$;
revoke all on function public.add_attendance_points() from public, anon;
grant execute on function public.add_attendance_points() to authenticated;

-- ============================================================
-- 7. admin_grant_points — 관리자 본인 지갑에 1000P 등 적립 (God Mode 서버화)
--    서버단 관리자 화이트리스트(UUID) 검증 → 클라 위조 불가.
-- ============================================================
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
  if v_uid not in (
    '4a612066-9a5d-4da1-905f-fe276fb73908',
    '82feb4b1-5365-4ff9-b68b-ce1b0805a2b2',
    '6b2482ab-ddde-46a2-bb71-f26880619fd2'
  ) then
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

-- ============================================================
-- 8. sync_local_points 재배선 — 적립을 _wallet_apply('sync') 로 (멱등 플래그 유지)
-- ============================================================
create or replace function public.sync_local_points(p_points integer)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid     uuid := auth.uid();
  v_balance integer;
  v_synced  boolean;
begin
  if v_uid is null then raise exception '인증이 필요합니다' using errcode = '28000'; end if;
  if p_points <= 0    then p_points := 0; end if;
  if p_points > 10000 then p_points := 10000; end if;

  insert into public.user_wallets (user_id) values (v_uid) on conflict (user_id) do nothing;
  select balance, points_synced into v_balance, v_synced
    from public.user_wallets where user_id = v_uid for update;

  -- ★ 플래그 기반 멱등: 이미 1회 동기화했으면 추가 적립 없음(무한 발행 차단)
  if v_synced then return v_balance; end if;

  update public.user_wallets set points_synced = true where user_id = v_uid;
  if p_points > 0 then
    return public._wallet_apply(v_uid, p_points, 'sync', null, 'localStorage migration');
  end if;
  return v_balance;
end;
$$;
revoke all on function public.sync_local_points(integer) from public, anon;
grant execute on function public.sync_local_points(integer) to authenticated;

-- ============================================================
-- 9. join_coop_bus 재정의 — 차감 호출에 bus_id(ref) 전달 (원장에 'board' + bus_id)
--    그 외 검증/원자적 INSERT 는 마이그 22 와 동일.
-- ============================================================
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
  p_memo         text default null
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
begin
  if v_uid is null then raise exception '인증이 필요합니다' using errcode = '28000'; end if;

  -- [방어 0.5] 잔액 fail-fast (비잠금) — 실제 차감/락은 debit_coop_deposit 이 담당
  select balance into v_balance from public.user_wallets where user_id = v_uid;
  if v_balance is null then raise exception '지갑 정보를 찾을 수 없습니다' using errcode = 'P0001'; end if;
  if v_balance < 300 then
    raise exception '포인트가 부족합니다. (탑승 안심 수수료 300P 필요)' using errcode = 'P0001';
  end if;

  -- [방어 0] 중복 탑승 차단
  if exists (select 1 from public.bus_riders where bus_id = p_bus_id and user_id = v_uid) then
    raise exception '이미 탑승한 버스입니다' using errcode = 'P0001';
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

  -- 고스트 라이더 방어: 마감/부재 버스 차단
  if not exists (select 1 from public.buses b where b.id = p_bus_id and b.ordered = false) then
    raise exception '이미 마감되었거나 존재하지 않는 공구입니다' using errcode = 'P0001';
  end if;

  -- 300P 차감 (락+권위검증+원장 'board' 기록). 잔액부족이면 여기서 롤백.
  perform public.debit_coop_deposit(300, p_bus_id);

  insert into public.bus_riders
    (bus_id, user_id, nick, product_name, qty, yen, power, method, amount, paid, issue, has_addr, memo)
  values
    (p_bus_id, v_uid, p_nick, p_product_name, coalesce(p_qty,1), coalesce(p_yen,0), p_power,
     coalesce(p_method,'conv'), coalesce(p_amount,0), false, null, true, p_memo)
  returning id into v_rider_id;

  insert into public.bus_rider_private
    (rider_id, bus_id, user_id, real_name, phone, address, payer)
  values
    (v_rider_id, p_bus_id, v_uid, p_real_name, p_phone, p_address, p_payer);

  return v_rider_id;
end;
$$;

-- ============================================================
-- 10. rpc_cancel_coop_by_host 재정의 — 환불을 _wallet_apply('host_cancel_refund') 루프로
--     (원장을 파티원별로 정확히 남기기 위해 group-by upsert → per-user 루프)
-- ============================================================
create or replace function public.rpc_cancel_coop_by_host(p_bus_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_deposit   constant integer := 300;
  v_uid       uuid := auth.uid();
  v_owner     uuid;
  v_refunded  integer := 0;
  v_new_count integer;
  v_count     integer;
  v_trust     integer;
  v_suspended boolean;
  v_until     timestamptz;
  v_rrec      record;
begin
  if v_uid is null then raise exception '인증이 필요합니다.' using errcode = '28000'; end if;

  select b.owner_id into v_owner from public.buses b where b.id = p_bus_id for update;
  if not found then raise exception '이미 무산되었거나 존재하지 않는 공구입니다.' using errcode = 'P0002'; end if;
  if v_owner <> v_uid then raise exception '권한이 없습니다. 방장만 공구를 무산시킬 수 있습니다.' using errcode = '42501'; end if;

  -- ① 파티원 보증금 환불 (유저별 루프 → 원장 1줄씩 기록)
  for v_rrec in
    select r.user_id as uid, count(*)::int as cnt
      from public.bus_riders r
     where r.bus_id = p_bus_id
     group by r.user_id
  loop
    perform public._wallet_apply(v_rrec.uid, v_rrec.cnt * v_deposit, 'host_cancel_refund', p_bus_id, 'host fault cancel refund');
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

  -- ③ 공구 무산: 삭제(riders/private cascade)
  delete from public.buses where id = p_bus_id;

  return jsonb_build_object(
    'bus_id', p_bus_id, 'refunded_riders', v_refunded, 'deposit_each', v_deposit,
    'host_cancel_count', v_new_count, 'trust_score', v_trust,
    'is_host_suspended', v_suspended, 'suspended_until', v_until
  );
end;
$$;
revoke all on function public.rpc_cancel_coop_by_host(uuid) from public, anon;
grant execute on function public.rpc_cancel_coop_by_host(uuid) to authenticated;
