#!/usr/bin/env python3
"""Prepare only the reviewed public assets, without deploying or contacting a service."""
from pathlib import Path
import re
import shutil
from zipfile import ZipFile, ZIP_DEFLATED

root = Path(__file__).resolve().parent
out = root / 'dist'
assets = ('index.html', 'privacy/index.html', 'styles.css', 'icon.svg')
if out.exists():
    unexpected = [str(p.relative_to(out)) for p in out.rglob('*') if p.is_file() and str(p.relative_to(out)) not in assets]
    if unexpected:
        raise SystemExit('Unexpected files in deployment directory; review before preparing: ' + ', '.join(unexpected))
for name in assets:
    source = root / name
    target = out / name
    target.parent.mkdir(parents=True, exist_ok=True)
    if source.suffix == '.html':
        text = source.read_text()
        if '{{' in text or 'PUBLIC_CONTACT_EMAIL' in text:
            raise SystemExit('Unresolved public-page placeholder; deployment assets not ready')
        text = re.sub(r'  <meta name="robots" content="noindex,nofollow">\n', '', text)
        text = re.sub(r'  <div class="draft-note" role="note">.*?</div>\n', '', text)
        text = text.replace('隐私政策草稿', '隐私政策').replace('草稿更新：', '最后更新：')
        text = text.replace('本网站计划使用 Cloudflare Pages', '本网站由 Cloudflare Pages')
        target.write_text(text)
    else:
        shutil.copy2(source, target)
with ZipFile(root / 's400-pages-upload.zip', 'w', ZIP_DEFLATED) as archive:
    for name in assets:
        archive.write(out / name, name)
print('Prepared public-only static assets in website/dist; no network or deployment performed.')
