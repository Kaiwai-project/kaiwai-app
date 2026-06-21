-- ============================================================
-- 26_lens_assets.sql  —  렌즈 카탈로그 이미지 인프라
--   1. lens-assets public 스토리지 버킷 + 공개 읽기 정책
--   2. 시드 6종 image_url 더미 이미지(placehold.co) UPDATE
--      ※ 실제 렌즈 이미지 확보 시 lens-assets 버킷에 업로드 후 공개 URL 로 교체.
-- ============================================================

-- ── 1. lens-assets 공개 버킷 ──
insert into storage.buckets (id, name, public)
values ('lens-assets', 'lens-assets', true)
on conflict (id) do nothing;

-- 공개 조회(Public Read) — 누구나 렌즈 이미지를 볼 수 있음
drop policy if exists "렌즈 이미지 공개 조회" on storage.objects;
create policy "렌즈 이미지 공개 조회" on storage.objects
  for select using (bucket_id = 'lens-assets');

-- (쓰기는 정책 없음 → service_role/대시보드 전용. 카탈로그 자체와 동일한 운영 모델)

-- ── 2. 더미 이미지 URL 할당 (무드 컬러 + 브랜드 텍스트) ──
update public.lens_catalog set image_url = 'https://placehold.co/400x400/E5468A/ffffff/png?text=Flurry+Panda'    where code = 'L01';
update public.lens_catalog set image_url = 'https://placehold.co/400x400/C8A88A/ffffff/png?text=Flurry+Ringo'    where code = 'L02';
update public.lens_catalog set image_url = 'https://placehold.co/400x400/B89A7A/ffffff/png?text=Bambi+Almond'    where code = 'L03';
update public.lens_catalog set image_url = 'https://placehold.co/400x400/7FB5D6/ffffff/png?text=Bambi+Swan'      where code = 'L04';
update public.lens_catalog set image_url = 'https://placehold.co/400x400/D6A27F/ffffff/png?text=Chus+Brown'      where code = 'L05';
update public.lens_catalog set image_url = 'https://placehold.co/400x400/2B2330/E5468A/png?text=Majolica+Black' where code = 'L06';
