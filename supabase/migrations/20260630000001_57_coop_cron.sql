-- ============================================================
-- 57_coop_cron.sql  —  공구 라이프사이클 자정 배치 (pg_cron)
--
--   · 매일 00:00 KST(=15:00 UTC) 만료/미달 공구 정리: expire_overdue_buses()
--   · 매일 00:30 KST(=15:30 UTC) 1년 보존만료 물리정리: sweep_coop_archive()
--   재적용 안전을 위해 기존 동일 job 은 먼저 unschedule.
-- ============================================================
create extension if not exists pg_cron;

do $$
begin
  -- 기존 잡 제거(있으면)
  if exists (select 1 from cron.job where jobname = 'coop-expire-daily') then
    perform cron.unschedule('coop-expire-daily');
  end if;
  if exists (select 1 from cron.job where jobname = 'coop-archive-purge-daily') then
    perform cron.unschedule('coop-archive-purge-daily');
  end if;
end $$;

-- 만료/미달 정리 — 매일 15:00 UTC(=00:00 KST)
select cron.schedule(
  'coop-expire-daily',
  '0 15 * * *',
  $$ select public.expire_overdue_buses(); $$
);

-- 1년 보존만료 물리정리 — 매일 15:30 UTC(=00:30 KST)
select cron.schedule(
  'coop-archive-purge-daily',
  '30 15 * * *',
  $$ select public.sweep_coop_archive(); $$
);
