import sys

targets = [
    ('lib/screens/home/home_widgets.dart', 330, 420),
    ('lib/screens/settings/settings_screen.dart', 1310, 1360),
    ('lib/screens/settings/settings_screen.dart', 1390, 1475),
    ('lib/screens/event/event_edit_screen.dart', 1400, 1470),
    ('lib/screens/voice/voice_input_screen.dart', 900, 1010),
    ('lib/screens/event/event_edit_screen.dart', 175, 260),
    ('lib/screens/settings/settings_screen.dart', 1195, 1220),
    ('lib/screens/voice/confirm_screen.dart', 855, 880),
    ('lib/screens/voice/confirm_screen.dart', 1095, 1120),
    ('lib/screens/settings/settings_screen.dart', 1655, 1700),
    ('lib/screens/settings/settings_widgets.dart', 215, 240),
]

for path, start, end in targets:
    with open(path, encoding='utf-8', errors='ignore') as f:
        lines = f.readlines()
    print(f'\n===== {path}:{start}-{end} =====')
    for i in range(start-1, min(end, len(lines))):
        print(f'{i+1:5}: {lines[i]}', end='')
