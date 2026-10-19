@echo off
REM ============================================================================
REM Builds fileinfo and roof_wireframe as PyInstaller --onedir folders.
REM Run from the folder that contains fileinfo.py and roof_wireframe.py.
REM Output: dist\fileinfo\  and  dist\roof_wireframe\   (copy BOTH whole folders
REM to PAR\Files\ on the share - exe + _internal together)
REM ============================================================================
setlocal
cd /d "%~dp0"

python -m pip install --upgrade pyinstaller numpy scipy matplotlib || goto :err

REM --- fileinfo: only needs numpy + scipy.io ---
python -m PyInstaller --onedir --noconfirm --clean --noupx --name fileinfo ^
  --exclude-module matplotlib --exclude-module tkinter --exclude-module pandas ^
  --exclude-module IPython --exclude-module pytest --exclude-module PyQt5 --exclude-module PyQt6 ^
  --exclude-module PySide2 --exclude-module PySide6 ^
  fileinfo.py || goto :err

REM --- roof_wireframe: needs numpy, scipy.io, matplotlib (Agg backend) + Pillow for jpg ---
python -m PyInstaller --onedir --noconfirm --clean --noupx --name roof_wireframe ^
  --exclude-module tkinter --exclude-module pandas ^
  --exclude-module IPython --exclude-module pytest --exclude-module PyQt5 --exclude-module PyQt6 ^
  --exclude-module PySide2 --exclude-module PySide6 ^
  --exclude-module matplotlib.backends.backend_tkagg --exclude-module matplotlib.backends._backend_tk ^
  roof_wireframe.py || goto :err

echo.
echo Done. Copy dist\fileinfo and dist\roof_wireframe (whole folders) to PAR\Files\
exit /b 0
:err
echo.
echo BUILD FAILED
exit /b 1
