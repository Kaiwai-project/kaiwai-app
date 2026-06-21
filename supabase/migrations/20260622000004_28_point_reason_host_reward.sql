-- ============================================================
-- 28_point_reason_host_reward.sql
--   point_reason enum 에 'host_reward'(총대 수고비) 추가.
--   ※ ALTER TYPE ADD VALUE 는 추가한 트랜잭션에서 '사용'할 수 없으므로,
--      이 값을 쓰는 트리거(마이그 29)와 분리해 먼저 커밋한다.
-- ============================================================
alter type public.point_reason add value if not exists 'host_reward';
