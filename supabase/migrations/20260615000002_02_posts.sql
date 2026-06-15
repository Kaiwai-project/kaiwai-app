-- ============================================================
-- 02_posts.sql  —  OOTD 피드 (이미지 다중 대비: text[] 1~10장)
-- ============================================================
create table public.posts (
  id         uuid        primary key default gen_random_uuid(),
  author_id  uuid        not null references public.profiles(id) on delete cascade,
  caption    text,
  image_urls text[]      not null check (array_length(image_urls, 1) between 1 and 10),
  like_count integer     not null default 0,   -- 비정규화 카운터 (03_likes 트리거로 유지)
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on column public.posts.image_urls is '최대 10장. 현재는 1장만 넣어도 무방 (다중 확장 대비)';

create index posts_author_idx     on public.posts (author_id);
create index posts_created_at_idx on public.posts (created_at desc);  -- 피드 정렬
