import os

targets = [
    ('lib/screens/home/home_widgets.dart', 337, 480),
    ('lib/screens/settings/settings_screen.dart', 1310, 1480),
    ('lib/screens/event/event_edit_screen.dart', 1400, 1470),
    ('lib/screens/voice/voice_input_screen.dart', 895, 1010),
    ('lib/screens/event/event_edit_screen.dart', 175, 250),
    ('lib/screens/settings/settings_screen.dart', 1195, 1215),
    ('lib/screens/voice/confirm_screen.dart', 855, 880),
    ('lib/screens/voice/confirm_screen.dart', 1095, 1120),
    ('lib/screens/settings/settings_screen.dart', 1655, 1700),
    ('lib/screens/settings/settings_widgets.dart', 215, 240),
    ('lib/screens/briefing/briefing_launch_screen.dart', 105, 240),
    ('lib/screens/location/location_pick_flow.dart', 320, 460),
    ('lib/screens/calendar/calendar_screen.dart', 915, 960),
    ('lib/screens/voice/voice_conversation_screen.dart', 940, 1090),
    ('lib/screens/widgets/recurrence_selector.dart', 160, 220),
]

out = []
for path, start, end in targets:
    if not os.path.exists(path):
        out.append(f'\n!! MISSING: {path}')
        continue
    with open(path, encoding='utf-8', errors='ignore') as f:
        lines = f.readlines()
    out.append(f'\n===== {path}:{start}-{end} =====')
    for i in range(start-1, min(end, len(lines))):
        out.append(f'{i+1:5}: {lines[i]}'.rstrip('\n'))

with open('_scan_out.txt', 'w', encoding='utf-8') as f:
    f.write('\n'.join(out))
print('done', len(out), 'lines')
