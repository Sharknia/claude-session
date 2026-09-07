"""개발 시 1회 생성: python -m pip install ds_store==1.3.3
일반 DMG 빌드는 생성된 Finder.DS_Store를 복사하며 Python 패키지가 필요 없다.
"""
from pathlib import Path
from ds_store import DSStore

output = Path(__file__).with_name('Finder.DS_Store')
with DSStore.open(str(output), 'w+') as store:
    store['.']['vSrn'] = ('long', 1)
    store['.']['bwsp'] = {
        'ShowStatusBar': False, 'ShowToolbar': False, 'ShowSidebar': False,
        'ShowPathbar': False, 'ShowTabView': False,
        'ContainerShowSidebar': False, 'PreviewPaneVisibility': False,
        'WindowBounds': '{{400, 200}, {660, 360}}', 'SidebarWidth': 0,
    }
    store['.']['icvp'] = {
        'viewOptionsVersion': 1, 'backgroundType': 0,
        'iconSize': 128.0, 'textSize': 14.0,
        'backgroundColorRed': 1.0, 'backgroundColorGreen': 1.0, 'backgroundColorBlue': 1.0,
        'scrollPositionX': 0.0, 'scrollPositionY': 0.0,
        'gridSpacing': 100.0, 'gridOffsetX': 0.0, 'gridOffsetY': 0.0,
        'arrangeBy': 'none', 'labelOnBottom': True,
        'showIconPreview': True, 'showItemInfo': False,
    }
    store['.']['icvl'] = ('type', b'icnv')
    store['ClaudeSessionWarmer.app']['Iloc'] = (165, 150)
    store['Applications']['Iloc'] = (495, 150)
