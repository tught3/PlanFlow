f = open('lib/screens/auth/login_screen.dart', 'r', encoding='utf-8').read()
idx = f.find('String? _validate()')
print(f[idx:idx+1500])
