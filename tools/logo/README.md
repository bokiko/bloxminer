# Logo generator

`gen.py` writes `assets/{logo,icon}-{light,dark}.svg`: a 4×5 core-grid "B" with one amber "hot core",
plus the wordmark converted to outlines (no font needed to view it).

    python3 -m venv venv && ./venv/bin/pip install fonttools
    # Inter 4.1 (SIL Open Font License 1.1): https://github.com/rsms/inter/releases/tag/v4.1
    cd ../../assets && ../tools/logo/venv/bin/python ../tools/logo/gen.py /path/to/InterDisplay-Bold.ttf

Font file used: `extras/ttf/InterDisplay-Bold.ttf` sha256 `b74c8e0dd744b3347faca4c96bc7b2e32f7d6f62300a79b1d1a99331e44a5bc4`.

Wordmark outlines are derived from Inter Display Bold, © The Inter Project Authors, SIL OFL 1.1.

## Social preview

`assets/social-preview.png` (1280×640, GitHub repo card) is rendered from `tools/social/social-preview.html`:

    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless=new --hide-scrollbars \
      --force-device-scale-factor=1 --window-size=1280,640 \
      --screenshot=$PWD/assets/social-preview.png file://$PWD/tools/social/social-preview.html

Upload it in the repository's Settings → General → Social preview.
