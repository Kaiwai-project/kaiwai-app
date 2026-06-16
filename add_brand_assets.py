# -*- coding: utf-8 -*-
# ============================================================
# add_brand_assets.py
#   단일 브랜드(id)의 배경+로고를 Supabase Storage 에 올린다.
#     - 배경: backgrounds/{id}_*  →  webp 최적화(가로≤1000px, q80) → bg/{id}.webp
#     - 로고: logos/{id}_*         →  원본 그대로 → logo/{id}.{원본확장자}
#   index.html 은 건드리지 않는다(이미 올바른 URL로 링크돼 있어야 함).
#   기존 파일이 있으면 덮어쓴다(x-upsert).
#
#   ⚠️ SUPABASE_SERVICE_ROLE_KEY 는 .env.local 또는 환경변수에서만 읽음(코드/깃 금지).
#
#   사용:  python add_brand_assets.py 60
# ============================================================
import os, re, sys, glob
try: sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception: pass

def ensure(pkg, imp=None):
    import importlib.util
    if importlib.util.find_spec(imp or pkg) is None:
        import subprocess; subprocess.run([sys.executable, "-m", "pip", "install", pkg], check=True)
ensure("requests"); ensure("Pillow", "PIL")
import requests
from PIL import Image, ImageOps

MAX_WIDTH, QUALITY = 1000, 80
MIME = {"png":"image/png","jpg":"image/jpeg","jpeg":"image/jpeg",
        "ico":"image/x-icon","webp":"image/webp","gif":"image/gif","svg":"image/svg+xml"}

if len(sys.argv) < 2 or not sys.argv[1].isdigit():
    print("사용법:  python add_brand_assets.py <id>   (예: python add_brand_assets.py 60)")
    sys.exit(1)
TARGET_ID = int(sys.argv[1])

def load_env(path=".env.local"):
    env = {}
    if os.path.exists(path):
        for line in open(path, encoding="utf-8"):
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1); env[k.strip()] = v.strip().strip('"').strip("'")
    return env
env = load_env()
URL = (os.environ.get("NEXT_PUBLIC_SUPABASE_URL") or env.get("NEXT_PUBLIC_SUPABASE_URL")
       or "https://iwrkpwmpfhlyfvutlnuy.supabase.co").rstrip("/")
KEY = os.environ.get("SUPABASE_SERVICE_ROLE_KEY") or env.get("SUPABASE_SERVICE_ROLE_KEY")
if not KEY:
    print("❌ SUPABASE_SERVICE_ROLE_KEY 없음 — .env.local 에 추가하거나 환경변수 설정 후 재실행")
    sys.exit(1)
BUCKET = "brand-assets"
AUTH = {"Authorization": f"Bearer {KEY}", "apikey": KEY}

def find_for_id(folder):
    for p in glob.glob(f"{folder}/*"):
        m = re.match(r"^(\d+)_", os.path.basename(p))
        if m and int(m.group(1)) == TARGET_ID and os.path.isfile(p):
            return p
    return None

def upload(data, dest, ctype):
    r = requests.post(f"{URL}/storage/v1/object/{BUCKET}/{dest}",
                      headers={**AUTH, "Content-Type": ctype, "x-upsert": "true"},
                      data=data, timeout=60)
    r.raise_for_status()
    return f"{URL}/storage/v1/object/public/{BUCKET}/{dest}"

# ── 배경: 최적화 후 webp 업로드 ─────────────────────────────
bg_src = find_for_id("backgrounds")
if bg_src:
    try:
        RESAMPLE = getattr(Image, "Resampling", Image).LANCZOS
        from io import BytesIO
        with Image.open(bg_src) as im:
            im = ImageOps.exif_transpose(im).convert("RGB")
            w, h = im.size
            if w > MAX_WIDTH:
                im = im.resize((MAX_WIDTH, round(h*MAX_WIDTH/w)), RESAMPLE)
            buf = BytesIO(); im.save(buf, "WEBP", quality=QUALITY, method=6)
        src_kb, opt_kb = os.path.getsize(bg_src)//1024, len(buf.getvalue())//1024
        u = upload(buf.getvalue(), f"bg/{TARGET_ID}.webp", "image/webp")
        print(f"✓ 배경  {src_kb}KB → {opt_kb}KB  {u}")
    except Exception as e:
        print(f"✗ 배경 실패 - {type(e).__name__}: {e}")
else:
    print(f"⚠️ backgrounds/{TARGET_ID}_* 파일 없음 — 배경 건너뜀")

# ── 로고: 원본 그대로 업로드 ────────────────────────────────
logo_src = find_for_id("logos")
if logo_src:
    ext = logo_src.rsplit(".", 1)[-1].lower()
    try:
        with open(logo_src, "rb") as f: data = f.read()
        u = upload(data, f"logo/{TARGET_ID}.{ext}", MIME.get(ext, "application/octet-stream"))
        print(f"✓ 로고  logo/{TARGET_ID}.{ext}  {u}")
    except Exception as e:
        print(f"✗ 로고 실패 - {type(e).__name__}: {e}")
else:
    print(f"⚠️ logos/{TARGET_ID}_* 파일 없음 — 로고 건너뜀")

print(f"\n완료: id {TARGET_ID}. index.html 의 logo/bgImg URL 이 이 경로와 일치하는지 확인하세요.")
