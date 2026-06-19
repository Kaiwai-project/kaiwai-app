-- ════════════════════════════════════════════════════════════════════════
--  제안: 매월 말일 자정(KST) 브랜드 하트(좋아요) 일괄 0 리셋
--  ------------------------------------------------------------------------
--  ⚠️ 이 파일은 "제안"입니다. supabase/migrations/ 의 번호 마이그레이션이 아니므로
--     `supabase db push` 로 자동 적용되지 않습니다. 도입을 결정하면 내용 검토 후
--     대시보드 SQL Editor 에서 직접 실행하거나, migrations 로 옮겨 번호를 붙이세요.
--
--  배경: 현재 index.html 의 브랜드 하트 수는 '티어 기반 의사난수 베이스(_mockBase)
--        + localStorage 증감(delta)' 로 표시되는 클라이언트 전용 값입니다.
--        실제 DB 집계(brand_likes)로 전환할 때 아래 스키마 + pg_cron 을 쓰면
--        매월 1일 00:00(KST = UTC 전일 15:00)에 모든 브랜드 하트가 0으로 리셋됩니다.
--  ════════════════════════════════════════════════════════════════════════

-- 1) 브랜드 하트 집계 테이블 (브랜드당 1행, count 누적)
create table if not exists public.brand_likes (
  brand_id   integer primary key,
  like_count integer not null default 0,
  updated_at timestamptz not null default now()
);

alter table public.brand_likes enable row level security;

-- 공개 조회 허용 (랭킹/카드 표시용)
drop policy if exists "brand_likes_select" on public.brand_likes;
create policy "brand_likes_select" on public.brand_likes
  for select to anon, authenticated using (true);

-- 증감은 보안 정의자 RPC 로만 (직접 update 금지 → 정책 없음 = 차단)

-- 2) 좋아요 토글 RPC (낙관적 UI 와 함께 사용; delta = +1 / -1)
create or replace function public.bump_brand_like(p_brand_id integer, p_delta integer)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count integer;
begin
  insert into public.brand_likes (brand_id, like_count, updated_at)
  values (p_brand_id, greatest(0, p_delta), now())
  on conflict (brand_id) do update
    set like_count = greatest(0, public.brand_likes.like_count + p_delta),
        updated_at = now()
  returning like_count into v_count;
  return v_count;
end;
$$;

grant execute on function public.bump_brand_like(integer, integer) to authenticated;

-- 3) 월간 리셋 함수 — 모든 브랜드 하트 0
create or replace function public.reset_brand_likes()
returns void
language sql
security definer
set search_path = public
as $$
  update public.brand_likes set like_count = 0, updated_at = now();
$$;

-- 4) pg_cron 스케줄 (매월 1일 00:00 KST = 매월 1일 15:00 UTC 전날... 주의: KST=UTC+9)
--    매월 1일 00:00 KST → 전월 말일 15:00 UTC. cron 은 UTC 기준이므로 '매월 마지막 날 15시'가
--    아니라 '매월 1일 00:00 KST' 를 정확히 맞추려면 'min hour day month dow' = '0 15 L * *'.
--    pg_cron 은 'L'(말일)을 지원하지 않으므로, 안전하게 '매월 1일 15:00 UTC'(=1일 자정+9h KST,
--    즉 1일 오전 0시 KST 보다 정확히는 1일 00:00 UTC=09:00 KST). 요구사항이 'KST 말일 자정'이면
--    아래처럼 매월 1일 00:00 KST(= 전월 말일 15:00 UTC) 에 맞춰 매일 15시 UTC 에서 내일이 1일인지 확인.
--    → 가장 단순·정확: 매일 15:05 UTC 에 '내일이 1일이면 리셋'.
create extension if not exists pg_cron;

select cron.schedule(
  'reset-brand-likes-monthly',
  '5 15 * * *',  -- 매일 15:05 UTC (= 00:05 KST)
  $$ select public.reset_brand_likes()
     where (now() at time zone 'Asia/Seoul')::date - interval '0 day'
           = date_trunc('month', (now() at time zone 'Asia/Seoul'))::date; $$
);

-- 스케줄 해제: select cron.unschedule('reset-brand-likes-monthly');
