import subprocess
result = subprocess.run(
    [r'C:\src\flutter\bin\flutter.BAT', 'analyze',
     'lib/widgets/overlap_warning_dialog.dart',
     'lib/screens/settings/beta_survey_sheet.dart',
     'lib/screens/settings/feedback_report_sheet.dart'],
    capture_output=True, text=True, encoding='utf-8', errors='replace'
)
print('EXIT:', result.returncode)
print('STDOUT:', result.stdout)
print('STDERR:', result.stderr)
