-- ============================================================
-- 49_point_reason_admin_revoke.sql
--   관리자 음수 차감(admin_grant_points_to 의 -amount) 감사용 사유값 추가.
--   ※ alter type ... add value 는 같은 트랜잭션에서 그 값을 literal 로 즉시
--     사용할 수 없으므로, 함수(마이그50)와 분리된 단독 마이그레이션으로 둔다.
-- ============================================================
alter type public.point_reason add value if not exists 'admin_revoke';
