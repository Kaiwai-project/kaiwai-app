-- ============================================================
-- 38_notifications.sql  —  [Phase2-1] 실시간 크로스-유저 푸시 알림
--
--   로컬 sendNotification(localStorage) 을 대체하는 진짜 DB 기반 알림.
--   · notifications 테이블 + RLS(본인만). INSERT 정책 없음 = 클라 위조 차단(Zero Trust).
--     생성은 전부 서버 DEFINER 경로(_notify 헬퍼 / 트리거 / RPC)로만.
--   · supabase_realtime publication 추가 → 클라가 자기 알림 INSERT 를 실시간 수신.
--   · 30일 경과 알림은 INSERT 시점 트리거로 자동 정리(별도 cron 불요).
--   알림 발생: 탑승(→총대) / 수정요청(→총대) / 승인·반려(→탑승자) / 자동마감(→총대).
-- ============================================================

-- 1) 테이블
create table if not exists public.notifications (
  id         uuid        primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  user_id    uuid        not null references auth.users(id) on delete cascade,  -- 수신자
  title      text        not null,
  body       text,
  type       text,           -- bus_join / mod_request / mod_approved / mod_rejected / bus_ordered
  link_id    uuid,           -- 딥링크 대상(버스 id 등)
  is_read    boolean     not null default false
);
create index if not exists idx_notifications_user on public.notifications(user_id, created_at desc);

-- 2) RLS — 본인 알림만 조회/수정(읽음)/삭제. INSERT 정책 없음(서버 DEFINER 전용).
alter table public.notifications enable row level security;
drop policy if exists "본인 알림 조회" on public.notifications;
drop policy if exists "본인 알림 수정" on public.notifications;
drop policy if exists "본인 알림 삭제" on public.notifications;
create policy "본인 알림 조회" on public.notifications for select using (user_id = auth.uid());
create policy "본인 알림 수정" on public.notifications for update using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "본인 알림 삭제" on public.notifications for delete using (user_id = auth.uid());
revoke all on public.notifications from anon, authenticated;
grant select, update, delete on public.notifications to authenticated;   -- insert 미부여(클라 생성 차단)

-- 3) Realtime publication 추가(중복 가드)
do $$ begin
  begin alter publication supabase_realtime add table public.notifications; exception when duplicate_object then null; end;
end $$;

-- 4) 중앙 알림 생성 헬퍼 — 서버 DEFINER 전용(authenticated 직접 호출 불가 = 위조 차단)
create or replace function public._notify(p_uid uuid, p_title text, p_body text, p_type text, p_link_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_uid is null then return; end if;
  if p_uid = auth.uid() then return; end if;   -- 본인 행동엔 알림 안 보냄(노이즈 감소)
  insert into public.notifications(user_id, title, body, type, link_id)
    values (p_uid, p_title, p_body, p_type, p_link_id);
end;
$$;
revoke all on function public._notify(uuid,text,text,text,uuid) from public, anon, authenticated;

-- 5) 30일 자동 정리 트리거 (INSERT 시 해당 유저 옛 알림 DELETE)
create or replace function public.prune_old_notifications()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from public.notifications
   where user_id = new.user_id and created_at < now() - interval '30 days';
  return null;   -- AFTER 트리거
end;
$$;
drop trigger if exists trg_prune_notifications on public.notifications;
create trigger trg_prune_notifications
  after insert on public.notifications
  for each row execute function public.prune_old_notifications();

-- 6) 새 탑승자 → 총대 알림 (bus_riders AFTER INSERT)
create or replace function public.notify_new_rider()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare v_owner uuid;
begin
  select owner_id into v_owner from public.buses where id = new.bus_id;
  perform public._notify(v_owner, '🚌 새 탑승자!', coalesce(new.nick,'누군가') || '님이 버스에 탔어요!', 'bus_join', new.bus_id);
  return null;
end;
$$;
drop trigger if exists trg_notify_new_rider on public.bus_riders;
create trigger trg_notify_new_rider
  after insert on public.bus_riders
  for each row execute function public.notify_new_rider();

-- 7) 수정 요청 생성(mod_request null→notnull) → 총대 알림 (bus_riders AFTER UPDATE)
create or replace function public.notify_mod_request()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare v_owner uuid;
begin
  if old.mod_request is null and new.mod_request is not null then
    select owner_id into v_owner from public.buses where id = new.bus_id;
    perform public._notify(v_owner, '🚨 정보 수정 요청', coalesce(new.nick,'탑승자') || '님의 정보 수정 요청이 들어왔습니다.', 'mod_request', new.bus_id);
  end if;
  return null;
end;
$$;
drop trigger if exists trg_notify_mod_request on public.bus_riders;
create trigger trg_notify_mod_request
  after update on public.bus_riders
  for each row execute function public.notify_mod_request();

-- 8) 자동/수동 마감(ordered false→true) → 총대 알림 (buses AFTER UPDATE)
create or replace function public.notify_bus_ordered()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.ordered = true and coalesce(old.ordered,false) = false then
    perform public._notify(new.owner_id, '🎉 목표 달성! 버스 마감', '버스가 마감되었습니다. 발주를 진행해 주세요.', 'bus_ordered', new.id);
  end if;
  return null;
end;
$$;
drop trigger if exists trg_notify_bus_ordered on public.buses;
create trigger trg_notify_bus_ordered
  after update on public.buses
  for each row execute function public.notify_bus_ordered();

-- 9) approve_mod_request 재정의 (마이그36 본문 + 탑승자 알림)
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
  v_rider  uuid;
  v_req    jsonb;
  v_yen    integer;
  v_qty    integer;
  v_power  text;
  v_method text;
  v_goods  integer;
  v_amount integer;
  v_goal   integer;
  v_pprice integer;
  v_others integer;
  v_total  integer;
  v_closed boolean;
begin
  if v_uid is null then raise exception '인증이 필요합니다' using errcode = '28000'; end if;

  select bus_id, mod_request, yen, user_id
    into v_bus_id, v_req, v_yen, v_rider
    from public.bus_riders where id = p_rider_id for update;
  if not found then raise exception '대상 라이더를 찾을 수 없습니다' using errcode = 'P0001'; end if;

  select owner_id into v_owner from public.buses where id = v_bus_id;
  if v_owner is distinct from v_uid then
    raise exception '방장만 수정 요청을 승인할 수 있습니다' using errcode = '42501';
  end if;
  if v_req is null then raise exception '대기 중인 수정 요청이 없습니다' using errcode = 'P0001'; end if;

  v_qty    := coalesce((v_req->>'qty')::int, 1);
  v_power  := coalesce(v_req->>'power', '');
  v_method := coalesce(v_req->>'method', 'conv');
  if v_qty < 1 or v_qty > 100 then raise exception '수량이 올바르지 않습니다' using errcode = 'P0001'; end if;
  if v_method not in ('conv','home','etc') then raise exception '수령 방법이 올바르지 않습니다' using errcode = 'P0001'; end if;
  if char_length(v_power) > 60 then raise exception '도수 값이 올바르지 않습니다' using errcode = 'P0001'; end if;

  -- 면세 한도 방어
  select goal, coalesce(product_price, 0) into v_goal, v_pprice from public.buses where id = v_bus_id;
  select coalesce(sum(yen * qty), 0) into v_others
    from public.bus_riders where bus_id = v_bus_id and id <> p_rider_id;
  v_total := v_pprice + v_others + (v_yen * v_qty);
  if v_total > v_goal then
    raise exception '수량을 늘리면 공구방의 남은 면세 한도를 초과하게 되어 승인할 수 없습니다.' using errcode = 'P0001';
  end if;

  v_goods  := v_yen * v_qty * 9;
  v_amount := v_goods + case v_method when 'conv' then 1800 when 'home' then 3500 else 0 end;

  update public.bus_riders
     set qty = v_qty, power = v_power, method = v_method, amount = v_amount, mod_request = null
   where id = p_rider_id;

  v_closed := public.auto_close_bus_if_full(v_bus_id);

  -- 탑승자에게 승인 알림
  perform public._notify(v_rider, '✅ 수정 요청 승인', '총대가 수량/도수 변경을 승인했어요. 변경된 금액을 확인해주세요!', 'mod_approved', v_bus_id);

  return jsonb_build_object('ok', true, 'rider_id', p_rider_id, 'qty', v_qty, 'amount', v_amount, 'closed', coalesce(v_closed, false));
end;
$$;
revoke all on function public.approve_mod_request(uuid) from public, anon;
grant execute on function public.approve_mod_request(uuid) to authenticated;

-- 10) reject_mod_request 재정의 (+ 탑승자 알림)
create or replace function public.reject_mod_request(p_rider_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid    uuid := auth.uid();
  v_bus_id uuid;
  v_owner  uuid;
  v_rider  uuid;
begin
  if v_uid is null then raise exception '인증이 필요합니다' using errcode = '28000'; end if;
  select bus_id, user_id into v_bus_id, v_rider from public.bus_riders where id = p_rider_id for update;
  if not found then raise exception '대상 라이더를 찾을 수 없습니다' using errcode = 'P0001'; end if;
  select owner_id into v_owner from public.buses where id = v_bus_id;
  if v_owner is distinct from v_uid then
    raise exception '방장만 처리할 수 있습니다' using errcode = '42501';
  end if;
  update public.bus_riders set mod_request = null where id = p_rider_id;
  perform public._notify(v_rider, '↩️ 수정 요청 반려', '총대가 수정 요청을 반려했어요. 기존 정보가 유지됩니다.', 'mod_rejected', v_bus_id);
  return jsonb_build_object('ok', true, 'rejected', true);
end;
$$;
revoke all on function public.reject_mod_request(uuid) from public, anon;
grant execute on function public.reject_mod_request(uuid) to authenticated;
