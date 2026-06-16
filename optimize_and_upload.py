# -*- coding: utf-8 -*-
# ============================================================
# optimize_and_upload.py
#   backgrounds/ 의 새 배경 원본을 경량 .webp 로 최적화 →
#   Supabase Storage(public 버킷 'brand-assets')의 bg/ 폴더에 업로드(덮어쓰기) →
#   index.html 의 각 브랜드 bgImg 를 .webp 공개 URL로 일괄 연결 →
#   임시 폴더(backgrounds_optimized/) 삭제.
#
#   파일명 규칙:  backgrounds/{id}_*.jpg  ->  bg/{id}.webp
#                (앞 숫자=브랜드 id 로 매핑. 일본어/특수문자 파일명 무관)
#
#   ⚠️ SUPABASE_SERVICE_ROLE_KEY 는 시크릿 — 코드/깃에 넣지 말 것.
#      환경변수 또는 .env.local 에서만 읽음.
#
#   실행 전 키 설정(둘 중 하나):
#     (A) 환경변수:  $env:SUPABASE_SERVICE_ROLE_KEY="..."   (PowerShell)
#     (B) .env.local 파일에  SUPABASE_SERVICE_ROLE_KEY=...  한 줄 추가
#
#   실행:  python optimize_and_upload.py
# ============================================================
import os
import re
import sys
import glob
import json
import shutil
import subprocess

# ── 튜닝 값 ─────────────────────────────────────────────────
MAX_WIDTH = 1000      # 가로 해상도 상한(px). 더 가볍게 원하면 800 으로 변경
WEBP_QUALITY = 80     # webp 품질(0~100)
SRC_DIR = "backgrounds"
OPT_DIR = "backgrounds_optimized"   # 업로드 후 자동 삭제되는 임시 폴더

# ── 콘솔 한글/한자 깨짐 방지 ────────────────────────────────
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

def log(m):
    try: print(m, flush=True)
    except Exception: print(str(m).encode("ascii", "replace").decode("ascii"), flush=True)

def ensure(pkg, imp=None):
    import importlib.util
    if importlib.util.find_spec(imp or pkg) is None:
        log(f"[setup] {pkg} 설치 중...")
        subprocess.run([sys.executable, "-m", "pip", "install", pkg], check=True)

ensure("requests")
ensure("Pillow", "PIL")
import requests
from PIL import Image, ImageOps

# Pillow 버전별 리샘플 상수 호환
try:
    RESAMPLE = Image.Resampling.LANCZOS
except AttributeError:
    RESAMPLE = Image.LANCZOS

# ── 설정값 로드 (upload_to_storage.py 와 동일 방식) ──────────
def load_env_file(path=".env.local"):
    env = {}
    if os.path.exists(path):
        for line in open(path, "r", encoding="utf-8"):
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            env[k.strip()] = v.strip().strip('"').strip("'")
    return env

fileenv = load_env_file()
SUPABASE_URL = (os.environ.get("NEXT_PUBLIC_SUPABASE_URL")
                or fileenv.get("NEXT_PUBLIC_SUPABASE_URL")
                or "https://iwrkpwmpfhlyfvutlnuy.supabase.co").rstrip("/")
SERVICE_KEY = (os.environ.get("SUPABASE_SERVICE_ROLE_KEY")
               or fileenv.get("SUPABASE_SERVICE_ROLE_KEY"))

if not SERVICE_KEY:
    log("❌ SUPABASE_SERVICE_ROLE_KEY 가 없습니다.")
    log("   PowerShell:  $env:SUPABASE_SERVICE_ROLE_KEY=\"<service_role 키>\"  설정 후 다시 실행")
    log("   또는 .env.local 에  SUPABASE_SERVICE_ROLE_KEY=<키>  추가")
    sys.exit(1)

BUCKET = "brand-assets"
AUTH = {"Authorization": f"Bearer {SERVICE_KEY}", "apikey": SERVICE_KEY}

def id_of(fname):
    m = re.match(r"^(\d+)_", os.path.basename(fname))
    return int(m.group(1)) if m else None

# ── 1. 최적화: 리사이즈 + webp 변환 ─────────────────────────
def optimize(src_path, dest_path):
    with Image.open(src_path) as im:
        im = ImageOps.exif_transpose(im)          # EXIF 회전 보정
        im = im.convert("RGB")                     # 배경은 알파 불필요
        w, h = im.size
        if w > MAX_WIDTH:
            new_h = round(h * MAX_WIDTH / w)
            im = im.resize((MAX_WIDTH, new_h), RESAMPLE)
        im.save(dest_path, "WEBP", quality=WEBP_QUALITY, method=6)
    return os.path.getsize(dest_path)

# ── 2. 업로드 (x-upsert: 덮어쓰기) ──────────────────────────
def upload(local_path, dest_path):
    with open(local_path, "rb") as f:
        data = f.read()
    r = requests.post(f"{SUPABASE_URL}/storage/v1/object/{BUCKET}/{dest_path}",
                      headers={**AUTH, "Content-Type": "image/webp", "x-upsert": "true"},
                      data=data, timeout=60)
    r.raise_for_status()
    return f"{SUPABASE_URL}/storage/v1/object/public/{BUCKET}/{dest_path}"

# ── 실행 ────────────────────────────────────────────────────
def main():
    sources = sorted(glob.glob(os.path.join(SRC_DIR, "*")), key=lambda x: id_of(x) or 0)
    sources = [p for p in sources if id_of(p) is not None and os.path.isfile(p)]
    if not sources:
        log(f"❌ {SRC_DIR}/ 에 '{{id}}_*' 형식 이미지가 없습니다.")
        sys.exit(1)

    os.makedirs(OPT_DIR, exist_ok=True)
    bg_urls = {}
    total_src = total_opt = 0

    log(f"[1/3] 최적화 (가로 ≤ {MAX_WIDTH}px, webp q{WEBP_QUALITY})")
    optimized = {}
    for p in sources:
        bid = id_of(p)
        dest = os.path.join(OPT_DIR, f"{bid}.webp")
        try:
            src_size = os.path.getsize(p)
            opt_size = optimize(p, dest)
            optimized[bid] = dest
            total_src += src_size
            total_opt += opt_size
            log(f"  ✓ id {bid:<3} {src_size//1024:>5}KB → {opt_size//1024:>4}KB  webp")
        except Exception as e:
            log(f"  ✗ id {bid} 최적화 실패 - {type(e).__name__}: {e}")

    log(f"\n[2/3] Supabase 업로드 → bg/{{id}}.webp (덮어쓰기)")
    for bid, dest in optimized.items():
        try:
            bg_urls[bid] = upload(dest, f"bg/{bid}.webp")
            log(f"  ✓ bg/{bid}.webp")
        except Exception as e:
            log(f"  ✗ id {bid} 업로드 실패 - {type(e).__name__}: {e}")

    # ── 3. index.html 의 브랜드 bgImg 연결 (브랜드 객체 한정) ──
    log("\n[3/3] index.html bgImg → .webp URL 연결")
    content = open("index.html", "r", encoding="utf-8").read()
    starts = [m.start() for m in re.finditer(r'\{id:\s*\d+', content)]
    starts.append(len(content))
    out, patched = [], 0
    for i in range(len(starts) - 1):
        seg = content[starts[i]:starts[i+1]]
        bid = int(re.search(r'id:\s*(\d+)', seg).group(1))
        if bid in bg_urls:
            new_seg, n = re.subn(r'bgImg:"[^"]*"', f'bgImg:"{bg_urls[bid]}"', seg, count=1)
            if n:
                patched += 1
                seg = new_seg
        out.append(seg)
    new_content = content[:starts[0]] + "".join(out)
    open("index.html", "w", encoding="utf-8").write(new_content)

    # ── 4. 임시 폴더 삭제 ────────────────────────────────────
    shutil.rmtree(OPT_DIR, ignore_errors=True)

    saved = (1 - total_opt / total_src) * 100 if total_src else 0
    log("\n" + "=" * 46)
    log(f"📊 최적화 {len(optimized)} / 업로드 {len(bg_urls)} / bgImg 연결 {patched}개")
    log(f"   용량: {total_src//1024//1024}MB → {total_opt//1024}KB  (약 {saved:.0f}% 절감)")
    log(f"   임시 폴더 '{OPT_DIR}/' 삭제 완료")
    if bg_urls:
        log(f"   URL 예시: {next(iter(bg_urls.values()))}")
    log("=" * 46)

if __name__ == "__main__":
    main()
