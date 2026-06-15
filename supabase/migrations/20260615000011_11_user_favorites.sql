-- ============================================================
-- 11_user_favorites.sql  —  브랜드 즐겨찾기 (좋아요)
--   클라이언트 브랜드 상수(B 배열)의 정수 id 를 저장.
--   brand_id 는 DB에 brands 테이블이 없으므로 FK 없는 정수.
--   복합 PK (user_id, brand_id) 로 중복 즐겨찾기 방지.
-- ============================================================
create table public.user_favorites (
  user_id    uuid        not null references public.profiles(id) on delete cascade,
  brand_id   integer     not null,
  created_at timestamptz not null default now(),
  primary key (user_id, brand_id)
);

-- "내 즐겨찾기"를 최근순으로 빠르게 조회
create index user_favorites_user_idx on public.user_favorites (user_id, created_at desc);

-- RLS: 본인 것만 조회/추가/삭제
alter table public.user_favorites enable row level security;

create policy "본인 즐겨찾기 조회" on public.user_favorites
  for select using (auth.uid() = user_id);

create policy "본인만 즐겨찾기 추가" on public.user_favorites
  for insert with check (auth.uid() = user_id);

create policy "본인만 즐겨찾기 삭제" on public.user_favorites
  for delete using (auth.uid() = user_id);
