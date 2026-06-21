-- ============================================================
-- 25_economy_lens_catalog.sql
--   1. 경제 밸런스: 출석 적립 50P → 100P (3일 출석 = 1회 탑승 300P)
--   2. 렌즈 카탈로그 서버화: index.html 하드코딩 curatedLenses → lens_catalog 테이블
--      · 관리자가 DB(대시보드/service_role)만 수정해도 프론트에 동적 반영
--      · 카테고리 = 무드/스타일(지뢰계/양산형/갸루/내추럴) — KAIWAI 브랜드 정체성
-- ============================================================

-- ── 1. 출석 적립 상수 100P 로 상향 (마이그23 함수 본문만 교체) ──
--    감사 무결성: 기존 원장의 50P 내역은 소급 변경하지 않는다(불변 로그).
create or replace function public.add_attendance_points()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid     uuid := auth.uid();
  v_award   constant integer := 100;   -- 50 → 100 (3일 출석 = 1회 탑승)
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

-- ── 2. lens_catalog 테이블 ──
create table if not exists public.lens_catalog (
  id          uuid        primary key default gen_random_uuid(),
  code        text        unique,                        -- 'L01'… 레거시 lensId 호환
  brand       text,
  name        text        not null,
  price_yen   integer     not null check (price_yen >= 0),
  image_url   text,                                       -- Supabase Storage 공개 URL
  category    text,                                       -- 무드: 지뢰계/양산형/갸루/내추럴 …
  is_active   boolean     not null default true,
  sort_order  integer     not null default 0,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
comment on table public.lens_catalog is '추천 렌즈 카탈로그(SSOT). 공개 SELECT(활성행만). 쓰기는 service_role/대시보드 전용.';
create index if not exists idx_lens_catalog_sort on public.lens_catalog(sort_order);

drop trigger if exists trg_lens_catalog_touch on public.lens_catalog;
create trigger trg_lens_catalog_touch before update on public.lens_catalog
  for each row execute function public.touch_updated_at();

-- RLS: 활성 행만 공개 조회. 클라 쓰기 정책 없음(관리자는 대시보드/service_role).
alter table public.lens_catalog enable row level security;
drop policy if exists "카탈로그: 활성행 공개조회" on public.lens_catalog;
create policy "카탈로그: 활성행 공개조회" on public.lens_catalog
  for select to anon, authenticated
  using (is_active = true);

-- ── 3. 시드(현재 6종) — 카테고리는 무드/스타일 기준 ──
insert into public.lens_catalog (code, brand, name, price_yen, category, sort_order) values
  ('L01', 'Flurry',          'Flurry 원데이 (칭찬받는 판다)',     1760, '갸루',   1),
  ('L02', 'Flurry',          'Flurry 먼슬리 (사랑받는 링고)',     1320, '내추럴', 2),
  ('L03', 'Bambi Series',    'Bambi Series 원데이 (아몬드)',      1760, '내추럴', 3),
  ('L04', 'Bambi Series',    'Bambi Series 먼슬리 (스완 블루)',   1650, '양산형', 4),
  ('L05', 'Chu''s Lens',     'Chu''s Lens 원데이 (모테 브라운)',  1705, '양산형', 5),
  ('L06', 'Majolica Majorca','Majolica Majorca (지뢰계 블랙)',    1600, '지뢰계', 6)
on conflict (code) do nothing;
