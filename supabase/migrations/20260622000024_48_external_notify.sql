-- ============================================================
-- 48_external_notify.sql  —  [Step 10] 외부 실시간 알림 연동 (DB)
--
--   확정 스펙:
--   ① profiles 에 phone / notify_email(기본 true) / notify_sms(기본 false)
--   ② 총대 인증(host_verifications) · 탑승 결제(bus_rider_private) 시 전화번호를
--      profiles.phone 으로 자동 동기화하는 트리거(DEFINER)
--   ③ notification_deliveries(UNIQUE(notification_id, channel)) — 외부발송 멱등/상태 로그
--
--   외부 발송 자체는 Edge Function(send-external-notification) + Database Webhook 이 담당.
--   본 마이그는 그 토대(연락처·동의·발송로그)만 구성.
-- ============================================================

-- ── 1. profiles 연락처 + 채널 동의 ──
alter table public.profiles
  add column if not exists phone        text,
  add column if not exists notify_email boolean not null default true,
  add column if not exists notify_sms   boolean not null default false;
comment on column public.profiles.phone is '외부 알림(SMS/알림톡) 발신용 전화번호. 인증/탑승 시 자동 동기화.';

-- ── 2. 전화번호 자동 동기화 트리거 (DEFINER — profiles 갱신을 RLS 무관하게 보장) ──
create or replace function public.sync_profile_phone()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  -- new.phone(host_verifications/bus_rider_private 공통 컬럼)이 있으면 최신값으로 동기화
  if coalesce(new.phone, '') <> '' then
    update public.profiles set phone = new.phone where id = new.user_id;
  end if;
  return new;
end;
$$;

-- 총대 인증 완료(verify-host → finalize_host_verification) 시
drop trigger if exists trg_sync_phone_verification on public.host_verifications;
create trigger trg_sync_phone_verification
  after insert or update of phone on public.host_verifications
  for each row execute function public.sync_profile_phone();

-- 탑승 결제(join_coop_bus → bus_rider_private INSERT) 시
drop trigger if exists trg_sync_phone_private on public.bus_rider_private;
create trigger trg_sync_phone_private
  after insert on public.bus_rider_private
  for each row execute function public.sync_profile_phone();

-- ── 3. 외부 발송 로그(멱등·상태) — Edge Function(service_role) 전용 적재 ──
create table if not exists public.notification_deliveries (
  id              bigint generated always as identity primary key,
  notification_id uuid not null references public.notifications(id) on delete cascade,
  user_id         uuid not null,
  channel         text not null check (channel in ('email','sms','alimtalk')),
  status          text not null check (status in ('queued','sent','failed','skipped','mock')),
  provider        text,
  error           text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  constraint nd_once unique (notification_id, channel)   -- 웹훅 재시도 중복발송 차단(멱등)
);
create index if not exists idx_nd_notification on public.notification_deliveries(notification_id);
comment on table public.notification_deliveries is '외부 알림 발송 로그(멱등·상태). 적재는 Edge Function(service_role), 조회는 관리자만.';

alter table public.notification_deliveries enable row level security;
-- SELECT 관리자만(운영 모니터링). INSERT/UPDATE/DELETE 정책 없음 = service_role(Edge Function) 전용.
drop policy if exists "발송로그: 관리자만 조회" on public.notification_deliveries;
create policy "발송로그: 관리자만 조회" on public.notification_deliveries
  for select to authenticated using (public.is_app_admin(auth.uid()));

-- updated_at 자동 갱신(공용 트리거 재사용)
drop trigger if exists trg_nd_touch on public.notification_deliveries;
create trigger trg_nd_touch before update on public.notification_deliveries
  for each row execute function public.touch_updated_at();
