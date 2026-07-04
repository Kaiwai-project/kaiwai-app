// ============================================================
// copy-web-assets.mjs — KAIWAI 웹 런타임 자산만 www/ 로 복사 (Capacitor webDir)
//
//   KAIWAI 는 빌드 스텝 없는 단일 index.html 앱이라, 프로젝트 루트에 웹자산·시크릿·
//   빌드소스가 섞여 있다. webDir 를 루트로 잡으면 .env.local(SERVICE_ROLE_KEY!)·
//   node_modules·supabase 마이그레이션 등이 앱에 번들되어 치명적 유출이 된다.
//   → 안전한 ALLOWLIST 방식: 아래 명시한 웹 런타임 자산만 www/ 로 복사한다.
//   (denylist 는 새 시크릿 추가 시 실수로 포함될 위험이 있어 의도적으로 배제)
//
//   자산 목록 근거: index.html/profile.html/*.js 의 실제 로컬 참조 분석
//     · HTML: index/profile/privacy/terms
//     · JS  : auth/coop-core/profile,  CSS: profile.css
//     · 폴더: assets(kaiwai.tailwind.css) / illust / UI / auth(callback.html)
//     · 루트 이미지: wallpaper.jpg, kaiwai-logo-trim_resize.png
//   (backgrounds/ images/ logos/ src/ 는 로컬 참조 0 = Supabase 스토리지 업로드용 소스 → 제외)
// ============================================================
import { existsSync, rmSync, mkdirSync, cpSync, readdirSync, statSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const WWW = join(ROOT, 'www');

// ⚠️ 절대 추가 금지: .env.local, node_modules, supabase, *.py, *.csv/xlsx, android, .git
const ALLOWLIST = [
  'index.html', 'profile.html', 'privacy.html', 'terms.html',
  'auth.js', 'coop-core.js', 'profile.js', 'profile.css',
  'wallpaper.jpg', 'kaiwai-logo-trim_resize.png',
  'calendar_data.json',                 // loadCal() 이 fetch 하는 캘린더 데이터(웹뷰 번들 필수 — 누락 시 앱 캘린더 빈 상태)
  'assets', 'illust', 'UI', 'auth',
];

// 안전장치: 혹시라도 시크릿/민감 항목이 목록에 들어오면 즉시 중단
const FORBIDDEN = /^\.env|node_modules|^supabase$|\.(py|csv|xlsx)$|^\.git/i;
for (const e of ALLOWLIST) {
  if (FORBIDDEN.test(e)) { console.error(`✗ 금지된 항목이 ALLOWLIST 에 있습니다: ${e}`); process.exit(1); }
}

// www 초기화(기존 내용 제거 후 재생성)
if (existsSync(WWW)) rmSync(WWW, { recursive: true, force: true });
mkdirSync(WWW, { recursive: true });

let files = 0, missing = [];
const countFiles = (p) => statSync(p).isDirectory()
  ? readdirSync(p).reduce((n, c) => n + countFiles(join(p, c)), 0) : 1;

for (const entry of ALLOWLIST) {
  const src = join(ROOT, entry);
  if (!existsSync(src)) { missing.push(entry); continue; }
  cpSync(src, join(WWW, entry), { recursive: true });
  files += countFiles(src);
}

console.log(`✓ www/ 동기화 완료 — 항목 ${ALLOWLIST.length - missing.length}개 / 파일 ${files}개`);
if (missing.length) console.warn(`  (누락: ${missing.join(', ')})`);
