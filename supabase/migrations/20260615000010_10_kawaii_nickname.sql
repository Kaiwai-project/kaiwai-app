-- ============================================================
-- 10_kawaii_nickname.sql  —  소셜 가입 시 display_name 자동 생성
--   메타데이터(full_name/name/nickname)에 이름이 있으면 그대로 사용,
--   없을 때만 카이와이 톤의 랜덤 닉네임을 display_name 에 부여.
--   (한글이라 username 제약 ^[a-zA-Z0-9_]{3,20}$ 에 못 들어가므로
--    username 은 기존 로직 유지, 한글 닉네임은 display_name 전용)
-- ============================================================
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  meta      jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb);
  _username text;
  _display  text;
  adjs      text[] := array[
    '말랑말랑한','딸기맛','폭신한','멘헤라','오컬트','반짝이는',
    '새콤한','몽글몽글한','우유빛','꿈꾸는','울보','새침한',
    '보들보들한','알록달록한','비밀스러운','시럽맛','마시멜로','졸린',
    '수줍은','나른한','복숭아빛','청포도맛','솜털같은','반짝반짝'
  ];
  nouns     text[] := array[
    '아기토끼','마법소녀','솜사탕곰','천사님','악마짱','요정',
    '유령','인형공주','별사탕','리본냥','젤리곰','막대사탕',
    '꼬마마녀','봉제인형','설탕별','푸딩','마카롱','체리',
    '달토끼','구름양','슈크림','복숭아','양젤리','새끼고양이'
  ];
begin
  -- username 후보: 메타데이터 → 없으면 id 앞 8자리 기반 기본값
  _username := coalesce(
    nullif(meta->>'user_name', ''),
    nullif(meta->>'preferred_username', ''),
    nullif(meta->>'nickname', ''),
    'user_' || substr(replace(new.id::text, '-', ''), 1, 8)
  );

  -- username_format(영문/숫자/_ 3~20자) 위반 또는 중복 시 안전한 기본값으로 대체
  if _username !~ '^[a-zA-Z0-9_]{3,20}$'
     or exists (select 1 from public.profiles where username = _username) then
    _username := 'user_' || substr(replace(new.id::text, '-', ''), 1, 12);
  end if;

  -- display_name: 메타데이터의 표시 이름 → 없으면 카이와이 랜덤 닉네임
  _display := nullif(coalesce(meta->>'full_name', meta->>'name', meta->>'nickname'), '');
  if _display is null then
    _display :=
        adjs[1 + floor(random() * array_length(adjs, 1))::int]
     || nouns[1 + floor(random() * array_length(nouns, 1))::int]
     || lpad((floor(random() * 10000))::int::text, 4, '0');   -- 중복 방지 4자리 (앞자리 0 보존)
  end if;

  insert into public.profiles (id, username, display_name, avatar_url)
  values (
    new.id,
    _username,
    _display,
    coalesce(meta->>'avatar_url', meta->>'picture', meta->>'profile_image')
  );

  return new;
end;
$$;
