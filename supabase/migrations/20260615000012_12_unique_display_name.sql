-- ============================================================
-- 12_unique_display_name.sql  —  닉네임(display_name) 중복 방지
--   프론트 checkNicknameUnique 의 서버측 보강: DB 레벨 UNIQUE 제약.
--   (NULL 은 서로 distinct 취급되어 다중 허용 — 가입 직후 일시적 NULL 안전)
-- ============================================================

-- 1) 기존 중복 정리:
--    같은 display_name 을 가진 행 중 관리자(rmfjwlak114) 외에는 유니크 임시값으로 변경.
--    임시값은 카이와이 패턴이 아니므로, 해당 유저가 마이페이지 접속 시
--    프론트가 자동으로 고유한 카이와이 닉네임으로 보정한다.
update public.profiles p
set display_name = 'user_' || left(replace(p.id::text, '-', ''), 12)
from auth.users u
where u.id = p.id
  and u.email <> 'rmfjwlak114@gmail.com'
  and p.display_name in (
    select display_name
    from public.profiles
    group by display_name
    having count(*) > 1
  );

-- 2) UNIQUE 인덱스
create unique index if not exists profiles_display_name_unique
  on public.profiles (display_name);
