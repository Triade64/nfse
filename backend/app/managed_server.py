"""Managed child process with a graceful stop signal controlled by its launcher."""
import os
import threading
from pathlib import Path
import uvicorn

def main():
    server=uvicorn.Server(uvicorn.Config('app.main:app',host='127.0.0.1',port=8000,log_level='warning',access_log=False))
    signal=Path(os.environ['NFSE_STOP_FILE'])
    def monitor():
        while not server.should_exit:
            if signal.exists():server.should_exit=True;return
            threading.Event().wait(.3)
    threading.Thread(target=monitor,daemon=True).start()
    server.run()
if __name__=='__main__':main()
