from pathlib import Path
import shutil
ROOT=Path(__file__).resolve().parents[1]
public=ROOT/'public'
if public.exists():shutil.rmtree(public)
shutil.copytree(ROOT/'frontend'/'dist',public)
print('Interface compilada copiada para public/.')
