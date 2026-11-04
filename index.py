"""Vercel entrypoint; app package is under backend, with no module-name collision."""
import sys
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parent/'backend'))
from app.main import app
