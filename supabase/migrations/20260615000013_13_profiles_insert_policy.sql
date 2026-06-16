-- ============================================================
-- 13_profiles_insert_policy.sql
--   본인 프로필 자가 생성(INSERT) 정책.
--   handle_new_user() 트리거 도입 이전에 만들어진 계정은 profiles 행이
--   없을 수 있음 → 게시물 작성 시 author_id FK(REFERENCES profiles) 위반.
--   클라이언트가 본인 id 로 프로필을 보충 생성할 수 있도록 허용.
--   (06_rls.sql 에는 select/update 만 있고 insert 정책이 없었음)
-- ============================================================
create policy "본인 프로필만 생성" on public.profiles
  for insert with check (auth.uid() = id);
